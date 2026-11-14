"""
SGS PDF Parser Module
Extracts Course Header, Student Roster, Scores, Attendance, and Attributes
from SGS (Secondary Grading System) PDF reports with Thai Unicode & PUA font normalization.
"""

import os
import re
import json
import unicodedata
from typing import Dict, Any, List, Optional, Tuple
from pathlib import Path

# Ensure Windows Application Control (WDAC) compatibility for charset_normalizer
os.environ["CHARSET_NORMALIZER_USE_MYPYC"] = "0"

# Fix Windows console UTF-8 output encoding
import sys
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

import pdfplumber

# Repairs tone marks / vowels in PDFs generated with a broken /ToUnicode map (no-op for healthy PDFs)
try:
    import thai_font_fix
    thai_font_fix.install()
except Exception:  # pragma: no cover - parser still works for healthy PDFs
    thai_font_fix = None


def normalize_thai_text(text: Optional[str]) -> str:
    """Standardize Thai Unicode sequences, PUA font glyphs, reversed text, and normalize spacing."""
    if not text:
        return ""
    normalized = unicodedata.normalize("NFC", str(text))
    normalized = normalized.replace("\u0e4d\u0e32", "\u0e33")  # sara am fix
    
    # Common PUA mappings found in SGS PDFs
    pua_map = {
        "\uf701": "\u0e31",
        "\uf702": "\u0e35",
        "\uf703": "\u0e35",
        "\uf704": "\u0e36",
        "\uf705": "\u0e37",
        "\uf706": "\u0e38",
        "\uf707": "\u0e39",
        "\uf70a": "\u0e48",
        "\uf70b": "\u0e49",
        "\uf70c": "\u0e4a",
        "\uf70d": "\u0e4b",
        "\uf70e": "\u0e4c",
        "\uf710": "\u0e48",
        "\uf711": "\u0e49",
        "\uf712": "\u0e4a",
        "\uf713": "\u0e4b",
        "\uf714": "\u0e4c",
    }
    for k, v in pua_map.items():
        normalized = normalized.replace(k, v)

    # Normalize known reversed glyph patterns from PDF font encoding
    reversed_patterns = {
        "ะลยอ้รนยีรเาม": "ร้อยละมาเรียน",
        "ะลยอรนยีรเาม": "ร้อยละมาเรียน",
        "นยีรเาม": "มาเรียน",
        "ดาข": "ขาด",
        "าล": "ลา",
        "นิมเะรปรากลผ": "ผลการประเมิน",
        "นิมเะรป": "ประเมิน",
        "ช้อ": "ข้อ",
    }
    for rev_k, rev_v in reversed_patterns.items():
        normalized = normalized.replace(rev_k, rev_v)

    return " ".join(normalized.strip().split())


def clean_number(val: Any) -> Optional[float]:
    """Parse numeric values (int/float) safely, returning None for non-numeric/empty cells."""
    if val is None:
        return None
    val_str = str(val).strip().replace(",", "")
    if re.search(r"^-?\d+(\.\d+)?$", val_str):
        num = float(val_str)
        return int(num) if num.is_integer() else num
    return None


