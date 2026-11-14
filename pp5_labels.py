"""
Header labels the teacher types into a course's ปพ.5 workbook:

- indicators: the ตัวชี้วัด / ผลการเรียนรู้ of score slots 1-8 (sheet (4) รวมคะแนน, C6:J6, merged down to row 8)
- attributes: the 8 คุณลักษณะอันพึงประสงค์ items (sheet (5) คุณลักษณะ, C5:J5)
- reading: the 5 อ่าน คิด วิเคราะห์ และเขียน items (sheet (5) คุณลักษณะ, L5:P5)

The columns are narrow, so the text is written vertically (rotated 90°, reading upwards). The columns never get
wider; when a label is longer than the header, the header row grows taller instead (the sheet is printed fit-to-page,
so the whole page scales down a little). Stored per course in courses.pp5_labels_json and applied every time the
workbook is generated (excel_mapper.map_sgs_to_excel) or the labels are edited (write_to_file).
"""
from __future__ import annotations

import json
import sqlite3
import unicodedata
from pathlib import Path
from typing import Any, Dict, List, Optional

DB_PATH = "school_archive.db"
GROUPS: Dict[str, int] = {"indicators": 8, "attributes": 8, "reading": 5}
MAX_LEN = 80  # characters per label; 80 Thai characters at 14 pt is ~41 cm tall, already more than any header needs

# คุณลักษณะอันพึงประสงค์ 8 ประการ (หลักสูตรแกนกลางการศึกษาขั้นพื้นฐาน พ.ศ. 2551), offered as a one-click fill
STANDARD_ATTRIBUTES = [
    "1. รักชาติ ศาสน์ กษัตริย์",
    "2. ซื่อสัตย์สุจริต",
    "3. มีวินัย",
    "4. ใฝ่เรียนรู้",
    "5. อยู่อย่างพอเพียง",
    "6. มุ่งมั่นในการทำงาน",
    "7. รักความเป็นไทย",
    "8. มีจิตสาธารณะ",
]

SHEET_SCORES = "(4) รวมคะแนน"
SHEET_ATTR = "(5) คุณลักษณะ"
# where each group lives: sheet, row, first column
CELLS = {
    "indicators": (SHEET_SCORES, 6, 3),
    "attributes": (SHEET_ATTR, 5, 3),
    "reading": (SHEET_ATTR, 5, 12),
}
# template row heights (pt) the labels sit in: sheet 4 rows 6-8 are one merged block (row 7 is the one that grows)
SCORES_ROWS_FIXED = 21.75 + 21.75  # rows 6 and 8 (template default height)
SCORES_ROW7_DEFAULT = 23.25
ATTR_ROW5_DEFAULT = 43.5
EXCEL_MAX_ROW_PT = 409.0
PAD_PT = 6.0  # space left at both ends of a vertical label


def empty() -> Dict[str, List[str]]:
    return {g: [""] * n for g, n in GROUPS.items()}


def clean_label(value: Any) -> str:
    """One line, trimmed, at most MAX_LEN characters."""
    text = " ".join(str(value or "").split())
    return text[:MAX_LEN]


def normalize(raw: Any) -> Dict[str, List[str]]:
    out = empty()
    if isinstance(raw, dict):
        for g, n in GROUPS.items():
            vals = raw.get(g)
            if isinstance(vals, list):
                out[g] = [clean_label(vals[i]) if i < len(vals) else "" for i in range(n)]
    return out


def _ensure_column(conn: sqlite3.Connection) -> None:
    cols = [r[1] for r in conn.execute("PRAGMA table_info(courses);")]
    if cols and "pp5_labels_json" not in cols:
        conn.execute("ALTER TABLE courses ADD COLUMN pp5_labels_json TEXT;")
        conn.commit()


def get_labels(course_code: str, term: str, year: str, db_path: str = DB_PATH) -> Dict[str, List[str]]:
    conn = sqlite3.connect(db_path)
    try:
        _ensure_column(conn)
        row = conn.execute(
            "SELECT pp5_labels_json FROM courses WHERE course_code = ? AND term = ? AND year = ?;",
            (str(course_code).strip(), str(term).strip(), str(year).strip()),
        ).fetchone()
    finally:
        conn.close()
    if not row or not row[0]:
        return empty()
    try:
        return normalize(json.loads(row[0]))
    except (ValueError, TypeError):
        return empty()


