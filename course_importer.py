# -*- coding: utf-8 -*-
"""
Course & Teacher Roster Importer + Automated PorPor 5 Excel & PDF Generator
Supports Term 2, Academic Year 2569 and beyond.
"""

import school_profile
import os
import sys
import re
import csv
import json
import sqlite3
from pathlib import Path
from typing import Dict, Any, List, Optional, Tuple

import openpyxl
from excel_mapper import map_sgs_to_excel, infer_course_metadata, infer_class_level
from attendance_rules import effective_remark
import pp5_labels

OUTPUT_DIR = Path("outputs").resolve()
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = "school_archive.db"

# Canonical department name mapping
DEPT_MAP = {
    "1": "กลุ่มสาระการเรียนรู้ภาษาไทย",
    "ภาษาไทย": "กลุ่มสาระการเรียนรู้ภาษาไทย",
    "1 ภาษาไทย": "กลุ่มสาระการเรียนรู้ภาษาไทย",
    "2": "กลุ่มสาระการเรียนรู้คณิตศาสตร์",
    "คณิต": "กลุ่มสาระการเรียนรู้คณิตศาสตร์",
    "คณิตศาสตร์": "กลุ่มสาระการเรียนรู้คณิตศาสตร์",
    "2 คณิต": "กลุ่มสาระการเรียนรู้คณิตศาสตร์",
    "3": "กลุ่มสาระการเรียนรู้วิทยาศาสตร์และเทคโนโลยี",
    "วิทย์": "กลุ่มสาระการเรียนรู้วิทยาศาสตร์และเทคโนโลยี",
    "วิทย์-เทคโน": "กลุ่มสาระการเรียนรู้วิทยาศาสตร์และเทคโนโลยี",
    "วิทยาศาสตร์": "กลุ่มสาระการเรียนรู้วิทยาศาสตร์และเทคโนโลยี",
    "3 วิทย์-เทคโน": "กลุ่มสาระการเรียนรู้วิทยาศาสตร์และเทคโนโลยี",
    "4": "กลุ่มสาระการเรียนรู้สังคมศึกษา ศาสนา และวัฒนธรรม",
    "สังคม": "กลุ่มสาระการเรียนรู้สังคมศึกษา ศาสนา และวัฒนธรรม",
    "สังคมฯ": "กลุ่มสาระการเรียนรู้สังคมศึกษา ศาสนา และวัฒนธรรม",
    "สังคมศึกษา": "กลุ่มสาระการเรียนรู้สังคมศึกษา ศาสนา และวัฒนธรรม",
    "4 สังคมฯ": "กลุ่มสาระการเรียนรู้สังคมศึกษา ศาสนา และวัฒนธรรม",
    "5": "กลุ่มสาระการเรียนรู้สุขศึกษาและพลศึกษา",
    "สุขศึกษา": "กลุ่มสาระการเรียนรู้สุขศึกษาและพลศึกษา",
    "สุขศึกษาฯ": "กลุ่มสาระการเรียนรู้สุขศึกษาและพลศึกษา",
    "พลศึกษา": "กลุ่มสาระการเรียนรู้สุขศึกษาและพลศึกษา",
    "5 สุขศึกษาฯ": "กลุ่มสาระการเรียนรู้สุขศึกษาและพลศึกษา",
    "6": "กลุ่มสาระการเรียนรู้ศิลปะ",
    "ศิลปะ": "กลุ่มสาระการเรียนรู้ศิลปะ",
    "6 ศิลปะ": "กลุ่มสาระการเรียนรู้ศิลปะ",
    "7": "กลุ่มสาระการเรียนรู้การงานอาชีพ",
    "การงาน": "กลุ่มสาระการเรียนรู้การงานอาชีพ",
    "การงานอาชีพ": "กลุ่มสาระการเรียนรู้การงานอาชีพ",
    "7 การงานอาชีพ": "กลุ่มสาระการเรียนรู้การงานอาชีพ",
    "8": "กลุ่มสาระการเรียนรู้ภาษาต่างประเทศ",
    "ภาษาต่างประเทศ": "กลุ่มสาระการเรียนรู้ภาษาต่างประเทศ",
    "อังกฤษ": "กลุ่มสาระการเรียนรู้ภาษาต่างประเทศ",
    "8 ภาษาต่างประเทศ": "กลุ่มสาระการเรียนรู้ภาษาต่างประเทศ",
    "9": "กลุ่มสาระการเรียนรู้วิทยาศาสตร์และเทคโนโลยี",
    "IS": "กลุ่มสาระการเรียนรู้วิทยาศาสตร์และเทคโนโลยี",
    "9 IS": "กลุ่มสาระการเรียนรู้วิทยาศาสตร์และเทคโนโลยี",
    "91": "กิจกรรมพัฒนาผู้เรียน",
    "กิจกรรม": "กิจกรรมพัฒนาผู้เรียน",
    "91 กิจกรรม": "กิจกรรมพัฒนาผู้เรียน",
}

COURSE_TYPE_MAP = {
    "1": "พื้นฐาน",
    "1 พื้นฐาน": "พื้นฐาน",
    "พื้นฐาน": "พื้นฐาน",
    "2": "เพิ่มเติม",
    "2 เพิ่มเติม": "เพิ่มเติม",
    "เพิ่มเติม": "เพิ่มเติม",
    "3": "เลือก",
    "3 เลือก": "เลือก",
    "เลือก": "เลือก",
    "4": "กิจกรรม",
    "4 กิจกรรม": "กิจกรรม",
    "กิจกรรม": "กิจกรรม",
}


def clean_dept(dept_str: str) -> str:
    s = str(dept_str or "").strip()
    return DEPT_MAP.get(s, s)


def clean_course_type(type_str: str) -> str:
    s = str(type_str or "").strip()
    return COURSE_TYPE_MAP.get(s, s)


def get_teacher_lookup_map(db_path: str = DB_PATH) -> Tuple[Dict[str, str], Dict[str, str]]:
    """Returns (code_to_name, name_to_fullname) lookup dicts based on school_teachers."""
    code_map = {}
    name_map = {}
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    c.execute("SELECT id, code, name FROM school_teachers")
    for tid, code, name in c.fetchall():
        full_name = name.strip()
        if code and code.strip():
            code_map[code.strip()] = full_name
        name_map[full_name] = full_name
        m = re.sub(r"^(นาย|นางสาว|นาง|ครู|ดร\.|ว่าที่\s*ร\.ต\.)\s*", "", full_name)
        first_name = m.split()[0] if m.split() else m
        name_map[first_name] = full_name
        name_map[f"ครู{first_name}"] = full_name
    conn.close()
    return code_map, name_map


