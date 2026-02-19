def _sanitize_tar_output(text: str) -> str:
    """Remove noisy tar/sysfs lines from tar output used in logs and job messages.
    Returns an empty string if only benign lines were present.
    """
    if not text:
        return ''
    lines = []
    for ln in str(text).splitlines():
        l = ln.strip()
        if not l:
            continue
        low = l.lower()
        if ('file shrank' in low
                or 'padding with zeros' in low
                or 'read error at byte' in low
                or 'input/output error' in low
                or 'removing leading' in low
                or 'permission denied' in low
                or 'cannot open' in low
                or low.startswith('tar: /sys')
                or low.startswith('tar: /proc')
                or low.startswith('tar: /dev')
                or low.startswith('tar: /run')
        ):
            continue
        lines.append(ln)
    out = '\n'.join(lines).strip()
    return out
import os
import posixpath
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional

from PyQt6.QtCore import QObject, QPropertyAnimation, QThread, Qt, pyqtSignal
from PyQt6.QtGui import QIcon
from PyQt6.QtWidgets import QGraphicsOpacityEffect
from PyQt6.QtWidgets import (
    QApplication,
    QFileDialog,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
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
import qtawesome as qta

BACKUP_ROOT = Path("backups").resolve()
DB_PATH = Path("app.db").resolve()
ASSETS_DIR = Path("assets")
APP_ICON_PNG = ASSETS_DIR / "icon-b.png"


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
    mode: str


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
                mode TEXT NOT NULL,
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
            INSERT INTO jobs (job_id, source, target_root, status, phase, progress, can_resume, message, mode, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(job_id) DO UPDATE SET
                status=excluded.status,
                phase=excluded.phase,
                progress=excluded.progress,
                can_resume=excluded.can_resume,
                message=excluded.message,
                mode=excluded.mode,
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
                job.mode,
                now,
            ),
        )
        conn.commit()
        conn.close()

    def list_jobs(self) -> List[Job]:
        conn = sqlite3.connect(self.db_path)
        cur = conn.cursor()
        cur.execute(
            "SELECT job_id, source, target_root, status, phase, progress, can_resume, message, mode FROM jobs ORDER BY updated_at DESC"
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
                mode=row[8],
            )
            for row in rows
        ]

    def get(self, job_id: str) -> Optional[Job]:
        conn = sqlite3.connect(self.db_path)
        cur = conn.cursor()
        cur.execute(
            "SELECT job_id, source, target_root, status, phase, progress, can_resume, message, mode FROM jobs WHERE job_id=?",
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
            mode=row[8],
        )

    def delete(self, job_id: str) -> None:
        conn = sqlite3.connect(self.db_path)
        conn.execute("DELETE FROM jobs WHERE job_id=?", (job_id,))
        conn.commit()
        conn.close()


class SSHManager:
    def __init__(self) -> None:
        self.client: Optional[paramiko.SSHClient] = None

    def connect(self, host: str, port: int, username: str, key_path: Optional[str], password: Optional[str]) -> None:
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

    def exec(self, command: str) -> tuple[str, str, int]:
        if not self.client:
            raise RuntimeError("Not connected")
        stdin, stdout, stderr = self.client.exec_command(command)
        out = stdout.read().decode(errors="ignore")
        err = stderr.read().decode(errors="ignore")
        code = stdout.channel.recv_exit_status()
        return out, err, code


