"""
แผ่นข้อมูลระหว่างเทอมของ "ไฟล์ข้อมูลโรงเรียน" (ต่อท้ายแผ่น 1-8 ของ school_import)

ส่งออกไฟล์เดียว -> แก้/ย้ายเครื่อง -> นำเข้าไฟล์เดียว แล้วทุกหน้าขึ้นครบ: คะแนน เกรด เวลาเรียนรายวัน
การตั้งค่าเช็คชื่อ ภาคเรียน ข้อมูล DMC เยี่ยมบ้าน ผู้ลงนาม ข้อสอบ การลา ผู้ดูแลระบบ การตั้งค่าระบบ

หลักการ (เจ้าของเลือก 7 พ.ย. 2569)
- นำเข้าแบบ รวม/อัปเดต: แถวที่จับคู่ได้ (ตามคีย์ของตาราง) อัปเดต แถวใหม่เพิ่ม แถวที่ไม่มีในไฟล์คงเดิม ไม่ลบอะไร
- ส่งออกได้เฉพาะผู้ดูแลระบบ ไม่มี PIN ของครู (school_teachers.login_pin ไม่อยู่ในไฟล์)
- แผ่นที่ผูกกับภาคเรียนไม่มีคอลัมน์ term/year: ใช้ภาคเรียนที่เลือกตอนนำเข้า
- หัวตารางเป็นชื่อคอลัมน์ในฐานข้อมูลตรง ๆ (ห้ามแก้) ค่ายาวเกิน 1 เซลล์ของ Excel ต่อคอลัมน์ "ชื่อ#2", "ชื่อ#3" ...
- รูปภาพ/ไฟล์แนบ (รูปเยี่ยมบ้าน ไฟล์ตารางสอบ โลโก้) ไม่อยู่ใน Excel อยู่ในไฟล์สำรอง .zip (backup_manager)
"""
import io
import json
import re
from typing import Any, Dict, List, Optional, Tuple

CELL_MAX = 32000          # Excel holds 32,767 characters per cell
HEAD_ROW = 2              # row 1 = Thai description, row 2 = column names, data from row 3


class DataSheet:
    def __init__(self, key, title, table, keys, term_scoped=True, cols=None, exclude=(), help="", update_only=False,
                 where=None):
        self.key, self.title, self.table, self.keys = key, title, table, list(keys)
        self.term_scoped, self.cols, self.exclude = term_scoped, cols, set(exclude)
        self.help, self.update_only, self.where = help, update_only, where


