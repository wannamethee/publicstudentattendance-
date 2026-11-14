"""
Phase 2: Database Storage (SQLite)
Manages storage of students, courses, and grade histories for SGS to ปพ.5.
"""

import school_profile
import os
import sys
import re
import json
import sqlite3
import io
import csv
from typing import Dict, Any, List, Optional, Tuple
from pathlib import Path
from datetime import date, datetime, timedelta
import threading

import attendance_rules

try:
    import openpyxl
except ImportError:
    openpyxl = None

# Configure console encoding for Thai characters on Windows
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

DB_DEFAULT_PATH = "school_archive.db"


# Databases whose file has been switched to WAL in this process (the mode is stored in the file).
_wal_ready: set = set()


_scoped = threading.local()


class connection_scope:
    """
    For read-heavy computations that call many helpers (one per course): inside the block, get_connection() on
    this thread returns one shared connection instead of opening a new one each time (opening one also re-reads
    the schema). Helpers use it as `with get_connection() as conn:`, which commits but never closes, so sharing
    is transparent; the connection is closed when the block ends.
    """

    def __init__(self, db_path: str = DB_DEFAULT_PATH):
        self.key = os.path.abspath(str(db_path))
        self.db_path = db_path
        self.owner = False

    def __enter__(self):
        conns = getattr(_scoped, "conns", None)
        if conns is None:
            conns = _scoped.conns = {}
        if self.key not in conns:
            conns[self.key] = _open_connection(self.db_path)
            self.owner = True
        return conns[self.key]

    def __exit__(self, *exc):
        if self.owner:
            conn = _scoped.conns.pop(self.key)
            try:
                conn.commit()
            finally:
                conn.close()
        return False


def get_connection(db_path: str = DB_DEFAULT_PATH) -> sqlite3.Connection:
    """Establish connection to SQLite database with foreign keys and WAL mode for high concurrency."""
    conns = getattr(_scoped, "conns", None)
    if conns:
        shared = conns.get(os.path.abspath(str(db_path)))
        if shared is not None:
            return shared
    return _open_connection(db_path)


