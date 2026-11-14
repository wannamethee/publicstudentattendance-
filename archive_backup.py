"""
ไฟล์สำรองทั้งระบบ (.zip) — ใช้กู้คืนเมื่อเครื่องเสีย / ไดรฟ์พัง / ย้ายเครื่อง (เจ้าของเลือก 7 พ.ย. 2569)

ในไฟล์ .zip
  school_archive.db      ฐานข้อมูลทั้งหมดทุกภาคเรียน (ไม่มี PIN ของครู)
  csv/<ตาราง>.csv        ทุกตารางเป็น CSV (UTF-8 เปิดด้วย Excel ได้) ไว้ตรวจทาน/ใช้กับโปรแกรมอื่น
  data/ uploads/ output/ รูปเยี่ยมบ้าน ไฟล์ตารางสอบ โลโก้ รายงาน
  outputs/               ไฟล์ ปพ.5 ทั้งหมด (เฉพาะชุดที่ "รวม ปพ.5"; ชุดอื่นระบบสร้าง ปพ.5 ใหม่จากฐานข้อมูลเองตอนกลางคืน)
  program/               ตัวโปรแกรมทั้งหมด (โค้ด หน้าเว็บที่ build แล้ว ชุดลงเครื่อง deploy/) ไม่มี token ngrok / auth_secret
  manifest.json          สร้างเมื่อไร มีอะไร จำนวนแถวแต่ละตาราง

สำรองอัตโนมัติทุกคืน (run_attendance_day_rollover): ทุกวันไม่รวม ปพ.5, วันอาทิตย์รวม ปพ.5
เก็บไว้ 7 วันล่าสุดทั้งในเครื่องและบน Google Drive (ทุกชุด รวมที่กดสร้างเอง) — อยากเก็บนานกว่านั้นให้ดาวน์โหลดไปเก็บเอง
ส่งขึ้น Google Drive ด้วย rclone (offsite_sync) เมื่อตั้งค่า offsite_remote ไว้ (หน้าตั้งค่า)

กู้คืน
- เครื่องเดิม: หน้า ตั้งค่า -> สำรองทั้งระบบ (.zip) -> กู้คืน
- ไดรฟ์พัง/เครื่องใหม่: แตก .zip -> โฟลเดอร์ program/ คือโปรแกรมทั้งชุด -> ลงเครื่อง (deploy/linux/setup.sh)
  -> เปิดเซิร์ฟเวอร์ -> เปิด http://localhost:8000 บนหน้าจอเครื่องเซิร์ฟเวอร์ -> หน้า "กู้คืนระบบ" (ขึ้นเมื่อฐานข้อมูลว่าง)
  -> อัปโหลด .zip  หรือ  python restore_archive.py <ไฟล์.zip>
- สำรองฐานข้อมูลปัจจุบันก่อนเสมอ • PIN ของครูในเครื่องนี้คงเดิม (จับคู่ด้วยรหัสครู) ครูอื่นใช้รหัสครูเป็น PIN แรก
- ไฟล์ถูกเขียนทับเฉพาะที่มีใน .zip ไฟล์อื่นในเครื่องไม่ถูกลบ • ตัวโปรแกรมใน .zip ไม่ถูกเขียนทับโปรแกรมที่ใช้อยู่
"""
import csv
import io
import json
import os
import shutil
import sqlite3
import tempfile
import zipfile
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

ROOT = Path(__file__).resolve().parent
ARCHIVE_DIR = ROOT / "backups" / "archives"
FILE_DIRS = ["data", "uploads", "output"]          # always
PP5_DIR = "outputs"                                # only with include_outputs
SKIP_DIRS = {"pdf_page_cache", "__pycache__"}
KEEP_DAYS = 7
SECRETS = {"ngrok_token.txt", "auth_secret.txt", "standby_config.json"}
PROGRAM_TOP = ["ngrok_domain.txt", "*.py", "*.js", "package.json", "requirements.txt", "*.sh", "*.bat", "*.vbs", "*.md", "LICENSE",
               "template_ปพ5_blank.xlsx", "thai_glyph_labels.json", "courses_*.xlsx", "courses_*.csv", "*.example.json"]
PROGRAM_DIRS = ["deploy", "tests", "frontend/build/web", "frontend/lib", "frontend/web", "frontend/assets"]
PROGRAM_FILES = ["frontend/pubspec.yaml", "frontend/pubspec.lock", "frontend/analysis_options.yaml"]
SKIP_PARTS = {"__pycache__", "node_modules", "venv", ".venv", ".dart_tool"}


