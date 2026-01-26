# Server Backup Desktop App

PyQt6 desktop app that pulls backups from a remote Linux host to the local Windows machine using ACID-style staging (staging → atomic swap into current). Jobs are tracked in SQLite for resume/restart.

## Requirements
- Python 3.10+
- Windows host with SSH connectivity to a remote Linux server
- Optional: `rsync` available in PATH (for fast, resumable sync); falls back to SFTP if absent

## Setup
1. Create and activate a virtual environment.
2. Install dependencies with `pip install -r requirements.txt`.
3. Run the app with `python src/app.py`.

## Backup model (remote → local, overwrite safely)
- Layout under the chosen local backup root:
  - `staging/` in-progress copy
  - `current/` always-valid backup
  - `previous/` temporary rollback during swap
- Flow: clean `staging/` → sync remote → verify not empty → atomic rename `staging/` → `current/` (move old `current/` to `previous/`, then delete `previous/`).
- Jobs persist in `app.db`; unfinished jobs can be resumed after reconnecting.

## Usage
1. Connect with SSH key (preferred) or password fallback.
2. Enter remote path (e.g., `/var/data`) and local backup root (defaults to `backups/`).
3. Start backup; progress and logs stream in the Backup tab. Jobs are listed in the Jobs tab for resume.

## Notes
- Only remote-to-local backups are supported in this build.
- Atomic moves require the staging/current/previous folders to reside on the same filesystem (true if you keep them under the same drive on Windows).
