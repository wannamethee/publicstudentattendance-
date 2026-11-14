"""
Timetable & Schedule Manager
Manages teacher timetables, period slots, template import/export,
and cascading late student attendance to subject absences in PorPor5.
"""

import school_profile
import sys
import os
import io
import json
import re
import sqlite3
from typing import Dict, Any, List, Optional, Tuple
from datetime import datetime
from pathlib import Path

try:
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.utils import get_column_letter
except ImportError:
    openpyxl = None

DB_DEFAULT_PATH = "school_archive.db"

# Official Period and Time Slot definitions (Starting directly from Period 1)
PERIOD_CONFIGS = [
    {"period": 1, "name": "คาบ 1", "time_start": "08:30", "time_end": "09:20", "label": "08.30 - 09.20"},
    {"period": 2, "name": "คาบ 2", "time_start": "09:20", "time_end": "10:10", "label": "09.20 - 10.10"},
    {"period": -1, "name": "พักเบรก", "time_start": "10:10", "time_end": "10:20", "label": "พัก 10 นาที", "is_break": True},
    {"period": 3, "name": "คาบ 3", "time_start": "10:20", "time_end": "11:10", "label": "10.20 - 11.10"},
    {"period": 4, "name": "คาบ 4", "time_start": "11:10", "time_end": "12:00", "label": "11.10 - 12.00"},
    {"period": -2, "name": "พักกลางวัน", "time_start": "12:00", "time_end": "13:00", "label": "พักกลางวัน", "is_break": True},
    {"period": 5, "name": "คาบ 5", "time_start": "13:00", "time_end": "13:50", "label": "13.00 - 13.50"},
    {"period": 6, "name": "คาบ 6", "time_start": "13:50", "time_end": "14:40", "label": "13.50 - 14.40"},
    {"period": 7, "name": "คาบ 7", "time_start": "14:40", "time_end": "15:30", "label": "14.40 - 15.30"},
    {"period": 8, "name": "คาบ 8", "time_start": "15:30", "time_end": "16:00", "label": "15.30 - 16.00"},
]

DAY_NAMES = {
    1: "วันจันทร์",
    2: "วันอังคาร",
    3: "วันพุธ",
    4: "วันพฤหัสบดี",
    5: "วันศุกร์"
}

def _teacher_aliases() -> Dict[str, List[str]]:
    b = school_profile.builtin()
    return dict(getattr(b, "TEACHER_ALIASES", {}) if b else {})


def _is_scout_lead(teacher_name: Optional[str]) -> bool:
    """The teacher whose ลูกเสือ slot is the reference one (this school's built-in data; nobody elsewhere)."""
    b = school_profile.builtin()
    lead = getattr(b, "SCOUT_LEAD", "") if b else ""
    return bool(lead) and lead in (teacher_name or "")


def get_connection(db_path: str = DB_DEFAULT_PATH) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path, timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON;")
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA synchronous = NORMAL;")
    return conn


def init_timetable_db(db_path: str = DB_DEFAULT_PATH) -> None:
    """Initialize table schema and seed initial data if needed."""
    schema = """
    CREATE TABLE IF NOT EXISTS teacher_timetables (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        term TEXT NOT NULL,
        year TEXT NOT NULL,
        teacher_name TEXT NOT NULL,
        day_of_week INTEGER NOT NULL,  -- 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri
        period_num INTEGER NOT NULL,   -- 1..8
        period_span INTEGER DEFAULT 1, -- number of periods this entry spans
        course_code TEXT NOT NULL,
        course_name TEXT,
        class_level TEXT,              -- e.g. 'ม.1', 'ม.2', ..., 'ม.6' or ''
        room TEXT DEFAULT '',
        note TEXT DEFAULT '',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(term, year, teacher_name, day_of_week, period_num)
    );

    CREATE INDEX IF NOT EXISTS idx_tt_lookup
    ON teacher_timetables(term, year, class_level, day_of_week, period_num);

    CREATE INDEX IF NOT EXISTS idx_tt_teacher
    ON teacher_timetables(term, year, teacher_name);
    """
    with get_connection(db_path) as conn:
        conn.executescript(schema)
        conn.commit()

    # A semester imported with the school form (school_import.py) owns its timetable: no built-in seed over it
    from school_import import form_managed
    with get_connection(db_path) as conn:
        managed = {s: form_managed(conn, *s) for s in (("1", "2569"), ("2", "2569"))}

    # This school's built-in courses and timetables (school_builtin_data.py; the blank edition has none)
    builtin = school_profile.builtin()
    if builtin is None:
        return
    # Ensure missing Term 1 courses are in course_catalog
    builtin.seed_missing_art_courses(db_path)
    if not managed[("1", "2569")]:
        # Seed extracted teacher schedules for 1/2569
        builtin.seed_initial_timetables(db_path)
        # Sync timetable courses into archive courses & grades_history for 1/2569
        sync_timetables_to_archive_courses("1", "2569", db_path)
    if not managed[("2", "2569")]:
        # Seed extracted teacher schedules for 2/2569 (เริ่มใช้ 28 ตุลาคม 2569)
        builtin.seed_term2_2569_timetables(db_path)
        # Sync timetable courses into archive courses & grades_history for 2/2569
        sync_timetables_to_archive_courses("2", "2569", db_path)


def _insert_blank_enrolment(cursor, student_id: str, student_no: Any, course_code: str, term: str, year: str, class_level: str) -> bool:
    """Enrol a student in a course unless already enrolled. Starts blank: attendance comes from the
    daily table, never assumed present. Returns True when a row was added."""
    exists = cursor.execute(
        "SELECT id FROM grades_history WHERE student_id = ? AND course_code = ? AND term = ? AND year = ?;",
        (student_id, course_code, term, year)
    ).fetchone()
    if exists:
        return False
    default_att = json.dumps({
        "status_list": [""] * 100,
        "present_count": 0,
        "absent_count": 0,
        "leave_count": 0,
        "late_count": 0,
        "percentage": 0.0,
        "manual_slots": []
    }, ensure_ascii=False)
    default_scores = json.dumps({
        "components": [0, 0, 0, 0],
        "total_score": 0,
        "percent": 0,
        "before_midterm": 0,
        "midterm": 0,
        "after_midterm": 0,
        "final": 0,
        "classroom": class_level,
        "student_no": student_no
    }, ensure_ascii=False)
    default_attrs = json.dumps({
        "desirable_characteristics": 3,
        "reading_analytical_thinking": 3
    }, ensure_ascii=False)
    cursor.execute(
        """
        INSERT INTO grades_history (
            student_id, course_code, term, year,
            scores_json, attendance_json, attributes_json, final_grade
        ) VALUES (?, ?, ?, ?, ?, ?, ?, '');
        """,
        (student_id, course_code, term, year, default_scores, default_att, default_attrs)
    )
    return True


def enroll_student_in_level_courses(
    term: str,
    year: str,
    class_level: str,
    student_id: str,
    db_path: str = DB_DEFAULT_PATH
) -> List[str]:
    """Enrol a student added to a class mid-semester in every course of that class level
    (the same rows the archive sync creates). Returns the course codes enrolled into."""
    t, y, cl, sid = str(term).strip(), str(year).strip(), str(class_level).strip(), str(student_id).strip()
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        st = cursor.execute(
            "SELECT student_no FROM class_students WHERE term = ? AND year = ? AND class_level = ? AND student_id = ? AND is_active = 1;",
            (t, y, cl, sid)
        ).fetchone()
        if not st:
            return []
        from school_import import eligible_students
        codes = [
            r["course_code"] for r in cursor.execute("SELECT course_code, class_level FROM courses WHERE term = ? AND year = ?;", (t, y))
            if cl in [l.strip() for l in str(r["class_level"] or "").split(",")]
        ]
        # only the courses of the student's programme; never a course enrolled by name
        codes = [c for c in codes if any(s["student_id"] == sid for s in (eligible_students(conn, c, t, y) or []))]
        added = [c for c in codes if _insert_blank_enrolment(cursor, sid, st["student_no"], c, t, y, cl)]
        conn.commit()
    return added