def program_files(root: Path = ROOT) -> List[Path]:
    """The program itself (no data, no secrets): enough to reinstall on an empty drive."""
    out = set()
    for pat in PROGRAM_TOP:
        out |= {p for p in root.glob(pat) if p.is_file()}
    out |= {p for p in (root / "scratch").glob("*.py")}
    for d in PROGRAM_DIRS:
        base = root / d
        if base.exists():
            out |= {p for p in base.rglob("*") if p.is_file()}
    out |= {root / f for f in PROGRAM_FILES if (root / f).is_file()}
    keep = []
    for p in out:
        rel = p.relative_to(root)
        if SKIP_PARTS & set(rel.parts) or p.name in SECRETS or p.name.startswith(("~$", ".")) or p.name.endswith(".tmp"):
            continue
        keep.append(p)
    return sorted(keep)


def _iter_files(base: Path):
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for f in filenames:
            p = Path(dirpath) / f
            if not f.endswith((".part", ".tmp")):
                yield p


def create_archive(include_outputs: bool = False, label: str = "", auto: bool = False,
                   db_path: Optional[str] = None, include_program: bool = True) -> Dict[str, Any]:
    db_path = str(db_path or ROOT / "school_archive.db")
    ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.now()
    kind = "full" if include_outputs else "data"
    name = f"school_backup_{now.strftime('%Y%m%d_%H%M%S')}_{'auto' if auto else 'manual'}_{kind}.zip"
    dest = ARCHIVE_DIR / name
    part = dest.with_suffix(".zip.part")
    counts: Dict[str, int] = {}
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "school_archive.db")
        s, d = sqlite3.connect(db_path), sqlite3.connect(copy)
        with d:
            s.backup(d)
        s.close()
        d.execute("UPDATE school_teachers SET login_pin = NULL")   # ไม่เก็บ PIN ของครูในไฟล์สำรอง
        d.commit()
        d.execute("VACUUM")
        tables = [r[0] for r in d.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        with zipfile.ZipFile(part, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for t in tables:
                cur = d.execute(f'SELECT * FROM "{t}"')
                cols = [c[0] for c in cur.description]
                buf = io.StringIO()
                w = csv.writer(buf)
                w.writerow(cols)
                n = 0
                for row in cur:
                    w.writerow(["" if v is None else v for v in row])
                    n += 1
                counts[t] = n
                z.writestr(f"csv/{t}.csv", "﻿" + buf.getvalue())
            d.close()
            z.write(copy, "school_archive.db")
            files = 0
            for sub in FILE_DIRS + ([PP5_DIR] if include_outputs else []):
                base = ROOT / sub
                if not base.exists():
                    continue
                for p in _iter_files(base):
                    z.write(p, p.relative_to(ROOT).as_posix())
                    files += 1
            program = 0
            if include_program:
                for p in program_files():
                    arc = "program/" + p.relative_to(ROOT).as_posix()
                    if p.suffix in (".sh", ".conf", ".service"):
                        # Linux shell/config files need LF line endings or bash refuses them
                        z.writestr(arc, p.read_bytes().replace(b"\r\n", b"\n"))
                    else:
                        z.write(p, arc)
                    program += 1
            manifest = {"created_at": now.strftime("%Y-%m-%d %H:%M:%S"),
                        "label": label or ("สำรองอัตโนมัติ" if auto else "สำรองโดยผู้ดูแลระบบ"),
                        "auto": auto, "include_outputs": include_outputs, "tables": counts, "files": files,
                        "program_files": program,
                        "note": "ไม่มี PIN ของครู • กู้คืนที่หน้าตั้งค่า หรือ python restore_archive.py <ไฟล์> "
                                "• ไดรฟ์พัง: โฟลเดอร์ program/ คือโปรแกรมทั้งชุด"}
            z.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=1))
    os.replace(part, dest)
    prune()
    return _info(dest)


def _info(p: Path) -> Dict[str, Any]:
    info = {"name": p.name, "size_mb": round(p.stat().st_size / 1048576, 1),
            "auto": "_auto_" in p.name, "include_outputs": p.name.endswith("_full.zip")}
    try:
        with zipfile.ZipFile(p) as z:
            m = json.loads(z.read("manifest.json").decode("utf-8"))
        info.update({"created_at": m.get("created_at"), "label": m.get("label"), "files": m.get("files"),
                     "program_files": m.get("program_files", 0),
                     "students": m.get("tables", {}).get("students"), "grades": m.get("tables", {}).get("grades_history")})
    except Exception as e:
        info["error"] = f"อ่านไฟล์ไม่ได้: {e}"
    return info


