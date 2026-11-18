"""
ตารางลงเวลาครู (teacher attendance grid), asked for by the owner on 2026-11-18.

It uses the same calendar as the students' daily grid: the semester's 100 day-slots (20 weeks x Mon-Fri,
from database.get_semester_start_date), minus holidays. A day is a holiday for teachers only when every class
level has it as a holiday (daily_attendance_config.holidays_json). Activity days are ordinary school days.

From 06:00 on the server's clock, every teacher counts as มา (/) for the day unless something else is recorded:
  ล   ลากิจ / ลาป่วย   teacher_leaves (the existing leave form), may span several days
  ขส  ขอเข้าสาย          teacher_leaves (the existing leave form), one day
  ร   ไปราชการ           teacher_attendance_marks, no details
  ส   มาสาย              teacher_attendance_marks, no details, only for today or earlier
When a day has more than one record, the first match wins: ล, then ขส, then ร, then ส, then /.
Rejected or cancelled leave records are ignored. Nothing is stored for "/": it is worked out on every read,
so no job has to run at 06:00.

Summary (owner's choice): มา = every school day so far that is not ล, so ส, ขส and ร also count as มา (as a
late student still counts as present); each is also counted on its own.

Who sees what (owner's choice): admin, the personnel head and the director see every teacher (the director
only reads); any other teacher sees only their own row and asks for ขส / ล through the leave form. ส and ร
are entered by the personnel head or an admin. The director has no row.
"""
import json
import sqlite3
from datetime import date, datetime, time
from typing import Any, Dict, List, Optional

import database
import leave_manager

DB = "school_archive.db"
DAY_STARTS = time(6, 0)              # every teacher is "มา" from this time on a school day
MARKS = ("ส", "ร")
LEAVE_SYMBOL = {"ลากิจ": "ล", "ลาป่วย": "ล", "ขอเข้าสาย": "ขส"}
IGNORED_LEAVE_STATUS = ("rejected", "cancelled")

SCHEMA = """
CREATE TABLE IF NOT EXISTS teacher_attendance_marks (
    teacher_code TEXT NOT NULL,
    date TEXT NOT NULL,              -- YYYY-MM-DD
    status TEXT NOT NULL,            -- 'ส' มาสาย, 'ร' ไปราชการ
    updated_by TEXT,
    updated_at TEXT,
    PRIMARY KEY (teacher_code, date)
);
"""


def ensure(conn) -> None:
    """Both tables this page reads (the leave table may not exist yet on a new school). One statement at a
    time, because executescript would commit the caller's open transaction (school_data import)."""
    for stmt in (leave_manager.SCHEMA + SCHEMA).split(";"):
        stmt = " ".join(ln.split("--")[0] for ln in stmt.splitlines()).strip()
        if stmt:
            conn.execute(stmt)


def _connect(db_path: str):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def _now(now: Optional[datetime]) -> datetime:
    return now or datetime.now()


def semester_calendar(term: str, year: str, db_path: str = DB) -> Dict[str, Any]:
    """The 100 day-slots of the semester and which of them are holidays for every class level."""
    t, y = str(term).strip(), str(year).strip()
    start = database.get_semester_start_date(t, y, db_path=db_path)
    dates = database.compute_100_dates(start, t, y)
    with _connect(db_path) as conn:
        rows = conn.execute("SELECT holidays_json FROM daily_attendance_config WHERE term = ? AND year = ?;", (t, y)).fetchall()
    common = None
    for r in rows:
        try:
            got = {int(i) for i in json.loads(r["holidays_json"] or "[]")}
        except Exception:
            got = set()
        common = got if common is None else common & got
    holidays = sorted(i for i in (common or set()) if 0 <= i < len(dates))
    return {"term": t, "year": y, "start_date": start, "dates": dates, "holidays": holidays}


def teacher_rows(db_path: str = DB) -> List[Dict[str, str]]:
    """Teachers on the grid: every teacher with a code, except the director."""
    with _connect(db_path) as conn:
        rows = conn.execute("SELECT code, name FROM school_teachers WHERE code IS NOT NULL AND TRIM(code) != '' ORDER BY id;").fetchall()
    out = []
    for r in rows:
        code, name = str(r["code"]).strip(), str(r["name"] or "").strip()
        if database.is_school_director(code, name, db_path):
            continue
        out.append({"code": code, "name": name})
    return out


