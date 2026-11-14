"""
ตารางสอบกลางภาค / ปลายภาค (the school's exam timetable form: days x time slots x ม.1–ม.6).

The admin uploads the form (image or PDF). A PDF made from Word/Excel is read automatically; a photo or scan
is kept as the original next to an editable grid. Saving the grid gives every course in it its own exam time
(exams.exam_course_times, source = 'timetable'), so its button unlocks for students at that time.
"""
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import database
import exams

LEVELS = ["ม.1", "ม.2", "ม.3", "ม.4", "ม.5", "ม.6"]
FILES_DIR = Path(__file__).resolve().parent / "data" / "exam_timetables"
ALLOWED = {".pdf": "application/pdf", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}
THAI_MONTHS = ["ม.ค.", "ก.พ.", "มี.ค.", "เม.ย.", "พ.ค.", "มิ.ย.", "ก.ค.", "ส.ค.", "ก.ย.", "ต.ค.", "พ.ย.", "ธ.ค."]
_CODE = re.compile(r"[ก-ฮA-Z]\s?\d{5}")
# fonts map the dash between the times to many characters (soft hyphen in Tahoma PDFs)
_TIME = re.compile(r"(\d{1,2})[.:](\d{2})\s*(?:[-–—‐‑­~]|ถึง)\s*(\d{1,2})[.:](\d{2})")

_ready = 0  # database.INIT_EPOCH + 1 once checked


def _conn(db_path: str):
    global _ready
    conn = exams._conn(db_path)
    if _ready != database.INIT_EPOCH[0] + 1:
        conn.execute(
            """CREATE TABLE IF NOT EXISTS exam_timetables (
                   term TEXT NOT NULL, year TEXT NOT NULL, exam_type TEXT NOT NULL,
                   days_json TEXT NOT NULL DEFAULT '[]',
                   file_name TEXT, file_path TEXT, uploaded_at TEXT, updated_by TEXT, updated_at TEXT,
                   PRIMARY KEY (term, year, exam_type)
               );""")
        _ready = database.INIT_EPOCH[0] + 1
    return conn


# ---------------------------------------------------------------- the grid

def _hm(s: Any) -> Optional[str]:
    m = re.fullmatch(r"\s*(\d{1,2})[.:](\d{2})\s*", str(s or ""))
    if not m or int(m.group(1)) > 23 or int(m.group(2)) > 59:
        return None
    return f"{int(m.group(1)):02d}:{m.group(2)}"


def clean_days(raw: Any) -> List[Dict[str, Any]]:
    """[{date, slots: [{start, end, kind: exam|break, label, cells: {ม.1: code}}]}] sorted, validated."""
    days = []
    for d in raw or []:
        date = str((d or {}).get("date") or "").strip()
        try:
            datetime.strptime(date, "%Y-%m-%d")
        except ValueError:
            raise ValueError(f"วันที่ไม่ถูกต้อง: {date or '(ว่าง)'}")
        slots = []
        for s in d.get("slots") or []:
            start, end = _hm(s.get("start")), _hm(s.get("end"))
            if not start or not end or end <= start:
                raise ValueError(f"ช่วงเวลาไม่ถูกต้อง ({date} {s.get('start')}-{s.get('end')})")
            kind = "break" if s.get("kind") == "break" else "exam"
            cells = {}
            if kind == "exam":
                for lv in LEVELS:
                    code = re.sub(r"\s", "", str((s.get("cells") or {}).get(lv) or ""))
                    if code:
                        cells[lv] = code
            slots.append({"start": start, "end": end, "kind": kind,
                          "label": str(s.get("label") or "").strip() if kind == "break" else "", "cells": cells})
        slots.sort(key=lambda x: x["start"])
        for a, b in zip(slots, slots[1:]):
            if b["start"] < a["end"]:
                raise ValueError(f"ช่วงเวลาซ้อนกัน ({date} {a['start']}-{a['end']} กับ {b['start']}-{b['end']})")
        days.append({"date": date, "slots": slots})
    days.sort(key=lambda x: x["date"])
    seen = {}
    for d in days:
        for s in d["slots"]:
            for code in s["cells"].values():
                if code in seen:
                    raise ValueError(f"{code} อยู่ในตารางสอบ 2 ช่อง ({seen[code]} และ {d['date']} {s['start']})")
                seen[code] = f"{d['date']} {s['start']}"
    return days


