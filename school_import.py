"""
ฟอร์มนำเข้าข้อมูลโรงเรียน: one workbook whose sheets map one-to-one onto the database, made for schools with
several rooms per level and several programmes (แผนการเรียน).

  sheet              -> table(s)
  1 ครู              -> school_teachers (a new teacher's first PIN is the teacher code)
  2 โปรแกรม          -> programs
  3 ห้องเรียน        -> class_rooms (+ class_advisors, which the per-level screens still read)
  4 นักเรียน         -> students, class_students (+ program), student_dmc_info (name parts, gender, citizen id)
  5 รายวิชา          -> course_catalog, courses (+ programs: only those programmes take the course)
  6 ครูผู้สอน        -> course_sections (teacher per course per room) -> courses.teacher
  7 ตารางสอน        -> teacher_timetables (the whole timetable of every teacher in the sheet) -> courses.schedule_json
  8 ลงทะเบียนรายคน   -> grades_history of courses enrolled by name (courses.enrol_mode = 'list')

preview() only reads. commit() checks the same file again, refuses while an error is left, backs the database up,
writes everything in one transaction and ends with database.sync_semester_attendance_to_courses (attendance recount
and the ปพ.5 refresh queue). Nothing is deleted except the timetable of each teacher in sheet 7 and the sections of
each course in sheet 6, which the sheet replaces. An empty or missing sheet leaves its tables as they are.

ปพ.5, scores, attendance and exams still work per course code: a course taught by several teachers keeps the first
section's teacher and the first room's timetable in `courses` until those screens learn about sections.
"""
import io
import json
import re
from datetime import datetime
from typing import Any, Dict, List, Optional, Set, Tuple

import database
from database import DB_DEFAULT_PATH, get_connection, normalize_teacher_base_name

