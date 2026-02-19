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
import time
from datetime import datetime
from pathlib import Path
import shlex
import paramiko

sys.path.append('src')
from app import SSHManager, JobStore, ExplorerModel, Job

ssh = SSHManager()
store = JobStore(Path("app.db"))
explorer = None

# Limit concurrency so we don't bombard remote servers when running large batches.
# Tune this value as appropriate for your environment.
MAX_PARALLEL_BACKUPS = 4
_backup_semaphore = threading.Semaphore(MAX_PARALLEL_BACKUPS)
# Per-server locks to serialize connect attempts to the same target
_server_locks = {}
_server_locks_lock = threading.Lock()

# Persistent per-host managers to avoid reconnecting for every job.
_persistent_managers = {}
_manager_connected = set()
_persistent_managers_lock = threading.Lock()
_per_host_semaphores = {}
_per_host_semaphores_lock = threading.Lock()

# Connect instrumentation
_connect_stats = {}
_connect_stats_lock = threading.Lock()

_TAR_EXCLUDE_FLAGS = "--exclude=/sys --exclude=/proc --exclude=/dev"


def _sanitize_tar_messages(text: str) -> str:
    if not text:
        return ""
    lines = []
    for ln in str(text).splitlines():
        low = ln.strip().lower()
        if not low:
            continue
        if low.startswith("tar: removing leading `/' from member names"):
            continue
        if "file shrank by" in low and (
            low.startswith('tar: /sys')
            or low.startswith('tar: /proc')
            or low.startswith('tar: /dev')
            or low.startswith('tar: /run')
        ):
            continue
        lines.append(ln)
    return "\n".join(lines).strip()


def _build_tar_stream_cmd(remote_path: str | None) -> str:
    rp = (remote_path or '/').strip()
    if rp == '/' or rp == '':
        return f"tar -czf - {_TAR_EXCLUDE_FLAGS} -C / ."

    normalized = '/' + rp.lstrip('/')
    parts = normalized.rstrip('/').rsplit('/', 1)
    parent = parts[0] or '/'
    name = parts[1] if len(parts) > 1 else parts[0]
    return (
        f"tar -czf - {_TAR_EXCLUDE_FLAGS} "
        f"-C {shlex.quote(parent)} {shlex.quote(name)}"
    )


def _build_tar_file_cmd(remote_tmp: str, remote_path: str | None) -> str:
    stream_cmd = _build_tar_stream_cmd(remote_path)
    return stream_cmd.replace("-czf -", f"-czf {shlex.quote(remote_tmp)}", 1)


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


def _stream_remote_tar(host: str, port: int, username: str, key_path: str | None, password: str | None, remote_path: str, local_path: str, timeout: int = 60) -> None:
    """
    Connects to the remote host using Paramiko and runs a tar->gzip streaming command
    that writes the archive to stdout. The stdout is streamed and written directly to
    `local_path` to avoid creating temporary files on the remote host.

    This is used as a fallback when the remote host has insufficient /tmp space.
    """
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        # connect using provided credentials
        connect_kwargs = {
            'hostname': host,
            'port': port,
            'username': username,
            'timeout': max(10, timeout),
        }
        if key_path:
            try:
                connect_kwargs['pkey'] = paramiko.RSAKey.from_private_key_file(key_path)
            except Exception:
                # fallback to letting connect handle key file or agent
                connect_kwargs['key_filename'] = key_path
        if password:
            connect_kwargs['password'] = password

        client.connect(**connect_kwargs)

        remote_cmd = _build_tar_stream_cmd(remote_path)

        stdin, stdout, stderr = client.exec_command(remote_cmd)

        # Write stdout stream to local file in binary mode
        with open(local_path, 'wb') as lf:
            while True:
                chunk = stdout.channel.recv(32768)
                if not chunk:
                    break
                lf.write(chunk)

        exit_code = stdout.channel.recv_exit_status()
        if exit_code != 0:
            err = _sanitize_tar_messages(stderr.read().decode(errors='ignore'))
            details = err or "tar exited with non-zero status"
            raise RuntimeError(f"remote tar failed (exit {exit_code}): {details}")

    finally:
        try:
            client.close()
        except Exception:
            pass