def list_archives() -> List[Dict[str, Any]]:
    if not ARCHIVE_DIR.exists():
        return []
    return [_info(p) for p in sorted(ARCHIVE_DIR.glob("*.zip"), key=lambda p: p.name, reverse=True)]


def archive_path(name: str) -> Path:
    p = (ARCHIVE_DIR / os.path.basename(name)).resolve()
    if p.parent != ARCHIVE_DIR.resolve() or p.suffix != ".zip" or not p.exists():
        raise FileNotFoundError("ไม่พบไฟล์สำรองนี้")
    return p


def _created(p: Path) -> Optional[datetime]:
    try:
        return datetime.strptime(p.name[14:29], "%Y%m%d_%H%M%S")
    except ValueError:
        return None


def prune(now: Optional[datetime] = None) -> List[str]:
    """Keep the last KEEP_DAYS days of archives (every kind); the newest set always stays."""
    if not ARCHIVE_DIR.exists():
        return []
    now = now or datetime.now()
    files = sorted(ARCHIVE_DIR.glob("school_backup_*.zip"), key=lambda p: (_created(p) or datetime.min, p.name))
    removed = []
    for p in files[:-1]:
        made = _created(p) or datetime.fromtimestamp(p.stat().st_mtime)
        if (now - made).total_seconds() > KEEP_DAYS * 86400:
            p.unlink()
            removed.append(p.name)
    return removed


def nightly(today: Optional[datetime] = None, db_path: Optional[str] = None, runner=None) -> Dict[str, Any]:
    """Once a day from the rollover: Sunday (or no full set within 7 days) -> with ปพ.5, otherwise data only;
    then copy to Google Drive when configured."""
    today = today or datetime.now()
    fulls = list(ARCHIVE_DIR.glob("school_backup_*_full.zip")) if ARCHIVE_DIR.exists() else []
    last_full = max((d for d in (_created(p) for p in fulls) if d), default=None)
    with_pp5 = today.weekday() == 6 or last_full is None or (today - last_full).days >= 7
    info = create_archive(include_outputs=with_pp5, auto=True, db_path=db_path)
    info["offsite"] = offsite_sync(db_path=db_path, runner=runner)
    return info


# ---------------------------------------------------------------- สำเนานอกเครื่อง (Google Drive ผ่าน rclone)
def _setting(key: str, db_path: Optional[str] = None, default: str = "") -> str:
    try:
        c = sqlite3.connect(str(db_path or ROOT / "school_archive.db"))
        r = c.execute("SELECT value FROM app_settings WHERE key = ?", (key,)).fetchone()
        c.close()
        return r[0] if r and r[0] is not None else default
    except sqlite3.Error:
        return default


def set_setting(key: str, value: str, db_path: Optional[str] = None) -> None:
    c = sqlite3.connect(str(db_path or ROOT / "school_archive.db"))
    c.execute("""INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP""", (key, value))
    c.commit()
    c.close()


def find_rclone() -> Optional[str]:
    for cand in (shutil.which("rclone"), str(ROOT / "tools" / "rclone.exe"), str(ROOT / "tools" / "rclone"),
                 "/usr/bin/rclone", "/usr/local/bin/rclone"):
        if cand and os.path.isfile(cand):
            return cand
    return None


def offsite_status(db_path: Optional[str] = None) -> Dict[str, Any]:
    try:
        last = json.loads(_setting("offsite_last", db_path) or "{}")
    except ValueError:
        last = {}
    return {"remote": _setting("offsite_remote", db_path), "rclone": find_rclone(), "keep_days": KEEP_DAYS, "last": last}


