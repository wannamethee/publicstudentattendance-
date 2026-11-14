"""
Excel Ingestion Parser for ปพ.5 and School Grading Archive.
Parses .xlsx / .xls workbooks into normalized structure and saves into SQLite database.
"""

import os
import io
import re
import json
import sqlite3
import shutil
from pathlib import Path
from typing import Dict, Any, List, Optional, Union
import openpyxl

from database import init_db, get_connection, normalize_teacher_name, DB_DEFAULT_PATH

OUTPUTS_DIR = Path("outputs")
OUTPUTS_DIR.mkdir(exist_ok=True)


def clean_thai_text(val: Any) -> str:
    """Strip and clean string value."""
    if val is None:
        return ""
    s = str(val).strip()
    if s in ("None", "#N/A", "0", "0.0", "-"):
        return ""
    return s


def parse_pwp5_excel(
    file_input: Union[str, Path, bytes, io.BytesIO],
    filename: Optional[str] = None
) -> Dict[str, Any]:
    """
    Parse a ปพ.5 Excel workbook into standardized course and student structure.
    """
    if isinstance(file_input, (str, Path)):
        filepath = Path(file_input)
        if not filepath.exists():
            raise FileNotFoundError(f"Excel file not found: {filepath}")
        fname = filepath.name if filename is None else filename
        wb = openpyxl.load_workbook(filepath, data_only=True)
    else:
        # Bytes or BytesIO
        if isinstance(file_input, bytes):
            bio = io.BytesIO(file_input)
        else:
            bio = file_input
        fname = filename or "uploaded.xlsx"
        wb = openpyxl.load_workbook(bio, data_only=True)

    # 1. Regex parse filename as strong fallback
    # Pattern: 68-1 (ม.1) ง21101 การงานอาชีพ 1 - ครูสมชาย.xlsx
    f_year = None
    f_term = None
    f_level = None
    f_code = None
    f_name = None
    f_teacher = None

    # Try matching "68-1" or "2568-1"
    m = re.search(
        r"(?:(?:25)?(\d{2})[-_/](\d))\s*(?:\((.*?)\)\s*)?([ก-ฮa-zA-Z\d]+)\s*(.*?)(?:\s*[-_]\s*ครู(.*?))?\.xlsx?$",
        fname,
        re.IGNORECASE
    )
    if m:
        y_short, t_val, f_level, f_code, f_cname, f_tch = m.groups()
        if y_short:
            f_year = f"25{y_short}" if len(y_short) == 2 else y_short
        f_term = t_val
        if f_code:
            f_code = f_code.strip()
        if f_cname:
            f_name = f_cname.strip()
        if f_tch:
            f_teacher = f"ครู{f_tch.strip()}"
    else:
        # Simpler pattern: e.g. "ค21101_การงาน_2568_1.xlsx" or "ง21101.xlsx"
        m2 = re.search(r"([ก-ฮa-zA-Z]\d{5})", fname)
        if m2:
            f_code = m2.group(1).strip()

    # 2. Extract course header from (1) ปกปพ. or sheet 1
    c_code = None
    c_name = None
    term = None
    year = None
    teacher = None
    level = f_level or ""

    if "(1) ปกปพ." in wb.sheetnames:
        ws1 = wb["(1) ปกปพ."]
        c_code = clean_thai_text(ws1["L9"].value)
        c_name = clean_thai_text(ws1["E9"].value)
        term_val = clean_thai_text(ws1["I7"].value)
        year_val = clean_thai_text(ws1["L7"].value)
        teacher_val = clean_thai_text(ws1["E11"].value)
        level_val = clean_thai_text(ws1["E7"].value)

        if term_val:
            term = term_val
        if year_val:
            year = year_val
        if teacher_val:
            teacher = teacher_val
        if level_val:
            level = level_val

    # Check (4) รวมคะแนน for course header fallback
    if "(4) รวมคะแนน" in wb.sheetnames:
        ws4 = wb["(4) รวมคะแนน"]
        if not c_name:
            c_name = clean_thai_text(ws4["C2"].value)
        if not c_code:
            c_code = clean_thai_text(ws4["M2"].value)
        if not level:
            level = clean_thai_text(ws4["M3"].value)

    # Apply filename fallbacks if sheet values were missing or formula #N/A
    if not c_code:
        c_code = f_code or "UNKNOWN"
    if not c_name:
        c_name = f_name or "รายวิชา"
    if not term:
        term = f_term or "1"
    if not year:
        year = f_year or "2568"
    if not teacher:
        teacher = f_teacher or ""

    # Normalize teacher title
    if teacher:
        m_t = re.search(r"((?:นาย|นางสาว|นาง|ดร\.|ว่าที่\s*ร\.ต\.|ครู)\s*[^\s\d]+(?:\s+[^\s\d]+)?)", teacher)
        if m_t:
            teacher = m_t.group(1).strip()

    # 3. Extract Students and Attendance
    students_dict: Dict[str, Dict[str, Any]] = {}

    # Read from (2) เวลาเรียน1 and (3) เวลาเรียน2
    if "(2) เวลาเรียน1" in wb.sheetnames:
        ws2 = wb["(2) เวลาเรียน1"]
        ws3 = wb.get("(3) เวลาเรียน2", None) if hasattr(wb, "get") else (wb["(3) เวลาเรียน2"] if "(3) เวลาเรียน2" in wb.sheetnames else None)

        for r in range(9, ws2.max_row + 1):
            s_no = ws2.cell(r, 1).value
            s_id = ws2.cell(r, 2).value
            s_name = ws2.cell(r, 3).value

            s_name_str = clean_thai_text(s_name)
            if not s_name_str:
                continue

            s_id_str = clean_thai_text(s_id)
            if not s_id_str:
                s_id_str = f"NO_{int(s_no):02d}" if s_no and isinstance(s_no, (int, float)) else f"ROW_{r:02d}"

            # Read 50 slots from ws2 (cols 4 to 53)
            status_list = []
            for c in range(4, 54):
                val = ws2.cell(r, c).value
                val_s = str(val).strip() if val is not None else ""
                status_list.append(val_s if val_s in ("/", "ล", "ข", "ขาด", "ลา") else ("/" if val == 1 else ""))

            # Read 50 slots from ws3 (cols 4 to 53)
            if ws3:
                for c in range(4, 54):
                    val = ws3.cell(r, c).value
                    val_s = str(val).strip() if val is not None else ""
                    status_list.append(val_s if val_s in ("/", "ล", "ข", "ขาด", "ลา") else ("/" if val == 1 else ""))
            else:
                status_list.extend([""] * 50)

            # Ensure exactly 100 slots
            if len(status_list) < 100:
                status_list.extend([""] * (100 - len(status_list)))
            elif len(status_list) > 100:
                status_list = status_list[:100]

            p_cnt = status_list.count("/")
            l_cnt = status_list.count("ล")
            a_cnt = max(0, 40 - p_cnt - l_cnt)
            pct = round((p_cnt / 40.0) * 100, 1)

            try:
                st_no_int = int(s_no) if s_no is not None else len(students_dict) + 1
            except Exception:
                st_no_int = len(students_dict) + 1

            students_dict[s_id_str] = {
                "student_no": st_no_int,
                "student_id": s_id_str,
                "full_name": s_name_str,
                "status_list": status_list,
                "present_count": p_cnt,
                "leave_count": l_cnt,
                "absent_count": a_cnt,
                "percentage": pct,
                "scores": {},
                "grade": "0"
            }

    # 4. Extract Scores and Grades from (4) รวมคะแนน
    if "(4) รวมคะแนน" in wb.sheetnames:
        ws4 = wb["(4) รวมคะแนน"]
        for r in range(10, ws4.max_row + 1):
            s_no = ws4.cell(r, 1).value
            s_name = ws4.cell(r, 2).value
            s_name_str = clean_thai_text(s_name)
            if not s_name_str:
                continue

            try:
                st_no_int = int(s_no) if s_no is not None else None
            except Exception:
                st_no_int = None

            total_score = ws4.cell(r, 17).value  # Col Q
            final_grade = ws4.cell(r, 18).value  # Col R
            grade_str = str(final_grade).strip() if final_grade is not None else "0"

            # Match to existing student by name or student_no
            matched_key = None
            for sid, sdata in students_dict.items():
                if sdata["full_name"] == s_name_str or (st_no_int and sdata["student_no"] == st_no_int):
                    matched_key = sid
                    break

            if not matched_key:
                sid_fallback = f"NO_{st_no_int:02d}" if st_no_int else f"ST_{len(students_dict)+1:02d}"
                matched_key = sid_fallback
                students_dict[matched_key] = {
                    "student_no": st_no_int or (len(students_dict) + 1),
                    "student_id": sid_fallback,
                    "full_name": s_name_str,
                    "status_list": [""] * 100,
                    "present_count": 0,
                    "leave_count": 0,
                    "absent_count": 40,
                    "percentage": 0.0,
                    "scores": {},
                    "grade": "0"
                }

            st = students_dict[matched_key]
            st["scores"]["total"] = total_score if total_score is not None else 0
            st["grade"] = grade_str

    # 5. Generic Fallback: if neither (2) nor (4) existed
    if not students_dict:
        # Scan first sheet
        ws_first = wb.active
        for r in range(2, ws_first.max_row + 1):
            s_no = ws_first.cell(r, 1).value
            s_id = ws_first.cell(r, 2).value
            s_name = ws_first.cell(r, 3).value
            s_name_str = clean_thai_text(s_name)
            if not s_name_str:
                # Maybe col 2 is name
                s_name_str = clean_thai_text(s_id)
                s_id = None
            if not s_name_str:
                continue

            sid_str = clean_thai_text(s_id) or f"NO_{r-1:02d}"
            try:
                st_no_int = int(s_no) if s_no is not None else r - 1
            except Exception:
                st_no_int = r - 1

            students_dict[sid_str] = {
                "student_no": st_no_int,
                "student_id": sid_str,
                "full_name": s_name_str,
                "status_list": [""] * 100,
                "present_count": 0,
                "leave_count": 0,
                "absent_count": 40,
                "percentage": 0.0,
                "scores": {},
                "grade": "0"
            }

    # 6. Check course description in (6) ตัวชี้วัด
    course_desc = None
    if "(6) ตัวชี้วัด" in wb.sheetnames:
        ws6 = wb["(6) ตัวชี้วัด"]
        cell_val = ws6["A3"].value
        if cell_val and "กรอกคำอธิบายรายวิชา" not in str(cell_val) and len(str(cell_val).strip()) > 10:
            course_desc = str(cell_val).strip()

    # Sort students by student_no
    sorted_students = sorted(students_dict.values(), key=lambda s: s["student_no"])

    return {
        "header": {
            "course_code": str(c_code).strip(),
            "course_name": str(c_name).strip(),
            "semester": str(term).strip(),
            "academic_year": str(year).strip(),
            "teacher": str(teacher).strip(),
            "level": str(level).strip(),
            "course_description": course_desc,
        },
        "students": sorted_students
    }