def extract_header_from_text(text: str) -> Dict[str, str]:
    """Extract course metadata from SGS PDF page text using Thai regex patterns."""
    text = normalize_thai_text(text)
    header = {
        "course_code": "",
        "course_name": "",
        "class_level": "",
        "semester": "",
        "academic_year": "",
        "teacher": "",
        "school_name": ""
    }

    # School Name
    school_match = re.search(r"โรงเรียน\s*([^\n\r]+?)(?=\s*(?:ตำบล|สังกัด|ชั้น|$))", text)
    if school_match:
        header["school_name"] = normalize_thai_text(school_match.group(1))

    # Course Code (e.g. รหัสวิชา ง21101 or รหัส ง21101)
    code_match = re.search(r"(?:รหัสวิชา|รหัส)\s*[:\s]?\s*([ก-ฮA-Za-z0-9]+)", text)
    if code_match:
        header["course_code"] = code_match.group(1).strip()

    # Course Name (e.g. รายวิชา การงานอาชีพ 1)
    name_match = re.search(
        r"(?:รายวิชา|ชื่อวิชา)\s*[:\s]?\s*([^\n\r]+?)(?=\s*(?:รหัส|ชั้น|ระดับ|กลุ่มสาระ|ภาคเรียน|ปีการศึกษา|ครู|$))",
        text
    )
    if name_match:
        header["course_name"] = normalize_thai_text(name_match.group(1))

    # Class / Level (e.g. ชั้น ม.1/1 or มัธยมศึกษาปีที่ 1)
    class_match = re.search(
        r"(?:ชั้น|ระดับชั้น)\s*[:\s]?\s*([^\n\r]+?)(?=\s*(?:ห้อง|ภาคเรียน|ปีการศึกษา|ครูผู้สอน|กลุ่มสาระ|$))",
        text
    )
    if class_match:
        header["class_level"] = normalize_thai_text(class_match.group(1))

    # Semester & Academic Year (e.g. ภาคเรียนที่ 1 ปีการศึกษา 2568)
    sem_year_match = re.search(r"ภาคเรียนที่\s*([0-9])\s*(?:ปีการศึกษา|\/)\s*([0-9]{2,4})", text)
    if sem_year_match:
        header["semester"] = sem_year_match.group(1).strip()
        year = sem_year_match.group(2).strip()
        header["academic_year"] = f"25{year}" if len(year) == 2 else year
    else:
        sem_match = re.search(r"ภาคเรียนที่\s*([0-9])", text)
        if sem_match:
            header["semester"] = sem_match.group(1).strip()
        year_match = re.search(r"ปีการศึกษา\s*([0-9]{2,4})", text)
        if year_match:
            year = year_match.group(1).strip()
            header["academic_year"] = f"25{year}" if len(year) == 2 else year

    # Teacher Name (supports inline or signature block 'ลงชื่อ ครูผู้สอน ( ... )')
    teacher_sig_match = re.search(
        r"ลงชื่อ\s*ครูผู[้]สอน\s*\(\s*([^)]+)\s*\)",
        text
    )
    if teacher_sig_match:
        header["teacher"] = normalize_thai_text(teacher_sig_match.group(1))
    else:
        teacher_match = re.search(
            r"(?:ครูผู้สอน|ครูผู[้]สอน|อาจารย์ผู้สอน|ผู้สอน)\s*[:\s]?\s*([^\n\r]+?)(?=\s*(?:โรงเรียน|กลุ่มสาระ|ชั้น|ครูที่ปรึกษา|$))",
            text
        )
        if teacher_match:
            header["teacher"] = normalize_thai_text(teacher_match.group(1))

    return header


def split_thai_name(full_name: str) -> Dict[str, str]:
    """Extract prefix/title, first name, and last name from Thai full name."""
    titles = ["เด็กชาย", "เด็กหญิง", "ด.ช.", "ด.ญ.", "นาย", "นางสาว", "นาง", "น.ส."]
    clean_name = normalize_thai_text(full_name)
    prefix = ""
    name_without_prefix = clean_name

    for t in titles:
        if clean_name.startswith(t):
            prefix = t
            name_without_prefix = clean_name[len(t):].strip()
            break

    parts = name_without_prefix.split(maxsplit=1)
    first_name = parts[0] if parts else ""
    last_name = parts[1] if len(parts) > 1 else ""

    return {
        "title": prefix,
        "first_name": first_name,
        "last_name": last_name,
        "full_name": clean_name
    }


def identify_table_type(header_rows: List[List[str]]) -> str:
    """Identify whether a table is Attendance, Scores, or Attributes."""
    full_header_text = ""
    for r in header_rows:
        for c in r:
            if c:
                full_header_text += " " + normalize_thai_text(str(c))
    
    clean = full_header_text.replace(" ", "")
    if "คุณลักษณะ" in clean or "อ่านคิดวิเคราะห์" in clean:
        return "attributes"
    elif "ตัวชี้วัด" in clean or "กลางภาค" in clean or "ปลายภาค" in clean or "ระหว่างภาค" in clean:
        return "scores"
    elif "เวลาเรียน" in clean or "มาเรียน" in clean or "ร้อยละ" in clean or "ชั่วโมงที่" in clean:
        return "attendance"
    return "generic"