def sync_timetables_to_archive_courses(
    term: str = "1",
    year: str = "2569",
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Synchronizes all academic courses taught in teacher_timetables for the given term/year into:
    1. courses table (for Archive repository, PorPor5, scores, reports)
    2. grades_history table for all active students enrolled in class_students for that class_level.
    Also ensures teacher names and teacher codes are mapped from school_teachers.
    """
    with get_connection(db_path) as conn:
        cursor = conn.cursor()

        # 1. Load official teachers mapping: clean name -> (official_name, teacher_code)
        st_rows = cursor.execute("SELECT name, code FROM school_teachers;").fetchall()
        teacher_map = {}
        for r in st_rows:
            raw_name = r["name"]
            code = r["code"] or ""
            clean = raw_name.replace("นางสาว", "").replace("นาย", "").replace("นาง", "").replace("ครู", "").strip()
            teacher_map[clean] = {"official_name": raw_name, "code": code}
            teacher_map[raw_name] = {"official_name": raw_name, "code": code}
            # nicknames used in this school's timetable files (school_builtin_data.TEACHER_ALIASES)
            for real, nicknames in _teacher_aliases().items():
                if real in clean:
                    for nick in nicknames:
                        teacher_map[nick] = {"official_name": raw_name, "code": code}

        # 2. Non-academic activities to exclude from courses table
        non_subject = {
            "Personal Learning", "PLC ครู", "คุณธรรม จริยธรรม", "บำเพ็ญบุญ",
            "Home Room", "พักเบรก", "พักกลางวัน", "ชุมนุม", "ลูกเสือ",
            "กิจกรรม พัฒนาผู้เรียน / ลูกเสือ", "กิจกรรม พัฒนาผู้เรียน / ชุมนุม",
            "กิจกรรมพัฒนาผู้เรียน / ลูกเสือ", "กิจกรรมพัฒนาผู้เรียน / ชุมนุม",
        }
        if term == "1":
            non_subject.add("แนะแนว")

        # 2.1 Clean up any accidental time-range fake courses
        cursor.execute("""
            DELETE FROM courses
            WHERE term = ? AND year = ? AND (
                course_code LIKE '%.%-%' OR course_code LIKE '%:%-%' OR course_code LIKE '%08.30%'
            );
        """, (term, year))
        cursor.execute("""
            DELETE FROM grades_history
            WHERE term = ? AND year = ? AND (
                course_code LIKE '%.%-%' OR course_code LIKE '%:%-%' OR course_code LIKE '%08.30%'
            );
        """, (term, year))

        # 3. Fetch all timetable entries for this term/year
        entries = cursor.execute(
            """
            SELECT teacher_name, day_of_week, period_num, period_span, course_code, course_name, class_level, room
            FROM teacher_timetables
            WHERE term = ? AND year = ?
            ORDER BY day_of_week, period_num;
            """,
            (term, year)
        ).fetchall()

        # 4. Group timetable slots by (course_code, class_level, teacher_name)
        course_slots_map: Dict[Tuple[str, str, str], List[Dict[str, Any]]] = {}

        for e in entries:
            c_code = (e["course_code"] or "").strip()
            t_name = (e["teacher_name"] or "").strip()
            c_lvl = (e["class_level"] or "").strip()
            c_name = (e["course_name"] or "").strip()

            if not c_code or c_code in non_subject or re.match(r"^\d{1,2}[\.:]\d{2}", c_code):
                continue

            # Handle Muay Thai / Combined class levels
            if c_code == "มวยไทย":
                levels = [l.strip() for l in c_lvl.split(",") if l.strip()]
                if term == "2":
                    muay_code_map = {
                        "ม.1": ("พ21222", "มวยไทยพื้นฐาน 2"),
                        "ม.2": ("พ22222", "มวยไทยพื้นฐาน 4"),
                        "ม.3": ("พ23222", "มวยไทยพื้นฐาน 6"),
                        "ม.4": ("พ31222", "มวยไทยพื้นฐาน 2"),
                        "ม.5": ("พ32222", "มวยไทยพื้นฐาน 4"),
                        "ม.6": ("พ33222", "มวยไทยพื้นฐาน 6"),
                    }
                    for lvl in levels:
                        sub_code, sub_name = muay_code_map.get(lvl, ("พ21222", "มวยไทยพื้นฐาน 2"))
                        key = (sub_code, lvl, t_name)
                        course_slots_map.setdefault(key, []).append({
                            "day": e["day_of_week"],
                            "period": e["period_num"],
                            "span": e["period_span"] or 1,
                            "room": e["room"] or "",
                            "course_name": sub_name
                        })
                else:
                    muay_code_map = {
                        "ม.1": "พ21221", "ม.2": "พ22221", "ม.3": "พ23221",
                        "ม.4": "พ31221", "ม.5": "พ32221", "ม.6": "พ33221"
                    }
                    for lvl in levels:
                        sub_code = muay_code_map.get(lvl, "พ21221")
                        key = (sub_code, lvl, t_name)
                        course_slots_map.setdefault(key, []).append({
                            "day": e["day_of_week"],
                            "period": e["period_num"],
                            "span": e["period_span"] or 1,
                            "room": e["room"] or "",
                            "course_name": f"มวยไทยพื้นฐาน {lvl[-1]}"
                        })
                continue

            # Handle Piano combined class levels in Term 2
            if c_code == "เปียโน" and term == "2":
                levels = [l.strip() for l in c_lvl.split(",") if l.strip()]
                for lvl in levels:
                    if lvl == "ม.3":
                        sub_code, sub_name = ("ศ23232", "เปียโนปฏิบัติพื้นฐาน 6")
                    elif lvl == "ม.6":
                        sub_code, sub_name = ("ศ33232", "เปียโนปฏิบัติพื้นฐาน 6")
                    elif lvl == "ม.4":
                        # Mon P4 -> ศ31232 (เปียโนปฏิบัติพื้นฐาน 2), Tue P7 -> ศ31212 (ศิลปะประยุกต์ 2)
                        if e["day_of_week"] == 2 and e["period_num"] == 7:
                            sub_code, sub_name = ("ศ31212", "ศิลปะประยุกต์ 2")
                        else:
                            sub_code, sub_name = ("ศ31232", "เปียโนปฏิบัติพื้นฐาน 2")
                    else:
                        sub_code, sub_name = ("ศ21232", "เปียโนปฏิบัติพื้นฐาน 2")
                    key = (sub_code, lvl, t_name)
                    course_slots_map.setdefault(key, []).append({
                        "day": e["day_of_week"],
                        "period": e["period_num"],
                        "span": e["period_span"] or 1,
                        "room": e["room"] or "",
                        "course_name": sub_name
                    })
                continue

            # Handle Music Education combined class levels in Term 2 (Wed P5 ม.4-6)
            if c_code == "ดนตรีศึกษา" and term == "2":
                levels = [l.strip() for l in c_lvl.split(",") if l.strip()]
                music_map = {
                    "ม.4": ("ศ31222", "ดนตรีศึกษา 2"),
                    "ม.5": ("ศ32222", "ดนตรีศึกษา 4"),
                    "ม.6": ("ศ33222", "ดนตรีศึกษา 6"),
                }
                for lvl in levels:
                    if lvl in music_map:
                        sub_code, sub_name = music_map[lvl]
                        key = (sub_code, lvl, t_name)
                        course_slots_map.setdefault(key, []).append({
                            "day": e["day_of_week"],
                            "period": e["period_num"],
                            "span": e["period_span"] or 1,
                            "room": e["room"] or "",
                            "course_name": sub_name
                        })
                continue

            # Handle Guidance (แนะแนว) in Term 2 -> ก21102..ก33102
            if c_code == "แนะแนว" and term == "2":
                guid_map = {
                    "ม.1": ("ก21102", "แนะแนว 2"),
                    "ม.2": ("ก22102", "แนะแนว 4"),
                    "ม.3": ("ก23102", "แนะแนว 6"),
                    "ม.4": ("ก31102", "แนะแนว 2"),
                    "ม.5": ("ก32102", "แนะแนว 4"),
                    "ม.6": ("ก33102", "แนะแนว 6"),
                }
                if c_lvl in guid_map:
                    sub_code, sub_name = guid_map[c_lvl]
                    key = (sub_code, c_lvl, t_name)
                    course_slots_map.setdefault(key, []).append({
                        "day": e["day_of_week"],
                        "period": e["period_num"],
                        "span": e["period_span"] or 1,
                        "room": e["room"] or "",
                        "course_name": sub_name
                    })
                continue

            # Handle combined multi-code / multi-class slots (e.g. "พ21222, พ33222" for "ม.1, ม.6")
            if "," in c_code and "," in c_lvl:
                codes = [x.strip() for x in c_code.split(",") if x.strip()]
                levels = [l.strip() for l in c_lvl.split(",") if l.strip()]
                if len(codes) == len(levels):
                    for sub_code, lvl in zip(codes, levels):
                        cat_r = cursor.execute(
                            "SELECT course_name FROM course_catalog WHERE course_code = ? LIMIT 1;",
                            (sub_code,)
                        ).fetchone()
                        sub_name = cat_r["course_name"] if cat_r and cat_r["course_name"] else c_name
                        key = (sub_code, lvl, t_name)
                        course_slots_map.setdefault(key, []).append({
                            "day": e["day_of_week"],
                            "period": e["period_num"],
                            "span": e["period_span"] or 1,
                            "room": e["room"] or "",
                            "course_name": sub_name
                        })
                    continue

            # Standard course
            levels = [l.strip() for l in c_lvl.split(",") if l.strip()] if "," in c_lvl else [c_lvl]
            for lvl in levels:
                key = (c_code, lvl, t_name)
                if key not in course_slots_map:
                    course_slots_map[key] = []
                course_slots_map[key].append({
                    "day": e["day_of_week"],
                    "period": e["period_num"],
                    "span": e["period_span"] or 1,
                    "room": e["room"] or "",
                    "course_name": c_name
                })

        # 5. For each course, resolve metadata and insert/update in `courses`
        synced_courses = []
        total_students_enrolled = 0

        if term == "1":
            default_start_date = f"{int(year)-543}-05-15"
        elif term == "2" and year == "2569":
            default_start_date = "2026-10-28"
        else:
            default_start_date = f"{int(year)-543}-11-01"

        from school_import import eligible_students, section_count
        before_schedule = {
            (r["course_code"], r["class_level"] or ""): (r["schedule_json"] or "", r["periods_per_week"], r["teacher"] or "")
            for r in cursor.execute("SELECT course_code, class_level, schedule_json, periods_per_week, teacher FROM courses WHERE term = ? AND year = ?;", (term, year))
        }
        structural: List[str] = []   # ปพ.5 files whose header/roster changes even if no attendance number moves
        for (c_code, c_lvl, t_name), slots in course_slots_map.items():
            if section_count(conn, c_code, term, year) > 1:
                # several teachers (sections from the import form): the form set teacher and timetable; only enrol
                for st in eligible_students(conn, c_code, term, year) or []:
                    if _insert_blank_enrolment(cursor, st["student_id"], st["student_no"], c_code, term, year, st["class_level"]):
                        total_students_enrolled += 1
                        structural.append(c_code)
                continue
            # Resolve teacher official name & code
            clean_t = t_name.replace("นางสาว", "").replace("นาย", "").replace("นาง", "").replace("ครู", "").strip()
            t_info = teacher_map.get(clean_t) or teacher_map.get(t_name)
            if t_info:
                official_teacher = t_info["official_name"]
                teacher_code = t_info["code"]
            else:
                official_teacher = t_name
                teacher_code = ""

            # Resolve catalog info
            cat_row = cursor.execute(
                "SELECT * FROM course_catalog WHERE course_code = ? LIMIT 1;",
                (c_code,)
            ).fetchone()

            if cat_row:
                course_name = cat_row["course_name"] or slots[0].get("course_name") or c_code
                credits = float(cat_row["credits"] or 1.0)
                department = cat_row["department"] or ""
                course_type = cat_row["course_type"] or "พื้นฐาน"
                score_ratio = cat_row["score_ratio"] or "70:30"
                course_desc = cat_row["course_description"] or ""
            else:
                course_name = slots[0].get("course_name") or c_code
                credits = 1.0
                department = ""
                course_type = "พื้นฐาน" if len(c_code) >= 3 and c_code[2] == '1' else "เพิ่มเติม"
                score_ratio = "70:30"
                course_desc = ""

            # Fallback department from prefix if empty
            if not department:
                prefix = c_code[0] if c_code else ""
                dept_map = {
                    "ท": "กลุ่มสาระการเรียนรู้ภาษาไทย",
                    "ค": "กลุ่มสาระการเรียนรู้คณิตศาสตร์",
                    "ว": "กลุ่มสาระการเรียนรู้วิทยาศาสตร์และเทคโนโลยี",
                    "ส": "กลุ่มสาระการเรียนรู้สังคมศึกษา ศาสนา และวัฒนธรรม",
                    "พ": "กลุ่มสาระการเรียนรู้สุขศึกษาและพลศึกษา",
                    "ศ": "กลุ่มสาระการเรียนรู้ศิลปะ",
                    "ง": "กลุ่มสาระการเรียนรู้การงานอาชีพ",
                    "อ": "กลุ่มสาระการเรียนรู้ภาษาต่างประเทศ",
                    "จ": "กลุ่มสาระการเรียนรู้ภาษาต่างประเทศ",
                    "I": "การศึกษาค้นคว้าอิสระ (IS)",
                    "ก": "กิจกรรมพัฒนาผู้เรียน",
                }
                department = dept_map.get(prefix, "")

            # Count periods per week
            periods_per_week = sum(s.get("span", 1) for s in slots)

            # Schedule JSON
            schedule_list = [
                {
                    "day": s["day"],
                    "day_name": DAY_NAMES.get(s["day"], ""),
                    "period": s["period"],
                    "span": s.get("span", 1),
                    "room": s.get("room", "")
                }
                for s in slots
            ]
            schedule_json = json.dumps(schedule_list, ensure_ascii=False)

            # Upsert into courses table
            cursor.execute(
                """
                INSERT INTO courses (
                    course_code, course_name, term, year, teacher, course_description,
                    start_date, schedule_json, credits, class_level, department,
                    course_type, score_ratio, teacher_code, periods_per_week
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(course_code, term, year) DO UPDATE SET
                    course_name = excluded.course_name,
                    teacher = excluded.teacher,
                    course_description = COALESCE(courses.course_description, excluded.course_description),
                    start_date = COALESCE(courses.start_date, excluded.start_date),
                    schedule_json = excluded.schedule_json,
                    credits = excluded.credits,
                    class_level = excluded.class_level,
                    department = excluded.department,
                    course_type = excluded.course_type,
                    score_ratio = excluded.score_ratio,
                    teacher_code = excluded.teacher_code,
                    periods_per_week = excluded.periods_per_week;
                """,
                (
                    c_code, course_name, term, year, official_teacher, course_desc,
                    default_start_date, schedule_json, credits, c_lvl, department,
                    course_type, score_ratio, teacher_code, periods_per_week
                )
            )

            synced_courses.append({
                "course_code": c_code,
                "course_name": course_name,
                "class_level": c_lvl,
                "teacher": official_teacher,
                "teacher_code": teacher_code,
                "periods_per_week": periods_per_week,
                "credits": credits
            })

            # 6. Enroll active students from class_students into grades_history
            #    (the level's students, only the listed programmes when the course names some, none when enrolled by name)
            if c_lvl:
                for st in eligible_students(conn, c_code, term, year) or []:
                    if _insert_blank_enrolment(cursor, st["student_id"], st["student_no"], c_code, term, year, c_lvl):
                        total_students_enrolled += 1
                        structural.append(c_code)
            # เวลาเรียนเต็ม and the teacher's name are printed from the course row, so a changed timetable means a
            # changed ปพ.5 even when no student's counts move
            old = before_schedule.get((c_code, c_lvl))
            if old is None or old != (schedule_json, periods_per_week, official_teacher):
                structural.append(c_code)

        conn.commit()

    from database import notify_courses_changed
    notify_courses_changed(term, year, structural)

    return {
        "status": "success",
        "term": term,
        "year": year,
        "synced_courses_count": len(synced_courses),
        "total_students_enrolled": total_students_enrolled,
        "courses": synced_courses
    }


def get_timetables(
    term: str,
    year: str,
    teacher_name: Optional[str] = None,
    class_level: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> List[Dict[str, Any]]:
    """Retrieve timetables filtered by teacher or class level."""
    init_timetable_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        query = "SELECT * FROM teacher_timetables WHERE term = ? AND year = ?"
        params: List[Any] = [term, year]

        if teacher_name:
            # Handle normalized name or partial
            query += " AND (teacher_name = ? OR teacher_name LIKE ?)"
            clean_t = teacher_name.replace("ครู", "").replace("นาย", "").replace("นางสาว", "").replace("นาง", "").strip()
            params.extend([teacher_name, f"%{clean_t}%"])

        if class_level:
            query += " AND (class_level = ? OR class_level LIKE ?)"
            params.extend([class_level, f"%{class_level}%"])

        query += " ORDER BY day_of_week ASC, period_num ASC;"
        rows = cursor.execute(query, params).fetchall()
        result = [dict(r) for r in rows]
        if class_level and not teacher_name:
            target_lvl = class_level.strip()
            deduped = []
            seen_shared = set()
            for item in result:
                c_code = (item.get("course_code") or "").strip()
                c_lvl = (item.get("class_level") or "").strip()
                if c_code == "PLC ครู":
                    continue
                # Resolve combined multi-course slots (e.g. "พ21222, พ33222" for "ม.1, ม.6") to the specific class's course code & name
                if "," in c_code and "," in c_lvl:
                    codes = [x.strip() for x in c_code.split(",") if x.strip()]
                    levels = [l.strip() for l in c_lvl.split(",") if l.strip()]
                    if len(codes) == len(levels) and target_lvl in levels:
                        idx = levels.index(target_lvl)
                        resolved_code = codes[idx]
                        cat_r = cursor.execute(
                            "SELECT course_name FROM course_catalog WHERE course_code = ? LIMIT 1;",
                            (resolved_code,)
                        ).fetchone()
                        item["course_code"] = resolved_code
                        if cat_r and cat_r["course_name"]:
                            item["course_name"] = cat_r["course_name"]
                        item["class_level"] = target_lvl
                        c_code = resolved_code
                elif c_code == "มวยไทย":
                    muay_map = {
                        "ม.1": ("พ21222", "มวยไทยพื้นฐาน 2") if term == "2" else ("พ21221", "มวยไทยพื้นฐาน 1"),
                        "ม.2": ("พ22222", "มวยไทยพื้นฐาน 4") if term == "2" else ("พ22221", "มวยไทยพื้นฐาน 3"),
                        "ม.3": ("พ23222", "มวยไทยพื้นฐาน 6") if term == "2" else ("พ23221", "มวยไทยพื้นฐาน 5"),
                        "ม.4": ("พ31222", "มวยไทยพื้นฐาน 2") if term == "2" else ("พ31221", "มวยไทยพื้นฐาน 1"),
                        "ม.5": ("พ32222", "มวยไทยพื้นฐาน 4") if term == "2" else ("พ32221", "มวยไทยพื้นฐาน 3"),
                        "ม.6": ("พ33222", "มวยไทยพื้นฐาน 6") if term == "2" else ("พ33221", "มวยไทยพื้นฐาน 5"),
                    }
                    if target_lvl in muay_map:
                        item["course_code"], item["course_name"] = muay_map[target_lvl]
                        item["class_level"] = target_lvl
                        c_code = item["course_code"]

                if c_code in ("Personal Learning", "ชุมนุม", "คุณธรรม จริยธรรม", "ลูกเสือ", "PLC ครู") or "จริยธรรม" in c_code:
                    item["teacher_name"] = ""
                    key = (item.get("day_of_week"), item.get("period_num"), c_code)
                    if key in seen_shared:
                        continue
                    seen_shared.add(key)
                deduped.append(item)
            result = deduped
        return result


def get_teachers_with_timetables(term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> List[str]:
    """Get unique teacher names that have timetables registered for this term/year."""
    init_timetable_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        rows = cursor.execute(
            """
            SELECT DISTINCT teacher_name FROM teacher_timetables
            WHERE term = ? AND year = ?
            ORDER BY teacher_name ASC;
            """,
            (term, year)
        ).fetchall()
        return [r["teacher_name"] for r in rows]


def get_teacher_courses(
    term: str,
    year: str,
    teacher_name: str,
    db_path: str = DB_DEFAULT_PATH
) -> List[Dict[str, Any]]:
    """
    Get list of courses taught by a specific teacher for a term/year.
    Filtered from both teacher_timetables and the courses/course_catalog table.
    """
    init_timetable_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        # Clean prefix
        clean_name = teacher_name.replace("ครู", "").replace("นาย", "").replace("นางสาว", "").replace("นาง", "").strip()
        
        # 1. From timetables
        tt_rows = cursor.execute(
            """
            SELECT DISTINCT course_code, course_name, class_level FROM teacher_timetables
            WHERE term = ? AND year = ? AND (teacher_name = ? OR teacher_name LIKE ?)
            AND course_code NOT IN ('Personal Learning', 'ชุมนุม', 'PLC ครู', 'คุณธรรม จริยธรรม', 'ลูกเสือ', 'แนะแนว', 'บำเพ็ญบุญ', 'Home Room')
            ORDER BY course_code ASC;
            """,
            (term, year, teacher_name, f"%{clean_name}%")
        ).fetchall()
        courses_dict = {}
        for r in tt_rows:
            courses_dict[r["course_code"]] = {
                "course_code": r["course_code"],
                "course_name": r["course_name"] or "",
                "class_level": r["class_level"] or ""
            }

        # 2. From courses table
        c_rows = cursor.execute(
            """
            SELECT course_code, course_name FROM courses
            WHERE term = ? AND year = ? AND (teacher LIKE ? OR teacher = ?)
            ORDER BY course_code ASC;
            """,
            (term, year, f"%{clean_name}%", teacher_name)
        ).fetchall()
        for r in c_rows:
            code = r["course_code"]
            if code not in courses_dict:
                courses_dict[code] = {
                    "course_code": code,
                    "course_name": r["course_name"] or "",
                    "class_level": ""
                }
        return list(courses_dict.values())


def upsert_timetable_entry(
    term: str,
    year: str,
    teacher_name: str,
    day_of_week: int,
    period_num: int,
    course_code: str,
    course_name: Optional[str] = None,
    class_level: Optional[str] = None,
    room: Optional[str] = "",
    note: Optional[str] = "",
    period_span: int = 1,
    db_path: str = DB_DEFAULT_PATH
) -> int:
    """Insert or update a single timetable slot."""
    init_timetable_db(db_path)
    
    # Auto-resolve course_name from catalog if missing (a combined slot "ค31102, ค32102" gets "ชื่อ1 / ชื่อ2")
    if not course_name and course_code:
        with get_connection(db_path) as conn:
            c = conn.cursor()
            names = []
            for code in [x.strip() for x in str(course_code).split(",") if x.strip()]:
                row = c.execute("SELECT course_name FROM course_catalog WHERE course_code = ? LIMIT 1;", (code,)).fetchone()
                names.append(row["course_name"] if row and row["course_name"] else code)
            course_name = " / ".join(names)

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            INSERT INTO teacher_timetables (
                term, year, teacher_name, day_of_week, period_num, period_span,
                course_code, course_name, class_level, room, note, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(term, year, teacher_name, day_of_week, period_num) DO UPDATE SET
                period_span = excluded.period_span,
                course_code = excluded.course_code,
                course_name = excluded.course_name,
                class_level = excluded.class_level,
                room = excluded.room,
                note = excluded.note,
                updated_at = CURRENT_TIMESTAMP;
            """,
            (term, year, teacher_name, day_of_week, period_num, period_span,
             course_code, course_name or "", class_level or "", room or "", note or "")
        )
        conn.commit()
        return cursor.lastrowid or 0


def timetable_clashes(term: str, year: str, teacher_name: str, day_of_week: int, period_num: int,
                      period_span: int, class_level: str, ignore_id: Optional[int] = None,
                      db_path: str = DB_DEFAULT_PATH) -> Dict[str, List[Dict[str, Any]]]:
    """What already sits at that time: the same teacher's other slot ("teacher") and other teachers teaching
    one of the same class levels ("class"). Activities shared by the whole school (ชุมนุม, PLC ...) are ignored."""
    shared = ("Personal Learning", "ชุมนุม", "คุณธรรม จริยธรรม", "ลูกเสือ", "PLC ครู")
    want = set(range(int(period_num), int(period_num) + max(1, int(period_span or 1))))
    levels = {x.strip() for x in str(class_level or "").split(",") if x.strip()}
    me = re.sub(r"\s+", "", re.sub(r"^(ครู|นางสาว|นาง|นาย)", "", str(teacher_name or "").strip()))
    out: Dict[str, List[Dict[str, Any]]] = {"teacher": [], "class": []}
    with get_connection(db_path) as conn:
        rows = conn.execute(
            "SELECT * FROM teacher_timetables WHERE term = ? AND year = ? AND day_of_week = ?;",
            (str(term), str(year), int(day_of_week))).fetchall()
    for r in rows:
        if ignore_id is not None and r["id"] == ignore_id:
            continue
        span = set(range(r["period_num"], r["period_num"] + max(1, r["period_span"] or 1)))
        if not (span & want):
            continue
        item = {"id": r["id"], "teacher_name": r["teacher_name"], "course_code": r["course_code"],
                "class_level": r["class_level"] or "", "period_num": r["period_num"]}
        other = re.sub(r"\s+", "", re.sub(r"^(ครู|นางสาว|นาง|นาย)", "", str(r["teacher_name"] or "").strip()))
        if other == me:
            out["teacher"].append(item)
        elif levels and r["course_code"] not in shared and levels & {x.strip() for x in str(r["class_level"] or "").split(",")}:
            out["class"].append(item)
    return out


def move_timetable_entry(entry_id: int, day_of_week: int, period_num: int,
                         db_path: str = DB_DEFAULT_PATH) -> Optional[Dict[str, Any]]:
    """Move one slot to another day/period (same teacher, same course). Returns the moved row, or None if
    the slot no longer exists. The caller checks clashes first (timetable_clashes)."""
    with get_connection(db_path) as conn:
        row = conn.execute("SELECT * FROM teacher_timetables WHERE id = ?;", (int(entry_id),)).fetchone()
        if not row:
            return None
        conn.execute(
            "UPDATE teacher_timetables SET day_of_week = ?, period_num = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?;",
            (int(day_of_week), int(period_num), int(entry_id)))
        conn.commit()
        return {**dict(row), "day_of_week": int(day_of_week), "period_num": int(period_num)}


def _slot_pairs(row) -> Optional[List[Tuple[str, str]]]:
    """(course_code, class_level) pairs of a slot; None when it is an activity or the pairs do not line up."""
    codes = [c.strip() for c in str(row["course_code"] or "").split(",") if c.strip()]
    levels = [l.strip() for l in str(row["class_level"] or "").split(",") if l.strip()]
    if not codes or len(codes) != len(levels):
        return None
    if not all(re.fullmatch(r"[ก-ฮA-Z]\d{5}", c.replace(" ", "")) for c in codes):
        return None
    return list(zip(codes, levels))


def can_merge_timetable_entries(source, target) -> bool:
    """A slot moved onto the same teacher's slot can become one combined slot (สอนรวมหลายชั้น) when both are
    real courses covering exactly the same periods and no course code repeats."""
    a, b = _slot_pairs(source), _slot_pairs(target)
    if not a or not b:
        return False
    if (source["period_span"] or 1) != (target["period_span"] or 1):
        return False
    return not ({c for c, _ in a} & {c for c, _ in b})


def merge_timetable_entries(source_id: int, target_id: int, db_path: str = DB_DEFAULT_PATH) -> Optional[Dict[str, Any]]:
    """Fold slot source_id into slot target_id as one combined slot ("ส31112, ส32222" / "ม.4, ม.5", ordered by
    class level) and delete the source. Returns the merged row, or None when the two cannot be merged."""
    with get_connection(db_path) as conn:
        src = conn.execute("SELECT * FROM teacher_timetables WHERE id = ?;", (int(source_id),)).fetchone()
        dst = conn.execute("SELECT * FROM teacher_timetables WHERE id = ?;", (int(target_id),)).fetchone()
        if not src or not dst or not can_merge_timetable_entries(src, dst):
            return None
        pairs = sorted(_slot_pairs(dst) + _slot_pairs(src), key=lambda p: (p[1], p[0]))
        own = {}
        for r in (dst, src):
            rp = _slot_pairs(r)
            parts = [x.strip() for x in str(r["course_name"] or "").split(" / ")]
            for i, (code, _) in enumerate(rp):
                own[code] = parts[i] if len(parts) == len(rp) else (parts[0] if parts else "")
        names = []
        for code, _ in pairs:
            n = own.get(code) or ""
            if not n:
                cat = conn.execute("SELECT course_name FROM course_catalog WHERE course_code = ? LIMIT 1;", (code,)).fetchone()
                n = (cat["course_name"] if cat and cat["course_name"] else code)
            if n not in names:
                names.append(n)
        code_s = ", ".join(c for c, _ in pairs)
        level_s = ", ".join(l for _, l in pairs)
        name_s = " / ".join(names)
        conn.execute(
            "UPDATE teacher_timetables SET course_code = ?, course_name = ?, class_level = ?, "
            "updated_at = CURRENT_TIMESTAMP WHERE id = ?;", (code_s, name_s, level_s, int(target_id)))
        conn.execute("DELETE FROM teacher_timetables WHERE id = ?;", (int(source_id),))
        conn.commit()
        return {**dict(dst), "course_code": code_s, "course_name": name_s, "class_level": level_s}


def delete_timetable_entry(entry_id: int, db_path: str = DB_DEFAULT_PATH) -> bool:
    """Delete a timetable slot by id."""
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("DELETE FROM teacher_timetables WHERE id = ?;", (entry_id,))
        conn.commit()
        return cursor.rowcount > 0


def get_class_schedule_for_day(
    term: str,
    year: str,
    class_level: str,
    day_of_week: int,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[int, Dict[str, Any]]:
    """
    Look up which course and teacher a specific class level has for each period (1..8) on a specific day of week.
    Returns: {period_num: {"course_code": ..., "course_name": ..., "teacher_name": ..., "room": ...}}
    """
    init_timetable_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        rows = cursor.execute(
            """
            SELECT period_num, period_span, course_code, course_name, class_level, teacher_name, room, note
            FROM teacher_timetables
            WHERE term = ? AND year = ? AND (class_level = ? OR class_level LIKE ?) AND day_of_week = ?
            ORDER BY period_num ASC;
            """,
            (term, year, class_level, f"%{class_level}%", day_of_week)
        ).fetchall()

        schedule = {}
        muay_code_map = {
            "ม.1": ("พ21221", "มวยไทยพื้นฐาน 1"),
            "ม.2": ("พ22221", "มวยไทยพื้นฐาน 3"),
            "ม.3": ("พ23221", "มวยไทยพื้นฐาน 5"),
            "ม.4": ("พ31221", "มวยไทยพื้นฐาน 1"),
            "ม.5": ("พ32221", "มวยไทยพื้นฐาน 3"),
            "ม.6": ("พ33221", "มวยไทยพื้นฐาน 5"),
        }
        want = str(class_level).strip()
        for r in rows:
            p_num = r["period_num"]
            span = r["period_span"] or 1
            c_code = r["course_code"]
            c_name = r["course_name"] or ""

            # คาบสอนรวม "ส31112, ส32222" / "ม.4, ม.5": ชั้นนี้ได้เฉพาะรหัส (และชื่อ) ที่จับคู่กับชั้นนี้
            levels = [x.strip() for x in str(r["class_level"] or "").split(",") if x.strip()]
            if want not in levels:
                continue   # LIKE จับ "ม.1" ใน "ม.1/2" ได้ แต่ไม่ใช่ชั้นนี้
            codes = [x.strip() for x in str(c_code or "").split(",") if x.strip()]
            if len(codes) > 1 and len(codes) == len(levels):
                mine = [i for i, l in enumerate(levels) if l == want]
                names = [x.strip() for x in c_name.split(" / ")]
                c_code = ", ".join(codes[i] for i in mine)
                if len(names) == len(codes):
                    c_name = " / ".join(dict.fromkeys(names[i] for i in mine))

            if c_code == "มวยไทย":
                clean_lvl = class_level.strip()
                if clean_lvl in muay_code_map:
                    c_code, c_name = muay_code_map[clean_lvl]

            data = {
                "period_num": p_num,
                "course_code": c_code,
                "course_name": c_name,
                "teacher_name": r["teacher_name"] or "",
                "room": r["room"] or "",
                "note": r["note"] or "",
                "period_span": span
            }
            # For Scout (ลูกเสือ), the scout lead's slot is the reference for time/day (ไม่ต้องแสดงชื่อครู)
            if c_code == "ลูกเสือ":
                if _is_scout_lead(r["teacher_name"]) or p_num not in schedule:
                    data["teacher_name"] = ""
                    schedule[p_num] = data
            elif c_code in ("Personal Learning", "ชุมนุม", "คุณธรรม จริยธรรม", "PLC ครู") or "จริยธรรม" in c_code:
                # คาบ ชุมนุม จริยธรรม personal ไม่ต้องขึ้นชื่อครู เพราะนักเรียนเลือกเรียนไม่ตรงกัน
                data["teacher_name"] = ""
                schedule[p_num] = data
            elif p_num in schedule and schedule[p_num].get("course_code") and schedule[p_num]["course_code"] != c_code:
                # ครูสองคนสอนชั้นนี้คาบเดียวกัน (แยกกลุ่มเรียน): เก็บไว้ทั้งสองวิชา ผู้เรียกเลือกวิชาที่นักเรียนลงทะเบียน
                schedule[p_num].setdefault("alternatives", []).append(data)
                continue
            else:
                schedule[p_num] = data

            # If span > 1, fill subsequent periods as well
            for s in range(1, span):
                schedule[p_num + s] = data
        return schedule


def _slot_for_student(cursor, slot: Optional[Dict[str, Any]], student_id: Optional[str], term: str, year: str):
    """Of a period's courses (slot + slot["alternatives"]), the one this student is enrolled in."""
    if not slot:
        return slot
    options = [slot] + list(slot.get("alternatives") or [])
    if len(options) == 1 or not student_id:
        return slot
    for o in options:
        if cursor.execute("SELECT 1 FROM grades_history WHERE course_code = ? AND student_id = ? AND term = ? AND year = ?;",
                          (o["course_code"], student_id, term, year)).fetchone():
            return o
    return slot


def preview_late_cascade(
    term: str,
    year: str,
    class_level: str,
    day_of_week: int,
    arrived_period: int,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Preview which course the student arrived at and which earlier courses
    will be marked absent if the student arrives at `arrived_period` (1..7).
    """
    init_timetable_db(db_path)
    class_sched = get_class_schedule_for_day(term, year, class_level, day_of_week, db_path)
    arrived_slot = class_sched.get(arrived_period)

    missed_periods_detail = []
    non_subject = {"Personal Learning", "PLC ครู", "คุณธรรม จริยธรรม", "บำเพ็ญบุญ", "Home Room", "พักเบรก", "พักกลางวัน", "ลูกเสือ", "ชุมนุม"}

    def _all(slot):
        # วิชาทั้งหมดในคาบนั้น (ครูสองคนสอนชั้นนี้คาบเดียวกัน) แสดงรวมกัน
        if not slot or not slot.get("alternatives"):
            return slot
        opts = [slot] + slot["alternatives"]
        return {**slot, "course_code": " / ".join(o["course_code"] for o in opts),
                "course_name": " / ".join(o["course_name"] for o in opts),
                "teacher_name": " / ".join(o["teacher_name"] for o in opts if o["teacher_name"])}
    class_sched = {p: _all(v) for p, v in class_sched.items()}
    arrived_slot = class_sched.get(arrived_period)

    for p in range(1, arrived_period):
        slot = class_sched.get(p)
        if slot:
            c_code = slot["course_code"]
            is_subj = c_code not in non_subject
            missed_periods_detail.append({
                "period_num": p,
                "course_code": c_code,
                "course_name": slot["course_name"],
                "teacher_name": slot["teacher_name"],
                "will_mark_absent": is_subj
            })
        else:
            missed_periods_detail.append({
                "period_num": p,
                "course_code": "",
                "course_name": "ยังไม่ได้ลงตารางสอนในคาบนี้",
                "teacher_name": "",
                "will_mark_absent": False
            })

    full_day = []
    for p in range(1, 9):
        s = class_sched.get(p)
        full_day.append({
            "period_num": p,
            "course_code": s["course_code"] if s else "",
            "course_name": s["course_name"] if s else "",
            "teacher_name": s["teacher_name"] if s else "",
        })

    return {
        "term": term,
        "year": year,
        "class_level": class_level,
        "day_of_week": day_of_week,
        "day_name": DAY_NAMES.get(day_of_week, ""),
        "arrived_period": arrived_period,
        "arrived_course": arrived_slot,
        "missed_periods_detail": missed_periods_detail,
        "full_day_schedule": full_day
    }


def cascade_late_student(
    term: str,
    year: str,
    class_level: str,
    student_id: str,
    date_str: str,
    arrived_period: int,
    slot_idx: Optional[int] = None,
    day_of_week_override: Optional[int] = None,
    outputs_dir: str = "outputs",
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Smart Attendance & Period Integration:
    When a student arrives late at `arrived_period` (1..7):
    1. Query class timetable for that day.
    2. Periods 1 to (arrived_period - 1) are marked as ABSENT ("ขาด") in each course taught to that class.
    3. The student's attendance record in `grades_history` for those courses is updated with "ข" on that date/slot.
    4. The PorPor5 Excel file for each affected course is synchronized.
    5. The daily_attendance record is updated to status='late', note='มาคาบ {arrived_period}'.
    Returns summary of affected courses and results.
    """
    from excel_mapper import update_course_attendance_in_file

    init_timetable_db(db_path)
    try:
        dt = datetime.strptime(date_str, "%Y-%m-%d")
        computed_dow = dt.weekday() + 1
    except Exception:
        dt = datetime.now()
        computed_dow = dt.weekday() + 1

    if day_of_week_override is not None and 1 <= day_of_week_override <= 5:
        day_of_week = day_of_week_override
    elif slot_idx is not None and 0 <= slot_idx < 100:
        day_of_week = (slot_idx % 5) + 1
    else:
        day_of_week = computed_dow

    if day_of_week > 5:
        return {
            "status": "warning",
            "message": "วันที่เลือกเป็นวันหยุดสุดสัปดาห์ ไม่มีตารางสอน",
            "missed_courses": []
        }

    # 1. Get class schedule for this weekday (a period with two courses -> the one this student is enrolled in)
    class_sched = get_class_schedule_for_day(term, year, class_level, day_of_week, db_path)
    with get_connection(db_path) as conn:
        cur = conn.cursor()
        class_sched = {p: _slot_for_student(cur, v, student_id, term, year) for p, v in class_sched.items()}

    # 2. Identify missed periods before arrived_period
    missed_periods = list(range(1, arrived_period))
    arrived_slot_info = class_sched.get(arrived_period)

    # 3. Find unique courses in missed periods
    missed_courses_map: Dict[str, Dict[str, Any]] = {}
    for p in missed_periods:
        slot = class_sched.get(p)
        if slot:
            c_code = slot["course_code"]
            if c_code not in ("Personal Learning", "PLC ครู", "คุณธรรม จริยธรรม", "บำเพ็ญบุญ", "Home Room", "พักเบรก", "พักกลางวัน", "ลูกเสือ", "ชุมนุม"):
                if c_code not in missed_courses_map:
                    missed_courses_map[c_code] = {
                        "course_code": c_code,
                        "course_name": slot["course_name"],
                        "teacher_name": slot["teacher_name"],
                        "periods": [p]
                    }
                else:
                    missed_courses_map[c_code]["periods"].append(p)

    # 4. For each missed course, mark absence in grades_history & PorPor5 Excel
    affected_courses_results = []
    excel_sync_queue = []
    with get_connection(db_path) as conn:
        cursor = conn.cursor()

        for c_code, c_info in missed_courses_map.items():
            row = cursor.execute(
                """
                SELECT attendance_json, scores_json FROM grades_history
                WHERE course_code = ? AND student_id = ? AND term = ? AND year = ?;
                """,
                (c_code, student_id, term, year)
            ).fetchone()

            if not row:
                affected_courses_results.append({
                    "course_code": c_code,
                    "course_name": c_info["course_name"],
                    "teacher_name": c_info["teacher_name"],
                    "periods": c_info["periods"],
                    "status": "pending_course_import",
                    "reason": "บันทึกสถานะขาดรอซิงก์เมื่ออัพโหลดวิชาเข้าคลัง"
                })
                continue

            affected_courses_results.append({
                "course_code": c_code,
                "course_name": c_info["course_name"],
                "teacher_name": c_info["teacher_name"],
                "periods": c_info["periods"],
                "status": "absent_marked",
                "excel_synced": True
            })

        # 4.5 For arrived period course, mark "ส" (Late) so teacher can evaluate conduct/จิตพิสัย
        # "ส่วนในเวลาเรียนของรายวิชา ก็ให้มาในคาบนั้น แต่ เชคขาดในคาบก่อนหน้า แต่แสดง ผลสาย เพื่อให้ครู พิจารณา คะแนนจิตพิสัย"
        if arrived_slot_info and arrived_slot_info.get("course_code"):
            arr_code = arrived_slot_info["course_code"]
            if arr_code not in ("Personal Learning", "PLC ครู", "คุณธรรม จริยธรรม", "บำเพ็ญบุญ", "Home Room", "พักเบรก", "พักกลางวัน"):
                row_arr = cursor.execute(
                    """
                    SELECT attendance_json FROM grades_history
                    WHERE course_code = ? AND student_id = ? AND term = ? AND year = ?;
                    """,
                    (arr_code, student_id, term, year)
                ).fetchone()

                if row_arr:
                    affected_courses_results.append({
                        "course_code": arr_code,
                        "course_name": arrived_slot_info.get("course_name", ""),
                        "teacher_name": arrived_slot_info.get("teacher_name", ""),
                        "periods": [arrived_period],
                        "status": "late_marked",
                        "note": "มาเรียนในคาบนี้ (ทำเครื่องหมาย ส เพื่อให้ครูพิจารณาคะแนนจิตพิสัย แต่นับเวลาเรียนปกติ)",
                        "excel_synced": True
                    })

        # 5. Record daily attendance
        note_text = f"มาคาบ {arrived_period}"
        if arrived_slot_info and arrived_slot_info.get("course_code"):
            note_text += f" ({arrived_slot_info['course_code']})"
        if missed_courses_map:
            missed_str = ", ".join(f"{k}(คาบ{','.join(map(str, v['periods']))})" for k, v in missed_courses_map.items())
            note_text += f" | ขาด: {missed_str}"

        cursor.execute(
            """
            INSERT INTO daily_attendance (
                attendance_date, term, year, class_level, student_id, status, note, updated_at
            ) VALUES (?, ?, ?, ?, ?, 'late', ?, CURRENT_TIMESTAMP)
            ON CONFLICT(attendance_date, student_id) DO UPDATE SET
                status = 'late',
                note = excluded.note,
                updated_at = CURRENT_TIMESTAMP;
            """,
            (date_str, term, year, class_level, student_id, note_text)
        )
        conn.commit()

    # The daily record ("late" + "มาคาบ N") is the source of truth: the canonical sync marks
    # earlier periods absent and the arrival period "ส" in every course, then refreshes the ปพ.5 files.
    if missed_courses_map or arrived_slot_info:
        from database import sync_daily_attendance_to_courses
        sync_daily_attendance_to_courses(term, year, class_level, student_ids=[student_id], db_path=db_path)

    return {
        "status": "success",
        "date": date_str,
        "day_of_week": day_of_week,
        "day_name": DAY_NAMES.get(day_of_week, ""),
        "student_id": student_id,
        "class_level": class_level,
        "arrived_period": arrived_period,
        "arrived_course": arrived_slot_info,
        "missed_periods": missed_periods,
        "affected_courses": affected_courses_results,
        "note": note_text,
        "message": f"บันทึกมาสาย (คาบ {arrived_period}) และเชื่อมตัดขาดเรียนอัตโนมัติ {len(affected_courses_results)} รายวิชา"
    }


def generate_timetable_template_excel(
    term: str = "1",
    year: str = "2569",
    teacher_name: str = "ครูผู้สอน",
    class_level: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> bytes:
    """
    Generate an Excel template matching the official teacher or class timetable form.
    Returns bytes of the xlsx file.
    """
    if not openpyxl:
        raise RuntimeError("openpyxl is required to generate Excel templates.")

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = f"ตารางเรียน_{class_level}" if class_level else "ตารางสอน"
    ws.views.sheetView[0].showGridLines = True

    # Styling constants
    font_header = Font(name="Sarabun", size=14, bold=True, color="1A237E")
    font_sub = Font(name="Sarabun", size=11, bold=True, color="37474F")
    font_col = Font(name="Sarabun", size=10, bold=True, color="FFFFFF")
    font_time = Font(name="Sarabun", size=9, bold=False, color="FFFFFF")
    font_cell = Font(name="Sarabun", size=10)
    font_day = Font(name="Sarabun", size=11, bold=True, color="1A237E")

    fill_navy = PatternFill(start_color="1A237E", end_color="1A237E", fill_type="solid")
    fill_indigo = PatternFill(start_color="3949AB", end_color="3949AB", fill_type="solid")
    fill_break = PatternFill(start_color="ECEFF1", end_color="ECEFF1", fill_type="solid")
    fill_day = PatternFill(start_color="F5F5F5", end_color="F5F5F5", fill_type="solid")

    thin_border = Border(
        left=Side(style="thin", color="CCCCCC"),
        right=Side(style="thin", color="CCCCCC"),
        top=Side(style="thin", color="CCCCCC"),
        bottom=Side(style="thin", color="CCCCCC")
    )
    align_center = Alignment(horizontal="center", vertical="center", wrap_text=True)

    # 1. School & Title Banner
    from database import get_app_setting
    school_name = school_profile.full_name(db_path)
    if not school_name.startswith("โรงเรียน"):
        school_name = f"โรงเรียน{school_name}"
    ws.merge_cells("A1:L1")
    ws["A1"] = f"{school_name} สำนักงานเขตพื้นที่การศึกษา"
    ws["A1"].font = font_header
    ws["A1"].alignment = align_center

    ws.merge_cells("A2:L2")
    if class_level and class_level.strip():
        ws["A2"] = f"ตารางเรียนประจำชั้น: {class_level}   |   ภาคเรียนที่ {term} ปีการศึกษา {year}   (เริ่มใช้ 15 พฤษภาคม {year})"
    else:
        ws["A2"] = f"ตารางสอนรายบุคคล: {teacher_name}   |   ภาคเรียนที่ {term} ปีการศึกษา {year}   (เริ่มใช้ 15 พฤษภาคม {year})"
    ws["A2"].font = font_sub
    ws["A2"].alignment = align_center

    # Column Headers: เริ่มต้นคาบที่ 1 ทันที (ตัดกิจกรรม 1-3 ออกเพื่อให้ตารางไม่หลุดขอบ)
    headers_row4 = [
        ("A", "วัน", "จันทร์ - ศุกร์"),
        ("B", "คาบ 1", "08.30 - 09.20"),
        ("C", "คาบ 2", "09.20 - 10.10"),
        ("D", "พัก 10 นาที", "10.10 - 10.20"),
        ("E", "คาบ 3", "10.20 - 11.10"),
        ("F", "คาบ 4", "11.10 - 12.00"),
        ("G", "พักกลางวัน", "12.00 - 13.00"),
        ("H", "คาบ 5", "13.00 - 13.50"),
        ("I", "คาบ 6", "13.50 - 14.40"),
        ("J", "คาบ 7", "14.40 - 15.30"),
        ("K", "คาบ 8", "15.30 - 16.00"),
        ("L", "หมายเหตุ", "คำอธิบายเพิ่มเติม"),
    ]

    for col_letter, title, time_info in headers_row4:
        cell_t = ws[f"{col_letter}4"]
        cell_t.value = title
        cell_t.font = font_col
        cell_t.fill = fill_navy
        cell_t.alignment = align_center
        cell_t.border = thin_border

        cell_time = ws[f"{col_letter}5"]
        cell_time.value = time_info
        cell_time.font = font_time
        cell_time.fill = fill_indigo
        cell_time.alignment = align_center
        cell_time.border = thin_border

    # Days rows
    days = [
        (1, "จันทร์"),
        (2, "อังคาร"),
        (3, "พุธ"),
        (4, "พฤหัสบดี"),
        (5, "ศุกร์"),
    ]

    existing_slots = {}
    if class_level and class_level.strip():
        try:
            records = get_timetables(term=term, year=year, class_level=class_level.strip(), db_path=db_path)
            from collections import defaultdict
            slots_by_dp = defaultdict(list)
            for r in records:
                slots_by_dp[(r["day_of_week"], r["period_num"])].append(r)
            for dp, r_list in slots_by_dp.items():
                if len(r_list) == 1:
                    existing_slots[dp] = r_list[0]
                else:
                    # Prioritize the scout lead for ลูกเสือ, or clean teacher for common activities
                    samarn_slot = next((s for s in r_list if s.get("course_code") == "ลูกเสือ" and _is_scout_lead(s.get("teacher_name"))), None)
                    if samarn_slot:
                        scout_slot = dict(samarn_slot)
                        scout_slot["teacher_name"] = ""  # ไม่ต้องขึ้นชื่อครู
                        existing_slots[dp] = scout_slot
                    else:
                        act_slot = dict(r_list[0])
                        c_code = act_slot.get("course_code")
                        if c_code in ("Personal Learning", "ชุมนุม", "คุณธรรม จริยธรรม", "ลูกเสือ", "PLC ครู") or "จริยธรรม" in c_code:
                            # ไม่ต้องขึ้นชื่อครู
                            act_slot["teacher_name"] = ""
                        existing_slots[dp] = act_slot
        except Exception:
            pass
    elif teacher_name and teacher_name.strip() and teacher_name != "ครูผู้สอน":
        try:
            records = get_timetables(term=term, year=year, teacher_name=teacher_name.strip(), db_path=db_path)
            for r in records:
                existing_slots[(r["day_of_week"], r["period_num"])] = r
        except Exception:
            pass

    period_col_map = {
        1: "B", 2: "C", 3: "E", 4: "F", 5: "H", 6: "I", 7: "J", 8: "K"
    }

    row_idx = 6
    for day_num, day_str in days:
        ws.row_dimensions[row_idx].height = 48

        # Day cell
        c_day = ws[f"A{row_idx}"]
        c_day.value = day_str
        c_day.font = font_day
        c_day.fill = fill_day
        c_day.alignment = align_center
        c_day.border = thin_border

        # Break 10 mins (Col D)
        c_brk1 = ws[f"D{row_idx}"]
        c_brk1.value = "พัก 10 นาที"
        c_brk1.font = Font(name="Sarabun", size=8, color="777777")
        c_brk1.fill = fill_break
        c_brk1.alignment = align_center
        c_brk1.border = thin_border

        # Lunch (Col G)
        c_lunch = ws[f"G{row_idx}"]
        c_lunch.value = "พักกลางวัน"
        c_lunch.font = Font(name="Sarabun", size=9, bold=True, color="555555")
        c_lunch.fill = fill_break
        c_lunch.alignment = align_center
        c_lunch.border = thin_border

        # Period slots 1..8 with pre-populated data if existing
        for p_num, col_l in period_col_map.items():
            cell = ws[f"{col_l}{row_idx}"]
            cell.font = font_cell
            cell.alignment = align_center
            cell.border = thin_border
            slot = existing_slots.get((day_num, p_num))
            if slot:
                lines = []
                if slot.get("course_code"):
                    lines.append(slot["course_code"])
                if class_level and class_level.strip():
                    if slot.get("course_name") and slot["course_name"] != slot.get("course_code"):
                        lines.append(slot["course_name"])
                    if slot.get("teacher_name") and slot.get("course_code") not in ("Personal Learning", "ชุมนุม", "คุณธรรม จริยธรรม", "ลูกเสือ", "PLC ครู") and "จริยธรรม" not in (slot.get("course_code") or ""):
                        lines.append(slot["teacher_name"])
                else:
                    if slot.get("class_level"):
                        lines.append(slot["class_level"])
                    if slot.get("course_name") and slot["course_name"] != slot.get("course_code"):
                        lines.append(slot["course_name"])
                cell.value = "\n".join(lines)

        # Note column (Col L)
        c_note = ws[f"L{row_idx}"]
        c_note.font = font_cell
        c_note.alignment = align_center
        c_note.border = thin_border

        row_idx += 1

    # Column widths
    ws.column_dimensions["A"].width = 12
    ws.column_dimensions["B"].width = 15
    ws.column_dimensions["C"].width = 15
    ws.column_dimensions["D"].width = 12
    ws.column_dimensions["E"].width = 15
    ws.column_dimensions["F"].width = 15
    ws.column_dimensions["G"].width = 13
    ws.column_dimensions["H"].width = 15
    ws.column_dimensions["I"].width = 15
    ws.column_dimensions["J"].width = 15
    ws.column_dimensions["K"].width = 15
    ws.column_dimensions["L"].width = 20

    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()


def import_timetables_from_file(
    file_content: bytes,
    term: str,
    year: str,
    teacher_name_override: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Import timetables from an uploaded Excel or CSV file.
    Supports either the visual timetable format or tabular (day, period, course_code, class_level, teacher_name).
    """
    init_timetable_db(db_path)
    if not openpyxl:
        raise RuntimeError("openpyxl is required to import Excel timetables.")

    wb = openpyxl.load_workbook(io.BytesIO(file_content), data_only=True)
    ws = wb.active

    # Check if this is the visual grid format (has 'คาบ 1', 'คาบ 2' in header)
    header_vals = [str(ws.cell(4, c).value or ws.cell(1, c).value or "").strip() for c in range(1, 15)]

    imported_count = 0
    detected_teacher = teacher_name_override or ""

    # Check cell A2 for teacher name if not provided
    a2_val = str(ws["A2"].value or "")
    if not detected_teacher and "ตารางสอนรายบุคคล:" in a2_val:
        parts = a2_val.split("ตารางสอนรายบุคคล:")[1].split("|")[0].strip()
        if parts:
            detected_teacher = parts

    # Period column mapping for visual layout - detect dynamically from header
    period_col_map = {}
    for r_hdr in range(1, 6):
        for c in range(1, ws.max_column + 1):
            val = str(ws.cell(r_hdr, c).value or "").strip()
            for p_num in range(1, 9):
                if f"คาบ {p_num}" in val or f"คาบที่ {p_num}" in val:
                    period_col_map[c] = p_num
        if len(period_col_map) >= 4:
            break

    # Fallback to standard column mapping if header text not recognized
    if not period_col_map:
        # Default layout without morning activities: B=1, C=2, D=Break, E=3, F=4, G=Lunch, H=5, I=6, J=7, K=8
        period_col_map = {2: 1, 3: 2, 5: 3, 6: 4, 8: 5, 9: 6, 10: 7, 11: 8}

    day_row_map = {
        "จันทร์": 1, "วันจันทร์": 1, "จ.": 1,
        "อังคาร": 2, "วันอังคาร": 2, "อ.": 2,
        "พุธ": 3, "วันพุธ": 3, "พ.": 3,
        "พฤหัสบดี": 4, "วันพฤหัสบดี": 4, "พฤ.": 4,
        "ศุกร์": 5, "วันศุกร์": 5, "ศ.": 5,
    }

    # Detect visual layout
    is_visual = any("คาบ" in v for v in header_vals)

    if is_visual:
        # Loop through rows looking for day names in Col A (start from row 6; row 5 is time headers)
        for r in range(6, ws.max_row + 1):
            day_cell_val = str(ws.cell(r, 1).value or "").strip()
            if not day_cell_val or "จันทร์ - ศุกร์" in day_cell_val or "-" in day_cell_val or "เวลา" in day_cell_val:
                continue

            clean_d = day_cell_val.replace("วัน", "").replace(".", "").strip()
            day_num = {"จันทร์": 1, "อังคาร": 2, "พุธ": 3, "พฤหัสบดี": 4, "ศุกร์": 5}.get(clean_d)
            if not day_num:
                for d_name, d_val in day_row_map.items():
                    if day_cell_val == d_name or day_cell_val.startswith(d_name):
                        day_num = d_val
                        break
            if not day_num:
                continue

            for col_idx, p_num in period_col_map.items():
                cell_val = str(ws.cell(r, col_idx).value or "").strip()
                if not cell_val:
                    continue

                # Ignore time strings accidentally placed in periods
                if re.match(r"^\d{1,2}[\.:]\d{2}", cell_val):
                    continue

                # Parse cell content (e.g. "ท23101\nม.3" or "ท23101 (ม.3)")
                lines = [l.strip() for l in cell_val.replace("\r", "").split("\n") if l.strip()]
                c_code = lines[0] if lines else cell_val
                c_lvl = lines[1] if len(lines) > 1 else ""

                if re.match(r"^\d{1,2}[\.:]\d{2}", c_code):
                    continue

                if not c_lvl and "(" in c_code and ")" in c_code:
                    m = re.search(r"\((ม\.\d+)\)", c_code)
                    if m:
                        c_lvl = m.group(1)
                        c_code = re.sub(r"\(ม\.\d+\)", "", c_code).strip()

                upsert_timetable_entry(
                    term=term,
                    year=year,
                    teacher_name=detected_teacher or "ครูผู้สอน",
                    day_of_week=day_num,
                    period_num=p_num,
                    course_code=c_code,
                    class_level=c_lvl,
                    db_path=db_path
                )
                imported_count += 1
    else:
        # Tabular format: Day, Period, CourseCode, ClassLevel, TeacherName
        for r in range(2, ws.max_row + 1):
            d_val = ws.cell(r, 1).value
            p_val = ws.cell(r, 2).value
            c_code = str(ws.cell(r, 3).value or "").strip()
            c_lvl = str(ws.cell(r, 4).value or "").strip()
            t_name = str(ws.cell(r, 5).value or detected_teacher or "ครูผู้สอน").strip()

            if not c_code or not d_val or not p_val:
                continue

            try:
                day_num = int(d_val)
                p_num = int(p_val)
            except Exception:
                continue

            upsert_timetable_entry(
                term=term,
                year=year,
                teacher_name=t_name,
                day_of_week=day_num,
                period_num=p_num,
                course_code=c_code,
                class_level=c_lvl,
                db_path=db_path
            )
            imported_count += 1

    return {
        "status": "success",
        "imported_count": imported_count,
        "teacher_name": detected_teacher,
        "message": f"นำเข้าข้อมูลตารางสอนเรียบร้อยแล้ว {imported_count} คาบ"
    }