# order matters on import: exams before exam_attempts (attempts point at an exam by course+type)
DATA_SHEETS: List[DataSheet] = [
    DataSheet("left_roster", "9 นักเรียนที่ออกจากชั้น", "class_students", ["class_level", "student_id"], exclude=("id",),
              where="is_active = 0", help="รายชื่อในชั้นที่ไม่ใช้งานแล้ว (ย้ายชั้น/ย้ายออก) ที่ยังมีผลการเรียนหรือเวลาเรียนค้างอยู่ "
                                        "• นักเรียนปัจจุบันอยู่ในแผ่น 4"),
    DataSheet("left_students", "10 ทะเบียนนักเรียนที่ออก", "students", ["student_id"], term_scoped=False,
              where="student_id IN (SELECT student_id FROM class_students WHERE term = :t AND year = :y AND is_active = 0) "
                    "AND student_id NOT IN (SELECT student_id FROM class_students WHERE term = :t AND year = :y AND is_active = 1)",
              help="ชื่อและเลขประจำตัวประชาชนของนักเรียนในแผ่น 9"),
    DataSheet("grades", "11 ผลการเรียน", "grades_history", ["student_id", "course_code"], exclude=("id",),
              help="คะแนนเก็บ/สอบ (scores_json) เวลาเรียน (attendance_json) คุณลักษณะ และเกรด ของนักเรียนแต่ละวิชา"),
    DataSheet("daily", "12 เช็คชื่อรายวัน", "daily_attendance", ["attendance_date", "student_id"], exclude=("id",),
              help="สถานะรายวันจากหน้าเช็คเวลาเรียน (present/absent/late/leave/sick ...) เวลาเรียนของทุกวิชาคำนวณจากแผ่นนี้"),
    DataSheet("daily_config", "13 ตั้งค่าเช็คชื่อ", "daily_attendance_config", ["class_level"], exclude=("id",),
              help="วันเริ่ม วันหยุด และวันที่ล็อกของแต่ละระดับชั้น"),
    DataSheet("course_detail", "14 รายวิชา (ละเอียด)", "courses", ["course_code"],
              cols=["course_code", "course_description", "start_date", "score_config_json", "attendance_config_json",
                    "pp5_labels_json"],
              update_only=True, help="ส่วนของรายวิชาที่ไม่อยู่ในแผ่น 5: โครงสร้างคะแนน การตั้งค่าเวลาเรียน วันเริ่มเรียน ตัวชี้วัดและหัวข้อคุณลักษณะใน ปพ.5 (รายวิชาต้องมีอยู่แล้ว)"),
    DataSheet("semesters", "15 ภาคเรียน", "semester_configs", ["term", "year"], term_scoped=False, exclude=("id",),
              help="รายการภาคเรียนที่เปิดในระบบ"),
    DataSheet("dmc", "16 ข้อมูล DMC", "student_dmc_info", ["student_id"], term_scoped=False,
              where="student_id IN (SELECT student_id FROM class_students WHERE term = :t AND year = :y)",
              help="ข้อมูลนักเรียนจาก DMC (วันเกิด ที่อยู่ ผู้ปกครอง ...) เฉพาะนักเรียนของภาคเรียนนี้ • ข้อมูลส่วนบุคคล"),
    DataSheet("home_visits", "17 เยี่ยมบ้าน", "home_visit_reports", ["class_level"], exclude=("id",),
              help="รายงานเยี่ยมบ้านของแต่ละระดับชั้น (รูปภาพอยู่ในไฟล์สำรอง .zip)"),
    DataSheet("signatories", "18 ผู้ลงนาม", "school_signatories", ["year"], term_scoped=False, exclude=("id",),
              where="year = :y", help="ผู้อำนวยการ หัวหน้าวิชาการ นายทะเบียน หัวหน้ากลุ่มสาระ ของปีการศึกษานี้"),
    DataSheet("exams", "19 ข้อสอบ", "exams", ["course_code", "exam_type"], exclude=("id",),
              help="ข้อสอบกลางภาค/ปลายภาคของแต่ละวิชา"),
    DataSheet("exam_attempts", "20 ผลสอบ", "exam_attempts", ["exam_course_code", "exam_type", "student_id"], exclude=("id", "exam_id"),
              help="ผลการสอบของนักเรียนแต่ละคน (อ้างข้อสอบด้วยรหัสวิชา + ประเภทสอบ)"),
    DataSheet("exam_permits", "21 สิทธิ์สอบ", "exam_permits", ["course_code", "student_id"], help="อนุญาตสอบรายคน (กรณี มส.)"),
    DataSheet("exam_locks", "22 ล็อกข้อสอบ", "exam_locks", ["course_code", "exam_type"]),
    DataSheet("exam_windows", "23 ช่วงสอบ", "exam_windows", ["exam_type"]),
    DataSheet("exam_timetables", "24 ตารางสอบ", "exam_timetables", ["exam_type"], help="ไฟล์ตารางสอบอยู่ในไฟล์สำรอง .zip"),
    DataSheet("exam_times", "25 เวลาสอบรายวิชา", "exam_course_times", ["course_code", "exam_type"]),
    DataSheet("leaves", "26 การลาของครู", "teacher_leaves", ["teacher_code", "leave_type", "start_date", "end_date", "created_at"],
              term_scoped=False, exclude=("id",), help="บันทึกการลาของครูทั้งหมด"),
    DataSheet("admins", "27 ผู้ดูแลระบบ", "system_admins", ["teacher_code"], term_scoped=False),
    DataSheet("prefs", "28 ค่าที่ผู้ใช้เลือก", "user_preferences", ["user_code", "key"], term_scoped=False,
              help="เช่น ภาคเรียนที่แต่ละคน mark ไว้"),
    DataSheet("settings", "29 ตั้งค่าระบบ", "app_settings", ["key"], term_scoped=False,
              help="ชื่อโรงเรียน สี โลโก้ วันเปิดภาคเรียน ... (ไฟล์โลโก้อยู่ในไฟล์สำรอง .zip)"),
    # quizzes before quiz_attempts (a try points at its quiz by the quiz's uid)
    DataSheet("quizzes", "30 แบบทดสอบย่อย", "quizzes", ["uid"], exclude=("id",),
              help="แบบทดสอบย่อย/หลังเรียนของแต่ละวิชา พร้อมช่องคะแนนที่เชื่อม (unit_slot 0-7 = ช่อง 1-8) • ห้ามแก้ uid"),
    DataSheet("quiz_attempts", "31 ผลแบบทดสอบย่อย", "quiz_attempts", ["quiz_uid", "student_id", "attempt_no"], exclude=("id", "quiz_id"),
              help="ทุกครั้งที่นักเรียนทำแบบทดสอบย่อย (อ้างแบบทดสอบด้วย uid ในแผ่น 30)"),
    DataSheet("teacher_marks", "32 ลงเวลาครู", "teacher_attendance_marks", ["teacher_code", "date"], term_scoped=False,
              help="ตารางลงเวลาครู: วันที่ครูมาสาย (ส) หรือไปราชการ (ร) • วันอื่นเป็น มา อัตโนมัติ ส่วน ล/ขส อยู่ในแผ่น 26"),
]
DATA_BY_KEY = {s.key: s for s in DATA_SHEETS}
NEVER_EXPORT = {"login_pin"}