def _open_connection(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path, timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON;")
    key = os.path.abspath(str(db_path))
    if key not in _wal_ready:
        conn.execute("PRAGMA journal_mode = WAL;")
        _wal_ready.add(key)
    conn.execute("PRAGMA synchronous = NORMAL;")
    return conn


# init_db is called by nearly every function. Its schema checks, migrations and "seed when empty" defaults run once
# per database file per process; invalidate_init_cache() (after deleting seeded rows, a reset or a restore) makes the
# next call run them again, exactly as an uncached call would have.
_init_done: Dict[str, Any] = {}
_init_lock = threading.Lock()
INIT_EPOCH = [0]  # bumped on every invalidation; other modules' own "tables ready" flags follow it


def _db_identity(db_path: str):
    try:
        st = os.stat(db_path)
    except OSError:
        return None
    return (st.st_dev, st.st_ino)


def invalidate_init_cache(db_path: Optional[str] = None) -> None:
    INIT_EPOCH[0] += 1
    if db_path is None:
        _init_done.clear()
        _wal_ready.clear()
    else:
        key = os.path.abspath(str(db_path))
        _init_done.pop(key, None)
        _wal_ready.discard(key)


def _reinit_after(fn):
    """For functions that delete rows init_db seeds when a table is empty (or replace the data)."""
    import functools

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        finally:
            invalidate_init_cache()
    return wrapper


def init_db(db_path: str = DB_DEFAULT_PATH) -> None:
    key = os.path.abspath(str(db_path))
    ident = _db_identity(db_path)
    if ident is not None and _init_done.get(key) == ident:
        return
    with _init_lock:
        if ident is not None and _init_done.get(key) == ident:
            return
        _init_db_uncached(db_path)
        _init_done[key] = _db_identity(db_path)


def _init_db_uncached(db_path: str = DB_DEFAULT_PATH) -> None:
    """
    Initialize SQLite database schema for students, courses, and grades_history.
    """
    schema = """
    CREATE TABLE IF NOT EXISTS student_dmc_info (
        student_id TEXT PRIMARY KEY,
        school_id TEXT,
        school_name TEXT,
        citizen_id TEXT,
        class_level TEXT,
        room TEXT,
        gender TEXT,
        prefix TEXT,
        first_name TEXT,
        last_name TEXT,
        birth_date TEXT,
        age TEXT,
        weight TEXT,
        height TEXT,
        blood_group TEXT,
        religion TEXT,
        race TEXT,
        nationality TEXT,
        address_no TEXT,
        moo TEXT,
        street TEXT,
        subdistrict TEXT,
        district TEXT,
        province TEXT,
        guardian_prefix TEXT,
        guardian_name TEXT,
        guardian_lastname TEXT,
        guardian_occupation TEXT,
        guardian_relation TEXT,
        father_prefix TEXT,
        father_name TEXT,
        father_lastname TEXT,
        father_occupation TEXT,
        mother_prefix TEXT,
        mother_name TEXT,
        mother_lastname TEXT,
        mother_occupation TEXT,
        disadvantaged TEXT,
        cannot_discharge TEXT,
        dmc_raw_json TEXT,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS students (
        student_id TEXT PRIMARY KEY,
        full_name TEXT NOT NULL,
        citizen_id TEXT
    );

    -- one row per course per semester (a fresh database gets the same table the running school has)
    CREATE TABLE IF NOT EXISTS courses (
        course_code TEXT NOT NULL,
        course_name TEXT NOT NULL,
        term TEXT NOT NULL,
        year TEXT NOT NULL,
        teacher TEXT,
        course_description TEXT,
        start_date TEXT,
        schedule_json TEXT,
        credits REAL,
        class_level TEXT,
        department TEXT,
        course_type TEXT,
        score_ratio TEXT,
        teacher_code TEXT,
        periods_per_week INTEGER,
        PRIMARY KEY (course_code, term, year)
    );

    CREATE TABLE IF NOT EXISTS grades_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        student_id TEXT NOT NULL,
        course_code TEXT NOT NULL,
        term TEXT NOT NULL,
        year TEXT NOT NULL,
        scores_json TEXT,
        attendance_json TEXT,
        attributes_json TEXT,
        final_grade TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (student_id) REFERENCES students (student_id) ON DELETE CASCADE,
        FOREIGN KEY (course_code) REFERENCES courses (course_code) ON DELETE CASCADE,
        UNIQUE(student_id, course_code, term, year)
    );

    CREATE INDEX IF NOT EXISTS idx_grades_lookup 
    ON grades_history(course_code, term, year);

    CREATE INDEX IF NOT EXISTS idx_student_history 
    ON grades_history(student_id);

    CREATE TABLE IF NOT EXISTS semester_configs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        term TEXT NOT NULL,
        year TEXT NOT NULL,
        title TEXT NOT NULL,
        display_order INTEGER DEFAULT 0,
        is_active INTEGER DEFAULT 1,
        UNIQUE(term, year)
    );

    CREATE TABLE IF NOT EXISTS class_advisors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        term TEXT NOT NULL,
        year TEXT NOT NULL,
        class_level TEXT NOT NULL,
        advisor1 TEXT,
        advisor2 TEXT,
        advisor3 TEXT,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(term, year, class_level)
    );

    CREATE TABLE IF NOT EXISTS school_teachers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        code TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS school_signatories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year TEXT NOT NULL,
        director_name TEXT,
        director_title TEXT,
        academic_head_name TEXT,
        academic_head_title TEXT,
        registrar_name TEXT,
        registrar_title TEXT,
        dept_head_default TEXT,
        dept_heads_json TEXT DEFAULT '{}',
        school_name TEXT DEFAULT '',
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(year)
    );

    CREATE TABLE IF NOT EXISTS daily_attendance (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        attendance_date TEXT NOT NULL,
        term TEXT NOT NULL,
        year TEXT NOT NULL,
        class_level TEXT NOT NULL,
        student_id TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'present',
        note TEXT DEFAULT '',
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(attendance_date, student_id)
    );

    CREATE INDEX IF NOT EXISTS idx_daily_att_date_class 
    ON daily_attendance(attendance_date, class_level);

    CREATE INDEX IF NOT EXISTS idx_daily_att_student 
    ON daily_attendance(student_id, attendance_date);

    CREATE TABLE IF NOT EXISTS class_students (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        term TEXT NOT NULL,
        year TEXT NOT NULL,
        class_level TEXT NOT NULL,
        student_id TEXT NOT NULL,
        student_no INTEGER DEFAULT 1,
        full_name TEXT NOT NULL,
        room TEXT DEFAULT '1',
        is_active INTEGER DEFAULT 1,
        is_locked INTEGER DEFAULT 0,
        note TEXT DEFAULT '',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(term, year, class_level, student_id)
    );

    CREATE INDEX IF NOT EXISTS idx_class_students_lookup
    ON class_students(term, year, class_level, is_active);

    CREATE TABLE IF NOT EXISTS daily_attendance_config (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        term TEXT NOT NULL,
        year TEXT NOT NULL,
        class_level TEXT NOT NULL,
        start_date TEXT,
        holidays_json TEXT DEFAULT '[]',
        locked_json TEXT DEFAULT '[]',
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(term, year, class_level)
    );

    CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS system_admins (
        teacher_code TEXT PRIMARY KEY,
        teacher_name TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    """
    with get_connection(db_path) as conn:
        conn.executescript(schema)
        # Migrate existing table if course_description is not present
        cursor = conn.cursor()
        cols = [r["name"] for r in cursor.execute("PRAGMA table_info(courses);").fetchall()]
        if "course_description" not in cols:
            cursor.execute("ALTER TABLE courses ADD COLUMN course_description TEXT;")
        if "start_date" not in cols:
            cursor.execute("ALTER TABLE courses ADD COLUMN start_date TEXT;")
        if "schedule_json" not in cols:
            cursor.execute("ALTER TABLE courses ADD COLUMN schedule_json TEXT;")
        for col, decl in (("credits", "REAL"), ("class_level", "TEXT"), ("department", "TEXT"), ("course_type", "TEXT"),
                          ("score_ratio", "TEXT"), ("teacher_code", "TEXT"), ("periods_per_week", "INTEGER")):
            if col not in cols:
                cursor.execute(f"ALTER TABLE courses ADD COLUMN {col} {decl};")
        if "attendance_config_json" not in cols:
            # Course-specific extra holidays / activity days set from the ปพ.5 attendance dialog.
            # Kept apart from schedule_json so the timetable stays the single owner of teaching slots.
            cursor.execute("ALTER TABLE courses ADD COLUMN attendance_config_json TEXT;")

        # Teacher login PIN: a fresh database (blank edition) needs it before the first admin is created
        tch_cols = [r["name"] for r in cursor.execute("PRAGMA table_info(school_teachers);").fetchall()]
        if "login_pin" not in tch_cols:
            cursor.execute("ALTER TABLE school_teachers ADD COLUMN login_pin TEXT;")
            cursor.execute("UPDATE school_teachers SET login_pin = code WHERE login_pin IS NULL;")

        # Migrate class_students if room is not present
        cs_cols = [r["name"] for r in cursor.execute("PRAGMA table_info(class_students);").fetchall()]
        if "room" not in cs_cols:
            cursor.execute("ALTER TABLE class_students ADD COLUMN room TEXT DEFAULT '1';")
        if "is_locked" not in cs_cols:
            cursor.execute("ALTER TABLE class_students ADD COLUMN is_locked INTEGER DEFAULT 0;")

        # Migrate students if citizen_id is not present
        st_cols = [r["name"] for r in cursor.execute("PRAGMA table_info(students);").fetchall()]
        if "citizen_id" not in st_cols:
            cursor.execute("ALTER TABLE students ADD COLUMN citizen_id TEXT;")

        # Rooms, programmes and course sections (school_import.py): additive tables and columns
        import school_import
        school_import.ensure_schema(conn)

        # ชื่อนักเรียนแยกช่อง: คำนำหน้า / ชื่อ / สกุล (full_name ยังอยู่ ระบบประกอบให้เองจากสามช่องนี้)
        for col in ("prefix", "first_name", "last_name"):
            if col not in cs_cols and col not in [r["name"] for r in cursor.execute("PRAGMA table_info(class_students);")]:
                cursor.execute(f"ALTER TABLE class_students ADD COLUMN {col} TEXT DEFAULT '';")
        # จำค่าที่แต่ละคน mark ไว้ (ภาคเรียนที่เลือกดู ฯลฯ) — ของ admin ยังเป็นค่าเริ่มต้นของโรงเรียน
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS user_preferences (
                user_code TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (user_code, key)
            );
        """)

        # Seed default semester configs if table is empty
        cursor.execute("SELECT COUNT(*) AS cnt FROM semester_configs;")
        if cursor.fetchone()["cnt"] == 0:
            defaults = [
                ("1", "2568", "ปีการศึกษา 2568 ภาคเรียนที่ 1", 1),
                ("2", "2568", "ปีการศึกษา 2568 ภาคเรียนที่ 2", 2),
                ("1", "2569", "ปีการศึกษา 2569 ภาคเรียนที่ 1", 3),
                ("2", "2569", "ปีการศึกษา 2569 ภาคเรียนที่ 2", 4),
            ]
            cursor.executemany(
                "INSERT INTO semester_configs (term, year, title, display_order) VALUES (?, ?, ?, ?);",
                defaults
            )

        # Seed default class advisors if table is empty
        cursor.execute("SELECT COUNT(*) AS cnt FROM class_advisors;")
        if cursor.fetchone()["cnt"] == 0:
            default_classes = school_profile.default_advisors()  # this school only; the blank edition starts empty
            for term, year in [("1", "2569"), ("2", "2569")]:
                for cl, a1, a2, a3 in default_classes:
                    cursor.execute(
                        """
                        INSERT OR IGNORE INTO class_advisors (term, year, class_level, advisor1, advisor2, advisor3)
                        VALUES (?, ?, ?, ?, ?, ?);
                        """,
                        (term, year, cl, a1, a2, a3)
                    )

        # Seed default school signatories if table is empty
        cursor.execute("SELECT COUNT(*) AS cnt FROM school_signatories;")
        # built-in signatories of this school only (school_profile); the blank edition starts empty
        if cursor.fetchone()["cnt"] == 0 and school_profile.BUILTIN_DATA:
            _sig = school_profile.default_signatories()
            default_director = _sig["director_name"]
            default_director_title = _sig["director_title"]
            default_academic = _sig["academic_head_name"]
            default_academic_title = _sig["academic_head_title"]
            default_registrar = _sig["registrar_name"]
            default_registrar_title = _sig["registrar_title"]
            default_dept_head = _sig["dept_head_default"]
            default_school = _sig["school_name"]

            for y in ["2567", "2568", "2569", "2570"]:
                cursor.execute(
                    """
                    INSERT OR IGNORE INTO school_signatories (
                        year, director_name, director_title,
                        academic_head_name, academic_head_title,
                        registrar_name, registrar_title,
                        dept_head_default, dept_heads_json, school_name
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    (
                        y,
                        default_director,
                        default_director_title,
                        default_academic,
                        default_academic_title,
                        default_registrar,
                        default_registrar_title,
                        default_dept_head,
                        "{}",
                        default_school
                    )
                )

        conn.commit()

    try:
        from catalog_manager import init_course_catalog
        init_course_catalog(db_path)
    except Exception:
        pass


def ingest_parsed_json(json_input: str | Dict[str, Any], db_path: str = DB_DEFAULT_PATH) -> Dict[str, int]:
    """
    Ingest parsed SGS data (file path or dictionary) into SQLite database.

    :param json_input: File path string to JSON or loaded dictionary.
    :param db_path: Path to target SQLite database.
    :return: Summary dictionary with count of ingested/updated records.
    """
    init_db(db_path)

    if isinstance(json_input, str):
        path = Path(json_input)
        if not path.exists():
            raise FileNotFoundError(f"JSON input file not found: {path}")
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = json_input

    header = data.get("header", {})
    students = data.get("students", [])

    course_code = str(header.get("course_code") or "UNKNOWN").strip()
    course_name = str(header.get("course_name") or "").strip()
    term = str(header.get("semester") or header.get("term") or "1").strip()
    year = str(header.get("academic_year") or header.get("year") or "").strip()
    teacher = header.get("teacher") or ""
    if teacher:
        m_t = re.search(r"((?:นาย|นางสาว|นาง|ดร\.|ว่าที่\s*ร\.ต\.)\s*[^\s\d]+(?:\s+[^\s\d]+)?)", teacher)
        if m_t:
            teacher = m_t.group(1).strip()

    desc = header.get("course_description") or data.get("course_description")

    # Override course_name and metadata from master course_catalog when course_code matches!
    cat_entry = None
    try:
        from catalog_manager import lookup_catalog_course, decode_course_code, _clean_garbled_course_name, upsert_catalog_course
        cat_entry = lookup_catalog_course(course_code, db_path=db_path)
        if cat_entry:
            course_name = cat_entry["course_name"]
            header["course_name"] = course_name
            if not header.get("class_level") and cat_entry.get("class_level"):
                header["class_level"] = cat_entry["class_level"]
            if not header.get("department") and cat_entry.get("department"):
                header["department"] = cat_entry["department"]
            if not header.get("course_type") and cat_entry.get("course_type"):
                header["course_type"] = cat_entry["course_type"]
            if not header.get("credits") and cat_entry.get("credits"):
                header["credits"] = cat_entry["credits"]
            if not header.get("score_ratio") and cat_entry.get("score_ratio"):
                header["score_ratio"] = cat_entry["score_ratio"]
            if not desc and cat_entry.get("course_description"):
                desc = cat_entry["course_description"]
                header["course_description"] = desc
        elif course_code and course_code != "UNKNOWN":
            course_name = _clean_garbled_course_name(course_code, course_name)
            header["course_name"] = course_name
            decoded = decode_course_code(course_code)
            upsert_catalog_course({
                "course_code": course_code,
                "course_name": course_name,
                "term": decoded["term"],
                "stage": decoded["stage"],
                "class_level": header.get("class_level") or decoded["class_level"],
                "course_type": header.get("course_type") or decoded["course_type"],
                "department": header.get("department") or decoded["department"],
                "subject_prefix": decoded["subject_prefix"],
                "credits": header.get("credits") or 1.0,
                "score_ratio": header.get("score_ratio") or "70:30",
                "course_description": desc or "",
            }, db_path=db_path)
    except Exception as e_cat:
        print(f"[WARN] Catalog lookup failed for {course_code}: {e_cat}")

    students_upserted = 0
    grades_upserted = 0

    with get_connection(db_path) as conn:
        cursor = conn.cursor()

        # 1. Upsert course record
        c_lvl = header.get("class_level") or (cat_entry.get("class_level") if cat_entry else "") or ""
        c_dept = header.get("department") or (cat_entry.get("department") if cat_entry else "") or ""
        c_type = header.get("course_type") or (cat_entry.get("course_type") if cat_entry else "") or ""
        c_cred = header.get("credits") or (cat_entry.get("credits") if cat_entry else 1.0)
        c_ratio = header.get("score_ratio") or (cat_entry.get("score_ratio") if cat_entry else "70:30")

        try:
            cursor.execute(
                """
                INSERT INTO courses (
                    course_code, course_name, term, year, teacher, course_description,
                    class_level, department, course_type, credits, score_ratio
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(course_code, term, year) DO UPDATE SET
                    course_name = excluded.course_name,
                    teacher = CASE WHEN excluded.teacher != '' THEN excluded.teacher ELSE courses.teacher END,
                    course_description = CASE WHEN excluded.course_description IS NOT NULL AND excluded.course_description != '' THEN excluded.course_description ELSE courses.course_description END,
                    class_level = CASE WHEN excluded.class_level != '' THEN excluded.class_level ELSE courses.class_level END,
                    department = CASE WHEN excluded.department != '' THEN excluded.department ELSE courses.department END,
                    course_type = CASE WHEN excluded.course_type != '' THEN excluded.course_type ELSE courses.course_type END,
                    credits = COALESCE(excluded.credits, courses.credits),
                    score_ratio = CASE WHEN excluded.score_ratio != '' THEN excluded.score_ratio ELSE courses.score_ratio END;
                """,
                (course_code, course_name, term, year, teacher, desc, c_lvl, c_dept, c_type, c_cred, c_ratio)
            )
        except sqlite3.OperationalError:
            cursor.execute(
                """
                INSERT INTO courses (course_code, course_name, term, year, teacher, course_description)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(course_code) DO UPDATE SET
                    course_name = excluded.course_name,
                    term = excluded.term,
                    year = excluded.year,
                    teacher = excluded.teacher,
                    course_description = COALESCE(excluded.course_description, courses.course_description);
                """,
                (course_code, course_name, term, year, teacher, desc)
            )

        # 2. Upsert student and grade history records
        for idx, student in enumerate(students, start=1):
            student_id = str(student.get("student_id") or "").strip()
            # If student_id is empty, assign fallback based on student_no
            if not student_id:
                st_no = student.get("student_no") or idx
                student_id = f"NO_{st_no:02d}"

            full_name = student.get("full_name") or ""
            if not full_name:
                first = student.get("first_name", "")
                last = student.get("last_name", "")
                title = student.get("title", "")
                full_name = f"{title}{first} {last}".strip()

            scores = dict(student.get("scores") or {})
            if "student_no" not in scores:
                scores["student_no"] = student.get("student_no") or idx
            if "classroom" not in scores:
                scores["classroom"] = student.get("classroom") or ""

            attendance = {
                "percentage": student.get("attendance_percentage"),
                "hours_attended": student.get("attendance_percentage") # or total hours
            }
            attributes = student.get("attributes") or {}
            final_grade = str(student.get("grade") or "").strip()

            scores_json = json.dumps(scores, ensure_ascii=False)
            attendance_json = json.dumps(attendance, ensure_ascii=False)
            attributes_json = json.dumps(attributes, ensure_ascii=False)

            # Insert/Update student table
            cursor.execute(
                """
                INSERT INTO students (student_id, full_name)
                VALUES (?, ?)
                ON CONFLICT(student_id) DO UPDATE SET
                    full_name = excluded.full_name;
                """,
                (student_id, full_name)
            )
            students_upserted += 1

            # Insert/Update grades_history table
            cursor.execute(
                """
                INSERT INTO grades_history (
                    student_id, course_code, term, year,
                    scores_json, attendance_json, attributes_json, final_grade
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(student_id, course_code, term, year) DO UPDATE SET
                    scores_json = excluded.scores_json,
                    attendance_json = excluded.attendance_json,
                    attributes_json = excluded.attributes_json,
                    final_grade = excluded.final_grade;
                """,
                (
                    student_id, course_code, term, year,
                    scores_json, attendance_json, attributes_json, final_grade
                )
            )
            grades_upserted += 1

        conn.commit()

    return {
        "course_code": course_code,
        "term": term,
        "year": year,
        "students_upserted": students_upserted,
        "grades_upserted": grades_upserted
    }


def query_grades_by_semester(term: str, year: str, course_code: Optional[str] = None, db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """
    Retrieve historical grading records for a specific term and academic year.
    """
    query = """
    SELECT 
        g.id,
        g.student_id,
        s.full_name,
        g.course_code,
        c.course_name,
        c.teacher,
        g.term,
        g.year,
        g.scores_json,
        g.attendance_json,
        g.attributes_json,
        g.final_grade,
        g.created_at
    FROM grades_history g
    JOIN students s ON g.student_id = s.student_id
    JOIN courses c ON g.course_code = c.course_code
    WHERE g.term = ? AND g.year = ?
    """
    params = [term, year]
    if course_code:
        query += " AND g.course_code = ?"
        params.append(course_code)

    query += " ORDER BY g.student_id ASC;"

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(query, params)
        rows = cursor.fetchall()
        results = []
        for r in rows:
            results.append({
                "id": r["id"],
                "student_id": r["student_id"],
                "full_name": r["full_name"],
                "course_code": r["course_code"],
                "course_name": r["course_name"],
                "teacher": r["teacher"],
                "term": r["term"],
                "year": r["year"],
                "scores": json.loads(r["scores_json"]) if r["scores_json"] else {},
                "attendance": json.loads(r["attendance_json"]) if r["attendance_json"] else {},
                "attributes": json.loads(r["attributes_json"]) if r["attributes_json"] else {},
                "final_grade": r["final_grade"],
                "created_at": r["created_at"]
            })
        return results


def query_student_transcript(student_id: str, db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """
    Retrieve complete historical academic transcript for an individual student.
    """
    query = """
    SELECT 
        g.term,
        g.year,
        g.course_code,
        c.course_name,
        c.teacher,
        g.scores_json,
        g.attendance_json,
        g.attributes_json,
        g.final_grade
    FROM grades_history g
    JOIN courses c ON g.course_code = c.course_code
    WHERE g.student_id = ?
    ORDER BY g.year ASC, g.term ASC;
    """
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(query, (student_id,))
        rows = cursor.fetchall()
        return [
            {
                "term": r["term"],
                "year": r["year"],
                "course_code": r["course_code"],
                "course_name": r["course_name"],
                "teacher": r["teacher"],
                "scores": json.loads(r["scores_json"]) if r["scores_json"] else {},
                "attendance": json.loads(r["attendance_json"]) if r["attendance_json"] else {},
                "attributes": json.loads(r["attributes_json"]) if r["attributes_json"] else {},
                "final_grade": r["final_grade"]
            }
            for r in rows
        ]


def update_course_description(course_code: str, description: str, db_path: str = DB_DEFAULT_PATH) -> bool:
    """Update or save the course description and indicators for a course (both courses and course_catalog)."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            "UPDATE courses SET course_description = ? WHERE course_code = ?;",
            (description, course_code)
        )
        updated = cursor.rowcount > 0
        try:
            cursor.execute(
                "UPDATE course_catalog SET course_description = ?, updated_at = CURRENT_TIMESTAMP WHERE course_code = ?;",
                (description, course_code)
            )
            updated = updated or (cursor.rowcount > 0)
        except Exception:
            pass
        conn.commit()
        return updated


def normalize_teacher_name(name: str) -> str:
    """Normalize teacher name: remove duplicate spaces, clean leading/trailing whitespace."""
    if not name:
        return ""
    import re
    return re.sub(r"\s+", " ", str(name).strip())


def update_course_teacher(
    course_code: str,
    teacher: str,
    term: Optional[str] = None,
    year: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> bool:
    """Update or save teacher assigned to a course in the courses table."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        query = "UPDATE courses SET teacher = ? WHERE course_code = ?"
        params = [normalize_teacher_name(teacher), course_code]
        if term and year:
            query += " AND term = ? AND year = ?"
            params.extend([term, year])
        cursor.execute(query, params)
        conn.commit()
        return cursor.rowcount > 0


def get_course_description(course_code: str, db_path: str = DB_DEFAULT_PATH) -> Optional[str]:
    """Retrieve the stored course description for a course (from courses or master course_catalog)."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT course_description FROM courses WHERE course_code = ? AND course_description IS NOT NULL AND course_description != '' LIMIT 1;",
            (course_code,)
        )
        row = cursor.fetchone()
        if row and row["course_description"]:
            return row["course_description"]
        try:
            cursor.execute(
                "SELECT course_description FROM course_catalog WHERE course_code = ? AND course_description IS NOT NULL AND course_description != '' LIMIT 1;",
                (course_code,)
            )
            cat_row = cursor.fetchone()
            if cat_row and cat_row["course_description"]:
                return cat_row["course_description"]
        except Exception:
            pass
        return None


def get_course_schedule(course_code: str, db_path: str = DB_DEFAULT_PATH, term: Optional[str] = None, year: Optional[str] = None) -> Dict[str, Any]:
    """Retrieve the stored start_date and schedule_json for a course (the same code can exist in several semesters)."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        if term and year:
            cursor.execute(
                "SELECT start_date, schedule_json FROM courses WHERE course_code = ? AND term = ? AND year = ?;",
                (course_code, str(term), str(year))
            )
        else:
            cursor.execute(
                "SELECT start_date, schedule_json FROM courses WHERE course_code = ? ORDER BY year DESC, term DESC LIMIT 1;",
                (course_code,)
            )
        row = cursor.fetchone()
        if not row:
            return {"start_date": None, "schedule": None}
        sch = json.loads(row["schedule_json"]) if row["schedule_json"] else None
        return {"start_date": row["start_date"], "schedule": sch}


def update_course_schedule(
    course_code: str,
    start_date: Optional[str] = None,
    schedule: Optional[Dict[str, Any]] = None,
    db_path: str = DB_DEFAULT_PATH,
    term: Optional[str] = None,
    year: Optional[str] = None
) -> bool:
    """Update start_date and schedule_json for a course, scoped to term/year when given."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        sch_json = json.dumps(schedule, ensure_ascii=False) if schedule is not None else None
        scope = " AND term = ? AND year = ?" if term and year else ""
        scope_args = (str(term), str(year)) if term and year else ()
        if start_date is not None and schedule is not None:
            cursor.execute(
                f"UPDATE courses SET start_date = ?, schedule_json = ? WHERE course_code = ?{scope};",
                (start_date, sch_json, course_code) + scope_args
            )
        elif start_date is not None:
            cursor.execute(
                f"UPDATE courses SET start_date = ? WHERE course_code = ?{scope};",
                (start_date, course_code) + scope_args
            )
        elif schedule is not None:
            cursor.execute(
                f"UPDATE courses SET schedule_json = ? WHERE course_code = ?{scope};",
                (sch_json, course_code) + scope_args
            )
        conn.commit()
        return cursor.rowcount > 0


def refresh_attendance_grade(cursor, course_code: str, student_id: str, term: str, year: str, attendance: Dict[str, Any]) -> bool:
    """Keep grades_history.final_grade in step with the automatic มส. (attendance_rules.effective_remark):
    set it while attendance cannot reach 80%, and give the score grade back once the teacher's
    attendance corrections lift it. A remark the teacher chose on the scores page always wins.
    Returns True when the grade was rewritten (the course's ปพ.5 then needs a refresh)."""
    row = cursor.execute(
        "SELECT scores_json, final_grade FROM grades_history WHERE course_code = ? AND student_id = ? AND term = ? AND year = ?;",
        (course_code, student_id, str(term), str(year))
    ).fetchone()
    if not row:
        return False
    scores = attendance_rules._load(row["scores_json"])
    scores = scores if isinstance(scores, dict) else {}
    current = row["final_grade"] or ""
    remark = attendance_rules.effective_remark(scores.get("remark"), attendance)
    if remark:
        new = remark
    elif current == attendance_rules.NO_EXAM_RIGHT:
        from course_importer import compute_excel_grade
        new = compute_excel_grade(float(scores.get("total_score") or 0), "") if scores.get("total_score") is not None else ""
    else:
        return False
    if new == current:
        return False
    cursor.execute(
        "UPDATE grades_history SET final_grade = ? WHERE course_code = ? AND student_id = ? AND term = ? AND year = ?;",
        (new, course_code, student_id, str(term), str(year))
    )
    return True


def update_course_attendance_batch(
    course_code: str,
    records: List[Dict[str, Any]],
    term: Optional[str] = None,
    year: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> int:
    """
    Update attendance records for students in a course.
    Each record contains:
      - student_id: str
      - attendance: dict (percentage, present, absent, leave, total_periods, status_list)
    """
    init_db(db_path)
    updated_count = 0
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        for rec in records:
            st_id = str(rec.get("student_id") or "").strip()
            if not st_id:
                continue
            att_dict = rec.get("attendance") or {}
            att_json = json.dumps(att_dict, ensure_ascii=False)

            if term and year:
                cursor.execute(
                    "UPDATE grades_history SET attendance_json = ? WHERE course_code = ? AND student_id = ? AND term = ? AND year = ?;",
                    (att_json, course_code, st_id, term, year)
                )
                refresh_attendance_grade(cursor, course_code, st_id, term, year, att_dict)
            else:
                cursor.execute(
                    "UPDATE grades_history SET attendance_json = ? WHERE course_code = ? AND student_id = ?;",
                    (att_json, course_code, st_id)
                )
            if cursor.rowcount > 0:
                updated_count += 1
        conn.commit()
    return updated_count


def get_semester_configs(db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """Retrieve all configured semesters with count of registered courses and default mark."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT value FROM app_settings WHERE key = 'default_semester';")
        row_def = cursor.fetchone()
        default_sem = row_def["value"].strip() if (row_def and row_def["value"]) else "1-2569"

        query = """
        SELECT 
            sc.id,
            sc.term,
            sc.year,
            sc.title,
            sc.display_order,
            sc.is_active,
            (SELECT COUNT(*) FROM courses c WHERE c.term = sc.term AND c.year = sc.year) AS course_count,
            (SELECT COUNT(*) FROM grades_history g WHERE g.term = sc.term AND g.year = sc.year) AS grade_count
        FROM semester_configs sc
        ORDER BY sc.display_order ASC, sc.year ASC, sc.term ASC;
        """
        cursor.execute(query)
        rows = [dict(r) for r in cursor.fetchall()]

        any_matched = False
        for r in rows:
            key = f"{r['term']}-{r['year']}"
            if key == default_sem:
                r["is_default"] = 1
                any_matched = True
            else:
                r["is_default"] = 0

        if not any_matched and rows:
            rows[0]["is_default"] = 1

        return rows


def set_default_semester(term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """Mark a specific semester (term-year) as the pinned default semester across the system."""
    init_db(db_path)
    sem_key = f"{str(term).strip()}-{str(year).strip()}"
    set_app_setting("default_semester", sem_key, db_path=db_path)
    return get_semester_configs(db_path=db_path)


def upsert_semester_config(
    term: str,
    year: str,
    title: str,
    display_order: int = 0,
    is_active: int = 1,
    config_id: Optional[int] = None,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """Create or update a semester configuration button."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        if config_id:
            cursor.execute(
                """
                UPDATE semester_configs
                SET term = ?, year = ?, title = ?, display_order = ?, is_active = ?
                WHERE id = ?;
                """,
                (term, year, title, display_order, is_active, config_id)
            )
        else:
            cursor.execute(
                """
                INSERT INTO semester_configs (term, year, title, display_order, is_active)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(term, year) DO UPDATE SET
                    title = excluded.title,
                    display_order = excluded.display_order,
                    is_active = excluded.is_active;
                """,
                (term, year, title, display_order, is_active)
            )
            config_id = cursor.lastrowid
        conn.commit()

        cursor.execute("SELECT * FROM semester_configs WHERE id = ?;", (config_id,))
        row = cursor.fetchone()
        return dict(row) if row else {"id": config_id, "term": term, "year": year, "title": title}


@_reinit_after
def delete_semester_config(config_id: int, db_path: str = DB_DEFAULT_PATH) -> bool:
    """Delete a semester configuration button."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("DELETE FROM semester_configs WHERE id = ?;", (config_id,))
        conn.commit()
        return cursor.rowcount > 0


@_reinit_after
def reset_semester_configs_to_defaults(db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """Reset semester configuration buttons to standard 4 defaults."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("DELETE FROM semester_configs;")
        defaults = [
            ("1", "2568", "ปีการศึกษา 2568 ภาคเรียนที่ 1", 1),
            ("2", "2568", "ปีการศึกษา 2568 ภาคเรียนที่ 2", 2),
            ("1", "2569", "ปีการศึกษา 2569 ภาคเรียนที่ 1", 3),
            ("2", "2569", "ปีการศึกษา 2569 ภาคเรียนที่ 2", 4),
        ]
        cursor.executemany(
            "INSERT INTO semester_configs (term, year, title, display_order) VALUES (?, ?, ?, ?);",
            defaults
        )
        conn.commit()
    return get_semester_configs(db_path)


@_reinit_after
def delete_semester_data(
    term: str,
    year: str,
    delete_files: bool = False,
    db_path: str = DB_DEFAULT_PATH,
    outputs_dir: str = "outputs"
) -> Dict[str, Any]:
    """
    Delete all grades, courses, and related data for a specific semester (term and year).
    Cleans up orphaned student profiles and optionally deletes generated Excel/PDF files.
    """
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        # Find all course codes belonging to this semester
        cursor.execute("SELECT course_code, course_name FROM courses WHERE term = ? AND year = ?;", (term, year))
        courses_to_del = cursor.fetchall()
        course_codes = [c["course_code"] for c in courses_to_del]

        # Delete grades_history
        cursor.execute("DELETE FROM grades_history WHERE term = ? AND year = ?;", (term, year))
        grades_deleted = cursor.rowcount

        # Delete courses
        cursor.execute("DELETE FROM courses WHERE term = ? AND year = ?;", (term, year))
        courses_deleted = cursor.rowcount

        # Delete class_students (roster for attendance & dashboard)
        cursor.execute("DELETE FROM class_students WHERE term = ? AND year = ?;", (term, year))
        class_students_deleted = cursor.rowcount

        # Delete class_advisors (homeroom teachers for this semester)
        cursor.execute("DELETE FROM class_advisors WHERE term = ? AND year = ?;", (term, year))
        advisors_deleted = cursor.rowcount

        # Delete daily_attendance and daily_attendance_config for this semester
        cursor.execute("DELETE FROM daily_attendance WHERE term = ? AND year = ?;", (term, year))
        cursor.execute("DELETE FROM daily_attendance_config WHERE term = ? AND year = ?;", (term, year))

        # Clean up orphan students
        cursor.execute("""
            DELETE FROM students 
            WHERE student_id NOT IN (SELECT DISTINCT student_id FROM grades_history)
              AND student_id NOT IN (SELECT DISTINCT student_id FROM class_students);
        """)
        students_cleaned = cursor.rowcount
        conn.commit()

    files_removed = 0
    if delete_files and os.path.exists(outputs_dir):
        out_path = Path(outputs_dir)
        for code in course_codes:
            for f in out_path.glob(f"*{code}*"):
                try:
                    f.unlink()
                    files_removed += 1
                except Exception:
                    pass

    return {
        "status": "success",
        "term": term,
        "year": year,
        "courses_deleted": courses_deleted,
        "grades_deleted": grades_deleted,
        "class_students_deleted": class_students_deleted,
        "advisors_deleted": advisors_deleted,
        "students_cleaned": students_cleaned,
        "files_removed": files_removed,
        "message": f"ลบข้อมูลภาคเรียนที่ {term}/{year} เรียบร้อยแล้ว (ลบ {courses_deleted} รายวิชา, {grades_deleted} ผลการเรียน, {class_students_deleted} รายชื่อนักเรียน, {advisors_deleted} ครูที่ปรึกษา)"
    }


@_reinit_after
def reset_all_data(
    delete_files: bool = False,
    db_path: str = DB_DEFAULT_PATH,
    outputs_dir: str = "outputs"
) -> Dict[str, Any]:
    """
    Reset all student grades, courses, and student records in the database.
    Optionally deletes all generated files in outputs/ except blank templates.
    """
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("DELETE FROM grades_history;")
        grades_deleted = cursor.rowcount
        cursor.execute("DELETE FROM courses;")
        courses_deleted = cursor.rowcount
        cursor.execute("DELETE FROM class_students;")
        cursor.execute("DELETE FROM class_advisors;")
        cursor.execute("DELETE FROM daily_attendance;")
        cursor.execute("DELETE FROM daily_attendance_config;")
        cursor.execute("DELETE FROM students;")
        students_deleted = cursor.rowcount
        conn.commit()

    files_removed = 0
    if delete_files and os.path.exists(outputs_dir):
        out_path = Path(outputs_dir)
        for f in out_path.iterdir():
            if f.is_file() and not f.name.startswith("template_"):
                try:
                    f.unlink()
                    files_removed += 1
                except Exception:
                    pass

    return {
        "status": "success",
        "courses_deleted": courses_deleted,
        "grades_deleted": grades_deleted,
        "students_deleted": students_deleted,
        "files_removed": files_removed,
        "message": f"รีเซ็ตข้อมูลทั้งหมดเรียบร้อยแล้ว (ลบ {courses_deleted} วิชา, {students_deleted} นักเรียน)"
    }


# ==============================================================================
# CLASS ADVISORS (ครูประจำชั้น / ครูที่ปรึกษา) MANAGEMENT
# ==============================================================================

def get_class_advisors(
    term: Optional[str] = None,
    year: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> List[Dict[str, Any]]:
    """Retrieve all class advisors, optionally filtered by term and year."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        if term and year:
            cursor.execute(
                """
                SELECT id, term, year, class_level, advisor1, advisor2, advisor3, updated_at
                FROM class_advisors
                WHERE term = ? AND year = ?
                ORDER BY class_level ASC;
                """,
                (str(term), str(year))
            )
        else:
            cursor.execute(
                """
                SELECT id, term, year, class_level, advisor1, advisor2, advisor3, updated_at
                FROM class_advisors
                ORDER BY year DESC, term DESC, class_level ASC;
                """
            )
        rows = cursor.fetchall()
        return [dict(r) for r in rows]


def get_advisor_for_class(
    term: str,
    year: str,
    class_level: str,
    db_path: str = DB_DEFAULT_PATH
) -> Optional[Dict[str, Any]]:
    """
    Find advisors for a class level with smart fallback:
    1. Exact (term, year, class_level)
    2. Normalize class_level (e.g. 'ม.1/1' -> 'ม.1')
    3. Same year, other term (year, class_level)
    4. Any latest year for class_level
    """
    if not class_level:
        return None

    init_db(db_path)
    clean_lvl = class_level.strip()
    m = re.search(r"ม\.?\s*([1-6])", clean_lvl)
    base_lvl = f"ม.{m.group(1)}" if m else clean_lvl

    with get_connection(db_path) as conn:
        cursor = conn.cursor()

        # 1. Exact match for current term & year
        cursor.execute(
            """
            SELECT * FROM class_advisors
            WHERE term = ? AND year = ? AND (class_level = ? OR class_level = ?);
            """,
            (str(term), str(year), clean_lvl, base_lvl)
        )
        row = cursor.fetchone()
        if row:
            return dict(row)

        # 2. Same year, any term
        cursor.execute(
            """
            SELECT * FROM class_advisors
            WHERE year = ? AND (class_level = ? OR class_level = ?)
            ORDER BY term DESC;
            """,
            (str(year), clean_lvl, base_lvl)
        )
        row = cursor.fetchone()
        if row:
            return dict(row)

        # 3. Any available year (latest first)
        cursor.execute(
            """
            SELECT * FROM class_advisors
            WHERE (class_level = ? OR class_level = ?)
            ORDER BY year DESC, term DESC;
            """,
            (clean_lvl, base_lvl)
        )
        row = cursor.fetchone()
        if row:
            return dict(row)

    return None


def upsert_class_advisor(
    term: str,
    year: str,
    class_level: str,
    advisor1: str = "",
    advisor2: str = "",
    advisor3: str = "",
    db_path: str = DB_DEFAULT_PATH
) -> int:
    """Insert or update a class advisor record."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            INSERT INTO class_advisors (term, year, class_level, advisor1, advisor2, advisor3, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(term, year, class_level) DO UPDATE SET
                advisor1 = excluded.advisor1,
                advisor2 = excluded.advisor2,
                advisor3 = excluded.advisor3,
                updated_at = CURRENT_TIMESTAMP;
            """,
            (
                str(term).strip(),
                str(year).strip(),
                class_level.strip(),
                (advisor1 or "").strip(),
                (advisor2 or "").strip(),
                (advisor3 or "").strip()
            )
        )
        rowid = cursor.lastrowid
        # A level with a single room (class_rooms from the import form): that room's advisors follow this screen
        rooms = cursor.execute(
            "SELECT id FROM class_rooms WHERE term = ? AND year = ? AND class_level = ?;",
            (str(term).strip(), str(year).strip(), class_level.strip())
        ).fetchall()
        if len(rooms) == 1:
            cursor.execute(
                "UPDATE class_rooms SET advisor1 = ?, advisor2 = ?, advisor3 = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?;",
                ((advisor1 or "").strip(), (advisor2 or "").strip(), (advisor3 or "").strip(), rooms[0]["id"])
            )
        conn.commit()
        return rowid


@_reinit_after
def delete_class_advisor(advisor_id: int, db_path: str = DB_DEFAULT_PATH) -> bool:
    """Delete a class advisor record by ID."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("DELETE FROM class_advisors WHERE id = ?;", (advisor_id,))
        conn.commit()
        return cursor.rowcount > 0


def bulk_upsert_class_advisors(
    term: str,
    year: str,
    items: List[Dict[str, Any]],
    db_path: str = DB_DEFAULT_PATH
) -> int:
    """Bulk insert or update class advisors for a semester."""
    init_db(db_path)
    count = 0
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        for it in items:
            cl = (it.get("class_level") or it.get("level") or "").strip()
            if not cl:
                continue
            a1 = (it.get("advisor1") or "").strip()
            a2 = (it.get("advisor2") or "").strip()
            a3 = (it.get("advisor3") or "").strip()
            cursor.execute(
                """
                INSERT INTO class_advisors (term, year, class_level, advisor1, advisor2, advisor3, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(term, year, class_level) DO UPDATE SET
                    advisor1 = excluded.advisor1,
                    advisor2 = excluded.advisor2,
                    advisor3 = excluded.advisor3,
                    updated_at = CURRENT_TIMESTAMP;
                """,
                (str(term).strip(), str(year).strip(), cl, a1, a2, a3)
            )
            count += 1
        conn.commit()
    return count


def copy_class_advisors_from_semester(
    from_term: str,
    from_year: str,
    to_term: str,
    to_year: str,
    db_path: str = DB_DEFAULT_PATH
) -> int:
    """Copy all class advisors from one semester to another."""
    init_db(db_path)
    source_items = get_class_advisors(term=from_term, year=from_year, db_path=db_path)
    if not source_items:
        return 0
    return bulk_upsert_class_advisors(term=to_term, year=to_year, items=source_items, db_path=db_path)


# ==============================================================================
# MASTER SCHOOL TEACHERS ROSTER
# ==============================================================================

def get_school_teachers(db_path: str = DB_DEFAULT_PATH) -> List[str]:
    """Retrieve all teachers from school_teachers table, sorted Thai alphabetical."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT name FROM school_teachers ORDER BY name COLLATE NOCASE ASC;")
        rows = cursor.fetchall()
        teachers = [r["name"].strip() for r in rows if r["name"] and r["name"].strip()]
        
        # Auto-seed if empty
        if not teachers:
            sync_school_teachers_from_system(db_path)
            cursor.execute("SELECT name FROM school_teachers ORDER BY name COLLATE NOCASE ASC;")
            rows = cursor.fetchall()
            teachers = [r["name"].strip() for r in rows if r["name"] and r["name"].strip()]

        return teachers


def get_school_teachers_with_code(db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """Retrieve all teachers with their id, name, code, and login_pin from school_teachers table."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        # Ensure login_pin column exists
        try:
            cursor.execute("SELECT id, name, code, login_pin FROM school_teachers ORDER BY code ASC, name COLLATE NOCASE ASC;")
        except Exception:
            cursor.execute("ALTER TABLE school_teachers ADD COLUMN login_pin TEXT;")
            cursor.execute("UPDATE school_teachers SET login_pin = code WHERE login_pin IS NULL;")
            conn.commit()
            cursor.execute("SELECT id, name, code, login_pin FROM school_teachers ORDER BY code ASC, name COLLATE NOCASE ASC;")
        rows = cursor.fetchall()
        return [
            {
                "id": r["id"],
                "name": r["name"].strip(),
                "code": (r["code"] or "").strip(),
                "login_pin": (r["login_pin"] if r["login_pin"] is not None and str(r["login_pin"]).strip() else (r["code"] or "")).strip()
            }
            for r in rows if r["name"] and r["name"].strip()
        ]


def add_school_teacher(name: str, code: Optional[str] = None, login_pin: Optional[str] = None, db_path: str = DB_DEFAULT_PATH) -> bool:
    """Add a new teacher with optional code and login_pin to the school_teachers table."""
    init_db(db_path)
    clean = name.strip()
    if not clean or clean == "-":
        return False
    c_code = code.strip() if code and code.strip() else None
    c_pin = str(login_pin).strip() if login_pin and str(login_pin).strip() else (c_code or None)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("INSERT OR IGNORE INTO school_teachers (name, code, login_pin) VALUES (?, ?, ?);", (clean, c_code, c_pin))
        if cursor.rowcount == 0 and (c_code or c_pin):
            # If name exists, update the code and login_pin
            cursor.execute("UPDATE school_teachers SET code = COALESCE(?, code), login_pin = COALESCE(?, login_pin) WHERE name = ?;", (c_code, c_pin, clean))
        conn.commit()
        return True


def update_school_teacher(
    teacher_id: int,
    name: str,
    code: Optional[str] = None,
    login_pin: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> bool:
    """Update an existing teacher's name, code, and optional login_pin."""
    init_db(db_path)
    clean = name.strip()
    if not clean:
        return False
    c_code = code.strip() if code and code.strip() else None
    c_pin = str(login_pin).strip() if login_pin is not None and str(login_pin).strip() else None
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        if c_pin is not None:
            cursor.execute("UPDATE school_teachers SET name = ?, code = ?, login_pin = ? WHERE id = ?;", (clean, c_code, c_pin, teacher_id))
        else:
            cursor.execute("UPDATE school_teachers SET name = ?, code = ? WHERE id = ?;", (clean, c_code, teacher_id))
        conn.commit()
        return cursor.rowcount > 0


def update_teacher_login_pin(teacher_code: str, new_pin: str, db_path: str = DB_DEFAULT_PATH) -> Tuple[bool, str]:
    """Update a teacher's login PIN (1 to 6 digits)."""
    init_db(db_path)
    clean_code = str(teacher_code).strip()
    clean_pin = str(new_pin).strip()
    if not clean_code:
        return False, "ไม่พบรหัสครู"
    import re
    if not re.match(r"^\d{1,6}$", clean_pin):
        return False, "รหัสใช้งานต้องเป็นตัวเลขความยาวไม่เกิน 6 หลัก (1-6 ตัวเลข)"

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("UPDATE school_teachers SET login_pin = ? WHERE code = ?;", (clean_pin, clean_code))
        updated = cursor.rowcount > 0
        conn.commit()
        if updated:
            return True, f"เปลี่ยนรหัสใช้งานของรหัสครู {clean_code} เป็น '{clean_pin}' เรียบร้อยแล้ว"
        else:
            return False, f"ไม่พบบัญชีครูรหัส {clean_code}"


def bulk_add_school_teachers(names: List[str], db_path: str = DB_DEFAULT_PATH) -> int:
    """Bulk add multiple teacher names to the school_teachers table."""
    init_db(db_path)
    added = 0
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        for n in names:
            clean = n.strip()
            if clean and clean != "-":
                cursor.execute("INSERT OR IGNORE INTO school_teachers (name) VALUES (?);", (clean,))
                if cursor.rowcount > 0:
                    added += 1
        conn.commit()
    return added


def delete_school_teacher(name_or_id: Any, db_path: str = DB_DEFAULT_PATH) -> bool:
    """Delete a teacher from school_teachers table by ID or by name."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        if isinstance(name_or_id, int) or (isinstance(name_or_id, str) and name_or_id.isdigit()):
            cursor.execute("DELETE FROM school_teachers WHERE id = ?;", (int(name_or_id),))
        else:
            clean = str(name_or_id).strip()
            if not clean:
                return False
            cursor.execute("DELETE FROM school_teachers WHERE name = ?;", (clean,))
        conn.commit()
        return cursor.rowcount > 0


def sync_school_teachers_from_system(db_path: str = DB_DEFAULT_PATH) -> int:
    """
    Harvests teacher names from SCHOOL_TEACHERS_ROSTER, courses table,
    and class_advisors table into the school_teachers table.
    """
    init_db(db_path)
    candidates = set()
    for full_name in SCHOOL_TEACHERS_ROSTER.values():
        if full_name and full_name.strip():
            candidates.add(full_name.strip())

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        try:
            for r in cursor.execute("SELECT DISTINCT teacher FROM courses WHERE teacher IS NOT NULL;").fetchall():
                t = r["teacher"]
                if t and t.strip() and t.strip() != "-":
                    candidates.add(t.strip())
        except Exception:
            pass

        try:
            for q in ["advisor1", "advisor2", "advisor3"]:
                for r in cursor.execute(f"SELECT DISTINCT {q} FROM class_advisors WHERE {q} IS NOT NULL;").fetchall():
                    t = r[q]
                    if t and t.strip() and t.strip() != "-":
                        candidates.add(t.strip())
        except Exception:
            pass

        added = 0
        for name in sorted(candidates):
            cursor.execute("INSERT OR IGNORE INTO school_teachers (name) VALUES (?);", (name,))
            if cursor.rowcount > 0:
                added += 1
        conn.commit()
        return added


# ==============================================================================
# SCHOOL SIGNATORIES (ข้อมูลผู้ลงนามและผู้บริหาร หน้าปก ปพ.5)
# ==============================================================================

DEFAULT_SIGNATORIES = school_profile.default_signatories()

def get_school_signatories(year: Optional[str] = None, db_path: str = DB_DEFAULT_PATH) -> Dict[str, Any]:
    """
    Retrieve school signatories for a specific academic year.
    If year not found, falls back to latest configured year or defaults.
    """
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        row = None
        if year and str(year).strip():
            cursor.execute("SELECT * FROM school_signatories WHERE year = ? LIMIT 1;", (str(year).strip(),))
            row = cursor.fetchone()

        if not row:
            # Fallback to latest year
            cursor.execute("SELECT * FROM school_signatories ORDER BY year DESC LIMIT 1;")
            row = cursor.fetchone()

        # Available years list
        cursor.execute("SELECT DISTINCT year FROM school_signatories ORDER BY year DESC;")
        y_rows = cursor.fetchall()
        avail_years = [r["year"] for r in y_rows] if y_rows else ["2569", "2568", "2567"]
        if year and str(year).strip() not in avail_years:
            avail_years.append(str(year).strip())
            avail_years.sort(reverse=True)

        if row:
            d = dict(row)
            dept_heads_raw = d.get("dept_heads_json") or "{}"
            try:
                dept_heads = json.loads(dept_heads_raw) if isinstance(dept_heads_raw, str) else dept_heads_raw
            except Exception:
                dept_heads = {}
            return {
                "year": str(year).strip() if (year and str(year).strip()) else d.get("year", "2568"),
                "school_name": d.get("school_name") or DEFAULT_SIGNATORIES["school_name"],
                "director_name": d.get("director_name") or DEFAULT_SIGNATORIES["director_name"],
                "director_title": d.get("director_title") or DEFAULT_SIGNATORIES["director_title"],
                "academic_head_name": d.get("academic_head_name") or DEFAULT_SIGNATORIES["academic_head_name"],
                "academic_head_title": d.get("academic_head_title") or DEFAULT_SIGNATORIES["academic_head_title"],
                "registrar_name": d.get("registrar_name") or DEFAULT_SIGNATORIES["registrar_name"],
                "registrar_title": d.get("registrar_title") or DEFAULT_SIGNATORIES["registrar_title"],
                "dept_head_default": d.get("dept_head_default") or DEFAULT_SIGNATORIES["dept_head_default"],
                "dept_heads": dept_heads,
                "available_years": avail_years,
                "updated_at": d.get("updated_at")
            }

        res = dict(DEFAULT_SIGNATORIES)
        res["year"] = str(year).strip() if (year and str(year).strip()) else "2568"
        res["available_years"] = avail_years
        return res


def get_all_school_signatories(db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """Retrieve all configured years of school signatories."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM school_signatories ORDER BY year DESC;")
        rows = cursor.fetchall()
        result = []
        for r in rows:
            d = dict(r)
            dept_heads_raw = d.get("dept_heads_json") or "{}"
            try:
                dept_heads = json.loads(dept_heads_raw) if isinstance(dept_heads_raw, str) else dept_heads_raw
            except Exception:
                dept_heads = {}
            d["dept_heads"] = dept_heads
            result.append(d)
        return result


def upsert_school_signatories(data: Dict[str, Any], db_path: str = DB_DEFAULT_PATH) -> Dict[str, Any]:
    """Create or update school signatories for a specific academic year."""
    init_db(db_path)
    year = str(data.get("year", "")).strip()
    if not year:
        raise ValueError("Academic year is required.")

    director_name = normalize_teacher_name(data.get("director_name", "") or "")
    director_title = str(data.get("director_title", "") or DEFAULT_SIGNATORIES["director_title"]).strip()
    academic_head_name = normalize_teacher_name(data.get("academic_head_name", "") or "")
    academic_head_title = str(data.get("academic_head_title", "") or DEFAULT_SIGNATORIES["academic_head_title"]).strip()
    registrar_name = normalize_teacher_name(data.get("registrar_name", "") or "")
    registrar_title = str(data.get("registrar_title", "") or DEFAULT_SIGNATORIES["registrar_title"]).strip()
    dept_head_default = normalize_teacher_name(data.get("dept_head_default", "") or "")
    school_name = str(data.get("school_name", "") or DEFAULT_SIGNATORIES["school_name"]).strip()

    dept_heads = data.get("dept_heads") or {}
    if isinstance(dept_heads, dict):
        clean_dept_heads = {k.strip(): normalize_teacher_name(v) for k, v in dept_heads.items() if k.strip() and v and v.strip()}
        dept_heads_json = json.dumps(clean_dept_heads, ensure_ascii=False)
    elif isinstance(dept_heads, str):
        dept_heads_json = dept_heads
    else:
        dept_heads_json = "{}"

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            INSERT INTO school_signatories (
                year, director_name, director_title,
                academic_head_name, academic_head_title,
                registrar_name, registrar_title,
                dept_head_default, dept_heads_json, school_name,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(year) DO UPDATE SET
                director_name = excluded.director_name,
                director_title = excluded.director_title,
                academic_head_name = excluded.academic_head_name,
                academic_head_title = excluded.academic_head_title,
                registrar_name = excluded.registrar_name,
                registrar_title = excluded.registrar_title,
                dept_head_default = excluded.dept_head_default,
                dept_heads_json = excluded.dept_heads_json,
                school_name = excluded.school_name,
                updated_at = CURRENT_TIMESTAMP;
            """,
            (
                year, director_name, director_title,
                academic_head_name, academic_head_title,
                registrar_name, registrar_title,
                dept_head_default, dept_heads_json, school_name
            )
        )
        conn.commit()

    # Automatically add any new teachers into school_teachers roster
    for t_name in [director_name, academic_head_name, registrar_name, dept_head_default]:
        if t_name:
            add_school_teacher(t_name, db_path=db_path)
    if isinstance(dept_heads, dict):
        for t_name in dept_heads.values():
            if t_name:
                add_school_teacher(t_name, db_path=db_path)

    return get_school_signatories(year=year, db_path=db_path)


def copy_school_signatories(from_year: str, to_year: str, db_path: str = DB_DEFAULT_PATH) -> Dict[str, Any]:
    """Copy school signatories from one academic year to another."""
    source = get_school_signatories(year=from_year, db_path=db_path)
    source["year"] = str(to_year).strip()
    return upsert_school_signatories(source, db_path=db_path)


# -------------------------------------------------------------------------
# APPLICATION GENERAL SETTINGS (e.g. School Logo, School Information)
# -------------------------------------------------------------------------

def get_app_setting(key: str, default: str = "", db_path: str = DB_DEFAULT_PATH) -> str:
    """Retrieve general system setting by key."""
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT value FROM app_settings WHERE key = ? LIMIT 1;", (key,))
        row = cursor.fetchone()
        return str(row["value"]) if row and row["value"] is not None else default


def set_app_setting(key: str, value: str, db_path: str = DB_DEFAULT_PATH) -> None:
    """Set general system setting by key."""
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO app_settings (key, value, updated_at)
            VALUES (?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP;
        """, (key, value))
        conn.commit()


def resolve_signatories_for_course(
    course_code: str,
    year: str,
    dept_name: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, str]:
    """
    Resolve specific names and titles for a course's cover sheet.
    """
    sigs = get_school_signatories(year=year, db_path=db_path)
    dept_heads = sigs.get("dept_heads") or {}

    dept_head_name = ""
    # Try explicit dept_name match
    if dept_name and dept_name in dept_heads and dept_heads[dept_name]:
        dept_head_name = dept_heads[dept_name]

    # Try mapping prefix
    if not dept_head_name and course_code:
        prefix = course_code[0]
        prefix_dept_map = {
            "ค": "คณิตศาสตร์",
            "ว": "วิทยาศาสตร์และเทคโนโลยี",
            "ท": "ภาษาไทย",
            "ส": "สังคมศึกษา ศาสนา และวัฒนธรรม",
            "ง": "การงานอาชีพ",
            "ศ": "ศิลปะ",
            "พ": "สุขศึกษาและพลศึกษา",
            "อ": "ภาษาต่างประเทศ",
            "จ": "ภาษาต่างประเทศ",
            "ญ": "ภาษาต่างประเทศ",
            "ฝ": "ภาษาต่างประเทศ",
            "ก": "กิจกรรมพัฒนาผู้เรียน",
        }
        mapped_dept = prefix_dept_map.get(prefix)
        if mapped_dept and mapped_dept in dept_heads and dept_heads[mapped_dept]:
            dept_head_name = dept_heads[mapped_dept]

    if not dept_head_name:
        dept_head_name = sigs.get("dept_head_default") or DEFAULT_SIGNATORIES["dept_head_default"]

    return {
        "school_name": sigs.get("school_name") or DEFAULT_SIGNATORIES["school_name"],
        "director_name": sigs.get("director_name") or DEFAULT_SIGNATORIES["director_name"],
        "director_title": sigs.get("director_title") or DEFAULT_SIGNATORIES["director_title"],
        "academic_head_name": sigs.get("academic_head_name") or DEFAULT_SIGNATORIES["academic_head_name"],
        "academic_head_title": sigs.get("academic_head_title") or DEFAULT_SIGNATORIES["academic_head_title"],
        "registrar_name": sigs.get("registrar_name") or DEFAULT_SIGNATORIES["registrar_name"],
        "registrar_title": sigs.get("registrar_title") or DEFAULT_SIGNATORIES["registrar_title"],
        "dept_head_name": dept_head_name,
        "dept_head_title": "หัวหน้ากลุ่มสาระการเรียนรู้"
    }


# ==============================================================================
# DAILY SCHOOL ATTENDANCE (ระบบเช็คเวลาเรียนรวมประจำวัน)
# ==============================================================================

def infer_class_level(course_code: str, class_level_hint: str = "") -> str:
    """Infer Thai class level (e.g. ม.1, ม.2, ..., ม.6) from hint or course code."""
    if class_level_hint and str(class_level_hint).strip() != "#N/A":
        m = re.search(r"ม\.?\s*([1-6](?:\/\d+)?)", str(class_level_hint))
        if m:
            return f"ม.{m.group(1)}"
        m_num = re.search(r"\b([1-6])\b", str(class_level_hint))
        if m_num:
            return f"ม.{m_num.group(1)}"
    if course_code:
        m = re.search(r"[ก-ฮa-zA-Z](\d)(\d)", course_code)
        if m:
            d1, d2 = m.group(1), m.group(2)
            if d1 == "2":
                return f"ม.{d2}"
            elif d1 == "3":
                num = int(d2) + 3
                if 4 <= num <= 6:
                    return f"ม.{num}"
    return class_level_hint or ""


def get_class_levels_for_semester(term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> List[str]:
    """Return available class levels (e.g. ['ม.1', 'ม.2', ..., 'ม.6']) for term and year."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT DISTINCT c.course_code
            FROM courses c
            JOIN grades_history g ON c.course_code = g.course_code AND c.term = g.term AND c.year = g.year
            WHERE g.term = ? AND g.year = ?;
            """,
            (str(term).strip(), str(year).strip())
        )
        levels = set()
        for r in cursor.fetchall():
            lvl = infer_class_level(r["course_code"], "")
            if lvl:
                levels.add(lvl)
        standard_order = ["ม.1", "ม.2", "ม.3", "ม.4", "ม.5", "ม.6"]
        sorted_lvls = [lvl for lvl in standard_order if lvl in levels]
        for lvl in sorted(levels):
            if lvl not in sorted_lvls:
                sorted_lvls.append(lvl)
        return sorted_lvls or standard_order


def get_students_for_class_level(term: str, year: str, class_level: str, db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """Retrieve distinct students in a class level for a given semester."""
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT DISTINCT s.student_id, s.full_name, c.course_code
            FROM students s
            JOIN grades_history g ON s.student_id = g.student_id
            JOIN courses c ON g.course_code = c.course_code AND g.term = c.term AND g.year = c.year
            WHERE g.term = ? AND g.year = ?;
            """,
            (str(term).strip(), str(year).strip())
        )
        matched_students = {}
        for r in cursor.fetchall():
            lvl = infer_class_level(r["course_code"], "")
            if lvl == class_level or (class_level == "ทั้งหมด"):
                sid = r["student_id"]
                if sid not in matched_students:
                    matched_students[sid] = r["full_name"]

        res = []
        for idx, (sid, name) in enumerate(sorted(matched_students.items(), key=lambda x: x[0]), start=1):
            res.append({
                "student_no": idx,
                "student_id": sid,
                "full_name": name
            })
        return res


def get_daily_attendance_records(
    term: str,
    year: str,
    class_level: str,
    date_str: str,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Retrieve attendance records for a class level on date_str (YYYY-MM-DD).
    Defaults students without records to 'present' (มาเรียน).
    """
    init_db(db_path)
    students = get_students_for_class_level(term, year, class_level, db_path=db_path)

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT student_id, status, note
            FROM daily_attendance
            WHERE attendance_date = ? AND term = ? AND year = ?;
            """,
            (date_str, str(term).strip(), str(year).strip())
        )
        existing = {r["student_id"]: {"status": r["status"], "note": r["note"] or ""} for r in cursor.fetchall()}

    present_count = 0
    absent_count = 0
    leave_count = 0
    late_count = 0

    student_records = []
    for s in students:
        sid = s["student_id"]
        rec = existing.get(sid)
        status = rec["status"] if rec else "present"
        note = rec["note"] if rec else ""

        if status == "present":
            present_count += 1
        elif status == "absent":
            absent_count += 1
        elif status == "leave":
            leave_count += 1
        elif status == "late":
            present_count += 1  # จากตารางเรียนรวม สาย ให้นับ เป็น มา ในวันนั้น
            late_count += 1

        student_records.append({
            "student_no": s["student_no"],
            "student_id": sid,
            "full_name": s["full_name"],
            "status": status,
            "note": note
        })

    total = len(student_records)
    pct = round((present_count / total * 100), 1) if total > 0 else 100.0

    return {
        "date": date_str,
        "term": str(term).strip(),
        "year": str(year).strip(),
        "class_level": class_level,
        "total_students": total,
        "present_count": present_count,
        "absent_count": absent_count,
        "leave_count": leave_count,
        "late_count": late_count,
        "attendance_percentage": pct,
        "is_recorded": len(existing) > 0,
        "students": student_records
    }


def save_daily_attendance_batch(
    term: str,
    year: str,
    class_level: str,
    date_str: str,
    records: List[Dict[str, Any]],
    db_path: str = DB_DEFAULT_PATH
) -> int:
    """Save daily attendance records for a class on a specific date (future dates are not stored),
    then carry them into every course of the class like the 20-week grid does."""
    init_db(db_path)
    count = 0
    saved_ids: List[str] = []
    if str(date_str).strip()[:10] > attendance_rules.today_iso():
        return 0
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        for r in records:
            sid = str(r.get("student_id", "")).strip()
            if not sid:
                continue
            saved_ids.append(sid)
            status = str(r.get("status", "present")).strip()
            note = str(r.get("note", "")).strip()
            cursor.execute(
                """
                INSERT INTO daily_attendance (
                    attendance_date, term, year, class_level, student_id, status, note, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(attendance_date, student_id) DO UPDATE SET
                    term = excluded.term,
                    year = excluded.year,
                    class_level = excluded.class_level,
                    status = excluded.status,
                    note = excluded.note,
                    updated_at = CURRENT_TIMESTAMP;
                """,
                (date_str, str(term).strip(), str(year).strip(), class_level, sid, status, note)
            )
            count += 1
        conn.commit()
    if saved_ids:
        try:
            sync_daily_attendance_to_courses(term, year, class_level, student_ids=saved_ids, db_path=db_path)
        except Exception as _e_sync:
            print(f"[WARN] Error syncing daily attendance to courses: {_e_sync}")
    return count


def get_daily_attendance_school_summary(
    term: str,
    year: str,
    date_str: str,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """Retrieve school-wide attendance overview by class levels for date_str."""
    levels = get_class_levels_for_semester(term, year, db_path=db_path)
    class_summaries = []
    tot_students = 0
    tot_present = 0
    tot_absent = 0
    tot_leave = 0
    tot_late = 0

    for lvl in levels:
        s = get_daily_attendance_records(term, year, lvl, date_str, db_path=db_path)
        class_summaries.append({
            "class_level": lvl,
            "total_students": s["total_students"],
            "present_count": s["present_count"],
            "absent_count": s["absent_count"],
            "leave_count": s["leave_count"],
            "late_count": s["late_count"],
            "attendance_percentage": s["attendance_percentage"],
            "is_recorded": s["is_recorded"]
        })
        tot_students += s["total_students"]
        tot_present += s["present_count"]
        tot_absent += s["absent_count"]
        tot_leave += s["leave_count"]
        tot_late += s["late_count"]

    tot_pct = round((tot_present / tot_students * 100), 1) if tot_students > 0 else 100.0

    return {
        "date": date_str,
        "term": str(term).strip(),
        "year": str(year).strip(),
        "total_students": tot_students,
        "present_count": tot_present,
        "absent_count": tot_absent,
        "leave_count": tot_leave,
        "late_count": tot_late,
        "attendance_percentage": tot_pct,
        "class_summaries": class_summaries
    }


def get_daily_attendance_dates_map(
    student_ids: List[str],
    dates: List[str],
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Dict[str, str]]:
    """
    Mapping of { student_id: { "YYYY-MM-DD": "present"|"absent"|"leave"|"late" } }
    Used to auto-populate course attendance for PorPor5.
    """
    if not student_ids or not dates:
        return {}

    init_db(db_path)
    result = {sid: {} for sid in student_ids}

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        chunk_size = 50
        for i in range(0, len(student_ids), chunk_size):
            s_chunk = student_ids[i:i + chunk_size]
            s_placeholders = ",".join("?" * len(s_chunk))
            d_placeholders = ",".join("?" * len(dates))
            params = s_chunk + dates

            cursor.execute(
                f"""
                SELECT student_id, attendance_date, status
                FROM daily_attendance
                WHERE student_id IN ({s_placeholders}) AND attendance_date IN ({d_placeholders});
                """,
                params
            )
            for r in cursor.fetchall():
                sid = r["student_id"]
                dt = r["attendance_date"]
                st = r["status"]
                if sid in result:
                    result[sid][dt] = st

    return result


def get_daily_attendance_records_map(
    student_ids: List[str],
    dates: List[str],
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Dict[str, Tuple[str, Optional[str]]]]:
    """Like get_daily_attendance_dates_map, but keeps the note so a late arrival ("มาคาบ N") can be applied per course."""
    result: Dict[str, Dict[str, Tuple[str, Optional[str]]]] = {sid: {} for sid in student_ids}
    if not student_ids or not dates:
        return result
    lo, hi = min(dates), max(dates)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        for i in range(0, len(student_ids), 500):
            chunk = student_ids[i:i + 500]
            cursor.execute(
                f"""
                SELECT student_id, attendance_date, status, note
                FROM daily_attendance
                WHERE attendance_date BETWEEN ? AND ? AND student_id IN ({",".join("?" * len(chunk))});
                """,
                [lo, hi] + chunk
            )
            for r in cursor.fetchall():
                result[r["student_id"]][r["attendance_date"]] = (r["status"], r["note"])
    return result


def get_class_students(term: str, year: str, class_level: str, room: Optional[str] = None, db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """
    Retrieve distinct active students in a class level (or all levels if class_level in ('all', 'ทั้งหมด')) for a given semester.
    If room is specified, filters by room.
    If class_students table is empty for this semester/level, auto-migrates from grades_history.
    """
    init_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        query = """
            SELECT student_no, student_id, full_name, class_level, room, is_active, is_locked, note
            FROM class_students
            WHERE term = ? AND year = ? AND is_active = 1
        """
        params = [str(term).strip(), str(year).strip()]
        is_all_levels = not class_level or str(class_level).strip() in ("all", "ทั้งหมด")
        if not is_all_levels:
            query += " AND class_level = ?"
            params.append(str(class_level).strip())
        if room and str(room).strip() not in ("", "all", "ทั้งหมด", "null"):
            query += " AND room = ?"
            params.append(str(room).strip())
        query += " ORDER BY class_level, CAST(room AS INTEGER), student_no, student_id;"
        cursor.execute(query, params)
        rows = cursor.fetchall()
        if rows:
            return [
                {
                    "student_no": r["student_no"],
                    "student_id": r["student_id"],
                    "full_name": r["full_name"],
                    "class_level": r["class_level"] if "class_level" in r.keys() else class_level,
                    "room": r["room"] or "1",
                    "is_active": r["is_active"],
                    "is_locked": bool(r["is_locked"]) if "is_locked" in r.keys() else False,
                    "note": r["note"] or ""
                }
                for r in rows
            ]

        # Auto-migrate from grades_history if not present yet and specific level requested
        if not is_all_levels:
            legacy = get_students_for_class_level(term, year, class_level, db_path=db_path)
            for s in legacy:
                cursor.execute(
                    """
                    INSERT OR IGNORE INTO class_students (term, year, class_level, student_id, student_no, full_name, room, is_active)
                    VALUES (?, ?, ?, ?, ?, ?, '1', 1);
                    """,
                    (str(term).strip(), str(year).strip(), str(class_level).strip(), s["student_id"], s["student_no"], s["full_name"])
                )
            conn.commit()
            return legacy
        return []


def add_class_student(
    term: str,
    year: str,
    class_level: str,
    student_id: str,
    full_name: str,
    student_no: Optional[int] = None,
    room: str = "1",
    note: str = "",
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """Add or transfer student into class level with optional room."""
    init_db(db_path)
    sid = str(student_id).strip()
    name = re.sub(r"\s+", " ", str(full_name or "")).strip()
    t = str(term).strip()
    y = str(year).strip()
    cl = str(class_level).strip()
    rm = str(room or "1").strip()
    # คำนำหน้า / ชื่อ / นามสกุล ลงช่องของตัวเองทันที (ไม่รอ backfill) และลงแถว DMC ด้วย
    n_prefix, n_first, n_last = split_full_name(name)
    if n_first:
        name = compose_full_name(n_prefix, n_first, n_last)

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        # 1. Ensure in students master table
        cursor.execute(
            """
            INSERT INTO students (student_id, full_name)
            VALUES (?, ?)
            ON CONFLICT(student_id) DO UPDATE SET full_name = excluded.full_name;
            """,
            (sid, name)
        )

        # 2. Determine student_no if not provided
        if student_no is None:
            cursor.execute(
                "SELECT MAX(student_no) FROM class_students WHERE term = ? AND year = ? AND class_level = ?;",
                (t, y, cl)
            )
            max_no = cursor.fetchone()[0]
            student_no = (max_no or 0) + 1

        # 3. Upsert into class_students
        cursor.execute(
            """
            INSERT INTO class_students (term, year, class_level, student_id, student_no, full_name, room, is_active, note,
                                        prefix, first_name, last_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
            ON CONFLICT(term, year, class_level, student_id) DO UPDATE SET
                student_no = excluded.student_no,
                full_name = excluded.full_name,
                prefix = excluded.prefix,
                first_name = excluded.first_name,
                last_name = excluded.last_name,
                room = excluded.room,
                is_active = 1,
                note = excluded.note,
                updated_at = CURRENT_TIMESTAMP;
            """,
            (t, y, cl, sid, int(student_no), name, rm, str(note or "").strip(), n_prefix, n_first, n_last)
        )
        if n_first:
            sync_dmc_name_row(conn, sid, n_prefix, n_first, n_last, class_level=cl, room=rm)
        conn.commit()

    return {
        "status": "success",
        "message": f"เพิ่มนักเรียน {name} ({sid}) เข้าชั้น {cl} ห้อง {rm} สำเร็จ",
        "student": {
            "student_no": student_no,
            "student_id": sid,
            "full_name": name,
            "room": rm,
            "note": note
        }
    }


def toggle_class_student_lock(
    term: str,
    year: str,
    class_level: str,
    student_id: str,
    locked: Optional[bool] = None,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Toggle or explicitly set student lock status in a class level.
    Locked students are excluded from attendance calculations and suppressed in PorPor5.
    """
    init_db(db_path)
    t = str(term).strip()
    y = str(year).strip()
    cl = str(class_level).strip()
    sid = str(student_id).strip()

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        if locked is None:
            cursor.execute(
                """
                UPDATE class_students
                SET is_locked = CASE WHEN is_locked = 1 THEN 0 ELSE 1 END,
                    updated_at = CURRENT_TIMESTAMP
                WHERE term = ? AND year = ? AND class_level = ? AND student_id = ?;
                """,
                (t, y, cl, sid)
            )
        else:
            val = 1 if locked else 0
            cursor.execute(
                """
                UPDATE class_students
                SET is_locked = ?,
                    updated_at = CURRENT_TIMESTAMP
                WHERE term = ? AND year = ? AND class_level = ? AND student_id = ?;
                """,
                (val, t, y, cl, sid)
            )

        cursor.execute(
            """
            SELECT student_id, full_name, is_locked
            FROM class_students
            WHERE term = ? AND year = ? AND class_level = ? AND student_id = ?;
            """,
            (t, y, cl, sid)
        )
        row = cursor.fetchone()
        conn.commit()

    if not row:
        raise ValueError(f"ไม่พบนักเรียนรหัส {sid} ในชั้น {cl} ภาคเรียนที่ {t}/{y}")

    is_lck = bool(row["is_locked"])
    st_name = row["full_name"]
    status_msg = "ล็อกนักเรียนแล้ว (ไม่นำข้อมูลมาคิดและไม่แสดงใน ปพ.5)" if is_lck else "ปลดล็อกนักเรียนแล้ว (นำกลับมาคิดตามปกติ)"

    return {
        "status": "success",
        "student_id": sid,
        "full_name": st_name,
        "is_locked": is_lck,
        "message": f"{st_name}: {status_msg}"
    }


def remove_class_student(
    term: str,
    year: str,
    class_level: str,
    student_id: str,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """Remove student from class level (marks inactive for transfers)."""
    init_db(db_path)
    sid = str(student_id).strip()
    t = str(term).strip()
    y = str(year).strip()
    cl = str(class_level).strip()

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            UPDATE class_students
            SET is_active = 0, updated_at = CURRENT_TIMESTAMP
            WHERE term = ? AND year = ? AND class_level = ? AND student_id = ?;
            """,
            (t, y, cl, sid)
        )
        conn.commit()

    return {
        "status": "success",
        "message": f"ลบ/ย้ายออกนักเรียนรหัส {sid} จากชั้น {cl} สำเร็จ"
    }


def copy_class_students_from_semester(
    from_term: str,
    from_year: str,
    to_term: str,
    to_year: str,
    from_class_level: Optional[str] = None,
    to_class_level: Optional[str] = None,
    all_levels: bool = False,
    overwrite: bool = False,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Import/copy students from a source semester (and class level) to destination semester.
    Supports either copying a single class level or all 6 levels (ม.1 - ม.6) at once.
    """
    init_db(db_path)
    levels_map = []
    if all_levels:
        for lvl in ["ม.1", "ม.2", "ม.3", "ม.4", "ม.5", "ม.6"]:
            levels_map.append((lvl, lvl))
    else:
        src_lvl = str(from_class_level or "ม.1").strip()
        dst_lvl = str(to_class_level or src_lvl).strip()
        levels_map.append((src_lvl, dst_lvl))

    total_imported = 0
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        for src_lvl, dst_lvl in levels_map:
            source_students = get_class_students(from_term, from_year, src_lvl, db_path=db_path)
            if not source_students:
                continue

            if overwrite:
                cursor.execute(
                    "UPDATE class_students SET is_active = 0 WHERE term = ? AND year = ? AND class_level = ?;",
                    (str(to_term).strip(), str(to_year).strip(), dst_lvl)
                )

            # Determine starting student_no if appending
            cursor.execute(
                "SELECT MAX(student_no) FROM class_students WHERE term = ? AND year = ? AND class_level = ? AND is_active = 1;",
                (str(to_term).strip(), str(to_year).strip(), dst_lvl)
            )
            max_existing_no = cursor.fetchone()[0] or 0

            # Get set of already active student_ids in destination
            cursor.execute(
                "SELECT student_id FROM class_students WHERE term = ? AND year = ? AND class_level = ? AND is_active = 1;",
                (str(to_term).strip(), str(to_year).strip(), dst_lvl)
            )
            existing_sids = {r[0] for r in cursor.fetchall()}

            for idx, s in enumerate(source_students):
                sid = str(s["student_id"]).strip()
                name = str(s["full_name"]).strip()
                if not sid:
                    continue

                if sid in existing_sids and not overwrite:
                    # Skip duplicate if already active
                    continue

                # Ensure in students master table
                cursor.execute(
                    """
                    INSERT INTO students (student_id, full_name)
                    VALUES (?, ?)
                    ON CONFLICT(student_id) DO UPDATE SET full_name = excluded.full_name;
                    """,
                    (sid, name)
                )

                if overwrite:
                    st_no = s.get("student_no") or (idx + 1)
                else:
                    max_existing_no += 1
                    st_no = max_existing_no

                note = f"นำเข้าจาก ภาคเรียนที่ {from_term}/{from_year} ({src_lvl})"
                cursor.execute(
                    """
                    INSERT INTO class_students (term, year, class_level, student_id, student_no, full_name, is_active, note)
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                    ON CONFLICT(term, year, class_level, student_id) DO UPDATE SET
                        student_no = excluded.student_no,
                        full_name = excluded.full_name,
                        is_active = 1,
                        note = excluded.note,
                        updated_at = CURRENT_TIMESTAMP;
                    """,
                    (str(to_term).strip(), str(to_year).strip(), dst_lvl, sid, int(st_no), name, note)
                )
                existing_sids.add(sid)
                total_imported += 1

        conn.commit()

    return {
        "status": "success",
        "imported_count": total_imported,
        "message": f"นำเข้ารายชื่อนักเรียนจากภาคเรียนที่ {from_term}/{from_year} สำเร็จ {total_imported} คน"
    }




def parse_dmc_file(file_content: bytes, filename: str) -> List[Dict[str, Any]]:
    """
    Parse student roster from DMC (Data Management Center) Excel (.xlsx/.xls) or CSV export.
    Dynamically maps columns: class_level, room, student_id, citizen_id, name, surname, gender.
    """
    rows_data: List[List[Any]] = []
    is_excel = filename.lower().endswith((".xlsx", ".xls")) or file_content.startswith(b"PK\x03\x04")

    if is_excel:
        if openpyxl is None:
            raise RuntimeError("openpyxl is not installed. Please install openpyxl to process Excel files.")
        wb = openpyxl.load_workbook(io.BytesIO(file_content), data_only=True)
        ws = wb.active
        for row in ws.iter_rows(values_only=True):
            rows_data.append(list(row))
    else:
        # CSV parsing with encoding fallback
        text_content = None
        for enc in ["utf-8-sig", "utf-8", "cp874", "tis-620"]:
            try:
                text_content = file_content.decode(enc)
                break
            except Exception:
                continue
        if text_content is None:
            text_content = file_content.decode("utf-8", errors="ignore")

        reader = csv.reader(io.StringIO(text_content))
        for row in reader:
            rows_data.append(row)

    if not rows_data:
        raise ValueError("ไฟล์ไม่มีข้อมูล")

    # Locate header row: looks for 'ชั้น' and ('ชื่อ' or 'รหัส' or 'เลขประจำตัว')
    header_row_idx = None
    headers: List[str] = []
    for r_idx, row in enumerate(rows_data[:15]):
        str_vals = [str(c or "").strip() for c in row]
        if any("ชั้น" in v for v in str_vals) and any("ชื่อ" in v or "เลขประจำตัว" in v for v in str_vals):
            header_row_idx = r_idx
            headers = str_vals
            break

    if header_row_idx is None:
        raise ValueError("ไม่พบแถวหัวตารางของไฟล์ DMC (ไม่พบคอลัมน์ 'ชั้น' หรือ 'ชื่อ')")

    # Identify columns
    class_col = None
    room_col = None
    gender_col = None
    prefix_col = None
    name_col = None
    lname_col = None
    fullname_col = None

    for idx, h in enumerate(headers):
        if not h:
            continue
        h_clean = h.replace(" ", "")
        if ("ชั้น" in h_clean or "ระดับชั้น" in h_clean) and class_col is None:
            class_col = idx
        elif "ห้อง" in h_clean and room_col is None:
            room_col = idx
        elif "เพศ" in h_clean and gender_col is None:
            gender_col = idx
        elif "คำนำหน้า" in h_clean and not any(k in h_clean for k in ["ผู้ปกครอง", "บิดา", "มารดา"]) and prefix_col is None:
            prefix_col = idx
        elif h_clean == "ชื่อ" and name_col is None:
            name_col = idx
        elif ("นามสกุล" in h_clean or h_clean == "สกุล") and not any(k in h_clean for k in ["ผู้ปกครอง", "บิดา", "มารดา"]) and lname_col is None:
            lname_col = idx
        elif ("ชื่อ-สกุล" in h_clean or "ชื่อ-นามสกุล" in h_clean or "ชื่อสกุล" in h_clean) and fullname_col is None:
            fullname_col = idx

    # Inspect candidate ID columns using sample data rows
    cid_col = None
    sid_col = None
    candidate_id_cols = []
    for idx, h in enumerate(headers):
        if not h:
            continue
        h_clean = h.replace(" ", "")
        if ("เลขประจำตัว" in h_clean or "รหัส" in h_clean or "citizen" in h.lower()) and "โรงเรียน" not in h_clean:
            candidate_id_cols.append(idx)

    # Check first few data rows to differentiate 13-digit citizen_id vs 4-6 digit student_id
    for r_idx in range(header_row_idx + 1, min(len(rows_data), header_row_idx + 10)):
        row = rows_data[r_idx]
        for c_idx in candidate_id_cols:
            if c_idx < len(row):
                val = str(row[c_idx] or "").strip()
                if len(val) == 13 or val.startswith("G") or "ประชาชน" in headers[c_idx]:
                    if cid_col is None:
                        cid_col = c_idx
                elif val.isdigit() and len(val) <= 6:
                    if sid_col is None:
                        sid_col = c_idx

    parsed_students: List[Dict[str, Any]] = []
    for r_idx in range(header_row_idx + 1, len(rows_data)):
        row = rows_data[r_idx]
        if not row:
            continue

        raw_class = str(row[class_col] or "").strip() if class_col is not None and class_col < len(row) else ""
        if not raw_class or raw_class.lower() == "none":
            continue

        # Normalize class level (e.g. 'ม.1', 'ม.2', 'ป.1'...)
        m_num = re.search(r"([1-6])", raw_class)
        cl_num = m_num.group(1) if m_num else "1"
        if "ป" in raw_class or "ประถม" in raw_class:
            norm_class = f"ป.{cl_num}"
        else:
            norm_class = f"ม.{cl_num}"

        # Room
        raw_room = row[room_col] if room_col is not None and room_col < len(row) else 1
        if isinstance(raw_room, float):
            raw_room = int(raw_room)
        norm_room = str(raw_room or "1").strip()
        if not norm_room or norm_room.lower() == "none":
            norm_room = "1"

        # Student ID
        raw_sid = row[sid_col] if sid_col is not None and sid_col < len(row) else ""
        if isinstance(raw_sid, float):
            raw_sid = int(raw_sid)
        sid_str = str(raw_sid or "").strip()
        if sid_str.isdigit() and len(sid_str) < 5:
            sid_str = sid_str.zfill(5)

        # Citizen ID
        cid_str = str(row[cid_col] or "").strip() if cid_col is not None and cid_col < len(row) else ""

        # Gender
        gender_str = str(row[gender_col] or "").strip() if gender_col is not None and gender_col < len(row) else ""

        # Name
        if fullname_col is not None and fullname_col < len(row) and str(row[fullname_col] or "").strip():
            full_name = str(row[fullname_col]).strip()
        else:
            pfx = str(row[prefix_col] or "").strip() if prefix_col is not None and prefix_col < len(row) else ""
            fname = str(row[name_col] or "").strip() if name_col is not None and name_col < len(row) else ""
            lname = str(row[lname_col] or "").strip() if lname_col is not None and lname_col < len(row) else ""
            if pfx and fname:
                full_name = f"{pfx}{fname} {lname}".strip()
            elif fname:
                full_name = f"{fname} {lname}".strip()
            else:
                full_name = ""

        if not full_name and not sid_str:
            continue

        parsed_students.append({
            "class_level": norm_class,
            "room": norm_room,
            "student_id": sid_str,
            "citizen_id": cid_str,
            "gender": gender_str,
            "full_name": full_name
        })

    return parsed_students


def _same_name(a: Any, b: Any) -> bool:
    return str(a or "").replace(" ", "") == str(b or "").replace(" ", "")


DMC_COMPARE_KEYS = ("new", "same", "changed", "other_level", "removed", "missing", "no_id")


def compare_dmc_roster(students: List[Dict[str, Any]], term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> Dict[str, List[Dict[str, Any]]]:
    """Sort the students of a DMC file against the roster of this semester (writes nothing).
    new          never on this semester's roster
    same         already in the same class, name and room as in the file
    changed      already in the same class, but the file has another name or room
    other_level  on the roster of another class this semester
    removed      was on this semester's roster but was taken off
    missing      on the roster of a class the file covers, but not in the file
    no_id        file rows without a student ID (cannot be imported)"""
    t, y = str(term).strip(), str(year).strip()
    init_db(db_path)
    with get_connection(db_path) as conn:
        rows = [dict(r) for r in conn.execute(
            """SELECT class_level, student_id, student_no, full_name, room, is_active, is_locked
               FROM class_students WHERE term = ? AND year = ? ORDER BY class_level, student_no;""", (t, y))]
    by_sid: Dict[str, List[Dict[str, Any]]] = {}
    for r in rows:
        by_sid.setdefault(str(r["student_id"]).strip(), []).append(r)
    out: Dict[str, List[Dict[str, Any]]] = {k: [] for k in DMC_COMPARE_KEYS}
    seen = set()
    for s in students:
        sid = s["student_id"]
        item = {"student_id": sid, "full_name": s["full_name"], "class_level": s["class_level"], "room": s["room"]}
        if not sid:
            out["no_id"].append(item)
            continue
        if sid in seen:
            continue
        seen.add(sid)
        mine = by_sid.get(sid, [])
        active = [r for r in mine if r["is_active"]]
        here = next((r for r in active if r["class_level"] == s["class_level"]), None)
        if here:
            diffs = [k for k, ok in (("ชื่อ", _same_name(here["full_name"], s["full_name"])),
                                     ("ห้อง", str(here["room"] or "1").strip() == s["room"])) if not ok]
            item.update(old_name=here["full_name"], old_room=str(here["room"] or ""), student_no=here["student_no"], diffs=diffs)
            out["changed" if diffs else "same"].append(item)
        elif active:
            item.update(old_level=active[0]["class_level"], old_name=active[0]["full_name"])
            out["other_level"].append(item)
        elif mine:
            item.update(old_level=mine[0]["class_level"], old_name=mine[0]["full_name"])
            out["removed"].append(item)
        else:
            out["new"].append(item)
    levels = {s["class_level"] for s in students if s["student_id"]}
    for sid, rs in by_sid.items():
        if sid in seen:
            continue
        for r in rs:
            if r["is_active"] and r["class_level"] in levels:
                out["missing"].append({"student_id": sid, "full_name": r["full_name"], "class_level": r["class_level"],
                                       "room": str(r["room"] or ""), "student_no": r["student_no"], "is_locked": bool(r["is_locked"])})
    return out


def preview_dmc_file(file_content: bytes, filename: str, term: Optional[str] = None, year: Optional[str] = None,
                     db_path: str = DB_DEFAULT_PATH) -> Dict[str, Any]:
    """
    Generate preview summary from DMC file without modifying the database.
    With a term/year it also compares the file with that semester's roster ("compare").
    """
    students = parse_dmc_file(file_content, filename)
    if not students:
        raise ValueError("ไม่พบข้อมูลนักเรียนที่สามารถนำเข้าได้จากไฟล์นี้")

    by_class: Dict[str, Dict[str, Any]] = {}
    for s in students:
        cl = s["class_level"]
        rm = s["room"]
        if cl not in by_class:
            by_class[cl] = {
                "class_level": cl,
                "total": 0,
                "rooms": set(),
                "rooms_detail": {},
                "samples": []
            }
        by_class[cl]["total"] += 1
        by_class[cl]["rooms"].add(rm)
        by_class[cl]["rooms_detail"][rm] = by_class[cl]["rooms_detail"].get(rm, 0) + 1
        if len(by_class[cl]["samples"]) < 3:
            by_class[cl]["samples"].append(f"{s['full_name']} ({s['student_id']})")

    classes_list = []
    ordered_levels = ["ม.1", "ม.2", "ม.3", "ม.4", "ม.5", "ม.6"]
    for cl in ordered_levels:
        if cl in by_class:
            item = by_class[cl]
            classes_list.append({
                "class_level": cl,
                "total": item["total"],
                "rooms": sorted(list(item["rooms"])),
                "rooms_detail": item["rooms_detail"],
                "samples": item["samples"]
            })
    for cl, item in sorted(by_class.items()):
        if cl not in ordered_levels:
            classes_list.append({
                "class_level": cl,
                "total": item["total"],
                "rooms": sorted(list(item["rooms"])),
                "rooms_detail": item["rooms_detail"],
                "samples": item["samples"]
            })

    res = {
        "status": "success",
        "filename": filename,
        "total_students": len(students),
        "classes": classes_list
    }
    if term and year:
        cmp = compare_dmc_roster(students, term, year, db_path)
        res["compare"] = {"term": str(term).strip(), "year": str(year).strip(),
                          "counts": {k: len(v) for k, v in cmp.items()},
                          **{k: v[:300] for k, v in cmp.items()}}
    return res


def import_students_from_dmc(
    file_content: bytes,
    filename: str,
    term: str,
    year: str,
    overwrite: bool = True,
    db_path: str = DB_DEFAULT_PATH,
    sync_courses: bool = True
) -> Dict[str, Any]:
    """
    Import students from a DMC file into the class levels (ม.1 – ม.6) and rooms of one semester.

    overwrite=False, "เพิ่มเฉพาะนักเรียนใหม่" (owner 10 พ.ย. 2569): only students never on this semester's roster
        are added, after the last เลขที่ of their class. Everyone already there keeps everything: name, เลขที่, room,
        lock, check-ins, scores. Someone in another class, or taken off the roster earlier, is not added again.
    overwrite=True, "ปรับรายชื่อให้ตรงกับไฟล์": for each class in the file, names, rooms and เลขที่ follow the file;
        students missing from the file leave the roster, students in another class move to the file's class, and
        students taken off earlier come back. Check-ins and scores are never deleted (they belong to the student ID),
        and the lock (โปรแกรม 3 รูปแบบ) is kept.
    Both: students who join a class roster are enrolled in its courses, their attendance is counted from the
    daily table, and the changed ปพ.5 files are queued for rebuilding (sync_courses=False skips that).
    """
    init_db(db_path)
    students = parse_dmc_file(file_content, filename)
    if not students:
        raise ValueError("ไม่พบข้อมูลนักเรียนที่สามารถนำเข้าได้จากไฟล์นี้")

    t = str(term).strip()
    y = str(year).strip()
    cmp = compare_dmc_roster(students, t, y, db_path)
    status: Dict[str, str] = {}
    for k in ("new", "same", "changed", "other_level", "removed"):
        for it in cmp[k]:
            status.setdefault(it["student_id"], k)

    students_by_class: Dict[str, List[Dict[str, Any]]] = {}
    seen = set()
    for s in students:
        if not s["student_id"] or s["student_id"] in seen:
            continue
        seen.add(s["student_id"])
        students_by_class.setdefault(s["class_level"], []).append(s)

    def room_sort_key(st: Dict[str, Any]):
        try:
            return int(st.get("room", "1"))
        except ValueError:
            return 999

    total_imported = 0
    breakdown: Dict[str, Dict[str, Any]] = {}
    joined: Dict[str, List[str]] = {}   # class -> students now on its roster who were not on it before
    left: Dict[str, List[str]] = {}     # class -> students taken off its roster
    updated = 0

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        for cl, cl_students in students_by_class.items():
            sorted_students = sorted(cl_students, key=room_sort_key)
            if overwrite:
                for m in cmp["missing"]:
                    if m["class_level"] == cl:
                        cursor.execute(
                            "UPDATE class_students SET is_active = 0, updated_at = CURRENT_TIMESTAMP "
                            "WHERE term = ? AND year = ? AND class_level = ? AND student_id = ?;",
                            (t, y, cl, m["student_id"]))
                        left.setdefault(cl, []).append(m["student_id"])
                current_st_no = 1
            else:
                cursor.execute(
                    "SELECT MAX(student_no) FROM class_students WHERE term = ? AND year = ? AND class_level = ? AND is_active = 1;",
                    (t, y, cl)
                )
                current_st_no = (cursor.fetchone()[0] or 0) + 1

            level_imported = 0
            room_counts: Dict[str, int] = {}
            for s in sorted_students:
                sid = s["student_id"]
                cid = s["citizen_id"]
                name = s["full_name"]
                rm = s["room"]
                st = status.get(sid, "new")
                if not overwrite and st != "new":
                    continue  # already in this semester (any class, or taken off): keep what is there
                if st == "other_level":
                    # moving class: off the roster of the old class of this semester
                    for r in cursor.execute(
                        "SELECT class_level FROM class_students WHERE term = ? AND year = ? AND student_id = ? AND is_active = 1 AND class_level != ?;",
                        (t, y, sid, cl)
                    ).fetchall():
                        left.setdefault(r[0], []).append(sid)
                    cursor.execute(
                        "UPDATE class_students SET is_active = 0, updated_at = CURRENT_TIMESTAMP "
                        "WHERE term = ? AND year = ? AND student_id = ? AND is_active = 1 AND class_level != ?;",
                        (t, y, sid, cl))

                # 1. Upsert into master students table
                cursor.execute(
                    """
                    INSERT INTO students (student_id, full_name, citizen_id)
                    VALUES (?, ?, ?)
                    ON CONFLICT(student_id) DO UPDATE SET
                        full_name = excluded.full_name,
                        citizen_id = CASE WHEN excluded.citizen_id != '' THEN excluded.citizen_id ELSE students.citizen_id END;
                    """,
                    (sid, name, cid)
                )

                # 2. Upsert into class_students table (a changed name is split again into prefix/first/last below)
                note_str = f"ห้อง {rm} (DMC)"
                cursor.execute(
                    """
                    INSERT INTO class_students (term, year, class_level, student_id, student_no, full_name, room, is_active, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
                    ON CONFLICT(term, year, class_level, student_id) DO UPDATE SET
                        student_no = excluded.student_no,
                        first_name = CASE WHEN REPLACE(class_students.full_name, ' ', '') = REPLACE(excluded.full_name, ' ', '')
                                          THEN class_students.first_name ELSE '' END,
                        full_name = excluded.full_name,
                        room = excluded.room,
                        is_active = 1,
                        note = excluded.note,
                        updated_at = CURRENT_TIMESTAMP;
                    """,
                    (t, y, cl, sid, current_st_no, name, rm, note_str)
                )

                n_prefix, n_first, n_last = split_full_name(name)
                if n_first:
                    sync_dmc_name_row(conn, sid, n_prefix, n_first, n_last, gender=s.get("gender", ""), class_level=cl, room=rm)

                if st in ("new", "removed", "other_level"):
                    joined.setdefault(cl, []).append(sid)
                elif st == "changed":
                    updated += 1
                current_st_no += 1
                level_imported += 1
                total_imported += 1
                room_counts[rm] = room_counts.get(rm, 0) + 1

            breakdown[cl] = {
                "total": level_imported,
                "rooms": room_counts
            }

        conn.commit()

    # ชื่อที่เพิ่งนำเข้า: แยกเป็นคำนำหน้า/ชื่อ/สกุล แล้วปรับคำนำหน้าตามอายุให้เลย
    backfill_student_name_columns(db_path)
    try:
        refresh_student_prefixes(db_path=db_path)
    except Exception as e:
        print(f"[WARN] refresh_student_prefixes after DMC import failed: {e}")

    if sync_courses:
        _sync_courses_after_roster_import(t, y, joined, left, list(students_by_class) if overwrite else [], db_path)

    n_joined = sum(len(v) for v in joined.values())
    n_left = sum(len(v) for v in left.values())
    counts = {k: len(v) for k, v in cmp.items()}
    if overwrite:
        message = (f"ปรับรายชื่อตามไฟล์ DMC แล้ว {total_imported} คน ({len(breakdown)} ระดับชั้น): "
                   f"เข้ารายชื่อใหม่ {n_joined} คน, แก้ชื่อ/ห้อง {updated} คน, นำออกจากรายชื่อ {n_left} คน")
    else:
        kept = counts["same"] + counts["changed"]
        message = f"เพิ่มนักเรียนใหม่ {n_joined} คน • คงข้อมูลเดิม {kept} คน"
        not_added = counts["other_level"] + counts["removed"]
        if not_added:
            message += f" • ไม่ได้เพิ่ม {not_added} คน (อยู่ชั้นอื่น/เคยนำออกจากรายชื่อ)"

    return {
        "status": "success",
        "mode": "overwrite" if overwrite else "add",
        "message": message,
        "total_imported": total_imported,
        "added": n_joined,
        "updated": updated,
        "removed_from_roster": n_left,
        "compare_counts": counts,
        "term": t,
        "year": y,
        "breakdown": breakdown
    }


def _sync_courses_after_roster_import(t: str, y: str, joined: Dict[str, List[str]], left: Dict[str, List[str]],
                                      relisted_levels: List[str], db_path: str) -> None:
    """Same follow-up as the + / - buttons of the check-in page, for many students at once: enrol the students who
    joined a class in its courses, count their attendance from the daily table, and queue the ปพ.5 files whose
    roster changed (a joining or leaving student moves no number, so the recount alone would not notice)."""
    from timetable_manager import enroll_student_in_level_courses
    codes: List[str] = []
    for sids in left.values():
        for sid in sids:
            codes += student_course_codes(sid, t, y, db_path=db_path)
    for cl, sids in joined.items():
        for sid in sids:
            enroll_student_in_level_courses(t, y, cl, sid, db_path=db_path)
    for cl in dict.fromkeys(list(joined) + list(left) + list(relisted_levels)):
        ids = None if cl in relisted_levels else list(dict.fromkeys(joined.get(cl, []) + left.get(cl, [])))
        sync_daily_attendance_to_courses(t, y, cl, student_ids=ids, db_path=db_path)
    for sids in joined.values():
        for sid in sids:
            codes += student_course_codes(sid, t, y, db_path=db_path)
    if relisted_levels:
        # names / rooms / เลขที่ of the whole class follow the file: every course of the class gets a new roster
        with get_connection(db_path) as conn:
            for r in conn.execute("SELECT course_code, class_level FROM courses WHERE term = ? AND year = ?;", (t, y)):
                if set(l.strip() for l in str(r["class_level"] or "").split(",")) & set(relisted_levels):
                    codes.append(r["course_code"])
    notify_courses_changed(t, y, codes)


def compute_100_dates(start_date: Optional[str] = None, term: str = "1", year_be: Optional[str] = None) -> List[str]:
    """Compute 100 ISO date strings (20 weeks x 5 days, Mon-Fri) starting from start_date."""
    from datetime import datetime, timedelta
    if start_date:
        clean_s = str(start_date).strip()[:10]
        try:
            start_dt = datetime.strptime(clean_s, "%Y-%m-%d")
        except ValueError:
            try:
                start_dt = datetime.strptime(clean_s, "%d/%m/%Y")
            except ValueError:
                start_dt = datetime.now()
    else:
        y_int = int(year_be) if year_be and str(year_be).isdigit() else 2568
        g_year = y_int - 543 if y_int > 2500 else y_int
        start_dt = datetime(g_year, 11, 3) if str(term).strip() == "2" else datetime(g_year, 5, 19)

    monday = start_dt - timedelta(days=start_dt.weekday())
    dates = []
    for w in range(20):
        w_monday = monday + timedelta(days=w * 7)
        for d in range(5):
            day_dt = w_monday + timedelta(days=d)
            dates.append(day_dt.strftime("%Y-%m-%d"))
    return dates

def get_attendance_dashboard(
    term: str = "1",
    year: str = "2568",
    mode: str = "subject",
    month: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Retrieve attendance dashboard metrics:
    - School-wide KPIs (total students, average attendance %, at-risk count, warning count)
    - Top 3 most absent students for each of the 6 class levels (ม.1 to ม.6)
    - School-wide top absent students list
    Supports 'subject' (PorPor5 course-level), 'daily' (Homeroom 20-week), or 'auto' mode.
    Supports filtering by month ('YYYY-MM' or 'all'). Auto-detects current month.
    """
    from datetime import datetime
    init_db(db_path)
    class_levels = ["ม.1", "ม.2", "ม.3", "ม.4", "ม.5", "ม.6"]
    levels_data = []
    all_school_ranked = []
    
    tot_school_students = 0
    tot_school_at_risk = 0
    tot_school_warning = 0
    all_pcts = []

    t_str = str(term).strip()
    y_str = str(year).strip()

    # Pre-calculate 100 schedule dates and month mapping
    dates_100 = compute_100_dates(get_semester_start_date(t_str, y_str, db_path=db_path), t_str, y_str)
    thai_months = ['', 'มกราคม', 'กุมภาพันธ์', 'มีนาคม', 'เมษายน', 'พฤษภาคม', 'มิถุนายน', 'กรกฎาคม', 'สิงหาคม', 'กันยายน', 'ตุลาคม', 'พฤศจิกายน', 'ธันวาคม']
    thai_short = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.']

    month_slots_map = {}
    for idx, dt in enumerate(dates_100):
        ym = dt[:7]
        if ym not in month_slots_map:
            d_obj = datetime.strptime(dt, '%Y-%m-%d')
            y_be = d_obj.year + 543
            m_idx = d_obj.month
            month_slots_map[ym] = {
                "key": ym,
                "name": f"{thai_months[m_idx]} {y_be}",
                "short_name": f"{thai_short[m_idx]} {y_be}",
                "indices": set(),
                "dates": set()
            }
        month_slots_map[ym]["indices"].add(idx)
        month_slots_map[ym]["dates"].add(dt)

    available_months = [
        {"key": v["key"], "name": v["name"], "short_name": v["short_name"], "days_count": len(v["dates"])}
        for v in month_slots_map.values()
    ]
    now_ym = datetime.now().strftime("%Y-%m")
    default_month = now_ym if now_ym in month_slots_map else (available_months[0]["key"] if available_months else "all")

    is_filtering_month = bool(month and month != "all" and month in month_slots_map)
    filter_indices = month_slots_map[month]["indices"] if is_filtering_month else None
    filter_dates = month_slots_map[month]["dates"] if is_filtering_month else None
    # a month is counted up to today only (same rule as the whole-semester figures); a month not
    # reached yet has nothing checked: 0 days, 0%, nobody at risk
    today = attendance_rules.today_iso()
    month_not_started = bool(is_filtering_month and all(dates_100[i] > today for i in filter_indices))

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        
        # 1. Fetch PorPor5 subject attendance for all students in this semester
        cursor.execute(
            """
            SELECT student_id, course_code, attendance_json 
            FROM grades_history 
            WHERE term = ? AND year = ? AND attendance_json IS NOT NULL;
            """,
            (t_str, y_str)
        )
        
        subject_att_map = {}
        for row in cursor.fetchall():
            sid = row["student_id"]
            try:
                att = json.loads(row["attendance_json"])
                if isinstance(att, dict):
                    if sid not in subject_att_map:
                        subject_att_map[sid] = {"absent": 0, "present": 0, "leave": 0, "late": 0, "courses_count": 0}
                    
                    if is_filtering_month and "status_list" in att:
                        s_list = att.get("status_list", [])
                        for idx in filter_indices:
                            if idx < len(s_list):
                                st = s_list[idx]
                                if st in ('ข', 'absent'):
                                    subject_att_map[sid]["absent"] += 1
                                elif st in ('ส', 'late'):
                                    subject_att_map[sid]["late"] += 1
                                    subject_att_map[sid]["present"] += 1
                                elif st in ('ล', 'leave'):
                                    subject_att_map[sid]["leave"] += 1
                                elif st in ('/', 'present'):
                                    subject_att_map[sid]["present"] += 1
                        subject_att_map[sid]["courses_count"] += 1
                    else:
                        if att.get("present_count", 0) > 0 or (att.get("absent_count", 0) > 0 and att.get("percentage", 0) > 0):
                            subject_att_map[sid]["absent"] += att.get("absent_count", 0)
                            subject_att_map[sid]["present"] += att.get("present_count", 0)
                            subject_att_map[sid]["leave"] += att.get("leave_count", 0)
                            subject_att_map[sid]["late"] += att.get("late_count", 0)
                            subject_att_map[sid]["courses_count"] += 1
            except Exception:
                pass

        # 2. Iterate each class level
        for lvl in class_levels:
            grid = get_daily_attendance_grid(t_str, y_str, lvl, db_path=db_path)
            # Exclude locked students from evaluation and top absentees
            students = [s for s in grid.get("students", []) if not s.get("is_locked", False)]
            locked_count = len(grid.get("students", [])) - len(students)
            month_days = []
            if is_filtering_month:
                level_holidays = attendance_rules.parse_slot_set(grid.get("holidays"))
                month_days = [i for i in sorted(filter_indices) if i not in level_holidays and dates_100[i] <= today]
            criterion_days = len(month_days) if is_filtering_month else grid.get("criterion_days", 100)
            has_daily_absences = any(s.get("absent_count", 0) > 0 for s in students)

            effective_mode = mode
            if mode == "auto":
                effective_mode = "daily" if has_daily_absences else "subject"

            enriched = []
            for s in students:
                sid = s["student_id"]
                s_att = subject_att_map.get(sid, {"absent": 0, "present": 0, "leave": 0, "late": 0, "courses_count": 0})
                s_tot = s_att["absent"] + s_att["present"] + s_att["leave"]
                s_pct = round((s_att["present"] / s_tot * 100), 1) if s_tot > 0 else (0.0 if is_filtering_month else 100.0)

                if is_filtering_month:
                    # The month's school days up to today, by the whole-semester grid's rules: holidays
                    # are not school days, days not reached yet are not counted, activity days are "/",
                    # and a school day nobody checked counts as ขาด
                    status_list = s.get("status_list", [])
                    d_abs = 0
                    d_pres = 0
                    d_leave = 0
                    d_late = 0
                    for idx in month_days:
                        st = status_list[idx] if idx < len(status_list) else ""
                        if st in ("ส", "late"):
                            d_late += 1
                            d_pres += 1
                        elif st in ("ล", "leave"):
                            d_leave += 1
                        elif st in ("/", "present"):
                            d_pres += 1
                        else:
                            d_abs += 1
                    d_tot = d_abs + d_pres + d_leave
                    d_pct = round((d_pres / d_tot * 100), 1) if d_tot > 0 else 0.0
                else:
                    d_abs = s.get("absent_count", 0)
                    d_pres = s.get("present_count", criterion_days)
                    d_leave = s.get("leave_count", 0)
                    d_late = s.get("late_count", 0)
                    d_pct = s.get("percentage", 100.0)

                if effective_mode == "subject":
                    courses_cnt = s_att.get("courses_count", 1) or 1
                    effective_abs = round(s_att["absent"] / courses_cnt) if courses_cnt > 0 else 0
                    effective_leave = round(s_att["leave"] / courses_cnt) if courses_cnt > 0 else 0
                    effective_late = round(s_att.get("late", 0) / courses_cnt) if courses_cnt > 0 else 0
                    effective_present = max(0, 100 - effective_abs - effective_leave)
                    effective_pct = s_pct
                    unit = "วัน"
                else:
                    effective_abs = d_abs
                    effective_present = d_pres
                    effective_leave = d_leave
                    effective_late = d_late
                    effective_pct = d_pct
                    unit = "วัน" 

                risk = "normal"
                if is_filtering_month and not (s_tot if effective_mode == "subject" else d_tot):
                    risk = "upcoming"  # nothing counted in this month yet: 0%, but not at risk
                elif effective_pct < 60.0:
                    risk = "critical"
                    tot_school_at_risk += 1
                elif effective_pct < 80.0 or effective_abs > 0:
                    risk = "warning"
                    tot_school_warning += 1

                item = {
                    "student_no": s.get("student_no", 0),
                    "student_id": sid,
                    "full_name": s.get("full_name", ""),
                    "class_level": lvl,
                    "room": s.get("room", "1"),
                    "daily_absent_days": d_abs,
                    "daily_present_days": d_pres,
                    "daily_leave_days": d_leave,
                    "daily_late_days": d_late,
                    "daily_percentage": d_pct,
                    "subject_absent_periods": s_att["absent"],
                    "subject_present_periods": s_att["present"],
                    "subject_leave_periods": s_att["leave"],
                    "subject_late_periods": s_att.get("late", 0),
                    "subject_percentage": s_pct,
                    "subject_courses_count": s_att["courses_count"],
                    "effective_absent": effective_abs,
                    "effective_present": effective_present,
                    "effective_leave": effective_leave,
                    "effective_late": effective_late,
                    "late_count": effective_late,
                    "percentage": effective_pct,
                    "risk_status": risk,
                    "unit": unit
                }
                enriched.append(item)
                all_pcts.append(effective_pct)

            # Sort students: highest absences first, then lowest percentage, then student_no
            enriched.sort(key=lambda x: (x["effective_absent"], -x["percentage"], -x["student_no"]), reverse=True)
            
            top3 = []
            for r_idx, st in enumerate(enriched[:3], start=1):
                st_copy = dict(st)
                st_copy["rank"] = r_idx
                top3.append(st_copy)

            lvl_avg = round(sum(s["percentage"] for s in enriched) / len(enriched), 1) if enriched else 100.0
            tot_school_students += len(enriched)

            # Group students by room and calculate gender counts (ช / ญ)
            rooms_map = {}
            for s in students:
                rm = str(s.get("room") or "1").strip()
                if rm not in rooms_map:
                    rooms_map[rm] = {"room": rm, "male": 0, "female": 0, "total": 0}
                n = (s.get("full_name") or "").strip()
                if n.startswith(('เด็กชาย', 'ด.ช.', 'ด.ช ', 'นาย')):
                    rooms_map[rm]["male"] += 1
                elif n.startswith(('เด็กหญิง', 'ด.ญ.', 'ด.ญ ', 'นางสาว', 'น.ส.', 'น.ส ', 'นาง')):
                    rooms_map[rm]["female"] += 1
                rooms_map[rm]["total"] += 1

            rooms_breakdown = []
            room_texts = []
            for rm in sorted(rooms_map.keys(), key=lambda r: int(r) if r.isdigit() else r):
                r_data = rooms_map[rm]
                m_c = r_data["male"]
                f_c = r_data["female"]
                txt = f"ห้อง {rm} : ช {m_c} ญ {f_c}"
                r_data["text"] = txt
                rooms_breakdown.append(r_data)
                room_texts.append(txt)

            gender_text = " , ".join(room_texts)

            # Locked students are the โปรแกรม 3 รูปแบบ (เรียนและทำงาน) group: no daily check or ปพ.5,
            # but the dashboard shows their numbers per room / gender in a chart of their own
            p3_map = {}
            for s in grid.get("students", []):
                if not s.get("is_locked", False):
                    continue
                rm = str(s.get("room") or "1").strip()
                e = p3_map.setdefault(rm, {"room": rm, "male": 0, "female": 0, "total": 0})
                n = (s.get("full_name") or "").strip()
                if n.startswith(('เด็กชาย', 'ด.ช.', 'ด.ช ', 'นาย')):
                    e["male"] += 1
                elif n.startswith(('เด็กหญิง', 'ด.ญ.', 'ด.ญ ', 'นางสาว', 'น.ส.', 'น.ส ', 'นาง')):
                    e["female"] += 1
                e["total"] += 1
            program3_breakdown = [p3_map[rm] for rm in sorted(p3_map, key=lambda r: int(r) if r.isdigit() else r)]

            levels_data.append({
                "class_level": lvl,
                "student_count": len(enriched),
                "average_pct": lvl_avg,
                "criterion_days": criterion_days,
                "top_absent": top3,
                "has_absences": any(t["effective_absent"] > 0 for t in top3),
                "unit": "วัน",
                "rooms_breakdown": rooms_breakdown,
                "locked_count": locked_count,  # โปรแกรม 3 รูปแบบ (locked): not in the counts above
                "program3_breakdown": program3_breakdown,
                "gender_text": gender_text
            })
            all_school_ranked.extend(enriched)

    all_school_ranked.sort(key=lambda x: (x["effective_absent"], -x["percentage"]), reverse=True)
    school_top15 = []
    for r_idx, st in enumerate(all_school_ranked[:15], start=1):
        st_c = dict(st)
        st_c["rank"] = r_idx
        school_top15.append(st_c)

    school_avg = round(sum(all_pcts) / len(all_pcts), 1) if all_pcts else 100.0

    return {
        "term": t_str,
        "year": y_str,
        "mode": mode,
        "selected_month": month or "all",
        "default_month": default_month,
        "is_current_month": (month == now_ym) if is_filtering_month else False,
        "month_not_started": month_not_started,
        "available_months": available_months,
        "month_name": month_slots_map.get(month, {}).get("name", "สะสมทั้งเทอม") if is_filtering_month else "สะสมทั้งเทอม",
        "summary": {
            "total_students": tot_school_students,
            "average_attendance_pct": school_avg,
            "at_risk_count": tot_school_at_risk,
            "warning_count": tot_school_warning
        },
        "levels": levels_data,
        "school_top_absent": school_top15
    }


def get_student_monthly_attendance_detail(
    term: str = "1",
    year: str = "2569",
    student_id: str = "",
    mode: str = "subject",
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Month-by-month attendance of one student in school days (วัน), for the student window.

    Same rules as the daily page (get_daily_attendance_grid), the dashboard and the student portal:
      - the semester's own start date, so the months line up with the daily page;
      - class holidays are not school days; activity days (locked_json) count as present;
      - only school days up to today are counted (ขาด = school days so far - มา - ลา, so a day
        nobody checked counts as ขาด). A month not reached yet shows 0 / 0% with "upcoming": True,
        because nothing in it has been checked (it used to show every future day as มาเรียน = 100%).
    mode "subject" also reads the ปพ.5 course marks: on a day without a homeroom record they stand in
    for it, and a course marked ข / ล / ส changes the day (the older reading). Course absences are
    listed in absence_records in both modes.
    """
    init_db(db_path)
    t = str(term).strip()
    y = str(year).strip()
    sid = str(student_id).strip()
    by_course = str(mode).strip() == "subject"

    from datetime import datetime
    today = attendance_rules.today_iso()
    dates_100 = compute_100_dates(get_semester_start_date(t, y, db_path=db_path), t, y)

    thai_months = ['', 'มกราคม', 'กุมภาพันธ์', 'มีนาคม', 'เมษายน', 'พฤษภาคม', 'มิถุนายน', 'กรกฎาคม', 'สิงหาคม', 'กันยายน', 'ตุลาคม', 'พฤศจิกายน', 'ธันวาคม']
    thai_short = ['', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.']

    month_slots_map = {}
    for dt in dates_100:
        ym = dt[:7]
        if ym not in month_slots_map:
            d_obj = datetime.strptime(dt, '%Y-%m-%d')
            month_slots_map[ym] = {
                "name": f"{thai_months[d_obj.month]} {d_obj.year + 543}",
                "short_name": thai_short[d_obj.month],
                "absent": 0,
                "present": 0,
                "leave": 0,
                "late": 0,
                "total_units": 0,  # school days up to today: what the counts and the % are out of
                "school_days": 0,  # every school day of the month in this semester
            }

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT student_no, student_id, full_name, class_level, room
            FROM class_students
            WHERE term = ? AND year = ? AND student_id = ?;
            """,
            (t, y, sid)
        )
        st_row = cursor.fetchone()
        if not st_row:
            st_info = {"student_no": 0, "student_id": sid, "full_name": sid, "class_level": "", "room": "1"}
        else:
            st_info = {
                "student_no": st_row["student_no"],
                "student_id": st_row["student_id"],
                "full_name": st_row["full_name"],
                "class_level": st_row["class_level"],
                "room": st_row["room"] or "1"
            }

        # 1. Daily homeroom attendance
        cursor.execute(
            """
            SELECT attendance_date, status
            FROM daily_attendance
            WHERE term = ? AND year = ? AND student_id = ?;
            """,
            (t, y, sid)
        )
        daily_map = {r["attendance_date"]: r["status"] for r in cursor.fetchall()}

        # 2. PorPor5 subject attendance (one mark per day slot)
        cursor.execute(
            """
            SELECT course_code, attendance_json
            FROM grades_history
            WHERE term = ? AND year = ? AND student_id = ?;
            """,
            (t, y, sid)
        )
        subject_courses = []
        for r in cursor.fetchall():
            try:
                s_list = json.loads(r["attendance_json"] or "{}").get("status_list", [])
                if s_list:
                    subject_courses.append((r["course_code"], s_list))
            except Exception:
                pass

    holidays, activity = get_class_calendar(t, y, st_info["class_level"], db_path=db_path)

    absence_records = []

    def note(dt: str, code: str, status: str, text: str) -> None:
        absence_records.append({"date": dt, "course_code": code, "status": status, "status_text": text})

    for idx, dt in enumerate(dates_100):
        if idx in holidays:
            continue  # not a school day
        m_info = month_slots_map[dt[:7]]
        m_info["school_days"] += 1
        if dt > today:
            continue  # not reached yet: nothing has been checked
        m_info["total_units"] += 1

        d_st = daily_map.get(dt)
        if idx in activity:
            day_status = "present"  # activity day: present for everyone (as the daily page)
        elif d_st in ("present", "late", "leave", "absent"):
            day_status = d_st
            if d_st == "absent":
                note(dt, "โฮมรูม", "absent", "ขาดเรียน")
            elif d_st == "leave":
                note(dt, "โฮมรูม", "leave", "ลา")
        elif by_course and any(idx < len(s) and s[idx] for _, s in subject_courses):
            day_status = "present"  # no homeroom record: the course marks below decide
        else:
            day_status = "absent"  # a school day so far that nobody checked counts as ขาด
            note(dt, "โฮมรูม", "unchecked", "ไม่ได้เช็คชื่อ (นับเป็นขาด)")

        for code, s_list in subject_courses:
            if idx >= len(s_list):
                continue
            st = s_list[idx]
            if st in ("ข", "absent"):
                note(dt, code, "absent", "ขาดเรียน")
                if by_course and day_status != "leave":
                    day_status = "absent"
            elif st in ("ล", "leave"):
                note(dt, code, "leave", "ลา")
                if by_course and day_status != "absent":
                    day_status = "leave"
            elif st in ("ส", "late"):
                if by_course and day_status == "present":
                    day_status = "late"

        if day_status == "absent":
            m_info["absent"] += 1
        elif day_status == "leave":
            m_info["leave"] += 1
        else:
            m_info["present"] += 1
            if day_status == "late":
                m_info["late"] += 1

    now_ym = today[:7]
    monthly_trend = []
    tot = {"present": 0, "absent": 0, "leave": 0, "late": 0, "total_units": 0, "school_days": 0}
    for ym in sorted(month_slots_map.keys()):
        m = month_slots_map[ym]
        u = m["total_units"]
        for k in tot:
            tot[k] += m[k]
        monthly_trend.append({
            "key": ym,
            "name": m["name"],
            "short_name": m["short_name"],
            "absent": m["absent"],
            "present": m["present"],
            "leave": m["leave"],
            "late": m["late"],
            "percentage": round(m["present"] / u * 100, 1) if u > 0 else 0.0,  # nothing checked yet = 0%
            "total_units": u,
            "school_days": m["school_days"],
            "upcoming": u == 0 and m["school_days"] > 0,
            "is_current": ym == now_ym
        })

    tot_units = tot["total_units"]
    overall_pct = round(tot["present"] / tot_units * 100, 1) if tot_units > 0 else 0.0
    if tot_units == 0:
        overall_risk = "not_started"
        risk_text = "ยังไม่ถึงวันเรียน (ยังไม่ได้เช็คเวลาเรียน)"
    elif overall_pct < 60.0:
        overall_risk = "critical"
        risk_text = "เวลาเรียนไม่ถึง 60% (หมดสิทธิ์สอบ)"
    elif overall_pct < 80.0:
        overall_risk = "warning"
        risk_text = "เวลาเรียนไม่ถึง 80% (เสี่ยง มส.)"
    else:
        overall_risk = "normal"
        risk_text = "ผ่านเกณฑ์เวลาเรียน"

    return {
        "term": t,
        "year": y,
        "mode": mode,
        "unit": "วัน",
        "as_of": today,
        "student": st_info,
        "overall": {
            "total_units": tot_units,
            "school_days": tot["school_days"],
            "present": tot["present"],
            "absent": tot["absent"],
            "leave": tot["leave"],
            "late": tot["late"],
            "percentage": overall_pct,
            "risk_status": overall_risk,
            "risk_text": risk_text
        },
        "monthly_trend": monthly_trend,
        "absence_records": absence_records
    }



def extract_periods_per_day(schedule_obj: Any) -> Dict[int, int]:
    """
    Returns a dict mapping day index 0..4 (0=Mon, 1=Tue, 2=Wed, 3=Thu, 4=Fri)
    to the number of teaching periods on that day.
    """
    periods_map = {0: 0, 1: 0, 2: 0, 3: 0, 4: 0}
    if not schedule_obj:
        return periods_map
    if isinstance(schedule_obj, str):
        try:
            schedule_obj = json.loads(schedule_obj)
        except Exception:
            return periods_map

    if isinstance(schedule_obj, list):
        for item in schedule_obj:
            if isinstance(item, dict):
                day_num = item.get("day")
                span = item.get("span", 1) or 1
                if day_num is not None:
                    try:
                        d_val = int(day_num)
                        if 1 <= d_val <= 5:
                            periods_map[d_val - 1] += int(span)
                    except (ValueError, TypeError):
                        pass
    elif isinstance(schedule_obj, dict):
        day_keys = {
            "mon": 0, "monday": 0, "จันทร์": 0, "จ": 0,
            "tue": 1, "tuesday": 1, "อังคาร": 1, "อ": 1,
            "wed": 2, "wednesday": 2, "พุธ": 2, "พ": 2,
            "thu": 3, "thursday": 3, "พฤหัสบดี": 3, "พฤ": 3,
            "fri": 4, "friday": 4, "ศุกร์": 4, "ศ": 4,
        }
        for k, v in schedule_obj.items():
            k_lower = str(k).lower().strip()
            if k_lower in day_keys:
                try:
                    val = int(v)
                    if val > 0:
                        periods_map[day_keys[k_lower]] += val
                except (ValueError, TypeError):
                    pass
    return periods_map


def get_semester_start_date(
    term: str,
    year: str,
    start_date_override: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> str:
    """
    Get the unified start date for a semester across ALL class levels.
    Ensures that when selected, all class levels (ม.1 to ม.6) display the exact same start date.
    """
    init_db(db_path)
    t = str(term).strip()
    y = str(year).strip()

    if start_date_override and str(start_date_override).strip():
        s = str(start_date_override).strip()[:10]
        try:
            dt = datetime.strptime(s, "%Y-%m-%d")
            monday = dt - timedelta(days=dt.weekday())
            return monday.strftime("%Y-%m-%d")
        except ValueError:
            pass

    key = f"semester_start_date_{t}_{y}"
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT value FROM app_settings WHERE key = ?;", (key,))
        row = cursor.fetchone()
        if row and row["value"]:
            s = str(row["value"]).strip()[:10]
            try:
                dt = datetime.strptime(s, "%Y-%m-%d")
                monday = dt - timedelta(days=dt.weekday())
                return monday.strftime("%Y-%m-%d")
            except ValueError:
                pass

        # Check daily_attendance_config for any class_level in this semester
        cursor.execute(
            """
            SELECT start_date 
            FROM daily_attendance_config 
            WHERE term = ? AND year = ? AND start_date IS NOT NULL AND start_date != ''
            ORDER BY updated_at DESC LIMIT 1;
            """,
            (t, y)
        )
        row_cfg = cursor.fetchone()
        if row_cfg and row_cfg["start_date"]:
            s = str(row_cfg["start_date"]).strip()[:10]
            try:
                dt = datetime.strptime(s, "%Y-%m-%d")
                monday = dt - timedelta(days=dt.weekday())
                m_str = monday.strftime("%Y-%m-%d")
                cursor.execute(
                    "INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                    (key, m_str)
                )
                conn.commit()
                return m_str
            except ValueError:
                pass

    # Default fallback aligned to Monday
    y_int = int(y) if y.isdigit() else 2568
    g_year = y_int - 543 if y_int > 2500 else y_int
    fallback_dt = datetime(g_year, 11, 2) if t == "2" else datetime(g_year, 5, 18)
    monday = fallback_dt - timedelta(days=fallback_dt.weekday())
    m_str = monday.strftime("%Y-%m-%d")
    try:
        with get_connection(db_path) as conn:
            cursor = conn.cursor()
            cursor.execute(
                "INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                (key, m_str)
            )
            conn.commit()
    except Exception:
        pass
    return m_str


def set_semester_start_date(
    term: str,
    year: str,
    start_date: str,
    db_path: str = DB_DEFAULT_PATH
) -> str:
    """
    Set the unified start date for a semester across ALL class levels.
    Updates app_settings and all daily_attendance_config rows for this semester.
    """
    init_db(db_path)
    t = str(term).strip()
    y = str(year).strip()
    s = str(start_date).strip()[:10]
    try:
        dt = datetime.strptime(s, "%Y-%m-%d")
        monday = dt - timedelta(days=dt.weekday())
    except ValueError:
        try:
            dt = datetime.strptime(s, "%d/%m/%Y")
            monday = dt - timedelta(days=dt.weekday())
        except ValueError:
            monday = datetime.now() - timedelta(days=datetime.now().weekday())
    
    monday_str = monday.strftime("%Y-%m-%d")
    key = f"semester_start_date_{t}_{y}"

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            "INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            (key, monday_str)
        )
        cursor.execute(
            "UPDATE daily_attendance_config SET start_date = ?, updated_at = CURRENT_TIMESTAMP WHERE term = ? AND year = ?;",
            (monday_str, t, y)
        )
        conn.commit()

    return monday_str


def sync_daily_attendance_to_courses(
    term: str,
    year: str,
    class_level: str,
    student_ids: Optional[List[str]] = None,
    db_path: str = DB_DEFAULT_PATH
) -> int:
    """
    Synchronizes daily attendance records into all courses of the given class level.
    Each course follows its own timetable, the class holidays/activity days, and keeps
    slots a teacher overrode in the ปพ.5 dialog (attendance_json.manual_slots).
    Locked students (ย้าย/พักการเรียน) are not part of the ปพ.5 and are skipped.
    Notifies COURSE_ATTENDANCE_CHANGED_HOOKS so the Excel files can be refreshed.
    """
    init_db(db_path)
    t = str(term).strip()
    y = str(year).strip()
    cl = str(class_level).strip()

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT student_id, COALESCE(is_locked, 0) AS is_locked FROM class_students WHERE term = ? AND year = ? AND class_level = ?;",
            (t, y, cl)
        )
        locked = {r["student_id"] for r in cursor.fetchall() if r["is_locked"]}
        if not student_ids:
            cursor.execute(
                "SELECT student_id FROM class_students WHERE term = ? AND year = ? AND class_level = ?;",
                (t, y, cl)
            )
            student_ids = [r["student_id"] for r in cursor.fetchall()]
        student_ids = [s for s in student_ids if s not in locked]
        if not student_ids:
            return 0

        s_placeholders = ",".join("?" * len(student_ids))
        cursor.execute(
            f"""
            SELECT DISTINCT c.course_code
            FROM courses c
            JOIN grades_history g ON c.course_code = g.course_code AND c.term = g.term AND c.year = g.year
            WHERE c.term = ? AND c.year = ? AND g.student_id IN ({s_placeholders});
            """,
            [t, y] + student_ids
        )
        course_codes = [r["course_code"] for r in cursor.fetchall()]

    updated_grades_count = 0
    touched_course_codes = []
    daily_map: Dict[str, Dict[str, Any]] = {}

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        for code in course_codes:
            ctx = get_course_attendance_context(code, t, y, db_path=db_path)
            if not daily_map:
                daily_map = get_daily_attendance_records_map(student_ids, ctx["dates"], db_path=db_path)

            cursor.execute(
                f"""
                SELECT student_id, attendance_json
                FROM grades_history
                WHERE course_code = ? AND term = ? AND year = ? AND student_id IN ({s_placeholders});
                """,
                [code, t, y] + student_ids
            )
            rows = cursor.fetchall()
            if not rows:
                continue
            course_changed = False

            for sr in rows:
                sid = sr["student_id"]
                try:
                    stored_att = json.loads(sr["attendance_json"]) if sr["attendance_json"] else {}
                except Exception:
                    stored_att = {}
                auto = attendance_rules.auto_status_list(
                    daily_map.get(sid, {}), ctx["dates"], ctx["hours"], ctx["activity"], ctx["period_numbers"], ctx["elapsed"]
                )
                status_list, manual = attendance_rules.resolve_status_list(stored_att, auto, has_daily=True)
                summary = attendance_rules.summarize(status_list, ctx["hours"], ctx["activity"], ctx["elapsed"])
                summary["manual_slots"] = manual
                # Only write (and only refresh the ปพ.5) when the stored numbers really move: a recount with
                # nothing new must not rewrite 111 Excel files and re-export their PDFs.
                summary_json = json.dumps(summary, ensure_ascii=False)
                if summary_json != (sr["attendance_json"] or ""):
                    cursor.execute(
                        "UPDATE grades_history SET attendance_json = ? WHERE course_code = ? AND student_id = ? AND term = ? AND year = ?;",
                        (summary_json, code, sid, t, y)
                    )
                    course_changed = True
                if refresh_attendance_grade(cursor, code, sid, t, y, summary):
                    course_changed = True
                updated_grades_count += 1
            if course_changed:
                touched_course_codes.append(code)
        conn.commit()

    for hook in list(COURSE_ATTENDANCE_CHANGED_HOOKS):
        try:
            hook(t, y, touched_course_codes)
        except Exception as e:
            print(f"[WARN] course attendance hook failed: {e}")

    return updated_grades_count


def sync_semester_attendance_to_courses(term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> int:
    """Recount every class level of a semester: needed after a change that moves the dates or hours
    of all courses at once (new semester start date, timetable linked into the archive)."""
    with get_connection(db_path) as conn:
        levels = [r["class_level"] for r in conn.execute(
            "SELECT DISTINCT class_level FROM class_students WHERE term = ? AND year = ?;",
            (str(term).strip(), str(year).strip())
        )]
    return sum(sync_daily_attendance_to_courses(term, year, lvl, db_path=db_path) for lvl in levels)


# Callables (term, year, course_codes) run after course attendance changes in the DB.
# main.py registers the ปพ.5 Excel refresh queue here.
COURSE_ATTENDANCE_CHANGED_HOOKS: List[Any] = []


def notify_courses_changed(term: str, year: str, course_codes: List[str]) -> None:
    """Queue a ปพ.5 refresh for these courses. sync_daily_attendance_to_courses only reports courses whose
    numbers moved, so a change that leaves every number alone but still alters the file — a student joining or
    leaving the roster, a new timetable — must say so here."""
    codes = [c for c in dict.fromkeys(course_codes) if c]
    if not codes:
        return
    for hook in list(COURSE_ATTENDANCE_CHANGED_HOOKS):
        try:
            hook(str(term).strip(), str(year).strip(), codes)
        except Exception as e:
            print(f"[WARN] course attendance hook failed: {e}")


def student_course_codes(student_id: str, term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> List[str]:
    """The courses a student is enrolled in: whose ปพ.5 roster changes when they join or leave."""
    with get_connection(db_path) as conn:
        return [r["course_code"] for r in conn.execute(
            "SELECT DISTINCT course_code FROM grades_history WHERE student_id = ? AND term = ? AND year = ?;",
            (str(student_id).strip(), str(term).strip(), str(year).strip())
        )]


# -------------------------------------------------------------
# ชื่อนักเรียน: คำนำหน้า / ชื่อ / สกุล แยกช่องกัน
#
# ช่องจริงอยู่ที่ class_students.prefix, .first_name, .last_name (และ student_dmc_info ชุดเดียวกัน)
# ส่วน full_name เก็บไว้เป็นช่องสำเร็จรูปที่ระบบประกอบให้เอง ทุกหน้าจอและ ปพ.5 ยังอ่าน full_name
# ได้เหมือนเดิม จึงไม่ต้องแก้โค้ดส่วนอื่นเมื่อชื่อเปลี่ยน
# -------------------------------------------------------------
CHILD_PREFIXES = {"เด็กชาย": "นาย", "เด็กหญิง": "นางสาว"}
NAME_PREFIXES = ["เด็กชาย", "เด็กหญิง", "นางสาว", "นาย", "นาง", "ด.ช.", "ด.ญ.", "น.ส."]
PREFIX_ALIASES = {"ด.ช.": "เด็กชาย", "ด.ญ.": "เด็กหญิง", "น.ส.": "นางสาว"}
# อายุที่เปลี่ยนคำนำหน้าเป็นผู้ใหญ่ (ครบ 15 ปีบริบูรณ์ ตามระเบียบราชการ)
ADULT_PREFIX_AGE = 15


def split_full_name(full_name: str) -> Tuple[str, str, str]:
    """'เด็กชายสมศักดิ์ รักเรียนดี' -> ('เด็กชาย', 'สมศักดิ์', 'รักเรียนดี')"""
    text = re.sub(r"\s+", " ", str(full_name or "")).strip()
    prefix = ""
    for p in NAME_PREFIXES:
        if text.startswith(p):
            prefix = PREFIX_ALIASES.get(p, p)
            text = text[len(p):].strip()
            break
    first, _, last = text.partition(" ")
    return prefix, first.strip(), last.strip()


def compose_full_name(prefix: str, first_name: str, last_name: str) -> str:
    """ชื่อเต็มที่ใช้แสดงและพิมพ์ลง ปพ.5 (คำนำหน้าติดกับชื่อ เว้นวรรคก่อนสกุล)"""
    return f"{str(prefix or '').strip()}{str(first_name or '').strip()} {str(last_name or '').strip()}".strip()


def gender_from_prefix(prefix: Any) -> str:
    """เพศแบบไฟล์ DMC (ช / ญ) จากคำนำหน้า; คำนำหน้าอื่น = ไม่ทราบ"""
    p = str(prefix or "").strip()
    p = PREFIX_ALIASES.get(p, p)
    return "ช" if p in ("เด็กชาย", "นาย") else ("ญ" if p in ("เด็กหญิง", "นางสาว", "นาง") else "")


def _dmc_gender(value: Any) -> str:
    g = str(value or "").strip()
    return {"ชาย": "ช", "หญิง": "ญ", "M": "ช", "F": "ญ", "m": "ช", "f": "ญ"}.get(g, g)


def sync_dmc_name_row(conn, student_id: str, prefix: str, first_name: str, last_name: str, gender: str = "",
                      class_level: Optional[str] = None, room: Optional[str] = None) -> None:
    """student_dmc_info is the row the DMC export reads, one column per header (คำนำหน้าชื่อ / ชื่อ / นามสกุล / เพศ).
    Keep it in step with the roster name; a student added by hand or moved in (no DMC row yet) gets a row with
    the columns we know. เพศ follows the prefix when the prefix says it (owner 10 พ.ย. 2569)."""
    sid = str(student_id).strip()
    p, f, l = (str(x or "").strip() for x in (prefix, first_name, last_name))
    g = _dmc_gender(gender) or gender_from_prefix(p)
    if conn.execute("SELECT 1 FROM student_dmc_info WHERE student_id = ?;", (sid,)).fetchone():
        conn.execute(
            """UPDATE student_dmc_info SET prefix = ?, first_name = ?, last_name = ?,
               gender = CASE WHEN ? != '' THEN ? ELSE gender END, updated_at = CURRENT_TIMESTAMP
               WHERE student_id = ?;""", (p, f, l, g, g, sid))
    else:
        conn.execute(
            """INSERT INTO student_dmc_info (student_id, prefix, first_name, last_name, gender, class_level, room)
               VALUES (?, ?, ?, ?, ?, ?, ?);""", (sid, p, f, l, g, str(class_level or "").strip(), str(room or "").strip()))


def thai_birth_date(value: Any) -> Optional[date]:
    """วันเกิดจาก DMC เป็น 'DD/MM/พ.ศ.' (รับ ISO และ พ.ศ./ค.ศ. ได้ทั้งคู่)"""
    s = str(value or "").strip()
    if not s:
        return None
    m = re.fullmatch(r"(\d{1,2})[/-](\d{1,2})[/-](\d{4})", s)
    if m:
        d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
    else:
        m = re.fullmatch(r"(\d{4})-(\d{1,2})-(\d{1,2})", s[:10])
        if not m:
            return None
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if y > 2400:
        y -= 543
    try:
        return date(y, mo, d)
    except ValueError:
        return None


def age_on(birth: Optional[date], today: Optional[date] = None) -> Optional[int]:
    if not birth:
        return None
    t = today or date.today()
    return t.year - birth.year - ((t.month, t.day) < (birth.month, birth.day))


def due_prefix(prefix: str, birth_date: Any, today: Optional[date] = None) -> str:
    """คำนำหน้าที่ควรเป็น ณ วันนี้: เด็กชาย/เด็กหญิง -> นาย/นางสาว เมื่ออายุครบ 15 ปี
    (ไม่เปลี่ยนย้อนกลับ และไม่แตะคำนำหน้าอื่นที่ครูตั้งไว้เอง)"""
    p = str(prefix or "").strip()
    p = PREFIX_ALIASES.get(p, p)
    if p not in CHILD_PREFIXES:
        return p
    a = age_on(thai_birth_date(birth_date), today)
    return CHILD_PREFIXES[p] if a is not None and a >= ADULT_PREFIX_AGE else p


def get_student_name(student_id: str, db_path: str = DB_DEFAULT_PATH) -> Dict[str, Any]:
    """ชื่อที่ระบบใช้อยู่ของนักเรียนคนนี้ (จาก class_students เทอมล่าสุด เสริมด้วย DMC)"""
    sid = str(student_id).strip()
    with get_connection(db_path) as conn:
        cs = conn.execute(
            """SELECT prefix, first_name, last_name, full_name FROM class_students WHERE student_id = ?
               ORDER BY CAST(year AS INTEGER) DESC, CAST(term AS INTEGER) DESC LIMIT 1;""", (sid,)).fetchone()
        d = conn.execute("SELECT prefix, first_name, last_name, birth_date FROM student_dmc_info WHERE student_id = ?;", (sid,)).fetchone()
    out = {"student_id": sid, "prefix": "", "first_name": "", "last_name": "", "birth_date": d["birth_date"] if d else ""}
    for row in (d, cs):
        if row and (row["first_name"] or "").strip():
            out.update({k: (row[k] or "").strip() for k in ("prefix", "first_name", "last_name")})
    if not out["first_name"] and cs and cs["full_name"]:
        out["prefix"], out["first_name"], out["last_name"] = split_full_name(cs["full_name"])
    out["full_name"] = compose_full_name(out["prefix"], out["first_name"], out["last_name"])
    return out


def set_student_name(
    student_id: str,
    prefix: Optional[str] = None,
    first_name: Optional[str] = None,
    last_name: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH,
) -> Dict[str, Any]:
    """เขียนชื่อนักเรียนที่เดียว แล้วกระจายให้ทุกที่ทันที: students, class_students (ทุกภาคเรียน)
    และ student_dmc_info. คืนรายวิชาที่ต้องสร้าง ปพ.5 ใหม่ (ชื่อในไฟล์เปลี่ยน)"""
    sid = str(student_id).strip()
    cur_name = get_student_name(sid, db_path=db_path)
    new = {
        "prefix": (cur_name["prefix"] if prefix is None else str(prefix)).strip(),
        "first_name": (cur_name["first_name"] if first_name is None else str(first_name)).strip(),
        "last_name": (cur_name["last_name"] if last_name is None else str(last_name)).strip(),
    }
    new["prefix"] = PREFIX_ALIASES.get(new["prefix"], new["prefix"])
    if not new["first_name"]:
        raise ValueError("ต้องมีชื่อ")
    full = compose_full_name(**new)
    changed = full != cur_name["full_name"] or new["prefix"] != cur_name["prefix"]
    with get_connection(db_path) as conn:
        conn.execute("UPDATE students SET full_name = ? WHERE student_id = ?;", (full, sid))
        conn.execute(
            """UPDATE class_students SET prefix = ?, first_name = ?, last_name = ?, full_name = ?,
               updated_at = CURRENT_TIMESTAMP WHERE student_id = ?;""",
            (new["prefix"], new["first_name"], new["last_name"], full, sid))
        here = conn.execute(
            "SELECT class_level, room FROM class_students WHERE student_id = ? AND is_active = 1 ORDER BY year DESC, term DESC LIMIT 1;",
            (sid,)).fetchone()
        sync_dmc_name_row(conn, sid, new["prefix"], new["first_name"], new["last_name"],
                          class_level=here["class_level"] if here else None, room=here["room"] if here else None)
        semesters = [(r["term"], r["year"]) for r in conn.execute(
            "SELECT DISTINCT term, year FROM class_students WHERE student_id = ?;", (sid,))]
        conn.commit()
    if changed:
        for t, y in semesters:
            notify_courses_changed(t, y, student_course_codes(sid, t, y, db_path=db_path))
    return {**new, "student_id": sid, "full_name": full, "changed": changed}


def refresh_student_prefixes(today: Optional[date] = None, db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, str]]:
    """เปลี่ยน เด็กชาย/เด็กหญิง เป็น นาย/นางสาว ให้นักเรียนที่อายุครบ 15 ปีแล้ว (ตามวันที่ของเครื่อง)
    เรียกได้บ่อยเท่าไหร่ก็ได้: คนที่ถูกต้องอยู่แล้วจะไม่ถูกแตะ"""
    init_db(db_path)
    t = today or date.today()
    # แถวที่เพิ่งนำเข้ามาอาจยังไม่มีสามช่องนี้ เติมให้ก่อนเสมอ (ราคาถูก: แตะเฉพาะแถวที่ยังว่าง)
    backfill_student_name_columns(db_path)
    with get_connection(db_path) as conn:
        rows = [dict(r) for r in conn.execute(
            """SELECT DISTINCT cs.student_id, COALESCE(NULLIF(d.prefix, ''), cs.prefix, '') AS prefix,
                      d.birth_date FROM class_students cs
               LEFT JOIN student_dmc_info d ON d.student_id = cs.student_id
               WHERE COALESCE(cs.is_active, 1) = 1;""")]
    done = []
    for r in rows:
        want = due_prefix(r["prefix"], r["birth_date"], t)
        if want and want != (r["prefix"] or "").strip():
            res = set_student_name(r["student_id"], prefix=want, db_path=db_path)
            done.append({"student_id": r["student_id"], "from": r["prefix"], "to": want, "full_name": res["full_name"]})
    if done:
        print(f"[INFO] คำนำหน้าอัตโนมัติ: เปลี่ยน {len(done)} คน (อายุครบ {ADULT_PREFIX_AGE} ปี)")
    return done


def backfill_student_name_columns(db_path: str = DB_DEFAULT_PATH) -> int:
    """เติมช่อง prefix/first_name/last_name ของ class_students จาก DMC หรือจากชื่อเต็มเดิม (ทำครั้งเดียว)"""
    with get_connection(db_path) as conn:
        rows = [dict(r) for r in conn.execute(
            """SELECT cs.id, cs.full_name, d.prefix AS d_prefix, d.first_name AS d_first, d.last_name AS d_last
               FROM class_students cs LEFT JOIN student_dmc_info d ON d.student_id = cs.student_id
               WHERE COALESCE(cs.first_name, '') = '';""")]
        n = 0
        for r in rows:
            if (r["d_first"] or "").strip() and compose_full_name(r["d_prefix"], r["d_first"], r["d_last"]).replace(" ", "") == str(r["full_name"] or "").replace(" ", ""):
                p, f, l = (r["d_prefix"] or "").strip(), r["d_first"].strip(), (r["d_last"] or "").strip()
            else:
                p, f, l = split_full_name(r["full_name"])
            if not f:
                continue
            conn.execute("UPDATE class_students SET prefix = ?, first_name = ?, last_name = ? WHERE id = ?;", (p, f, l, r["id"]))
            n += 1
        conn.commit()
    return n


def get_user_preference(user_code: str, key: str, default: Optional[str] = None, db_path: str = DB_DEFAULT_PATH) -> Optional[str]:
    """ค่าที่ผู้ใช้คนนี้ตั้งไว้เอง เช่น ภาคเรียนที่ mark ไว้ดู"""
    init_db(db_path)
    with get_connection(db_path) as conn:
        row = conn.execute("SELECT value FROM user_preferences WHERE user_code = ? AND key = ?;",
                           (str(user_code).strip(), key)).fetchone()
    return row["value"] if row else default


def set_user_preference(user_code: str, key: str, value: str, db_path: str = DB_DEFAULT_PATH) -> None:
    init_db(db_path)
    with get_connection(db_path) as conn:
        conn.execute("""INSERT INTO user_preferences (user_code, key, value, updated_at)
                        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
                        ON CONFLICT(user_code, key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP;""",
                     (str(user_code).strip(), key, value))
        conn.commit()


def clear_user_preference(user_code: str, key: str, db_path: str = DB_DEFAULT_PATH) -> None:
    init_db(db_path)
    with get_connection(db_path) as conn:
        conn.execute("DELETE FROM user_preferences WHERE user_code = ? AND key = ?;", (str(user_code).strip(), key))
        conn.commit()


def get_class_calendar(term: str, year: str, class_level: str, db_path: str = DB_DEFAULT_PATH) -> Tuple[set, set]:
    """Holidays and activity days (slot indexes 0..99) set on the daily attendance page for a class level.
    A combined level such as "ม.1, ม.6" gets the union of each level's calendar."""
    levels = [l.strip() for l in str(class_level or "").split(",") if l.strip()]
    holidays: set = set()
    activity: set = set()
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        if levels:
            cursor.execute(
                f"SELECT holidays_json, locked_json FROM daily_attendance_config WHERE term = ? AND year = ? AND class_level IN ({','.join('?' * len(levels))});",
                [str(term), str(year)] + levels
            )
        else:
            cursor.execute(
                "SELECT holidays_json, locked_json FROM daily_attendance_config WHERE term = ? AND year = ?;",
                (str(term), str(year))
            )
        for r in cursor.fetchall():
            holidays |= attendance_rules.parse_slot_set(r["holidays_json"])
            activity |= attendance_rules.parse_slot_set(r["locked_json"])
    return holidays, activity - holidays


def get_course_attendance_context(course_code: str, term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> Dict[str, Any]:
    """
    Everything needed to compute a course's ปพ.5 attendance, resolved from the DB:
    timetable periods, class calendar + course-specific holidays, the 100 semester dates and row-8 hours.
    """
    t, y = str(term), str(year)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT class_level, schedule_json, attendance_config_json FROM courses WHERE course_code = ? AND term = ? AND year = ?;",
            (course_code, t, y)
        )
        row = cursor.fetchone()
    class_level = (row["class_level"] if row else "") or ""
    schedule = attendance_rules._load(row["schedule_json"]) if row else None
    cfg = attendance_rules._load(row["attendance_config_json"]) if row and "attendance_config_json" in row.keys() else None
    cfg = cfg if isinstance(cfg, dict) else {}

    holidays, activity = get_class_calendar(t, y, class_level, db_path=db_path)
    holidays |= attendance_rules.parse_slot_set(cfg.get("holidays"))
    activity |= attendance_rules.parse_slot_set(cfg.get("locked_counted"))
    if isinstance(schedule, dict):  # legacy dict schedules carried their own holidays
        holidays |= attendance_rules.parse_slot_set(schedule.get("holidays"))
        activity |= attendance_rules.parse_slot_set(schedule.get("locked_counted"))
    activity -= holidays

    periods = attendance_rules.periods_by_weekday(schedule)
    if sum(periods) == 0:
        periods = list(attendance_rules.DEFAULT_PERIODS)
    start_date = get_semester_start_date(t, y, db_path=db_path)
    hours = attendance_rules.slot_hours(periods, holidays, activity)
    dates = compute_100_dates(start_date, t, y)
    return {
        "course_code": course_code,
        "term": t,
        "year": y,
        "class_level": class_level,
        "schedule": schedule,
        "schedule_slots": attendance_rules.schedule_slots(schedule),
        "periods": periods,
        "period_numbers": attendance_rules.period_numbers_by_weekday(schedule),
        "holidays": holidays,
        "activity": activity,
        "course_holidays": attendance_rules.parse_slot_set(cfg.get("holidays")),
        "course_activity": attendance_rules.parse_slot_set(cfg.get("locked_counted")),
        "start_date": start_date,
        "dates": dates,
        "elapsed": attendance_rules.elapsed_slot_count(dates),
        "hours": hours,
        "total": sum(hours),
    }


def set_course_attendance_config(course_code: str, term: str, year: str, holidays: Any, locked_counted: Any, db_path: str = DB_DEFAULT_PATH) -> None:
    """Store course-specific holidays/activity days (beyond the class calendar) without touching the timetable."""
    cfg = {
        "holidays": sorted(attendance_rules.parse_slot_set(holidays)),
        "locked_counted": sorted(attendance_rules.parse_slot_set(locked_counted)),
    }
    with get_connection(db_path) as conn:
        conn.execute(
            "UPDATE courses SET attendance_config_json = ? WHERE course_code = ? AND term = ? AND year = ?;",
            (json.dumps(cfg), course_code, str(term), str(year))
        )
        conn.commit()


def get_porpor5_roster(course_code: str, term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """Students printed in a course's ปพ.5, in row order: enrolled, active and not locked, by เลขที่."""
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT cs.student_no, cs.student_id, COALESCE(NULLIF(cs.full_name, ''), s.full_name) AS full_name
            FROM grades_history g
            JOIN class_students cs ON cs.student_id = g.student_id AND cs.term = g.term AND cs.year = g.year
            LEFT JOIN students s ON s.student_id = g.student_id
            WHERE g.course_code = ? AND g.term = ? AND g.year = ?
              AND COALESCE(cs.is_locked, 0) = 0 AND COALESCE(cs.is_active, 1) = 1
            ORDER BY cs.student_no ASC, cs.student_id ASC;
            """,
            (course_code, str(term), str(year))
        )
        return [dict(r) for r in cursor.fetchall()]


def get_daily_attendance_grid(
    term: str,
    year: str,
    class_level: str,
    room: Optional[str] = None,
    start_date_override: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Retrieve 20-week (100 slots, Mon-Fri) Daily Attendance grid for a class level.
    Supports optional room filtering and returns available rooms.
    """
    init_db(db_path)
    t = str(term).strip()
    y = str(year).strip()
    cl = str(class_level).strip()

    # Get distinct available rooms for room selector
    all_level_students = get_class_students(t, y, cl, room=None, db_path=db_path)
    distinct_rooms = sorted(list({s.get("room", "1") for s in all_level_students}))

    # Get students filtered by room if specified
    students = get_class_students(t, y, cl, room=room, db_path=db_path)
    student_ids = [s["student_id"] for s in students]

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT start_date, holidays_json, locked_json
            FROM daily_attendance_config
            WHERE term = ? AND year = ? AND class_level = ?;
            """,
            (t, y, cl)
        )
        cfg_row = cursor.fetchone()

    # Determine start date (Unified across ALL class levels of this semester)
    start_date = get_semester_start_date(t, y, start_date_override=start_date_override, db_path=db_path)

    # Compute 100 schedule dates
    dates_100 = compute_100_dates(start_date, t, y)

    holidays = []
    locked_counted = []
    if cfg_row:
        try:
            holidays = json.loads(cfg_row["holidays_json"] or "[]")
        except Exception:
            holidays = []
        try:
            locked_counted = json.loads(cfg_row["locked_json"] or "[]")
        except Exception:
            locked_counted = []

    # Map daily attendance records
    att_map = get_daily_attendance_dates_map(student_ids, dates_100, db_path=db_path)

    holiday_set = set(holidays)
    locked_set = set(locked_counted)

    # Calculate actual periods criterion
    total_criterion = 0
    for slot_idx in range(100):
        if slot_idx in holiday_set:
            continue
        total_criterion += 1
    # ขาด / ร้อยละ count school days up to today only (same rule as course attendance)
    today_iso = attendance_rules.today_iso()
    elapsed_criterion = sum(1 for i, dt in enumerate(dates_100) if i not in holiday_set and dt <= today_iso)

    student_records = []
    for s in students:
        sid = s["student_id"]
        s_att = att_map.get(sid, {})
        has_any_record = len(s_att) > 0

        status_list = []
        p_cnt = 0
        l_cnt = 0
        lt_cnt = 0
        for slot_idx, dt in enumerate(dates_100):
            if slot_idx in holiday_set:
                status_list.append("")
                continue
            if slot_idx in locked_set:
                status_list.append("/")
                if dt <= today_iso:
                    p_cnt += 1
                continue

            if dt in s_att and dt <= today_iso:
                raw_st = s_att[dt]
                if raw_st == "present":
                    status_list.append("/")
                    p_cnt += 1
                elif raw_st == "leave":
                    status_list.append("ล")
                    l_cnt += 1
                elif raw_st == "late":
                    status_list.append("ส")
                    p_cnt += 1  # จากตารางเรียนรวม สาย ให้นับ เป็น มา ในวันนั้น
                    lt_cnt += 1
                else:
                    status_list.append("")
            else:
                status_list.append("")

        a_cnt = max(0, elapsed_criterion - p_cnt - l_cnt)
        pct = round((p_cnt / elapsed_criterion * 100), 1) if elapsed_criterion > 0 else 100.0

        student_records.append({
            "student_no": s["student_no"],
            "student_id": sid,
            "full_name": s["full_name"],
            "room": s.get("room", "1"),
            "is_locked": s.get("is_locked", False),
            "note": s.get("note", ""),
            "status_list": status_list,
            "present_count": p_cnt,
            "absent_count": a_cnt,
            "leave_count": l_cnt,
            "late_count": lt_cnt,
            "percentage": pct
        })

    return {
        "term": t,
        "year": y,
        "class_level": cl,
        "start_date": start_date,
        "holidays": holidays,
        "locked_counted": locked_counted,
        "total_criterion": total_criterion,
        "elapsed_criterion": elapsed_criterion,
        "total_students": len(student_records),
        "available_rooms": distinct_rooms,
        "selected_room": room or "all",
        "students": student_records
    }


def save_daily_attendance_grid(
    term: str,
    year: str,
    class_level: str,
    start_date: str,
    holidays: List[int],
    locked_counted: List[int],
    students: List[Dict[str, Any]],
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """Save 20-week Daily Attendance grid into daily_attendance table and config."""
    init_db(db_path)
    t = str(term).strip()
    y = str(year).strip()
    cl = str(class_level).strip()

    previous_start_date = get_semester_start_date(t, y, db_path=db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        # 1. Set unified semester start date across all class levels
        unified_start_date = set_semester_start_date(t, y, start_date, db_path=db_path)

        # Upsert config for this class level
        cursor.execute(
            """
            INSERT INTO daily_attendance_config (term, year, class_level, start_date, holidays_json, locked_json, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(term, year, class_level) DO UPDATE SET
                start_date = excluded.start_date,
                holidays_json = excluded.holidays_json,
                locked_json = excluded.locked_json,
                updated_at = CURRENT_TIMESTAMP;
            """,
            (t, y, cl, unified_start_date, json.dumps(holidays), json.dumps(locked_counted))
        )

        # 2. Compute the 100 dates
        dates_100 = compute_100_dates(start_date, t, y)

        holiday_set = set(holidays)
        locked_set = set(locked_counted)

        # Days after today have not happened: never store them (a blank cell would otherwise become "absent")
        today_iso = attendance_rules.today_iso()

        upsert_count = 0
        batch_attendance_rows = []
        for s in students:
            sid = s["student_id"]
            if "is_locked" in s:
                lck_val = 1 if s["is_locked"] else 0
                cursor.execute(
                    "UPDATE class_students SET is_locked = ? WHERE term = ? AND year = ? AND class_level = ? AND student_id = ?;",
                    (lck_val, t, y, cl, sid)
                )
            cursor.execute(
                "DELETE FROM daily_attendance WHERE student_id = ? AND term = ? AND year = ? AND attendance_date > ?;",
                (sid, t, y, today_iso)
            )
            s_list = s.get("status_list", [])
            for slot_idx, dt in enumerate(dates_100):
                if slot_idx in holiday_set or dt > today_iso:
                    continue

                if slot_idx in locked_set:
                    status = "present"
                else:
                    mark = s_list[slot_idx] if slot_idx < len(s_list) else ""
                    if mark == "/":
                        status = "present"
                    elif mark == "ล":
                        status = "leave"
                    elif mark == "ส":
                        status = "late"
                    else:
                        status = "absent"

                batch_attendance_rows.append((dt, t, y, cl, sid, status))

        if batch_attendance_rows:
            # The grid cannot show notes: keep a note ("มาคาบ N", a leave reason) while its status stands,
            # drop it once the status changes so it can never come back attached to a different mark
            cursor.executemany(
                """
                INSERT INTO daily_attendance (attendance_date, term, year, class_level, student_id, status, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(attendance_date, student_id) DO UPDATE SET
                    note = CASE WHEN daily_attendance.status = excluded.status THEN daily_attendance.note ELSE NULL END,
                    status = excluded.status,
                    class_level = excluded.class_level,
                    term = excluded.term,
                    year = excluded.year,
                    updated_at = CURRENT_TIMESTAMP;
                """,
                batch_attendance_rows
            )
            upsert_count = len(batch_attendance_rows)

        conn.commit()

    # Automatically synchronize daily attendance to all course records (ครูผู้สอน & คาบเรียน).
    # A new start date moves every date of every class, so then all class levels are recounted.
    try:
        if unified_start_date != previous_start_date:
            sync_semester_attendance_to_courses(t, y, db_path=db_path)
        else:
            student_sids = [s["student_id"] for s in students if "student_id" in s]
            sync_daily_attendance_to_courses(t, y, cl, student_ids=student_sids, db_path=db_path)
    except Exception as _e_sync:
        print(f"[WARN] Error syncing daily attendance to courses: {_e_sync}")

    return {
        "status": "success",
        "message": f"บันทึกตารางเวลาเรียน 20 สัปดาห์ ชั้น {cl} สำเร็จ ({len(students)} คน, {upsert_count} รายการ)",
        "updated_count": upsert_count
    }


def get_all_levels_attendance_summary(term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """Retrieve fast summary badge counts for all 6 levels (ม.1 – ม.6)."""
    init_db(db_path)
    standard_levels = ["ม.1", "ม.2", "ม.3", "ม.4", "ม.5", "ม.6"]
    results = []
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        for lvl in standard_levels:
            students = get_class_students(term, year, lvl, db_path=db_path)
            results.append({
                "class_level": lvl,
                "student_count": len(students)
            })
    return results


# ==============================================================================
# SYSTEM ADMINS & TEACHER AUTHENTICATION HELPERS
# ==============================================================================

def init_admin_db(db_path: str = DB_DEFAULT_PATH) -> None:
    """Ensure system_admins table exists; this school (school_builtin_data) seeds its first admin, code 308."""
    schema = """
    CREATE TABLE IF NOT EXISTS system_admins (
        teacher_code TEXT PRIMARY KEY,
        teacher_name TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    """
    with get_connection(db_path) as conn:
        conn.executescript(schema)
        cursor = conn.cursor()
        cursor.execute("SELECT COUNT(*) FROM system_admins;")
        if cursor.fetchone()[0] == 0 and school_profile.BUILTIN_DATA:
            cursor.execute("SELECT name FROM school_teachers WHERE code = '308';")
            r = cursor.fetchone()
            name = r["name"] if r else "ผู้ดูแลระบบ"
            cursor.execute("INSERT OR IGNORE INTO system_admins (teacher_code, teacher_name) VALUES (?, ?);", ('308', name))
        conn.commit()


def get_system_admins(db_path: str = DB_DEFAULT_PATH) -> List[Dict[str, Any]]:
    """Retrieve all current system administrators (max 3)."""
    init_admin_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT teacher_code, teacher_name, created_at FROM system_admins ORDER BY created_at ASC;")
        return [dict(r) for r in cursor.fetchall()]


def is_system_admin(teacher_code: str, db_path: str = DB_DEFAULT_PATH) -> bool:
    """Check if the given teacher code has administrator privileges."""
    if not teacher_code:
        return False
    init_admin_db(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT 1 FROM system_admins WHERE teacher_code = ?;", (str(teacher_code).strip(),))
        return cursor.fetchone() is not None


def add_system_admin(teacher_code: str, db_path: str = DB_DEFAULT_PATH) -> Tuple[bool, str]:
    """Appoint a teacher as administrator (up to 3 maximum)."""
    init_admin_db(db_path)
    clean_code = str(teacher_code).strip()
    if not clean_code:
        return False, "กรุณาระบุรหัสประจำตัวครู"

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT COUNT(*) FROM system_admins;")
        if cursor.fetchone()[0] >= 3:
            return False, "ระบบจำกัดผู้ดูแลระบบ (Admin) ได้ไม่เกิน 3 ท่าน"

        cursor.execute("SELECT name FROM school_teachers WHERE code = ?;", (clean_code,))
        t_row = cursor.fetchone()
        if not t_row:
            return False, f"ไม่พบข้อมูลครูรหัส {clean_code} ในระบบ"
        teacher_name = t_row["name"]

        cursor.execute("INSERT OR REPLACE INTO system_admins (teacher_code, teacher_name) VALUES (?, ?);", (clean_code, teacher_name))
        conn.commit()
        return True, f"แต่งตั้ง {teacher_name} เป็นผู้ดูแลระบบเรียบร้อยแล้ว"


def remove_system_admin(teacher_code: str, db_path: str = DB_DEFAULT_PATH) -> Tuple[bool, str]:
    """Revoke admin privileges from a teacher, ensuring at least 1 admin remains."""
    init_admin_db(db_path)
    clean_code = str(teacher_code).strip()
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT COUNT(*) FROM system_admins;")
        if cursor.fetchone()[0] <= 1:
            return False, "ไม่สามารถลบได้ เนื่องจากต้องมีผู้ดูแลระบบอย่างน้อย 1 ท่าน"

        cursor.execute("DELETE FROM system_admins WHERE teacher_code = ?;", (clean_code,))
        conn.commit()
        return True, "ถอดถอนสิทธิ์ผู้ดูแลระบบเรียบร้อยแล้ว"


def login_teacher_with_code(code: str, pin: Optional[str] = None, db_path: str = DB_DEFAULT_PATH) -> Tuple[bool, Optional[Dict[str, Any]], str]:
    """Authenticate a teacher using teacher code and optional login PIN (up to 4 digits)."""
    init_admin_db(db_path)
    clean_code = str(code).strip()
    clean_pin = str(pin).strip() if pin is not None and str(pin).strip() else None

    if not clean_code:
        return False, None, "กรุณาระบุรหัสประจำตัวครู"

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        try:
            cursor.execute("SELECT id, name, code, login_pin FROM school_teachers WHERE code = ?;", (clean_code,))
        except Exception:
            cursor.execute("SELECT id, name, code FROM school_teachers WHERE code = ?;", (clean_code,))
        t_row = cursor.fetchone()

        if not t_row:
            # Check if this code belongs directly to system_admins
            cursor.execute("SELECT teacher_code, teacher_name FROM system_admins WHERE teacher_code = ?;", (clean_code,))
            adm_row = cursor.fetchone()
            if adm_row:
                # Admin without a teacher record: its PIN is its code, and it must still be typed
                if clean_pin != clean_code:
                    return False, None, "รหัสใช้งาน (PIN) ไม่ถูกต้อง กรุณาตรวจสอบอีกครั้ง"
                director_flag = is_school_director(adm_row["teacher_code"], adm_row["teacher_name"], db_path)
                return True, {
                    "code": adm_row["teacher_code"],
                    "name": adm_row["teacher_name"],
                    "login_pin": clean_code,
                    "is_admin": True,
                    "is_director": director_flag
                }, "เข้าสู่ระบบสำเร็จในฐานะผู้ดูแลระบบ"
            return False, None, "ไม่พบรหัสครูดังกล่าวในระบบ กรุณาตรวจสอบรหัสอีกครั้ง"

        # Check PIN
        stored_pin = (t_row["login_pin"] if "login_pin" in t_row.keys() and t_row["login_pin"] else t_row["code"] or "").strip()
        if not stored_pin:
            stored_pin = clean_code

        if clean_pin is not None:
            if clean_pin != stored_pin:
                return False, None, "รหัสใช้งาน (PIN) ไม่ถูกต้อง กรุณาตรวจสอบอีกครั้ง"
        else:
            # If PIN wasn't provided, only allow if stored PIN matches teacher code
            if stored_pin != clean_code:
                return False, None, "กรุณาระบุรหัสใช้งาน (PIN)"

        admin_flag = is_system_admin(clean_code, db_path)
        director_flag = is_school_director(clean_code, t_row["name"], db_path)
        is_personnel_head = school_profile.is_personnel_head(clean_code, db_path)
        return True, {
            "id": t_row["id"],
            "code": t_row["code"],
            "name": t_row["name"],
            "login_pin": stored_pin,
            "is_admin": admin_flag,
            "is_director": director_flag,
            "is_personnel_head": is_personnel_head
        }, "เข้าสู่ระบบสำเร็จ"



def is_school_director(code: str, name: str, db_path: str = DB_DEFAULT_PATH) -> bool:
    """Check if the given teacher code or name corresponds to the School Director (ผู้อำนวยการ)."""
    clean_code = str(code).strip()
    if clean_code == "1234":
        return True
    clean_name = str(name).strip() if name else ""
    if clean_name.startswith("ผู้อำนวยการ") or clean_name.startswith("ผอ."):
        return True
    norm_name = normalize_teacher_base_name(clean_name)
    if not norm_name:
        return False
    try:
        with get_connection(db_path) as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT director_name FROM school_signatories;")
            for row in cursor.fetchall():
                d_name = row["director_name"]
                if d_name and normalize_teacher_base_name(d_name) == norm_name:
                    return True
    except Exception:
        pass
    return False

def normalize_teacher_base_name(name: str) -> str:
    """Normalize teacher name for robust comparison across formats."""
    if not name:
        return ""
    import re
    cleaned = re.sub(r"^(นาย|นางสาว|นาง|ครู|ว่าที่ร้อยตรี|ว่าที่\s*ร\.ต\.|ดร\.|ผอ\.|ผู้อำนวยการโรงเรียน)\s*", "", name.strip())
    return re.sub(r"\s+", "", cleaned)





# -------------------------------------------------------------
# HOME VISIT SYSTEM (ระบบบันทึกการเยี่ยมบ้านนักเรียน)
# -------------------------------------------------------------

def init_home_visit_tables(db_path: str = DB_DEFAULT_PATH) -> None:
    """Initialize home visit table if not exists."""
    schema = """
    CREATE TABLE IF NOT EXISTS home_visit_reports (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        term TEXT NOT NULL,
        year TEXT NOT NULL,
        class_level TEXT NOT NULL,
        advisor_name TEXT,
        recorded_by_name TEXT DEFAULT '',
        recorded_at TEXT DEFAULT '',
        fields_json TEXT NOT NULL DEFAULT '{}',
        photo_paths_json TEXT NOT NULL DEFAULT '[]',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(term, year, class_level)
    );
    """
    with get_connection(db_path) as conn:
        conn.executescript(schema)
        try:
            cursor = conn.cursor()
            cursor.execute("PRAGMA table_info(home_visit_reports);")
            cols = [c["name"] for c in cursor.fetchall()]
            if "recorded_by_name" not in cols:
                cursor.execute("ALTER TABLE home_visit_reports ADD COLUMN recorded_by_name TEXT DEFAULT '';")
            if "recorded_at" not in cols:
                cursor.execute("ALTER TABLE home_visit_reports ADD COLUMN recorded_at TEXT DEFAULT '';")
            if "photo_captions_json" not in cols:
                cursor.execute("ALTER TABLE home_visit_reports ADD COLUMN photo_captions_json TEXT DEFAULT '{}';")
            conn.commit()
        except Exception:
            pass


def get_home_visit_report(term: str, year: str, class_level: str, db_path: str = DB_DEFAULT_PATH) -> Optional[Dict[str, Any]]:
    """Retrieve home visit report for a specific class level in a given semester."""
    init_home_visit_tables(db_path)
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT * FROM home_visit_reports WHERE term = ? AND year = ? AND class_level = ? LIMIT 1;",
            (str(term).strip(), str(year).strip(), str(class_level).strip())
        )
        row = cursor.fetchone()
        if not row:
            return None
        col_names = row.keys()
        return {
            "id": row["id"],
            "term": row["term"],
            "year": row["year"],
            "class_level": row["class_level"],
            "advisor_name": row["advisor_name"] or "",
            "recorded_by_name": row["recorded_by_name"] if "recorded_by_name" in col_names and row["recorded_by_name"] else "",
            "recorded_at": row["recorded_at"] if "recorded_at" in col_names and row["recorded_at"] else (row["updated_at"] or ""),
            "fields": json.loads(row["fields_json"] or "{}"),
            "photos": json.loads(row["photo_paths_json"] or "[]"),
            "photo_captions": json.loads(row["photo_captions_json"] or "{}") if "photo_captions_json" in col_names and row["photo_captions_json"] else {},
            "created_at": row["created_at"],
            "updated_at": row["updated_at"]
        }


def upsert_home_visit_report(
    term: str,
    year: str,
    class_level: str,
    advisor_name: str,
    fields: dict,
    photo_paths: Optional[List[str]] = None,
    photo_captions: Optional[Dict[str, str]] = None,
    recorded_by_name: Optional[str] = None,
    recorded_at: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """Insert or update a class home visit report."""
    init_home_visit_tables(db_path)
    t = str(term).strip()
    y = str(year).strip()
    cl = str(class_level).strip()
    adv = str(advisor_name or "").strip()
    rec_by = str(recorded_by_name or "").strip()
    rec_at = str(recorded_at).strip() if recorded_at else None

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT id, photo_paths_json, photo_captions_json, recorded_by_name, recorded_at FROM home_visit_reports WHERE term = ? AND year = ? AND class_level = ?;",
            (t, y, cl)
        )
        existing = cursor.fetchone()

        current_photos = json.loads(existing["photo_paths_json"] or "[]") if existing else []
        final_photos = photo_paths if photo_paths is not None else current_photos

        current_captions = json.loads(existing["photo_captions_json"] or "{}") if (existing and "photo_captions_json" in existing.keys() and existing["photo_captions_json"]) else {}
        final_captions = photo_captions if photo_captions is not None else current_captions

        final_rec_by = rec_by if rec_by else (existing["recorded_by_name"] if (existing and "recorded_by_name" in existing.keys() and existing["recorded_by_name"]) else "")
        final_rec_at = rec_at if rec_at else (existing["recorded_at"] if (existing and "recorded_at" in existing.keys() and existing["recorded_at"]) else None)

        fields_str = json.dumps(fields, ensure_ascii=False)
        photos_str = json.dumps(final_photos, ensure_ascii=False)
        captions_str = json.dumps(final_captions, ensure_ascii=False)

        if existing:
            cursor.execute("""
                UPDATE home_visit_reports
                SET advisor_name = ?, recorded_by_name = ?, recorded_at = COALESCE(?, CURRENT_TIMESTAMP),
                    fields_json = ?, photo_paths_json = ?, photo_captions_json = ?, updated_at = CURRENT_TIMESTAMP
                WHERE id = ?;
            """, (adv, final_rec_by, final_rec_at, fields_str, photos_str, captions_str, existing["id"]))
        else:
            cursor.execute("""
                INSERT INTO home_visit_reports (term, year, class_level, advisor_name, recorded_by_name, recorded_at, fields_json, photo_paths_json, photo_captions_json)
                VALUES (?, ?, ?, ?, ?, COALESCE(?, CURRENT_TIMESTAMP), ?, ?, ?);
            """, (t, y, cl, adv, final_rec_by, final_rec_at, fields_str, photos_str, captions_str))
        conn.commit()

    return get_home_visit_report(t, y, cl, db_path)


def update_home_visit_photos(
    term: str,
    year: str,
    class_level: str,
    photo_paths: List[str],
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """Update only the photo paths of a class home visit report."""
    init_home_visit_tables(db_path)
    t = str(term).strip()
    y = str(year).strip()
    cl = str(class_level).strip()

    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT id FROM home_visit_reports WHERE term = ? AND year = ? AND class_level = ?;",
            (t, y, cl)
        )
        existing = cursor.fetchone()
        photos_str = json.dumps(photo_paths, ensure_ascii=False)

        if existing:
            cursor.execute("""
                UPDATE home_visit_reports
                SET photo_paths_json = ?, updated_at = CURRENT_TIMESTAMP
                WHERE id = ?;
            """, (photos_str, existing["id"]))
        else:
            cursor.execute("""
                INSERT INTO home_visit_reports (term, year, class_level, advisor_name, fields_json, photo_paths_json)
                VALUES (?, ?, ?, '', '{}', ?);
            """, (t, y, cl, photos_str))
        conn.commit()

    return get_home_visit_report(t, y, cl, db_path)


HOME_VISIT_SCREENING_ITEMS = [
    {"num": "1", "key": "1. จำนวนนักเรียนที่ออกเยี่ยมบ้าน (คน)", "label": "1. จำนวนนักเรียนที่ออกเยี่ยมบ้านทั้งหมด", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "1.1", "key": "1.1 ชาย (คน)", "label": "   1.1 ชาย", "unit": "คน", "type": "number", "is_sub": True},
    {"num": "1.2", "key": "1.2 หญิง (คน)", "label": "   1.2 หญิง", "unit": "คน", "type": "number", "is_sub": True},
    {"num": "2", "key": "2. จำนวนนักเรียนที่ไม่ได้ออกเยี่ยมบ้าน (คน)", "label": "2. จำนวนนักเรียนที่ไม่ได้ออกเยี่ยมบ้าน", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "3", "key": "3. สาเหตุที่ไม่ได้ออกเยี่ยมบ้าน", "label": "3. สาเหตุที่ไม่ได้ออกเยี่ยมบ้าน", "unit": "", "type": "text", "is_sub": False},
    {"num": "4", "key": "4. ครอบครัวอบอุ่น (คน)", "label": "4. ครอบครัวอบอุ่น", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "5", "key": "5. ครอบครัวแตกแยก (คน)", "label": "5. ครอบครัวแตกแยก", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "6", "key": "6. นักเรียนที่บิดาและมารดาเสียชีวิต (คน)", "label": "6. นักเรียนที่บิดาและมารดาเสียชีวิต", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "7", "key": "7. นักเรียนที่บิดาหรือมารดาเสียชีวิต (คน)", "label": "7. นักเรียนที่บิดาหรือมารดาเสียชีวิต", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "8", "key": "8. นักเรียนที่บิดาหรือมารดาเลิกร้างกัน (คน)", "label": "8. นักเรียนที่บิดาหรือมารดาเลิกร้างกัน", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "9", "key": "9. นักเรียนไม่ได้อาศัยกับบิดาหรือมารดาของตนเอง (คน)", "label": "9. นักเรียนไม่ได้อาศัยกับบิดาหรือมารดาของตนเอง", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "10", "key": "10. นักเรียนเสี่ยงหรือมีปัญหาด้านการเรียน (คน)", "label": "10. นักเรียนเสี่ยงหรือมีปัญหาด้านการเรียน", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "11", "key": "11. นักเรียนมีปัญหาด้านสุขภาพ (คน)", "label": "11. นักเรียนมีปัญหาด้านสุขภาพ", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "12", "key": "12. นักเรียนมีพฤติกรรมเสี่ยง (คน)", "label": "12. นักเรียนมีพฤติกรรมเสี่ยง (รวม)", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "12.1", "key": "12.1 เสี่ยงด้านสุขภาพ (คน)", "label": "   12.1 เสี่ยงด้านสุขภาพ", "unit": "คน", "type": "number", "is_sub": True},
    {"num": "12.2", "key": "12.2 เสี่ยงด้านการใช้สารเสพติด (คน)", "label": "   12.2 เสี่ยงด้านการใช้สารเสพติด", "unit": "คน", "type": "number", "is_sub": True},
    {"num": "12.3", "key": "12.3 เสี่ยงด้านความรุนแรง", "label": "   12.3 เสี่ยงด้านความรุนแรง", "unit": "คน", "type": "number", "is_sub": True},
    {"num": "12.4", "key": "12.4 เสี่ยงด้านการเดินทางมาเรียน", "label": "   12.4 เสี่ยงด้านการเดินทางมาเรียน", "unit": "คน", "type": "number", "is_sub": True},
    {"num": "12.5", "key": "12.5 เสี่ยงด้านเพศ", "label": "   12.5 เสี่ยงด้านเพศ", "unit": "คน", "type": "number", "is_sub": True},
    {"num": "12.6", "key": "12.6 เสี่ยงติดเกม", "label": "   12.6 เสี่ยงติดเกม", "unit": "คน", "type": "number", "is_sub": True},
    {"num": "12.7", "key": "12.7 เสี่ยงด้านอื่นๆ (โปรดระบุ)", "label": "   12.7 เสี่ยงด้านอื่นๆ (โปรดระบุ)", "unit": "", "type": "text", "is_sub": True},
    {"num": "13", "key": "13. นักเรียนมีปัญหาด้านเศรษฐกิจ (คน)", "label": "13. นักเรียนมีปัญหาด้านเศรษฐกิจ", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "14", "key": "14. นักเรียนมีปัญหาอื่นๆ (คน)", "label": "14. นักเรียนมีปัญหาอื่นๆ", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "14.1", "key": "14.1 ระบุปัญหาที่พบ", "label": "   14.1 ระบุปัญหาที่พบ", "unit": "", "type": "text", "is_sub": True},
    {"num": "15", "key": "15. นักเรียนที่ต้องได้รับการช่วยเหลือเร่งด่วน (คน)", "label": "15. นักเรียนที่ต้องได้รับการช่วยเหลือเร่งด่วน", "unit": "คน", "type": "number", "is_sub": False},
    {"num": "16", "key": "16. หน่วยงาน/สหวิชาชีพ/องค์กร ที่ร่วมเยี่ยมบ้าน", "label": "16. หน่วยงาน/สหวิชาชีพ/องค์กร ที่ร่วมเยี่ยมบ้าน", "unit": "", "type": "text", "is_sub": False},
    {"num": "17", "key": "17. การนำข้อมูลเยี่ยมบ้านไปใช้ประโยชน์อย่างไร", "label": "17. การนำข้อมูลเยี่ยมบ้านไปใช้ประโยชน์อย่างไร", "unit": "", "type": "text", "is_sub": False},
    {"num": "18", "key": "18. ข้อห่วงใยของผู้ปกครองที่มีต่อนักเรียน", "label": "18. ข้อห่วงใยของผู้ปกครองที่มีต่อนักเรียน", "unit": "", "type": "text", "is_sub": False},
]


def clean_narrative_item_text(text: str) -> str:
    """
    Cleans teacher narrative responses:
    - Strips leading numbers or item references (e.g. '1.', '1)', '(1)', '1.1', 'ข้อ 1', 'ข้อ 1.', '3.', '16.', etc.)
    - Strips leading bullets or dashes (-, *, •)
    - Strips whitespace
    - Returns '' if value is '-', 'ไม่มี', 'ไม่พบ', etc.
    """
    if not text:
        return ""
    t = str(text).strip()
    if t in ("-", "--", "---", "ไม่มี", "ไม่พบ", "ไม่มีข้อมูล", "ปกติ"):
        return ""
    # Strip leading item numbers, item prefix, or bullets
    cleaned = re.sub(r'^(?:(?:ข้อ\s*)?\(?\d+(?:\.\d+)?\)?[\.\)\s\:\-]*|[\-\*\•\–\—]\s*)+', '', t).strip()
    return cleaned


def get_home_visit_summary(term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> Dict[str, Any]:
    """Calculate and return school-wide home visit summary & class comparisons."""
    init_home_visit_tables(db_path)
    t = str(term).strip()
    y = str(year).strip()
    levels = ['ม.1', 'ม.2', 'ม.3', 'ม.4', 'ม.5', 'ม.6']

    # Class advisors
    advisors_list = get_class_advisors(t, y, db_path=db_path)
    advisor_map = {item['class_level']: ', '.join(filter(None, [item.get('advisor1', ''), item.get('advisor2', ''), item.get('advisor3', '')])) for item in advisors_list}

    # Student count per class (Active students only to match Attendance)
    counts_map = {}
    with get_connection(db_path) as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT class_level, COUNT(*) as cnt FROM class_students WHERE term = ? AND year = ? AND is_active = 1 GROUP BY class_level;",
            (t, y)
        )
        for r in cursor.fetchall():
            counts_map[r["class_level"]] = r["cnt"]

    class_reports = []
    all_class_fields = {}
    total_students_school = 0
    total_visited = 0
    total_male = 0
    total_female = 0
    total_not_visited = 0
    warm_family = 0
    broken_family = 0
    deceased_parents = 0
    divorced_parents = 0
    not_with_parents = 0
    learning_risk = 0
    health_problem = 0
    behavior_risk = 0
    economy_problem = 0
    urgent_help = 0

    def _to_int(val):
        try:
            return int(float(str(val).strip()))
        except (ValueError, TypeError):
            return 0

    for cl in levels:
        rep = get_home_visit_report(t, y, cl, db_path)
        # Class advisors strictly reference Settings (class_advisors) as primary source
        adv = advisor_map.get(cl) or (rep and rep.get("advisor_name")) or ""
        f = (rep and rep.get("fields")) or {}
        all_class_fields[cl] = f
        photos = (rep and rep.get("photos")) or []

        st_count = counts_map.get(cl, 0)
        c_visited = _to_int(f.get("1. จำนวนนักเรียนที่ออกเยี่ยมบ้าน (คน)"))
        c_male = _to_int(f.get("1.1 ชาย (คน)"))
        c_female = _to_int(f.get("1.2 หญิง (คน)"))
        c_not_visited = _to_int(f.get("2. จำนวนนักเรียนที่ไม่ได้ออกเยี่ยมบ้าน (คน)"))

        if c_visited == 0 and (c_male + c_female) > 0:
            c_visited = c_male + c_female

        # If report specifies visited + not_visited, prioritize the form's evaluated total
        form_total = c_visited + c_not_visited
        if form_total > 0:
            st_count = form_total

        is_completed = (rep is not None) and (c_visited > 0 or len(photos) > 0 or len(f) > 3)
        pct = (c_visited / st_count * 100.0) if st_count > 0 else (100.0 if is_completed else 0.0)
        if pct > 100.0:
            pct = 100.0

        total_students_school += st_count
        total_visited += c_visited
        total_male += c_male
        total_female += c_female
        total_not_visited += c_not_visited
        warm_family += _to_int(f.get("4. ครอบครัวอบอุ่น (คน)"))
        broken_family += _to_int(f.get("5. ครอบครัวแตกแยก (คน)"))
        deceased_parents += _to_int(f.get("6. นักเรียนที่บิดาและมารดาเสียชีวิต (คน)")) + _to_int(f.get("7. นักเรียนที่บิดาหรือมารดาเสียชีวิต (คน)"))
        divorced_parents += _to_int(f.get("8. นักเรียนที่บิดาหรือมารดาเลิกร้างกัน (คน)"))
        not_with_parents += _to_int(f.get("9. นักเรียนไม่ได้อาศัยกับบิดาหรือมารดาของตนเอง (คน)"))
        learning_risk += _to_int(f.get("10. นักเรียนเสี่ยงหรือมีปัญหาด้านการเรียน (คน)"))
        health_problem += _to_int(f.get("11. นักเรียนมีปัญหาด้านสุขภาพ (คน)"))
        behavior_risk += _to_int(f.get("12. นักเรียนมีพฤติกรรมเสี่ยง (คน)"))
        economy_problem += _to_int(f.get("13. นักเรียนมีปัญหาด้านเศรษฐกิจ (คน)"))
        urgent_help += _to_int(f.get("15. นักเรียนที่ต้องได้รับการช่วยเหลือเร่งด่วน (คน)"))

        class_reports.append({
            "class_level": cl,
            "advisor_name": adv,
            "recorded_by_name": rep.get("recorded_by_name") if rep else "",
            "recorded_at": rep.get("recorded_at") if rep else (rep.get("updated_at") if rep else None),
            "student_count": st_count,
            "visited_count": c_visited,
            "male_count": c_male,
            "female_count": c_female,
            "not_visited_count": c_not_visited,
            "percentage": round(pct, 1),
            "is_completed": is_completed,
            "photos_count": len(photos),
            "updated_at": rep.get("updated_at") if rep else None,
            "report_data": rep
        })

    school_pct = (total_visited / total_students_school * 100.0) if total_students_school > 0 else 0.0

    # Aggregated screening data across all grade levels
    screening_totals = []
    for item in HOME_VISIT_SCREENING_ITEMS:
        key = item["key"]
        i_type = item["type"]
        by_class = {}

        if i_type == "number":
            tot = 0
            for cl in levels:
                f = all_class_fields.get(cl, {})
                v = _to_int(f.get(key))
                if v == 0 and key.endswith(" (คน)"):
                    v = _to_int(f.get(key[:-6]))
                if key == "1. จำนวนนักเรียนที่ออกเยี่ยมบ้าน (คน)" and v == 0:
                    v = _to_int(f.get("1.1 ชาย (คน)")) + _to_int(f.get("1.2 หญิง (คน)"))
                by_class[cl] = v
                tot += v

            screening_totals.append({
                "num": item["num"],
                "key": key,
                "label": item["label"],
                "value": str(tot),
                "numeric_value": tot,
                "unit": item["unit"],
                "type": "number",
                "is_sub": item["is_sub"],
                "by_class": by_class
            })
        else:
            bullet_lines = []
            for cl in levels:
                f = all_class_fields.get(cl, {})
                raw_val = str(f.get(key, "")).strip()
                if not raw_val and key.endswith(" (โปรดระบุ)"):
                    raw_val = str(f.get(key[:-12], "")).strip()

                cl_cleaned_parts = []
                for subline in raw_val.split("\n"):
                    c_line = clean_narrative_item_text(subline)
                    if c_line:
                        cl_cleaned_parts.append(c_line)
                        bullet_lines.append(f"-\u00a0{c_line}")

                by_class[cl] = "\n".join(cl_cleaned_parts) if cl_cleaned_parts else "-"

            combined_text = "\n".join(bullet_lines) if bullet_lines else "-"
            screening_totals.append({
                "num": item["num"],
                "key": key,
                "label": item["label"],
                "value": combined_text,
                "unit": "",
                "type": "text",
                "is_sub": item["is_sub"],
                "by_class": by_class
            })

    return {
        "term": t,
        "year": y,
        "summary": {
            "total_students": total_students_school,
            "total_visited": total_visited,
            "total_male": total_male,
            "total_female": total_female,
            "total_not_visited": total_not_visited,
            "average_percentage": round(school_pct, 1),
            "warm_family": warm_family,
            "broken_family": broken_family,
            "deceased_parents": deceased_parents,
            "divorced_parents": divorced_parents,
            "not_with_parents": not_with_parents,
            "learning_risk": learning_risk,
            "health_problem": health_problem,
            "behavior_risk": behavior_risk,
            "economy_problem": economy_problem,
            "urgent_help": urgent_help
        },
        "classes": class_reports,
        "screening_totals": screening_totals
    }


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Manage SQLite School Grading Archive.")
    parser.add_argument("--init", action="store_true", help="Initialize database schema")
    parser.add_argument("--ingest", type=str, help="Path to JSON file to ingest (e.g. output.json)")
    parser.add_argument("--db", type=str, default=DB_DEFAULT_PATH, help="Path to SQLite DB file")
    parser.add_argument("--list", action="store_true", help="List all courses and grade counts")

    args = parser.parse_args()

    if args.init:
        init_db(args.db)
        print(f"[SUCCESS] Initialized database at: {args.db}")

    if args.ingest:
        summary = ingest_parsed_json(args.ingest, args.db)
        print(f"[SUCCESS] Ingested course: {summary['course_code']} ({summary['year']}/{summary['term']})")
        print(f"          Students upserted: {summary['students_upserted']}")
        print(f"          Grades recorded:   {summary['grades_upserted']}")

    if args.list:
        with get_connection(args.db) as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT course_code, course_name, term, year, teacher FROM courses;")
            courses = cursor.fetchall()
            print("\n=== ARCHIVED COURSES ===")
            for c in courses:
                cursor.execute(
                    "SELECT COUNT(*) FROM grades_history WHERE course_code = ? AND term = ? AND year = ?;",
                    (c["course_code"], c["term"], c["year"])
                )
                cnt = cursor.fetchone()[0]
                print(f"Course: {c['course_code']} {c['course_name']} | Term: {c['term']}/{c['year']} | Teacher: {c['teacher']} | Records: {cnt}")


# ==============================================================================
# DMC EXPORT & COLUMN DEFINITION SYSTEM
# ==============================================================================

DMC_COLUMNS_SPEC = [
    {"col_num": 1, "header": "รหัสโรงเรียน", "field": "school_id", "group": "school", "group_th": "ข้อมูลโรงเรียน"},
    {"col_num": 2, "header": "ชื่อโรงเรียน", "field": "school_name", "group": "school", "group_th": "ข้อมูลโรงเรียน"},
    {"col_num": 3, "header": "เลขประจำตัวนักเรียน", "field": "citizen_id", "label_th": "เลขประจำตัวประชาชน (13 หลัก)", "group": "student", "group_th": "ข้อมูลนักเรียน"},
    {"col_num": 4, "header": "ชั้น", "field": "class_level", "group": "student", "group_th": "ข้อมูลนักเรียน"},
    {"col_num": 5, "header": "ห้อง", "field": "room", "group": "student", "group_th": "ข้อมูลนักเรียน"},
    {"col_num": 6, "header": "เลขประจำตัวนักเรียน", "field": "student_id", "label_th": "เลขประจำตัวนักเรียน (รหัสนักเรียน)", "group": "student", "group_th": "ข้อมูลนักเรียน"},
    {"col_num": 7, "header": "เพศ", "field": "gender", "group": "student", "group_th": "ข้อมูลนักเรียน"},
    {"col_num": 8, "header": "คำนำหน้าชื่อ", "field": "prefix", "group": "student", "group_th": "ข้อมูลนักเรียน"},
    {"col_num": 9, "header": "ชื่อ", "field": "first_name", "group": "student", "group_th": "ข้อมูลนักเรียน"},
    {"col_num": 10, "header": "นามสกุล", "field": "last_name", "group": "student", "group_th": "ข้อมูลนักเรียน"},
    {"col_num": 11, "header": "วันเกิด", "field": "birth_date", "group": "health", "group_th": "ข้อมูลสุขภาพและส่วนตัว"},
    {"col_num": 12, "header": "อายุ(ปี)", "field": "age", "group": "health", "group_th": "ข้อมูลสุขภาพและส่วนตัว"},
    {"col_num": 13, "header": "น้ำหนัก", "field": "weight", "group": "health", "group_th": "ข้อมูลสุขภาพและส่วนตัว"},
    {"col_num": 14, "header": "ส่วนสูง", "field": "height", "group": "health", "group_th": "ข้อมูลสุขภาพและส่วนตัว"},
    {"col_num": 15, "header": "กลุ่มเลือด", "field": "blood_group", "group": "health", "group_th": "ข้อมูลสุขภาพและส่วนตัว"},
    {"col_num": 16, "header": "ศาสนา", "field": "religion", "group": "health", "group_th": "ข้อมูลสุขภาพและส่วนตัว"},
    {"col_num": 17, "header": "เชื้อชาติ", "field": "race", "group": "health", "group_th": "ข้อมูลสุขภาพและส่วนตัว"},
    {"col_num": 18, "header": "สัญชาติ", "field": "nationality", "group": "health", "group_th": "ข้อมูลสุขภาพและส่วนตัว"},
    {"col_num": 19, "header": "บ้านเลขที่", "field": "address_no", "group": "address", "group_th": "ที่อยู่ตามทะเบียนบ้าน"},
    {"col_num": 20, "header": "หมู่", "field": "moo", "group": "address", "group_th": "ที่อยู่ตามทะเบียนบ้าน"},
    {"col_num": 21, "header": "ถนน/ซอย", "field": "street", "group": "address", "group_th": "ที่อยู่ตามทะเบียนบ้าน"},
    {"col_num": 22, "header": "ตำบล", "field": "subdistrict", "group": "address", "group_th": "ที่อยู่ตามทะเบียนบ้าน"},
    {"col_num": 23, "header": "อำเภอ", "field": "district", "group": "address", "group_th": "ที่อยู่ตามทะเบียนบ้าน"},
    {"col_num": 24, "header": "จังหวัด", "field": "province", "group": "address", "group_th": "ที่อยู่ตามทะเบียนบ้าน"},
    {"col_num": 25, "header": "คำนำหน้าชื่อผู้ปกครอง", "field": "guardian_prefix", "group": "guardian", "group_th": "ข้อมูลผู้ปกครอง"},
    {"col_num": 26, "header": "ชื่อผู้ปกครอง", "field": "guardian_name", "group": "guardian", "group_th": "ข้อมูลผู้ปกครอง"},
    {"col_num": 27, "header": "นามสกุลผู้ปกครอง", "field": "guardian_lastname", "group": "guardian", "group_th": "ข้อมูลผู้ปกครอง"},
    {"col_num": 28, "header": "อาชีพของผู้ปกครอง", "field": "guardian_occupation", "group": "guardian", "group_th": "ข้อมูลผู้ปกครอง"},
    {"col_num": 29, "header": "ความเกี่ยวข้องของผู้ปกครองกับนักเรียน", "field": "guardian_relation", "group": "guardian", "group_th": "ข้อมูลผู้ปกครอง"},
    {"col_num": 30, "header": "คำนำหน้าชื่อบิดา", "field": "father_prefix", "group": "parents", "group_th": "ข้อมูลบิดา-มารดา"},
    {"col_num": 31, "header": "ชื่อบิดา", "field": "father_name", "group": "parents", "group_th": "ข้อมูลบิดา-มารดา"},
    {"col_num": 32, "header": "นามสกุลบิดา", "field": "father_lastname", "group": "parents", "group_th": "ข้อมูลบิดา-มารดา"},
    {"col_num": 33, "header": "อาชีพของบิดา", "field": "father_occupation", "group": "parents", "group_th": "ข้อมูลบิดา-มารดา"},
    {"col_num": 34, "header": "คำนำหน้าชื่อมารดา", "field": "mother_prefix", "group": "parents", "group_th": "ข้อมูลบิดา-มารดา"},
    {"col_num": 35, "header": "ชื่อมารดา", "field": "mother_name", "group": "parents", "group_th": "ข้อมูลบิดา-มารดา"},
    {"col_num": 36, "header": "นามสกุลมารดา", "field": "mother_lastname", "group": "parents", "group_th": "ข้อมูลบิดา-มารดา"},
    {"col_num": 37, "header": "อาชีพของมารดา", "field": "mother_occupation", "group": "parents", "group_th": "ข้อมูลบิดา-มารดา"},
    {"col_num": 38, "header": "ความด้อยโอกาส", "field": "disadvantaged", "group": "status", "group_th": "สถานะและสิทธิ์"},
    {"col_num": 39, "header": "ยังไม่สามารถจำหน่ายได้ (3.1.8)", "field": "cannot_discharge", "group": "status", "group_th": "สถานะและสิทธิ์"},
]


def get_dmc_columns_definition() -> List[Dict[str, Any]]:
    """Return available DMC columns with groups for frontend column selection."""
    return DMC_COLUMNS_SPEC


def export_students_dmc_excel(
    term: str = "1",
    year: str = "2569",
    class_level: str = "ม.1",
    room: str = "all",
    student_ids: Optional[List[str]] = None,
    columns_subset: Optional[List[str]] = None,
    db_path: str = DB_DEFAULT_PATH,
    hide_citizen_id: bool = False
) -> bytes:
    """
    Export students in official DMC Excel format (.xlsx)
    Supports room filtering, custom student ID selection, and column subsets
    strictly maintaining the original DMC column ordering.
    hide_citizen_id leaves the เลขประจำตัวประชาชน column blank (non-admin exports).
    """
    import io
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    import datetime

    init_db(db_path)
    t = str(term).strip()
    y = str(year).strip()

    # Filter active columns
    if columns_subset and len(columns_subset) > 0:
        subset_set = set(columns_subset)
        active_cols = [
            c for c in DMC_COLUMNS_SPEC
            if c["field"] in subset_set or c["header"] in subset_set or str(c["col_num"]) in subset_set
        ]
        if not active_cols:
            active_cols = DMC_COLUMNS_SPEC
    else:
        active_cols = DMC_COLUMNS_SPEC

    # Query students
    with get_connection(db_path) as conn:
        cursor = conn.cursor()

        query = """
            SELECT cs.student_id, cs.student_no, cs.class_level, cs.room, cs.full_name,
                   cs.prefix AS cs_prefix, cs.first_name AS cs_first, cs.last_name AS cs_last,
                   d.school_id, d.school_name, d.citizen_id, d.gender, d.prefix, d.first_name, d.last_name,
                   d.birth_date, d.age, d.weight, d.height, d.blood_group, d.religion, d.race, d.nationality,
                   d.address_no, d.moo, d.street, d.subdistrict, d.district, d.province,
                   d.guardian_prefix, d.guardian_name, d.guardian_lastname, d.guardian_occupation, d.guardian_relation,
                   d.father_prefix, d.father_name, d.father_lastname, d.father_occupation,
                   d.mother_prefix, d.mother_name, d.mother_lastname, d.mother_occupation,
                   d.disadvantaged, d.cannot_discharge
            FROM class_students cs
            LEFT JOIN student_dmc_info d ON cs.student_id = d.student_id
            WHERE cs.term = ? AND cs.year = ? AND cs.is_active = 1
        """
        params: List[Any] = [t, y]

        if class_level and class_level != "all":
            query += " AND cs.class_level = ?"
            params.append(str(class_level).strip())

        if room and room != "all":
            query += " AND cs.room = ?"
            params.append(str(room).strip())

        if student_ids and len(student_ids) > 0:
            placeholders = ",".join("?" for _ in student_ids)
            query += f" AND cs.student_id IN ({placeholders})"
            params.extend([str(sid).strip() for sid in student_ids])

        query += " ORDER BY cs.class_level, CAST(cs.room AS INTEGER), cs.student_no;"
        rows = cursor.execute(query, params).fetchall()

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Student_DMC"

    # Row 1: Timestamp metadata
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")
    ws.cell(1, 1, f"วันและเวลาที่สร้างรายงาน {now_str}")
    ws.cell(1, 1).font = Font(name="Tahoma", size=9, color="555555")

    # Row 2: Headers
    header_fill = PatternFill(start_color="351C75", end_color="351C75", fill_type="solid")
    header_font = Font(name="Tahoma", size=10, bold=True, color="FACC15")
    header_align = Alignment(horizontal="center", vertical="center", wrap_text=True)
    thin_border = Border(
        left=Side(style='thin', color='E5E7EB'),
        right=Side(style='thin', color='E5E7EB'),
        top=Side(style='thin', color='E5E7EB'),
        bottom=Side(style='thin', color='E5E7EB')
    )

    ws.row_dimensions[2].height = 28
    for col_idx, c_info in enumerate(active_cols, start=1):
        cell = ws.cell(2, col_idx, c_info["header"])
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = header_align
        cell.border = thin_border

    # Data Rows
    row_font = Font(name="Tahoma", size=10)
    zebra_fill = PatternFill(start_color="FCFAF2", end_color="FCFAF2", fill_type="solid")

    for r_idx, r in enumerate(rows, start=3):
        ws.row_dimensions[r_idx].height = 20
        use_zebra = (r_idx % 2 == 1)
        # คำนำหน้า / ชื่อ / นามสกุล คนละช่องตามหัวตาราง: จากรายชื่อ (ที่ทุกหน้าใช้) ก่อน แล้วจึงข้อมูล DMC;
        # คนที่ไม่มีสามช่องเลย ตัดจากชื่อเต็ม • เพศ: ข้อมูล DMC หรือตามคำนำหน้า (owner 10 พ.ย. 2569)
        n_prefix, n_first, n_last = (str(r[k] or "").strip() for k in ("cs_prefix", "cs_first", "cs_last"))
        if not n_first:
            n_prefix, n_first, n_last = (str(r[k] or "").strip() for k in ("prefix", "first_name", "last_name"))
        if not n_first:
            n_prefix, n_first, n_last = split_full_name(r["full_name"])
        own = {"prefix": n_prefix, "first_name": n_first, "last_name": n_last,
               "gender": str(r["gender"] or "").strip() or gender_from_prefix(n_prefix)}

        for col_idx, c_info in enumerate(active_cols, start=1):
            field = c_info["field"]
            if field in own:
                val = own[field]
            else:
                val = r[field] if field in r.keys() and r[field] is not None else ""

            # Fallbacks from class_students if dmc fields are blank
            if not val:
                if field == "class_level":
                    val = r["class_level"]
                elif field == "room":
                    val = r["room"]
                elif field == "student_id":
                    val = r["student_id"]
                elif field == "school_name":
                    val = school_profile.short_name(db_path)
                elif field == "school_id":
                    val = school_profile.get("school_id", db_path)

            if hide_citizen_id and field == "citizen_id":
                val = ""  # เลขบัตรประชาชน: admin only

            cell = ws.cell(r_idx, col_idx, str(val))
            cell.font = row_font
            cell.border = thin_border
            if use_zebra:
                cell.fill = zebra_fill

            # Alignments
            if field in ("school_id", "citizen_id", "student_id", "room", "age", "weight", "height", "gender"):
                cell.alignment = Alignment(horizontal="center", vertical="center")
            else:
                cell.alignment = Alignment(horizontal="left", vertical="center")

    # Column widths autofit
    for col in ws.columns:
        max_len = 0
        col_letter = col[0].column_letter
        for cell in col[1:]:
            val_s = str(cell.value or "")
            max_len = max(max_len, len(val_s))
        ws.column_dimensions[col_letter].width = max(12, min(max_len + 4, 30))

    out_bytes = io.BytesIO()
    wb.save(out_bytes)
    return out_bytes.getvalue()


def generate_students_template_excel(db_path: str = DB_DEFAULT_PATH) -> bytes:
    """
    Generate official standard student roster Excel template (.xlsx)
    with clean headers, validation tips, and sample data.
    Compatible with parse_dmc_file and standard school imports.
    """
    import io
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "รายชื่อนักเรียน"
    ws.views.sheetView[0].showGridLines = True

    # Styling
    school_name = get_app_setting("school_name", "โรงเรียน...", db_path=db_path)
    font_title = Font(name="Sarabun", size=14, bold=True, color="1A237E")
    font_sub = Font(name="Sarabun", size=10, italic=True, color="555555")
    font_header = Font(name="Sarabun", size=11, bold=True, color="FFFFFF")
    font_cell = Font(name="Sarabun", size=10)

    fill_header = PatternFill(start_color="1A237E", end_color="1A237E", fill_type="solid")
    fill_zebra = PatternFill(start_color="F5F7FA", end_color="F5F7FA", fill_type="solid")

    thin_border = Border(
        left=Side(style="thin", color="CCCCCC"),
        right=Side(style="thin", color="CCCCCC"),
        top=Side(style="thin", color="CCCCCC"),
        bottom=Side(style="thin", color="CCCCCC")
    )

    # Title Banner
    ws.merge_cells("A1:J1")
    ws["A1"] = f"แบบฟอร์มนำเข้ารายชื่อนักเรียนมาตรฐาน - {school_name}"
    ws["A1"].font = font_title
    ws["A1"].alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[1].height = 28

    ws.merge_cells("A2:J2")
    ws["A2"] = "* กรอกข้อมูลนักเรียนตามคอลัมน์ด้านล่าง สามารถอัปโหลดนำเข้าสู่ระบบได้ทันที (รองรับทั้งไฟล์นี้และไฟล์ส่งออกจาก DMC สพฐ.)"
    ws["A2"].font = font_sub
    ws["A2"].alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[2].height = 20

    # Headers (Row 3)
    headers = [
        ("A", "เลขที่", 8),
        ("B", "รหัสประจำตัวนักเรียน", 18),
        ("C", "เลขประจำตัวประชาชน", 22),
        ("D", "คำนำหน้า", 14),
        ("E", "ชื่อ", 18),
        ("F", "นามสกุล", 20),
        ("G", "ระดับชั้น", 12),
        ("H", "ห้อง", 10),
        ("I", "เพศ", 10),
        ("J", "สถานะ", 12),
    ]

    ws.row_dimensions[3].height = 26
    for col_letter, h_text, width in headers:
        cell = ws[f"{col_letter}3"]
        cell.value = h_text
        cell.font = font_header
        cell.fill = fill_header
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        cell.border = thin_border
        ws.column_dimensions[col_letter].width = width

    # Sample rows (Rows 4-8)
    sample_data = [
        (1, "10001", "1439900123451", "เด็กชาย", "สมชาย", "ใจดี", "ม.1", "1", "ช", "ปกติ"),
        (2, "10002", "1439900123452", "เด็กหญิง", "สมศรี", "มีสุข", "ม.1", "1", "ญ", "ปกติ"),
        (3, "10003", "1439900123453", "เด็กชาย", "กิตติ", "รักเรียน", "ม.1", "1", "ช", "ปกติ"),
        (4, "10004", "1439900123454", "เด็กหญิง", "พรทิพย์", "แสงจันทร์", "ม.1", "1", "ญ", "ปกติ"),
        (5, "10005", "1439900123455", "เด็กชาย", "อนุชา", "มั่นคง", "ม.1", "2", "ช", "ปกติ"),
    ]

    for r_idx, row in enumerate(sample_data, start=4):
        ws.row_dimensions[r_idx].height = 22
        for c_idx, val in enumerate(row, start=1):
            cell = ws.cell(r_idx, c_idx, str(val))
            cell.font = font_cell
            cell.border = thin_border
            if r_idx % 2 == 1:
                cell.fill = fill_zebra
            if c_idx in (1, 2, 3, 7, 8, 9, 10):
                cell.alignment = Alignment(horizontal="center", vertical="center")
            else:
                cell.alignment = Alignment(horizontal="left", vertical="center")

    out_bytes = io.BytesIO()
    wb.save(out_bytes)
    return out_bytes.getvalue()


def reset_all_daily_attendance(
    term: str,
    year: str,
    mode: str = "empty",
    class_levels: Optional[List[str]] = None,
    db_path: str = "school_archive.db"
) -> Dict[str, Any]:
    """
    Reset daily attendance for all 6 class levels (ม.1 - ม.6) or selected levels in a semester.
    If mode == "empty": sets all non-holiday slots as '' (blank / reset).
    If mode == "all_present": sets all non-holiday slots as '/' (all present).
    Also cascades into courses via sync_daily_attendance_to_courses.
    """
    if not class_levels:
        class_levels = ["ม.1", "ม.2", "ม.3", "ม.4", "ม.5", "ม.6"]

    start_date = get_semester_start_date(term, year, db_path=db_path)
    total_students_updated = 0
    results_per_level = {}

    for lvl in class_levels:
        grid_data = get_daily_attendance_grid(
            term=term,
            year=year,
            class_level=lvl,
            room=None,
            start_date_override=start_date,
            db_path=db_path
        )
        students = grid_data.get("students", [])
        holidays = grid_data.get("holidays", [])
        locked_counted = grid_data.get("locked_counted", [])

        if not students:
            continue

        for st in students:
            if st.get("is_locked"):
                continue
            status_list = [""] * 100
            if mode == "all_present":
                for i in range(100):
                    if i in holidays:
                        status_list[i] = ""
                    else:
                        status_list[i] = "/"
            st["status_list"] = status_list
            total_students_updated += 1

        save_res = save_daily_attendance_grid(
            term=term,
            year=year,
            class_level=lvl,
            start_date=start_date,
            holidays=holidays,
            locked_counted=locked_counted,
            students=students,
            db_path=db_path
        )
        results_per_level[lvl] = save_res.get("saved_count", len(students))

    return {
        "status": "success",
        "mode": mode,
        "total_students_updated": total_students_updated,
        "levels": results_per_level
    }