def resolve_teacher(teacher_code: str, teacher_raw: str, code_map: Dict[str, str], name_map: Dict[str, str]) -> str:
    """Resolve teacher canonical name by code first, then by name match."""
    c_str = str(teacher_code or "").strip()
    if c_str and c_str in code_map:
        return code_map[c_str]

    raw = str(teacher_raw or "").strip()
    if raw in name_map:
        return name_map[raw]

    raw_clean = re.sub(r"^(นาย|นางสาว|นาง|ครู)\s*", "", raw)
    for k, v in name_map.items():
        if raw_clean and (raw_clean in k or k in raw_clean):
            return v

    return raw


def parse_course_rows(file_bytes_or_text: bytes | str) -> List[Dict[str, Any]]:
    """Parse CSV text or Excel bytes into a list of normalized course dictionaries."""
    rows_data = []

    if isinstance(file_bytes_or_text, bytes):
        try:
            from io import BytesIO
            wb = openpyxl.load_workbook(BytesIO(file_bytes_or_text), data_only=True)
            ws = wb.active
            all_rows = list(ws.iter_rows(values_only=True))
            if all_rows:
                header = [str(c or "").strip() for c in all_rows[0]]
                for r in all_rows[1:]:
                    if not any(r):
                        continue
                    row_dict = {}
                    for idx, val in enumerate(r):
                        if idx < len(header):
                            row_dict[header[idx]] = str(val or "").strip()
                    rows_data.append(row_dict)
        except Exception:
            try:
                text = file_bytes_or_text.decode("utf-8-sig")
            except Exception:
                text = file_bytes_or_text.decode("cp874", errors="replace")
            return parse_course_rows(text)
    else:
        reader = csv.reader(file_bytes_or_text.strip().splitlines())
        lines = list(reader)
        if lines:
            header = [c.strip() for c in lines[0]]
            for r in lines[1:]:
                if not any(r):
                    continue
                row_dict = {}
                for idx, val in enumerate(r):
                    if idx < len(header):
                        row_dict[header[idx]] = str(val or "").strip()
                rows_data.append(row_dict)

    parsed_courses = []
    for r in rows_data:
        code = r.get("รหัสวิชา") or r.get("course_code") or ""
        name = r.get("ชื่อรายวิชา") or r.get("course_name") or ""
        credits_str = r.get("หน่วยกิต") or r.get("credits") or "1.0"
        level = r.get("ชั้นเรียน") or r.get("class_level") or ""
        c_type = r.get("ประเภทวิชา") or r.get("course_type") or "พื้นฐาน"
        dept = r.get("กลุ่มสาระ") or r.get("department") or ""
        t_code = r.get("รหัสครู") or r.get("teacher_code") or ""
        t_name = r.get("ครูผู้สอน") or r.get("teacher") or ""
        score_ratio = r.get("สัดส่วนคะแนน") or r.get("score_ratio") or "70:30"
        periods = r.get("คาบ/สัปดาห์") or r.get("periods_per_week") or ""

        if not code or not name:
            continue

        try:
            c_val = float(credits_str)
        except Exception:
            c_val = 1.0

        try:
            p_val = int(periods)
        except Exception:
            p_val = int(c_val * 2) if c_val > 0 else 1

        parsed_courses.append({
            "course_code": code,
            "course_name": name,
            "credits": c_val,
            "class_level": level,
            "course_type": clean_course_type(c_type),
            "department": clean_dept(dept),
            "teacher_code": t_code,
            "teacher_raw": t_name,
            "score_ratio": score_ratio,
            "periods_per_week": p_val,
        })

    return parsed_courses


def generate_single_course_porpor5(
    course_dict: Dict[str, Any],
    db_path: str = DB_PATH
) -> Optional[str]:
    """Generates PorPor 5 Excel file for a single course with pre-filled students."""
    c_code = course_dict["course_code"]
    c_name = course_dict["course_name"]
    term = str(course_dict["term"])
    year = str(course_dict["year"])
    level = course_dict.get("class_level") or ""
    teacher = course_dict.get("teacher") or ""
    credits = course_dict.get("credits", 1.0)
    dept = course_dict.get("department") or ""
    c_type = course_dict.get("course_type") or "พื้นฐาน"
    ratio = course_dict.get("score_ratio") or "70:30"

    conn = sqlite3.connect(db_path)
    c = conn.cursor()

    # Pre-fetch students
    c.execute(
        """
        SELECT student_no, student_id, full_name 
        FROM class_students 
        WHERE term = ? AND year = ? AND class_level = ?
          AND COALESCE(is_locked, 0) = 0 AND COALESCE(is_active, 1) = 1
        ORDER BY student_no ASC
        """,
        (term, year, level)
    )
    s_rows = c.fetchall()
    if not s_rows:
        c.execute(
            """
            SELECT student_no, student_id, full_name 
            FROM class_students 
            WHERE term = '1' AND year = ? AND class_level = ?
              AND COALESCE(is_locked, 0) = 0 AND COALESCE(is_active, 1) = 1
            ORDER BY student_no ASC
            """,
            (year, level)
        )
        s_rows = c.fetchall()

    students = [
        {"student_no": r[0], "student_id": r[1], "full_name": r[2]}
        for r in s_rows
    ]

    c.execute("SELECT school_name FROM school_signatories WHERE year = ?", (year,))
    s_row = c.fetchone()
    school_name = s_row[0] if s_row and s_row[0] else school_profile.full_name(db_path)
    conn.close()

    filename_base = f"{year}-{term} ({level}) {c_code} {c_name} - {teacher}"
    clean_filename_base = re.sub(r'[\\/*?:"<>|]', "_", filename_base)
    excel_out = OUTPUT_DIR / f"{clean_filename_base}_ปพ5_filled.xlsx"

    data = {
        "header": {
            "school_name": school_name,
            "semester": term,
            "academic_year": year,
            "course_code": c_code,
            "course_name": c_name,
            "credits": credits,
            "class_level": level,
            "teacher": teacher,
            "department": dept,
            "course_type": c_type,
            "score_ratio": ratio,
        },
        "students": students,
    }

    try:
        map_sgs_to_excel(
            data,
            template_path="template_ปพ5_blank.xlsx",
            output_excel_path=str(excel_out)
        )
        return str(excel_out)
    except Exception as e:
        print(f"[ERROR] Failed generating PorPor 5 for {c_code}: {e}")
        return None


