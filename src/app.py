import os
import shutil
import sqlite3
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from PyQt6.QtCore import QObject, QThread, pyqtSignal
from PyQt6.QtWidgets import (
    QApplication,
    QFileDialog,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QProgressBar,
    QTabWidget,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

import paramiko

# Local backup layout (same filesystem for atomic moves):
# backup_root/
#   staging/  (in-progress)
#   current/  (always consistent)
#   previous/ (optional rollback)
BACKUP_ROOT = Path("backups").resolve()
DB_PATH = Path("app.db").resolve()


@dataclass
class Job:
    job_id: str
    source: str
    target_root: str
    status: str
    phase: str
    progress: int
    can_resume: bool
    message: str


class JobStore:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self._init_db()

    def _init_db(self) -> None:
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS jobs (
                job_id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                target_root TEXT NOT NULL,
                status TEXT NOT NULL,
                phase TEXT NOT NULL,
                progress INTEGER NOT NULL,
                can_resume INTEGER NOT NULL,
                message TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        conn.commit()
        conn.close()

    def upsert(self, job: Job) -> None:
        now = time.time()
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            """
            INSERT INTO jobs (job_id, source, target_root, status, phase, progress, can_resume, message, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(job_id) DO UPDATE SET
                status=excluded.status,
                phase=excluded.phase,
                progress=excluded.progress,
                can_resume=excluded.can_resume,
                message=excluded.message,
                updated_at=excluded.updated_at
            """,
            (
                job.job_id,
                job.source,
                job.target_root,
                job.status,
                job.phase,
                job.progress,
                int(job.can_resume),
                job.message,
                now,
            ),
        )
        conn.commit()
        conn.close()

    def list_jobs(self) -> list[Job]:
        conn = sqlite3.connect(self.db_path)
        cur = conn.cursor()
        cur.execute(
            "SELECT job_id, source, target_root, status, phase, progress, can_resume, message FROM jobs ORDER BY updated_at DESC"
        )
        rows = cur.fetchall()
        conn.close()
        return [
            Job(
                job_id=row[0],
                source=row[1],
                target_root=row[2],
                status=row[3],
                phase=row[4],
                progress=row[5],
                can_resume=bool(row[6]),
                message=row[7],
            )
            for row in rows
        ]

    def get(self, job_id: str) -> Job | None:
        conn = sqlite3.connect(self.db_path)
        cur = conn.cursor()
        cur.execute(
            "SELECT job_id, source, target_root, status, phase, progress, can_resume, message FROM jobs WHERE job_id=?",
            (job_id,),
        )
        row = cur.fetchone()
        conn.close()
        if not row:
            return None
        return Job(
            job_id=row[0],
            source=row[1],
            target_root=row[2],
            status=row[3],
            phase=row[4],
            progress=row[5],
            can_resume=bool(row[6]),
            message=row[7],
        )


class SSHManager:
    def __init__(self) -> None:
        self.client: paramiko.SSHClient | None = None

    def connect(self, host: str, port: int, username: str, key_path: str | None, password: str | None) -> None:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(host, port=port, username=username, key_filename=key_path or None, password=password, timeout=10)
        self.client = client

    def disconnect(self) -> None:
        if self.client:
            self.client.close()
        self.client = None

    def is_connected(self) -> bool:
        return self.client is not None

    def open_sftp(self) -> paramiko.SFTPClient:
        if not self.client:
            raise RuntimeError("Not connected")
        return self.client.open_sftp()


class BackupWorker(QObject):
    progress = pyqtSignal(int)
    log = pyqtSignal(str)
    finished = pyqtSignal(str)
    error = pyqtSignal(str)

    def __init__(
        self,
        ssh: SSHManager,
        store: JobStore,
        job: Job,
        username: str,
        host: str,
    ) -> None:
        super().__init__()
        self.ssh = ssh
        self.store = store
        self.job = job
        self.username = username
        self.host = host

    def run(self) -> None:
        try:
            self._ensure_paths()
            staging = Path(self.job.target_root) / "staging"
            current = Path(self.job.target_root) / "current"
            previous = Path(self.job.target_root) / "previous"

            self._update_status("running", "clean-staging", 0, "Preparing staging")
            self._clean_dir(staging)
            staging.mkdir(parents=True, exist_ok=True)

            if self._can_use_rsync():
                self._update_status("running", "rsync", 0, "Running rsync")
                self._run_rsync(staging)
            else:
                self._update_status("running", "sftp", 0, "Copying via SFTP")
                self._run_sftp(staging)

            self._update_status("running", "verify", 95, "Verifying")
            self._verify(staging)

            self._update_status("running", "atomic-switch", 98, "Atomic switch")
            self._atomic_switch(staging, current, previous)

            self._update_status("completed", "done", 100, "Backup completed")
            self.finished.emit("Backup completed")
        except Exception as exc:  # noqa: BLE001
            self._update_status("failed", self.job.phase, self.job.progress, str(exc))
            self.error.emit(str(exc))

    def _update_status(self, status: str, phase: str, progress: int, message: str) -> None:
        self.job.status = status
        self.job.phase = phase
        self.job.progress = progress
        self.job.message = message
        self.store.upsert(self.job)
        self.progress.emit(progress)
        self.log.emit(message)

    def _can_use_rsync(self) -> bool:
        return shutil.which("rsync") is not None

    def _run_rsync(self, staging: Path) -> None:
        remote = f"{self.username}@{self.host}:{self.job.source.rstrip('/')}/"
        cmd = [
            "rsync",
            "-av",
            "--partial",
            "--progress",
            "--delete",
            remote,
            str(staging) + os.sep,
        ]
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        if not process.stdout:
            raise RuntimeError("Unable to read rsync output")
        for line in process.stdout:
            line = line.strip()
            if line:
                self.log.emit(line)
            percent = self._parse_percent(line)
            if percent is not None:
                self._update_status("running", "rsync", percent, "Syncing")
        code = process.wait()
        if code != 0:
            raise RuntimeError(f"rsync failed with code {code}")

    def _parse_percent(self, line: str) -> int | None:
        parts = line.split()
        for part in parts:
            if part.endswith("%") and part[:-1].isdigit():
                return int(part[:-1])
        return None

    def _run_sftp(self, staging: Path) -> None:
        sftp = self.ssh.open_sftp()
        try:
            total, transferred = self._calc_remote_size(sftp, self.job.source), 0
            for root, dirs, files in self._walk_remote(sftp, self.job.source):
                rel_root = root[len(self.job.source.rstrip('/') + '/') :]
                local_root = staging / rel_root
                local_root.mkdir(parents=True, exist_ok=True)
                for fname in files:
                    remote_path = f"{root}/{fname}"
                    local_path = local_root / fname
                    transferred += self._download_file(sftp, remote_path, local_path)
                    progress = int((transferred / max(total, 1)) * 90)
                    self._update_status("running", "sftp", progress, "Copying via SFTP")
        finally:
            sftp.close()

    def _download_file(self, sftp: paramiko.SFTPClient, remote_path: str, local_path: Path) -> int:
        remote_size = sftp.stat(remote_path).st_size
        local_size = local_path.stat().st_size if local_path.exists() else 0
        if local_size == remote_size:
            return remote_size
        with sftp.open(remote_path, "rb") as src:
            if local_size > 0:
                src.seek(local_size)
            local_path.parent.mkdir(parents=True, exist_ok=True)
            with local_path.open("ab") as dst:
                copied = 0
                while True:
                    chunk = src.read(1024 * 256)
                    if not chunk:
                        break
                    dst.write(chunk)
                    copied += len(chunk)
                return copied + local_size

    def _walk_remote(self, sftp: paramiko.SFTPClient, remote_root: str):
        stack = [remote_root.rstrip("/")]
        while stack:
            current = stack.pop()
            entries = sftp.listdir_attr(current)
            dirs, files = [], []
            for entry in entries:
                mode = entry.st_mode
                if mode & 0o40000:
                    dirs.append(entry.filename)
                else:
                    files.append(entry.filename)
            for d in reversed(dirs):
                stack.append(f"{current}/{d}")
            yield current, dirs, files

    def _calc_remote_size(self, sftp: paramiko.SFTPClient, remote_root: str) -> int:
        total = 0
        for root, dirs, files in self._walk_remote(sftp, remote_root):
            for fname in files:
                total += sftp.stat(f"{root}/{fname}").st_size
        return total

    def _verify(self, staging: Path) -> None:
        if not staging.exists():
            raise RuntimeError("Staging missing")
        if not any(staging.iterdir()):
            raise RuntimeError("Staging is empty")

    def _atomic_switch(self, staging: Path, current: Path, previous: Path) -> None:
        if current.exists():
            self._clean_dir(previous)
            current.rename(previous)
        staging.rename(current)
        self._clean_dir(previous)

    def _clean_dir(self, path: Path) -> None:
        if path.exists():
            shutil.rmtree(path)

    def _ensure_paths(self) -> None:
        Path(self.job.target_root).mkdir(parents=True, exist_ok=True)


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("Server Backup (Remote → Local)")
        self.ssh = SSHManager()
        self.store = JobStore(DB_PATH)

        self.tabs = QTabWidget()
        self.setCentralWidget(self.tabs)

        self._build_login_tab()
        self._build_backup_tab()
        self._build_jobs_tab()
        self._refresh_jobs()

    def _build_login_tab(self) -> None:
        tab = QWidget()
        layout = QGridLayout()

        self.host_input = QLineEdit()
        self.port_input = QLineEdit("22")
        self.user_input = QLineEdit()
        self.key_input = QLineEdit()
        self.password_input = QLineEdit()
        self.password_input.setEchoMode(QLineEdit.EchoMode.Password)

        browse_key = QPushButton("Browse Key")
        browse_key.clicked.connect(self._browse_key)
        connect_btn = QPushButton("Connect")
        connect_btn.clicked.connect(self._connect)
        disconnect_btn = QPushButton("Disconnect")
        disconnect_btn.clicked.connect(self._disconnect)
        self.status_label = QLabel("Disconnected")

        layout.addWidget(QLabel("Host"), 0, 0)
        layout.addWidget(self.host_input, 0, 1)
        layout.addWidget(QLabel("Port"), 1, 0)
        layout.addWidget(self.port_input, 1, 1)
        layout.addWidget(QLabel("Username"), 2, 0)
        layout.addWidget(self.user_input, 2, 1)
        layout.addWidget(QLabel("SSH Key (preferred)"), 3, 0)
        layout.addWidget(self.key_input, 3, 1)
        layout.addWidget(browse_key, 3, 2)
        layout.addWidget(QLabel("Password (fallback)"), 4, 0)
        layout.addWidget(self.password_input, 4, 1)
        layout.addWidget(connect_btn, 5, 0)
        layout.addWidget(disconnect_btn, 5, 1)
        layout.addWidget(self.status_label, 6, 0, 1, 2)

        tab.setLayout(layout)
        self.tabs.addTab(tab, "Login")

    def _build_backup_tab(self) -> None:
        tab = QWidget()
        layout = QVBoxLayout()

        form = QGridLayout()
        self.remote_path_input = QLineEdit("/var/data")
        self.local_root_input = QLineEdit(str(BACKUP_ROOT))
        browse_local = QPushButton("Choose Local Root")
        browse_local.clicked.connect(self._browse_local_root)

        form.addWidget(QLabel("Remote source (Linux)"), 0, 0)
        form.addWidget(self.remote_path_input, 0, 1)
        form.addWidget(QLabel("Local backup root"), 1, 0)
        form.addWidget(self.local_root_input, 1, 1)
        form.addWidget(browse_local, 1, 2)

        self.backup_progress = QProgressBar()
        self.backup_log = QTextEdit()
        self.backup_log.setReadOnly(True)
        start_btn = QPushButton("Start Backup")
        start_btn.clicked.connect(self._start_backup)

        layout.addLayout(form)
        layout.addWidget(start_btn)
        layout.addWidget(self.backup_progress)
        layout.addWidget(self.backup_log)

        tab.setLayout(layout)
        self.tabs.addTab(tab, "Backup")

    def _build_jobs_tab(self) -> None:
        tab = QWidget()
        layout = QVBoxLayout()
        self.jobs_list = QListWidget()
        resume_btn = QPushButton("Resume Selected")
        resume_btn.clicked.connect(self._resume_selected)
        refresh_btn = QPushButton("Refresh")
        refresh_btn.clicked.connect(self._refresh_jobs)

        layout.addWidget(self.jobs_list)
        layout.addWidget(resume_btn)
        layout.addWidget(refresh_btn)
        tab.setLayout(layout)
        self.tabs.addTab(tab, "Jobs")

    def _browse_key(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "Select SSH Key")
        if path:
            self.key_input.setText(path)

    def _browse_local_root(self) -> None:
        path = QFileDialog.getExistingDirectory(self, "Select Local Backup Root")
        if path:
            self.local_root_input.setText(path)

    def _connect(self) -> None:
        host = self.host_input.text().strip()
        port = int(self.port_input.text() or "22")
        user = self.user_input.text().strip()
        key_path = self.key_input.text().strip() or None
        password = self.password_input.text().strip() or None
        if not host or not user:
            QMessageBox.warning(self, "Missing", "Host and username are required.")
            return
        try:
            self.ssh.connect(host, port, user, key_path, password)
            self.status_label.setText("Connected")
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Connection failed", str(exc))

    def _disconnect(self) -> None:
        self.ssh.disconnect()
        self.status_label.setText("Disconnected")

    def _start_backup(self) -> None:
        if not self.ssh.is_connected():
            QMessageBox.warning(self, "Not Connected", "Connect first.")
            return
        remote = self.remote_path_input.text().strip()
        local_root = Path(self.local_root_input.text().strip()).resolve()
        if not remote:
            QMessageBox.warning(self, "Missing", "Remote source is required.")
            return
        job_id = f"backup_{int(time.time())}_{uuid.uuid4().hex[:6]}"
        job = Job(
            job_id=job_id,
            source=remote,
            target_root=str(local_root),
            status="pending",
            phase="init",
            progress=0,
            can_resume=True,
            message="",
        )
        self.store.upsert(job)
        self._refresh_jobs()
        self.backup_log.clear()
        self.backup_progress.setValue(0)

        worker = BackupWorker(
            self.ssh,
            self.store,
            job,
            username=self.user_input.text().strip(),
            host=self.host_input.text().strip(),
        )
        thread = QThread()
        worker.moveToThread(thread)
        thread.started.connect(worker.run)
        worker.progress.connect(self.backup_progress.setValue)
        worker.log.connect(self.backup_log.append)
        worker.finished.connect(lambda msg: self._on_finished(msg))
        worker.error.connect(self._on_error)
        worker.finished.connect(thread.quit)
        worker.finished.connect(worker.deleteLater)
        worker.error.connect(thread.quit)
        worker.error.connect(worker.deleteLater)
        thread.finished.connect(thread.deleteLater)
        thread.start()

    def _on_finished(self, message: str) -> None:
        self.backup_log.append(message)
        self._refresh_jobs()

    def _on_error(self, message: str) -> None:
        QMessageBox.critical(self, "Error", message)
        self.backup_log.append(message)
        self._refresh_jobs()

    def _refresh_jobs(self) -> None:
        self.jobs_list.clear()
        for job in self.store.list_jobs():
            label = f"{job.job_id} | {job.status} | {job.phase} | {job.progress}%"
            self.jobs_list.addItem(label)

    def _resume_selected(self) -> None:
        if not self.ssh.is_connected():
            QMessageBox.warning(self, "Not Connected", "Connect first.")
            return
        item = self.jobs_list.currentItem()
        if not item:
            return
        job_id = item.text().split(" | ")[0]
        job = self.store.get(job_id)
        if not job:
            QMessageBox.information(self, "Not found", "Job not found")
            return
        if job.status == "running":
            QMessageBox.information(self, "Running", "Job already running")
            return
        self.remote_path_input.setText(job.source)
        self.local_root_input.setText(job.target_root)
        self._start_backup()


def main() -> None:
    app = QApplication([])
    window = MainWindow()
    window.resize(900, 600)
    window.show()
    app.exec()


if __name__ == "__main__":
    main()
