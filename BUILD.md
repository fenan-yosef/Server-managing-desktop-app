Building an EXE (Windows) for distribution

Prerequisites (activate your virtualenv first):

- python installed (3.10+ recommended)
- pip install pyinstaller pillow

Steps:

1. Place the provided icon file at `assets/icon-b.png` (the app code expects this path).
2. From project root, run:

```bash
python -m pip install --upgrade pip
python -m pip install pyinstaller pillow
python build_exe.py
```

What the script does:

- Converts `assets/icon-b.png` → `assets/icon-b.ico` using Pillow
- Runs PyInstaller to produce a single-file Windows exe named `ServerBackup.exe` in `dist/`
- Bundles the `assets/` folder into the EXE so the runtime can access `assets/icon-b.png` if needed.

Notes:

- PyInstaller `--add-data` uses platform-specific separators; the script handles that.
- If you need a console app, remove `--windowed` from the `build_exe.py` command.
- For code signing or additional packaging (MSI, installer), perform those steps after the exe is produced.