def save_labels(course_code: str, term: str, year: str, changes: Dict[str, Any],
                db_path: str = DB_PATH) -> Optional[Dict[str, List[str]]]:
    """Replace the groups present in `changes` (others are kept). None when the course does not exist."""
    current = get_labels(course_code, term, year, db_path=db_path)
    incoming = normalize(changes)
    for g in GROUPS:
        if isinstance((changes or {}).get(g), list):
            current[g] = incoming[g]
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.execute(
            "UPDATE courses SET pp5_labels_json = ? WHERE course_code = ? AND term = ? AND year = ?;",
            (json.dumps(current, ensure_ascii=False), str(course_code).strip(), str(term).strip(), str(year).strip()),
        )
        conn.commit()
        if cur.rowcount == 0:
            return None
    finally:
        conn.close()
    return current


def text_height_pt(text: str, font_pt: float) -> float:
    """
    Length of a one-line label in points, i.e. the height it needs when rotated. TH SarabunPSK averages about
    0.34 em per character that takes space (Thai vowel/tone marks above or below take none); 0.38 leaves room
    for bold and for LibreOffice's slightly wider rendering.
    """
    n = sum(1 for ch in text if unicodedata.category(ch) != "Mn")
    return n * 0.38 * font_pt


def _font_pt(cell, default: float = 14.0) -> float:
    try:
        return float(cell.font.sz or default)
    except (AttributeError, TypeError, ValueError):
        return default


def _set_text(cell, value: Optional[str], rotated: bool) -> None:
    from copy import copy
    cell.value = value
    al = copy(cell.alignment)
    al.textRotation = 90 if rotated else 0
    al.horizontal = "center"
    al.vertical = "center"
    al.wrap_text = False
    cell.alignment = al


def apply_to_workbook(wb, labels: Dict[str, List[str]]) -> None:
    """Write the labels into an open ปพ.5 workbook (no save). Empty labels give the template's look back."""
    labels = normalize(labels)

    if SHEET_SCORES in wb.sheetnames:
        ws = wb[SHEET_SCORES]
        sheet, row, col0 = CELLS["indicators"]
        need = 0.0
        for i, text in enumerate(labels["indicators"]):
            cell = ws.cell(row=row, column=col0 + i)
            _set_text(cell, text or None, rotated=True)  # the template already writes these cells vertically
            if text:
                need = max(need, text_height_pt(text, _font_pt(cell)) + PAD_PT)
        ws.row_dimensions[7].height = min(EXCEL_MAX_ROW_PT, max(SCORES_ROW7_DEFAULT, need - SCORES_ROWS_FIXED))

    if SHEET_ATTR in wb.sheetnames:
        ws = wb[SHEET_ATTR]
        need = 0.0
        for g in ("attributes", "reading"):
            _, row, col0 = CELLS[g]
            texts = labels[g]
            custom = any(texts)
            for i, text in enumerate(texts):
                cell = ws.cell(row=row, column=col0 + i)
                if custom:
                    shown = text or f"ข้อ {i + 1}"
                    _set_text(cell, shown, rotated=True)
                    need = max(need, text_height_pt(shown, _font_pt(cell)) + PAD_PT)
                else:
                    _set_text(cell, f"ข้อ {i + 1}", rotated=False)  # template look (it read "ช้อ 1" by mistake)
        ws.row_dimensions[5].height = min(EXCEL_MAX_ROW_PT, max(ATTR_ROW5_DEFAULT, need))


def apply_from_db(wb, course_code: str, term: str, year: str, db_path: str = DB_PATH) -> None:
    """Used while a workbook is generated; never lets a label problem stop the ปพ.5 file from being written."""
    try:
        if course_code and term and year:
            apply_to_workbook(wb, get_labels(course_code, term, year, db_path=db_path))
    except Exception as e:  # noqa: BLE001
        print(f"[WARN] ปพ.5 labels for {course_code} {term}/{year}: {e}")


def write_to_file(course_code: str, term: str, year: str, labels: Dict[str, List[str]],
                  output_dir: Optional[Path] = None) -> Optional[Path]:
    """Write the labels into the course's existing ปพ.5 file and drop its cached PDF. Returns the file, or None."""
    import openpyxl
    from excel_mapper import find_course_matching_file, save_workbook_atomic, workbook_lock

    root = Path(output_dir) if output_dir else Path("outputs").resolve()
    xl = find_course_matching_file(root, course_code, term=term, year=year, ext=".xlsx")
    if not xl or not xl.exists():
        return None
    with workbook_lock(xl):
        wb = openpyxl.load_workbook(str(xl))
        apply_to_workbook(wb, labels)
        save_workbook_atomic(wb, xl)
    pdf = find_course_matching_file(root, course_code, term=term, year=year, ext=".pdf")
    if pdf and pdf.exists():
        try:
            pdf.unlink()  # the next PDF view/download renders the new headers
        except OSError:
            pass
    return xl