class ConnectWorker(QObject):
    success = pyqtSignal()
    error = pyqtSignal(str)

    def __init__(self, ssh: SSHManager, host: str, port: int, user: str, key_path: Optional[str], password: Optional[str]) -> None:
        super().__init__()
        self.ssh = ssh
        self.host = host
        self.port = port
        self.user = user
        self.key_path = key_path
        self.password = password

    def run(self) -> None:
        try:
            self.ssh.connect(self.host, self.port, self.user, self.key_path, self.password)
            self.success.emit()
        except Exception as exc:  # noqa: BLE001
            self.error.emit(str(exc))


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
        self._pause_event = threading.Event()
        self._cancel_event = threading.Event()
        self._process: Optional[subprocess.Popen[str]] = None

    def run(self) -> None:
        try:
            self._ensure_paths()
            staging = Path(self.job.target_root) / "staging"
            current = Path(self.job.target_root) / "current"
            previous = Path(self.job.target_root) / "previous"

            self._update_status("running", "clean-staging", 0, "Preparing staging")
            self._clean_dir(staging)
            staging.mkdir(parents=True, exist_ok=True)
            self._wait_if_paused()
            self._raise_if_cancelled()

            if self.job.mode == "rsync":
                self._update_status("running", "rsync", 0, "Running rsync")
                self._run_rsync(staging)
            else:
                self._update_status("running", "tar", 0, "Creating remote tar")
                self._run_tar(staging)

            self._wait_if_paused()
            self._raise_if_cancelled()
            self._update_status("running", "verify", 95, "Verifying staging")
            self._verify(staging)

            self._wait_if_paused()
            self._raise_if_cancelled()
            self._update_status("running", "atomic-switch", 98, "Atomic switch")
            self._atomic_switch(staging, current, previous)

            self._update_status("completed", "done", 100, "Backup completed")
            self.finished.emit("Backup completed")
        except Exception as exc:  # noqa: BLE001
            status = "aborted" if str(exc) == "Cancelled" else "failed"
            self._update_status(status, self.job.phase, self.job.progress, str(exc))
            self.error.emit(str(exc))

    def request_pause(self, paused: bool) -> None:
        if paused:
            self._pause_event.set()
        else:
            self._pause_event.clear()

    def request_cancel(self) -> None:
        self._cancel_event.set()
        if self._process and self._process.poll() is None:
            try:
                self._process.terminate()
            except Exception:  # noqa: BLE001
                pass

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
        if not self._can_use_rsync():
            raise RuntimeError("rsync not available on this system; choose tar mode")
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
        self._process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        if not self._process.stdout:
            raise RuntimeError("Unable to read rsync output")
        for line in self._process.stdout:
            line = line.strip()
            if line:
                self.log.emit(line)
            percent = self._parse_percent(line)
            if percent is not None:
                self._update_status("running", "rsync", percent, "Syncing")
            self._raise_if_cancelled()
        code = self._process.wait()
        if code != 0:
            raise RuntimeError(f"rsync failed with code {code}")

    def _parse_percent(self, line: str) -> Optional[int]:
        parts = line.split()
        for part in parts:
            if part.endswith("%") and part[:-1].isdigit():
                return int(part[:-1])
        return None

    def _run_tar(self, staging: Path) -> None:
        remote_tmp = f"/tmp/{self.job.job_id}.tar.gz"
        create_cmd = f"tar -czf {remote_tmp} {self.job.source}"
        out, err, code = self.ssh.exec(create_cmd)
        if code != 0:
            # sanitize tar output before surfacing
            sanitized = _sanitize_tar_output(err or out)
            if not sanitized:
                sanitized = f"(exit code {code})"
            raise RuntimeError(f"Remote tar failed: {sanitized}")
        self._update_status("running", "download", 50, "Downloading archive")
        sftp = self.ssh.open_sftp()
        try:
            local_archive = staging / "backup.tar.gz"
            self._download_file(sftp, remote_tmp, local_archive)
        finally:
            try:
                self.ssh.exec(f"rm -f {remote_tmp}")
            except Exception:  # noqa: BLE001
                pass
            sftp.close()
        self._update_status("running", "download", 80, "Archive downloaded")

    def _download_file(self, sftp: paramiko.SFTPClient, remote_path: str, local_path: Path) -> None:
        remote_size = sftp.stat(remote_path).st_size
        local_size = local_path.stat().st_size if local_path.exists() else 0
        with sftp.open(remote_path, "rb") as src:
            if local_size > 0:
                src.seek(local_size)
            local_path.parent.mkdir(parents=True, exist_ok=True)
            with local_path.open("ab") as dst:
                transferred = local_size
                while transferred < remote_size:
                    self._wait_if_paused()
                    self._raise_if_cancelled()
                    chunk = src.read(1024 * 256)
                    if not chunk:
                        break
                    dst.write(chunk)
                    transferred += len(chunk)
                    percent = int((transferred / remote_size) * 80)
                    self._update_status("running", "download", percent, "Downloading archive")

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

    def _wait_if_paused(self) -> None:
        while self._pause_event.is_set():
            time.sleep(0.2)
            if self._cancel_event.is_set():
                break

    def _raise_if_cancelled(self) -> None:
        if self._cancel_event.is_set():
            raise RuntimeError("Cancelled")