def get_timetable(term: str, year: str, exam_type: str, db_path: str = exams.DB_PATH) -> Dict[str, Any]:
    """The grid, each exam cell enriched with the course name, teacher and whether it is open now."""
    with _conn(db_path) as conn:
        r = conn.execute("SELECT * FROM exam_timetables WHERE term = ? AND year = ? AND exam_type = ?;",
                         (str(term), str(year), exam_type)).fetchone()
        courses = {c["course_code"]: dict(c) for c in conn.execute(
            "SELECT course_code, course_name, teacher, class_level FROM courses WHERE term = ? AND year = ?;", (str(term), str(year)))}
        has_exam = {(e[0]) for e in conn.execute(
            "SELECT course_code FROM exams WHERE term = ? AND year = ? AND exam_type = ? AND ready = 1;", (str(term), str(year), exam_type))}
    days = json.loads(r["days_json"]) if r else []
    windows, times = exams.get_windows(term, year, db_path), exams.course_times(term, year, db_path)
    locks = exams.locked_slots(term, year, db_path)
    for d in days:
        for s in d["slots"]:
            info = {}
            for lv, code in s.get("cells", {}).items():
                c = courses.get(code) or {}
                sw = exams.slot_window(windows, times, code, exam_type)
                info[lv] = {"course_code": code, "course_name": c.get("course_name"), "teacher": c.get("teacher"),
                            "known": bool(c), "has_exam": code in has_exam, "locked": (code, exam_type) in locks,
                            "is_open": sw["is_open"], "has_ended": sw["has_ended"], "opened_early": sw["opened_early"]}
            s["info"] = info
    return {"term": str(term), "year": str(year), "exam_type": exam_type, "label": exams.EXAM_TYPES[exam_type],
            "days": days, "file_name": r["file_name"] if r else None, "has_file": bool(r and r["file_path"]),
            "uploaded_at": r["uploaded_at"] if r else None, "updated_by": r["updated_by"] if r else None,
            "updated_at": r["updated_at"] if r else None}


def save_timetable(term: str, year: str, exam_type: str, days: Any, by: str, db_path: str = exams.DB_PATH) -> Dict[str, Any]:
    """Stores the grid and gives each course in it its exam time (replacing the previous timetable's times)."""
    if exam_type not in exams.EXAM_TYPES:
        raise ValueError("ประเภทข้อสอบไม่ถูกต้อง")
    days = clean_days(days)
    with _conn(db_path) as conn:
        known = {r[0] for r in conn.execute("SELECT course_code FROM courses WHERE term = ? AND year = ?;", (str(term), str(year)))}
        unknown = sorted({c for d in days for s in d["slots"] for c in s["cells"].values() if c not in known})
        if unknown:
            raise ValueError(f"ไม่พบรายวิชาในภาคเรียน {term}/{year}: {', '.join(unknown)}")
        now = exams._fmt(exams.now())
        conn.execute(
            """INSERT INTO exam_timetables (term, year, exam_type, days_json, updated_by, updated_at) VALUES (?, ?, ?, ?, ?, ?)
               ON CONFLICT(term, year, exam_type) DO UPDATE SET days_json = excluded.days_json,
                 updated_by = excluded.updated_by, updated_at = excluded.updated_at;""",
            (str(term), str(year), exam_type, json.dumps(days, ensure_ascii=False), by, now))
        # times that came from the previous timetable go; the new ones replace them
        conn.execute("""UPDATE exam_course_times SET start_at = NULL, end_at = NULL, source = NULL
                        WHERE term = ? AND year = ? AND exam_type = ? AND source = 'timetable';""", (str(term), str(year), exam_type))
        for d in days:
            for s in d["slots"]:
                for code in s["cells"].values():
                    conn.execute(
                        """INSERT INTO exam_course_times (course_code, term, year, exam_type, start_at, end_at, source)
                           VALUES (?, ?, ?, ?, ?, ?, 'timetable')
                           ON CONFLICT(course_code, term, year, exam_type) DO UPDATE SET
                             start_at = excluded.start_at, end_at = excluded.end_at, source = 'timetable';""",
                        (code, str(term), str(year), exam_type, f"{d['date']}T{s['start']}:00", f"{d['date']}T{s['end']}:00"))
    return get_timetable(term, year, exam_type, db_path)


# ---------------------------------------------------------------- the uploaded form

def file_path_for(term: str, year: str, exam_type: str, db_path: str = exams.DB_PATH) -> Optional[Path]:
    with _conn(db_path) as conn:
        r = conn.execute("SELECT file_path FROM exam_timetables WHERE term = ? AND year = ? AND exam_type = ?;",
                         (str(term), str(year), exam_type)).fetchone()
    p = Path(r["file_path"]) if r and r["file_path"] else None
    return p if p and p.exists() else None