def _counts_today(d: str, now: datetime) -> bool:
    """A day is counted once it has started: earlier days, or today from 06:00."""
    today = now.date().isoformat()
    return d < today or (d == today and now.time() >= DAY_STARTS)


def build_grid(term: str, year: str, only_code: Optional[str] = None, now: Optional[datetime] = None,
               db_path: str = DB) -> Dict[str, Any]:
    """Status of every teacher on every day-slot, plus each teacher's summary up to now.
    only_code: a teacher who may see only their own row."""
    now = _now(now)
    cal = semester_calendar(term, year, db_path)
    dates, holidays = cal["dates"], set(cal["holidays"])
    first, last = dates[0], dates[-1]
    teachers = teacher_rows(db_path)
    if only_code is not None:
        teachers = [t for t in teachers if t["code"] == str(only_code).strip()]
    codes = {t["code"] for t in teachers}

    with _connect(db_path) as conn:
        ensure(conn)
        leaves = conn.execute(
            "SELECT * FROM teacher_leaves WHERE COALESCE(status, 'pending') NOT IN (?, ?) "
            "AND start_date <= ? AND COALESCE(NULLIF(end_date, ''), start_date) >= ? ORDER BY start_date, id;",
            (*IGNORED_LEAVE_STATUS, last, first)).fetchall()
        marks = conn.execute("SELECT teacher_code, date, status FROM teacher_attendance_marks WHERE date BETWEEN ? AND ?;",
                             (first, last)).fetchall()

    slot_of = {d: i for i, d in enumerate(dates)}
    # leave records per teacher per slot: ล beats ขส when both cover the same day
    leave_at: Dict[str, Dict[int, Dict[str, Any]]] = {}
    for r in leaves:
        code = str(r["teacher_code"]).strip()
        sym = LEAVE_SYMBOL.get(str(r["leave_type"]).strip())
        if code not in codes or not sym:
            continue
        start = str(r["start_date"]).strip()[:10]
        end = (str(r["end_date"] or "").strip()[:10] or start) if sym == "ล" else start
        for d in dates:
            if start <= d <= end:
                i = slot_of[d]
                have = leave_at.setdefault(code, {}).get(i)
                if have and have["symbol"] == "ล":
                    continue
                leave_at[code][i] = {"symbol": sym, "leave_id": r["id"], "leave_type": r["leave_type"],
                                     "approval": r["status"] or "pending", "time": r["expected_arrival_time"] or "",
                                     "start_date": start, "end_date": end}
    mark_at: Dict[str, Dict[int, str]] = {}
    for r in marks:
        code, d = str(r["teacher_code"]).strip(), str(r["date"])
        if code in codes and d in slot_of and r["status"] in MARKS:
            mark_at.setdefault(code, {})[slot_of[d]] = r["status"]

    counted = [i not in holidays and _counts_today(d, now) for i, d in enumerate(dates)]
    elapsed = sum(counted)
    out_rows = []
    for t in teachers:
        code = t["code"]
        status, info = [], []
        n = {"/": 0, "ส": 0, "ขส": 0, "ล": 0, "ร": 0}
        kij = puay = 0
        for i, d in enumerate(dates):
            if i in holidays:
                status.append("")
                info.append(None)
                continue
            lv = leave_at.get(code, {}).get(i)
            mk = mark_at.get(code, {}).get(i)
            if lv:
                s = lv["symbol"]
            elif mk == "ร":
                s = "ร"
            elif mk == "ส" and counted[i]:
                s = "ส"
            else:
                s = "/" if counted[i] else ""
            status.append(s)
            info.append({k: v for k, v in lv.items() if k != "symbol"} if lv else None)
            if counted[i] and s:
                n[s] += 1
                if s == "ล":
                    kij += lv["leave_type"] == "ลากิจ"
                    puay += lv["leave_type"] == "ลาป่วย"
        out_rows.append({
            "teacher_code": code, "teacher_name": t["name"], "status_list": status, "info": info,
            "summary": {"school_days": elapsed, "present": elapsed - n["ล"], "on_time": n["/"], "late": n["ส"],
                        "late_request": n["ขส"], "leave": n["ล"], "leave_kij": kij, "leave_puay": puay, "official": n["ร"]},
        })
    today = now.date().isoformat()
    return {**cal, "today": today, "today_slot": slot_of.get(today), "day_started": now.time() >= DAY_STARTS,
            "day_starts": DAY_STARTS.strftime("%H:%M"), "school_days": elapsed, "teachers": out_rows}