def offsite_sync(db_path: Optional[str] = None, runner=None) -> Dict[str, Any]:
    """Copy every archive to the remote (e.g. "gdrive:SchoolBackup"), then delete remote archives older than
    KEEP_DAYS days. Nothing configured -> skipped. The result is stored in app_settings.offsite_last."""
    import subprocess
    remote = _setting("offsite_remote", db_path).strip()
    if not remote:
        return {"ok": None, "message": "ยังไม่ได้ตั้งค่าที่เก็บนอกเครื่อง"}
    exe = find_rclone()
    if not exe and runner is None:
        res: Dict[str, Any] = {"ok": False, "message": "ไม่พบโปรแกรม rclone ในเครื่อง (ดูวิธีติดตั้งที่หน้าตั้งค่า)"}
    else:
        run = runner or (lambda args: subprocess.run(args, capture_output=True, text=True, timeout=3600))
        pattern = ["--include", "school_backup_*.zip"]
        steps = [[exe or "rclone", "copy", str(ARCHIVE_DIR), remote] + pattern,
                 [exe or "rclone", "delete", remote, "--min-age", f"{KEEP_DAYS}d"] + pattern]
        res = {"ok": True, "message": f"ส่งขึ้น {remote} แล้ว (เก็บ {KEEP_DAYS} วันล่าสุด)"}
        for args in steps:
            try:
                p = run(args)
            except Exception as e:
                res = {"ok": False, "message": f"rclone ทำงานไม่สำเร็จ: {e}"}
                break
            if p.returncode != 0:
                lines = (p.stderr or p.stdout or "").strip().splitlines() or ["error"]
                res = {"ok": False, "message": "rclone: " + lines[-1][:300]}
                break
    res["at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    res["remote"] = remote
    set_setting("offsite_last", json.dumps(res, ensure_ascii=False), db_path)
    return res


# ---------------------------------------------------------------- เครื่องใหม่: หน้า "กู้คืนระบบ"
def needs_recovery(db_path: Optional[str] = None) -> bool:
    """A fresh install: no teacher and no student yet, so nobody can log in to upload a backup."""
    try:
        c = sqlite3.connect(str(db_path or ROOT / "school_archive.db"))
        n = 0
        for t in ("school_teachers", "class_students"):
            try:
                n += c.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
            except sqlite3.OperationalError:
                pass
        c.close()
        return n == 0
    except sqlite3.Error:
        return True


def restore_archive(zip_path: str, db_path: Optional[str] = None, root: Optional[Path] = None,
                    with_program: bool = False) -> Dict[str, Any]:
    """Replace the database with the archive's, keep this machine's teacher PINs, write back the archive's files.
    with_program=True also writes program/ (only for an empty machine: a running program is never downgraded)."""
    db_path = str(db_path or ROOT / "school_archive.db")
    root = Path(root or ROOT)
    kept = 0
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        if "school_archive.db" not in names:
            raise ValueError("ไฟล์นี้ไม่ใช่ไฟล์สำรองทั้งระบบ (ไม่มี school_archive.db)")
        manifest = json.loads(z.read("manifest.json").decode("utf-8")) if "manifest.json" in names else {}
        with tempfile.TemporaryDirectory() as tmp:
            z.extract("school_archive.db", tmp)
            new_db = os.path.join(tmp, "school_archive.db")
            chk = sqlite3.connect(new_db)
            ok = chk.execute("PRAGMA integrity_check").fetchone()[0]
            chk.close()
            if ok != "ok":
                raise ValueError(f"ฐานข้อมูลในไฟล์สำรองเสีย ({ok})")
            pins: Dict[str, str] = {}
            safety = None
            if os.path.exists(db_path):
                cur = sqlite3.connect(db_path)
                try:
                    pins = {str(c).strip(): p for c, p in cur.execute("SELECT code, login_pin FROM school_teachers") if c and p}
                except sqlite3.Error:
                    pins = {}
                cur.close()
                import backup_manager
                safety = backup_manager.create_backup(label=f"ก่อนกู้คืนจาก {os.path.basename(zip_path)}", db_path=db_path).get("id")
            src, dst = sqlite3.connect(new_db), sqlite3.connect(db_path)
            with dst:
                src.backup(dst)
            src.close()
            for code, pin in pins.items():
                kept += dst.execute("UPDATE school_teachers SET login_pin = ? WHERE TRIM(code) = ?", (pin, code)).rowcount
            dst.execute("UPDATE school_teachers SET login_pin = code WHERE login_pin IS NULL OR login_pin = ''")
            dst.commit()
            dst.close()
        files = 0
        for n in names:
            if n.endswith("/"):
                continue
            top = n.split("/", 1)[0]
            if top == "program":
                if not with_program:
                    continue
                rel = n.split("/", 1)[1]
            elif top in FILE_DIRS + [PP5_DIR]:
                rel = n
            else:
                continue
            target = (root / rel).resolve()
            if root.resolve() not in target.parents:
                continue   # never write outside the program folder
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(n) as fsrc, open(target, "wb") as fdst:
                shutil.copyfileobj(fsrc, fdst)
            files += 1
    return {"restored_from": os.path.basename(zip_path), "created_at": manifest.get("created_at"),
            "safety_backup_id": safety, "pins_kept": kept, "files": files,
            "include_outputs": bool(manifest.get("include_outputs"))}
