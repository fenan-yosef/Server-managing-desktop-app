#!/usr/bin/env python3
"""
Simple backend CLI stub for demoing stdin/stdout IPC with a frontend.

Supported commands (one per line):
- ping -> responds 'pong'
- time -> responds with ISO timestamp
- quit|exit -> respond 'bye' and exit
- anything else -> echo back with prefix
"""
import sys
import socket
import threading
import json
import tempfile
import uuid
from datetime import datetime
from pathlib import Path

sys.path.append('src')
from app import SSHManager, JobStore, ExplorerModel, Job

ssh = SSHManager()
store = JobStore(Path("app.db"))
explorer = None


def _make_job(job_id: str, source: str, target_root: str, status: str, phase: str, progress: int, message: str, mode: str) -> Job:
    return Job(
        job_id=job_id,
        source=source,
        target_root=target_root,
        status=status,
        phase=phase,
        progress=progress,
        can_resume=False,
        message=message,
        mode=mode,
    )


def _run_single_batch(job_id: str, server: dict, local_root: Path, mode: str, store: JobStore) -> str:
    host = server.get("host", "")
    port = int(server.get("port", 22))
    username = server.get("username", "")
    key_path = server.get("key_path") or None
    password = server.get("password") or None
    remote_path = server.get("remote_path", "/")

    initial_job = _make_job(job_id, remote_path, str(local_root), "running", "connect", 1, "Starting", mode)
    store.upsert(initial_job)

    mgr = SSHManager()
    try:
        mgr.connect(host, port, username, key_path, password)
        job = _make_job(job_id, remote_path, str(local_root), "running", "tar", 10, "Connected", mode)
        store.upsert(job)

        remote_tmp = f"/tmp/{job_id}.tar.gz"
        tar_cmd = f"tar -czf {remote_tmp} {remote_path}"
        out, err, code = mgr.exec(tar_cmd)
        if code != 0:
            raise RuntimeError(f"Remote tar failed: {err or out}")

        job = _make_job(job_id, remote_path, str(local_root), "running", "download", 30, "Downloading archive", mode)
        store.upsert(job)

        local_root.mkdir(parents=True, exist_ok=True)
        remote_size = 0
        sftp = mgr.open_sftp()
        try:
            remote_size = sftp.stat(remote_tmp).st_size
            dest_name = f"{host.replace(' ', '_')}-{Path(remote_path).name or 'backup'}-{job_id[:8]}.tar.gz"
            local_path = local_root / dest_name
            with sftp.open(remote_tmp, "rb") as src, local_path.open("wb") as dst:
                transferred = 0
                while True:
                    chunk = src.read(1024 * 256)
                    if not chunk:
                        break
                    dst.write(chunk)
                    transferred += len(chunk)
                    if remote_size > 0:
                        pct = int(30 + (transferred / remote_size) * 60)
                        job = _make_job(job_id, remote_path, str(local_root), "running", "download", pct, "Downloading archive", mode)
                        store.upsert(job)
            job = _make_job(job_id, remote_path, str(local_root), "running", "cleanup", 95, "Cleaning up", mode)
            store.upsert(job)
        finally:
            try:
                mgr.exec(f"rm -f {remote_tmp}")
            except Exception:
                pass
            try:
                sftp.close()
            except Exception:
                pass

        job = _make_job(job_id, remote_path, str(local_root), "completed", "done", 100, f"Saved to {local_path}", mode)
        store.upsert(job)
    except Exception as exc:  # noqa: BLE001
        fail_job = _make_job(job_id, remote_path, str(local_root), "failed", "error", 0, str(exc), mode)
        store.upsert(fail_job)
    finally:
        try:
            mgr.disconnect()
        except Exception:
            pass

    return job_id