def set_mark(term: str, year: str, teacher_code: str, day: str, status: str, by: str,
             now: Optional[datetime] = None, db_path: str = DB) -> Dict[str, Any]:
    """Set ส (late) or ร (official duty) on one school day; status "" or "/" puts the day back to มา.
    Raises ValueError with a Thai message the page can show."""
    now = _now(now)
    code = str(teacher_code or "").strip()
    st = str(status or "").strip()
    st = "" if st == "/" else st
    if st and st not in MARKS:
        raise ValueError("สถานะต้องเป็น ส (มาสาย) หรือ ร (ไปราชการ)")
    try:
        d = date.fromisoformat(str(day).strip()[:10]).isoformat()
    except ValueError:
        raise ValueError("วันที่ไม่ถูกต้อง")
    if date.fromisoformat(d).weekday() >= 5:
        raise ValueError("วันเสาร์-อาทิตย์ไม่ใช่วันเรียน")
    cal = semester_calendar(term, year, db_path)
    if d not in cal["dates"]:
        raise ValueError("วันนี้ไม่อยู่ในภาคเรียนที่เลือก")
    if cal["dates"].index(d) in set(cal["holidays"]):
        raise ValueError("วันนี้เป็นวันหยุด")
    if not any(t["code"] == code for t in teacher_rows(db_path)):
        raise ValueError("ไม่พบครูรหัสนี้ในตารางลงเวลา")
    if st == "ส" and d > now.date().isoformat():
        raise ValueError("ยังไม่ถึงวันนี้ ลง ส (มาสาย) ล่วงหน้าไม่ได้")
    with _connect(db_path) as conn:
        ensure(conn)
        if st:
            lv = conn.execute(
                "SELECT leave_type FROM teacher_leaves WHERE teacher_code = ? AND COALESCE(status, 'pending') NOT IN (?, ?) "
                "AND start_date <= ? AND (CASE WHEN leave_type = 'ขอเข้าสาย' THEN start_date "
                "ELSE COALESCE(NULLIF(end_date, ''), start_date) END) >= ? LIMIT 1;",
                (code, *IGNORED_LEAVE_STATUS, d, d)).fetchone()
            if lv:
                raise ValueError(f"วันนี้มีรายการ{lv['leave_type']}อยู่แล้ว แก้ไขหรือลบรายการนั้นก่อน")
            conn.execute(
                "INSERT INTO teacher_attendance_marks (teacher_code, date, status, updated_by, updated_at) VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT(teacher_code, date) DO UPDATE SET status = excluded.status, updated_by = excluded.updated_by, "
                "updated_at = excluded.updated_at;",
                (code, d, st, by, now.strftime("%Y-%m-%d %H:%M:%S")))
        else:
            conn.execute("DELETE FROM teacher_attendance_marks WHERE teacher_code = ? AND date = ?;", (code, d))
        conn.commit()
    return {"teacher_code": code, "date": d, "status": st or "/"}


def marks_between(teacher_code: str, start: str, end: Optional[str], db_path: str = DB) -> List[Dict[str, str]]:
    """ส / ร already entered for this teacher between two dates (inclusive)."""
    s = str(start or "").strip()[:10]
    e = str(end or "").strip()[:10] or s
    with _connect(db_path) as conn:
        ensure(conn)
        rows = conn.execute("SELECT date, status FROM teacher_attendance_marks WHERE teacher_code = ? AND date BETWEEN ? AND ? "
                            "ORDER BY date;", (str(teacher_code).strip(), s, e)).fetchall()
    return [{"date": r["date"], "status": r["status"]} for r in rows]


def clear_marks(teacher_code: str, start: str, end: Optional[str], db_path: str = DB) -> int:
    """A leave entered by the personnel head / an admin replaces any ส / ร on its days."""
    s = str(start or "").strip()[:10]
    e = str(end or "").strip()[:10] or s
    with _connect(db_path) as conn:
        ensure(conn)
        cur = conn.execute("DELETE FROM teacher_attendance_marks WHERE teacher_code = ? AND date BETWEEN ? AND ?;",
                           (str(teacher_code).strip(), s, e))
        conn.commit()
        return cur.rowcount