def ingest_excel_file(
    file_input: Union[str, Path, bytes, io.BytesIO],
    filename: Optional[str] = None,
    override_term: Optional[str] = None,
    override_year: Optional[str] = None,
    override_teacher: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Parse an Excel file and ingest course, students, and grade history into SQLite database.
    Also ensures populated workbook is saved to outputs/ for direct access.
    """
    init_db(db_path)

    parsed = parse_pwp5_excel(file_input, filename=filename)
    header = parsed["header"]
    students = parsed["students"]

    course_code = header.get("course_code") or "UNKNOWN"
    course_name = header.get("course_name") or ""
    term = str(override_term or header.get("semester") or "1")
    year = str(override_year or header.get("academic_year") or "2568")
    teacher = normalize_teacher_name(override_teacher or header.get("teacher") or "")
    course_desc = header.get("course_description")

    students_upserted = 0
    grades_upserted = 0

    with get_connection(db_path) as conn:
        cursor = conn.cursor()

        # 1. Upsert course record with composite key (course_code, term, year)
        if course_desc:
            cursor.execute(
                """
                INSERT INTO courses (course_code, course_name, term, year, teacher, course_description)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(course_code, term, year) DO UPDATE SET
                    course_name = excluded.course_name,
                    teacher = CASE WHEN excluded.teacher != '' THEN excluded.teacher ELSE courses.teacher END,
                    course_description = excluded.course_description;
                """,
                (course_code, course_name, term, year, teacher, course_desc)
            )
        else:
            cursor.execute(
                """
                INSERT INTO courses (course_code, course_name, term, year, teacher)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(course_code, term, year) DO UPDATE SET
                    course_name = excluded.course_name,
                    teacher = CASE WHEN excluded.teacher != '' THEN excluded.teacher ELSE courses.teacher END;
                """,
                (course_code, course_name, term, year, teacher)
            )

        # 2. Upsert student and grade history records
        for idx, student in enumerate(students, start=1):
            student_id = str(student.get("student_id") or "").strip()
            if not student_id:
                student_id = f"NO_{idx:02d}"

            full_name = str(student.get("full_name") or "").strip()
            scores = dict(student.get("scores") or {})
            scores["student_no"] = student.get("student_no") or idx

            att_dict = {
                "percentage": student.get("percentage", 100.0),
                "present_count": student.get("present_count", 40),
                "absent_count": student.get("absent_count", 0),
                "leave_count": student.get("leave_count", 0),
                "status_list": student.get("status_list") or (["/"] * 40 + [""] * 60)
            }
            final_grade = str(student.get("grade") or "0").strip()

            scores_json = json.dumps(scores, ensure_ascii=False)
            attendance_json = json.dumps(att_dict, ensure_ascii=False)
            attributes_json = json.dumps({}, ensure_ascii=False)

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

    # 3. Save copy into outputs/ folder
    target_excel_name = f"{course_code}_{term}_{year}_ปพ5_filled.xlsx"
    out_path = OUTPUTS_DIR / target_excel_name
    if isinstance(file_input, (str, Path)):
        shutil.copy2(str(file_input), str(out_path))
    elif isinstance(file_input, bytes):
        with open(out_path, "wb") as f:
            f.write(file_input)
    elif isinstance(file_input, io.BytesIO):
        file_input.seek(0)
        with open(out_path, "wb") as f:
            f.write(file_input.read())

    # Sync cover sheet and class advisors onto the saved file
    try:
        from excel_mapper import sync_advisors_to_excel
        sync_advisors_to_excel(out_path, term=term, year=year, course_code=course_code)
    except Exception:
        pass

    return {
        "status": "success",
        "course_code": course_code,
        "course_name": course_name,
        "term": term,
        "year": year,
        "teacher": teacher,
        "students_upserted": students_upserted,
        "grades_upserted": grades_upserted,
        "output_excel": str(out_path.name)
    }


def batch_ingest_excel_folder(
    folder_path: Union[str, Path],
    override_term: Optional[str] = None,
    override_year: Optional[str] = None,
    override_teacher: Optional[str] = None,
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Scan a directory for all .xlsx files and ingest them into the archive database.
    Supports auto-detecting teacher names from subfolder names (e.g. '101 ครูสมชาย').
    """
    root = Path(folder_path)
    if not root.exists():
        raise FileNotFoundError(f"Folder not found: {root}")

    excel_files: List[Path] = []
    for r, _, files in os.walk(root):
        for f in files:
            if f.endswith(".xlsx") and not f.startswith("~$"):
                excel_files.append(Path(r) / f)

    results = []
    total_courses = 0
    total_students = 0

    for ef in excel_files:
        try:
            # Check if parent folder contains teacher name
            file_teacher = override_teacher
            if not file_teacher:
                parent_name = ef.parent.name
                if "ครู" in parent_name:
                    file_teacher = parent_name

            res = ingest_excel_file(
                ef,
                filename=ef.name,
                override_term=override_term,
                override_year=override_year,
                override_teacher=file_teacher,
                db_path=db_path
            )
            results.append({
                "file": ef.name,
                "status": "success",
                "course_code": res["course_code"],
                "course_name": res["course_name"],
                "term": res["term"],
                "year": res["year"],
                "teacher": res.get("teacher", ""),
                "students_count": res["students_upserted"]
            })
            total_courses += 1
            total_students += res["students_upserted"]
        except Exception as e:
            results.append({
                "file": ef.name,
                "status": "error",
                "error": str(e)
            })

    return {
        "total_files": len(excel_files),
        "total_courses": total_courses,
        "total_students": total_students,
        "results": results
    }