def _table_cols(conn, table) -> List[Tuple[str, bool]]:
    return [(r[1], bool(r[3])) for r in conn.execute(f"PRAGMA table_info({table})")]


def _cols(conn, spec: DataSheet) -> List[str]:
    """Sheet columns, in table order (exam_attempts: exam_id replaced by the exam's course code + type)."""
    have = [c for c, _ in _table_cols(conn, spec.table)]
    cols = [c for c in (spec.cols or have) if c in have and c not in spec.exclude and c not in NEVER_EXPORT]
    if spec.term_scoped:
        cols = [c for c in cols if c not in ("term", "year")]
    if spec.table == "exam_attempts":
        cols = ["exam_course_code", "exam_type"] + cols
    if spec.table == "quiz_attempts":
        cols = ["quiz_uid"] + cols
    return cols


def _rows(conn, spec: DataSheet, t: str, y: str) -> List[Dict[str, Any]]:
    if spec.table == "exam_attempts":
        sql = ("SELECT a.*, e.course_code AS exam_course_code, e.exam_type AS exam_type FROM exam_attempts a "
               "JOIN exams e ON e.id = a.exam_id WHERE e.term = :t AND e.year = :y ORDER BY e.course_code, e.exam_type, a.student_id")
    elif spec.table == "quiz_attempts":
        sql = ("SELECT a.*, z.uid AS quiz_uid FROM quiz_attempts a JOIN quizzes z ON z.id = a.quiz_id "
               "WHERE z.term = :t AND z.year = :y ORDER BY z.course_code, z.id, a.student_id, a.attempt_no")
    else:
        conds = []
        if spec.term_scoped:
            conds.append("term = :t AND year = :y")
        if spec.where:
            conds.append(spec.where)
        sql = f"SELECT * FROM {spec.table}" + (" WHERE " + " AND ".join(conds) if conds else "")
        order = [k for k in spec.keys if k in [c for c, _ in _table_cols(conn, spec.table)]]
        if order:
            sql += " ORDER BY " + ", ".join(order)
    return [dict(r) for r in conn.execute(sql, {"t": t, "y": y})]


def _text(v) -> str:
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


