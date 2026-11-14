"""
รูปนักเรียน (student photos): one small JPEG per student ID in data/student_photos/<id>.jpg.

Upload = many photo files and/or ZIPs whose file names carry the student ID
("01234.jpg", "01234 สมชาย.png", "ม.2-1/01234.jpeg" inside a ZIP). Two steps:
  1. stage   - every photo is turned upright (EXIF), cropped to 3:4 and shrunk to 360x480 JPEG
               (~30 KB, so the student window opens at once), matched to a student and parked
               in tmp/student_photo_stage/<token>/ (not backed up, not synced);
  2. commit  - after the teacher has checked the list (with thumbnails), the photos move into
               data/student_photos/ (os.replace, same volume). cancel throws the stage away.
Who may upload: an admin for any student; a class advisor (ครูประจำชั้น/ครูที่ปรึกษา) only for
the students of the levels they advise in that semester - other files are listed as not allowed.
Who sees photos: teachers, the director and admins; a student only their own; guests never
(auth.py). data/ is in the nightly backup and the standby sync, so photos travel with the system.
"""
import io
import json
import os
import re
import secrets
import shutil
import time
import zipfile
from pathlib import Path
from typing import Any, BinaryIO, Dict, Iterable, List, Optional, Tuple, Union

# one uploaded file: its bytes, or the open (seekable) file that holds it - the server passes the temp file of
# the upload, so a ZIP is read one photo at a time and never sits in RAM whole
Source = Union[bytes, BinaryIO]

ROOT = Path(__file__).resolve().parent
PHOTO_DIR = ROOT / "data" / "student_photos"
STAGE_DIR = ROOT / "tmp" / "student_photo_stage"

PHOTO_W, PHOTO_H = 360, 480            # 3:4 portrait
JPEG_QUALITY = 85
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff", ".heic", ".heif"}
MAX_FILE_BYTES = 40 * 1024 * 1024      # one photo
MAX_ZIP_ENTRIES = 4000
MAX_ZIP_TOTAL = 3 * 1024 * 1024 * 1024  # uncompressed bytes in one ZIP
MAX_PIXELS = 80_000_000
STAGE_TTL_SECONDS = 6 * 3600
LIST_LIMIT = 2000

_SID_RE = re.compile(r"[0-9A-Za-z_-]{1,32}")
_TOKEN_RE = re.compile(r"[0-9a-f]{32}")


# ---------------------------------------------------------------- photos on disk

def valid_sid(student_id: str) -> bool:
    return bool(_SID_RE.fullmatch(str(student_id or "")))


def photo_path(student_id: str) -> Optional[Path]:
    """The stored photo of this student, or None."""
    if not valid_sid(student_id):
        return None
    p = PHOTO_DIR / f"{student_id}.jpg"
    return p if p.is_file() else None