def get_courses_by_teacher(
    teacher: str,
    term: Optional[str] = None,
    year: Optional[str] = None,
    db_path: str = DB_PATH
) -> List[Dict[str, Any]]:
    """Retrieve all courses taught by a given teacher name or code."""
    code_map, name_map = get_teacher_lookup_map(db_path)
    canonical = resolve_teacher(teacher, teacher, code_map, name_map)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()

    query = """
        SELECT 
            c.course_code,
            c.course_name,
            c.term,
            c.year,
            c.teacher,
            c.credits,
            c.class_level,
            c.department,
            c.course_type,
            c.score_ratio,
            c.teacher_code,
            c.periods_per_week,
            COALESCE(
                NULLIF((SELECT COUNT(*) FROM grades_history g WHERE g.course_code = c.course_code AND g.term = c.term AND g.year = c.year), 0),
                NULLIF((SELECT COUNT(*) FROM class_students cs WHERE cs.term = c.term AND cs.year = c.year AND cs.class_level = c.class_level AND COALESCE(cs.is_locked, 0) = 0 AND COALESCE(cs.is_active, 1) = 1), 0),
                (SELECT COUNT(*) FROM class_students cs WHERE cs.term = '1' AND cs.year = c.year AND cs.class_level = c.class_level AND COALESCE(cs.is_locked, 0) = 0 AND COALESCE(cs.is_active, 1) = 1),
                0
            ) AS student_count
        FROM courses c
        WHERE (c.teacher = ? OR c.teacher LIKE ? OR c.teacher_code = ?)
    """
    params = [canonical, f"%{canonical}%", teacher]

    if term:
        query += " AND c.term = ?"
        params.append(str(term))
    if year:
        query += " AND c.year = ?"
        params.append(str(year))

    query += " ORDER BY c.year DESC, c.term DESC, c.class_level ASC, c.course_code ASC;"

    c.execute(query, params)
    rows = [dict(r) for r in c.fetchall()]
    conn.close()
    return rows


def update_or_create_course(
    course_data: Dict[str, Any],
    old_keys: Optional[Dict[str, str]] = None,
    regenerate_porpor5: bool = True,
    db_path: str = DB_PATH
) -> Dict[str, Any]:
    """
    Update an existing course or insert a new one.
    Also regenerates PorPor 5 Excel template with student roster.
    """
    code_map, name_map = get_teacher_lookup_map(db_path)

    c_code = str(course_data["course_code"]).strip()
    c_name = str(course_data["course_name"]).strip()
    term = str(course_data.get("term", "2")).strip()
    year = str(course_data.get("year", "2569")).strip()
    level = str(course_data.get("class_level", "")).strip()
    t_code = str(course_data.get("teacher_code", "")).strip()
    t_raw = str(course_data.get("teacher", "")).strip()
    credits = float(course_data.get("credits", 1.0) or 1.0)
    dept = clean_dept(course_data.get("department", ""))
    c_type = clean_course_type(course_data.get("course_type", "พื้นฐาน"))
    ratio = str(course_data.get("score_ratio", "70:30")).strip()
    periods = int(course_data.get("periods_per_week", int(credits * 2) if credits > 0 else 1) or 1)

    canonical_teacher = resolve_teacher(t_code, t_raw, code_map, name_map)

    conn = sqlite3.connect(db_path)
    c = conn.cursor()

    # Handle renaming of course_code / term / year
    if old_keys:
        old_code = old_keys.get("course_code")
        old_term = old_keys.get("term", term)
        old_year = old_keys.get("year", year)
        if old_code and (old_code != c_code or old_term != term or old_year != year):
            c.execute(
                "DELETE FROM courses WHERE course_code = ? AND term = ? AND year = ?;",
                (old_code, old_term, old_year)
            )

    c.execute(
        """
        INSERT INTO courses (
            course_code, course_name, term, year, teacher,
            credits, class_level, department, course_type, score_ratio, teacher_code, periods_per_week
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(course_code, term, year) DO UPDATE SET
            course_name = excluded.course_name,
            teacher = excluded.teacher,
            credits = excluded.credits,
            class_level = excluded.class_level,
            department = excluded.department,
            course_type = excluded.course_type,
            score_ratio = excluded.score_ratio,
            teacher_code = excluded.teacher_code,
            periods_per_week = excluded.periods_per_week
        """,
        (
            c_code, c_name, term, year, canonical_teacher,
            credits, level, dept, c_type, ratio, t_code, periods
        )
    )
    conn.commit()
    conn.close()

    try:
        from catalog_manager import lookup_catalog_course, upsert_catalog_course, decode_course_code
        existing_cat = lookup_catalog_course(c_code, db_path=db_path)
        decoded = decode_course_code(c_code)
        upsert_catalog_course({
            "course_code": c_code,
            "course_name": c_name,
            "term": decoded["term"],
            "stage": decoded["stage"],
            "class_level": level or decoded["class_level"],
            "course_type": c_type or decoded["course_type"],
            "department": dept or decoded["department"],
            "subject_prefix": decoded["subject_prefix"],
            "credits": credits,
            "score_ratio": ratio,
            "course_description": course_data.get("course_description") or (existing_cat.get("course_description") if existing_cat else "") or "",
        }, old_course_code=(old_keys.get("course_code") if old_keys else None), db_path=db_path)
    except Exception as e_cat:
        print(f"[WARN] Could not sync course {c_code} to catalog: {e_cat}")

    excel_file = None
    if regenerate_porpor5:
        updated_dict = {
            "course_code": c_code,
            "course_name": c_name,
            "term": term,
            "year": year,
            "class_level": level,
            "teacher": canonical_teacher,
            "credits": credits,
            "department": dept,
            "course_type": c_type,
            "score_ratio": ratio,
        }
        excel_file = generate_single_course_porpor5(updated_dict, db_path=db_path)

    return {
        "status": "success",
        "course_code": c_code,
        "course_name": c_name,
        "class_level": level,
        "teacher": canonical_teacher,
        "excel_file": excel_file,
        "message": f"บันทึกข้อมูลวิชา {c_code} {c_name} (ระดับชั้น {level}) สำเร็จ"
    }


def delete_course(
    course_code: str,
    term: str,
    year: str,
    db_path: str = DB_PATH
) -> bool:
    """Delete a course from courses table."""
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    c.execute(
        "DELETE FROM courses WHERE course_code = ? AND term = ? AND year = ?;",
        (course_code, term, year)
    )
    deleted = c.rowcount > 0
    conn.commit()
    conn.close()
    return deleted


