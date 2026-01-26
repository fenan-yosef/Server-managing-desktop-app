import json
import os
import queue
import re
import shutil
import sqlite3
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from PyQt6.QtCore import QObject, QThread, pyqtSignal
from PyQt6.QtWidgets import (
    QApplication,
    QComboBox,
    QFileDialog,
    QGridLayout,
    QGroupBox,
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

DB_PATH = "app.db"


class TransactionStore:
    def __init__(self, db_path: str) -> None:
        self.db_path = db_path
        self._init_db()

    def _init_db(self) -> None:
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS transactions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                type TEXT NOT NULL,
                status TEXT NOT NULL,
                details TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        conn.commit()
        conn.close()

    def create(self, tx_type: str, details: dict) -> int:
        now = time.time()
        conn = sqlite3.connect(self.db_path)
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO transactions (type, status, details, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            (tx_type, "running", json.dumps(details), now, now),
        )
        tx_id = cur.lastrowid
        conn.commit()
        conn.close()
        return int(tx_id)

    def update_status(self, tx_id: int, status: str) -> None:
        now = time.time()
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            "UPDATE transactions SET status = ?, updated_at = ? WHERE id = ?",
            (status, now, tx_id),
        )
        conn.commit()
        conn.close()

    def list_pending(self) -> list[dict]:
        conn = sqlite3.connect(self.db_path)
        cur = conn.cursor()
        cur.execute(
            "SELECT id, type, status, details, created_at, updated_at FROM transactions WHERE status IN ('running','aborted','failed') ORDER BY updated_at DESC"
        )
        rows = cur.fetchall()
        conn.close()
        return [
            {
                "id": row[0],
                "type": row[1],
                "status": row[2],
                "details": json.loads(row[3]),
                "created_at": row[4],
                "updated_at": row[5],
            }
            for row in rows
        ]


class SSHManager:
    def __init__(self) -> None:
        self.client: paramiko.SSHClient | None = None

    def connect(self, host: str, port: int, username: str, password: str | None, key_path: str | None) -> None:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        if key_path:
            client.connect(host, port=port, username=username, key_filename=key_path, timeout=10)
        else:
            client.connect(host, port=port, username=username, password=password, timeout=10)
        self.client = client

    def disconnect(self) -> None:
        if self.client:
            self.client.close()
        self.client = None

    def is_connected(self) -> bool:
        return self.client is not None

    def exec_command(self, command: str) -> tuple[str, str]:
        if not self.client:
            raise RuntimeError("Not connected")
        stdin, stdout, stderr = self.client.exec_command(command)
        out = stdout.read().decode(errors="ignore")
        err = stderr.read().decode(errors="ignore")
        return out, err

    def open_sftp(self) -> paramiko.SFTPClient:
        if not self.client:
            raise RuntimeError("Not connected")
        return self.client.open_sftp()


