# Server Managing Desktop App

A PyQt6 desktop app for SSH authentication, server command management, and resumable backups with local transaction tracking.

## Requirements
- Python 3.10+
- An SSH-accessible Linux server

## Setup
1. Create and activate a virtual environment.
2. Install dependencies:
   - `pip install -r requirements.txt`
3. Run the app:
   - `python src/app.py`

## Notes
- Backups use `rsync` if available on your system. If not, the app falls back to SFTP transfers via Paramiko (resumable where possible).
- Transactions are stored locally in `app.db`.