def import_courses_and_generate(
    file_bytes_or_text: bytes | str,
    term: str = "2",
    year: str = "2569",
    db_path: str = DB_PATH,
    generate_excel: bool = True,
    generate_pdf: bool = False
) -> Dict[str, Any]:
    """
    Main pipeline:
    1. Parse uploaded course list.
    2. Map teachers via teacher_code to canonical names in school_teachers.
    3. Save courses to SQLite courses table.
    4. Query enrolled students from class_students table.
    5. Generate pre-filled PorPor 5 Excel files in outputs/.
    """
    code_map, name_map = get_teacher_lookup_map(db_path)
    parsed = parse_course_rows(file_bytes_or_text)

    if not parsed:
        return {
            "status": "error",
            "message": "ไม่พบข้อมูลรายวิชาในไฟล์ กรุณาตรวจสอบหัวตาราง (รหัสวิชา, ชื่อรายวิชา, หน่วยกิต, ชั้นเรียน, รหัสครู)"
        }

    conn = sqlite3.connect(db_path)
    c = conn.cursor()

    # Pre-fetch students per class_level for this semester
    students_by_level: Dict[str, List[Dict[str, Any]]] = {}
    for lvl in ["ม.1", "ม.2", "ม.3", "ม.4", "ม.5", "ม.6"]:
        c.execute(
            """
            SELECT student_no, student_id, full_name 
            FROM class_students 
            WHERE term = ? AND year = ? AND class_level = ?
              AND COALESCE(is_locked, 0) = 0 AND COALESCE(is_active, 1) = 1
            ORDER BY student_no ASC
            """,
            (term, year, lvl)
        )
        s_rows = c.fetchall()
        if not s_rows:
            c.execute(
                """
                SELECT student_no, student_id, full_name 
                FROM class_students 
                WHERE term = '1' AND year = ? AND class_level = ?
                  AND COALESCE(is_locked, 0) = 0 AND COALESCE(is_active, 1) = 1
                ORDER BY student_no ASC
                """,
                (year, lvl)
            )
            s_rows = c.fetchall()

        students_by_level[lvl] = [
            {"student_no": r[0], "student_id": r[1], "full_name": r[2]}
            for r in s_rows
        ]

    c.execute("SELECT school_name FROM school_signatories WHERE year = ?", (year,))
    s_row = c.fetchone()
    school_name = s_row[0] if s_row and s_row[0] else school_profile.full_name(db_path)

    results = []
    excel_generated_paths = []

    for item in parsed:
        c_code = item["course_code"]
        c_name = item["course_name"]
        credits = item["credits"]
        level = item["class_level"]
        c_type = item["course_type"]
        dept = item["department"]
        t_code = item["teacher_code"]
        t_raw = item["teacher_raw"]
        ratio = item["score_ratio"]
        periods = item["periods_per_week"]

        try:
            from catalog_manager import lookup_catalog_course, upsert_catalog_course, decode_course_code, _clean_garbled_course_name
            cat = lookup_catalog_course(c_code, db_path=db_path)
            if cat and cat.get("course_name"):
                c_name = cat["course_name"]
            else:
                c_name = _clean_garbled_course_name(c_code, c_name)
                decoded = decode_course_code(c_code)
                upsert_catalog_course({
                    "course_code": c_code,
                    "course_name": c_name,
                    "term": decoded["term"],
                    "stage": decoded["stage"],
                    "class_level": level or decoded["class_level"],
                    "course_type": c_type or decoded["course_type"],
                    "department": dept or decoded["department"],
                    "subject_prefix": decoded["subject_prefix"],
                    "credits": credits,
                    "score_ratio": ratio,
                    "course_description": "",
                }, db_path=db_path)
        except Exception:
            pass

        canonical_teacher = resolve_teacher(t_code, t_raw, code_map, name_map)

        c.execute(
            """
            INSERT INTO courses (
                course_code, course_name, term, year, teacher,
                credits, class_level, department, course_type, score_ratio, teacher_code, periods_per_week
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(course_code, term, year) DO UPDATE SET
                course_name = excluded.course_name,
                teacher = excluded.teacher,
                credits = excluded.credits,
                class_level = excluded.class_level,
                department = excluded.department,
                course_type = excluded.course_type,
                score_ratio = excluded.score_ratio,
                teacher_code = excluded.teacher_code,
                periods_per_week = excluded.periods_per_week
            """,
            (
                c_code, c_name, term, year, canonical_teacher,
                credits, level, dept, c_type, ratio, t_code, periods
            )
        )

        students = students_by_level.get(level, [])

        filename_base = f"{year}-{term} ({level}) {c_code} {c_name} - {canonical_teacher}"
        clean_filename_base = re.sub(r'[\\/*?:"<>|]', "_", filename_base)
        excel_out = OUTPUT_DIR / f"{clean_filename_base}_ปพ5_filled.xlsx"

        has_excel = False
        if generate_excel:
            try:
                data = {
                    "header": {
                        "school_name": school_name,
                        "semester": term,
                        "academic_year": year,
                        "course_code": c_code,
                        "course_name": c_name,
                        "credits": credits,
                        "class_level": level,
                        "teacher": canonical_teacher,
                        "department": dept,
                        "course_type": c_type,
                        "score_ratio": ratio,
                    },
                    "students": students,
                }
                map_sgs_to_excel(
                    data,
                    template_path="template_ปพ5_blank.xlsx",
                    output_excel_path=str(excel_out)
                )
                has_excel = True
                excel_generated_paths.append(excel_out)
            except Exception as e_gen:
                print(f"[ERROR] Failed to generate Excel for {c_code}: {e_gen}")

        results.append({
            "course_code": c_code,
            "course_name": c_name,
            "class_level": level,
            "credits": credits,
            "teacher_code": t_code,
            "teacher": canonical_teacher,
            "student_count": len(students),
            "excel_filename": excel_out.name if has_excel else None,
            "has_excel": has_excel,
        })

    conn.commit()
    conn.close()

    return {
        "status": "success",
        "total_courses": len(results),
        "excel_count": len(excel_generated_paths),
        "pdf_count": 0,
        "courses": results,
        "message": f"นำเข้าสำเร็จ {len(results)} รายวิชา สร้าง ปพ.5 Excel {len(excel_generated_paths)} ไฟล์เรียบร้อยแล้ว"
    }


def _to_num(val: Any) -> Optional[float | int]:
    if val is None:
        return None
    s = str(val).strip()
    if not s or s.startswith("="):
        return None
    try:
        f = float(s)
        return int(f) if f.is_integer() else round(f, 2)
    except Exception:
        return None


