import sqlite3
import school_profile
from typing import List, Dict, Any, Optional
from datetime import datetime

SCHEMA = """
CREATE TABLE IF NOT EXISTS teacher_leaves (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    teacher_code TEXT NOT NULL,
    teacher_name TEXT NOT NULL,
    leave_type TEXT NOT NULL, -- 'ลากิจ', 'ลาป่วย', 'ขอเข้าสาย'
    start_date TEXT NOT NULL,
    end_date TEXT,
    expected_arrival_time TEXT,
    reason TEXT,
    contact_phone TEXT,
    status TEXT DEFAULT 'pending', -- 'pending', 'approved', 'rejected', 'cancelled'
    approved_by TEXT,
    approved_at TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_teacher_leaves_code ON teacher_leaves(teacher_code);
CREATE INDEX IF NOT EXISTS idx_teacher_leaves_date ON teacher_leaves(start_date);
"""

def get_db_connection(db_path: str = "school_archive.db"):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn

def ensure_leave_schema(db_path: str = "school_archive.db") -> None:
    with get_db_connection(db_path) as conn:
        conn.executescript(SCHEMA)

def calc_days(start_date: str, end_date: Optional[str]) -> int:
    try:
        s = datetime.strptime(start_date.strip(), "%Y-%m-%d").date()
        e = datetime.strptime(end_date.strip(), "%Y-%m-%d").date() if end_date and end_date.strip() else s
        if e < s:
            return 1
        return (e - s).days + 1
    except Exception:
        return 1

def _decorate_leave_dict(d: Dict[str, Any]) -> Dict[str, Any]:
    l_type = d.get("leave_type", "")
    start_d = d.get("start_date", "")
    end_d = d.get("end_date") or start_d
    d["times_count"] = 1
    if l_type == "ขอเข้าสาย":
        d["days_count"] = 0
    else:
        d["days_count"] = calc_days(start_d, end_d)
    d["late_time"] = d.get("expected_arrival_time") or d.get("late_time") or ""
    d["phone"] = d.get("contact_phone") or d.get("phone") or ""
    return d