class CommandWorker(QObject):
    finished = pyqtSignal(str, str)
    error = pyqtSignal(str)

    def __init__(self, ssh: SSHManager, command: str) -> None:
        super().__init__()
        self.ssh = ssh
        self.command = command

    def run(self) -> None:
        try:
            out, err = self.ssh.exec_command(self.command)
            self.finished.emit(out, err)
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
        store: TransactionStore,
        tx_id: int,
        direction: str,
        source: str,
        dest: str,
        username: str,
        host: str,
    ) -> None:
        super().__init__()
        self.ssh = ssh
        self.store = store
        self.tx_id = tx_id
        self.direction = direction
        self.source = source
        self.dest = dest
        self.username = username
        self.host = host

    def run(self) -> None:
        try:
            if self._can_use_rsync():
                self._run_rsync()
            else:
                self._run_sftp()
            self.store.update_status(self.tx_id, "completed")
            self.progress.emit(100)
            self.finished.emit("Backup completed")
        except Exception as exc:  # noqa: BLE001
            self.store.update_status(self.tx_id, "failed")
            self.error.emit(str(exc))

    def _can_use_rsync(self) -> bool:
        return shutil.which("rsync") is not None

    def _run_rsync(self) -> None:
        if self.direction == "local-to-remote":
            src = self.source
            dst = f"{self.username}@{self.host}:{self.dest}"
        else:
            src = f"{self.username}@{self.host}:{self.source}"
            dst = self.dest
        cmd = [
            "rsync",
            "-az",
            "--partial",
            "--append-verify",
            "--info=progress2",
            "-e",
            "ssh",
            src,
            dst,
        ]
        self.log.emit("Running rsync...")
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        if not process.stdout:
            raise RuntimeError("Failed to start rsync")
        for line in process.stdout:
            line = line.strip()
            if line:
                self.log.emit(line)
            match = re.search(r"(\d+)%", line)
            if match:
                self.progress.emit(int(match.group(1)))
        code = process.wait()
        if code != 0:
            raise RuntimeError(f"rsync failed with code {code}")

    def _run_sftp(self) -> None:
        self.log.emit("Using SFTP fallback (limited resume support)...")
        sftp = self.ssh.open_sftp()
        try:
            if self.direction == "local-to-remote":
                self._upload_dir(sftp, Path(self.source), self.dest)
            else:
                self._download_dir(sftp, self.source, Path(self.dest))
        finally:
            sftp.close()

    def _upload_dir(self, sftp: paramiko.SFTPClient, local_dir: Path, remote_dir: str) -> None:
        total = self._calc_local_size(local_dir)
        transferred = 0
        for root, dirs, files in os.walk(local_dir):
            rel = Path(root).relative_to(local_dir)
            remote_root = str(Path(remote_dir) / rel)
            self._ensure_remote_dir(sftp, remote_root)
            for filename in files:
                local_path = Path(root) / filename
                remote_path = str(Path(remote_root) / filename)
                transferred += self._upload_file(sftp, local_path, remote_path)
                self._emit_progress(transferred, total)

    def _download_dir(self, sftp: paramiko.SFTPClient, remote_dir: str, local_dir: Path) -> None:
        total = self._calc_remote_size(sftp, remote_dir)
        transferred = 0
        self._ensure_local_dir(local_dir)
        for entry in sftp.listdir_attr(remote_dir):
            remote_path = f"{remote_dir}/{entry.filename}"
            local_path = local_dir / entry.filename
            if paramiko.SFTPAttributes.from_stat(entry).st_mode & 0o40000:
                transferred += self._download_dir(sftp, remote_path, local_path)
            else:
                transferred += self._download_file(sftp, remote_path, local_path)
            self._emit_progress(transferred, total)
        return transferred

    def _upload_file(self, sftp: paramiko.SFTPClient, local_path: Path, remote_path: str) -> int:
        local_size = local_path.stat().st_size
        remote_size = 0
        try:
            remote_size = sftp.stat(remote_path).st_size
        except FileNotFoundError:
            remote_size = 0
        if remote_size == local_size:
            return local_size
        with local_path.open("rb") as src:
            if remote_size > 0:
                src.seek(remote_size)
            with sftp.open(remote_path, "ab") as dst:
                return self._copy_stream(src, dst, local_size - remote_size)

    def _download_file(self, sftp: paramiko.SFTPClient, remote_path: str, local_path: Path) -> int:
        remote_size = sftp.stat(remote_path).st_size
        local_size = local_path.stat().st_size if local_path.exists() else 0
        if local_size == remote_size:
            return remote_size
        with sftp.open(remote_path, "rb") as src:
            if local_size > 0:
                src.seek(local_size)
            self._ensure_local_dir(local_path.parent)
            with local_path.open("ab") as dst:
                return self._copy_stream(src, dst, remote_size - local_size)

    def _copy_stream(self, src, dst, remaining: int) -> int:
        transferred = 0
        while remaining > 0:
            chunk = src.read(min(1024 * 256, remaining))
            if not chunk:
                break
            dst.write(chunk)
            transferred += len(chunk)
            remaining -= len(chunk)
        return transferred

    def _calc_local_size(self, local_dir: Path) -> int:
        total = 0
        for root, _, files in os.walk(local_dir):
            for filename in files:
                total += (Path(root) / filename).stat().st_size
        return max(total, 1)

    def _calc_remote_size(self, sftp: paramiko.SFTPClient, remote_dir: str) -> int:
        total = 0
        for entry in sftp.listdir_attr(remote_dir):
            remote_path = f"{remote_dir}/{entry.filename}"
            if paramiko.SFTPAttributes.from_stat(entry).st_mode & 0o40000:
                total += self._calc_remote_size(sftp, remote_path)
            else:
                total += entry.st_size
        return max(total, 1)

    def _ensure_remote_dir(self, sftp: paramiko.SFTPClient, remote_dir: str) -> None:
        parts = Path(remote_dir).parts
        current = ""
        for part in parts:
            current = f"{current}/{part}" if current else part
            try:
                sftp.stat(current)
            except FileNotFoundError:
                sftp.mkdir(current)

    def _ensure_local_dir(self, path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)

    def _emit_progress(self, transferred: int, total: int) -> None:
        percent = int((transferred / total) * 100)
        self.progress.emit(min(max(percent, 0), 100))


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("Server Managing Desktop App")
        self.ssh = SSHManager()
        self.store = TransactionStore(DB_PATH)

        self.tabs = QTabWidget()
        self.setCentralWidget(self.tabs)

        self._build_login_tab()
        self._build_manage_tab()
        self._build_backup_tab()
        self._build_transactions_tab()

        self._refresh_transactions()

    def _build_login_tab(self) -> None:
        tab = QWidget()
        layout = QGridLayout()

        self.host_input = QLineEdit()
        self.port_input = QLineEdit("22")
        self.username_input = QLineEdit()
        self.password_input = QLineEdit()
        self.password_input.setEchoMode(QLineEdit.EchoMode.Password)
        self.key_input = QLineEdit()
        key_browse = QPushButton("Browse Key")
        key_browse.clicked.connect(self._browse_key)

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
        layout.addWidget(self.username_input, 2, 1)
        layout.addWidget(QLabel("Password"), 3, 0)
        layout.addWidget(self.password_input, 3, 1)
        layout.addWidget(QLabel("Key Path"), 4, 0)
        layout.addWidget(self.key_input, 4, 1)
        layout.addWidget(key_browse, 4, 2)
        layout.addWidget(connect_btn, 5, 0)
        layout.addWidget(disconnect_btn, 5, 1)
        layout.addWidget(self.status_label, 6, 0, 1, 2)

        tab.setLayout(layout)
        self.tabs.addTab(tab, "Login")

    def _build_manage_tab(self) -> None:
        tab = QWidget()
        layout = QVBoxLayout()

        cmd_row = QHBoxLayout()
        self.command_input = QLineEdit("uname -a")
        run_btn = QPushButton("Run")
        run_btn.clicked.connect(self._run_command)
        cmd_row.addWidget(self.command_input)
        cmd_row.addWidget(run_btn)

        self.command_output = QTextEdit()
        self.command_output.setReadOnly(True)

        layout.addLayout(cmd_row)
        layout.addWidget(self.command_output)

        tab.setLayout(layout)
        self.tabs.addTab(tab, "Manage")

    def _build_backup_tab(self) -> None:
        tab = QWidget()
        layout = QVBoxLayout()

        form = QGridLayout()
        self.direction_combo = QComboBox()
        self.direction_combo.addItems(["local-to-remote", "remote-to-local"])
        self.source_input = QLineEdit()
        self.dest_input = QLineEdit()
        browse_source = QPushButton("Browse Source")
        browse_dest = QPushButton("Browse Destination")
        browse_source.clicked.connect(self._browse_source)
        browse_dest.clicked.connect(self._browse_dest)

        form.addWidget(QLabel("Direction"), 0, 0)
        form.addWidget(self.direction_combo, 0, 1)
        form.addWidget(QLabel("Source"), 1, 0)
        form.addWidget(self.source_input, 1, 1)
        form.addWidget(browse_source, 1, 2)
        form.addWidget(QLabel("Destination"), 2, 0)
        form.addWidget(self.dest_input, 2, 1)
        form.addWidget(browse_dest, 2, 2)

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

    def _build_transactions_tab(self) -> None:
        tab = QWidget()
        layout = QVBoxLayout()

        self.tx_list = QListWidget()
        resume_btn = QPushButton("Resume Selected")
        resume_btn.clicked.connect(self._resume_selected)
        refresh_btn = QPushButton("Refresh")
        refresh_btn.clicked.connect(self._refresh_transactions)

        layout.addWidget(self.tx_list)
        layout.addWidget(resume_btn)
        layout.addWidget(refresh_btn)

        tab.setLayout(layout)
        self.tabs.addTab(tab, "Transactions")

    def _browse_key(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "Select SSH Key")
        if path:
            self.key_input.setText(path)

    def _browse_source(self) -> None:
        if self.direction_combo.currentText() == "local-to-remote":
            path = QFileDialog.getExistingDirectory(self, "Select Local Source")
            if path:
                self.source_input.setText(path)
        else:
            QMessageBox.information(self, "Remote Source", "Enter remote source path manually.")

    def _browse_dest(self) -> None:
        if self.direction_combo.currentText() == "remote-to-local":
            path = QFileDialog.getExistingDirectory(self, "Select Local Destination")
            if path:
                self.dest_input.setText(path)
        else:
            QMessageBox.information(self, "Remote Destination", "Enter remote destination path manually.")

    def _connect(self) -> None:
        host = self.host_input.text().strip()
        port = int(self.port_input.text().strip() or "22")
        username = self.username_input.text().strip()
        password = self.password_input.text() or None
        key_path = self.key_input.text().strip() or None
        if not host or not username:
            QMessageBox.warning(self, "Missing Info", "Host and username are required.")
            return
        try:
            self.ssh.connect(host, port, username, password, key_path)
            self.status_label.setText("Connected")
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Connection Failed", str(exc))

    def _disconnect(self) -> None:
        self.ssh.disconnect()
        self.status_label.setText("Disconnected")

    def _run_command(self) -> None:
        if not self.ssh.is_connected():
            QMessageBox.warning(self, "Not Connected", "Connect to a server first.")
            return
        command = self.command_input.text().strip()
        if not command:
            return
        worker = CommandWorker(self.ssh, command)
        thread = QThread()
        worker.moveToThread(thread)
        thread.started.connect(worker.run)
        worker.finished.connect(lambda out, err: self._show_command_output(out, err))
        worker.error.connect(self._show_error)
        worker.finished.connect(thread.quit)
        worker.finished.connect(worker.deleteLater)
        worker.error.connect(thread.quit)
        worker.error.connect(worker.deleteLater)
        thread.finished.connect(thread.deleteLater)
        thread.start()

    def _show_command_output(self, out: str, err: str) -> None:
        if err:
            self.command_output.setText(err)
        else:
            self.command_output.setText(out)

    def _start_backup(self) -> None:
        if not self.ssh.is_connected():
            QMessageBox.warning(self, "Not Connected", "Connect to a server first.")
            return
        direction = self.direction_combo.currentText()
        source = self.source_input.text().strip()
        dest = self.dest_input.text().strip()
        if not source or not dest:
            QMessageBox.warning(self, "Missing Info", "Source and destination are required.")
            return
        details = {
            "direction": direction,
            "source": source,
            "dest": dest,
            "username": self.username_input.text().strip(),
            "host": self.host_input.text().strip(),
        }
        tx_id = self.store.create("backup", details)
        self._refresh_transactions()
        self.backup_log.clear()
        self.backup_progress.setValue(0)

        worker = BackupWorker(
            self.ssh,
            self.store,
            tx_id,
            direction,
            source,
            dest,
            details["username"],
            details["host"],
        )
        thread = QThread()
        worker.moveToThread(thread)
        thread.started.connect(worker.run)
        worker.progress.connect(self.backup_progress.setValue)
        worker.log.connect(self.backup_log.append)
        worker.finished.connect(self._backup_finished)
        worker.error.connect(self._show_error)
        worker.finished.connect(thread.quit)
        worker.finished.connect(worker.deleteLater)
        worker.error.connect(thread.quit)
        worker.error.connect(worker.deleteLater)
        thread.finished.connect(thread.deleteLater)
        thread.start()

    def _backup_finished(self, message: str) -> None:
        self.backup_log.append(message)
        self._refresh_transactions()

    def _refresh_transactions(self) -> None:
        self.tx_list.clear()
        for tx in self.store.list_pending():
            label = f"#{tx['id']} {tx['type']} {tx['status']}"
            self.tx_list.addItem(label)

    def _resume_selected(self) -> None:
        if not self.ssh.is_connected():
            QMessageBox.warning(self, "Not Connected", "Connect to a server first.")
            return
        selected = self.tx_list.currentItem()
        if not selected:
            return
        tx_id = int(selected.text().split()[0].lstrip("#"))
        pending = {tx["id"]: tx for tx in self.store.list_pending()}
        tx = pending.get(tx_id)
        if not tx:
            QMessageBox.information(self, "Not Found", "Transaction not found.")
            return
        if tx["type"] != "backup":
            QMessageBox.information(self, "Unsupported", "Only backup resume is supported.")
            return
        details = tx["details"]
        self.direction_combo.setCurrentText(details["direction"])
        self.source_input.setText(details["source"])
        self.dest_input.setText(details["dest"])
        self._start_backup()

    def _show_error(self, message: str) -> None:
        QMessageBox.critical(self, "Error", message)


def main() -> None:
    app = QApplication([])
    window = MainWindow()
    window.resize(900, 600)
    window.show()
    app.exec()


if __name__ == "__main__":
    main()