def compute_excel_grade(total_score: float, remark: str = "") -> str:
    """
    Matches Sheet (4) รวมคะแนน Col R formula:
    =IF(B10="","",(IF(S10="",(IF(Q10>=80,4,IF(Q10>=75,3.5,IF(Q10>=70,3,IF(Q10>=65,2.5,IF(Q10>=60,2,IF(Q10>=55,1.5,IF(Q10>=50,1,0)))))))),S10)))
    """
    rem = str(remark or "").strip()
    if rem:
        return rem
    if total_score >= 80:
        return "4"
    elif total_score >= 75:
        return "3.5"
    elif total_score >= 70:
        return "3"
    elif total_score >= 65:
        return "2.5"
    elif total_score >= 60:
        return "2"
    elif total_score >= 55:
        return "1.5"
    elif total_score >= 50:
        return "1"
    else:
        return "0"


def _ensure_score_config_column(conn: sqlite3.Connection) -> None:
    c = conn.cursor()
    cols = [r[1] for r in c.execute("PRAGMA table_info(courses);").fetchall()]
    if "score_config_json" not in cols:
        c.execute("ALTER TABLE courses ADD COLUMN score_config_json TEXT;")
        conn.commit()


_scores_wb_cache: Dict[str, Tuple[Tuple[int, int], Dict[str, Any]]] = {}


def _read_scores_workbook(excel_path: Path) -> Dict[str, Any]:
    """
    Sheet (3) attendance % and sheet (4) max scores / student rows of a ปพ.5 file. Opening the workbook is the slow
    part of the scores page, so the values are kept until the file changes (modification time or size); callers
    get their own copy.
    """
    import copy
    st = os.stat(excel_path)
    stamp = (st.st_mtime_ns, st.st_size)
    hit = _scores_wb_cache.get(str(excel_path))
    if hit and hit[0] == stamp:
        return copy.deepcopy(hit[1])
    out: Dict[str, Any] = {"att_pct": {}, "has_scores": False, "u_max": [None] * 8, "m_max": None, "c_max": None,
                           "s_max": None, "students": {}}
    wb = openpyxl.load_workbook(str(excel_path), data_only=False)
    if "(3) เวลาเรียน2" in wb.sheetnames:
        ws_att2 = wb["(3) เวลาเรียน2"]
        for idx in range(1, 45):
            pct_v = _to_num(ws_att2.cell(8 + idx, 52).value)
            if pct_v is not None:
                out["att_pct"][idx] = float(pct_v)
    if "(4) รวมคะแนน" in wb.sheetnames:
        ws = wb["(4) รวมคะแนน"]
        out["has_scores"] = True
        out["u_max"] = [_to_num(ws.cell(9, 3 + i).value) for i in range(8)]
        out["m_max"] = _to_num(ws.cell(9, 12).value)
        out["c_max"] = _to_num(ws.cell(9, 14).value)
        out["s_max"] = _to_num(ws.cell(9, 15).value)
        for idx in range(1, 45):
            r = 9 + idx
            units_r = [_to_num(ws.cell(r, 3 + i).value) for i in range(8)]
            mid_r = _to_num(ws.cell(r, 12).value)
            cen_r = _to_num(ws.cell(r, 14).value)
            fin_r = _to_num(ws.cell(r, 15).value)
            rem_v = ws.cell(r, 19).value
            rem_str = str(rem_v).strip() if rem_v is not None and not str(rem_v).startswith("=") else ""
            if any(x is not None for x in units_r) or mid_r is not None or cen_r is not None or fin_r is not None or rem_str:
                out["students"][idx] = {"units": units_r, "midterm": mid_r, "central_exam": cen_r, "final": fin_r, "remark": rem_str}
    wb.close()
    _scores_wb_cache[str(excel_path)] = (stamp, out)
    return copy.deepcopy(out)


def _unit_manual(raw: Any, units: List[Any]) -> List[int]:
    """Slots 0..7 the teacher typed over (quiz-linked columns); a slot with no value is not kept."""
    out = set()
    for v in raw if isinstance(raw, (list, tuple)) else []:
        try:
            i = int(v)
        except (TypeError, ValueError):
            continue
        if 0 <= i < 8 and i < len(units) and units[i] is not None:
            out.add(i)
    return sorted(out)


