from pathlib import Path
import os
import subprocess
import sys

try:
    from PIL import Image
except Exception:
    print("Pillow is required to convert PNG to ICO. Install with: pip install pillow")
    sys.exit(1)

ROOT = Path(__file__).parent
ASSETS = ROOT / "assets"
PNG = ASSETS / "icon-b.png"
ICO = ASSETS / "icon-b.ico"
DIST = ROOT / "dist"
BUILD = ROOT / "build"
SPEC = ROOT / "ServerBackup.spec"

if not PNG.exists():
    print("Missing assets/icon-b.png — place the provided icon at assets/icon-b.png and re-run.")
    sys.exit(2)

# convert PNG to ICO with multiple sizes for Windows taskbar
try:
    img = Image.open(PNG)
    print(f"Image size: {img.size}, mode: {img.mode}")
    img = img.convert("RGBA")  # ensure RGBA mode for transparency
    # Crop to square if not already
    width, height = img.size
    if width != height:
        size = min(width, height)
        left = (width - size) // 2
        top = (height - size) // 2
        right = left + size
        bottom = top + size
        img = img.crop((left, top, right, bottom))
        print(f"Cropped to square: {img.size}")
    sizes = [(16, 16), (32, 32), (48, 48), (256, 256)]
    img.save(ICO, format="ICO", sizes=sizes)
    print(f"Wrote {ICO}")
except Exception as e:
    print("Failed to create ICO:", e)
    sys.exit(3)

# Build with PyInstaller using the current Python interpreter (avoids PATH issues)
name = "ServerBackup"
# Clean prior builds to avoid Windows icon cache and stale resources
for path in [DIST, BUILD, SPEC]:
    if path.exists():
        if path.is_file():
            path.unlink(missing_ok=True)
        else:
            # remove directory tree
            import shutil

            shutil.rmtree(path, ignore_errors=True)
# PyInstaller requires add-data with platform-specific separator
add_data = f"{ASSETS}{os.pathsep}assets"
cmd = [
    sys.executable,
    "-m",
    "PyInstaller",
    "--onefile",
    "--windowed",
    "--clean",
    "--noconfirm",
    "--name",
    name,
    "--icon",
    str(ICO.relative_to(ROOT)),
    "src/app.py",
    "--add-data",
    add_data,
]

print("Running:", " ".join(map(str, cmd)))
ret = subprocess.call(cmd)
if ret != 0:
    print("PyInstaller failed with code", ret)
    sys.exit(ret)

print("Build complete. Dist/ holds the exe.")