def identify_columns(header_rows: List[List[str]], table_type: str = "generic") -> Dict[str, Any]:
    """Dynamically map table column positions accurately by table type."""
    num_cols = max(len(r) for r in header_rows) if header_rows else 0
    merged_headers = [""] * num_cols

    for row in header_rows:
        for idx, cell in enumerate(row):
            if cell and idx < num_cols:
                merged_headers[idx] += " " + normalize_thai_text(str(cell))

    merged_headers = [h.strip() for h in merged_headers]

    col_map = {
        "table_type": table_type,
        "no": 0,
        "student_id": -1,
        "name": 1,
        "formative_scores": [],
        "formative_total": -1,
        "midterm": -1,
        "midterm_sum": -1,
        "final_central": -1,
        "final_school": -1,
        "final_sum": -1,
        "total_score": -1,
        "grade": -1,
        "attendance_hours": -1,
        "absence_hours": -1,
        "leave_hours": -1,
        "attendance_pct": -1,
        "desirable_items": [],
        "desirable_summary": -1,
        "reading_items": [],
        "reading_summary": -1,
    }

    # Standard column locations
    for idx, col in enumerate(merged_headers):
        clean_col = col.replace(" ", "")

        if re.search(r"^(เลขที่|ที่|ลำดับ)$", clean_col):
            col_map["no"] = idx
        elif re.search(r"(?:รหัส|เลข).*(?:ตัว|นักเรียน)", clean_col):
            col_map["student_id"] = idx
        elif re.search(r"ชื่อ", clean_col) and col_map["name"] in (-1, 1):
            col_map["name"] = idx

    # Table Type Specific Mapping
    if table_type == "scores":
        for idx, col in enumerate(merged_headers):
            clean_col = col.replace(" ", "")

            # Formative subtotal (ระหว่างภาค / รายข้อ)
            if re.search(r"(ระหว่างภาค|รายข้อ)", clean_col) and not re.search(r"ปลายภาค", clean_col):
                col_map["formative_total"] = idx
            # Midterm (กลางภาค)
            elif re.search(r"กลางภาค", clean_col):
                col_map["midterm"] = idx
            # Central Exam (ข้อสอบกลาง)
            elif re.search(r"ข้อสอบกลาง", clean_col):
                col_map["final_central"] = idx
            # School Final Exam (ข้อสอบรร. / ข้อสอบโรงเรียน)
            elif re.search(r"(ข้อสอบรร|ข้อสอบโรงเรียน)", clean_col):
                col_map["final_school"] = idx
            # Total 100 / Grand total (ทั้งหมด / รวม100)
            elif re.search(r"(ทั้งหมด|ทั้ง\s*หมด|รวม100)", clean_col):
                col_map["total_score"] = idx
            # Grade (ผลการประเมิน / เกรด / ระดับผลการเรียน)
            elif re.search(r"(ผลการประเมิน|ระดับผลการเรียน|เกรด)", clean_col):
                col_map["grade"] = idx

        name_col = col_map["name"] if col_map["name"] != -1 else 1
        end_formative = col_map["formative_total"] if col_map["formative_total"] != -1 else (col_map["midterm"] if col_map["midterm"] != -1 else 10)
        col_map["formative_scores"] = list(range(name_col + 1, end_formative))

        if col_map["final_school"] == -1 and col_map["final_central"] != -1:
            col_map["final_school"] = col_map["final_central"] + 1

    elif table_type == "attributes":
        col_map["desirable_items"] = list(range(2, 10))
        col_map["desirable_summary"] = 10
        col_map["reading_items"] = list(range(11, 16))
        col_map["reading_summary"] = 16

    elif table_type == "attendance":
        for idx, col in enumerate(merged_headers):
            clean_col = col.replace(" ", "")
            if "ร้อยละ" in clean_col or "%" in clean_col:
                col_map["attendance_pct"] = idx
            elif "มาเรียน" in clean_col and "ร้อยละ" not in clean_col:
                col_map["attendance_hours"] = idx
            elif "ขาด" in clean_col:
                col_map["absence_hours"] = idx
            elif "ลา" in clean_col:
                col_map["leave_hours"] = idx

        if col_map["attendance_pct"] == -1 and num_cols >= 52:
            col_map["attendance_pct"] = 51
        if col_map["attendance_hours"] == -1 and num_cols >= 49:
            col_map["attendance_hours"] = 48

    return col_map