def get_course_scores_sheet(
    course_code: str,
    term: str,
    year: str,
    db_path: str = DB_PATH
) -> Dict[str, Any]:
    """
    Retrieve Sheet (4) รวมคะแนน data (max_scores config + student scores + computed totals/grades)
    for a given course, term, and year.
    """
    import json
    from excel_mapper import find_course_matching_file, infer_class_level, infer_course_metadata

    c_code = str(course_code).strip()
    t_str = str(term).strip()
    y_str = str(year).strip()

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    _ensure_score_config_column(conn)
    c = conn.cursor()

    c.execute(
        """
        SELECT course_code, course_name, term, year, teacher, credits, class_level,
               department, course_type, score_ratio, score_config_json
        FROM courses
        WHERE course_code = ? AND term = ? AND year = ?;
        """,
        (c_code, t_str, y_str)
    )
    course_row = c.fetchone()
    if not course_row:
        conn.close()
        return {"status": "error", "message": f"ไม่พบรายวิชา {c_code} ในภาคเรียนที่ {t_str}/{y_str}"}

    course_dict = dict(course_row)
    c_name = course_dict.get("course_name") or ""
    level = course_dict.get("class_level") or infer_class_level(c_code, c_name)
    inferred_meta = infer_course_metadata(c_code, c_name)
    score_ratio = course_dict.get("score_ratio") or inferred_meta.get("score_ratio") or "80:20"

    # Default max scores based on score_ratio (70:30 vs 80:20)
    is_70_30 = "70" in str(score_ratio) and "30" in str(score_ratio)
    score_config = {
        "unit_max": [30, 20, None, None, None, None, None, None] if is_70_30 else [30, 30, None, None, None, None, None, None],
        "midterm_max": 20,
        "central_exam_max": None,
        "school_exam_max": 30 if is_70_30 else 20,
    }

    has_custom_cfg = False
    if course_dict.get("score_config_json"):
        try:
            saved_cfg = json.loads(course_dict["score_config_json"])
            if isinstance(saved_cfg, dict):
                score_config.update(saved_cfg)
                has_custom_cfg = True
        except Exception:
            pass

    # Check if Excel file exists in outputs/ to read Row 9 max scores or student scores if DB is empty
    excel_path = find_course_matching_file(OUTPUT_DIR, c_code, term=t_str, year=y_str, ext=".xlsx")
    excel_student_scores: Dict[int, Dict[str, Any]] = {}
    excel_att_pct_by_no: Dict[int, float] = {}
    if excel_path and excel_path.exists():
        try:
            xl = _read_scores_workbook(excel_path)
            excel_att_pct_by_no = xl["att_pct"]
            if xl["has_scores"]:
                if not has_custom_cfg and not is_70_30:
                    u_max = xl["u_max"]
                    if any(x is not None for x in u_max):
                        score_config["unit_max"] = u_max
                    m_max = xl["m_max"]
                    if m_max is not None:
                        score_config["midterm_max"] = m_max
                    c_max = xl["c_max"]
                    score_config["central_exam_max"] = c_max
                    s_max = xl["s_max"]
                    if s_max is not None:
                        score_config["school_exam_max"] = s_max
                excel_student_scores = xl["students"]
        except Exception as e:
            print(f"[WARN] Could not read scores from Excel {excel_path}: {e}")

    # Load students from class_students (active & not locked)
    c.execute(
        """
        SELECT student_no, student_id, full_name
        FROM class_students
        WHERE term = ? AND year = ? AND class_level = ?
          AND COALESCE(is_locked, 0) = 0 AND COALESCE(is_active, 1) = 1
        ORDER BY student_no ASC, student_id ASC;
        """,
        (t_str, y_str, level)
    )
    roster_rows = c.fetchall()
    if not roster_rows:
        c.execute(
            """
            SELECT student_no, student_id, full_name
            FROM class_students
            WHERE term = '1' AND year = ? AND class_level = ?
              AND COALESCE(is_locked, 0) = 0 AND COALESCE(is_active, 1) = 1
            ORDER BY student_no ASC, student_id ASC;
            """,
            (y_str, level)
        )
        roster_rows = c.fetchall()

    # Load existing grades_history for this course (including attendance_json)
    c.execute(
        """
        SELECT g.student_id, s.full_name, g.scores_json, g.final_grade, g.attendance_json
        FROM grades_history g
        LEFT JOIN students s ON g.student_id = s.student_id
        WHERE g.course_code = ? AND g.term = ? AND g.year = ?
        ORDER BY g.id ASC;
        """,
        (c_code, t_str, y_str)
    )
    grade_rows = c.fetchall()
    conn.close()

    grades_by_sid: Dict[str, Dict[str, Any]] = {}
    for gr in grade_rows:
        sid = str(gr["student_id"]).strip()
        sc_dict = {}
        if gr["scores_json"]:
            try:
                sc_dict = json.loads(gr["scores_json"])
            except Exception:
                sc_dict = {}
        att_dict = {}
        if gr["attendance_json"]:
            try:
                att_dict = json.loads(gr["attendance_json"])
            except Exception:
                att_dict = {}
        grades_by_sid[sid] = {
            "full_name": gr["full_name"] or "",
            "scores": sc_dict,
            "attendance": att_dict,
            "final_grade": str(gr["final_grade"] or "").strip(),
        }

    # Build final student list
    student_items = []
    if roster_rows:
        base_list = [
            {"student_no": idx, "student_id": str(r["student_id"]).strip(), "full_name": r["full_name"]}
            for idx, r in enumerate(roster_rows, start=1)
        ]
    else:
        base_list = [
            {"student_no": idx, "student_id": str(gr["student_id"]).strip(), "full_name": gr["full_name"] or ""}
            for idx, gr in enumerate(grade_rows, start=1)
        ]

    for item in base_list:
        idx = item["student_no"]
        sid = item["student_id"]
        g_info = grades_by_sid.get(sid, {})
        sc = g_info.get("scores") or {}
        att = g_info.get("attendance") or {}
        ex_sc = excel_student_scores.get(idx, {})

        # Resolve attendance percentage
        att_pct = 100.0
        if att.get("percentage") is not None:
            try:
                att_pct = float(att["percentage"])
            except Exception:
                att_pct = 100.0
        elif att.get("present_count") is not None:
            try:
                p_cnt = float(att.get("present_count") or 0)
                a_cnt = float(att.get("absent_count") or 0)
                l_cnt = float(att.get("leave_count") or 0)
                tot_att = p_cnt + a_cnt + l_cnt
                if tot_att > 0:
                    att_pct = round((p_cnt / tot_att) * 100.0, 1)
            except Exception:
                pass
        elif idx in excel_att_pct_by_no:
            att_pct = excel_att_pct_by_no[idx]

        raw_units = sc.get("units") if "units" in sc else ex_sc.get("units")
        units: List[Optional[float | int]] = []
        for i in range(8):
            val = raw_units[i] if isinstance(raw_units, list) and i < len(raw_units) else None
            units.append(_to_num(val))

        # Support SGS PDF before_midterm / after_midterm if units wasn't populated
        if all(u is None for u in units):
            bm = _to_num(sc.get("before_midterm"))
            am = _to_num(sc.get("after_midterm"))
            if bm is not None or am is not None:
                units[0] = bm
                units[1] = am
            elif sc.get("formative_total") is not None:
                units[0] = _to_num(sc.get("formative_total"))

        midterm = _to_num(sc.get("midterm") if "midterm" in sc else ex_sc.get("midterm"))
        central_exam = _to_num(sc.get("central_exam") if "central_exam" in sc else ex_sc.get("central_exam"))
        final_exam = _to_num(sc.get("final") if "final" in sc else ex_sc.get("final"))

        # Legacy imports kept the remark only as the grade (or only in the file's column S). An
        # attendance-driven มส. is not a teacher's remark: it comes back as auto_remark and follows the attendance.
        auto_driven = "no_exam_right" in att
        file_remark = str(ex_sc.get("remark") or "").strip()
        if auto_driven and file_remark == "มส":
            file_remark = ""
        remark = str(sc.get("remark") or file_remark or "").strip()
        saved_grade = g_info.get("final_grade") or ""
        if not remark and saved_grade in ("ร", "มส", "มผ", "ผ", "ขส") and not (auto_driven and saved_grade == "มส"):
            remark = saved_grade
        auto_remark = "มส" if auto_driven and att.get("no_exam_right") else ""

        formative_total = round(sum(float(u) for u in units if u is not None), 2)
        if formative_total.is_integer():
            formative_total = int(formative_total)

        between_term_total = round(float(formative_total) + float(midterm or 0), 2)
        if between_term_total.is_integer():
            between_term_total = int(between_term_total)

        final_total = round(float(central_exam or 0) + float(final_exam or 0), 2)
        if final_total.is_integer():
            final_total = int(final_total)

        total_score = round(float(between_term_total) + float(final_total), 2)
        if total_score.is_integer():
            total_score = int(total_score)

        calc_grade = compute_excel_grade(float(total_score), "")
        final_grade = compute_excel_grade(float(total_score), remark or auto_remark)

        student_items.append({
            "student_no": idx,
            "student_id": sid,
            "full_name": item["full_name"],
            "units": units,
            # ช่องที่เชื่อมแบบทดสอบย่อยแต่ครูพิมพ์คะแนนเอง (ระบบไม่เขียนทับ)
            "unit_manual": _unit_manual(sc.get("unit_manual"), units),
            "formative_total": formative_total,
            "midterm": midterm,
            "between_term_total": between_term_total,
            "central_exam": central_exam,
            "final": final_exam,
            "final_total": final_total,
            "total_score": total_score,
            "remark": remark,
            "auto_remark": auto_remark,
            "calculated_grade": calc_grade,
            "final_grade": final_grade,
            "attendance_pct": att_pct,
        })

    # Compute Row 9 summary formulas
    u_max_list = [_to_num(x) for x in (score_config.get("unit_max") or [30, 30, None, None, None, None, None, None])]
    while len(u_max_list) < 8:
        u_max_list.append(None)
    u_max_list = u_max_list[:8]

    mid_max = _to_num(score_config.get("midterm_max"))
    cen_max = _to_num(score_config.get("central_exam_max"))
    sch_max = _to_num(score_config.get("school_exam_max"))

    formative_max = sum(float(x) for x in u_max_list if x is not None)
    between_max = formative_max + float(mid_max or 0)
    final_max = float(cen_max or 0) + float(sch_max or 0)
    total_max = between_max + final_max

    return {
        "status": "success",
        "course": {
            "course_code": c_code,
            "course_name": c_name,
            "term": t_str,
            "year": y_str,
            "class_level": level,
            "teacher": course_dict.get("teacher") or "",
            "credits": course_dict.get("credits") or 1.0,
            "score_ratio": score_ratio,
        },
        "score_config": {
            "unit_max": u_max_list,
            "formative_max": int(formative_max) if formative_max.is_integer() else formative_max,
            "midterm_max": mid_max,
            "between_term_max": int(between_max) if between_max.is_integer() else between_max,
            "central_exam_max": cen_max,
            "school_exam_max": sch_max,
            "final_max": int(final_max) if final_max.is_integer() else final_max,
            "total_max": int(total_max) if total_max.is_integer() else total_max,
        },
        # ตัวชี้วัด typed for slots 1-8 (ปพ.5 sheet 4, C6:J6); edited through /api/v1/courses/pp5-labels only
        "indicator_labels": pp5_labels.get_labels(c_code, t_str, y_str, db_path=db_path)["indicators"],
        "students": student_items,
    }