class ExplorerModel:
    def __init__(self, ssh: SSHManager) -> None:
        self.ssh = ssh
        self.current_path = "/"

    def list_dir(self, path: str) -> list[tuple[str, bool, int]]:
        sftp = self.ssh.open_sftp()
        try:
            entries = sftp.listdir_attr(path)
            results: list[tuple[str, bool, int]] = []
            for entry in entries:
                is_dir = bool(entry.st_mode & 0o40000)
                results.append((entry.filename, is_dir, entry.st_size))
            return sorted(results, key=lambda t: (not t[1], t[0].lower()))
        finally:
            sftp.close()

    def make_dir(self, path: str) -> None:
        sftp = self.ssh.open_sftp()
        try:
            sftp.mkdir(path)
        finally:
            sftp.close()

    def delete(self, path: str) -> None:
        sftp = self.ssh.open_sftp()
        try:
            try:
                sftp.remove(path)
            except IOError:
                sftp.rmdir(path)
        finally:
            sftp.close()

    def rename(self, old: str, new: str) -> None:
        sftp = self.ssh.open_sftp()
        try:
            sftp.rename(old, new)
        finally:
            sftp.close()

    def upload(self, local_path: Path, remote_path: str) -> None:
        sftp = self.ssh.open_sftp()
        try:
            sftp.put(str(local_path), remote_path)
        finally:
            sftp.close()

    def download(self, remote_path: str, local_path: Path) -> None:
        sftp = self.ssh.open_sftp()
        try:
            local_path.parent.mkdir(parents=True, exist_ok=True)
            sftp.get(remote_path, str(local_path))
        finally:
            sftp.close()


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("Server Backup (Remote → Local)")
        self.ssh = SSHManager()
        self.store = JobStore(DB_PATH)
        self.explorer: Optional[ExplorerModel] = None
        self.job_active = False
        self._threads: list[QThread] = []
        self._current_worker: Optional[BackupWorker] = None
        self._current_thread: Optional[QThread] = None

        self.tabs = QTabWidget()
        self.setCentralWidget(self.tabs)

        self._build_login_tab()
        self._build_explorer_tab()
        self._build_backup_tab()
        self._build_jobs_tab()
        self._refresh_jobs()
        self._set_explorer_enabled(False)
        self._login_thread: Optional[QThread] = None
        self._login_worker: Optional[ConnectWorker] = None

    # Login
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

    # Explorer
    def _build_explorer_tab(self) -> None:
        tab = QWidget()
        layout = QVBoxLayout()

        path_row = QHBoxLayout()
        self.path_input = QLineEdit("/")
        self.path_input.returnPressed.connect(self._explorer_go_path)
        refresh_btn = QPushButton("Refresh")
        refresh_btn.clicked.connect(self._explorer_refresh)
        up_btn = QPushButton("Up")
        up_btn.clicked.connect(self._explorer_up)
        use_btn = QPushButton("Use as Source")
        use_btn.clicked.connect(self._use_selection_for_backup)

        path_row.addWidget(QLabel("Path"))
        path_row.addWidget(self.path_input)
        path_row.addWidget(refresh_btn)
        path_row.addWidget(up_btn)
        path_row.addWidget(use_btn)

        self.listing = QListWidget()
        self.listing.setUniformItemSizes(True)
        self.listing.itemDoubleClicked.connect(self._explorer_double_click)

        self.explorer_status = QLabel("")

        ops_row = QHBoxLayout()
        self.mkdir_btn = QPushButton("New Folder")
        self.mkdir_btn.setIcon(qta.icon("fa5s.folder-plus"))
        self.mkdir_btn.clicked.connect(self._explorer_mkdir)
        self.rename_btn = QPushButton("Rename")
        self.rename_btn.setIcon(qta.icon("fa5s.i-cursor"))
        self.rename_btn.clicked.connect(self._explorer_rename)
        self.delete_btn = QPushButton("Delete")
        self.delete_btn.setIcon(qta.icon("fa5s.trash"))
        self.delete_btn.clicked.connect(self._explorer_delete)
        self.upload_btn = QPushButton("Upload")
        self.upload_btn.setIcon(qta.icon("fa5s.upload"))
        self.upload_btn.clicked.connect(self._explorer_upload)
        self.download_btn = QPushButton("Download")
        self.download_btn.setIcon(qta.icon("fa5s.download"))
        self.download_btn.clicked.connect(self._explorer_download)

        ops_row.addWidget(self.mkdir_btn)
        ops_row.addWidget(self.rename_btn)
        ops_row.addWidget(self.delete_btn)
        ops_row.addWidget(self.upload_btn)
        ops_row.addWidget(self.download_btn)

        layout.addLayout(path_row)
        layout.addWidget(self.explorer_status)
        layout.addWidget(self.listing)
        layout.addLayout(ops_row)
        tab.setLayout(layout)
        self.tabs.addTab(tab, "Explorer")

        self.list_opacity = QGraphicsOpacityEffect()
        self.listing.setGraphicsEffect(self.list_opacity)
        self.list_anim = QPropertyAnimation(self.list_opacity, b"opacity")
        self.list_anim.setDuration(180)

    def _set_explorer_enabled(self, enabled: bool) -> None:
        for btn in [self.mkdir_btn, self.rename_btn, self.delete_btn, self.upload_btn, self.download_btn, self.listing]:
            btn.setEnabled(enabled)
        self.path_input.setReadOnly(not enabled)

    def _explorer_refresh(self) -> None:
        if not self.explorer:
            return
        self._set_loading(True)
        normalized = self._normalize_remote_path(self.path_input.text())
        self.path_input.setText(normalized)
        try:
            entries = self.explorer.list_dir(normalized)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "List failed", str(exc))
            self._set_loading(False)
            return
        self.listing.clear()
        for name, is_dir, size in entries:
            label = f"[DIR] {name}" if is_dir else f"{name} ({size} bytes)"
            item = QListWidgetItem(label)
            item.setData(Qt.ItemDataRole.UserRole, (name, is_dir))
            if is_dir:
                item.setIcon(qta.icon("fa5s.folder"))
            else:
                item.setIcon(qta.icon("fa5s.file"))
            self.listing.addItem(item)
        self._animate_list()
        self._set_loading(False)

    def _explorer_up(self) -> None:
        path = self._normalize_remote_path(self.path_input.text())
        new_path = posixpath.dirname(path.rstrip("/")) or "/"
        self.path_input.setText(new_path)
        self._explorer_refresh()

    def _explorer_go_path(self) -> None:
        # navigate to typed path on Enter
        self._explorer_refresh()

    def _explorer_double_click(self, item: QListWidgetItem) -> None:
        data = item.data(Qt.ItemDataRole.UserRole)
        if not data:
            return
        name, is_dir = data
        if not is_dir:
            return
        base = self._normalize_remote_path(self.path_input.text()).rstrip("/")
        new_path = posixpath.join(base if base else "/", name)
        new_path = self._normalize_remote_path(new_path)
        self.path_input.setText(new_path)
        self._explorer_refresh()

    def _explorer_mkdir(self) -> None:
        if not self.explorer or self.job_active:
            return
        base = self._normalize_remote_path(self.path_input.text())
        name, ok = QFileDialog.getSaveFileName(self, "Folder name", "new_folder")
        if not ok or not name:
            return
        new_path = posixpath.join(base.rstrip("/"), Path(name).name)
        new_path = self._normalize_remote_path(new_path)
        try:
            self.explorer.make_dir(new_path)
            self._explorer_refresh()
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "mkdir failed", str(exc))

    def _explorer_rename(self) -> None:
        if not self.explorer or self.job_active:
            return
        item = self.listing.currentItem()
        if not item:
            return
        name, _ = item.data(Qt.ItemDataRole.UserRole)
        base = self._normalize_remote_path(self.path_input.text()).rstrip("/")
        old_path = posixpath.join(base if base else "/", name)
        new_name, ok = QFileDialog.getSaveFileName(self, "New name", name)
        if not ok or not new_name:
            return
        new_path = posixpath.join(base if base else "/", Path(new_name).name)
        new_path = self._normalize_remote_path(new_path)
        try:
            self.explorer.rename(old_path, new_path)
            self._explorer_refresh()
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Rename failed", str(exc))

    def _explorer_delete(self) -> None:
        if not self.explorer or self.job_active:
            return
        item = self.listing.currentItem()
        if not item:
            return
        name, _ = item.data(Qt.ItemDataRole.UserRole)
        base = self._normalize_remote_path(self.path_input.text()).rstrip("/")
        target = posixpath.join(base if base else "/", name)
        if QMessageBox.question(self, "Delete", f"Delete {target}?") != QMessageBox.StandardButton.Yes:
            return
        try:
            self.explorer.delete(target)
            self._explorer_refresh()
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Delete failed", str(exc))

    def _explorer_upload(self) -> None:
        if not self.explorer or self.job_active:
            return
        local_path, _ = QFileDialog.getOpenFileName(self, "Select file to upload")
        if not local_path:
            return
        base = self._normalize_remote_path(self.path_input.text()).rstrip("/")
        remote_path = posixpath.join(base if base else "/", Path(local_path).name)
        remote_path = self._normalize_remote_path(remote_path)
        try:
            self.explorer.upload(Path(local_path), remote_path)
            self._explorer_refresh()
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Upload failed", str(exc))

    def _explorer_download(self) -> None:
        if not self.explorer or self.job_active:
            return
        item = self.listing.currentItem()
        if not item:
            return
        name, is_dir = item.data(Qt.ItemDataRole.UserRole)
        if is_dir:
            QMessageBox.information(self, "Download", "Download supports files only.")
            return
        base = self._normalize_remote_path(self.path_input.text()).rstrip("/")
        remote_path = posixpath.join(base if base else "/", name)
        local_path, _ = QFileDialog.getSaveFileName(self, "Save As", name)
        if not local_path:
            return
        try:
            self.explorer.download(remote_path, Path(local_path))
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Download failed", str(exc))

    def _use_selection_for_backup(self) -> None:
        item = self.listing.currentItem()
        if not item:
            return
        name, is_dir = item.data(Qt.ItemDataRole.UserRole)
        base = self._normalize_remote_path(self.path_input.text()).rstrip("/")
        remote_path = posixpath.join(base if base else "/", name)
        remote_path = self._normalize_remote_path(remote_path)
        if not is_dir:
            QMessageBox.information(self, "Selection", "Pick a directory for backup root.")
            return
        self.remote_path_input.setText(remote_path)
        QMessageBox.information(self, "Selection", f"Backup source set to {remote_path}")

    # Backup
    def _build_backup_tab(self) -> None:
        tab = QWidget()
        layout = QVBoxLayout()

        form = QGridLayout()
        self.remote_path_input = QLineEdit("/var/data")
        self.local_root_input = QLineEdit(str(BACKUP_ROOT))
        browse_local = QPushButton("Choose Local Root")
        browse_local.clicked.connect(self._browse_local_root)

        self.mode_input = QListWidget()
        self.mode_input.addItem("rsync (resumable)")
        self.mode_input.addItem("tar.gz (single archive)")
        self.mode_input.setCurrentRow(0)

        form.addWidget(QLabel("Remote source (Linux)"), 0, 0)
        form.addWidget(self.remote_path_input, 0, 1)
        form.addWidget(QLabel("Local backup root"), 1, 0)
        form.addWidget(self.local_root_input, 1, 1)
        form.addWidget(browse_local, 1, 2)
        form.addWidget(QLabel("Mode"), 2, 0)
        form.addWidget(self.mode_input, 2, 1)

        self.backup_progress = QProgressBar()
        self.backup_log = QTextEdit()
        self.backup_log.setReadOnly(True)
        start_btn = QPushButton("Start Backup")
        start_btn.clicked.connect(self._start_backup)
        self.pause_btn = QPushButton("Pause")
        self.pause_btn.clicked.connect(self._pause_backup)
        self.resume_btn = QPushButton("Resume")
        self.resume_btn.clicked.connect(self._resume_backup)
        self.cancel_btn = QPushButton("Cancel")
        self.cancel_btn.clicked.connect(self._cancel_backup)
        self.pause_btn.setEnabled(False)
        self.resume_btn.setEnabled(False)
        self.cancel_btn.setEnabled(False)

        layout.addLayout(form)
        layout.addWidget(start_btn)
        layout.addWidget(self.pause_btn)
        layout.addWidget(self.resume_btn)
        layout.addWidget(self.cancel_btn)
        layout.addWidget(self.backup_progress)
        layout.addWidget(self.backup_log)

        tab.setLayout(layout)
        self.tabs.addTab(tab, "Backup")

    # Jobs
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
        delete_btn = QPushButton("Delete Selected")
        delete_btn.clicked.connect(self._delete_selected_job)
        layout.addWidget(delete_btn)
        layout.addWidget(refresh_btn)
        tab.setLayout(layout)
        self.tabs.addTab(tab, "Jobs")

    # Connection helpers
    def _browse_key(self) -> None:
        home_dir = str(Path.home())
        path, _ = QFileDialog.getOpenFileName(self, "Select SSH Key", home_dir)
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
        self.status_label.setText("Connecting...")
        QApplication.setOverrideCursor(Qt.CursorShape.WaitCursor)
        connect_btn = self.sender()
        if isinstance(connect_btn, QPushButton):
            connect_btn.setEnabled(False)
        worker = ConnectWorker(self.ssh, host, port, user, key_path, password)
        thread = QThread()
        worker.moveToThread(thread)
        thread.started.connect(worker.run)
        worker.success.connect(lambda: self._on_connect_success(connect_btn, thread, worker))
        worker.error.connect(lambda msg: self._on_connect_error(msg, connect_btn, thread, worker))
        thread.finished.connect(thread.deleteLater)
        self._login_thread = thread
        self._login_worker = worker
        thread.start()

    def _disconnect(self) -> None:
        self.ssh.disconnect()
        self.status_label.setText("Disconnected")
        self._set_explorer_enabled(False)
        self.path_input.setText("/")
        self._login_thread = None
        self._login_worker = None

    # Backup workflow
    def _start_backup(self) -> None:
        if self.job_active:
            QMessageBox.information(self, "Busy", "A job is already running.")
            return
        if not self.ssh.is_connected():
            QMessageBox.warning(self, "Not Connected", "Connect first.")
            return
        remote = self.remote_path_input.text().strip()
        local_root = Path(self.local_root_input.text().strip()).resolve()
        if not remote:
            QMessageBox.warning(self, "Missing", "Remote source is required.")
            return
        mode = "rsync" if self.mode_input.currentRow() == 0 else "tar"
        if mode == "rsync" and not shutil.which("rsync"):
            QMessageBox.information(self, "rsync missing", "rsync not found in PATH. Switching to tar.gz mode.")
            mode = "tar"
            self.mode_input.setCurrentRow(1)

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
            mode=mode,
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
        thread.finished.connect(lambda: self._threads.remove(thread))
        self.job_active = True
        self._set_explorer_enabled(False)
        self._current_worker = worker
        self._current_thread = thread
        self.pause_btn.setEnabled(True)
        self.cancel_btn.setEnabled(True)
        self.resume_btn.setEnabled(False)
        self._threads.append(thread)
        thread.start()

    def _on_finished(self, message: str) -> None:
        self.job_active = False
        self._set_explorer_enabled(True)
        self.pause_btn.setEnabled(False)
        self.resume_btn.setEnabled(False)
        self.cancel_btn.setEnabled(False)
        self._current_worker = None
        self._current_thread = None
        self.backup_log.append(message)
        self._refresh_jobs()

    def _on_connect_success(self, button: Optional[QPushButton], thread: QThread, worker: ConnectWorker) -> None:
        QApplication.restoreOverrideCursor()
        if button:
            button.setEnabled(True)
        self.status_label.setText("Connected")
        self.explorer = ExplorerModel(self.ssh)
        self.path_input.setText("/")
        self._set_explorer_enabled(True)
        self._explorer_refresh()
        worker.deleteLater()
        thread.quit()
        self._login_thread = None
        self._login_worker = None

    def _on_connect_error(self, message: str, button: Optional[QPushButton], thread: QThread, worker: ConnectWorker) -> None:
        QApplication.restoreOverrideCursor()
        if button:
            button.setEnabled(True)
        self.status_label.setText("Disconnected")
        QMessageBox.critical(self, "Connection failed", message)
        worker.deleteLater()
        thread.quit()
        self._login_thread = None
        self._login_worker = None

    def _on_error(self, message: str) -> None:
        self.job_active = False
        self._set_explorer_enabled(True)
        self.pause_btn.setEnabled(False)
        self.resume_btn.setEnabled(False)
        self.cancel_btn.setEnabled(False)
        self._current_worker = None
        self._current_thread = None
        QMessageBox.critical(self, "Error", message)
        self.backup_log.append(message)
        self._refresh_jobs()

    def _delete_selected_job(self) -> None:
        item = self.jobs_list.currentItem()
        if not item:
            return
        job_id = item.text().split(" | ")[0]
        job = self.store.get(job_id)
        if not job:
            return
        if job.status == "running" and self.job_active:
            QMessageBox.information(self, "Busy", "Cancel the running job instead.")
            return
        if QMessageBox.question(self, "Delete job", f"Delete job {job_id}? This removes it from history.") != QMessageBox.StandardButton.Yes:
            return
        self.store.delete(job_id)
        self._refresh_jobs()

    def _pause_backup(self) -> None:
        if not self._current_worker:
            return
        if self._current_worker.job.mode == "rsync":
            QMessageBox.information(self, "Pause", "Pause is not supported for rsync. Use Cancel if needed.")
            return
        self._current_worker.request_pause(True)
        self.pause_btn.setEnabled(False)
        self.resume_btn.setEnabled(True)

    def _resume_backup(self) -> None:
        if not self._current_worker:
            return
        self._current_worker.request_pause(False)
        self.pause_btn.setEnabled(True)
        self.resume_btn.setEnabled(False)

    def _cancel_backup(self) -> None:
        if not self._current_worker:
            return
        if QMessageBox.question(self, "Cancel", "Cancel the running backup?") != QMessageBox.StandardButton.Yes:
            return
        self._current_worker.request_cancel()

    def _refresh_jobs(self) -> None:
        self.jobs_list.clear()
        for job in self.store.list_jobs():
            label = f"{job.job_id} | {job.status} | {job.phase} | {job.progress}% | {job.mode}"
            self.jobs_list.addItem(label)

    def _resume_selected(self) -> None:
        if self.job_active:
            QMessageBox.information(self, "Busy", "A job is already running.")
            return
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
        self.mode_input.setCurrentRow(0 if job.mode == "rsync" else 1)
        self._start_backup()

    def _normalize_remote_path(self, raw_path: str) -> str:
        path = (raw_path or "/").strip()
        path = path.replace("\\", "/")
        if not path.startswith("/"):
            path = "/" + path
        path = posixpath.normpath(path)
        return "/" if path in (".", "") else path

    def _animate_list(self) -> None:
        self.list_anim.stop()
        self.list_opacity.setOpacity(0.0)
        self.list_anim.setStartValue(0.0)
        self.list_anim.setEndValue(1.0)
        self.list_anim.start()

    def _set_loading(self, loading: bool) -> None:
        if loading:
            self.explorer_status.setText("Loading...")
            QApplication.setOverrideCursor(Qt.CursorShape.WaitCursor)
        else:
            self.explorer_status.setText("")
            QApplication.restoreOverrideCursor()


def main() -> None:
    # On Windows set an explicit AppUserModelID so the taskbar associates the
    # running process with the exe's icon and jump list. Do this before creating
    # any windows.
    if os.name == "nt":
        try:
            import ctypes

            appid = "com.server.managing.backup"
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(appid)
        except Exception:
            pass

    app = QApplication([])
    # Set application icon from assets/icon-b.png when available
    try:
        if APP_ICON_PNG.exists():
            app_icon = QIcon(str(APP_ICON_PNG))
            app.setWindowIcon(app_icon)
    except Exception:
        pass

    window = MainWindow()
    # also set window icon explicitly
    try:
        if APP_ICON_PNG.exists():
            window.setWindowIcon(QIcon(str(APP_ICON_PNG)))
    except Exception:
        pass

    window.resize(1000, 700)
    window.show()
    app.exec()


if __name__ == "__main__":
    main()