def _run_single_batch(job_id: str, server: dict, local_root: Path, mode: str, store: JobStore, per_host_limit: int = 1) -> str:
    host = server.get("host", "")
    port = int(server.get("port", 22))
    username = server.get("username", "")
    key_path = server.get("key_path") or None
    password = server.get("password") or None
    remote_path = server.get("remote_path", "/")

    initial_job = _make_job(job_id, remote_path, str(local_root), "running", "connect", 1, "Starting", mode)
    store.upsert(initial_job)

    # Acquire global semaphore to limit overall parallelism
    _backup_semaphore.acquire()

    # Compose a key to identify this target server (includes username/port/key)
    host_key = f"{username}@{host}:{port}:{key_path or ''}"

    # Ensure we have a persistent manager for this host_key
    with _persistent_managers_lock:
        mgr = _persistent_managers.get(host_key)
        if mgr is None:
            mgr = SSHManager()
            _persistent_managers[host_key] = mgr

    # Ensure there's a per-host lock to serialize access to the persistent manager
    with _server_locks_lock:
        lock = _server_locks.get(host_key)
        if lock is None:
            lock = threading.Lock()
            _server_locks[host_key] = lock

    # Ensure a per-host semaphore exists (to limit concurrency per host)
    with _per_host_semaphores_lock:
        sem = _per_host_semaphores.get(host_key)
        if sem is None:
            sem = threading.Semaphore(per_host_limit)
            _per_host_semaphores[host_key] = sem

    auth_failed = False
    # Acquire per-host slot
    sem.acquire()
    try:
        # Use the per-host lock to serialize connect and operations on the shared manager
        with lock:
            # Connect only once for the persistent manager; if not connected, attempt to connect with retries
            need_connect = False
            with _persistent_managers_lock:
                if host_key not in _manager_connected:
                    need_connect = True

            if need_connect:
                connect_err = None
                for attempt in range(1, 4):
                    # record attempt
                    with _connect_stats_lock:
                        stats = _connect_stats.setdefault(host_key, {'attempts': 0, 'success': 0, 'failure': 0})
                        stats['attempts'] += 1
                    try:
                        mgr.connect(host, port, username, key_path, password)
                        # record success
                        with _connect_stats_lock:
                            stats['success'] += 1
                        connect_err = None
                        break
                    except Exception as e:
                        # record failure
                        with _connect_stats_lock:
                            stats['failure'] += 1
                        connect_err = e
                        if attempt < 3:
                            time.sleep(0.5 * (2 ** (attempt - 1)))
                if connect_err:
                    # mark failure to allow cleanup logic below
                    raise connect_err
                # mark manager as connected for reuse
                with _persistent_managers_lock:
                    _manager_connected.add(host_key)

        # Serialize all SSH operations on the shared manager per-host.
        with lock:
            job = _make_job(job_id, remote_path, str(local_root), "running", "tar", 10, "Connected", mode)
            store.upsert(job)

            remote_tmp = f"/tmp/{job_id}.tar.gz"
            tar_cmd = _build_tar_file_cmd(remote_tmp, remote_path)
            out, err, code = mgr.exec(tar_cmd)
            # If remote tar failed due to lack of remote space, attempt streaming tar over SSH.
            stream_fallback = False
            if code != 0:
                combined = _sanitize_tar_messages((err or '') + (out or ''))
                if 'no space' in combined.lower() or 'no space left' in combined.lower():
                    stream_fallback = True
                else:
                    details = combined or "remote tar exited with non-zero status"
                    raise RuntimeError(f"Remote tar failed: {details}")

            local_archive_path = None
            if stream_fallback:
                # ensure destination directory exists
                sanitized_host = host.replace('/', '_').replace('\\', '_').replace(':', '_')
                host_dir = local_root / sanitized_host
                host_dir.mkdir(parents=True, exist_ok=True)
                local_archive_path = host_dir / f"{job_id}.tar.gz"
                try:
                    _stream_remote_tar(host, port, username, key_path, password, remote_path, str(local_archive_path))
                except Exception as e:
                    raise RuntimeError(f"Remote tar failed and streaming fallback failed: {e}") from e

            job = _make_job(job_id, remote_path, str(local_root), "running", "download", 30, "Downloading archive", mode)
            store.upsert(job)

            # Ensure destination subfolder per host exists and use it for the archive
            local_root.mkdir(parents=True, exist_ok=True)
            # sanitize host for filesystem
            sanitized_host = host.replace('/', '_').replace('\\', '_').replace(':', '_')
            host_dir = local_root / sanitized_host
            host_dir.mkdir(parents=True, exist_ok=True)
            remote_size = 0
            sftp = mgr.open_sftp()
            try:
                if local_archive_path is not None:
                    # streaming fallback already wrote the archive locally
                    remote_size = int(local_archive_path.stat().st_size)
                    dest_path = local_archive_path
                else:
                    remote_size = sftp.stat(remote_tmp).st_size
                    # Ensure destination subfolder per host exists and use it for the archive
                    dest_path = host_dir / f"{job_id}.tar.gz"
                    sftp.get(remote_tmp, str(dest_path))
                # Ensure cleanup of remote temp file only if we created it remotely
            finally:
                try:
                    if local_archive_path is None:
                        # Clean up remote temp file only if we created it remotely
                        try:
                            sftp.remove(remote_tmp)
                        except Exception:
                            pass
                finally:
                    try:
                        sftp.close()
                    except Exception:
                        pass

            # record where we saved the archive locally for the job message
            local_path = str(dest_path)
            job = _make_job(job_id, remote_path, str(local_root), "completed", "done", 100, f"Saved to {local_path}", mode)
            store.upsert(job)
    except Exception as exc:  # noqa: BLE001
        fail_job = _make_job(job_id, remote_path, str(local_root), "failed", "error", 0, str(exc), mode)
        store.upsert(fail_job)
        # Detect authentication-related failures so we can discard the persistent manager
        et = str(exc).lower()
        if 'auth' in et or 'authentication' in et or 'permission denied' in et:
            auth_failed = True
        else:
            auth_failed = False
    finally:
        try:
            if auth_failed:
                with lock:
                    try:
                        mgr.disconnect()
                    except Exception:
                        pass
                    with _persistent_managers_lock:
                        try:
                            del _persistent_managers[host_key]
                        except Exception:
                            pass
                        _manager_connected.discard(host_key)
        except Exception:
            pass
        # Release per-host slot
        try:
            sem.release()
        except Exception:
            pass
        # Release our global semaphore permit
        try:
            _backup_semaphore.release()
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
                        per_host_limit = int(pget("per_host_limit", 1) or 1)
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
                                    args=(job_id, server, local_root_path, mode, store, per_host_limit),
                                    daemon=True,
                                )
                                t.start()
                                jobs.append({"job_id": job_id, "host": server.get("host"), "remote_path": server.get("remote_path")})
                            # include current connect stats snapshot for instrumentation
                            with _connect_stats_lock:
                                stats_snapshot = {k: v.copy() for k, v in _connect_stats.items()}
                            self.send_json({"id": req_id, "result": {"jobs": jobs, "local_root": str(local_root_path), "connect_stats": stats_snapshot}})
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