def save_course_scores_sheet(
    course_code: str,
    term: str,
    year: str,
    score_config: Dict[str, Any],
    students: List[Dict[str, Any]],
    score_ratio: Optional[str] = None,
    db_path: str = DB_PATH
) -> Dict[str, Any]:
    """
    Save updated Sheet (4) รวมคะแนน max_scores config and student scores/remarks
    into SQLite (courses & grades_history) and sync directly into the course's
    PorPor 5 Excel file in outputs/ (preserving all Excel formulas).
    """
    import json
    from excel_mapper import find_course_matching_file, safe_set_cell, safe_set_cell_addr, save_workbook_atomic

    c_code = str(course_code).strip()
    t_str = str(term).strip()
    y_str = str(year).strip()

    raw_u_max = score_config.get("unit_max") or []
    u_max_list = [_to_num(raw_u_max[i]) if i < len(raw_u_max) else None for i in range(8)]
    mid_max = _to_num(score_config.get("midterm_max"))
    cen_max = _to_num(score_config.get("central_exam_max"))
    sch_max = _to_num(score_config.get("school_exam_max"))

    clean_cfg = {
        "unit_max": u_max_list,
        "midterm_max": mid_max,
        "central_exam_max": cen_max,
        "school_exam_max": sch_max,
    }

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    _ensure_score_config_column(conn)
    c = conn.cursor()

    c.execute(
        "SELECT * FROM courses WHERE course_code = ? AND term = ? AND year = ?;",
        (c_code, t_str, y_str)
    )
    course_row = c.fetchone()
    if not course_row:
        conn.close()
        return {"status": "error", "message": f"ไม่พบรายวิชา {c_code} ({t_str}/{y_str})"}

    course_dict = dict(course_row)
    effective_ratio = str(score_ratio or course_dict.get("score_ratio") or "80:20").strip()

    c.execute(
        """
        UPDATE courses
        SET score_config_json = ?, score_ratio = ?
        WHERE course_code = ? AND term = ? AND year = ?;
        """,
        (json.dumps(clean_cfg, ensure_ascii=False), effective_ratio, c_code, t_str, y_str)
    )

    # Save each student's scores and final_grade into grades_history
    processed_students = []
    for idx, st in enumerate(students, start=1):
        sid = str(st.get("student_id") or "").strip()
        fname = str(st.get("full_name") or "").strip()
        if not sid:
            continue

        raw_units = st.get("units") or []
        units = [_to_num(raw_units[i]) if i < len(raw_units) else None for i in range(8)]
        midterm = _to_num(st.get("midterm"))
        central_exam = _to_num(st.get("central_exam"))
        final_exam = _to_num(st.get("final"))
        remark = str(st.get("remark") or "").strip()

        formative_total = round(sum(float(u) for u in units if u is not None), 2)
        if formative_total.is_integer():
            formative_total = int(formative_total)

        between_term_total = round(float(formative_total) + float(midterm or 0), 2)
        if between_term_total.is_integer():
            between_term_total = int(between_term_total)

        final_total = round(float(central_exam or 0) + float(final_exam or 0), 2)
        if final_total.is_integer():
            final_total = int(final_total)

        total_score = round(float(between_term_total) + float(final_total), 2)
        if total_score.is_integer():
            total_score = int(total_score)

        c.execute(
            "INSERT OR IGNORE INTO students (student_id, full_name) VALUES (?, ?);",
            (sid, fname)
        )

        # Check existing grades_history row to preserve attendance_json and attributes_json
        c.execute(
            "SELECT scores_json, attendance_json, attributes_json FROM grades_history WHERE student_id = ? AND course_code = ? AND term = ? AND year = ?;",
            (sid, c_code, t_str, y_str)
        )
        existing_g = c.fetchone()
        att_json = existing_g["attendance_json"] if existing_g and existing_g["attendance_json"] else "{}"
        attr_json = existing_g["attributes_json"] if existing_g and existing_g["attributes_json"] else "{}"
        try:
            att_now = json.loads(att_json)
        except Exception:
            att_now = {}
        # The teacher's remark wins; otherwise มส. follows the attendance (column S and the grade)
        effective = effective_remark(remark, att_now if isinstance(att_now, dict) else {})
        final_grade = compute_excel_grade(float(total_score), effective)

        scores_payload = {
            "units": units,
            # quiz-linked cells the teacher typed over: quizzes.apply_scores leaves them alone (an empty cell is automatic again)
            "unit_manual": _unit_manual(st.get("unit_manual"), units),
            "formative_total": formative_total,
            "midterm": midterm,
            "between_term_total": between_term_total,
            "central_exam": central_exam,
            "final": final_exam,
            "final_total": final_total,
            "total_score": total_score,
            "remark": remark,
        }

        c.execute(
            """
            INSERT INTO grades_history (
                student_id, course_code, term, year,
                scores_json, final_grade, attendance_json, attributes_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(student_id, course_code, term, year) DO UPDATE SET
                scores_json = excluded.scores_json,
                final_grade = excluded.final_grade;
            """,
            (
                sid, c_code, t_str, y_str,
                json.dumps(scores_payload, ensure_ascii=False),
                final_grade,
                att_json,
                attr_json
            )
        )

        processed_students.append({
            "student_no": idx,
            "student_id": sid,
            "full_name": fname,
            "scores": scores_payload,
            "grade": final_grade,
            "effective_remark": effective,
        })

    conn.commit()
    conn.close()

    # Sync directly into the Excel file in outputs/
    excel_path = find_course_matching_file(OUTPUT_DIR, c_code, term=t_str, year=y_str, ext=".xlsx")
    if not excel_path or not excel_path.exists():
        course_dict["score_ratio"] = effective_ratio
        gen_path = generate_single_course_porpor5(course_dict, db_path=db_path)
        if gen_path:
            excel_path = Path(gen_path)

    if excel_path and excel_path.exists():
        try:
            wb = openpyxl.load_workbook(str(excel_path))
            # Update (1) ปกปพ. lookup table score_ratio if present
            if "(1) ปกปพ." in wb.sheetnames:
                ws_cover = wb["(1) ปกปพ."]
                for r_idx in range(5, 131):
                    if ws_cover.cell(r_idx, 23).value == c_code:
                        ws_cover.cell(r_idx, 26).value = effective_ratio
                        break

            # Ensure student names are in (2) เวลาเรียน1 so B{r} formula in (4) รวมคะแนน resolves
            if "(2) เวลาเรียน1" in wb.sheetnames:
                ws_att1 = wb["(2) เวลาเรียน1"]
                for st in processed_students:
                    idx = st["student_no"]
                    r_att = 8 + idx
                    if not ws_att1.cell(r_att, 3).value:
                        ws_att1.cell(r_att, 1).value = idx
                        ws_att1.cell(r_att, 2).value = st["student_id"]
                        ws_att1.cell(r_att, 3).value = st["full_name"]

            if "(4) รวมคะแนน" in wb.sheetnames:
                ws_scores = wb["(4) รวมคะแนน"]
                safe_set_cell_addr(ws_scores, "C2", course_dict.get("course_name") or "")
                safe_set_cell_addr(ws_scores, "M2", c_code)
                safe_set_cell_addr(ws_scores, "E3", effective_ratio)
                safe_set_cell_addr(ws_scores, "M3", course_dict.get("class_level") or "")

                # Row 9 max scores + formulas
                for u_idx in range(8):
                    safe_set_cell(ws_scores, 9, 3 + u_idx, u_max_list[u_idx])
                safe_set_cell(ws_scores, 9, 11, "=SUM(C9:J9)")
                safe_set_cell(ws_scores, 9, 12, mid_max)
                safe_set_cell(ws_scores, 9, 13, "=K9+L9")
                safe_set_cell(ws_scores, 9, 14, cen_max)
                safe_set_cell(ws_scores, 9, 15, sch_max)
                safe_set_cell(ws_scores, 9, 16, "=O9+N9")
                safe_set_cell(ws_scores, 9, 17, "=P9+M9")

                # Student rows (Rows 10+)
                for st in processed_students:
                    idx = st["student_no"]
                    r = 9 + idx
                    sc = st["scores"]
                    ws_scores.cell(row=r, column=1).value = idx
                    ws_scores.cell(row=r, column=2).value = f'=IF(\'(2) เวลาเรียน1\'!C{8 + idx}="","",\'(2) เวลาเรียน1\'!C{8 + idx})'

                    for u_idx in range(8):
                        ws_scores.cell(row=r, column=3 + u_idx).value = sc["units"][u_idx]

                    ws_scores.cell(row=r, column=11).value = f'=IF(B{r}="","",SUM(C{r}:J{r}))'
                    ws_scores.cell(row=r, column=12).value = sc["midterm"]
                    ws_scores.cell(row=r, column=13).value = f'=IF(B{r}="","",K{r}+L{r})'
                    ws_scores.cell(row=r, column=14).value = sc["central_exam"]
                    ws_scores.cell(row=r, column=15).value = sc["final"]
                    ws_scores.cell(row=r, column=16).value = f'=IF(B{r}="","",N{r}+O{r})'
                    ws_scores.cell(row=r, column=17).value = f'=IF(B{r}="","",M{r}+P{r})'
                    ws_scores.cell(row=r, column=19).value = st["effective_remark"] or None
                    ws_scores.cell(row=r, column=18).value = (
                        f'=IF(B{r}="","",(IF(S{r}="",(IF(Q{r}>=80,4,IF(Q{r}>=75,3.5,IF(Q{r}>=70,3,IF(Q{r}>=65,2.5,IF(Q{r}>=60,2,IF(Q{r}>=55,1.5,IF(Q{r}>=50,1,0)))))))),S{r})))'
                    )

            save_workbook_atomic(wb, excel_path)

            # Remove cached PDF so next PDF view/download re-renders from the updated Excel
            pdf_match = find_course_matching_file(OUTPUT_DIR, c_code, term=t_str, year=y_str, ext=".pdf")
            if pdf_match and pdf_match.exists():
                try:
                    pdf_match.unlink()
                except Exception:
                    pass
        except Exception as e:
            print(f"[ERROR] Failed updating Excel scores for {c_code}: {e}")

    return {
        "status": "success",
        "message": f"บันทึกคะแนนผลการเรียนรู้และอัปเดตไฟล์ ปพ.5 วิชา {c_code} เรียบร้อยแล้ว ({len(processed_students)} คน)",
        "excel_file": str(excel_path.name) if excel_path else None,
        "updated_students": len(processed_students),
    }