# ---------------------------------------------------------------- export
def write_sheets(wb, conn, term: str, year: str) -> Dict[str, int]:
    """Append the data sheets to an openpyxl workbook. Returns row counts per sheet."""
    from openpyxl.styles import Alignment, Font, PatternFill
    from openpyxl.utils import get_column_letter
    t, y = str(term), str(year)
    import quizzes
    quizzes.ensure(conn)
    import exams
    exams.ensure_columns(conn)
    import teacher_attendance
    teacher_attendance.ensure(conn)
    font = Font(name="TH SarabunPSK", size=14)
    head = Font(name="Consolas", size=10, bold=True, color="FFFFFF")
    fill = PatternFill("solid", start_color="374151")
    counts = {}
    for spec in DATA_SHEETS:
        cols = _cols(conn, spec)
        rows = _rows(conn, spec, t, y)
        # a value longer than one Excel cell continues in "col#2", "col#3" ...
        width = {c: 1 for c in cols}
        for r in rows:
            for c in cols:
                n = len(_text(r.get(c)))
                if n > CELL_MAX:
                    width[c] = max(width[c], -(-n // CELL_MAX))
        heads = []
        for c in cols:
            heads += [c] + [f"{c}#{i}" for i in range(2, width[c] + 1)]
        sh = wb.create_sheet(spec.title)
        sh.cell(1, 1, f"{spec.help or spec.table}  •  ตาราง {spec.table}  •  ห้ามแก้หัวตารางแถวที่ 2  •  "
                      + ("ภาคเรียนตามที่เลือกตอนนำเข้า" if spec.term_scoped else "ไม่ผูกภาคเรียน")).font = Font(name="TH SarabunPSK", size=14, bold=True)
        for ci, h in enumerate(heads, start=1):
            c = sh.cell(HEAD_ROW, ci, h)
            c.font, c.fill = head, fill
            c.alignment = Alignment(horizontal="center")
            sh.column_dimensions[get_column_letter(ci)].width = 14 if not h.endswith("_json") else 30
        for ri, r in enumerate(rows, start=HEAD_ROW + 1):
            ci = 1
            for c in cols:
                v = _text(r.get(c))
                for i in range(width[c]):
                    cell = sh.cell(ri, ci, v[i * CELL_MAX:(i + 1) * CELL_MAX] or None)
                    cell.number_format = "@"
                    cell.font = font
                    ci += 1
        sh.freeze_panes = sh.cell(HEAD_ROW + 1, 1)
        counts[spec.key] = len(rows)
    return counts


# ---------------------------------------------------------------- import
def read_sheets(content: bytes) -> Dict[str, List[Tuple[int, Dict[str, str]]]]:
    """{sheet key: [(excel row, {column: text})]} for the data sheets found in the workbook."""
    import openpyxl
    wb = openpyxl.load_workbook(io.BytesIO(content), data_only=True, read_only=True)
    names = {re.sub(r"^\d+\s*", "", n).strip(): n for n in wb.sheetnames}
    out: Dict[str, List[Tuple[int, Dict[str, str]]]] = {}
    for spec in DATA_SHEETS:
        name = spec.title if spec.title in wb.sheetnames else names.get(re.sub(r"^\d+\s*", "", spec.title).strip())
        if not name:
            continue
        rows = list(wb[name].iter_rows(values_only=True))
        if len(rows) < HEAD_ROW:
            continue
        heads = [_text(h).strip() for h in rows[HEAD_ROW - 1]]
        data = []
        for i, r in enumerate(rows[HEAD_ROW:], start=HEAD_ROW + 1):
            rec: Dict[str, str] = {}
            for ci, h in enumerate(heads):
                if not h:
                    continue
                v = _text(r[ci]) if ci < len(r) else ""
                base = h.split("#")[0]
                rec[base] = rec.get(base, "") + v
            if any(v.strip() for v in rec.values()):
                data.append((i, rec))
        out[spec.key] = data
    wb.close()
    return out


def _same(a, b) -> bool:
    return _text(a).strip() == _text(b).strip()


def analyse(content: bytes, term: str, year: str, conn, issues, known_sids=(), known_courses=()) -> Dict[str, Any]:
    """Plan the data-sheet writes. known_sids / known_courses: students and courses sheets 4/5 of the same file add."""
    t, y = str(term), str(year)
    import quizzes
    quizzes.ensure(conn)
    import exams
    exams.ensure_columns(conn)
    import teacher_attendance
    teacher_attendance.ensure(conn)
    sheets = read_sheets(content)
    sids = {r[0] for r in conn.execute("SELECT student_id FROM class_students WHERE term = ? AND year = ?", (t, y))} | set(known_sids)         | {_text(r.get("student_id")).strip() for _, r in sheets.get("left_roster", [])}
    all_sids = sids | {r[0] for r in conn.execute("SELECT student_id FROM students")}         | {_text(r.get("student_id")).strip() for _, r in sheets.get("left_students", [])}
    courses = {r[0] for r in conn.execute("SELECT course_code FROM courses WHERE term = ? AND year = ?", (t, y))} | set(known_courses)
    file_exams = {(_text(r.get("course_code")).strip(), _text(r.get("exam_type")).strip()) for _, r in sheets.get("exams", [])}
    db_exams = {(r[0], r[1]) for r in conn.execute("SELECT course_code, exam_type FROM exams WHERE term = ? AND year = ?", (t, y))}
    quiz_uids = {_text(r.get("uid")).strip() for _, r in sheets.get("quizzes", [])} | {
        r[0] for r in conn.execute("SELECT uid FROM quizzes WHERE term = ? AND year = ?", (t, y))}
    plan: Dict[str, Any] = {"writes": {}, "counts": {}}
    for spec in DATA_SHEETS:
        rows = sheets.get(spec.key)
        if rows is None:
            continue
        cols = _cols(conn, spec)
        table_cols = dict(_table_cols(conn, spec.table))
        unknown = [c for c in (rows[0][1] if rows else {}) if c not in cols and c not in ("term", "year")]
        if unknown:
            issues.warn(spec.title, HEAD_ROW, None, "ไม่รู้จักคอลัมน์ " + ", ".join(unknown) + " (ข้ามคอลัมน์นี้)")
        c = {"rows": len(rows), "new": 0, "update": 0, "same": 0}
        writes = []
        for row, rec in rows:
            rec = {k: v for k, v in rec.items() if k in cols}
            if spec.term_scoped and spec.table not in ("exam_attempts", "quiz_attempts"):
                rec["term"], rec["year"] = t, y
            missing = [k for k in spec.keys if not _text(rec.get(k)).strip()]
            if missing and spec.table != "teacher_leaves":
                issues.error(spec.title, row, missing[0], f"ต้องมีค่า {', '.join(missing)}")
                continue
            sid = _text(rec.get("student_id")).strip()
            if sid and spec.table in ("grades_history", "daily_attendance", "exam_permits", "exam_attempts", "quiz_attempts") and sid not in sids:
                issues.warn(spec.title, row, "student_id", f"ไม่พบนักเรียน {sid} ในภาคเรียน {t}/{y} (ข้ามแถวนี้)")
                continue
            if sid and spec.table == "student_dmc_info" and sid not in all_sids:
                issues.warn(spec.title, row, "student_id", f"ไม่พบนักเรียน {sid} (ข้ามแถวนี้)")
                continue
            code = _text(rec.get("course_code") or rec.get("exam_course_code")).strip()
            if code and spec.table in ("grades_history", "courses", "exams", "exam_permits", "exam_locks", "exam_course_times",
                                       "exam_attempts", "quizzes") and code not in courses:
                issues.warn(spec.title, row, "course_code", f"ไม่พบรายวิชา {code} ในภาคเรียน {t}/{y} (ข้ามแถวนี้)")
                continue
            if spec.table == "exam_attempts" and (code, _text(rec.get("exam_type")).strip()) not in (file_exams | db_exams):
                issues.warn(spec.title, row, "exam_type", f"ไม่พบข้อสอบ {code} {rec.get('exam_type')} (ข้ามแถวนี้)")
                continue
            if spec.table == "quiz_attempts" and _text(rec.get("quiz_uid")).strip() not in quiz_uids:
                issues.warn(spec.title, row, "quiz_uid", "ไม่พบแบบทดสอบนี้ในแผ่น 30 (ข้ามแถวนี้)")
                continue
            for k, v in list(rec.items()):
                if k.endswith("_json") and _text(v).strip():
                    try:
                        json.loads(v)
                    except Exception:
                        issues.error(spec.title, row, k, "ข้อมูล JSON เสีย (อย่าแก้ช่องนี้ด้วยมือ)")
                        break
            else:
                old = _find(conn, spec, rec, t, y)
                if old is None and spec.update_only:
                    if _text(rec.get(spec.keys[0])).strip() in known_courses:
                        c["update"] += 1        # the course row comes from sheet 5 of this same file
                        writes.append(_blank_to_null(rec, table_cols))
                        continue
                    issues.warn(spec.title, row, spec.keys[0], "ไม่พบแถวนี้ในระบบ (ข้าม)")
                    continue
                if old is None:
                    c["new"] += 1
                elif all(_same(old.get(k), rec.get(k)) for k in rec):
                    c["same"] += 1
                    continue
                else:
                    c["update"] += 1
                writes.append(_blank_to_null(rec, table_cols))
        plan["writes"][spec.key] = writes
        plan["counts"][spec.key] = c
    return plan


def _blank_to_null(rec, table_cols):
    """Empty cell: NOT NULL column -> "", otherwise NULL."""
    return {k: (v if _text(v).strip() else ("" if table_cols.get(k) else None)) for k, v in rec.items()}


def _exam_id(conn, code, etype, t, y) -> Optional[int]:
    r = conn.execute("SELECT id FROM exams WHERE course_code = ? AND exam_type = ? AND term = ? AND year = ?", (code, etype, t, y)).fetchone()
    return r[0] if r else None


def _quiz_id(conn, uid, t, y) -> Optional[int]:
    r = conn.execute("SELECT id FROM quizzes WHERE uid = ? AND term = ? AND year = ?", (_text(uid).strip(), t, y)).fetchone()
    return r[0] if r else None


def _find(conn, spec: DataSheet, rec: Dict[str, Any], t: str, y: str) -> Optional[Dict[str, Any]]:
    if spec.table == "quiz_attempts":
        qid = _quiz_id(conn, rec.get("quiz_uid"), t, y)
        if qid is None:
            return None
        r = conn.execute("SELECT * FROM quiz_attempts WHERE quiz_id = ? AND student_id = ? AND CAST(attempt_no AS TEXT) = ?",
                         (qid, rec.get("student_id"), _text(rec.get("attempt_no")).strip())).fetchone()
        return {**dict(r), "quiz_uid": rec.get("quiz_uid")} if r else None
    if spec.table == "exam_attempts":
        eid = _exam_id(conn, rec.get("exam_course_code"), rec.get("exam_type"), t, y)
        if eid is None:
            return None
        r = conn.execute("SELECT * FROM exam_attempts WHERE exam_id = ? AND student_id = ?", (eid, rec.get("student_id"))).fetchone()
        if not r:
            return None
        return {**dict(r), "exam_course_code": rec.get("exam_course_code"), "exam_type": rec.get("exam_type")}
    keys = list(spec.keys) + (["term", "year"] if spec.term_scoped else [])
    where = " AND ".join(f"CAST(COALESCE({k}, '') AS TEXT) = ?" for k in keys)
    r = conn.execute(f"SELECT * FROM {spec.table} WHERE {where}", [_text(rec.get(k)).strip() for k in keys]).fetchone()
    return dict(r) if r else None


def apply(plan: Dict[str, Any], cur, term: str, year: str) -> Dict[str, Any]:
    """Write the planned rows inside the caller's transaction. Returns what changed (for the ปพ.5 refresh)."""
    t, y = str(term), str(year)
    import quizzes
    quizzes.ensure(cur)
    import exams
    exams.ensure_columns(cur)
    import teacher_attendance
    teacher_attendance.ensure(cur)
    touched_courses = set()
    written = 0
    for spec in DATA_SHEETS:
        for rec in plan["writes"].get(spec.key, []):
            rec = dict(rec)
            if spec.table == "exam_attempts":
                eid = _exam_id(cur, rec.pop("exam_course_code"), rec.pop("exam_type"), t, y)
                if eid is None:
                    continue
                rec["exam_id"] = eid
                old = cur.execute("SELECT id FROM exam_attempts WHERE exam_id = ? AND student_id = ?", (eid, rec["student_id"])).fetchone()
                match = {"id": old[0]} if old else None
            elif spec.table == "quiz_attempts":
                qid = _quiz_id(cur, rec.pop("quiz_uid"), t, y)
                if qid is None:
                    continue
                rec["quiz_id"] = qid
                old = cur.execute("SELECT id FROM quiz_attempts WHERE quiz_id = ? AND student_id = ? AND CAST(attempt_no AS TEXT) = ?",
                                  (qid, rec["student_id"], _text(rec.get("attempt_no")).strip())).fetchone()
                match = {"id": old[0]} if old else None
            else:
                old = _find(cur, spec, rec, t, y)
                keys = list(spec.keys) + (["term", "year"] if spec.term_scoped else [])
                match = {k: rec.get(k) for k in keys} if old else None
            if match:
                sets = [k for k in rec if k not in match]
                if sets:
                    cur.execute(f"UPDATE {spec.table} SET " + ", ".join(f"{k} = ?" for k in sets) + " WHERE "
                                + " AND ".join(f"CAST(COALESCE({k}, '') AS TEXT) = ?" for k in match),
                                [rec[k] for k in sets] + [_text(v).strip() for v in match.values()])
            else:
                cur.execute(f"INSERT INTO {spec.table} (" + ", ".join(rec) + ") VALUES (" + ", ".join("?" * len(rec)) + ")",
                            list(rec.values()))
            written += 1
            if spec.table in ("grades_history", "courses"):
                touched_courses.add(_text(rec.get("course_code")).strip())
    daily_levels = {_text(r.get("class_level")).strip() for r in plan["writes"].get("daily", [])} | \
                   {_text(r.get("class_level")).strip() for r in plan["writes"].get("daily_config", [])}
    return {"written": written, "courses": sorted(c for c in touched_courses if c), "daily_levels": sorted(l for l in daily_levels if l)}