class JSONSocketHandler(threading.Thread):
    def __init__(self, conn, addr):
        super().__init__(daemon=True)
        self.conn = conn
        self.addr = addr

    def send_json(self, obj):
        try:
            data = json.dumps(obj) + "\n"
            self.conn.sendall(data.encode())
        except Exception:
            pass

    def run(self):
        # Ensure we modify the module-level `explorer` when assigning
        global explorer
        try:
            buf = b""
            while True:
                chunk = self.conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        msg = json.loads(line.decode())
                    except Exception:
                        self.send_json({"error": "invalid_json"})
                        continue
                    cmd = msg.get("cmd")
                    req_id = msg.get("id")
                    # Support two shapes: legacy top-level params, or
                    # structured {"params": {...}} from the frontend helper.
                    params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
                    # Helper to read from params first, then top-level
                    def pget(k, default=None):
                        return params.get(k, msg.get(k, default))
                    if cmd == "ping":
                        self.send_json({"id": req_id, "result": "pong"})
                    elif cmd == "time":
                        self.send_json({"id": req_id, "result": datetime.utcnow().isoformat() + "Z"})
                    elif cmd == "echo":
                        self.send_json({"id": req_id, "result": f"echo: {msg.get('params')}"})
                    elif cmd == "connect":
                        host = pget("host")
                        port = pget("port", 22)
                        username = pget("username")
                        key_path = pget("key_path")
                        password = pget("password")
                        try:
                            ssh.connect(host, port, username, key_path, password)
                            explorer = ExplorerModel(ssh)
                            self.send_json({"id": req_id, "result": "connected"})
                        except Exception as e:
                            self.send_json({"id": req_id, "error": str(e)})
                    elif cmd == "disconnect":
                        ssh.disconnect()
                        explorer = None
                        self.send_json({"id": req_id, "result": "disconnected"})
                    elif cmd == "list_dir":
                        path = pget("path")
                        if explorer:
                            try:
                                entries = explorer.list_dir(path)
                                self.send_json({"id": req_id, "result": entries})
                            except Exception as e:
                                self.send_json({"id": req_id, "error": str(e)})
                        else:
                            self.send_json({"id": req_id, "error": "not connected"})
                    elif cmd == "make_dir":
                        path = pget("path")
                        if explorer:
                            try:
                                explorer.make_dir(path)
                                self.send_json({"id": req_id, "result": "ok"})
                            except Exception as e:
                                self.send_json({"id": req_id, "error": str(e)})
                        else:
                            self.send_json({"id": req_id, "error": "not connected"})
                    elif cmd == "delete":
                        path = pget("path")
                        if explorer:
                            try:
                                explorer.delete(path)
                                self.send_json({"id": req_id, "result": "ok"})
                            except Exception as e:
                                self.send_json({"id": req_id, "error": str(e)})
                        else:
                            self.send_json({"id": req_id, "error": "not connected"})
                    elif cmd == "rename":
                        old_path = pget("old_path")
                        new_path = pget("new_path")
                        if explorer:
                            try:
                                explorer.rename(old_path, new_path)
                                self.send_json({"id": req_id, "result": "ok"})
                            except Exception as e:
                                self.send_json({"id": req_id, "error": str(e)})
                        else:
                            self.send_json({"id": req_id, "error": "not connected"})
                    elif cmd == "upload":
                        local_path = pget("local_path")
                        remote_path = pget("remote_path")
                        if explorer:
                            try:
                                explorer.upload(Path(local_path), remote_path)
                                self.send_json({"id": req_id, "result": "ok"})
                            except Exception as e:
                                self.send_json({"id": req_id, "error": str(e)})
                        else:
                            self.send_json({"id": req_id, "error": "not connected"})
                    elif cmd == "download":
                        remote_path = pget("remote_path")
                        local_path = pget("local_path")
                        if explorer:
                            try:
                                explorer.download(remote_path, Path(local_path))
                                self.send_json({"id": req_id, "result": "ok"})
                            except Exception as e:
                                self.send_json({"id": req_id, "error": str(e)})
                        else:
                            self.send_json({"id": req_id, "error": "not connected"})
                    elif cmd == "start_backup":
                        remote_path = pget("remote_path")
                        local_path = pget("local_path")
                        mode = pget("mode", "rsync")
                        if explorer:
                            try:
                                # If ExplorerModel exposes a higher-level backup API, use it.
                                if hasattr(explorer, 'start_backup'):
                                    explorer.start_backup(remote_path, Path(local_path), mode=mode)
                                    self.send_json({"id": req_id, "result": "ok"})
                                else:
                                    # Fallback to download (some implementations treat download as recursive)
                                    explorer.download(remote_path, Path(local_path))
                                    self.send_json({"id": req_id, "result": "ok"})
                            except Exception as e:
                                self.send_json({"id": req_id, "error": str(e)})
                        else:
                            self.send_json({"id": req_id, "error": "not connected"})
                    elif cmd == "read_file":
                        remote_path = pget("remote_path")
                        if explorer:
                            try:
                                # Prefer a direct read API if available
                                if hasattr(explorer, 'read_file'):
                                    content = explorer.read_file(remote_path)
                                    self.send_json({"id": req_id, "result": content})
                                else:
                                    # Fallback: download to a temp file and return text
                                    tf = tempfile.NamedTemporaryFile(delete=False)
                                    tf.close()
                                    tmp_path = Path(tf.name)
                                    explorer.download(remote_path, tmp_path)
                                    try:
                                        text = tmp_path.read_text(encoding='utf-8')
                                    except Exception:
                                        text = tmp_path.read_text(encoding='latin-1')
                                    # cleanup
                                    try:
                                        tmp_path.unlink()
                                    except Exception:
                                        pass
                                    self.send_json({"id": req_id, "result": text})
                            except Exception as e:
                                self.send_json({"id": req_id, "error": str(e)})
                        else:
                            self.send_json({"id": req_id, "error": "not connected"})
                    elif cmd == "multi_backup":
                        servers = pget("servers", []) or []
                        mode = pget("mode", "tar")
                        local_root = pget("local_root") or tempfile.mkdtemp(prefix="servermgr_batch_")
                        local_root_path = Path(local_root)
                        if not servers:
                            self.send_json({"id": req_id, "error": "no_servers"})
                        else:
                            jobs = []
                            for server in servers:
                                job_id = str(uuid.uuid4())
                                t = threading.Thread(
                                    target=_run_single_batch,
                                    args=(job_id, server, local_root_path, mode, store),
                                    daemon=True,
                                )
                                t.start()
                                jobs.append({"job_id": job_id, "host": server.get("host"), "remote_path": server.get("remote_path")})
                            self.send_json({"id": req_id, "result": {"jobs": jobs, "local_root": str(local_root_path)}})
                    elif cmd == "list_jobs":
                        jobs = store.list_jobs()
                        result = [{"job_id": j.job_id, "source": j.source, "target_root": j.target_root, "status": j.status, "phase": j.phase, "progress": j.progress, "can_resume": j.can_resume, "message": j.message, "mode": j.mode} for j in jobs]
                        self.send_json({"id": req_id, "result": result})
                    elif cmd == "delete_job":
                        job_id = pget("job_id")
                        store.delete(job_id)
                        self.send_json({"id": req_id, "result": "ok"})
                    else:
                        self.send_json({"id": req_id, "error": "unknown_cmd"})
        finally:
            try:
                self.conn.close()
            except Exception:
                pass


def start_socket_server(host="127.0.0.1", port=8765):
    def server_thread():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind((host, port))
            srv.listen(5)
            print(f"backend: listening on {host}:{port}", flush=True)
            while True:
                try:
                    conn, addr = srv.accept()
                except Exception:
                    break
                handler = JSONSocketHandler(conn, addr)
                handler.start()

    t = threading.Thread(target=server_thread, daemon=True)
    t.start()


def main():
    # start socket server for JSON-line commands
    start_socket_server()
    print('backend: ready (stdin + socket)', flush=True)

    # run stdin loop in a thread to not block socket
    def stdin_thread():
        for raw in sys.stdin:
            line = raw.rstrip('\n')
            if not line:
                continue
            if line.lower() in ('quit', 'exit'):
                print('bye', flush=True)
                break
            if line.lower() == 'ping':
                print('pong', flush=True)
                continue
            if line.lower() == 'time':
                print(datetime.utcnow().isoformat() + 'Z', flush=True)
                continue
            print(f'echo: {line}', flush=True)

    t = threading.Thread(target=stdin_thread, daemon=True)
    t.start()
    # wait for the thread
    t.join()


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'error: {exc}', file=sys.stderr, flush=True)
        sys.exit(1)