LEVELS = ["ม.1", "ม.2", "ม.3", "ม.4", "ม.5", "ม.6"]
DAY_NAMES = {1: "จันทร์", 2: "อังคาร", 3: "พุธ", 4: "พฤหัสบดี", 5: "ศุกร์"}
COURSE_TYPES = ["พื้นฐาน", "เพิ่มเติม", "กิจกรรม"]
STAGES = {"ม.ต้น": "2", "ม.ปลาย": "3", "ทุกช่วงชั้น": ""}
ALL_ROOMS = "*"
COURSE_CODE = re.compile(r"^[ก-ฮA-Z]\d{5}$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS programs (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    stage TEXT DEFAULT '',            -- '2' ม.ต้น, '3' ม.ปลาย, '' every level
    note TEXT DEFAULT '',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS class_rooms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    term TEXT NOT NULL,
    year TEXT NOT NULL,
    class_level TEXT NOT NULL,
    room TEXT NOT NULL,
    program TEXT DEFAULT '',
    advisor1 TEXT DEFAULT '',
    advisor2 TEXT DEFAULT '',
    advisor3 TEXT DEFAULT '',
    no_checkin INTEGER DEFAULT 0,     -- its students default to is_locked (no check-in, no ปพ.5)
    note TEXT DEFAULT '',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(term, year, class_level, room)
);
CREATE TABLE IF NOT EXISTS course_sections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    course_code TEXT NOT NULL,
    term TEXT NOT NULL,
    year TEXT NOT NULL,
    class_level TEXT NOT NULL,
    rooms TEXT NOT NULL,              -- '*' every room of the level, else '1,2,3'
    teacher TEXT NOT NULL,
    teacher_code TEXT DEFAULT '',
    note TEXT DEFAULT '',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(course_code, term, year, class_level, rooms)
);
CREATE INDEX IF NOT EXISTS idx_course_sections ON course_sections(course_code, term, year);
"""
EXTRA_COLUMNS = [
    ("class_students", "program", "TEXT DEFAULT ''"),
    ("courses", "programs", "TEXT DEFAULT ''"),
    ("courses", "enrol_mode", "TEXT DEFAULT ''"),
    ("course_catalog", "programs", "TEXT DEFAULT ''"),
]


def ensure_schema(conn) -> None:
    conn.executescript(SCHEMA)
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for table, col, decl in EXTRA_COLUMNS:
        if table in tables and col not in {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
    conn.commit()


# ---------------------------------------------------------------- shared rules (also used by timetable_manager)
def _managed_key(term, year) -> str:
    return f"school_import_{str(term).strip()}_{str(year).strip()}"


def form_managed(conn, term, year) -> bool:
    """A semester imported with the form: the built-in timetable seed must not overwrite it."""
    try:
        return conn.execute("SELECT 1 FROM app_settings WHERE key = ?", (_managed_key(term, year),)).fetchone() is not None
    except Exception:
        return False


def section_count(conn, course_code, term, year) -> int:
    try:
        return conn.execute("SELECT COUNT(*) FROM course_sections WHERE course_code = ? AND term = ? AND year = ?",
                            (course_code, str(term), str(year))).fetchone()[0]
    except Exception:
        return 0


def _split(v) -> List[str]:
    return [x.strip() for x in str(v or "").split(",") if x.strip()]


def eligible_students(conn, course_code, term, year) -> Optional[List[Dict[str, Any]]]:
    """Active students the course enrols automatically: its level(s), and its programmes when it names some.
    None = enrolled by name only (sheet 8), never automatically."""
    t, y = str(term), str(year)
    cols = {r[1] for r in conn.execute("PRAGMA table_info(courses)")}
    has_prog = "programs" in cols
    c = conn.execute(
        f"SELECT class_level{', programs, enrol_mode' if has_prog else ''} FROM courses WHERE course_code = ? AND term = ? AND year = ?",
        (course_code, t, y)).fetchone()
    if not c:
        return []
    if has_prog and (c[2] or "") == "list":
        return None
    levels = _split(c[0])
    progs = set(_split(c[1])) if has_prog else set()
    if not levels:
        return []
    marks = ",".join("?" * len(levels))
    try:
        rows = conn.execute(
            f"""SELECT cs.student_id, cs.student_no, cs.class_level,
                       COALESCE(NULLIF(cs.program, ''), r.program, '') AS program
                FROM class_students cs
                LEFT JOIN class_rooms r ON r.term = cs.term AND r.year = cs.year AND r.class_level = cs.class_level AND r.room = cs.room
                WHERE cs.term = ? AND cs.year = ? AND cs.is_active = 1 AND cs.class_level IN ({marks})
                ORDER BY cs.class_level, cs.student_no, cs.student_id""", (t, y, *levels)).fetchall()
    except Exception:  # before the migration: every student of the level, as before
        rows = conn.execute(
            f"""SELECT student_id, student_no, class_level, '' AS program FROM class_students
                WHERE term = ? AND year = ? AND is_active = 1 AND class_level IN ({marks})
                ORDER BY class_level, student_no, student_id""", (t, y, *levels)).fetchall()
    return [{"student_id": r[0], "student_no": r[1], "class_level": r[2], "program": r[3]}
            for r in rows if not progs or r[3] in progs]


# ---------------------------------------------------------------- cell normalisers
_THAI_DIGITS = str.maketrans("๐๑๒๓๔๕๖๗๘๙", "0123456789")


def clean(v) -> str:
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    s = re.sub(r"\s+", " ", str(v).replace("​", "").replace("\xa0", " ")).strip()
    return "" if s.lower() in ("none", "nan") else s


def norm_level(v) -> Tuple[Optional[str], str]:
    """'ม.1', 'ม1', '1', 'มัธยมศึกษาปีที่ 1', 'ม.1/2' -> ('ม.1', '' or '2'); invalid -> (None, '')."""
    s = clean(v).translate(_THAI_DIGITS).replace(" ", "")
    if not s:
        return "", ""
    m = re.fullmatch(r"(?:มัธยมศึกษาปีที่|มัธยม|ม\.?|M\.?)?([1-6])(?:/(\w{1,6}))?", s, re.I)
    if not m:
        return None, ""
    return f"ม.{m.group(1)}", norm_room(m.group(2) or "")


def norm_room(v) -> str:
    s = clean(v).translate(_THAI_DIGITS).replace("ห้อง", "").replace(" ", "")
    if "/" in s:
        s = s.split("/")[-1]
    return str(int(s)) if s.isdigit() else s


def room_key(r: str):
    return (0, int(r), "") if r.isdigit() else (1, 0, r)


def parse_rooms(v) -> Tuple[Optional[List[str]], bool]:
    """'' / 'ทุกห้อง' -> ([], True) = every room; '1,3-4' -> (['1','3','4'], False); invalid -> (None, False)."""
    s = clean(v).translate(_THAI_DIGITS)
    if not s or s.replace(" ", "") in ("ทุกห้อง", "ทั้งหมด", "ทุก", "*", "all"):
        return [], True
    out: List[str] = []
    for part in re.split(r"[,\s]+", s):
        if not part:
            continue
        m = re.fullmatch(r"(\d+)-(\d+)", part)
        if m:
            a, b = int(m.group(1)), int(m.group(2))
            if a > b or b - a > 30:
                return None, False
            out += [str(i) for i in range(a, b + 1)]
            continue
        r = norm_room(part)
        if not re.fullmatch(r"[0-9A-Za-zก-๙]{1,6}", r):
            return None, False
        out.append(r)
    return sorted(set(out), key=room_key), False


def rooms_text(rooms: List[str], every: bool) -> str:
    return ALL_ROOMS if every else ",".join(rooms)


def norm_sid(v) -> Tuple[str, bool]:
    s = clean(v).translate(_THAI_DIGITS).replace(" ", "")
    padded = s.isdigit() and len(s) < 5
    return (s.zfill(5) if padded else s), padded


def norm_day(v) -> Optional[int]:
    s = clean(v).translate(_THAI_DIGITS).replace("วัน", "").replace(".", "").replace(" ", "").lower()
    names = {"จันทร์": 1, "จ": 1, "mon": 1, "monday": 1, "อังคาร": 2, "อ": 2, "tue": 2, "tuesday": 2,
             "พุธ": 3, "พ": 3, "wed": 3, "wednesday": 3, "พฤหัสบดี": 4, "พฤหัส": 4, "พฤ": 4, "thu": 4, "thursday": 4,
             "ศุกร์": 5, "ศ": 5, "fri": 5, "friday": 5}
    if s in names:
        return names[s]
    return int(s) if s.isdigit() and 1 <= int(s) <= 5 else None


def norm_yes(v) -> Optional[bool]:
    s = clean(v).lower()
    if s in ("", "ไม่", "ไม่ใช่", "no", "n", "false", "0", "-"):
        return None if s == "" else False
    if s in ("ใช่", "y", "yes", "true", "1", "/", "✓", "✔", "x"):
        return True
    return None


def to_int(v) -> Optional[int]:
    s = clean(v).translate(_THAI_DIGITS)
    try:
        f = float(s)
    except ValueError:
        return None
    return int(f) if f.is_integer() else None


def to_float(v) -> Optional[float]:
    try:
        return float(clean(v).translate(_THAI_DIGITS))
    except ValueError:
        return None


def norm_ratio(v) -> Optional[str]:
    s = clean(v).translate(_THAI_DIGITS).replace(" ", "")
    if s in ("", "-"):
        return s
    m = re.fullmatch(r"(\d{1,3})[:/\-](\d{1,3})", s)
    if not m or int(m.group(1)) + int(m.group(2)) != 100:
        return None
    return f"{int(m.group(1))}:{int(m.group(2))}"


_PREFIX = re.compile(r"^(เด็กชาย|เด็กหญิง|ด\.ช\.|ด\.ญ\.|นางสาว|นาย|นาง|น\.ส\.)")


def split_name(full: str) -> Tuple[str, str, str]:
    full = clean(full)
    m = _PREFIX.match(full)
    prefix = m.group(1) if m else ""
    rest = full[len(prefix):].strip()
    first, _, last = rest.partition(" ")
    return prefix, first, last.strip()


def _same_name(a, b) -> bool:
    return re.sub(r"\s+", "", a or "") == re.sub(r"\s+", "", b or "")


# ---------------------------------------------------------------- sheets
class Col:
    def __init__(self, key, header, required=False, width=14, text=False, help="", choices=None, ref=None):
        self.key, self.header, self.required, self.width = key, header, required, width
        self.text, self.help, self.choices, self.ref = text, help, choices, ref


class Sheet:
    def __init__(self, key, title, tables, cols, help):
        self.key, self.title, self.tables, self.cols, self.help = key, title, tables, cols, help


TEACHER_REF = ("teachers", "B")
SHEETS = [
    Sheet("teachers", "1 ครู", "school_teachers", [
        Col("code", "รหัสครู", True, 12, True, "รหัสเข้าสู่ระบบของครู (ไม่ซ้ำกัน) ครูใหม่ใช้รหัสนี้เป็น PIN แรก"),
        Col("name", "ชื่อ-สกุล", True, 34, help="มีคำนำหน้า เช่น นางสาวสมหญิง รักเรียน"),
    ], "ครูทุกคนที่เป็นครูผู้สอนหรือครูที่ปรึกษา ครูที่มีในระบบแล้วจับคู่ด้วยรหัสหรือชื่อ (ไม่เปลี่ยนชื่อและ PIN เดิม)"),
    Sheet("programs", "2 โปรแกรม", "programs", [
        Col("code", "รหัสโปรแกรม", True, 14, True, "ตัวย่อสั้น ๆ เช่น SCI, ART, EP, GEN"),
        Col("name", "ชื่อโปรแกรม", True, 34, help="เช่น วิทยาศาสตร์-คณิตศาสตร์"),
        Col("stage", "ช่วงชั้น", False, 14, choices=list(STAGES)),
        Col("note", "หมายเหตุ", False, 30),
    ], "แผนการเรียน/โปรแกรมของโรงเรียน ถ้าไม่มีโปรแกรมให้เว้นแผ่นนี้ว่าง (ทุกคนในระดับชั้นเรียนทุกวิชาของชั้น)"),
    Sheet("rooms", "3 ห้องเรียน", "class_rooms, class_advisors", [
        Col("level", "ระดับชั้น", True, 10, choices=LEVELS),
        Col("room", "ห้อง", True, 8, True, "เลขห้อง เช่น 1, 2 (ม.1/2 ใส่ระดับชั้น ม.1 ห้อง 2)"),
        Col("program", "โปรแกรม", False, 16, help="รหัสหรือชื่อโปรแกรมจากแผ่น 2 (ห้องที่นักเรียนคละโปรแกรม เว้นว่างแล้วระบุรายคนในแผ่น 4)", ref=("programs", "A")),
        Col("advisor1", "ครูที่ปรึกษา 1", False, 30, ref=TEACHER_REF),
        Col("advisor2", "ครูที่ปรึกษา 2", False, 30, ref=TEACHER_REF),
        Col("advisor3", "ครูที่ปรึกษา 3", False, 30, ref=TEACHER_REF),
        Col("no_checkin", "ไม่เช็คชื่อ/ไม่ออก ปพ.5", False, 14, choices=["ใช่"],
            help="ใช่ = ห้องเรียนรูปแบบพิเศษ (เช่น เรียนและทำงาน) ไม่เช็คชื่อและไม่ออก ปพ.5 แต่นับในจำนวนนักเรียน"),
        Col("note", "หมายเหตุ", False, 24),
    ], "หนึ่งแถวต่อหนึ่งห้อง ภาคเรียนเดียวกับที่เลือกตอนนำเข้า"),
    Sheet("students", "4 นักเรียน", "students, class_students, student_dmc_info", [
        Col("sid", "เลขประจำตัวนักเรียน", True, 12, True, "ตั้งเซลล์เป็นข้อความเพื่อเก็บเลข 0 ข้างหน้า (ตัวเลขที่สั้นกว่า 5 หลัก ระบบเติม 0 ให้)"),
        Col("prefix", "คำนำหน้า", False, 10, choices=["เด็กชาย", "เด็กหญิง", "นาย", "นางสาว"]),
        Col("first", "ชื่อ", True, 16),
        Col("last", "นามสกุล", True, 18),
        Col("level", "ระดับชั้น", True, 10, choices=LEVELS),
        Col("room", "ห้อง", True, 8, True),
        Col("no", "เลขที่", False, 8, help="เลขที่ในห้อง (ว่าง = ต่อท้ายให้)"),
        Col("program", "โปรแกรม", False, 14, help="ว่าง = ตามโปรแกรมของห้อง", ref=("programs", "A")),
        Col("gender", "เพศ", False, 8, choices=["ช", "ญ"]),
        Col("cid", "เลขประจำตัวประชาชน", False, 18, True, "ไม่บังคับ (แสดงเฉพาะผู้ดูแลระบบ)"),
        Col("status", "สถานะ", False, 14, choices=["กำลังศึกษา", "ย้ายออก"]),
        Col("no_checkin", "ไม่เช็คชื่อ/ไม่ออก ปพ.5", False, 14, choices=["ใช่", "ไม่"], help="ว่าง = ตามห้อง"),
    ], "รายชื่อนักเรียนของภาคเรียนนี้ (ข้อมูลอื่นจาก DMC นำเข้าได้ที่หน้าเช็คชื่อเหมือนเดิม) นักเรียนที่ไม่อยู่ในไฟล์จะไม่ถูกลบ"),
    Sheet("courses", "5 รายวิชา", "course_catalog, courses", [
        Col("code", "รหัสวิชา", True, 10, True),
        Col("name", "ชื่อวิชา", True, 28),
        Col("level", "ระดับชั้น", True, 10, choices=LEVELS),
        Col("type", "ประเภท", False, 11, choices=COURSE_TYPES, help="ว่าง = อ่านจากรหัสวิชา"),
        Col("department", "กลุ่มสาระการเรียนรู้", False, 30),
        Col("credits", "หน่วยกิต", False, 9),
        Col("periods", "คาบ/สัปดาห์", False, 10, help="ว่าง = นับจากตารางสอน"),
        Col("ratio", "สัดส่วนคะแนน เก็บ:สอบ", False, 12, help="เช่น 70:30 (กิจกรรมใส่ -)"),
        Col("programs", "เรียนเฉพาะโปรแกรม", False, 18, help="ว่าง = นักเรียนทุกคนในระดับชั้น • ใส่รหัสโปรแกรม คั่นด้วยจุลภาค เช่น SCI, ART"),
    ], "รายวิชาที่เปิดสอนในภาคเรียนนี้ หนึ่งแถวต่อหนึ่งรหัสวิชา"),
    Sheet("sections", "6 ครูผู้สอน", "course_sections, courses.teacher", [
        Col("code", "รหัสวิชา", True, 10, True, ref=("courses", "A")),
        Col("level", "ระดับชั้น", False, 10, choices=LEVELS, help="ว่าง = ตามรายวิชา"),
        Col("rooms", "ห้อง", False, 12, True, "ว่าง/ทุกห้อง = ทุกห้องที่เรียนวิชานี้ • 1,2 หรือ 1-3"),
        Col("teacher", "ครูผู้สอน", True, 30, ref=TEACHER_REF, help="ชื่อหรือรหัสครูจากแผ่น 1"),
        Col("note", "หมายเหตุ", False, 20),
    ], "ใครสอนวิชาไหนห้องไหน (วิชาเดียวสอนหลายครูได้ แยกแถวตามห้อง) ว่างทั้งแผ่น = อ่านจากตารางสอน"),
    Sheet("timetable", "7 ตารางสอน", "teacher_timetables, courses.schedule_json", [
        Col("day", "วัน", True, 10, choices=list(DAY_NAMES.values())),
        Col("period", "คาบที่", True, 7),
        Col("span", "จำนวนคาบ", False, 9, help="คาบติดกัน (ว่าง = 1)"),
        Col("code", "รหัสวิชา/กิจกรรม", True, 16, True, "รหัสวิชา หรือชื่อกิจกรรม เช่น PLC ครู, ชุมนุม • สอนรวมหลายชั้น: พ21222, พ33222"),
        Col("name", "ชื่อวิชา/กิจกรรม", False, 24),
        Col("level", "ระดับชั้น", False, 14, help="หลายชั้นคั่นด้วยจุลภาค เช่น ม.1, ม.6 (กิจกรรมของครูเว้นว่างได้)"),
        Col("room", "ห้อง", False, 8, True, "ว่าง = ทุกห้อง • หลายห้องเรียนรวม 1,2"),
        Col("teacher", "ครูผู้สอน", True, 30, ref=TEACHER_REF),
        Col("note", "หมายเหตุ/สถานที่", False, 18),
    ], "หนึ่งแถวต่อหนึ่งคาบสอน ตารางของครูที่อยู่ในแผ่นนี้จะถูกแทนที่ทั้งชุด ครูที่ไม่อยู่ในแผ่นคงเดิม"),
    Sheet("electives", "8 ลงทะเบียนรายคน", "grades_history (enrol_mode = list)", [
        Col("code", "รหัสวิชา", True, 10, True, ref=("courses", "A")),
        Col("sid", "เลขประจำตัวนักเรียน", True, 12, True),
        Col("name", "ชื่อ-สกุล (ไว้ตรวจทาน)", False, 28),
    ], "เฉพาะวิชาเลือกที่นักเรียนเลือกเป็นรายคน (ข้ามห้องได้) วิชาที่อยู่ในแผ่นนี้จะลงทะเบียนเฉพาะคนในรายชื่อ ว่างทั้งแผ่น = ไม่เปลี่ยน"),
]
SHEET_BY_KEY = {s.key: s for s in SHEETS}


def _hnorm(h) -> str:
    s = re.sub(r"\(.*?\)", "", clean(h)).replace("*", "")
    return re.sub(r"\s+", "", s).lower()


# ---------------------------------------------------------------- template
def build_template(term: str, year: str, prefill: bool = True, db_path: str = DB_DEFAULT_PATH, full: bool = False) -> bytes:
    """full=True: also the data sheets 9+ (scores, daily attendance, settings ...) so one file round-trips the whole term."""
    import openpyxl
    from openpyxl.comments import Comment
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from openpyxl.worksheet.datavalidation import DataValidation

    data = _current_rows(term, year, db_path) if prefill else {}
    wb = openpyxl.Workbook()
    font = Font(name="TH SarabunPSK", size=15)
    bold = Font(name="TH SarabunPSK", size=15, bold=True)
    head_font = Font(name="TH SarabunPSK", size=15, bold=True, color="FFFFFF")
    req_fill = PatternFill("solid", start_color="7F1D1D")
    opt_fill = PatternFill("solid", start_color="1E3A8A")
    thin = Side(style="thin", color="D0D0D0")
    border = Border(top=thin, left=thin, right=thin, bottom=thin)

    ws = wb.active
    ws.title = "อ่านก่อน"
    ws["A1"] = "แบบฟอร์มนำเข้าข้อมูลโรงเรียน (ตรงกับฐานข้อมูลของระบบ)"
    ws["A1"].font = Font(name="TH SarabunPSK", size=20, bold=True)
    ws["A2"], ws["B2"] = "ภาคเรียน/ปีการศึกษา", f"{term}/{year}"
    ws["A3"], ws["B3"] = "สร้างเมื่อ", datetime.now().strftime("%d/%m/%Y %H:%M")
    lines = [
        "", "วิธีใช้",
        "1. กรอกแผ่นตามลำดับเลข 1 → 8 (แผ่นหลังอ้างอิงแผ่นก่อน) แผ่นที่ไม่ใช้เว้นว่างได้ = ข้อมูลส่วนนั้นในระบบไม่เปลี่ยน",
        "2. หัวตารางสีแดง = ต้องกรอก • สีน้ำเงิน = ไม่บังคับ • ชี้ที่หัวตารางเพื่อดูคำอธิบาย • ห้ามแก้ชื่อหัวตาราง",
        "3. อัปโหลดที่ ตั้งค่า → นำเข้าข้อมูลโรงเรียน → ระบบตรวจทุกแถวก่อน (ยังไม่บันทึก) แก้จุดสีแดงให้หมดแล้วจึงกดบันทึก",
        "4. ก่อนบันทึก ระบบสำรองฐานข้อมูลให้อัตโนมัติ (ดูได้ที่ จัดเก็บข้อมูล → สำรองข้อมูล)",
        "", "หลักการ",
        "• ระดับชั้นเขียน ม.1–ม.6 • ห้องเป็นเลขห้อง (ม.1/3 = ระดับชั้น ม.1 ห้อง 3)",
        "• นักเรียนลงทะเบียนวิชาอัตโนมัติ: ทุกวิชาของระดับชั้น ยกเว้นวิชาที่ระบุ 'เรียนเฉพาะโปรแกรม' (เฉพาะโปรแกรมนั้น) และวิชาในแผ่น 8 (เฉพาะรายชื่อ)",
        "• โปรแกรมของนักเรียน = ช่องโปรแกรมในแผ่น 4 ถ้าว่างใช้โปรแกรมของห้องในแผ่น 3",
        "• วิชาเดียวกันสอนหลายห้องโดยครูหลายคน ให้แยกแถวในแผ่น 6 ตามห้อง",
        "• ไม่มีการลบนักเรียน ครู หรือรายวิชา (นักเรียนย้ายออกให้ใส่สถานะ ย้ายออก)",
        "", "แผ่น → ตารางในฐานข้อมูล",
    ] + [f"{s.title}  →  {s.tables}   ({s.help})" for s in SHEETS]
    for i, line in enumerate(lines, start=4):
        ws.cell(i, 1, line).font = bold if line in ("วิธีใช้", "หลักการ", "แผ่น → ตารางในฐานข้อมูล") else font
    for r in (2, 3):
        ws.cell(r, 1).font, ws.cell(r, 2).font = bold, font
    ws.column_dimensions["A"].width = 28
    ws.column_dimensions["B"].width = 20

    last_row = 3000
    for spec in SHEETS:
        sh = wb.create_sheet(spec.title)
        for ci, col in enumerate(spec.cols, start=1):
            c = sh.cell(1, ci, col.header + (" *" if col.required else ""))
            c.font, c.fill, c.border = head_font, (req_fill if col.required else opt_fill), border
            c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
            tip = col.help or ""
            if col.choices:
                tip = (tip + "\n" if tip else "") + "เลือกได้: " + ", ".join(col.choices)
            if tip:
                c.comment = Comment(tip, "ระบบ")
            letter = openpyxl.utils.get_column_letter(ci)
            sh.column_dimensions[letter].width = col.width
            if col.text:
                for r in range(2, last_row + 1):
                    sh.cell(r, ci).number_format = "@"
            formula = None
            if col.choices:
                formula = '"' + ",".join(col.choices) + '"'
            elif col.ref:
                ref_title = SHEET_BY_KEY[col.ref[0]].title
                formula = f"='{ref_title}'!${col.ref[1]}$2:${col.ref[1]}${last_row}"
            if formula:
                dv = DataValidation(type="list", formula1=formula, allow_blank=True, showErrorMessage=True,
                                    errorStyle="information", error="ค่านี้ไม่อยู่ในรายการ ตรวจอีกครั้งตอนนำเข้า")
                sh.add_data_validation(dv)
                dv.add(f"{letter}2:{letter}{last_row}")
        sh.row_dimensions[1].height = 36
        sh.freeze_panes = "A2"
        for ri, row in enumerate(data.get(spec.key, []), start=2):
            for ci, col in enumerate(spec.cols, start=1):
                v = row.get(col.key, "")
                cell = sh.cell(ri, ci, "" if v is None else (str(v) if col.text else v))
                cell.font = font
    if full and prefill:
        import school_data
        with get_connection(db_path) as conn:
            school_data.write_sheets(wb, conn, term, year)
        ws.cell(ws.max_row + 2, 1, "ไฟล์ข้อมูลทั้งหมด: แผ่น 9 ขึ้นไปเป็นข้อมูลระหว่างเทอม (คะแนน เวลาเรียน ตั้งค่า ...) "
                                   "นำเข้าไฟล์นี้ไฟล์เดียวได้ทั้งหมด • มีข้อมูลส่วนบุคคล เก็บรักษาเป็นความลับ").font = bold
    buf = io.BytesIO()
    wb.save(buf)
    wb.close()
    return buf.getvalue()


def _teacher_display(conn) -> Dict[str, str]:
    return {normalize_teacher_base_name(r[0]): r[0] for r in conn.execute("SELECT name FROM school_teachers")}


def _current_rows(term, year, db_path) -> Dict[str, List[Dict[str, Any]]]:
    """What the database holds now, in sheet form: export -> edit -> import changes only what was edited."""
    t, y = str(term), str(year)
    with get_connection(db_path) as conn:
        ensure_schema(conn)
        out: Dict[str, List[Dict[str, Any]]] = {}
        out["teachers"] = [{"code": r[1] or "", "name": r[0]} for r in
                           conn.execute("SELECT name, code FROM school_teachers ORDER BY CAST(code AS INTEGER), name")]
        out["programs"] = [{"code": r[0], "name": r[1], "stage": {v: k for k, v in STAGES.items()}.get(r[2] or "", ""), "note": r[3]}
                           for r in conn.execute("SELECT code, name, stage, note FROM programs ORDER BY code")]
        roster = [dict(r) for r in conn.execute(
            """SELECT cs.*, COALESCE(NULLIF(cs.prefix, ''), d.prefix) AS prefix,
                      COALESCE(NULLIF(cs.first_name, ''), d.first_name) AS first_name,
                      COALESCE(NULLIF(cs.last_name, ''), d.last_name) AS last_name,
                      d.gender, s.citizen_id
               FROM class_students cs LEFT JOIN student_dmc_info d ON d.student_id = cs.student_id
               LEFT JOIN students s ON s.student_id = cs.student_id
               WHERE cs.term = ? AND cs.year = ? AND cs.is_active = 1""", (t, y))]
        rooms = {(r["class_level"], r["room"]): dict(r) for r in conn.execute(
            "SELECT * FROM class_rooms WHERE term = ? AND year = ?", (t, y))}
        if not rooms:  # first export: rooms from the roster, the level's advisors on its first room
            adv = {r["class_level"]: r for r in conn.execute("SELECT * FROM class_advisors WHERE term = ? AND year = ?", (t, y))}
            by_level: Dict[str, Set[str]] = {}
            for s in roster:
                by_level.setdefault(s["class_level"], set()).add(s["room"] or "1")
            for lv, rms in by_level.items():
                for i, rm in enumerate(sorted(rms, key=room_key)):
                    members = [s for s in roster if s["class_level"] == lv and (s["room"] or "1") == rm]
                    a = adv.get(lv) if i == 0 else None
                    rooms[(lv, rm)] = {"class_level": lv, "room": rm, "program": "",
                                       "advisor1": a["advisor1"] if a else "", "advisor2": a["advisor2"] if a else "",
                                       "advisor3": a["advisor3"] if a else "",
                                       "no_checkin": 1 if members and all(m["is_locked"] for m in members) else 0, "note": ""}
        out["rooms"] = [{"level": r["class_level"], "room": r["room"], "program": r["program"] or "",
                         "advisor1": clean(r["advisor1"]), "advisor2": clean(r["advisor2"]), "advisor3": clean(r["advisor3"]),
                         "no_checkin": "ใช่" if r["no_checkin"] else "", "note": r["note"] or ""}
                        for _, r in sorted(rooms.items(), key=lambda kv: (kv[0][0], room_key(kv[0][1])))]
        st_rows = []
        for s in sorted(roster, key=lambda s: (s["class_level"], room_key(s["room"] or "1"), s["student_no"] or 0, s["student_id"])):
            p, f, l = split_name(s["full_name"])
            if s["first_name"] and _same_name(f"{s['prefix'] or ''}{s['first_name']} {s['last_name'] or ''}", s["full_name"]):
                p, f, l = s["prefix"] or "", s["first_name"], s["last_name"] or ""
            room_lock = bool(rooms.get((s["class_level"], s["room"] or "1"), {}).get("no_checkin"))
            st_rows.append({"sid": s["student_id"], "prefix": p, "first": f, "last": l, "level": s["class_level"],
                            "room": s["room"] or "1", "no": s["student_no"], "program": s.get("program") or "",
                            "gender": s["gender"] or "", "cid": s["citizen_id"] or "", "status": "กำลังศึกษา",
                            "no_checkin": "" if bool(s["is_locked"]) == room_lock else ("ใช่" if s["is_locked"] else "ไม่")})
        out["students"] = st_rows
        courses = [dict(r) for r in conn.execute("SELECT * FROM courses WHERE term = ? AND year = ? ORDER BY class_level, course_code", (t, y))]
        out["courses"] = [{"code": c["course_code"], "name": c["course_name"], "level": c["class_level"], "type": c["course_type"] or "",
                           "department": c["department"] or "", "credits": c["credits"], "periods": c["periods_per_week"],
                           "ratio": c["score_ratio"] or "", "programs": c.get("programs") or ""} for c in courses]
        secs = {}
        for r in conn.execute("SELECT * FROM course_sections WHERE term = ? AND year = ?", (t, y)):
            secs.setdefault(r["course_code"], []).append(dict(r))
        sec_rows = []
        for c in courses:
            for s in sorted(secs.get(c["course_code"], []), key=lambda s: room_key(s["rooms"].split(",")[0])):
                sec_rows.append({"code": c["course_code"], "level": s["class_level"],
                                 "rooms": "" if s["rooms"] == ALL_ROOMS else s["rooms"], "teacher": s["teacher"], "note": s["note"] or ""})
            if not secs.get(c["course_code"]) and c["teacher"]:
                sec_rows.append({"code": c["course_code"], "level": c["class_level"], "rooms": "", "teacher": c["teacher"], "note": ""})
        out["sections"] = sec_rows
        names = _teacher_display(conn)
        out["timetable"] = [{"day": DAY_NAMES.get(r["day_of_week"], r["day_of_week"]), "period": r["period_num"], "span": r["period_span"] or 1,
                             "code": r["course_code"], "name": r["course_name"] or "", "level": r["class_level"] or "", "room": r["room"] or "",
                             "teacher": names.get(normalize_teacher_base_name(r["teacher_name"]), r["teacher_name"]), "note": r["note"] or ""}
                            for r in conn.execute("SELECT * FROM teacher_timetables WHERE term = ? AND year = ? ORDER BY teacher_name, day_of_week, period_num", (t, y))]
        el = []
        for c in courses:
            if (c.get("enrol_mode") or "") == "list":
                for r in conn.execute("""SELECT g.student_id, COALESCE(cs.full_name, s.full_name) FROM grades_history g
                                         LEFT JOIN students s ON s.student_id = g.student_id
                                         LEFT JOIN class_students cs ON cs.student_id = g.student_id AND cs.term = g.term AND cs.year = g.year AND cs.is_active = 1
                                         WHERE g.course_code = ? AND g.term = ? AND g.year = ? ORDER BY g.student_id""", (c["course_code"], t, y)):
                    el.append({"code": c["course_code"], "sid": r[0], "name": r[1] or ""})
        out["electives"] = el
        return out


# ---------------------------------------------------------------- reading an uploaded workbook
class Issues:
    def __init__(self):
        self.items: List[Dict[str, Any]] = []

    def add(self, level, sheet, row, column, message):
        self.items.append({"level": level, "sheet": sheet, "row": row, "column": column, "message": message})

    def error(self, sheet, row, column, message):
        self.add("error", sheet, row, column, message)

    def warn(self, sheet, row, column, message):
        self.add("warning", sheet, row, column, message)

    def info(self, sheet, row, column, message):
        self.add("info", sheet, row, column, message)

    @property
    def errors(self) -> int:
        return sum(1 for i in self.items if i["level"] == "error")


def read_workbook(content: bytes, issues: Issues) -> Tuple[Dict[str, List[Tuple[int, Dict[str, Any]]]], str]:
    import openpyxl
    try:
        wb = openpyxl.load_workbook(io.BytesIO(content), data_only=True, read_only=True)
    except Exception:
        raise ValueError("อ่านไฟล์ไม่ได้ กรุณาใช้ไฟล์ .xlsx จากปุ่มดาวน์โหลดแบบฟอร์ม")
    stamp = ""
    if "อ่านก่อน" in wb.sheetnames:
        stamp = clean(wb["อ่านก่อน"]["B2"].value)
    titles = {_hnorm(re.sub(r"^\d+\s*", "", n)): n for n in wb.sheetnames}
    out: Dict[str, List[Tuple[int, Dict[str, Any]]]] = {}
    for spec in SHEETS:
        name = spec.title if spec.title in wb.sheetnames else titles.get(_hnorm(re.sub(r"^\d+\s*", "", spec.title)))
        if not name:
            continue
        rows = list(wb[name].iter_rows(values_only=True))
        wanted = {_hnorm(c.header): c.key for c in spec.cols}
        head_idx, mapping = None, {}
        for i, r in enumerate(rows[:10]):
            m = {ci: wanted[_hnorm(v)] for ci, v in enumerate(r) if _hnorm(v) in wanted}
            if len(m) > len(mapping):
                head_idx, mapping = i, m
        if head_idx is None:
            if any(any(clean(v) for v in r) for r in rows):
                issues.error(spec.title, None, None, "ไม่พบหัวตาราง (อย่าแก้ชื่อหัวตาราง)")
            continue
        missing = [c.header for c in spec.cols if c.required and c.key not in mapping.values()]
        if missing:
            issues.error(spec.title, head_idx + 1, None, "ไม่มีคอลัมน์ที่ต้องกรอก: " + ", ".join(missing))
            continue
        data = []
        for i, r in enumerate(rows[head_idx + 1:], start=head_idx + 2):
            rec = {key: (r[ci] if ci < len(r) else None) for ci, key in mapping.items()}
            if any(clean(v) for v in rec.values()):
                data.append((i, rec))
        out[spec.key] = data
    wb.close()
    return out, stamp


# ---------------------------------------------------------------- analysis (shared by preview and commit)
class TeacherBook:
    def __init__(self):
        self.by_code: Dict[str, Dict[str, str]] = {}
        self.by_base: Dict[str, List[Dict[str, str]]] = {}

    def add(self, name, code):
        t = {"name": name, "code": code or ""}
        if code:
            self.by_code[code] = t
        lst = self.by_base.setdefault(normalize_teacher_base_name(name), [])
        if not any(x["name"] == name for x in lst):
            lst.append(t)
        return t

    def find(self, ref) -> Tuple[Optional[Dict[str, str]], str]:
        s = clean(ref)
        if not s:
            return None, ""
        if s in self.by_code:
            return self.by_code[s], ""
        hits = self.by_base.get(normalize_teacher_base_name(s), [])
        if len(hits) == 1:
            return hits[0], ""
        return None, ("มีครูชื่อนี้มากกว่าหนึ่งคน ใช้รหัสครูแทน" if hits else f"ไม่พบครู '{s}' (เพิ่มในแผ่น 1 ครู)")


class Plan:
    pass


def analyse(content: bytes, term: str, year: str, conn) -> Plan:
    t, y = str(term).strip(), str(year).strip()
    ensure_schema(conn)
    iss = Issues()
    sheets, stamp = read_workbook(content, iss)
    p = Plan()
    p.term, p.year, p.issues, p.sheets = t, y, iss, sheets
    p.counts = {s.key: {"rows": len(sheets.get(s.key, [])), "new": 0, "update": 0, "same": 0} for s in SHEETS}
    if stamp and stamp != f"{t}/{y}":
        iss.warn("อ่านก่อน", 2, "ภาคเรียน", f"ไฟล์นี้ดาวน์โหลดสำหรับ {stamp} แต่กำลังนำเข้า {t}/{y}")

    def cnt(key, kind):
        p.counts[key][kind] += 1

    # ---- 1 ครู
    S = SHEET_BY_KEY["teachers"].title
    book = TeacherBook()
    db_teachers = [dict(r) for r in conn.execute("SELECT id, name, code FROM school_teachers")]
    for r in db_teachers:
        book.add(r["name"], (r["code"] or "").strip())
    p.teachers = []
    seen_codes, seen_names = {}, {}
    for row, rec in sheets.get("teachers", []):
        code, name = clean(rec.get("code")), clean(rec.get("name"))
        base = normalize_teacher_base_name(name)
        if name and not code and any(normalize_teacher_base_name(d["name"]) == base and not (d["code"] or "").strip() for d in db_teachers):
            iss.warn(S, row, "รหัสครู", f"{name} ยังไม่มีรหัสครู (เข้าสู่ระบบไม่ได้จนกว่าจะใส่รหัส)")
            cnt("teachers", "same")
            continue
        if name and not code and base not in seen_names and not any(normalize_teacher_base_name(d["name"]) == base for d in db_teachers):
            # ครูที่ยังไม่มีรหัส (เช่น ไฟล์ข้อมูลทั้งหมดจากอีกเครื่อง): เพิ่มชื่อไว้ให้ตารางสอน/ครูที่ปรึกษาอ้างถึงได้
            iss.warn(S, row, "รหัสครู", f"{name} ยังไม่มีรหัสครู (เพิ่มชื่อไว้ เข้าสู่ระบบไม่ได้จนกว่าจะใส่รหัส)")
            seen_names[base] = row
            p.teachers.append({"action": "new", "name": name, "code": ""})
            book.add(name, "")
            cnt("teachers", "new")
            continue
        if not code or not name:
            iss.error(S, row, "รหัสครู" if not code else "ชื่อ-สกุล", "ต้องกรอกรหัสครูและชื่อ-สกุล")
            continue
        if code in seen_codes or base in seen_names:
            iss.error(S, row, "รหัสครู" if code in seen_codes else "ชื่อ-สกุล", f"ซ้ำกับแถว {seen_codes.get(code) or seen_names.get(base)}")
            continue
        seen_codes[code], seen_names[base] = row, row
        by_code = next((d for d in db_teachers if (d["code"] or "").strip() == code), None)
        by_name = [d for d in db_teachers if normalize_teacher_base_name(d["name"]) == base]
        if by_code:
            if normalize_teacher_base_name(by_code["name"]) != base:
                iss.warn(S, row, "ชื่อ-สกุล", f"รหัส {code} ในระบบเป็นของ {by_code['name']} (ใช้ชื่อในระบบ ไม่เปลี่ยนชื่อ)")
            cnt("teachers", "same")
        elif by_name:
            d = by_name[0]
            if (d["code"] or "").strip():
                iss.error(S, row, "รหัสครู", f"{d['name']} มีรหัส {d['code']} ในระบบแล้ว (ใช้รหัสเดิม หรือแก้ที่หน้าตั้งค่าครู)")
                continue
            p.teachers.append({"action": "set_code", "id": d["id"], "name": d["name"], "code": code})
            book.add(d["name"], code)
            cnt("teachers", "update")
        else:
            p.teachers.append({"action": "new", "name": name, "code": code})
            book.add(name, code)
            cnt("teachers", "new")

    def teacher(sheet, row, col, ref, required=False):
        if not clean(ref):
            if required:
                iss.error(sheet, row, col, "ต้องระบุครู")
            return None
        tt, err = book.find(ref)
        if err:
            iss.error(sheet, row, col, err)
        return tt

    # ---- 2 โปรแกรม
    S = SHEET_BY_KEY["programs"].title
    db_prog = {r["code"]: dict(r) for r in conn.execute("SELECT * FROM programs")}
    p.programs = {}
    for row, rec in sheets.get("programs", []):
        code, name = clean(rec.get("code")).upper(), clean(rec.get("name"))
        stage_txt = clean(rec.get("stage"))
        if not code or not name:
            iss.error(S, row, None, "ต้องกรอกรหัสและชื่อโปรแกรม")
            continue
        if not re.fullmatch(r"[0-9A-Za-zก-๙_\-]{1,12}", code):
            iss.error(S, row, "รหัสโปรแกรม", "รหัสโปรแกรมใช้ตัวอักษร/ตัวเลข ไม่เกิน 12 ตัว ไม่เว้นวรรค")
            continue
        if code in p.programs:
            iss.error(S, row, "รหัสโปรแกรม", "รหัสโปรแกรมซ้ำ")
            continue
        if stage_txt and stage_txt not in STAGES:
            iss.error(S, row, "ช่วงชั้น", "ช่วงชั้นต้องเป็น ม.ต้น / ม.ปลาย / ทุกช่วงชั้น")
            continue
        rec2 = {"code": code, "name": name, "stage": STAGES.get(stage_txt, ""), "note": clean(rec.get("note"))}
        p.programs[code] = rec2
        old = db_prog.get(code)
        cnt("programs", "new" if not old else ("same" if all((old[k] or "") == rec2[k] for k in ("name", "stage", "note")) else "update"))
    all_prog = {**db_prog, **p.programs}
    prog_by_name = {normalize_teacher_base_name(v["name"]): k for k, v in all_prog.items()}

    def program(sheet, row, col, v):
        s = clean(v)
        if not s:
            return ""
        if s.upper() in all_prog:
            return s.upper()
        if normalize_teacher_base_name(s) in prog_by_name:
            return prog_by_name[normalize_teacher_base_name(s)]
        iss.error(sheet, row, col, f"ไม่พบโปรแกรม '{s}' (เพิ่มในแผ่น 2 โปรแกรม)")
        return None

    # ---- 3 ห้องเรียน
    S = SHEET_BY_KEY["rooms"].title
    db_rooms = {(r["class_level"], r["room"]): dict(r) for r in conn.execute("SELECT * FROM class_rooms WHERE term = ? AND year = ?", (t, y))}
    p.rooms = {}
    advised: Dict[str, str] = {}
    for row, rec in sheets.get("rooms", []):
        lv, rm_from_lv = norm_level(rec.get("level"))
        rm = norm_room(rec.get("room")) or rm_from_lv
        if not lv:
            iss.error(S, row, "ระดับชั้น", "ระดับชั้นต้องเป็น ม.1–ม.6")
            continue
        if not rm:
            iss.error(S, row, "ห้อง", "ต้องกรอกห้อง")
            continue
        if (lv, rm) in p.rooms:
            iss.error(S, row, "ห้อง", f"{lv}/{rm} ซ้ำ")
            continue
        prog = program(S, row, "โปรแกรม", rec.get("program"))
        advisors = []
        for i in (1, 2, 3):
            tt = teacher(S, row, f"ครูที่ปรึกษา {i}", rec.get(f"advisor{i}"))
            if tt and tt["name"] not in advisors:
                advisors.append(tt["name"])
                if tt["name"] in advised:
                    iss.warn(S, row, f"ครูที่ปรึกษา {i}", f"{tt['name']} เป็นครูที่ปรึกษา {advised[tt['name']]} อยู่แล้ว")
                advised.setdefault(tt["name"], f"{lv}/{rm}")
        if prog is None:
            continue
        advisors += [""] * (3 - len(advisors))
        rec2 = {"level": lv, "room": rm, "program": prog, "advisors": advisors, "no_checkin": 1 if norm_yes(rec.get("no_checkin")) else 0,
                "note": clean(rec.get("note"))}
        p.rooms[(lv, rm)] = rec2
        old = db_rooms.get((lv, rm))
        same = old and old["program"] == prog and old["no_checkin"] == rec2["no_checkin"] and (old["note"] or "") == rec2["note"] \
            and [normalize_teacher_base_name(old[f"advisor{i}"] or "") for i in (1, 2, 3)] == [normalize_teacher_base_name(a) for a in advisors]
        cnt("rooms", "new" if not old else ("same" if same else "update"))
    final_rooms = {**db_rooms, **{k: {"program": v["program"], "no_checkin": v["no_checkin"]} for k, v in p.rooms.items()}}

    # ---- 4 นักเรียน
    S = SHEET_BY_KEY["students"].title
    roster = [dict(r) for r in conn.execute("SELECT * FROM class_students WHERE term = ? AND year = ?", (t, y))]
    by_sid: Dict[str, List[Dict[str, Any]]] = {}
    for r in roster:
        by_sid.setdefault(r["student_id"], []).append(r)
    db_students = {r["student_id"]: dict(r) for r in conn.execute("SELECT * FROM students")}
    dmc = {r["student_id"]: dict(r) for r in conn.execute("SELECT student_id, prefix, first_name, last_name, gender FROM student_dmc_info")}
    rooms_of_level: Dict[str, Set[str]] = {}
    for (lv, rm) in final_rooms:
        rooms_of_level.setdefault(lv, set()).add(rm)
    derived_rooms = not rooms_of_level
    p.students = []
    seen_sid: Dict[str, int] = {}
    seen_no: Dict[Tuple[str, str, int], int] = {}
    pending_no: List[Dict[str, Any]] = []
    padded_rows = []
    for row, rec in sheets.get("students", []):
        sid, padded = norm_sid(rec.get("sid"))
        lv, rm_from_lv = norm_level(rec.get("level"))
        rm = norm_room(rec.get("room")) or rm_from_lv
        first, last, prefix = clean(rec.get("first")), clean(rec.get("last")), clean(rec.get("prefix"))
        bad = False
        if not re.fullmatch(r"[0-9A-Za-z\-]{1,15}", sid or ""):
            iss.error(S, row, "เลขประจำตัวนักเรียน", "เลขประจำตัวว่างหรือมีอักขระที่ใช้ไม่ได้")
            bad = True
        elif sid in seen_sid:
            iss.error(S, row, "เลขประจำตัวนักเรียน", f"{sid} ซ้ำกับแถว {seen_sid[sid]}")
            bad = True
        if padded:
            padded_rows.append(row)
        if not lv:
            iss.error(S, row, "ระดับชั้น", "ระดับชั้นต้องเป็น ม.1–ม.6")
            bad = True
        if not rm:
            iss.error(S, row, "ห้อง", "ต้องกรอกห้อง")
            bad = True
        elif lv and not derived_rooms and lv in rooms_of_level and rm not in rooms_of_level[lv]:
            iss.error(S, row, "ห้อง", f"ยังไม่มีห้อง {lv}/{rm} ในแผ่น 3 ห้องเรียน")
            bad = True
        if not first:
            iss.error(S, row, "ชื่อ", "ต้องกรอกชื่อ")
            bad = True
        if not last:
            iss.warn(S, row, "นามสกุล", "ไม่มีนามสกุล")
        prog = program(S, row, "โปรแกรม", rec.get("program"))
        no_raw = clean(rec.get("no"))
        no = to_int(no_raw) if no_raw else None
        if no_raw and (no is None or no < 1 or no > 999):
            iss.error(S, row, "เลขที่", "เลขที่ต้องเป็นจำนวนเต็ม")
            bad = True
        cid = clean(rec.get("cid")).replace("-", "").replace(" ", "")
        if cid and not re.fullmatch(r"\d{13}|G\d{12}", cid):
            iss.warn(S, row, "เลขประจำตัวประชาชน", "เลขประจำตัวประชาชนควรมี 13 หลัก")
        gender = clean(rec.get("gender"))
        gender = {"ชาย": "ช", "หญิง": "ญ", "m": "ช", "f": "ญ"}.get(gender.lower(), gender)
        status = clean(rec.get("status"))
        if status and status not in ("กำลังศึกษา", "ปกติ", "ย้ายออก", "ลาออก", "จำหน่าย"):
            iss.error(S, row, "สถานะ", "สถานะต้องเป็น กำลังศึกษา หรือ ย้ายออก")
            bad = True
        lock_raw = clean(rec.get("no_checkin"))
        lock = norm_yes(lock_raw)
        if lock_raw and lock is None:
            iss.error(S, row, "ไม่เช็คชื่อ/ไม่ออก ปพ.5", "ใส่ ใช่ / ไม่ หรือเว้นว่าง")
            bad = True
        if bad or prog is None:
            continue
        seen_sid[sid] = row
        if no is not None:
            k = (lv, rm, no)
            if k in seen_no:
                iss.error(S, row, "เลขที่", f"เลขที่ {no} ของ {lv}/{rm} ซ้ำกับแถว {seen_no[k]}")
                continue
            seen_no[k] = row
        old_rows = by_sid.get(sid, [])
        here = next((r for r in old_rows if r["class_level"] == lv), None)
        moved = [r for r in old_rows if r["class_level"] != lv and r["is_active"]]
        if moved:
            iss.warn(S, row, "ระดับชั้น", f"{sid} อยู่ {moved[0]['class_level']}/{moved[0]['room']} ในภาคเรียนนี้ — จะย้ายไป {lv}/{rm}")
        if lock is None:
            room_flag = final_rooms.get((lv, rm))
            lock = bool(room_flag["no_checkin"]) if room_flag else (bool(here["is_locked"]) if here else False)
        rec2 = {"row": row, "sid": sid, "prefix": prefix, "first": first, "last": last,
                "full_name": f"{prefix}{first} {last}".strip(), "level": lv, "room": rm, "no": no, "program": prog,
                "gender": gender, "cid": cid, "active": 0 if status in ("ย้ายออก", "ลาออก", "จำหน่าย") else 1,
                "locked": 1 if lock else 0, "moved_from": [r["class_level"] for r in moved]}
        if no is None:
            pending_no.append(rec2)
        p.students.append(rec2)
        if not here:
            cnt("students", "new")
        else:
            same = _same_name(here["full_name"], rec2["full_name"]) and (here["room"] or "1") == rm and here["student_no"] == (no or here["student_no"]) \
                and (here.get("program") or "") == prog and here["is_active"] == rec2["active"] and here["is_locked"] == rec2["locked"] and not moved
            if same and cid and (db_students.get(sid, {}).get("citizen_id") or "") != cid:
                same = False
            if same and sid in dmc and gender and (dmc[sid]["gender"] or "") != gender:
                same = False
            cnt("students", "same" if same else "update")
    if padded_rows:
        iss.warn(S, padded_rows[0], "เลขประจำตัวนักเรียน", f"เลขประจำตัวสั้นกว่า 5 หลัก {len(padded_rows)} แถว — เติม 0 ข้างหน้าให้ (ตั้งเซลล์เป็นข้อความเพื่อป้องกัน)")
    # students without เลขที่: after the highest number of their room (file + database)
    for rec2 in pending_no:
        here = next((r for r in by_sid.get(rec2["sid"], []) if r["class_level"] == rec2["level"]), None)
        if here and here["student_no"]:
            rec2["no"] = here["student_no"]
            continue
        used = [k[2] for k in seen_no if k[0] == rec2["level"] and k[1] == rec2["room"]] + \
               [r["student_no"] or 0 for r in roster if r["class_level"] == rec2["level"] and (r["room"] or "1") == rec2["room"] and r["is_active"]]
        rec2["no"] = max(used or [0]) + 1
        seen_no[(rec2["level"], rec2["room"], rec2["no"])] = rec2["row"]
    if pending_no:
        iss.info(S, pending_no[0]["row"], "เลขที่", f"ไม่ระบุเลขที่ {len(pending_no)} คน — เรียงต่อท้ายห้องให้")
    if derived_rooms:
        for s in p.students:
            rooms_of_level.setdefault(s["level"], set()).add(s["room"])
        for r in roster:
            if r["is_active"]:
                rooms_of_level.setdefault(r["class_level"], set()).add(r["room"] or "1")

    # ---- 5 รายวิชา
    S = SHEET_BY_KEY["courses"].title
    try:
        from catalog_manager import decode_course_code
    except Exception:
        decode_course_code = None
    db_courses = {r["course_code"]: dict(r) for r in conn.execute("SELECT * FROM courses WHERE term = ? AND year = ?", (t, y))}
    catalog = {r["course_code"]: dict(r) for r in conn.execute("SELECT * FROM course_catalog")} if \
        conn.execute("SELECT 1 FROM sqlite_master WHERE name = 'course_catalog'").fetchone() else {}
    p.courses = {}
    for row, rec in sheets.get("courses", []):
        code = clean(rec.get("code")).replace(" ", "")
        name = clean(rec.get("name"))
        lv, _ = norm_level(rec.get("level"))
        if not code or not name:
            iss.error(S, row, None, "ต้องกรอกรหัสวิชาและชื่อวิชา")
            continue
        if code in p.courses:
            iss.error(S, row, "รหัสวิชา", f"{code} ซ้ำ")
            continue
        if not lv:
            iss.error(S, row, "ระดับชั้น", "ระดับชั้นต้องเป็น ม.1–ม.6 (วิชาเดียวหนึ่งระดับชั้น)")
            continue
        dec = decode_course_code(code) if decode_course_code else {}
        if not COURSE_CODE.match(code):
            iss.warn(S, row, "รหัสวิชา", f"{code} ไม่ใช่รูปแบบรหัสวิชามาตรฐาน (อักษร 1 ตัว + ตัวเลข 5 หลัก)")
        elif code[2] in "123" and dec.get("class_level") and dec["class_level"] != lv:
            iss.warn(S, row, "ระดับชั้น", f"รหัส {code} เป็นวิชาของ {dec['class_level']} แต่ระบุ {lv}")
        ctype = clean(rec.get("type")) or dec.get("course_type") or "พื้นฐาน"
        if ctype not in COURSE_TYPES:
            iss.error(S, row, "ประเภท", "ประเภทต้องเป็น พื้นฐาน / เพิ่มเติม / กิจกรรม")
            continue
        cr_raw, pd_raw = clean(rec.get("credits")), clean(rec.get("periods"))
        credits = to_float(cr_raw) if cr_raw else None
        periods = to_int(pd_raw) if pd_raw else None
        if cr_raw and (credits is None or credits < 0 or credits > 10 or (credits * 2) % 1):
            iss.error(S, row, "หน่วยกิต", "หน่วยกิตต้องเป็นตัวเลขทีละ 0.5")
            continue
        if pd_raw and (periods is None or periods < 0 or periods > 40):
            iss.error(S, row, "คาบ/สัปดาห์", "คาบ/สัปดาห์ต้องเป็นจำนวนเต็ม")
            continue
        ratio = norm_ratio(rec.get("ratio"))
        if ratio is None:
            iss.error(S, row, "สัดส่วนคะแนน", "ใส่เป็น เก็บ:สอบ รวมกัน 100 เช่น 70:30")
            continue
        progs = []
        bad = False
        for x in _split(clean(rec.get("programs")).replace("、", ",")):
            pc = program(S, row, "เรียนเฉพาะโปรแกรม", x)
            bad = bad or pc is None
            if pc:
                progs.append(pc)
        if bad:
            continue
        old_cat = catalog.get(code)
        if old_cat and str(old_cat.get("term") or "") not in ("", t):
            iss.warn(S, row, "รหัสวิชา", f"ในคลังรายวิชา {code} เป็นวิชาภาคเรียนที่ {old_cat['term']}")
        old = db_courses.get(code)
        rec2 = {"row": row, "code": code, "name": name, "level": lv, "type": ctype,
                "department": clean(rec.get("department")) or (old or {}).get("department") or dec.get("department") or "",
                "credits": credits if credits is not None else ((old or {}).get("credits") or (old_cat or {}).get("credits") or 1.0),
                "periods": periods, "ratio": ratio if ratio != "" else ((old or {}).get("score_ratio") or (old_cat or {}).get("score_ratio") or "70:30"),
                "programs": ",".join(sorted(set(progs)))}
        p.courses[code] = rec2
        if not old:
            cnt("courses", "new")
        else:
            same = old["course_name"] == name and old["class_level"] == lv and (old["course_type"] or "") == ctype \
                and (old["department"] or "") == rec2["department"] and float(old["credits"] or 0) == float(rec2["credits"]) \
                and (periods is None or old["periods_per_week"] == periods) and (old["score_ratio"] or "") == rec2["ratio"] \
                and (old.get("programs") or "") == rec2["programs"]
            cnt("courses", "same" if same else "update")
    final_courses = {c: {"level": v["class_level"], "programs": v.get("programs") or "", "name": v["course_name"],
                         "periods": v["periods_per_week"]} for c, v in db_courses.items()}
    for c, v in p.courses.items():
        final_courses[c] = {"level": v["level"], "programs": v["programs"], "name": v["name"],
                            "periods": v["periods"] if v["periods"] is not None else (db_courses.get(c) or {}).get("periods_per_week")}

    # ---- 8 ลงทะเบียนรายคน (read before sections: changes who takes a course)
    S = SHEET_BY_KEY["electives"].title
    known_sids = {s["sid"]: s for s in p.students if s["active"]}
    for r in roster:
        if r["is_active"] and r["student_id"] not in known_sids:
            known_sids[r["student_id"]] = {"sid": r["student_id"], "level": r["class_level"], "no": r["student_no"]}
    p.electives: Dict[str, List[str]] = {}
    for row, rec in sheets.get("electives", []):
        code = clean(rec.get("code")).replace(" ", "")
        sid, _ = norm_sid(rec.get("sid"))
        if code not in final_courses:
            iss.error(S, row, "รหัสวิชา", f"ไม่พบรายวิชา {code} ในภาคเรียนนี้ (เพิ่มในแผ่น 5)")
            continue
        if sid not in known_sids:
            iss.error(S, row, "เลขประจำตัวนักเรียน", f"ไม่พบนักเรียน {sid} ในภาคเรียนนี้")
            continue
        lst = p.electives.setdefault(code, [])
        if sid in lst:
            iss.warn(S, row, "เลขประจำตัวนักเรียน", "ลงทะเบียนซ้ำ (ข้าม)")
            continue
        if known_sids[sid]["level"] not in _split(final_courses[code]["level"]):
            iss.warn(S, row, "เลขประจำตัวนักเรียน", f"{sid} อยู่ {known_sids[sid]['level']} แต่วิชานี้เป็นของ {final_courses[code]['level']}")
        lst.append(sid)
    p.list_off: List[str] = []
    if p.electives:
        for code, lst in p.electives.items():
            old = db_courses.get(code)
            enrolled = {r[0] for r in conn.execute("SELECT student_id FROM grades_history WHERE course_code = ? AND term = ? AND year = ?", (code, t, y))}
            extra = enrolled - set(lst)
            if extra:
                iss.warn(S, None, "รหัสวิชา", f"{code}: นักเรียน {len(extra)} คนลงทะเบียนอยู่แล้วแต่ไม่อยู่ในรายชื่อ (ไม่ลบ คะแนนเดิมยังอยู่)")
            new_n = len(set(lst) - enrolled)
            cnt("electives", "new" if new_n else "same")
            if old is not None and (old.get("enrol_mode") or "") != "list":
                iss.info(S, None, "รหัสวิชา", f"{code}: เปลี่ยนเป็นลงทะเบียนเฉพาะรายชื่อ")
        p.list_off = [c for c, v in db_courses.items() if (v.get("enrol_mode") or "") == "list" and c not in p.electives]
        for c in p.list_off:
            iss.info(S, None, None, f"{c}: ไม่อยู่ในแผ่นนี้แล้ว — กลับไปลงทะเบียนตามระดับชั้น/โปรแกรม")

    # ---- 6 ครูผู้สอน
    S = SHEET_BY_KEY["sections"].title
    db_secs: Dict[str, List[Dict[str, Any]]] = {}
    for r in conn.execute("SELECT * FROM course_sections WHERE term = ? AND year = ?", (t, y)):
        db_secs.setdefault(r["course_code"], []).append(dict(r))
    p.sections: Dict[str, List[Dict[str, Any]]] = {}
    for row, rec in sheets.get("sections", []):
        code = clean(rec.get("code")).replace(" ", "")
        if code not in final_courses:
            iss.error(S, row, "รหัสวิชา", f"ไม่พบรายวิชา {code} ในภาคเรียนนี้ (เพิ่มในแผ่น 5)")
            continue
        clv = final_courses[code]["level"]
        lv, _ = norm_level(rec.get("level"))
        if lv is None or (lv and lv not in _split(clv)):
            iss.error(S, row, "ระดับชั้น", f"{code} เป็นวิชาของ {clv}")
            continue
        lv = lv or _split(clv)[0]
        rooms, every = parse_rooms(rec.get("rooms"))
        if rooms is None:
            iss.error(S, row, "ห้อง", "เขียนห้องแบบ 1 หรือ 1,2 หรือ 1-3 (ว่าง = ทุกห้อง)")
            continue
        unknown = [r for r in rooms if r not in rooms_of_level.get(lv, set())]
        if unknown:
            iss.error(S, row, "ห้อง", f"ไม่มีห้อง {', '.join(lv + '/' + r for r in unknown)}")
            continue
        tt = teacher(S, row, "ครูผู้สอน", rec.get("teacher"), required=True)
        if not tt:
            continue
        p.sections.setdefault(code, []).append({"row": row, "level": lv, "rooms": rooms, "every": every, "teacher": tt["name"],
                                                "teacher_code": tt["code"], "note": clean(rec.get("note"))})

    # ---- 7 ตารางสอน
    S = SHEET_BY_KEY["timetable"].title
    p.timetable: Dict[str, Dict[str, Any]] = {}   # teacher base name -> {"name": stored teacher_name, "official", "rows"}
    stored_names = {}
    for r in conn.execute("SELECT DISTINCT teacher_name FROM teacher_timetables ORDER BY year DESC, term DESC"):
        stored_names.setdefault(normalize_teacher_base_name(r[0]), r[0])
    occ_teacher: Dict[Tuple[str, int, int], Tuple[int, Dict[str, Any]]] = {}
    for row, rec in sheets.get("timetable", []):
        day = norm_day(rec.get("day"))
        period = to_int(rec.get("period"))
        span_raw = clean(rec.get("span"))
        span = to_int(span_raw) if span_raw else 1
        raw_code = clean(rec.get("code"))
        if day is None:
            iss.error(S, row, "วัน", "วันต้องเป็น จันทร์–ศุกร์")
            continue
        if period is None or not 1 <= period <= 12:
            iss.error(S, row, "คาบที่", "คาบที่ต้องเป็น 1–12")
            continue
        if span is None or not 1 <= span <= 6 or period + span - 1 > 12:
            iss.error(S, row, "จำนวนคาบ", "จำนวนคาบไม่ถูกต้อง")
            continue
        if not raw_code:
            iss.error(S, row, "รหัสวิชา/กิจกรรม", "ต้องกรอกรหัสวิชาหรือชื่อกิจกรรม")
            continue
        levels, bad = [], False
        for x in _split(rec.get("level")):
            l, _ = norm_level(x)
            if not l:
                iss.error(S, row, "ระดับชั้น", f"ระดับชั้น '{x}' ไม่ถูกต้อง")
                bad = True
            elif l not in levels:
                levels.append(l)
        rooms, every = parse_rooms(rec.get("room"))
        if rooms is None:
            iss.error(S, row, "ห้อง", "เขียนห้องแบบ 1 หรือ 1,2 (ว่าง = ทุกห้อง)")
            bad = True
        tt = teacher(S, row, "ครูผู้สอน", rec.get("teacher"), required=True)
        if bad or not tt:
            continue
        codes = [c.replace(" ", "") if COURSE_CODE.match(c.replace(" ", "")) else c for c in _split(raw_code)]
        course_codes = [c for c in codes if COURSE_CODE.match(c)]
        pairs: List[Tuple[str, str]] = []
        if course_codes:
            unknown = [c for c in course_codes if c not in final_courses]
            if unknown:
                iss.error(S, row, "รหัสวิชา/กิจกรรม", f"ไม่พบรายวิชา {', '.join(unknown)} ในภาคเรียนนี้ (เพิ่มในแผ่น 5)")
                continue
            if len(course_codes) != len(codes):
                iss.error(S, row, "รหัสวิชา/กิจกรรม", "ช่องเดียวใส่ได้ทั้งรหัสวิชาหรือชื่อกิจกรรม ไม่ปนกัน")
                continue
            if not levels:
                levels = [final_courses[c]["level"] for c in codes]
            if len(codes) == 1 and len(levels) == 1:
                pairs = [(codes[0], levels[0])]
            elif len(codes) == len(levels):
                pairs = list(zip(codes, levels))
            else:
                iss.error(S, row, "ระดับชั้น", "สอนรวมหลายรหัส: จำนวนรหัสวิชาต้องเท่ากับจำนวนระดับชั้น (เรียงตามกัน)")
                continue
            mism = [f"{c} เป็นวิชาของ {final_courses[c]['level']}" for c, l in pairs if l not in _split(final_courses[c]["level"])]
            if mism:
                iss.error(S, row, "ระดับชั้น", "; ".join(mism))
                continue
            for c, l in pairs:
                if rooms:
                    unknown_r = [r for r in rooms if r not in rooms_of_level.get(l, set())]
                    if unknown_r:
                        iss.error(S, row, "ห้อง", f"ไม่มีห้อง {', '.join(l + '/' + r for r in unknown_r)}")
                        bad = True
            if bad:
                continue
        name = clean(rec.get("name")) or (final_courses[codes[0]]["name"] if len(course_codes) == 1 else raw_code)
        base = normalize_teacher_base_name(tt["name"])
        entry = {"row": row, "day": day, "period": period, "span": span, "code": ", ".join(codes), "name": name,
                 "level": ", ".join(levels), "room": "" if every else ",".join(rooms), "rooms": rooms, "every": every,
                 "pairs": pairs, "note": clean(rec.get("note"))}
        clash = None
        for k in range(period, period + span):
            if (base, day, k) in occ_teacher:
                clash = occ_teacher[(base, day, k)]
                break
        if clash:
            prev_row, prev = clash
            if prev["code"] == entry["code"] and prev["level"] == entry["level"] and prev["period"] == period and prev["span"] == span \
                    and not prev["every"] and not every:
                prev["rooms"] = sorted(set(prev["rooms"]) | set(rooms), key=room_key)
                prev["room"] = ",".join(prev["rooms"])
                iss.info(S, row, "ห้อง", f"รวมกับแถว {prev_row}: สอนห้อง {prev['room']} พร้อมกัน")
            else:
                iss.error(S, row, "คาบที่", f"{tt['name']} มีสอนวัน{DAY_NAMES[day]} คาบ {period} แล้ว (แถว {prev_row})")
            continue
        for k in range(period, period + span):
            occ_teacher[(base, day, k)] = (row, entry)
        slot = p.timetable.setdefault(base, {"name": stored_names.get(base) or "ครู" + re.sub(
            r"^(นาย|นางสาว|นาง|ครู|ว่าที่ร้อยตรี|ว่าที่\s*ร\.ต\.|ดร\.)\s*", "", tt["name"]), "official": tt["name"],
            "code": tt["code"], "rows": []})
        slot["rows"].append(entry)
    db_tt = [dict(r) for r in conn.execute("SELECT * FROM teacher_timetables WHERE term = ? AND year = ?", (t, y))]
    for base, slot in p.timetable.items():
        old = sorted((r["day_of_week"], r["period_num"], r["period_span"] or 1, r["course_code"], r["class_level"] or "", r["room"] or "")
                     for r in db_tt if normalize_teacher_base_name(r["teacher_name"]) == base)
        new = sorted((e["day"], e["period"], e["span"], e["code"], e["level"], e["room"]) for e in slot["rows"])
        cnt("timetable", "same" if old == new else ("new" if not old else "update"))
    # the semester's timetable after the import, as rows with (course, level) pairs
    merged: List[Dict[str, Any]] = []
    for r in db_tt:
        if normalize_teacher_base_name(r["teacher_name"]) in p.timetable:
            continue
        codes = [c.replace(" ", "") for c in _split(r["course_code"])]
        levels = _split(r["class_level"])
        pairs = []
        if all(c in final_courses for c in codes) and codes:
            pairs = list(zip(codes, levels)) if len(codes) == len(levels) else [(codes[0], l) for l in levels[:1]] if len(codes) == 1 else []
        rooms, every = parse_rooms(r["room"])
        merged.append({"row": None, "day": r["day_of_week"], "period": r["period_num"], "span": r["period_span"] or 1, "pairs": pairs,
                       "rooms": rooms or [], "every": every if rooms is not None else True,
                       "teacher": normalize_teacher_base_name(r["teacher_name"]), "official": r["teacher_name"]})
    for base, slot in p.timetable.items():
        for e in slot["rows"]:
            merged.append({**e, "teacher": base, "official": slot["official"], "teacher_code": slot["code"]})
    p.merged_tt = merged

    # sections not in sheet 6: from the timetable of each room (only for courses without sections yet)
    touched_tt = {c for e in merged if e["row"] is not None for c, _ in e["pairs"]}
    if not p.sections:
        for code in sorted(touched_tt):
            if db_secs.get(code):
                continue
            by_teacher: Dict[str, Dict[str, Any]] = {}
            for e in merged:
                for c, l in e["pairs"]:
                    if c == code:
                        d = by_teacher.setdefault(e["official"], {"level": l, "rooms": set(), "every": False,
                                                                  "teacher_code": e.get("teacher_code", "")})
                        if e["every"]:
                            d["every"] = True
                        d["rooms"] |= set(e["rooms"])
            if len(by_teacher) > 1:
                p.sections[code] = [{"row": None, "level": d["level"], "rooms": sorted(d["rooms"], key=room_key), "every": d["every"],
                                     "teacher": name, "teacher_code": d["teacher_code"] or (book.find(name)[0] or {}).get("code", ""),
                                     "note": "จากตารางสอน"} for name, d in by_teacher.items()]
                iss.info(SHEET_BY_KEY["sections"].title, None, None, f"{code}: ครูผู้สอน {len(by_teacher)} คน อ่านจากตารางสอน")
            elif by_teacher:
                name, d = next(iter(by_teacher.items()))
                p.sections[code] = [{"row": None, "level": d["level"], "rooms": [], "every": True, "teacher": name,
                                     "teacher_code": d["teacher_code"] or (book.find(name)[0] or {}).get("code", ""), "note": ""}]
    final_secs = {**db_secs}
    for code, lst in p.sections.items():
        final_secs[code] = [{"class_level": s["level"], "rooms": rooms_text(s["rooms"], s["every"]), "teacher": s["teacher"],
                             "teacher_code": s["teacher_code"]} for s in lst]
    p.final_secs = final_secs

    # sections: overlaps, rooms left without a teacher, several teachers
    for code, lst in p.sections.items():
        lv = lst[0]["level"]
        all_rooms = sorted(rooms_of_level.get(lv, set()), key=room_key)
        taker_rooms = [r for r in all_rooms if _room_takes(final_courses[code]["programs"], final_rooms.get((lv, r)))]
        covered: Dict[str, int] = {}
        for s in lst:
            for r in (taker_rooms if s["every"] else s["rooms"]):
                if r in covered:
                    iss.error(S if s["row"] else SHEET_BY_KEY["timetable"].title, s["row"], "ห้อง",
                              f"{code} ห้อง {lv}/{r} มีครูสอนสองคน (ดูแถว {covered[r] or '-'})")
                covered.setdefault(r, s["row"])
        missing = [r for r in taker_rooms if r not in covered]
        if missing and not any(s["every"] for s in lst):
            iss.warn(SHEET_BY_KEY["sections"].title, lst[0]["row"], "ห้อง", f"{code}: ห้อง {', '.join(lv + '/' + r for r in missing)} ยังไม่มีครูสอน")
        if len(lst) > 1:
            iss.info(SHEET_BY_KEY["sections"].title, lst[0]["row"], "ครูผู้สอน",
                     f"{code} สอน {len(lst)} กลุ่ม (เก็บแยกห้องแล้ว • ปพ.5/สิทธิ์ครูตอนนี้ยังใช้ {lst[0]['teacher']} ทั้งวิชา จนกว่าจะเปิดระบบแยกห้อง)")
        old = sorted((s["class_level"], s["rooms"], s["teacher"]) for s in db_secs.get(code, []))
        new = sorted((s["level"], rooms_text(s["rooms"], s["every"]), s["teacher"]) for s in lst)
        if sheets.get("sections"):
            cnt("sections", "same" if old == new else ("new" if not old else "update"))

    # timetable vs sections, class clashes, periods per week
    S = SHEET_BY_KEY["timetable"].title
    occ_room: Dict[Tuple[str, str, int, int], Set[str]] = {}
    for e in merged:
        for c, l in e["pairs"]:
            rms = sorted(rooms_of_level.get(l, set()) or {"1"}, key=room_key) if e["every"] else e["rooms"]
            if e["row"] is not None and c in final_secs:
                for r in rms:
                    who = _section_teacher(final_secs[c], l, r, rooms_of_level)
                    if who and normalize_teacher_base_name(who) != e["teacher"]:
                        iss.error(S, e["row"], "ครูผู้สอน", f"{c} {l}/{r}: แผ่น 6 ระบุครู {who}")
                        break
            for r in rms:
                for k in range(e["period"], e["period"] + e["span"]):
                    occ_room.setdefault((l, r, e["day"], k), set()).add(c)
    warned = set()
    for (l, r, d, k), codes in sorted(occ_room.items()):
        if len(codes) > 1 and (l, d, k, tuple(sorted(codes))) not in warned:
            warned.add((l, d, k, tuple(sorted(codes))))
            iss.warn(S, None, "คาบที่", f"{l}/{r} วัน{DAY_NAMES.get(d, d)} คาบ {k} มีหลายวิชาพร้อมกัน: {', '.join(sorted(codes))} "
                     "(ถ้าเป็นวิชาเลือกแยกกลุ่ม ให้ระบุโปรแกรมในแผ่น 5 หรือรายชื่อในแผ่น 8)")
    p.schedules = {}
    for code in sorted(touched_tt | set(p.sections)):
        if code not in final_courses:
            continue
        lv, first_room = _first_room(final_secs.get(code), final_courses[code]["level"], rooms_of_level)
        slots = _course_slots(merged, code, lv, first_room)
        p.schedules[code] = slots
        want = final_courses[code]["periods"]
        got = sum(s["span"] for s in slots)
        if code in p.courses and p.courses[code]["periods"] is not None and slots and got != want:
            iss.warn(SHEET_BY_KEY["courses"].title, p.courses[code]["row"], "คาบ/สัปดาห์", f"{code}: ระบุ {want} คาบ แต่ตารางสอนมี {got} คาบ")
    p.rooms_of_level = rooms_of_level
    p.final_rooms = final_rooms
    p.final_courses = final_courses
    import school_data
    p.data = school_data.analyse(content, t, y, conn, iss, known_sids={s["sid"] for s in p.students},
                                 known_courses=set(p.courses))
    if not any(sheets.values()) and not any(c["rows"] for c in p.data["counts"].values()) and not iss.errors:
        iss.error("ไฟล์", None, None, "ไม่พบข้อมูลในแผ่นใดเลย")
    return p


def _room_takes(programs: str, room: Optional[Dict[str, Any]]) -> bool:
    """A room counts as taking a programme course when its programme is listed (mixed rooms count too)."""
    progs = set(_split(programs))
    return not progs or not room or not room.get("program") or room["program"] in progs


def _section_teacher(secs, level, room, rooms_of_level) -> Optional[str]:
    for s in secs or []:
        if s["class_level"] == level and (s["rooms"] == ALL_ROOMS or room in s["rooms"].split(",")):
            return s["teacher"]
    return None


def _first_room(secs, course_level, rooms_of_level) -> Tuple[str, Optional[str]]:
    """The room whose timetable stands for the whole course in `courses.schedule_json` (None = every slot)."""
    lv = _split(course_level)[0] if _split(course_level) else ""
    if not secs:
        return lv, None
    s0 = sorted(secs, key=lambda s: (0, 0, "") if s["rooms"] == ALL_ROOMS else room_key(s["rooms"].split(",")[0]))[0]
    lv = s0["class_level"] or lv
    if s0["rooms"] == ALL_ROOMS:
        rooms = sorted(rooms_of_level.get(lv, set()), key=room_key)
        return lv, (rooms[0] if len(rooms) > 1 else None)
    return lv, s0["rooms"].split(",")[0]


def _course_slots(merged, code, level, first_room) -> List[Dict[str, Any]]:
    out = []
    for e in sorted(merged, key=lambda e: (e["day"], e["period"])):
        if not any(c == code for c, _ in e["pairs"]):
            continue
        if first_room is not None and not e["every"] and first_room not in e["rooms"]:
            continue
        out.append({"day": e["day"], "day_name": "วัน" + DAY_NAMES.get(e["day"], ""), "period": e["period"], "span": e["span"],
                    "room": "" if e["every"] else ",".join(e["rooms"])})
    return out


# ---------------------------------------------------------------- public entry points
def _report(p: Plan) -> Dict[str, Any]:
    order = {"error": 0, "warning": 1, "info": 2}
    import school_data
    data = getattr(p, "data", {"counts": {}})
    specs = [(s.key, s.title, s.tables, p.counts[s.key]) for s in SHEETS] +             [(d.key, d.title, d.table, data["counts"][d.key]) for d in school_data.DATA_SHEETS if d.key in data["counts"]]
    titles = [x[1] for x in specs]
    items = sorted(p.issues.items, key=lambda i: (order[i["level"]], titles.index(i["sheet"]) if i["sheet"] in titles else -1, i["row"] or 0))
    sheets = []
    for key, title, tables, c in specs:
        sheets.append({"key": key, "title": title, "tables": tables, **c,
                       "errors": sum(1 for i in items if i["sheet"] == title and i["level"] == "error"),
                       "warnings": sum(1 for i in items if i["sheet"] == title and i["level"] == "warning")})
    return {"term": p.term, "year": p.year, "sheets": sheets, "issues": items[:800], "issue_total": len(items),
            "errors": p.issues.errors, "warnings": sum(1 for i in items if i["level"] == "warning"),
            "can_commit": p.issues.errors == 0 and any(x[3]["rows"] for x in specs)}


def preview(content: bytes, term: str, year: str, db_path: str = DB_DEFAULT_PATH) -> Dict[str, Any]:
    with get_connection(db_path) as conn:
        return _report(analyse(content, term, year, conn))


def commit(content: bytes, term: str, year: str, db_path: str = DB_DEFAULT_PATH, by: str = "") -> Dict[str, Any]:
    from timetable_manager import _insert_blank_enrolment
    with get_connection(db_path) as conn:
        p = analyse(content, term, year, conn)
        rep = _report(p)
        if not rep["can_commit"]:
            rep["committed"] = False
            return rep
    import backup_manager
    backup = backup_manager.create_backup(label=f"ก่อนนำเข้าฟอร์มข้อมูลโรงเรียน {term}/{year}", term=term, year=year, db_path=db_path)
    t, y = p.term, p.year
    done: Dict[str, int] = {}
    start = database.get_semester_start_date(t, y, db_path=db_path)
    with get_connection(db_path) as conn:
        cur = conn.cursor()
        try:
            for tr in p.teachers:
                if tr["action"] == "new":
                    cur.execute("INSERT INTO school_teachers (name, code, login_pin) VALUES (?, ?, ?)", (tr["name"], tr["code"], tr["code"]))
                else:
                    cur.execute("UPDATE school_teachers SET code = ?, login_pin = COALESCE(NULLIF(login_pin, ''), ?) WHERE id = ?",
                                (tr["code"], tr["code"], tr["id"]))
            for pr in p.programs.values():
                cur.execute("""INSERT INTO programs (code, name, stage, note, updated_at) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
                               ON CONFLICT(code) DO UPDATE SET name = excluded.name, stage = excluded.stage, note = excluded.note,
                               updated_at = CURRENT_TIMESTAMP""", (pr["code"], pr["name"], pr["stage"], pr["note"]))
            levels_with_rooms: Dict[str, List[Dict[str, Any]]] = {}
            for (lv, rm), r in p.rooms.items():
                cur.execute("""INSERT INTO class_rooms (term, year, class_level, room, program, advisor1, advisor2, advisor3, no_checkin, note, updated_at)
                               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                               ON CONFLICT(term, year, class_level, room) DO UPDATE SET program = excluded.program, advisor1 = excluded.advisor1,
                               advisor2 = excluded.advisor2, advisor3 = excluded.advisor3, no_checkin = excluded.no_checkin, note = excluded.note,
                               updated_at = CURRENT_TIMESTAMP""", (t, y, lv, rm, r["program"], *r["advisors"], r["no_checkin"], r["note"]))
                levels_with_rooms.setdefault(lv, [])
            for lv in levels_with_rooms:  # the per-level advisors the older screens read: the level's rooms in order
                names: List[str] = []
                rows = sorted(cur.execute("SELECT advisor1, advisor2, advisor3, room FROM class_rooms WHERE term = ? AND year = ? AND class_level = ?",
                                          (t, y, lv)).fetchall(), key=lambda r: room_key(r["room"]))
                for r in rows:
                    for a in (r["advisor1"], r["advisor2"], r["advisor3"]):
                        if a and normalize_teacher_base_name(a) not in [normalize_teacher_base_name(n) for n in names]:
                            names.append(a)
                old = cur.execute("SELECT advisor1, advisor2, advisor3 FROM class_advisors WHERE term = ? AND year = ? AND class_level = ?",
                                  (t, y, lv)).fetchone()
                new3 = (names + ["", "", ""])[:3]
                if old and [normalize_teacher_base_name(a or "") for a in old] == [normalize_teacher_base_name(a) for a in new3]:
                    continue
                cur.execute("""INSERT INTO class_advisors (term, year, class_level, advisor1, advisor2, advisor3, updated_at)
                               VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                               ON CONFLICT(term, year, class_level) DO UPDATE SET advisor1 = excluded.advisor1, advisor2 = excluded.advisor2,
                               advisor3 = excluded.advisor3, updated_at = CURRENT_TIMESTAMP""", (t, y, lv, *new3))
            for s in p.students:
                cur.execute("""INSERT INTO students (student_id, full_name, citizen_id) VALUES (?, ?, ?)
                               ON CONFLICT(student_id) DO UPDATE SET full_name = excluded.full_name,
                               citizen_id = CASE WHEN excluded.citizen_id != '' THEN excluded.citizen_id ELSE students.citizen_id END""",
                            (s["sid"], s["full_name"], s["cid"]))
                for old_lv in s["moved_from"]:
                    cur.execute("UPDATE class_students SET is_active = 0, updated_at = CURRENT_TIMESTAMP WHERE term = ? AND year = ? AND class_level = ? AND student_id = ?",
                                (t, y, old_lv, s["sid"]))
                old = cur.execute("SELECT full_name FROM class_students WHERE term = ? AND year = ? AND class_level = ? AND student_id = ?",
                                  (t, y, s["level"], s["sid"])).fetchone()
                full = old["full_name"] if old and _same_name(old["full_name"], s["full_name"]) else s["full_name"]
                cur.execute("""INSERT INTO class_students (term, year, class_level, student_id, student_no, full_name,
                               prefix, first_name, last_name, room, is_active, is_locked, program, note)
                               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ฟอร์มนำเข้า')
                               ON CONFLICT(term, year, class_level, student_id) DO UPDATE SET student_no = excluded.student_no, full_name = excluded.full_name,
                               prefix = excluded.prefix, first_name = excluded.first_name, last_name = excluded.last_name,
                               room = excluded.room, is_active = excluded.is_active, is_locked = excluded.is_locked, program = excluded.program,
                               updated_at = CURRENT_TIMESTAMP""",
                            (t, y, s["level"], s["sid"], s["no"], full, s["prefix"], s["first"], s["last"],
                             s["room"], s["active"], s["locked"], s["program"]))
                has_dmc = cur.execute("SELECT 1 FROM student_dmc_info WHERE student_id = ?", (s["sid"],)).fetchone()
                if has_dmc or not old:
                    cur.execute("""INSERT INTO student_dmc_info (student_id, prefix, first_name, last_name, gender, class_level, room, citizen_id, updated_at)
                                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                                   ON CONFLICT(student_id) DO UPDATE SET prefix = excluded.prefix, first_name = excluded.first_name,
                                   last_name = excluded.last_name, class_level = excluded.class_level, room = excluded.room,
                                   gender = CASE WHEN excluded.gender != '' THEN excluded.gender ELSE student_dmc_info.gender END,
                                   citizen_id = CASE WHEN excluded.citizen_id != '' THEN excluded.citizen_id ELSE student_dmc_info.citizen_id END,
                                   updated_at = CURRENT_TIMESTAMP""",
                                (s["sid"], s["prefix"], s["first"], s["last"], s["gender"], s["level"], s["room"], s["cid"]))
            for c in p.courses.values():
                old = cur.execute("SELECT 1 FROM courses WHERE course_code = ? AND term = ? AND year = ?", (c["code"], t, y)).fetchone()
                if old:
                    cur.execute("""UPDATE courses SET course_name = ?, class_level = ?, course_type = ?, department = ?, credits = ?, score_ratio = ?,
                                   programs = ?, periods_per_week = COALESCE(?, periods_per_week) WHERE course_code = ? AND term = ? AND year = ?""",
                                (c["name"], c["level"], c["type"], c["department"], c["credits"], c["ratio"], c["programs"], c["periods"], c["code"], t, y))
                else:
                    cur.execute("""INSERT INTO courses (course_code, course_name, term, year, teacher, teacher_code, start_date, schedule_json, credits,
                                   class_level, department, course_type, score_ratio, periods_per_week, programs)
                                   VALUES (?, ?, ?, ?, '', '', ?, '[]', ?, ?, ?, ?, ?, ?, ?)""",
                                (c["code"], c["name"], t, y, start, c["credits"], c["level"], c["department"], c["type"], c["ratio"], c["periods"] or 0, c["programs"]))
                stage = "3" if c["level"] in ("ม.4", "ม.5", "ม.6") else "2"
                cur.execute("""INSERT INTO course_catalog (course_code, course_name, term, stage, class_level, course_type, department, subject_prefix,
                               credits, score_ratio, programs, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                               ON CONFLICT(course_code) DO UPDATE SET course_name = excluded.course_name, term = excluded.term, stage = excluded.stage,
                               class_level = excluded.class_level, course_type = excluded.course_type, department = excluded.department,
                               credits = excluded.credits, score_ratio = excluded.score_ratio, programs = excluded.programs, updated_at = CURRENT_TIMESTAMP""",
                            (c["code"], c["name"], t, stage, c["level"], c["type"], c["department"] or "-", c["code"][0], c["credits"], c["ratio"], c["programs"]))
            for code in p.electives:
                cur.execute("UPDATE courses SET enrol_mode = 'list' WHERE course_code = ? AND term = ? AND year = ?", (code, t, y))
            for code in p.list_off:
                cur.execute("UPDATE courses SET enrol_mode = '' WHERE course_code = ? AND term = ? AND year = ?", (code, t, y))
            for code, lst in p.sections.items():
                cur.execute("DELETE FROM course_sections WHERE course_code = ? AND term = ? AND year = ?", (code, t, y))
                for s in lst:
                    cur.execute("""INSERT INTO course_sections (course_code, term, year, class_level, rooms, teacher, teacher_code, note)
                                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""", (code, t, y, s["level"], rooms_text(s["rooms"], s["every"]), s["teacher"],
                                                                       s["teacher_code"], s["note"]))
                first = sorted(lst, key=lambda s: (0, 0, "") if s["every"] else room_key(s["rooms"][0]))[0]
                cur.execute("UPDATE courses SET teacher = ?, teacher_code = ? WHERE course_code = ? AND term = ? AND year = ?",
                            (first["teacher"], first["teacher_code"], code, t, y))
            done["timetable_rows"] = 0
            for base, slot in p.timetable.items():
                for r in cur.execute("SELECT id, teacher_name FROM teacher_timetables WHERE term = ? AND year = ?", (t, y)).fetchall():
                    if normalize_teacher_base_name(r["teacher_name"]) == base:
                        cur.execute("DELETE FROM teacher_timetables WHERE id = ?", (r["id"],))
                for e in slot["rows"]:
                    cur.execute("""INSERT INTO teacher_timetables (term, year, teacher_name, day_of_week, period_num, period_span, course_code,
                                   course_name, class_level, room, note, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)""",
                                (t, y, slot["name"], e["day"], e["period"], e["span"], e["code"], e["name"], e["level"], e["room"], e["note"]))
                    done["timetable_rows"] += 1
            for code, slots in p.schedules.items():
                if slots or code in p.sections:
                    cur.execute("UPDATE courses SET schedule_json = ?, periods_per_week = ? WHERE course_code = ? AND term = ? AND year = ?",
                                (json.dumps(slots, ensure_ascii=False), sum(s["span"] for s in slots) or
                                 (p.courses.get(code) or {}).get("periods") or 0, code, t, y))
                    if code in p.courses and p.courses[code]["periods"] is not None:
                        cur.execute("UPDATE courses SET periods_per_week = ? WHERE course_code = ? AND term = ? AND year = ?",
                                    (p.courses[code]["periods"], code, t, y))
            # enrolment: touched courses x their students, touched students x their level's courses
            touched = set(p.courses) | set(p.sections) | set(p.electives) | set(p.list_off) | set(p.schedules)
            levels = {s["level"] for s in p.students}
            if levels:
                marks = ",".join("?" * len(levels))
                for r in cur.execute(f"SELECT course_code, class_level FROM courses WHERE term = ? AND year = ?", (t, y)).fetchall():
                    if set(_split(r["class_level"])) & levels:
                        touched.add(r["course_code"])
            sids = {s["sid"] for s in p.students}
            added = 0
            enrolled_into: List[str] = []
            for code in sorted(touched):
                takers = eligible_students(conn, code, t, y)
                if takers is None:
                    info = {r["student_id"]: r for r in cur.execute(
                        "SELECT student_id, student_no, class_level FROM class_students WHERE term = ? AND year = ? AND is_active = 1", (t, y))}
                    takers = [dict(info[s]) for s in p.electives.get(code, []) if s in info]
                elif code not in (set(p.courses) | set(p.sections) | set(p.electives) | set(p.list_off) | set(p.schedules)):
                    takers = [s for s in takers if s["student_id"] in sids]
                for s in takers:
                    if _insert_blank_enrolment(cur, s["student_id"], s["student_no"], code, t, y, s["class_level"]):
                        added += 1
                        if code not in enrolled_into:
                            enrolled_into.append(code)
            done["enrolments_added"] = added
            import school_data
            data_done = school_data.apply(p.data, cur, t, y)
            done["data_rows"] = data_done["written"]
            cur.execute("""INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)
                           ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP""",
                        (_managed_key(t, y), json.dumps({"at": datetime.now().isoformat(timespec="seconds"), "by": by,
                                                         "rows": {k: v["rows"] for k, v in p.counts.items()}}, ensure_ascii=False)))
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    database.sync_semester_attendance_to_courses(t, y, db_path=db_path)
    database.refresh_student_prefixes(db_path=db_path)   # คำนำหน้าตามอายุ สำหรับรายชื่อที่เพิ่งนำเข้า
    # courses whose ปพ.5 changes without any attendance number moving: a new roster, a new course row, a new timetable
    database.notify_courses_changed(t, y, sorted(set(enrolled_into) | set(p.courses) | set(p.sections) | set(p.schedules)
                                                 | set(data_done["courses"])))
    rep["committed"] = True
    rep["backup_id"] = backup.get("id")
    rep["done"] = done
    return rep
