"""
Pack everything the Linux server needs into one .tar.gz (run on the current Windows server).
The database is copied with SQLite's online backup, so the server may keep running.
Thai file names are stored as UTF-8 (PAX) and unpack correctly on Linux.

Usage:  python deploy/make_migration_bundle.py [--with-backups]
Result: tmp/schooltranscription_linux_<date>.tar.gz  (copy to the Linux PC, see deploy/linux/README_TH.md)
"""
import argparse
import hashlib
import sqlite3
import sys
import tarfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.stdout.reconfigure(encoding="utf-8")

TOP_LEVEL_PATTERNS = ["*.py", "*.js", "package.json", "requirements.txt", "ngrok_token.txt", "ngrok_domain.txt", "auth_secret.txt", "*.sh",
                      "template_*.xlsx", "*.md", "LICENSE",
                      # read at runtime: the ปพ.5 glyph table and the course-import template behind /api/v1/courses/template
                      "thai_glyph_labels.json", "courses_*.xlsx", "courses_*.csv"]
DIRS = ["deploy", "tests", "scratch", "uploads", "data", "outputs", "frontend/build/web", "tools/tessdata"]
SKIP_PARTS = {"__pycache__", "node_modules", "venv", ".venv", ".dart_tool"}
# Must be in the bundle or the server starts with a missing feature
REQUIRED = ["main.py", "database.py", "school_import.py", "school_data.py", "archive_backup.py", "restore_archive.py", "quizzes.py", "exam_import.py", "student_photos.py", "pp5_labels.py", "requirements.txt", "template_ปพ5_blank.xlsx",
            "thai_glyph_labels.json", "courses_2569_term2.xlsx", "deploy/linux/setup.sh",
            "deploy/linux/status.sh", "deploy/linux/battery_guard.sh", "deploy/linux/backup_db.sh",
            "deploy/linux/fonts/THSarabun.ttf", "frontend/build/web/index.html", "frontend/build/web/main.dart.js"]


def wanted(p: Path) -> bool:
    if SKIP_PARTS & set(p.parts):
        return False
    name = p.name
    return not (name.startswith("~$") or name.startswith(".") or name.endswith(".tmp") or ".tmp." in name)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--with-backups", action="store_true", help="also pack backups/ (large)")
    args = ap.parse_args()

    out_dir = ROOT / "tmp"
    out_dir.mkdir(exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M")
    db_copy = out_dir / f"school_archive_{stamp}.db"
    src = sqlite3.connect(ROOT / "school_archive.db")
    dst = sqlite3.connect(db_copy)
    src.backup(dst)
    ok = dst.execute("PRAGMA integrity_check;").fetchone()[0]
    dst.close()
    src.close()
    if ok != "ok":
        raise SystemExit(f"database integrity check failed: {ok}")

    files = []
    for pat in TOP_LEVEL_PATTERNS:
        files += [p for p in ROOT.glob(pat) if p.is_file()]
    for d in DIRS + (["backups"] if args.with_backups else []):
        base = ROOT / d
        if base.exists():
            files += [p for p in base.rglob("*") if p.is_file() and wanted(p.relative_to(ROOT))]
    files = sorted(set(f for f in files if wanted(f.relative_to(ROOT))))

    packed = {f.relative_to(ROOT).as_posix() for f in files}
    missing = [r for r in REQUIRED if r not in packed]
    if missing:
        raise SystemExit("ไฟล์ที่จำเป็นไม่อยู่ในชุดย้ายเครื่อง: " + ", ".join(missing))

    bundle = out_dir / f"schooltranscription_linux_{stamp}.tar.gz"
    with tarfile.open(bundle, "w:gz", format=tarfile.PAX_FORMAT, encoding="utf-8") as tar:
        tar.add(db_copy, arcname="schooltranscription/school_archive.db")
        for f in files:
            arc = "schooltranscription/" + f.relative_to(ROOT).as_posix()
            if f.suffix in (".sh", ".conf", ".service"):
                # Linux shell/config files must have LF line endings or bash refuses them
                data = f.read_bytes().replace(b"\r\n", b"\n")
                info = tar.gettarinfo(str(f), arcname=arc)
                info.size = len(data)
                info.mode = 0o755 if f.suffix == ".sh" else 0o644
                import io
                tar.addfile(info, io.BytesIO(data))
            else:
                tar.add(f, arcname=arc)
    db_copy.unlink()

    h = hashlib.sha256()
    with open(bundle, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    print(f"files: {len(files) + 1}   size: {bundle.stat().st_size / 1e6:.0f} MB")
    print(f"bundle: {bundle}")
    print(f"sha256: {h.hexdigest()}")
    print("note: contains student data, the ngrok token and the login signing secret — copy by USB/LAN only, delete the copy after install")


if __name__ == "__main__":
    main()