def store_upload(term: str, year: str, exam_type: str, file_name: str, data: bytes, by: str,
                 db_path: str = exams.DB_PATH) -> Dict[str, Any]:
    """Keeps the original form and, for a PDF with text, reads the grid from it (a draft for the admin to check)."""
    if exam_type not in exams.EXAM_TYPES:
        raise ValueError("ประเภทข้อสอบไม่ถูกต้อง")
    ext = Path(file_name or "").suffix.lower()
    if ext not in ALLOWED:
        raise ValueError("รองรับไฟล์ PDF, JPG, PNG หรือ WEBP")
    if len(data) > 15 * 1024 * 1024:
        raise ValueError("ไฟล์ใหญ่เกิน 15 MB")
    FILES_DIR.mkdir(parents=True, exist_ok=True)
    for old in FILES_DIR.glob(f"{year}-{term}-{exam_type}.*"):
        old.unlink()
    path = FILES_DIR / f"{year}-{term}-{exam_type}{ext}"
    path.write_bytes(data)
    with _conn(db_path) as conn:
        conn.execute(
            """INSERT INTO exam_timetables (term, year, exam_type, file_name, file_path, uploaded_at, updated_by) VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(term, year, exam_type) DO UPDATE SET file_name = excluded.file_name, file_path = excluded.file_path,
                 uploaded_at = excluded.uploaded_at;""",
            (str(term), str(year), exam_type, file_name, str(path), exams._fmt(exams.now()), by))
    draft, note = [], ""
    if ext == ".pdf":
        try:
            draft = parse_pdf(path, year)
        except Exception as e:
            note = f"อ่านตารางจาก PDF ไม่ได้ ({e})"
        if not draft and not note:
            note = "PDF นี้ไม่มีข้อความให้อ่าน (เป็นภาพสแกน) กรุณากรอกตารางจากภาพต้นฉบับ"
    else:
        note = "ไฟล์ภาพ: ระบบอ่านตัวหนังสือในภาพเองไม่ได้ กรุณากรอกตารางโดยดูจากภาพต้นฉบับ (เลือกรายวิชาจากรายการ)"
    return {"draft_days": draft, "note": note, "file_name": file_name}


def _thai_date(text: str, year_be: str) -> Optional[str]:
    t = re.sub(r"\s+", " ", text or "")
    for i, mon in enumerate(THAI_MONTHS):
        m = re.search(r"(\d{1,2})\s*" + re.escape(mon) + r"\s*(\d{2,4})?", t)
        if m:
            y = m.group(2)
            be = int(y) + 2500 if y and len(y) == 2 else int(y) if y else int(year_be)
            return f"{be - 543:04d}-{i + 1:02d}-{int(m.group(1)):02d}"
    return None


def parse_pdf(path: Path, year_be: str) -> List[Dict[str, Any]]:
    """Reads the form's tables: a header row with ม.1–ม.6, a date cell, time ranges, course codes or a break."""
    import pdfplumber
    days: List[Dict[str, Any]] = []
    with pdfplumber.open(str(path)) as pdf:
        for page in pdf.pages:
            for table in page.extract_tables():
                cols: Dict[int, str] = {}
                day = None
                for row in table:
                    cells = [re.sub(r"\s+", " ", str(c or "")).strip() for c in row]
                    header = {i: c.replace(" ", "") for i, c in enumerate(cells) if c.replace(" ", "") in LEVELS}
                    if len(header) >= 3:
                        cols = header
                        continue
                    if not cols:
                        continue
                    for c in cells:
                        dt = _thai_date(c, year_be)
                        if dt:
                            if day is None or day["date"] != dt:
                                day = next((d for d in days if d["date"] == dt), None)
                                if day is None:
                                    day = {"date": dt, "slots": []}
                                    days.append(day)
                            break
                    tm = next((m for m in (_TIME.search(c) for c in cells) if m), None)
                    if not tm or day is None:
                        continue
                    start, end = f"{int(tm.group(1)):02d}:{tm.group(2)}", f"{int(tm.group(3)):02d}:{tm.group(4)}"
                    found = {lv: _CODE.search(cells[i]) for i, lv in cols.items() if i < len(cells)}
                    found = {lv: m.group(0).replace(" ", "") for lv, m in found.items() if m}
                    if found:
                        day["slots"].append({"start": start, "end": end, "kind": "exam", "label": "", "cells": found})
                    else:
                        label = next((c for c in cells if "พัก" in c), "")
                        day["slots"].append({"start": start, "end": end, "kind": "break", "label": label, "cells": {}})
    return clean_days(days) if days else []