def create_leave_record(
    teacher_code: str,
    teacher_name: str,
    leave_type: str,
    start_date: str,
    end_date: Optional[str] = None,
    expected_arrival_time: Optional[str] = None,
    reason: Optional[str] = None,
    contact_phone: Optional[str] = None,
    db_path: str = "school_archive.db"
) -> Dict[str, Any]:
    ensure_leave_schema(db_path)
    clean_type = leave_type.strip()
    valid_types = {"ลากิจ", "ลาป่วย", "ขอเข้าสาย"}
    if clean_type not in valid_types:
        raise ValueError(f"ประเภทการลาไม่ถูกต้อง: {clean_type} (ต้องเป็น ลากิจ, ลาป่วย หรือ ขอเข้าสาย)")
    
    end_d = end_date.strip() if end_date else start_date
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    with get_db_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """INSERT INTO teacher_leaves 
               (teacher_code, teacher_name, leave_type, start_date, end_date, expected_arrival_time, reason, contact_phone, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (teacher_code.strip(), teacher_name.strip(), clean_type, start_date.strip(), end_d,
             (expected_arrival_time or "").strip(), (reason or "").strip(), (contact_phone or "").strip(), now_str, now_str)
        )
        new_id = cursor.lastrowid
        conn.commit()

    record = {
        "id": new_id,
        "teacher_code": teacher_code,
        "teacher_name": teacher_name,
        "leave_type": clean_type,
        "start_date": start_date,
        "end_date": end_d,
        "expected_arrival_time": expected_arrival_time or "",
        "reason": reason or "",
        "contact_phone": contact_phone or "",
        "status": "pending",
        "created_at": now_str
    }
    return _decorate_leave_dict(record)

def get_leaves_for_teacher(teacher_code: str, db_path: str = "school_archive.db") -> List[Dict[str, Any]]:
    ensure_leave_schema(db_path)
    with get_db_connection(db_path) as conn:
        rows = conn.execute(
            """SELECT * FROM teacher_leaves 
               WHERE teacher_code = ? 
               ORDER BY start_date DESC, id DESC""",
            (teacher_code.strip(),)
        ).fetchall()
        return [_decorate_leave_dict(dict(r)) for r in rows]

def get_all_leaves(
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    leave_type: Optional[str] = None,
    db_path: str = "school_archive.db"
) -> List[Dict[str, Any]]:
    ensure_leave_schema(db_path)
    query = "SELECT * FROM teacher_leaves WHERE 1=1"
    params = []
    if start_date:
        query += " AND end_date >= ?"
        params.append(start_date.strip())
    if end_date:
        query += " AND start_date <= ?"
        params.append(end_date.strip())
    if leave_type:
        query += " AND leave_type = ?"
        params.append(leave_type.strip())
    query += " ORDER BY start_date DESC, id DESC"

    with get_db_connection(db_path) as conn:
        rows = conn.execute(query, params).fetchall()
        return [_decorate_leave_dict(dict(r)) for r in rows]

def get_teacher_leaves_summary(db_path: str = "school_archive.db") -> List[Dict[str, Any]]:
    ensure_leave_schema(db_path)
    with get_db_connection(db_path) as conn:
        teachers = conn.execute(
            "SELECT code, name FROM school_teachers WHERE code IS NOT NULL AND TRIM(code) != '' ORDER BY id"
        ).fetchall()
        leaves = conn.execute("SELECT * FROM teacher_leaves ORDER BY start_date DESC, id DESC").fetchall()

    leaves_by_teacher = {}
    for r in leaves:
        d = _decorate_leave_dict(dict(r))
        code = d["teacher_code"]
        leaves_by_teacher.setdefault(code, []).append(d)

    summary = []
    for t in teachers:
        t_code = str(t["code"]).strip()
        t_name = str(t["name"]).strip()
        t_leaves = leaves_by_teacher.get(t_code, [])

        kij_leaves = [l for l in t_leaves if l["leave_type"] == "ลากิจ"]
        puay_leaves = [l for l in t_leaves if l["leave_type"] == "ลาป่วย"]
        late_leaves = [l for l in t_leaves if l["leave_type"] == "ขอเข้าสาย"]

        total_kij_times = len(kij_leaves)
        total_kij_days = sum(l["days_count"] for l in kij_leaves)

        total_puay_times = len(puay_leaves)
        total_puay_days = sum(l["days_count"] for l in puay_leaves)

        total_late_times = len(late_leaves)
        total_leave_times = total_kij_times + total_puay_times
        total_leave_days = total_kij_days + total_puay_days

        summary.append({
            "teacher_code": t_code,
            "teacher_name": t_name,
            "total_kij_times": total_kij_times,
            "total_kij_days": total_kij_days,
            "total_puay_times": total_puay_times,
            "total_puay_days": total_puay_days,
            "total_late_count": total_late_times,
            "total_late_times": total_late_times,
            "total_leave_times": total_leave_times,
            "total_leave_days": total_leave_days,
            "total_leaves_count": len(t_leaves),
            "leaves": t_leaves
        })

    return summary

def delete_leave_record(
    leave_id: int,
    teacher_code: str,
    is_admin: bool = False,
    db_path: str = "school_archive.db"
) -> bool:
    ensure_leave_schema(db_path)
    with get_db_connection(db_path) as conn:
        clean_code = teacher_code.strip()
        if is_admin or school_profile.is_personnel_head(clean_code):
            cur = conn.execute("DELETE FROM teacher_leaves WHERE id = ?", (leave_id,))
        else:
            cur = conn.execute("DELETE FROM teacher_leaves WHERE id = ? AND teacher_code = ?", (leave_id, clean_code))
        conn.commit()
        return cur.rowcount > 0

def update_leave_record(
    leave_id: int,
    leave_type: Optional[str] = None,
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    expected_arrival_time: Optional[str] = None,
    reason: Optional[str] = None,
    contact_phone: Optional[str] = None,
    db_path: str = "school_archive.db"
) -> Optional[Dict[str, Any]]:
    ensure_leave_schema(db_path)
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with get_db_connection(db_path) as conn:
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT * FROM teacher_leaves WHERE id = ?", (leave_id,)).fetchone()
        if not row:
            return None
        cur_type = leave_type.strip() if leave_type else row["leave_type"]
        cur_start = start_date.strip() if start_date else row["start_date"]
        cur_end = end_date.strip() if end_date else (row["end_date"] or cur_start)
        cur_time = expected_arrival_time.strip() if expected_arrival_time is not None else row["expected_arrival_time"]
        cur_reason = reason.strip() if reason is not None else row["reason"]
        cur_phone = contact_phone.strip() if contact_phone is not None else row["contact_phone"]

        conn.execute(
            """UPDATE teacher_leaves
               SET leave_type = ?, start_date = ?, end_date = ?, expected_arrival_time = ?,
                   reason = ?, contact_phone = ?, updated_at = ?
               WHERE id = ?""",
            (cur_type, cur_start, cur_end, cur_time, cur_reason, cur_phone, now_str, leave_id)
        )
        conn.commit()
        updated_row = conn.execute("SELECT * FROM teacher_leaves WHERE id = ?", (leave_id,)).fetchone()
        return _decorate_leave_dict(dict(updated_row))

def update_leave_status(
    leave_id: int,
    status: str,
    approved_by: str,
    db_path: str = "school_archive.db"
) -> bool:
    ensure_leave_schema(db_path)
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with get_db_connection(db_path) as conn:
        cur = conn.execute(
            """UPDATE teacher_leaves 
               SET status = ?, approved_by = ?, approved_at = ?, updated_at = ?
               WHERE id = ?""",
            (status.strip(), approved_by.strip(), now_str, now_str, leave_id)
        )
        conn.commit()
        return cur.rowcount > 0