def photo_version(student_id: str) -> Optional[int]:
    """Changes whenever the photo is replaced: the client puts it in the URL (?v=) so the
    browser may cache the picture for good and still picks up a new one at once."""
    p = photo_path(student_id)
    return int(p.stat().st_mtime_ns // 1_000_000) if p else None


def save_photo(student_id: str, data: bytes) -> Dict[str, Any]:
    """One student's photo straight from the student window (camera or a file on the device):
    normalised like the bulk upload, written atomically. Rights are checked by the caller."""
    if not valid_sid(student_id):
        raise ValueError("รหัสนักเรียนไม่ถูกต้อง")
    jpg = normalize(data)
    PHOTO_DIR.mkdir(parents=True, exist_ok=True)
    dst = PHOTO_DIR / f"{student_id}.jpg"
    existed = dst.is_file()
    tmp = PHOTO_DIR / f".{student_id}.{secrets.token_hex(4)}.tmp"
    tmp.write_bytes(jpg)
    os.replace(tmp, dst)
    return {"student_id": student_id, "version": photo_version(student_id), "replaced": existed, "bytes": len(jpg)}


def delete_photo(student_id: str) -> bool:
    p = photo_path(student_id)
    if not p:
        return False
    p.unlink(missing_ok=True)
    return True


def normalize(data: bytes) -> bytes:
    """Any photo -> upright, 3:4 crop (faces sit high in a portrait, so keep more of the top),
    at most 360x480, JPEG. Raises ValueError with a Thai reason."""
    from PIL import Image, ImageOps
    if len(data) > MAX_FILE_BYTES:
        raise ValueError("ไฟล์ใหญ่เกิน 40 MB")
    if data[4:12] in (b"ftypheic", b"ftypheix", b"ftypmif1", b"ftyphevc", b"ftypmsf1"):
        raise ValueError("ไฟล์ HEIC (iPhone) ยังเปิดไม่ได้ กรุณาบันทึกเป็น JPG ก่อน")
    try:
        img = Image.open(io.BytesIO(data))
        if img.width * img.height > MAX_PIXELS:
            raise ValueError("รูปมีขนาดพิกเซลใหญ่เกินไป")
        img = ImageOps.exif_transpose(img)
        if img.mode in ("RGBA", "LA", "P", "PA"):
            img = img.convert("RGBA")
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(img, mask=img.split()[-1])
            img = bg
        else:
            img = img.convert("RGB")
    except ValueError:
        raise
    except Exception:
        raise ValueError("ไม่ใช่ไฟล์รูปที่เปิดได้")
    w, h = img.size
    if w < 40 or h < 40:
        raise ValueError("รูปเล็กเกินไป")
    ratio = PHOTO_W / PHOTO_H
    if w / h > ratio:                      # too wide: cut both sides
        nw = round(h * ratio)
        left = (w - nw) // 2
        img = img.crop((left, 0, left + nw, h))
    elif w / h < ratio:                    # too tall: keep 30 % of the cut above, 70 % below
        nh = round(w / ratio)
        top = round((h - nh) * 0.3)
        img = img.crop((0, top, w, top + nh))
    if img.width > PHOTO_W:
        img = img.resize((PHOTO_W, PHOTO_H), Image.LANCZOS)
    out = io.BytesIO()
    img.save(out, "JPEG", quality=JPEG_QUALITY, optimize=True, progressive=True)
    return out.getvalue()


# ---------------------------------------------------------------- who is who

def _students(term: str, year: str, db_path: str) -> Dict[str, Dict[str, Any]]:
    """Every student ID the system knows -> name/class to show. A student's row in the chosen
    semester wins over older ones; DMC-only IDs are known too."""
    import database
    out: Dict[str, Dict[str, Any]] = {}
    with database.get_connection(db_path) as conn:
        rows = conn.execute(
            """SELECT student_id, full_name, class_level, room, student_no, term, year, COALESCE(is_active, 1) AS is_active
               FROM class_students
               ORDER BY CAST(year AS INTEGER), CAST(term AS INTEGER);""").fetchall()
        for r in rows:
            sid = str(r["student_id"] or "").strip()
            if not sid:
                continue
            cur = out.get(sid)
            this_sem = str(r["term"]) == str(term) and str(r["year"]) == str(year)
            if cur and cur["_this_sem"] and not this_sem:
                continue
            out[sid] = {"student_id": sid, "full_name": r["full_name"] or "", "class_level": r["class_level"] or "",
                        "room": str(r["room"] or ""), "student_no": r["student_no"], "_this_sem": this_sem,
                        "_active": bool(r["is_active"])}
        try:
            for r in conn.execute("SELECT student_id, prefix, first_name, last_name, class_level, room FROM student_dmc_info;"):
                sid = str(r["student_id"] or "").strip()
                if sid and sid not in out:
                    name = database.compose_full_name(r["prefix"] or "", r["first_name"] or "", r["last_name"] or "")
                    out[sid] = {"student_id": sid, "full_name": name, "class_level": r["class_level"] or "",
                                "room": str(r["room"] or ""), "student_no": None, "_this_sem": False, "_active": False}
        except Exception:
            pass
    return out


def upload_scope(user: Dict[str, Any], term: str, year: str, db_path: str) -> Dict[str, Any]:
    """{'all': True} for an admin; else the levels this teacher advises in that semester."""
    if user.get("role") == "admin":
        return {"all": True, "levels": []}
    if user.get("role") not in ("teacher",):
        return {"all": False, "levels": []}
    import auth
    import database
    with database.get_connection(db_path) as conn:
        levels = [r[0] for r in conn.execute(
            "SELECT DISTINCT class_level FROM class_students WHERE term = ? AND year = ? AND COALESCE(is_active, 1) = 1;",
            (str(term), str(year)))]
    mine = [lv for lv in levels if lv and auth.advises_class(user, lv, term, year, db_path=db_path)]
    return {"all": False, "levels": sorted(mine)}


def _allowed(scope: Dict[str, Any], st: Dict[str, Any]) -> bool:
    return scope["all"] or (st["_this_sem"] and st["_active"] and st["class_level"] in scope["levels"])


def can_edit(user: Dict[str, Any], student_id: str, term: str, year: str, db_path: str) -> bool:
    st = _students(term, year, db_path).get(str(student_id))
    return bool(st) and _allowed(upload_scope(user, term, year, db_path), st)


def match_name(filename: str, known: Dict[str, Any]) -> Tuple[Optional[str], str]:
    """(student_id, '') or (None, reason). The ID may be the whole name or any run of digits in it;
    a run of 3+ digits that lost its leading zeros (1234 for 01234) matches when unambiguous."""
    stem = re.split(r"[\\/]", filename)[-1]
    stem = stem.rsplit(".", 1)[0].strip()
    if stem in known:
        return stem, ""
    runs = re.findall(r"\d+", stem)
    hits = {r for r in runs if r in known}
    if not hits:
        by_int: Dict[str, Optional[str]] = {}
        for sid in known:
            if sid.isdigit():
                k = sid.lstrip("0")
                by_int[k] = None if k in by_int else sid
        hits = {by_int[r.lstrip("0")] for r in runs if len(r) >= 3 and by_int.get(r.lstrip("0"))}
    if len(hits) == 1:
        return hits.pop(), ""
    if len(hits) > 1:
        return None, "ชื่อไฟล์มีรหัสนักเรียนมากกว่า 1 คน (" + ", ".join(sorted(hits)) + ")"
    return None, "ไม่พบรหัสนักเรียนในชื่อไฟล์" if not runs else "ไม่พบนักเรียนรหัสนี้ในระบบ"


# ---------------------------------------------------------------- the student window

def _clean(v: Any) -> str:
    s = str(v or "").replace("\xa0", " ").strip()
    return "" if s in ("-", "--", "0000-00-00", "None") else re.sub(r"\s+", " ", s)


def student_profile(student_id: str, term: str, year: str, include_citizen: bool = False,
                    db_path: str = "school_archive.db") -> Optional[Dict[str, Any]]:
    """What the student window shows next to the attendance: name/class (that semester, else the
    latest), basic DMC data, address, guardian and parents, the photo version. เลขบัตรประชาชน
    only when include_citizen (admins)."""
    import database
    sid = str(student_id or "").strip()
    if not valid_sid(sid):
        return None
    with database.get_connection(db_path) as conn:
        cs = conn.execute(
            """SELECT student_id, full_name, prefix, first_name, last_name, class_level, room, student_no, term, year
               FROM class_students WHERE student_id = ?
               ORDER BY (term = ? AND year = ?) DESC, CAST(year AS INTEGER) DESC, CAST(term AS INTEGER) DESC LIMIT 1;""",
            (sid, str(term), str(year))).fetchone()
        d = conn.execute("SELECT * FROM student_dmc_info WHERE student_id = ?;", (sid,)).fetchone()
    if not cs and not d:
        return None
    d = dict(d) if d else {}
    g = lambda k: _clean(d.get(k))
    person = lambda p, f, l: database.compose_full_name(g(p), g(f), g(l)).strip()

    birth = database.thai_birth_date(g("birth_date"))
    age = database.age_on(birth)
    gender = g("gender")
    gender = {"ช": "ชาย", "ญ": "หญิง"}.get(gender, gender)
    if not gender and cs:
        gender = {"ช": "ชาย", "ญ": "หญิง"}.get(database.gender_from_prefix(cs["prefix"] or ""), "")
    parts = [("บ้านเลขที่ ", "address_no"), ("หมู่ ", "moo"), ("ถนน", "street"),
             ("ต.", "subdistrict"), ("อ.", "district"), ("จ.", "province")]
    address = " ".join(lbl + g(k) for lbl, k in parts if g(k))

    student = {"student_id": sid, "full_name": "", "class_level": g("class_level"), "room": g("room"),
               "student_no": None, "term": None, "year": None}
    if cs:
        student.update({"full_name": cs["full_name"] or "", "class_level": cs["class_level"] or "",
                        "room": str(cs["room"] or ""), "student_no": cs["student_no"],
                        "term": str(cs["term"]), "year": str(cs["year"])})
    if not student["full_name"]:
        student["full_name"] = person("prefix", "first_name", "last_name")
    info = {
        "gender": gender, "birth_date": g("birth_date"),
        "age": str(age) if age is not None else g("age"),
        "weight": g("weight"), "height": g("height"), "blood_group": g("blood_group"),
        "religion": g("religion"), "race": g("race"), "nationality": g("nationality"),
        "address": address,
        "guardian": {"name": person("guardian_prefix", "guardian_name", "guardian_lastname"),
                     "relation": g("guardian_relation"), "occupation": g("guardian_occupation")},
        "father": {"name": person("father_prefix", "father_name", "father_lastname"), "occupation": g("father_occupation")},
        "mother": {"name": person("mother_prefix", "mother_name", "mother_lastname"), "occupation": g("mother_occupation")},
        "has_dmc": bool(d),
    }
    if include_citizen:
        info["citizen_id"] = g("citizen_id")
    return {"student": student, "info": info,
            "photo": {"exists": photo_path(sid) is not None, "version": photo_version(sid)}}


def coverage(scope: Dict[str, Any], term: str, year: str, db_path: str = "school_archive.db") -> Dict[str, Any]:
    """How many students of the semester (that this user may upload for) have a photo, and who is missing."""
    known = _students(term, year, db_path)
    mine = [s for s in known.values() if s["_this_sem"] and s["_active"] and _allowed(scope, s)]
    have = {p.stem for p in PHOTO_DIR.glob("*.jpg")} if PHOTO_DIR.is_dir() else set()
    missing = [s for s in mine if s["student_id"] not in have]

    def order(x):
        no = x.get("student_no")
        return (x["class_level"], x["room"], int(no) if str(no or "").isdigit() else 9999, x["student_id"])
    missing.sort(key=order)
    return {"total": len(mine), "with_photo": len(mine) - len(missing),
            "missing": [{k: s[k] for k in ("student_id", "full_name", "class_level", "room", "student_no")}
                        for s in missing[:LIST_LIMIT]]}


# ---------------------------------------------------------------- stage -> commit

def _source_head(src: Source, n: int = 4) -> bytes:
    if isinstance(src, (bytes, bytearray)):
        return bytes(src[:n])
    src.seek(0)
    head = src.read(n)
    src.seek(0)
    return head


def _source_size(src: Source) -> int:
    if isinstance(src, (bytes, bytearray)):
        return len(src)
    src.seek(0, os.SEEK_END)
    size = src.tell()
    src.seek(0)
    return size


def _iter_photos(files: Iterable[Tuple[str, Source]]) -> Iterable[Tuple[str, Optional[bytes], str]]:
    """(display name, bytes or None, reason when skipped) for every photo, ZIPs opened.
    Only one photo is in memory at a time when the sources are files."""
    for name, data in files:
        name = name or "ไม่มีชื่อ"
        in_memory = isinstance(data, (bytes, bytearray))
        if name.lower().endswith(".zip") or _source_head(data) == b"PK\x03\x04":
            try:
                zf = zipfile.ZipFile(io.BytesIO(data) if in_memory else data)
            except Exception:
                yield name, None, "เปิดไฟล์ ZIP ไม่ได้"
                continue
            entries = [i for i in zf.infolist() if not i.is_dir()]
            entries = [i for i in entries
                       if not (i.filename.startswith("__MACOSX/") or re.split(r"[\\/]", i.filename)[-1].startswith("."))]
            if len(entries) > MAX_ZIP_ENTRIES:
                yield name, None, f"ZIP มีไฟล์เกิน {MAX_ZIP_ENTRIES} ไฟล์ กรุณาแบ่งเป็นหลายไฟล์"
                continue
            if sum(i.file_size for i in entries) > MAX_ZIP_TOTAL:
                yield name, None, "ZIP ใหญ่เกิน 3 GB เมื่อแตกไฟล์ กรุณาแบ่งเป็นหลายไฟล์"
                continue
            for info in entries:
                inner = f"{name} › {info.filename}"
                if Path(info.filename).suffix.lower() not in IMAGE_EXT:
                    yield inner, None, "ไม่ใช่ไฟล์รูป"
                    continue
                if info.file_size > MAX_FILE_BYTES:
                    yield inner, None, "ไฟล์ใหญ่เกิน 40 MB"
                    continue
                try:
                    yield inner, zf.read(info), ""
                except Exception:
                    yield inner, None, "อ่านไฟล์ใน ZIP ไม่ได้"
            continue
        if Path(name).suffix.lower() not in IMAGE_EXT:
            yield name, None, "ไม่ใช่ไฟล์รูป"
            continue
        if in_memory:
            yield name, data, ""
        elif _source_size(data) > MAX_FILE_BYTES:      # same limit as normalize(), checked before reading
            yield name, None, "ไฟล์ใหญ่เกิน 40 MB"
        else:
            yield name, data.read(), ""


def _stage_dir(token: str) -> Path:
    if not _TOKEN_RE.fullmatch(str(token or "")):
        raise ValueError("รหัสชุดรูปไม่ถูกต้อง")
    return STAGE_DIR / token


def _load(token: str, user: Dict[str, Any]) -> Tuple[Path, Dict[str, Any]]:
    d = _stage_dir(token)
    try:
        man = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    except Exception:
        raise ValueError("ไม่พบชุดรูปนี้ (อาจหมดเวลาแล้ว) กรุณาเลือกไฟล์ใหม่")
    if man.get("owner") != user.get("code"):
        raise PermissionError("ชุดรูปนี้เป็นของผู้ใช้คนอื่น")
    return d, man


def _save(d: Path, man: Dict[str, Any]) -> None:
    tmp = d / "manifest.json.tmp"
    tmp.write_text(json.dumps(man, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, d / "manifest.json")


def cleanup_stale(now: Optional[float] = None) -> int:
    now = now or time.time()
    gone = 0
    if STAGE_DIR.is_dir():
        for d in STAGE_DIR.iterdir():
            try:
                if d.is_dir() and now - d.stat().st_mtime > STAGE_TTL_SECONDS:
                    shutil.rmtree(d, ignore_errors=True)
                    gone += 1
            except OSError:
                pass
    return gone


def stage(files: List[Tuple[str, Source]], user: Dict[str, Any], term: str, year: str,
          token: Optional[str] = None, db_path: str = "school_archive.db") -> Dict[str, Any]:
    """Normalise + match the files (name, bytes or open file) and park them. Send big batches in several
    calls with the same token: the summary covers everything staged so far. A later file for the same
    student wins."""
    scope = upload_scope(user, term, year, db_path)
    if not scope["all"] and not scope["levels"]:
        raise PermissionError(f"อัปโหลดรูปได้เฉพาะครูประจำชั้น (ครูที่ปรึกษา) ของภาคเรียน {term}/{year} หรือผู้ดูแลระบบ")
    cleanup_stale()
    if token:
        d, man = _load(token, user)
        if (man.get("term"), man.get("year")) != (str(term), str(year)):
            raise ValueError("ภาคเรียนไม่ตรงกับชุดรูปที่เริ่มไว้")
    else:
        token = secrets.token_hex(16)
        d = _stage_dir(token)
        d.mkdir(parents=True, exist_ok=True)
        man = {"owner": user.get("code"), "term": str(term), "year": str(year), "created": time.time(),
               "matched": {}, "unmatched": [], "not_allowed": [], "replaced_in_batch": []}
    known = _students(term, year, db_path)
    for name, data, reason in _iter_photos(files):
        if data is None:
            man["unmatched"].append({"file": name, "reason": reason})
            continue
        sid, why = match_name(name, known)
        if not sid:
            man["unmatched"].append({"file": name, "reason": why})
            continue
        st = known[sid]
        if not _allowed(scope, st):
            man["not_allowed"].append({"file": name, "student_id": sid, "full_name": st["full_name"],
                                       "class_level": st["class_level"], "room": st["room"],
                                       "reason": "ไม่ใช่นักเรียนในชั้นที่ท่านเป็นครูประจำชั้น"})
            continue
        try:
            jpg = normalize(data)
        except ValueError as e:
            man["unmatched"].append({"file": name, "reason": str(e)})
            continue
        if sid in man["matched"]:
            man["replaced_in_batch"].append({"file": man["matched"][sid]["file"], "student_id": sid,
                                             "reason": f"มีไฟล์ของรหัส {sid} มากกว่า 1 ไฟล์ ใช้ไฟล์ {name} แทน"})
        (d / f"{sid}.jpg").write_bytes(jpg)
        man["matched"][sid] = {"file": name, "bytes": len(jpg)}
    _save(d, man)
    return summary(token, man, known)


def summary(token: str, man: Dict[str, Any], known: Dict[str, Any]) -> Dict[str, Any]:
    matched = []
    for sid, m in man["matched"].items():
        st = known.get(sid, {})
        matched.append({"student_id": sid, "file": m["file"], "full_name": st.get("full_name", ""),
                        "class_level": st.get("class_level", ""), "room": st.get("room", ""),
                        "student_no": st.get("student_no"), "has_photo": photo_path(sid) is not None})

    def order(x):
        no = x.get("student_no")
        return (x["class_level"], x["room"], int(no) if str(no or "").isdigit() else 9999, x["student_id"])
    matched.sort(key=order)
    return {
        "token": token, "term": man["term"], "year": man["year"],
        "counts": {"matched": len(matched), "replace": sum(1 for m in matched if m["has_photo"]),
                   "new": sum(1 for m in matched if not m["has_photo"]),
                   "unmatched": len(man["unmatched"]), "not_allowed": len(man["not_allowed"]),
                   "duplicates": len(man["replaced_in_batch"])},
        "matched": matched[:LIST_LIMIT],
        "unmatched": man["unmatched"][:LIST_LIMIT],
        "not_allowed": man["not_allowed"][:LIST_LIMIT],
        "duplicates": man["replaced_in_batch"][:LIST_LIMIT],
    }


def staged_photo(token: str, student_id: str, user: Dict[str, Any]) -> Path:
    d, man = _load(token, user)
    if student_id not in man["matched"] or not valid_sid(student_id):
        raise FileNotFoundError(student_id)
    return d / f"{student_id}.jpg"


def commit(token: str, user: Dict[str, Any], db_path: str = "school_archive.db") -> Dict[str, Any]:
    d, man = _load(token, user)
    # the teacher's rights are checked again: an advisor may have been changed meanwhile
    scope = upload_scope(user, man["term"], man["year"], db_path)
    known = _students(man["term"], man["year"], db_path)
    PHOTO_DIR.mkdir(parents=True, exist_ok=True)
    added = replaced = 0
    for sid in list(man["matched"]):
        st = known.get(sid)
        src = d / f"{sid}.jpg"
        if not st or not _allowed(scope, st) or not src.is_file():
            continue
        existed = (PHOTO_DIR / f"{sid}.jpg").is_file()
        os.replace(src, PHOTO_DIR / f"{sid}.jpg")
        replaced += existed
        added += not existed
    shutil.rmtree(d, ignore_errors=True)
    total = added + replaced
    msg = f"บันทึกรูปนักเรียน {total} คน" + (f" (ใหม่ {added} • แทนรูปเดิม {replaced})" if replaced else "")
    return {"saved": total, "added": added, "replaced": replaced, "message": msg}


def cancel(token: str, user: Dict[str, Any]) -> bool:
    d, _ = _load(token, user)
    shutil.rmtree(d, ignore_errors=True)
    return True
