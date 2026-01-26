# Server Backup Desktop App

PyQt6 desktop app that pulls backups from a remote Linux host to the local Windows machine using ACID-style staging (staging → atomic swap into current). Jobs are tracked in SQLite for resume/restart.

## Requirements
- Python 3.10+
- Windows host with SSH connectivity to a remote Linux server
- Optional: `rsync` available in PATH (for fast, resumable sync); falls back to tar.gz mode if absent

## Setup
1. Create and activate a virtual environment.
2. Install dependencies with `pip install -r requirements.txt`.
3. Run the app with `python src/app.py`.

## Features
- Remote SFTP explorer (lazy listing) with optional write ops (mkdir/rename/delete/upload/download) when no backup job is running.
- Select directories in the explorer to set the backup source.
- Two backup modes:
  - `rsync (resumable)`: remote → staging with --partial/--delete, then atomic swap staging → current.
  - `tar.gz (single archive)`: create tar.gz on remote, download to staging, then atomic swap staging → current.
- Layout under the local backup root: `staging/` (in-progress), `current/` (always valid), `previous/` (temporary rollback during swap).
- Jobs persisted in `app.db`; unfinished jobs can be resumed after reconnecting.

## Usage
1. Connect with SSH key (preferred) or password fallback.
2. Browse remote paths in Explorer; choose “Use as Source” on a directory to set backup source.
3. Pick mode (rsync or tar.gz) and local backup root (keep on same drive for atomic rename).
4. Start backup. Explorer becomes read-only while a job runs. Progress and logs appear in Backup tab; Jobs tab lists resumable jobs.

## Notes
- Only remote-to-local backups are supported in this build.
- Atomic moves require staging/current/previous on the same filesystem (keep them under the same drive on Windows).