def parse_student_row(row: List[str], col_map: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Convert an extracted table row into a structured Student record."""
    clean_cells = [normalize_thai_text(str(c)) if c is not None else "" for c in row]

    student_no_raw = clean_cells[col_map["no"]] if 0 <= col_map["no"] < len(clean_cells) else ""
    student_id_raw = clean_cells[col_map["student_id"]] if 0 <= col_map["student_id"] < len(clean_cells) else ""
    name_raw = clean_cells[col_map["name"]] if 0 <= col_map["name"] < len(clean_cells) else ""

    id_clean = re.sub(r"\D", "", student_id_raw)
    
    # Extract student number if present
    no_num = None
    nums_in_no = re.findall(r"\d+", student_no_raw)
    if nums_in_no:
        no_num = int(nums_in_no[0])

    name_clean = normalize_thai_text(name_raw)

    # Validate that this is a real student row
    if not name_clean and not id_clean:
        return None

    # Skip rows that are table headers, notes, scale legends, or footnotes
    invalid_keywords = [
        "เลขประจำตัว", "รหัสนักเรียน", "ชื่อ", "คะแนน", "ชั่วโมง", "หมายเหตุ",
        "ระดับผลการเรียน", "ความหมาย", "ช่วงคะแนน", "คำชี้แจง", "สามารถคัดสรร",
        "ดีเยี่ยม", "ปานกลาง", "ผ่านเกณฑ์", "ต่ำกว่าเกณฑ์", "2=ดี", "1=ผ่าน", "3=ดีเยี่ยม"
    ]
    if any(k in name_clean for k in invalid_keywords):
        return None

    # Require minimum valid name length
    if len(name_clean) < 4 and not id_clean:
        return None

    name_info = split_thai_name(name_clean)
    table_type = col_map.get("table_type", "generic")

    student_record = {
        "student_no": no_num,
        "student_id": id_clean if id_clean else student_id_raw,
        "title": name_info["title"],
        "first_name": name_info["first_name"],
        "last_name": name_info["last_name"],
        "full_name": name_info["full_name"],
        "scores": {
            "units": [],
            "formative_total": None,
            "midterm": None,
            "final": None,
            "total_score": None
        },
        "grade": "",
        "attendance_percentage": None,
        "attendance_hours": None,
        "attributes": {
            "desirable_characteristics": None,
            "desirable_items": [],
            "reading_analytical_thinking": None,
            "reading_items": []
        }
    }

    if table_type == "scores":
        formative_scores = []
        for f_idx in col_map.get("formative_scores", []):
            if f_idx < len(clean_cells):
                s_val = clean_number(clean_cells[f_idx])
                if s_val is not None:
                    formative_scores.append(s_val)

        formative_total = clean_number(clean_cells[col_map["formative_total"]]) if 0 <= col_map["formative_total"] < len(clean_cells) else None
        midterm = clean_number(clean_cells[col_map["midterm"]]) if 0 <= col_map["midterm"] < len(clean_cells) else None
        
        final_val = None
        if 0 <= col_map["final_school"] < len(clean_cells):
            final_val = clean_number(clean_cells[col_map["final_school"]])
        if final_val is None and 0 <= col_map["final_central"] < len(clean_cells):
            final_val = clean_number(clean_cells[col_map["final_central"]])

        total_score = clean_number(clean_cells[col_map["total_score"]]) if 0 <= col_map["total_score"] < len(clean_cells) else None
        grade = clean_cells[col_map["grade"]] if 0 <= col_map["grade"] < len(clean_cells) else ""

        student_record["scores"] = {
            "units": formative_scores,
            "formative_total": formative_total,
            "midterm": midterm,
            "final": final_val,
            "total_score": total_score
        }
        student_record["grade"] = grade

    elif table_type == "attributes":
        desirable_items = []
        for d_idx in col_map.get("desirable_items", []):
            if d_idx < len(clean_cells):
                d_val = clean_number(clean_cells[d_idx])
                if d_val is not None:
                    desirable_items.append(int(d_val))

        desirable_summary = clean_number(clean_cells[col_map["desirable_summary"]]) if 0 <= col_map["desirable_summary"] < len(clean_cells) else None

        reading_items = []
        for r_idx in col_map.get("reading_items", []):
            if r_idx < len(clean_cells):
                r_val = clean_number(clean_cells[r_idx])
                if r_val is not None:
                    reading_items.append(int(r_val))

        reading_summary = clean_number(clean_cells[col_map["reading_summary"]]) if 0 <= col_map["reading_summary"] < len(clean_cells) else None

        student_record["attributes"] = {
            "desirable_characteristics": int(desirable_summary) if desirable_summary is not None else None,
            "desirable_items": desirable_items,
            "reading_analytical_thinking": int(reading_summary) if reading_summary is not None else None,
            "reading_items": reading_items
        }

    elif table_type == "attendance":
        att_pct = clean_number(clean_cells[col_map["attendance_pct"]]) if 0 <= col_map["attendance_pct"] < len(clean_cells) else None
        att_hrs = clean_number(clean_cells[col_map["attendance_hours"]]) if 0 <= col_map["attendance_hours"] < len(clean_cells) else None
        student_record["attendance_percentage"] = att_pct
        student_record["attendance_hours"] = att_hrs

    return student_record


def merge_student_record(existing: Dict[str, Any], incoming: Dict[str, Any]) -> None:
    """Safely merge incoming student data into an existing record without overwriting valid data with empty values."""
    # Merge Student No (prefer valid number <= 50)
    if incoming.get("student_no") is not None:
        if existing.get("student_no") is None or (isinstance(existing.get("student_no"), int) and existing.get("student_no") > 50):
            existing["student_no"] = incoming["student_no"]

    # Merge ID
    if incoming.get("student_id") and not existing.get("student_id"):
        existing["student_id"] = incoming["student_id"]

    # Merge Name
    if incoming.get("full_name") and not existing.get("full_name"):
        existing["title"] = incoming["title"]
        existing["first_name"] = incoming["first_name"]
        existing["last_name"] = incoming["last_name"]
        existing["full_name"] = incoming["full_name"]

    # Merge Scores
    in_scores = incoming.get("scores", {})
    if in_scores.get("units"):
        existing["scores"]["units"] = in_scores["units"]
    if in_scores.get("formative_total") is not None:
        existing["scores"]["formative_total"] = in_scores["formative_total"]
    if in_scores.get("midterm") is not None:
        existing["scores"]["midterm"] = in_scores["midterm"]
    if in_scores.get("final") is not None:
        existing["scores"]["final"] = in_scores["final"]
    if in_scores.get("total_score") is not None:
        existing["scores"]["total_score"] = in_scores["total_score"]

    # Merge Grade
    if incoming.get("grade"):
        existing["grade"] = incoming["grade"]

    # Merge Attendance
    if incoming.get("attendance_percentage") is not None:
        existing["attendance_percentage"] = incoming["attendance_percentage"]
    if incoming.get("attendance_hours") is not None:
        existing["attendance_hours"] = incoming["attendance_hours"]

    # Merge Attributes
    in_attr = incoming.get("attributes", {})
    if in_attr.get("desirable_characteristics") is not None:
        existing["attributes"]["desirable_characteristics"] = in_attr["desirable_characteristics"]
    if in_attr.get("desirable_items"):
        existing["attributes"]["desirable_items"] = in_attr["desirable_items"]
    if in_attr.get("reading_analytical_thinking") is not None:
        existing["attributes"]["reading_analytical_thinking"] = in_attr["reading_analytical_thinking"]
    if in_attr.get("reading_items"):
        existing["attributes"]["reading_items"] = in_attr["reading_items"]


TITLE_MAP = {
    "ด.ช.": "เด็กชาย", "ด.ญ.": "เด็กหญิง", "น.ส.": "นางสาว",
    "เด็กชาย": "เด็กชาย", "เด็กหญิง": "เด็กหญิง", "นางสาว": "นางสาว",
    "นาย": "นาย", "นาง": "นาง",
}
_TITLE_RE = r"(?:ด\.ช\.|ด\.ญ\.|น\.ส\.|เด็กชาย|เด็กหญิง|นางสาว|นาย|นาง)"
_ROSTER_ROW_RE = re.compile(rf"^\d+\s+\d{{4,6}}\s+{_TITLE_RE}")
_DEC2_RE = re.compile(r"^\d+\.\d{2}$")
_GRADES = {"4", "3.5", "3", "2.5", "2", "1.5", "1", "0", "ร", "มส", "ผ", "มผ", "มก"}


def _num(tok: str):
    try:
        f = float(tok)
        return int(f) if f.is_integer() else f
    except (TypeError, ValueError):
        return None


def parse_roster_header(text: str) -> Dict[str, str]:
    """Header of the roster print format, e.g.
    'วิชา ค22102 คณิตศาสตร์ 4 นก.1.5 ปีการศึกษา 2568 ภาคเรียนที่ 2 ระดับชั้น ม.2 กลุ่มที่ 1'."""
    header = {"course_code": "", "course_name": "", "credits": "", "class_level": "",
              "semester": "", "academic_year": "", "teacher": "", "school_name": ""}
    lines = [normalize_thai_text(line) for line in text.split("\n") if line.strip()]
    for line in lines:
        if line.startswith("วิชา") and ("ปีการศึกษา" in line or "นก." in line):
            m = re.search(r"วิชา\s+([ก-ฮ]\d{4,6})\s+(.+?)\s+นก\.?\s*([\d.\-]+)?\s*ปีการศึกษา\s*(\d{4})\s*ภาคเรียนที่\s*(\d)\s*ระดับชั้น\s*(\S+)", line)
            if m:
                raw_cr = (m.group(3) or "").strip()
                if raw_cr.startswith("."):
                    raw_cr = "0" + raw_cr
                raw_cr = raw_cr.rstrip(".")
                header.update(course_code=m.group(1), course_name=normalize_thai_text(m.group(2)),
                              credits=raw_cr, academic_year=m.group(4),
                              semester=m.group(5), class_level=m.group(6).strip(","))
            else:
                m2 = re.search(r"วิชา\s+([ก-ฮ]\d{4,6})\s+(.+?)(?:\s+นก|\s+ปีการศึกษา|$)", line)
                if m2:
                    header.update(course_code=m2.group(1), course_name=normalize_thai_text(m2.group(2)))
                y = re.search(r"ปีการศึกษา\s*(\d{4})", line)
                s = re.search(r"ภาคเรียนที่\s*(\d)", line)
                c = re.search(r"ระดับชั้น\s*(\S+)", line)
                if y: header["academic_year"] = y.group(1)
                if s: header["semester"] = s.group(1)
                if c: header["class_level"] = c.group(1).strip(",")
        elif "ครูผู้สอน" in line:
            m_teacher = re.search(r"ครูผู้สอน\s+((?:นาย|นางสาว|นาง|ดร\.|ว่าที่\s*ร\.ต\.)\s*[^\s\d]+(?:\s+[^\s\d]+)?)", line)
            if m_teacher:
                header["teacher"] = m_teacher.group(1).strip()
            else:
                t = re.search(r"ครูผู้สอน\s+([^\d\n]+)", line)
                if t:
                    clean = re.split(r"\s+(?:เลข|ประจำตัว|ก่อน|กลางภาค|ปลาย|ผลการ|ห้อง|ชื่อ)\b", t.group(1))[0].strip()
                    header["teacher"] = clean
        elif "โรงเรียน" in line and not header["school_name"]:
            sc = re.search(r"โรงเรียน\s*(\S+)", line)
            if sc:
                header["school_name"] = sc.group(1)
    return header


def parse_roster_row(line: str, classroom: str) -> Optional[Dict[str, Any]]:
    """One student line:
    Graded: '<room#> <id> <title+first> <last...> <no> <scores...> <total> <pct> <grade> <attr x17> <attendance%>'
    Activity: '<room#> <id> <title+first> <last...> <no> <grade: ผ/มผ> <attendance%>'
    """
    tok = line.split()
    if len(tok) < 5 or not tok[1].isdigit():
        return None
    i = 2
    while i < len(tok) and not tok[i].isdigit():
        i += 1
    if i >= len(tok):
        return None
    name_tokens = tok[2:i]
    try:
        student_no = int(tok[i])
    except ValueError:
        return None
    rest = tok[i + 1:]

    first_tok = name_tokens[0]
    m = re.match(rf"^({_TITLE_RE})(.*)$", first_tok)
    title_raw, first = (m.group(1), m.group(2)) if m else ("", first_tok)
    title = TITLE_MAP.get(title_raw, title_raw)
    last = normalize_thai_text(" ".join(name_tokens[1:]))
    first = normalize_thai_text(first)

    # Activity course row (ผ / มผ)
    if rest and rest[0] in {"ผ", "มผ", "ผ.", "มผ."}:
        grade = rest[0].replace(".", "")
        attendance = _num(rest[1]) if len(rest) > 1 else None
        scores: Dict[str, Any] = {
            "components": [],
            "total_score": None,
            "percent": None,
            "units": [],
            "formative_total": None,
        }
        attributes = {
            "desirable_characteristics": None,
            "desirable_items": [],
            "reading_analytical_thinking": None,
            "reading_items": [],
            "raw": [],
        }
        return {
            "student_no": student_no,
            "student_id": tok[1],
            "classroom": classroom,
            "title": title,
            "first_name": first,
            "last_name": last,
            "full_name": f"{title}{first} {last}".strip(),
            "scores": scores,
            "grade": grade,
            "attendance_percentage": attendance,
            "attendance_hours": None,
            "attributes": attributes,
        }

    # Graded course row:
    # total / percent are the first adjacent pair written with 2 decimals (e.g. 63.00 63.00)
    j = next((k for k in range(len(rest) - 1) if _DEC2_RE.match(rest[k]) and _DEC2_RE.match(rest[k + 1])), None)
    if j is None or j + 2 >= len(rest):
        return None
    components = [_num(x) for x in rest[:j]]
    total, pct = _num(rest[j]), _num(rest[j + 1])
    grade = rest[j + 2]
    tail = rest[j + 3:]
    attendance = _num(tail[-1]) if tail else None
    attrs = [_num(x) for x in tail[:-1]]

    scores = {"components": components, "total_score": total, "percent": pct}
    if len(components) == 4:
        before, mid, after, fin = components
        scores.update(before_midterm=before, midterm=mid, after_midterm=after, final=fin,
                      units=[before, after], formative_total=(before or 0) + (after or 0))
    elif len(components) == 3:
        before, mid, fin = components
        scores.update(before_midterm=before, midterm=mid, final=fin, units=[before], formative_total=before)
    else:
        scores.update(units=components)

    desirable_items = attrs[:10] if len(attrs) >= 17 else []
    reading_items = attrs[11:16] if len(attrs) >= 17 else []
    attributes = {
        "desirable_characteristics": attrs[10] if len(attrs) >= 17 else None,
        "desirable_items": desirable_items,
        "reading_analytical_thinking": attrs[16] if len(attrs) >= 17 else None,
        "reading_items": reading_items,
        "raw": attrs,
    }
    return {
        "student_no": student_no,
        "student_id": tok[1],
        "classroom": classroom,
        "title": title,
        "first_name": first,
        "last_name": last,
        "full_name": f"{title}{first} {last}".strip(),
        "scores": scores,
        "grade": grade,
        "attendance_percentage": attendance,
        "attendance_hours": None,
        "attributes": attributes,
    }


def parse_roster_pdf(pdf_path: str) -> Optional[Dict[str, Any]]:
    """Parse the 'roster' SGS print format. Returns None if the PDF is not in that format."""
    file_path = Path(pdf_path)
    students: List[Dict[str, Any]] = []
    header: Dict[str, str] = {}
    warnings: List[str] = []
    declared_total: Optional[int] = None
    classroom = ""

    with pdfplumber.open(file_path) as pdf:
        for page_idx, page in enumerate(pdf.pages):
            text = page.extract_text() or ""
            if page_idx == 0:
                if "พิมพ์วันที่" not in text and "ระดับชั้น" not in text:
                    return None
                header = parse_roster_header(text)
            for raw in text.split("\n"):
                line = normalize_thai_text(raw)
                room = re.search(r"ชั้น/ห้อง\s+(\S+)", line)
                if room:
                    classroom = room.group(1)
                    continue
                tot = re.search(r"รวมจำนวนนักเรียน\s+(\d+)\s+คน", line)
                if tot and declared_total is None:
                    declared_total = int(tot.group(1))
                if _ROSTER_ROW_RE.match(line):
                    st = parse_roster_row(line, classroom)
                    if st:
                        students.append(st)
                    else:
                        warnings.append(f"แถวที่อ่านไม่ได้: {line[:60]}")

    if not students:
        return None
    # Ensure sequential student numbering (1..N) for the subject roster
    for idx, st in enumerate(students, start=1):
        st["student_no"] = idx

    if declared_total is not None and declared_total != len(students):
        warnings.append(f"จำนวนนักเรียนในไฟล์ {declared_total} คน แต่อ่านได้ {len(students)} คน")
    if thai_font_fix is not None and thai_font_fix.UNKNOWN_GLYPHS:
        warnings.append(f"พบสระ/วรรณยุกต์ที่ยังไม่รู้จัก {len(thai_font_fix.UNKNOWN_GLYPHS)} แบบ "
                        f"(รัน: python thai_font_fix.py --scan <pdf>)")

    grade_dist: Dict[str, int] = {}
    for st in students:
        grade_dist[st["grade"]] = grade_dist.get(st["grade"], 0) + 1
    return {
        "file_name": file_path.name,
        "format": "roster",
        "header": header,
        "students": students,
        "summary": {"total_students": len(students), "declared_total": declared_total,
                    "grade_distribution": grade_dist},
        "warnings": warnings,
    }


def parse_sgs_pdf(pdf_path: str) -> Dict[str, Any]:
    """
    Parse an SGS PDF report file and return structured course and student data.

    :param pdf_path: Path to the target SGS PDF.
    :return: Dictionary containing header metadata, student records, and class summary.
    """
    file_path = Path(pdf_path)
    if not file_path.exists():
        raise FileNotFoundError(f"PDF file not found: {file_path}")

    roster = parse_roster_pdf(str(file_path))
    if roster is not None:
        return roster

    structured_data: Dict[str, Any] = {
        "file_name": file_path.name,
        "header": {},
        "students": [],
        "summary": {
            "total_students": 0,
            "grade_distribution": {}
        }
    }

    students_dict: Dict[str, Dict[str, Any]] = {}

    table_settings = {
        "vertical_strategy": "lines",
        "horizontal_strategy": "lines",
        "snap_tolerance": 4,
        "join_tolerance": 4,
    }

    with pdfplumber.open(file_path) as pdf:
        for page_idx, page in enumerate(pdf.pages):
            page_text = page.extract_text() or ""

            # Extract header from page 1 or fill missing header fields
            if page_idx == 0 or not structured_data["header"].get("course_code"):
                extracted_header = extract_header_from_text(page_text)
                for k, v in extracted_header.items():
                    if v and not structured_data["header"].get(k):
                        structured_data["header"][k] = v

            # Only process student roster pages (pages 2 to 5)
            if page_idx == 0 or page_idx >= 5:
                continue

            tables = page.extract_tables(table_settings=table_settings)
            if not tables:
                tables = page.extract_tables()

            for table in tables:
                if not table or len(table) < 2:
                    continue

                # Find first student row where student 1 begins
                first_st_idx = None
                for r_idx, r in enumerate(table):
                    c0 = normalize_thai_text(str(r[0] or ""))
                    c1 = normalize_thai_text(str(r[1] or ""))
                    c2 = normalize_thai_text(str(r[2] or "")) if len(r) > 2 else ""
                    if c0 == "1" and any(title in (c1 + c2) for title in ["เด็ก", "นาย", "นาง", "ด.ช.", "ด.ญ.", "น.ส."]):
                        first_st_idx = r_idx
                        break

                if first_st_idx is None:
                    # Fallback keyword scan
                    header_row_indices = []
                    for r_idx, row in enumerate(table[:5]):
                        row_str = " ".join([str(c or "") for c in row])
                        if any(k in row_str for k in ["เลขที่", "รหัส", "ชื่อ", "คะแนน", "เกรด", "ผลการเรียน", "คุณลักษณะ", "อ่านคิด", "เวลาเรียน"]):
                            header_row_indices.append(r_idx)
                    if not header_row_indices:
                        continue
                    first_st_idx = max(header_row_indices) + 1
                    h_rows = [table[i] for i in header_row_indices]
                else:
                    h_rows = table[:first_st_idx]

                table_type = identify_table_type(h_rows)
                col_map = identify_columns(h_rows, table_type)
                data_rows = table[first_st_idx:]

                for row in data_rows:
                    parsed_student = parse_student_row(row, col_map)
                    if not parsed_student:
                        continue

                    # Key primarily by normalized full_name, fallback to student_id or student_no
                    name_key = normalize_thai_text(parsed_student["full_name"])
                    if name_key:
                        key = f"name_{name_key}"
                    elif parsed_student["student_id"]:
                        key = f"id_{parsed_student['student_id']}"
                    elif parsed_student["student_no"] is not None:
                        key = f"no_{parsed_student['student_no']}"
                    else:
                        continue

                    if key not in students_dict:
                        students_dict[key] = parsed_student
                    else:
                        merge_student_record(students_dict[key], parsed_student)

    # Sort students by student_no
    sorted_students = sorted(
        students_dict.values(),
        key=lambda s: s["student_no"] if s["student_no"] is not None else 999
    )

    # Assign sequential student numbers if missing
    for idx, st in enumerate(sorted_students, start=1):
        if st["student_no"] is None or st["student_no"] > len(sorted_students):
            st["student_no"] = idx

    # Calculate summary metrics
    grade_dist: Dict[str, int] = {}
    for st in sorted_students:
        g = st.get("grade", "")
        if g:
            grade_dist[g] = grade_dist.get(g, 0) + 1

    structured_data["students"] = sorted_students
    structured_data["summary"]["total_students"] = len(sorted_students)
    structured_data["summary"]["grade_distribution"] = grade_dist

    return structured_data


if __name__ == "__main__":
    import argparse
    import sys

    parser = argparse.ArgumentParser(description="Parse SGS School Grading PDF into structured JSON.")
    parser.add_argument("pdf_path", type=str, help="Path to SGS PDF file")
    parser.add_argument("-o", "--output", type=str, default=None, help="Output JSON file path (optional)")
    parser.add_argument("--indent", type=int, default=2, help="JSON indentation level")

    args = parser.parse_args()

    try:
        result = parse_sgs_pdf(args.pdf_path)
        json_output = json.dumps(result, ensure_ascii=False, indent=args.indent)

        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(json_output)
            print(f"[SUCCESS] Extracted {result['summary']['total_students']} students -> {args.output}")
        else:
            print(json_output)
    except Exception as e:
        print(f"[ERROR] {str(e)}", file=sys.stderr)
        sys.exit(1)
