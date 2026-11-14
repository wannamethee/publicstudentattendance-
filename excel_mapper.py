"""
Phase 3: Excel Mapping & PDF Export (Blank Template + Dynamic Injection Workflow)
- Ingests parsed SGS data into a clean blank ปพ.5 template.
- Dynamically injects Course Header, Student Roster, Scores, Attendance, and Attributes.
- Preserves all built-in template formulas, styles, and print configurations.
- Configures clean print page fits (FitToPagesWide=1, A4 Portrait/Landscape as configured).
- Exports a single combined, print-ready PDF via native Windows Excel COM or headless LibreOffice.
"""

import os
import sys
import re
import json
import shutil
import subprocess
import threading
from pathlib import Path
from typing import Dict, Any, List, Optional, Union
from datetime import datetime, timedelta
import openpyxl

# Configure console encoding for Thai characters on Windows
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

# Import siblings for unified pipeline workflow
try:
    from sgs_parser import parse_sgs_pdf
except ImportError:
    parse_sgs_pdf = None

try:
    from database import (
        ingest_parsed_json,
        get_course_description,
        get_course_schedule,
        update_course_schedule,
        get_advisor_for_class,
        normalize_teacher_name,
        get_connection,
        resolve_signatories_for_course,
        get_school_signatories,
        get_app_setting
    )
except ImportError:
    ingest_parsed_json = None
    get_course_description = None
    get_course_schedule = None
    update_course_schedule = None
    get_advisor_for_class = None
    normalize_teacher_name = None
    get_connection = None
    resolve_signatories_for_course = None
    get_school_signatories = None
    get_app_setting = None


def clean_val(val: Any) -> Any:
    """Convert numeric string to float/int if possible, otherwise return trimmed string."""
    if val is None:
        return None
    val_str = str(val).strip()
    try:
        f = float(val_str)
        return int(f) if f.is_integer() else f
    except ValueError:
        return val_str


def get_effective_pp5_logo_path(db_path: str = "school_archive.db") -> Optional[str]:
    """
    Returns the file path of the logo that should be used for ปพ.5 documents.
    Order of precedence:
    1. Custom PP5 logo specified in app_settings (pp5_logo_path)
    2. School logo specified in app_settings (school_logo_path)
    3. Fallback file paths: uploads/pp5_logo.png, uploads/school_logo.png, school_logo.png
    """
    try:
        if get_app_setting is not None:
            custom_pp5 = get_app_setting("pp5_logo_path", "", db_path=db_path)
            if custom_pp5 and Path(custom_pp5).exists():
                return str(Path(custom_pp5))
    except Exception:
        pass

    # Check direct uploads/pp5_logo.* if exists (raster only)
    for ext in [".png", ".jpg", ".jpeg", ".webp"]:
        p = Path("uploads") / f"pp5_logo{ext}"
        if p.exists():
            return str(p)

    try:
        if get_app_setting is not None:
            school_logo = get_app_setting("school_logo_path", "", db_path=db_path)
            if school_logo and Path(school_logo).exists():
                sp = Path(school_logo)
                if sp.suffix.lower() != ".svg":
                    return str(sp)
    except Exception:
        pass

    # Fallback to standard raster files
    for candidate in ["uploads/school_logo.png", "school_logo.png"]:
        p = Path(candidate)
        if p.exists():
            return str(p)

    return None


def format_logo_for_excel_and_web(img_input: Any, target_aspect: float = 1.452066) -> Any:
    """
    Ensures the logo emblem is cropped to its true content bounds and padded
    symmetrically to the exact aspect ratio (1.452066) required by the Excel F1:H2 anchor box.
    This guarantees that the emblem displays with 100% natural, undistorted proportions
    in both Excel and PDF exports.
    """
    try:
        from PIL import Image
        import numpy as np
    except ImportError:
        return img_input

    if isinstance(img_input, (str, Path)):
        img = Image.open(str(img_input))
    else:
        img = img_input

    img = img.convert("RGBA")
    alpha = np.array(img.getchannel("A"))
    rgb = np.array(img.convert("RGB"))
    content_mask = (alpha > 10) & ~((rgb[:, :, 0] > 250) & (rgb[:, :, 1] > 250) & (rgb[:, :, 2] > 250))
    if not np.any(content_mask):
        content_mask = alpha > 10

    if np.any(content_mask):
        y_indices, x_indices = np.where(content_mask)
        bbox = (int(x_indices.min()), int(y_indices.min()), int(x_indices.max() + 1), int(y_indices.max() + 1))
        img = img.crop(bbox)

    w, h = img.size
    if w <= 0 or h <= 0:
        return img
    current_aspect = w / h

    if current_aspect < target_aspect:
        new_w = int(round(h * target_aspect))
        pad_left = (new_w - w) // 2
        canvas = Image.new("RGBA", (new_w, h), (255, 255, 255, 0))
        canvas.paste(img, (pad_left, 0), img)
    else:
        new_h = int(round(w / target_aspect))
        pad_top = (new_h - h) // 2
        canvas = Image.new("RGBA", (w, new_h), (255, 255, 255, 0))
        canvas.paste(img, (0, pad_top), img)

    target_h = 772
    target_w = int(round(target_h * target_aspect))
    return canvas.resize((target_w, target_h), Image.Resampling.LANCZOS)


def update_excel_logo_in_zip(excel_path: Path, image_data: bytes) -> bool:
    """
    Fast direct binary replacement of xl/media/image1.png in an existing Excel workbook.
    Takes ~5ms per file and 100% preserves formulas, drawing structure, and formatting.
    """
    import zipfile
    import tempfile
    try:
        temp_dir = tempfile.gettempdir()
        temp_zip = os.path.join(temp_dir, f"tz_{os.getpid()}_{excel_path.name}")
        replaced = False
        with zipfile.ZipFile(excel_path, "r") as zin:
            with zipfile.ZipFile(temp_zip, "w", compression=zipfile.ZIP_DEFLATED) as zout:
                for item in zin.infolist():
                    if item.filename == "xl/media/image1.png":
                        zout.writestr(item, image_data)
                        replaced = True
                    else:
                        zout.writestr(item, zin.read(item.filename))
        if replaced:
            os.replace(temp_zip, excel_path)
            return True
        else:
            if os.path.exists(temp_zip):
                os.remove(temp_zip)
            return False
    except Exception:
        return False


def inject_cover_sheet_logo(ws_cover, logo_path: Optional[str] = None, db_path: str = "school_archive.db") -> bool:
    """
    Injects the active School / PP5 emblem into sheet '(1) ปกปพ.'
    Replaces any existing image in ws_cover or anchors to F1.
    Maintains clean aspect ratio and positioning.
    """
    try:
        from openpyxl.drawing.image import Image as OpenpyxlImage
    except ImportError:
        return False

    effective_path = logo_path or get_effective_pp5_logo_path(db_path=db_path)
    if not effective_path or not Path(effective_path).exists():
        return False

    if Path(effective_path).suffix.lower() == ".svg":
        return False

    try:
        new_img = OpenpyxlImage(effective_path)
        orig_w, orig_h = new_img.width, new_img.height
        if orig_w <= 0 or orig_h <= 0:
            return False

        max_w, max_h = 240, 160
        scale = min(max_w / orig_w, max_h / orig_h, 1.0)
        new_img.width = max(1, int(orig_w * scale))
        new_img.height = max(1, int(orig_h * scale))

        if getattr(ws_cover, "_images", None) and len(ws_cover._images) > 0:
            new_img.anchor = ws_cover._images[0].anchor
            ws_cover._images[0] = new_img
        else:
            ws_cover.add_image(new_img, "F1")

        return True
    except Exception as e:
        print(f"[WARN] Failed to inject cover sheet logo: {e}")
        return False


def _sync_outputs_worker(effective_path: str, db_path: str):
    """Background worker to update cover logos in existing output workbooks and clear stale PDF caches."""
    import io
    image_bytes = None
    try:
        from PIL import Image
        img = Image.open(effective_path)
        formatted_img = format_logo_for_excel_and_web(img)
        buf = io.BytesIO()
        formatted_img.save(buf, format="PNG", optimize=True)
        image_bytes = buf.getvalue()
    except Exception:
        try:
            with open(effective_path, "rb") as f:
                image_bytes = f.read()
        except Exception:
            pass

    if not image_bytes:
        return

    # 1. Update template_ปพ5_blank.xlsx
    tpl = Path("template_ปพ5_blank.xlsx")
    if tpl.exists():
        update_excel_logo_in_zip(tpl, image_bytes)

    # 2. Update all existing output workbooks via fast zip replacement
    output_dirs = [Path("outputs"), Path("output")]
    for out_dir in output_dirs:
        if out_dir.exists():
            for xl_file in out_dir.glob("*.xlsx"):
                try:
                    if not update_excel_logo_in_zip(xl_file, image_bytes):
                        wb = openpyxl.load_workbook(xl_file)
                        if "(1) ปกปพ." in wb.sheetnames:
                            ws = wb["(1) ปกปพ."]
                            if inject_cover_sheet_logo(ws, logo_path=effective_path, db_path=db_path):
                                save_workbook_atomic(wb, xl_file)
                except Exception:
                    pass

    # 3. Clear PDF page cache so stale squashed page images are re-rendered crisply
    cache_dir = Path("data/pdf_page_cache")
    if cache_dir.exists():
        for item in cache_dir.iterdir():
            try:
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink()
            except Exception:
                pass


def sync_all_excel_logos(db_path: str = "school_archive.db", custom_logo_path: Optional[str] = None, run_async: bool = True) -> Dict[str, Any]:
    """
    Synchronizes the active school/PP5 logo into template_ปพ5_blank.xlsx immediately
    and updates existing generated Excel files in outputs/*.xlsx in the background.
    """
    effective_path = custom_logo_path or get_effective_pp5_logo_path(db_path=db_path)
    template_updated = False

    if not effective_path or not Path(effective_path).exists():
        return {"status": "skipped", "message": "No logo found to sync", "template_updated": False}

    # 1. Update blank template synchronously
    template_path = Path("template_ปพ5_blank.xlsx")
    if template_path.exists():
        try:
            from PIL import Image
            import io
            img = Image.open(effective_path)
            formatted_img = format_logo_for_excel_and_web(img)
            buf = io.BytesIO()
            formatted_img.save(buf, format="PNG", optimize=True)
            if update_excel_logo_in_zip(template_path, buf.getvalue()):
                template_updated = True
            else:
                wb = openpyxl.load_workbook(template_path)
                if "(1) ปกปพ." in wb.sheetnames:
                    ws = wb["(1) ปกปพ."]
                    if inject_cover_sheet_logo(ws, logo_path=effective_path, db_path=db_path):
                        save_workbook_atomic(wb, template_path)
                        template_updated = True
        except Exception as e:
            print(f"[WARN] Failed to update template logo: {e}")

    # 2. Update existing files in outputs/ (async thread by default so APIs return immediately)
    if run_async:
        t = threading.Thread(target=_sync_outputs_worker, args=(effective_path, db_path), daemon=True)
        t.start()
    else:
        _sync_outputs_worker(effective_path, db_path)

    return {
        "status": "success",
        "template_updated": template_updated,
        "effective_logo": effective_path,
        "background_sync_started": run_async
    }


def infer_course_metadata(course_code: str, course_name: str = "") -> Dict[str, str]:
    """Infer department (กลุ่มสาระการเรียนรู้), type (ประเภทวิชา), and score ratio from course code or master catalog."""
    if not course_code:
        return {"department": "-", "course_type": "พื้นฐาน", "score_ratio": "70 : 30"}

    try:
        from catalog_manager import lookup_catalog_course, decode_course_code
        cat = lookup_catalog_course(course_code)
        if cat:
            return {
                "department": "-" if str(course_code).startswith("ก") else (cat.get("department") or "-"),
                "course_type": cat.get("course_type") or "พื้นฐาน",
                "score_ratio": cat.get("score_ratio") or ("-" if str(course_code).startswith("ก") else "70 : 30"),
            }
        decoded = decode_course_code(course_code)
        prefix = decoded["subject_prefix"]
        return {
            "department": "-" if prefix == "ก" else decoded["department"],
            "course_type": decoded["course_type"],
            "score_ratio": "-" if prefix == "ก" else ("80 : 20" if prefix == "ง" and decoded["course_type"] == "พื้นฐาน" else "70 : 30"),
        }
    except Exception:
        pass

    prefix = course_code[0]
    dept_map = {
        "ค": "คณิตศาสตร์",
        "ว": "วิทยาศาสตร์และเทคโนโลยี",
        "ท": "ภาษาไทย",
        "ส": "สังคมศึกษา ศาสนา และวัฒนธรรม",
        "ง": "การงานอาชีพ",
        "ศ": "ศิลปะศึกษาและดนตรีนาฏศิลป์",
        "พ": "สุขศึกษาและพลศึกษา",
        "อ": "ภาษาต่างประเทศ (ภาษาอังกฤษ)",
        "จ": "ภาษาต่างประเทศ (ภาษาจีน)",
        "ญ": "ภาษาต่างประเทศ",
        "ฝ": "ภาษาต่างประเทศ",
        "ก": "-",
        "I": "การศึกษาค้นคว้าอิสระ (IS)",
    }
    department = dept_map.get(prefix, "-")

    if prefix == "ก":
        course_type = "กิจกรรม"
        score_ratio = "-"
    elif "เพิ่มเติม" in (course_name or "") or (len(course_code) >= 4 and course_code[3] == "2"):
        course_type = "เพิ่มเติม"
        score_ratio = "70 : 30"
    else:
        course_type = "พื้นฐาน"
        score_ratio = "80 : 20" if prefix == "ง" else "70 : 30"

    return {
        "department": department,
        "course_type": course_type,
        "score_ratio": score_ratio,
    }


def infer_class_level(course_code: str, class_level_hint: str = "") -> str:
    """Infer Thai class level (e.g. ม.1, ม.2, ..., ม.6) from hint, master catalog, or course code."""
    if class_level_hint and str(class_level_hint).strip() != "#N/A":
        m = re.search(r"ม\.?\s*([1-6](?:\/\d+)?)", str(class_level_hint))
        if m:
            return f"ม.{m.group(1)}"
        m_num = re.search(r"\b([1-6])\b", str(class_level_hint))
        if m_num:
            return f"ม.{m_num.group(1)}"
    if course_code:
        try:
            from catalog_manager import lookup_catalog_course, decode_course_code
            cat = lookup_catalog_course(course_code)
            if cat and cat.get("class_level"):
                return str(cat["class_level"]).strip()
            decoded = decode_course_code(course_code)
            if decoded.get("class_level"):
                return str(decoded["class_level"]).strip()
        except Exception:
            pass
        m = re.search(r"[ก-ฮa-zA-Z](\d)(\d)", course_code)
        if m:
            d1, d2 = m.group(1), m.group(2)
            if d1 == "2":
                return f"ม.{d2}" if d2 != "0" else "ม.2"
            elif d1 == "3":
                if d2 == "0":
                    return "ม.5"
                num = int(d2) + 3
                if 4 <= num <= 6:
                    return f"ม.{num}"
    return class_level_hint or ""


def stage_label(class_level: str) -> str:
    """ต้น = ม.1-ม.3, ปลาย = ม.4-ม.6 (ช่องถัดจากคำว่า ปพ.5 บนหน้าปก)
    กรณีสอนรวมหลายชั้น (เช่น ม.1, ม.6) ให้ใช้ระดับชั้นตัวแรกในการตัดสิน
    """
    m = re.search(r"([1-6])", str(class_level or ""))
    if not m:
        return ""
    return "ต้น" if int(m.group(1)) <= 3 else "ปลาย"


def format_and_fit_course_description(text: str) -> tuple[str, int]:
    """
    Format course description and calculate optimal font size
    so that it fits comfortably within sheet (6) ตัวชี้วัด on a single A4 page.
    """
    if not text:
        return "", 16

    # Normalize newlines
    normalized = text.replace("\r\n", "\n").replace("\r", "\n").strip()

    # Calculate estimated lines taking wrapping into account (~95 Thai chars per line at 16pt)
    raw_lines = normalized.split("\n")
    total_est_lines = 0
    wrap_limit = 95
    for line in raw_lines:
        line_len = len(line.strip())
        if line_len == 0:
            total_est_lines += 1
        else:
            total_est_lines += max(1, (line_len + wrap_limit - 1) // wrap_limit)

    # Dynamic font size selection to guarantee fitting on 1 A4 page (rows 3 to 32 = 30 rows)
    if total_est_lines <= 20:
        font_size = 16
    elif total_est_lines <= 26:
        font_size = 15
    elif total_est_lines <= 32:
        font_size = 14
    elif total_est_lines <= 38:
        font_size = 13
    elif total_est_lines <= 45:
        font_size = 12
    else:
        font_size = 11

    return normalized, font_size


def inject_course_description(ws: openpyxl.worksheet.worksheet.Worksheet, text: str) -> None:
    """Inject course description and indicators into sheet (6) ตัวชี้วัด with auto-fit formatting."""
    formatted_text, font_size = format_and_fit_course_description(text)
    
    cell = ws["A3"]
    cell.value = formatted_text
    cell.font = openpyxl.styles.Font(name="TH SarabunPSK", size=font_size, bold=False)
    cell.alignment = openpyxl.styles.Alignment(horizontal="left", vertical="top", wrap_text=True)

    # Ensure sheet setup strictly fits 1 page wide x 1 page tall in Excel and PDF
    ws.page_setup.orientation = "portrait"
    ws.page_setup.paperSize = 9  # A4
    ws.page_setup.fitToWidth = 1
    ws.page_setup.fitToHeight = 1
    ws.sheet_properties.pageSetUpPr.fitToPage = True


def safe_set_cell(ws: openpyxl.worksheet.worksheet.Worksheet, row: int, col: int, val: Any) -> None:
    """Set cell value safely, skipping MergedCell slaves to prevent AttributeError."""
    cell = ws.cell(row=row, column=col)
    if not isinstance(cell, openpyxl.cell.cell.MergedCell):
        cell.value = val


def safe_set_cell_addr(ws: openpyxl.worksheet.worksheet.Worksheet, addr: str, val: Any) -> None:
    """Set cell value safely by address (e.g. 'L9'), skipping MergedCell slaves to avoid errors."""
    try:
        cell = ws[addr]
        if not isinstance(cell, openpyxl.cell.cell.MergedCell):
            cell.value = val
    except Exception:
        pass


# Excel COM / LibreOffice exports must not run concurrently.
PDF_EXPORT_LOCK = threading.RLock()

_workbook_locks_guard = threading.Lock()
_workbook_locks: Dict[str, threading.RLock] = {}


def workbook_lock(path: Union[str, Path]) -> threading.RLock:
    """Per-file lock so concurrent API calls / background workers never interleave on one ปพ.5 file."""
    key = os.path.normcase(str(Path(path).resolve()))
    with _workbook_locks_guard:
        lock = _workbook_locks.get(key)
        if lock is None:
            lock = _workbook_locks[key] = threading.RLock()
        return lock


def save_workbook_atomic(wb: openpyxl.Workbook, path: Union[str, Path]) -> None:
    """
    Write to a temp file in the same folder, then atomically replace the target.
    Readers (preview, PDF export) therefore never see a half-written .xlsx, which is
    how the corrupted (Bad CRC-32) ปพ.5 files were produced.
    """
    target = Path(path)
    tmp = target.with_name(f".{target.stem}.{os.getpid()}.{threading.get_ident()}.tmp{target.suffix}")
    with workbook_lock(target):
        wb.save(str(tmp))
        last_err: Optional[Exception] = None
        for attempt in range(10):
            try:
                os.replace(tmp, target)
                return
            except PermissionError as e:  # target briefly opened by Excel COM / a reader on Windows
                last_err = e
                import time
                time.sleep(0.2 * (attempt + 1))
        try:
            tmp.unlink()
        except OSError:
            pass
        raise last_err  # type: ignore[misc]


def sanitize_blank_template(wb: openpyxl.Workbook, max_student_slots: int = 25) -> openpyxl.Workbook:
    """
    Ensure the workbook is a true BLANK template by clearing out previous
    course info, student IDs, names, scores, attendance marks, and attributes
    while strictly preserving all formula structures, formatting, and print settings.
    """
    # 1. Clear Header inputs in (1) ปกปพ.
    if "(1) ปกปพ." in wb.sheetnames:
        ws_cover = wb["(1) ปกปพ."]
        safe_set_cell(ws_cover, 9, 12, None)   # L9: Course Code
        safe_set_cell(ws_cover, 11, 5, None)   # E11: Teacher Name
        safe_set_cell(ws_cover, 12, 5, None)   # E12: Class Advisor 1
        safe_set_cell(ws_cover, 13, 5, None)   # E13: Class Advisor 2
        safe_set_cell(ws_cover, 26, 5, None)   # E26: Teacher Signature
        safe_set_cell(ws_cover, 7, 9, None)    # I7: Term / Semester
        safe_set_cell(ws_cover, 7, 12, None)   # L7: Academic Year

    # 2. Clear Student Roster and Attendance in (2) เวลาเรียน1 (Rows 9 to 33)
    if "(2) เวลาเรียน1" in wb.sheetnames:
        ws_att1 = wb["(2) เวลาเรียน1"]
        for r in range(9, 9 + max_student_slots):
            safe_set_cell(ws_att1, r, 2, None)  # Student ID
            safe_set_cell(ws_att1, r, 3, None)  # Full Name
            for c in range(4, min(ws_att1.max_column + 1, 59)):
                safe_set_cell(ws_att1, r, c, None)  # Period checkmarks

    # 3. Clear Attendance in (3) เวลาเรียน2 (Rows 9 to 33)
    if "(3) เวลาเรียน2" in wb.sheetnames:
        ws_att2 = wb["(3) เวลาเรียน2"]
        for r in range(9, 9 + max_student_slots):
            for c in range(4, 49):
                safe_set_cell(ws_att2, r, c, None)
            safe_set_cell(ws_att2, r, 49, None)  # Hours
            safe_set_cell(ws_att2, r, 50, None)  # Absence
            safe_set_cell(ws_att2, r, 51, None)  # Leave
            safe_set_cell(ws_att2, r, 52, None)  # Percentage

    # 4. Clear Scores in (4) รวมคะแนน (Rows 10 to 34, preserving formulas)
    if "(4) รวมคะแนน" in wb.sheetnames:
        ws_scores = wb["(4) รวมคะแนน"]
        for r in range(10, 10 + max_student_slots):
            for c in range(3, 11):
                safe_set_cell(ws_scores, r, c, None)  # Units C-J
            safe_set_cell(ws_scores, r, 12, None)     # Col L: Midterm
            safe_set_cell(ws_scores, r, 14, None)     # Col N: Central Exam
            safe_set_cell(ws_scores, r, 15, None)     # Col O: Final Exam
            safe_set_cell(ws_scores, r, 19, None)     # Col S: Non-numeric Override

    # 5. Clear Attributes in (5) คุณลักษณะ (Rows 7 to 31, preserving MODE formulas)
    if "(5) คุณลักษณะ" in wb.sheetnames:
        ws_attr = wb["(5) คุณลักษณะ"]
        for r in range(7, 7 + max_student_slots):
            for c in range(3, 11):
                safe_set_cell(ws_attr, r, c, None)    # 8 Items
            for c in range(12, 17):
                safe_set_cell(ws_attr, r, c, None)    # 5 Items

    # 6. Clear Indicators in (6) ตัวชี้วัด
    if "(6) ตัวชี้วัด" in wb.sheetnames:
        safe_set_cell(wb["(6) ตัวชี้วัด"], 3, 1, "กรอกคำอธิบายรายวิชา และ ตัวชี้วัด ที่ช่องนี้")

    return wb


def create_blank_template(
    source_template_path: str = "template_ปพ5_blank.xlsx",
    output_blank_path: str = "template_ปพ5_blank.xlsx"
) -> str:
    """Utility to generate a pristine reusable blank ปพ.5 template from any workbook."""
    wb = openpyxl.load_workbook(source_template_path)
    wb = sanitize_blank_template(wb)
    out_path = Path(output_blank_path).resolve()
    save_workbook_atomic(wb, out_path)
    return str(out_path)


def get_approval_date_str(term: Any, year: Any = None) -> str:
    """
    Format cover sheet approval date centered cleanly without overflowing cell borders:
    Term 1 -> (30 or last Friday)  /  ก.ย.  /  {academic_year}
    Term 2 -> (30 or last Friday)  /  มี.ค.  /  {academic_year + 1}

    Automatically checks whether 30 September and 30 March fall on a weekday (Mon-Fri).
    If falling on Saturday or Sunday, selects the last Friday of that month:
    - If Saturday (day 30) -> last Friday is day 29
    - If Sunday (day 30) -> last Friday is day 28
    """
    raw_term = str(term or "1").strip()
    term_str = "2" if "2" in raw_term else "1"
    month = "มี.ค." if term_str == "2" else "ก.ย."
    month_num = 3 if term_str == "2" else 9

    be_year = None
    if year:
        try:
            m = re.search(r"(25\d{2})", str(year))
            if m:
                be_year = int(m.group(1))
            else:
                y_int = int(str(year).strip())
                be_year = (2500 + y_int) if y_int < 100 else y_int
        except Exception:
            pass
    if not be_year:
        now = datetime.now()
        be_year = now.year + 543

    display_year = (be_year + 1) if term_str == "2" else be_year
    ce_year = display_year - 543

    try:
        base_dt = datetime(ce_year, month_num, 30)
        # weekday(): 0=Mon, 1=Tue, 2=Wed, 3=Thu, 4=Fri, 5=Sat, 6=Sun
        if base_dt.weekday() < 5:
            chosen_day = 30
        elif base_dt.weekday() == 5:
            chosen_day = 29  # Saturday -> previous Friday
        else:
            chosen_day = 28  # Sunday -> previous Friday
    except Exception:
        chosen_day = 30

    return f"{chosen_day}  /  {month}  /  {display_year}"


def find_course_matching_file(
    search_dir: Path,
    course_code: str,
    term: Optional[str] = None,
    year: Optional[str] = None,
    ext: str = ".xlsx"
) -> Optional[Path]:
    """
    Strictly and robustly finds the matching course Excel or PDF file.
    Matches regardless of token ordering (e.g. 'course_term_year' or 'ปพ.5-year-term-course').
    Prevents cross-year contamination (a 2568 file will never match a 2569 request).
    """
    if not search_dir.exists():
        return None

    clean_code = course_code.strip().lower()
    t_str = str(term).strip() if term else None
    y_str = str(year).strip() if year else None
    y_short = y_str[-2:] if y_str and len(y_str) >= 2 else None

    candidates = []
    for p in search_dir.iterdir():
        if p.is_dir() or p.name.startswith("~$") or "template" in p.name.lower() or "blank" in p.name.lower():
            continue
        if not p.name.lower().endswith(ext.lower()):
            continue

        name = p.name.lower()
        if clean_code not in name:
            continue

        # Year matching: must match requested year and NOT contain another year
        if y_str:
            has_year = (y_str in name) or (y_short and (f"{y_short}-" in name or f"{y_short}_" in name or f" {y_short} " in name))
            if not has_year:
                continue
            conflict = False
            for other_y in range(2550, 2580):
                if str(other_y) != y_str and str(other_y) in name:
                    conflict = True
                    break
            if conflict:
                continue

        # Term matching
        if t_str:
            term_patterns = [f"-{t_str}-", f"_{t_str}_", f"-{t_str}_", f"_{t_str}-", f" {t_str} ", f"-{t_str} ", f" {t_str}-", f"_{t_str}.", f"-{t_str}."]
            has_term = any(pat in name for pat in term_patterns) or bool(re.search(rf"[_\- ]{t_str}[_\- .]", name))
            if not has_term:
                continue

        score = 0
        if "_filled" in name and ext == ".xlsx":
            score += 10
        if "_print_ready" in name and ext == ".pdf":
            score += 10
        if y_str and y_str in name:
            score += 5
        candidates.append((score, p))

    if candidates:
        candidates.sort(key=lambda x: (x[0], x[1].stat().st_mtime), reverse=True)
        return candidates[0][1]

    # If no match and neither term nor year were requested, allow fallback
    if not term and not year:
        for p in search_dir.iterdir():
            if not p.is_dir() and not p.name.startswith("~$") and p.name.lower().endswith(ext.lower()):
                if clean_code in p.name.lower() and "blank" not in p.name.lower() and "template" not in p.name.lower():
                    return p

    return None


# 100 attendance columns across Sheet (2) and Sheet (3) (20 weeks x 5 days)
ALL_P1_COLS = list(range(4, 59))  # 55 cols in (2) เวลาเรียน1 (Weeks 1 to 11)
ALL_P2_COLS = list(range(4, 49))  # 45 cols in (3) เวลาเรียน2 (Weeks 12 to 20)
TOTAL_ATTENDANCE_PERIODS = 100

# Legacy 40-period column subsets (Day 1 & Day 2 of each of the 20 weeks)
P1_COLS = [4, 5, 9, 10, 14, 15, 19, 20, 24, 25, 29, 30, 34, 35, 39, 40, 44, 45, 49, 50, 54, 55]
P2_COLS = [4, 5, 9, 10, 14, 15, 19, 20, 24, 25, 29, 30, 34, 35, 39, 40, 44, 45]


def normalize_attendance_status_list(status_list: List[str], target_len: int = 100) -> List[str]:
    """
    Ensure status_list has target_len (100) items.
    If input has 40 items (legacy 2-days-per-week format), expand to 100 items
    placing the 2 days in Day 1 and Day 2 of each of the 20 weeks.
    """
    if not status_list:
        return [""] * target_len

    if len(status_list) == 40:
        expanded: List[str] = []
        for w in range(20):
            d1 = status_list[w * 2] if w * 2 < len(status_list) else ""
            d2 = status_list[w * 2 + 1] if w * 2 + 1 < len(status_list) else ""
            expanded.extend([d1, d2, "", "", ""])
        return expanded

    if len(status_list) < target_len:
        return list(status_list) + [""] * (target_len - len(status_list))
    return list(status_list[:target_len])


THAI_MONTHS_ABBR = [
    "", "ม.ค.", "ก.พ.", "มี.ค.", "เม.ย.", "พ.ค.", "มิ.ย.",
    "ก.ค.", "ส.ค.", "ก.ย.", "ต.ค.", "พ.ย.", "ธ.ค."
]


def calculate_schedule_dates(
    start_date: Optional[str | datetime] = None,
    term: Any = "1",
    year_be: Any = None
) -> List[Dict[str, Any]]:
    """
    Calculate 20 weeks (100 days, Mon-Fri, skipping Sat-Sun) starting from start_date.
    If start_date is not specified, uses a sensible default based on semester and academic year:
      - Term 1: Mid-May (Monday)
      - Term 2: Early November (Monday)
    Returns a list of 20 week objects, each containing:
      - week_num: 1..20
      - month_year: e.g. 'พ.ค. 68', 'มิ.ย. 68' (Thai month abbreviation + 2-digit BE year)
      - days: 5 day objects (Mon-Fri) with day_num, month, year_be, iso date string
    """
    if start_date:
        if isinstance(start_date, str):
            clean_s = start_date.strip()[:10]
            try:
                start_dt = datetime.strptime(clean_s, "%Y-%m-%d")
            except ValueError:
                try:
                    start_dt = datetime.strptime(clean_s, "%d/%m/%Y")
                except ValueError:
                    start_dt = datetime.now()
        else:
            start_dt = start_date
    else:
        now = datetime.now()
        try:
            be_y = int(year_be) if year_be else (now.year + 543)
        except Exception:
            be_y = now.year + 543
        ce_year = be_y - 543

        term_str = str(term or "1").strip()
        if term_str == "2":
            start_dt = datetime(ce_year, 11, 3)
        else:
            start_dt = datetime(ce_year, 5, 12)

    # Snap start_dt to Monday of that week
    monday = start_dt - timedelta(days=start_dt.weekday())

    weeks = []
    for w in range(20):
        w_mon = monday + timedelta(weeks=w)
        w_fri = w_mon + timedelta(days=4)
        m1_abbr = THAI_MONTHS_ABBR[w_mon.month]
        m2_abbr = THAI_MONTHS_ABBR[w_fri.month]
        y1_2d = (w_mon.year + 543) % 100
        y2_2d = (w_fri.year + 543) % 100
        if w_mon.month == w_fri.month and w_mon.year == w_fri.year:
            month_year_str = f"{m1_abbr} {y1_2d:02d}"
        else:
            month_year_str = f"{m1_abbr} {y1_2d:02d} - {m2_abbr} {y2_2d:02d}"

        days = []
        for d in range(5):
            d_dt = w_mon + timedelta(days=d)
            days.append({
                "day_num": d_dt.day,
                "month": d_dt.month,
                "year_be": d_dt.year + 543,
                "iso": d_dt.strftime("%Y-%m-%d"),
            })

        weeks.append({
            "week_num": w + 1,
            "month_year": month_year_str,
            "days": days,
        })
    return weeks


def _get_periods_for_day(schedule_dict: Optional[Any], day_idx: int) -> int:
    """Return period count for day_idx (0=Mon, 1=Tue, 2=Wed, 3=Thu, 4=Fri). Supports lists of schedule slots and dicts."""
    if not schedule_dict:
        return 1 if day_idx in (0, 1) else 0
    if isinstance(schedule_dict, list):
        count = 0
        for item in schedule_dict:
            if isinstance(item, dict):
                d_val = item.get("day")
                span = item.get("span", 1) or 1
                try:
                    if int(d_val) == (day_idx + 1):
                        count += int(span)
                except (ValueError, TypeError):
                    pass
        return count
    if isinstance(schedule_dict, dict):
        name_keys = ["mon", "tue", "wed", "thu", "fri"]
        num_str_keys = ["1", "2", "3", "4", "5"]
        num_keys = [1, 2, 3, 4, 5]
        zero_keys = [0, 1, 2, 3, 4]

        for k in (name_keys[day_idx], num_str_keys[day_idx], num_keys[day_idx], zero_keys[day_idx]):
            if k in schedule_dict:
                try:
                    return int(schedule_dict[k] or 0)
                except Exception:
                    pass
        for sub_key in ("slots", "schedule"):
            if isinstance(schedule_dict.get(sub_key), list):
                return _get_periods_for_day(schedule_dict[sub_key], day_idx)
    return 0


def inject_schedule_calendar_and_hours(
    ws_att1: Optional[openpyxl.worksheet.worksheet.Worksheet],
    ws_att2: Optional[openpyxl.worksheet.worksheet.Worksheet],
    weeks: List[Dict[str, Any]],
    schedule_dict: Optional[Dict[str, Any]] = None,
    slot_hours: Optional[List[int]] = None
) -> None:
    """
    Inject Month/Year (Row 6), Day numbers (Row 7), and Teaching Periods (Row 8)
    across all 20 weeks in Sheet (2) เวลาเรียน1 and Sheet (3) เวลาเรียน2.
    schedule_dict maps day keys ('mon', 'tue', etc. or '1', '2', etc.)
    to the number of teaching periods on that day.
    Holidays in schedule_dict['holidays'] will be locked (Row 8 set to None).
    Row 8 ("ชั่วโมงที่") numbers the teaching sessions 1, 2, 3 ... on every day the course meets (blank on
    holidays and days without a period). It is a session count, not hours: a double period still takes one
    number, so a 2-hour course ends at half its full hours (owner's choice, 6 Nov 2026). The hour totals that
    count for มา/ขาด/ลา come from slot_hours and are written elsewhere (N3 / AW8 and the summary columns).
    """
    if slot_hours is not None:
        session_num = 0
        for ws, week_range, base in ((ws_att1, range(min(11, len(weeks))), 0), (ws_att2, range(11, min(20, len(weeks))), 11)):
            for w in week_range:
                c_start = 4 + (w - base) * 5
                if ws:
                    safe_set_cell(ws, 6, c_start, weeks[w]["month_year"])
                for d in range(5):
                    if ws:
                        safe_set_cell(ws, 7, c_start + d, weeks[w]["days"][d]["day_num"])
                    if slot_hours[w * 5 + d]:
                        session_num += 1
                        if ws:
                            safe_set_cell(ws, 8, c_start + d, session_num)
                    else:
                        if ws:
                            safe_set_cell(ws, 8, c_start + d, None)
        return

    holidays = set()
    locked_counted = set()
    if schedule_dict and isinstance(schedule_dict, dict):
        raw_h = schedule_dict.get("holidays") or []
        try:
            holidays = {int(x) for x in raw_h}
        except Exception:
            holidays = set()
        raw_lc = schedule_dict.get("locked_counted") or []
        try:
            locked_counted = {int(x) for x in raw_lc}
        except Exception:
            locked_counted = set()

    session_num = 0
    for ws, week_range, base in ((ws_att1, range(min(11, len(weeks))), 0), (ws_att2, range(11, min(20, len(weeks))), 11)):
        for w in week_range:
            w_obj = weeks[w]
            c_start = 4 + (w - base) * 5
            if ws:
                safe_set_cell(ws, 6, c_start, w_obj["month_year"])
            for d in range(5):
                col = c_start + d
                slot_idx = w * 5 + d
                if ws:
                    safe_set_cell(ws, 7, col, w_obj["days"][d]["day_num"])
                if slot_idx in holidays:
                    if ws:
                        safe_set_cell(ws, 8, col, None)
                elif slot_idx in locked_counted:
                    session_num += 1
                    if ws:
                        safe_set_cell(ws, 8, col, session_num)
                else:
                    periods = _get_periods_for_day(schedule_dict, d)
                    if periods > 0:
                        session_num += 1
                        if ws:
                            safe_set_cell(ws, 8, col, session_num)
                    else:
                        if ws:
                            safe_set_cell(ws, 8, col, None)


def create_default_status_list(
    p_count: int,
    l_count: int,
    a_count: int,
    tot_hours: int = 40,
    schedule_dict: Optional[Dict[str, Any]] = None
) -> List[str]:
    """
    Generate 100 slots (20 weeks x 5 days) where teaching periods
    are placed on the scheduled teaching days (excluding holidays).
    """
    status_list = [""] * 100
    marks = (["/"] * p_count) + (["ล"] * l_count) + ([""] * a_count)

    holidays = set()
    if schedule_dict and isinstance(schedule_dict, dict):
        raw_h = schedule_dict.get("holidays") or []
        try:
            holidays = {int(x) for x in raw_h}
        except Exception:
            holidays = set()

    active_slots = []
    for w in range(20):
        for d in range(5):
            slot_idx = w * 5 + d
            if slot_idx not in holidays:
                periods_count = _get_periods_for_day(schedule_dict, d)
                if periods_count > 0:
                    active_slots.append(slot_idx)

    if not active_slots:
        for w in range(20):
            if (w * 5 + 0) not in holidays:
                active_slots.append(w * 5 + 0)
            if (w * 5 + 1) not in holidays:
                active_slots.append(w * 5 + 1)

    for i, slot_idx in enumerate(active_slots):
        if i < len(marks):
            status_list[slot_idx] = marks[i]
        else:
            status_list[slot_idx] = "/"
    return status_list



def clean_cover_school_name(school_name: Any) -> str:
    """Strips leading 'โรงเรียน' so that cover cell B5 gets only the school name without duplicate 'โรงเรียน'."""
    import school_profile
    if not school_name:
        return school_profile.short_name()
    clean = re.sub(r"^โรงเรียน\s*", "", str(school_name)).strip()
    return clean or school_profile.short_name()


def apply_school_address(ws_cover, db_path: str = "school_archive.db") -> None:
    """Cover sheet ตำบล / อำเภอ / จังหวัด / สังกัด from the school's settings (school_profile); empty values leave the cell."""
    import school_profile
    for addr, key, fmt in (("D5", "school_subdistrict", "ตำบล  {}"), ("H5", "school_district", "{}"),
                           ("L5", "school_province", "{}"), ("A6", "school_area_office", "สังกัด{}")):
        val = school_profile.get(key, db_path)
        if val:
            safe_set_cell_addr(ws_cover, addr, fmt.format(val))

def map_sgs_to_excel(
    json_input: str | Dict[str, Any],
    template_path: str = "template_ปพ5_blank.xlsx",
    output_excel_path: str = "68-1_ปพ5_filled.xlsx",
    course_description: Optional[str] = None,
    start_date: Optional[str] = None,
    schedule: Optional[Dict[str, Any]] = None
) -> str:
    """
    Strict Blank Template + Dynamic Injection Workflow:
    1. Loads the blank template (or auto-sanitizes if previously filled).
    2. Dynamically injects Header info (Course Code, Name, Teacher, Term, Year).
    3. Injects Student list, Scores, Attendance, and Evaluation Attributes into exact corresponding cells.
    4. Saves the fully populated Excel workbook ready for archiving and PDF conversion.

    :param json_input: Path to parsed JSON or dictionary data.
    :param template_path: Path to the blank template file.
    :param output_excel_path: Destination path for the populated Excel workbook.
    :return: Absolute path to the saved Excel workbook.
    """
    tmpl = Path(template_path)
    if not tmpl.exists():
        raise FileNotFoundError(f"Template workbook not found: {tmpl}")

    if isinstance(json_input, (str, Path)):
        with open(json_input, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = json_input

    header = data.get("header", {})
    students = data.get("students", [])

    wb = openpyxl.load_workbook(str(tmpl), keep_vba=tmpl.suffix.lower() == ".xlsm")
    wb = sanitize_blank_template(wb)

    # =========================================================================
    # 1. SHEET: (1) ปกปพ. (Cover Sheet - Dynamic Header Injection)
    # =========================================================================
    if "(1) ปกปพ." in wb.sheetnames:
        ws_cover = wb["(1) ปกปพ."]

        # School Name (Strip leading 'โรงเรียน' to prevent duplicate 'โรงเรียน โรงเรียน...' on cover)
        if header.get("school_name"):
            ws_cover["B5"] = clean_cover_school_name(header["school_name"])

        # Term / Semester
        if header.get("semester"):
            ws_cover["I7"] = clean_val(header["semester"])

        # Academic Year
        if header.get("academic_year"):
            ws_cover["L7"] = clean_val(header["academic_year"])

        # Cover sheet approval date (Term 1 -> 30  /  ก.ย.  /  year, Term 2 -> 30  /  มี.ค.  /  year+1)
        ws_cover["E42"] = get_approval_date_str(header.get("semester") or "1", header.get("academic_year"))
        try:
            ws_cover["E42"].alignment = openpyxl.styles.Alignment(horizontal="center", vertical="center")
        except Exception:
            pass

        # Inject school / PP5 logo into cover sheet (1) ปกปพ.
        inject_cover_sheet_logo(ws_cover, db_path="school_archive.db")

        c_code = str(header.get("course_code") or "").strip()
        c_name = str(header.get("course_name") or "").strip()
        credits = clean_val(header.get("credits"))
        level = str(header.get("class_level") or "").strip()
        teacher = header.get("teacher") or ""

        # Reference canonical course name & metadata from master catalog if course_code matches
        if c_code:
            try:
                from catalog_manager import lookup_catalog_course, _clean_garbled_course_name
                cat = lookup_catalog_course(c_code)
                if cat:
                    c_name = cat["course_name"]
                    header["course_name"] = c_name
                    if credits is None and cat.get("credits") is not None:
                        credits = clean_val(cat["credits"])
                    if (not level or level == "#N/A") and cat.get("class_level"):
                        level = str(cat["class_level"]).strip()
                    if not course_description and not header.get("course_description") and cat.get("course_description"):
                        header["course_description"] = cat["course_description"]
                else:
                    c_name = _clean_garbled_course_name(c_code, c_name)
                    header["course_name"] = c_name
            except Exception:
                pass

        # Infer department and course type
        meta = infer_course_metadata(c_code, c_name)
        department = meta["department"]
        course_type = meta["course_type"]
        score_ratio = meta["score_ratio"]

        # Clean teacher name rigorously (keep only Title + First + Last)
        if teacher:
            m_t = re.search(r"((?:นาย|นางสาว|นาง|ดร\.|ว่าที่\s*ร\.ต\.)\s*[^\s\d]+(?:\s+[^\s\d]+)?)", teacher)
            clean_teacher = m_t.group(1).strip() if m_t else teacher.strip()
            ws_cover["E11"] = clean_teacher
            ws_cover["E26"] = clean_teacher

        # Directly inject cover fields so NO #N/A ever appears on cover
        if c_code:
            ws_cover["L9"] = c_code
        
        # Determine class level (infer if missing or #N/A)
        c_level = level
        if not c_level or str(c_level).strip() == "#N/A":
            c_level = infer_class_level(c_code, str(level or ""))
        if c_level:
            ws_cover["E7"] = c_level
            safe_set_cell_addr(ws_cover, "O1", stage_label(c_level))

        # Directly inject Class Advisors (ครูที่ปรึกษา / ครูประจำชั้น)
        term = str(header.get("semester") or "1")
        year = str(header.get("academic_year") or "2568")
        if get_advisor_for_class and c_level:
            adv_info = get_advisor_for_class(term=term, year=year, class_level=str(c_level))
            if adv_info:
                adv_list = [
                    a.strip() for a in [
                        adv_info.get("advisor1"),
                        adv_info.get("advisor2"),
                        adv_info.get("advisor3")
                    ] if a and a.strip()
                ]
                if len(adv_list) == 1:
                    ws_cover["E12"] = adv_list[0]
                    ws_cover["E13"] = ""
                elif len(adv_list) == 2:
                    ws_cover["E12"] = adv_list[0]
                    ws_cover["E13"] = adv_list[1]
                elif len(adv_list) >= 3:
                    ws_cover["E12"] = f"1. {adv_list[0]}   2. {adv_list[1]}"
                    ws_cover["E13"] = f"3. {adv_list[2]}"

        # Directly inject School Signatories / Authorities (ผู้อำนวยการ, หัวหน้าวิชาการ, งานทะเบียน, หัวหน้ากลุ่มสาระ)
        if resolve_signatories_for_course:
            try:
                sigs = resolve_signatories_for_course(
                    course_code=c_code,
                    year=year,
                    dept_name=department
                )
                if sigs.get("school_name"):
                    ws_cover["B5"] = clean_cover_school_name(sigs["school_name"])
                if sigs.get("dept_head_name"):
                    ws_cover["E29"] = sigs["dept_head_name"]
                if sigs.get("dept_head_title"):
                    ws_cover["K28"] = sigs["dept_head_title"]
                if sigs.get("registrar_name"):
                    ws_cover["E32"] = sigs["registrar_name"]
                if sigs.get("registrar_title"):
                    ws_cover["K31"] = sigs["registrar_title"]
                if sigs.get("academic_head_name"):
                    ws_cover["E36"] = sigs["academic_head_name"]
                if sigs.get("academic_head_title"):
                    ws_cover["K35"] = sigs["academic_head_title"]
                if sigs.get("director_name"):
                    ws_cover["E41"] = sigs["director_name"]
                if sigs.get("director_title"):
                    ws_cover["K40"] = sigs["director_title"]
            except Exception as e_sig:
                print(f"[WARN] Failed to resolve signatories in map_sgs_to_excel: {e_sig}")
        try:
            apply_school_address(ws_cover)
        except Exception as e_addr:
            print(f"[WARN] school address on the cover: {e_addr}")

        if department and department != "-":
            ws_cover["E8"] = department     # กลุ่มสาระการเรียนรู้
        if course_type:
            ws_cover["L8"] = course_type    # ประเภทวิชา
        if c_name:
            ws_cover["E9"] = c_name         # รายวิชา
        if credits is not None:
            ws_cover["F10"] = credits       # จำนวนน้ำหนัก/หน่วยกิต
            try:
                c_num = float(credits)
                ws_cover["K10"] = int(c_num * 2) if (c_num * 2).is_integer() else (c_num * 2)
            except Exception:
                ws_cover["K10"] = "=F10*2"

        # Also register course into the lookup table W5:AD130 so formulas like
        # =VLOOKUP('(1) ปกปพ.'!L9,'(1) ปกปพ.'!W4:AC107,4,FALSE) in Sheet (4) also succeed!
        if c_code:
            found_row = None
            first_empty_row = None
            for r in range(5, 131):
                val = ws_cover.cell(r, 23).value
                if val == c_code:
                    found_row = r
                    break
                if not val and first_empty_row is None:
                    first_empty_row = r

            target_r = found_row or first_empty_row
            if target_r and target_r <= 130:
                ws_cover.cell(target_r, 23).value = c_code
                ws_cover.cell(target_r, 24).value = c_name
                ws_cover.cell(target_r, 25).value = credits
                ws_cover.cell(target_r, 26).value = score_ratio
                ws_cover.cell(target_r, 27).value = level
                ws_cover.cell(target_r, 28).value = course_type
                ws_cover.cell(target_r, 29).value = department

    # Ensure headers in Sheet (2) and Sheet (3) never show #N/A
    tot_hours = 40
    if credits:
        try:
            tot_hours = int(float(credits) * 40)
        except Exception:
            tot_hours = 40

    if "(2) เวลาเรียน1" in wb.sheetnames:
        ws_h1 = wb["(2) เวลาเรียน1"]
        if c_name:
            ws_h1["I2"] = c_name
        if c_code:
            ws_h1["AF2"] = c_code
        ws_h1["N3"] = tot_hours
        if level:
            ws_h1["AH3"] = level

    if "(3) เวลาเรียน2" in wb.sheetnames:
        ws_h2 = wb["(3) เวลาเรียน2"]
        if c_name:
            ws_h2["I2"] = c_name
        if c_code:
            ws_h2["AF2"] = c_code
        ws_h2["N3"] = tot_hours
        ws_h2["AW8"] = tot_hours
        if level:
            ws_h2["AH3"] = level

    # =========================================================================
    # 2 & 3. SHEETS: (2) เวลาเรียน1 & (3) เวลาเรียน2 (Student Roster & Attendance)
    # =========================================================================
    ws_att1 = wb["(2) เวลาเรียน1"] if "(2) เวลาเรียน1" in wb.sheetnames else None
    ws_att2 = wb["(3) เวลาเรียน2"] if "(3) เวลาเรียน2" in wb.sheetnames else None

    # Inject Calendar (Row 6 Month/Year & Row 7 Date) and Hours (Row 8)
    weeks = calculate_schedule_dates(
        start_date=start_date,
        term=header.get("semester") or "1",
        year_be=header.get("academic_year")
    )
    inject_schedule_calendar_and_hours(ws_att1, ws_att2, weeks, schedule)

    for idx, st in enumerate(students, start=1):
        r = 8 + idx
        st_id = str(st.get("student_id") or "")
        f_name = st.get("full_name") or ""

        if ws_att1:
            ws_att1.cell(row=r, column=1).value = idx        # Col A: เลขที่
            ws_att1.cell(row=r, column=2).value = st_id      # Col B: เลขประจำตัว
            ws_att1.cell(row=r, column=3).value = f_name     # Col C: ชื่อ-สกุล

        # Determine attendance marks and summary counts
        att = st.get("attendance") or {}
        att_pct = st.get("attendance_percentage") or att.get("percentage")

        raw_status_list: List[str] = att.get("status_list") or []
        status_list = normalize_attendance_status_list(raw_status_list, 100)

        has_custom_marks = any(m for m in status_list)
        if has_custom_marks:
            p_count = sum(1 for s in status_list if s in ("/", "ส"))
            l_count = sum(1 for s in status_list if s == "ล")
            a_count = max(0, tot_hours - p_count - l_count)
            pct = round((p_count / float(tot_hours)) * 100, 1) if tot_hours > 0 else 100.0
        elif att.get("present_count") is not None or att.get("present") is not None:
            p_count = int(att.get("present_count") or att.get("present") or 0)
            l_count = int(att.get("leave_count") or att.get("leave") or 0)
            a_count = int(att.get("absent_count") or att.get("absent") or max(0, tot_hours - p_count - l_count))
            pct = round((p_count / float(tot_hours)) * 100, 1) if tot_hours > 0 else 100.0
            status_list = create_default_status_list(p_count, l_count, a_count, tot_hours)
        elif att_pct is not None:
            pct = clean_val(att_pct)
            p_count = min(tot_hours, max(0, int(round(tot_hours * (float(pct) / 100.0)))))
            l_count = 0
            a_count = max(0, tot_hours - p_count)
            status_list = create_default_status_list(p_count, l_count, a_count, tot_hours)
        else:
            p_count = tot_hours
            l_count = 0
            a_count = 0
            pct = 100.0
            status_list = create_default_status_list(p_count, 0, 0, tot_hours)

        # Inject checkmarks into Sheet (2) เวลาเรียน1 (Cols 4-58: 55 periods)
        if ws_att1:
            for p_i, c_idx in enumerate(ALL_P1_COLS):
                mark = status_list[p_i] if p_i < len(status_list) else ""
                ws_att1.cell(row=r, column=c_idx).value = mark if mark else None

        # Inject checkmarks and summary into Sheet (3) เวลาเรียน2 (Cols 4-48: 45 periods)
        if ws_att2:
            for p_i, c_idx in enumerate(ALL_P2_COLS):
                slot_idx = 55 + p_i
                mark = status_list[slot_idx] if slot_idx < len(status_list) else ""
                ws_att2.cell(row=r, column=c_idx).value = mark if mark else None

            # Summary columns
            ws_att2.cell(row=r, column=49).value = p_count        # Col AW: มาเรียน
            ws_att2.cell(row=r, column=50).value = a_count        # Col AX: ขาด (ว่าง)
            ws_att2.cell(row=r, column=51).value = l_count        # Col AY: ลา (ล)
            ws_att2.cell(row=r, column=52).value = pct            # Col AZ: มาเรียนร้อยละ

    # =========================================================================
    # 4. SHEET: (4) รวมคะแนน (Score Breakdown & Grade Determination)
    # =========================================================================
    if "(4) รวมคะแนน" in wb.sheetnames:
        ws_scores = wb["(4) รวมคะแนน"]
        if c_name:
            safe_set_cell_addr(ws_scores, "C2", c_name)
        if c_code:
            safe_set_cell_addr(ws_scores, "M2", c_code)
        if score_ratio:
            safe_set_cell_addr(ws_scores, "E3", score_ratio)
        if level:
            safe_set_cell_addr(ws_scores, "M3", level)

        score_cfg = header.get("score_config")
        if isinstance(score_cfg, dict):
            unit_max_list = score_cfg.get("unit_max") or []
            for u_idx in range(8):
                val = unit_max_list[u_idx] if u_idx < len(unit_max_list) else None
                safe_set_cell(ws_scores, 9, 3 + u_idx, clean_val(val) if val is not None and str(val).strip() != "" else None)
            safe_set_cell(ws_scores, 9, 11, "=SUM(C9:J9)")
            mid_m = score_cfg.get("midterm_max")
            safe_set_cell(ws_scores, 9, 12, clean_val(mid_m) if mid_m is not None and str(mid_m).strip() != "" else None)
            safe_set_cell(ws_scores, 9, 13, "=K9+L9")
            cen_m = score_cfg.get("central_exam_max")
            safe_set_cell(ws_scores, 9, 14, clean_val(cen_m) if cen_m is not None and str(cen_m).strip() != "" else None)
            sch_m = score_cfg.get("school_exam_max")
            safe_set_cell(ws_scores, 9, 15, clean_val(sch_m) if sch_m is not None and str(sch_m).strip() != "" else None)
            safe_set_cell(ws_scores, 9, 16, "=O9+N9")
            safe_set_cell(ws_scores, 9, 17, "=P9+M9")

        for idx, st in enumerate(students, start=1):
            r = 9 + idx
            ws_scores.cell(row=r, column=1).value = idx                             # Col A: เลขที่
            ws_scores.cell(row=r, column=2).value = f"=IF('(2) เวลาเรียน1'!C{8 + idx}=\"\",\"\",'(2) เวลาเรียน1'!C{8 + idx})" # Col B: ชื่อ-สกุล

            scores = st.get("scores") or {}
            units = scores.get("units") or []

            # Unit / Formative scores (Cols C to J: up to 8 units)
            for u_idx in range(8):
                u_score = units[u_idx] if u_idx < len(units) else None
                ws_scores.cell(row=r, column=3 + u_idx).value = (
                    clean_val(u_score) if u_score is not None and str(u_score).strip() != "" else None
                )

            # Formative Subtotal (Col K): formula =IF(B{r}="","",SUM(C{r}:J{r}))
            ws_scores.cell(row=r, column=11).value = f'=IF(B{r}="","",SUM(C{r}:J{r}))'

            # Midterm score (Col L)
            mid_v = scores.get("midterm")
            ws_scores.cell(row=r, column=12).value = (
                clean_val(mid_v) if mid_v is not None and str(mid_v).strip() != "" else None
            )

            # Between-term Subtotal (Col M): formula =IF(B{r}="","",K{r}+L{r})
            ws_scores.cell(row=r, column=13).value = f'=IF(B{r}="","",K{r}+L{r})'

            # Central exam score (Col N: ข้อสอบกลาง)
            cen_v = scores.get("central_exam")
            ws_scores.cell(row=r, column=14).value = (
                clean_val(cen_v) if cen_v is not None and str(cen_v).strip() != "" else None
            )

            # Final score (Col O: ข้อสอบ รร.)
            fin_v = scores.get("final")
            ws_scores.cell(row=r, column=15).value = (
                clean_val(fin_v) if fin_v is not None and str(fin_v).strip() != "" else None
            )

            # Final Subtotal (Col P): formula =IF(B{r}="","",N{r}+O{r})
            ws_scores.cell(row=r, column=16).value = f'=IF(B{r}="","",N{r}+O{r})'

            # Total score (Col Q: รวม 100): formula =IF(B{r}="","",M{r}+P{r})
            ws_scores.cell(row=r, column=17).value = f'=IF(B{r}="","",M{r}+P{r})'

            # Remark override (Col S: 'ร', 'มส', 'มผ', 'ผ') & Grade formula (Col R)
            remark_str = str(scores.get("remark") or "").strip()
            grade_str = str(st.get("grade") or "").strip()
            if not remark_str and grade_str and not isinstance(clean_val(grade_str), (int, float)):
                remark_str = grade_str

            ws_scores.cell(row=r, column=19).value = remark_str if remark_str else None
            ws_scores.cell(row=r, column=18).value = (
                f'=IF(B{r}="","",(IF(S{r}="",(IF(Q{r}>=80,4,IF(Q{r}>=75,3.5,IF(Q{r}>=70,3,IF(Q{r}>=65,2.5,IF(Q{r}>=60,2,IF(Q{r}>=55,1.5,IF(Q{r}>=50,1,0)))))))),S{r})))'
            )

    # =========================================================================
    # 5. SHEET: (5) คุณลักษณะ (Desirable Attributes & Reading Analysis)
    # =========================================================================
    if "(5) คุณลักษณะ" in wb.sheetnames:
        ws_attr = wb["(5) คุณลักษณะ"]
        for idx, st in enumerate(students, start=1):
            r = 6 + idx
            ws_attr.cell(row=r, column=1).value = idx                               # Col A: เลขที่
            ws_attr.cell(row=r, column=2).value = f"='(2) เวลาเรียน1'!C{8 + idx}"  # Col B: ชื่อ-สกุล

            attrs = st.get("attributes") or {}
            desirable_val = clean_val(attrs.get("desirable_characteristics") or 2)
            desirable_items = attrs.get("desirable_items") or [desirable_val] * 8
            
            reading_val = clean_val(attrs.get("reading_analytical_thinking") or 2)
            reading_items = attrs.get("reading_items") or [reading_val] * 5

            # 8 Desirable Attributes items (Cols C to J)
            for u_idx, item_val in enumerate(desirable_items[:8]):
                ws_attr.cell(row=r, column=3 + u_idx).value = clean_val(item_val)
            ws_attr.cell(row=r, column=11).value = desirable_val                    # Col K: ผลการประเมิน คุณลักษณะ

            # 5 Reading & Analytical Thinking items (Cols L to P)
            for u_idx, item_val in enumerate(reading_items[:5]):
                ws_attr.cell(row=r, column=12 + u_idx).value = clean_val(item_val)
            ws_attr.cell(row=r, column=17).value = reading_val                      # Col Q: ผลการประเมิน อ่านคิดวิเคราะห์

    # =========================================================================
    # 6. SHEET: (6) ตัวชี้วัด (Course Description & Indicators Auto-Fit)
    # =========================================================================
    if "(6) ตัวชี้วัด" in wb.sheetnames:
        ws_indicators = wb["(6) ตัวชี้วัด"]
        desc_text = course_description or header.get("course_description") or ""
        if not desc_text and get_course_description is not None and header.get("course_code"):
            desc_text = get_course_description(header["course_code"]) or ""
        if desc_text and desc_text.strip():
            inject_course_description(ws_indicators, desc_text.strip())

    # ตัวชี้วัด of slots 1-8 and the คุณลักษณะ / อ่านคิดวิเคราะห์ item names the teacher typed (vertical headers)
    import pp5_labels
    pp5_labels.apply_from_db(wb, str(header.get("course_code") or "").strip(),
                             str(header.get("semester") or "").strip(), str(header.get("academic_year") or "").strip())

    out_file = Path(output_excel_path).resolve()
    save_workbook_atomic(wb, out_file)
    return str(out_file)


_excel_com_lock = threading.Lock()


def convert_excel_to_pdf_win32(excel_path: str, pdf_path: str) -> str:
    """Convert all sheets of an Excel workbook to a combined single PDF via Excel COM with clean page fitting."""
    import win32com.client
    import pythoncom

    excel_abs = str(Path(excel_path).resolve())
    pdf_abs = str(Path(pdf_path).resolve())

    Path(pdf_abs).parent.mkdir(parents=True, exist_ok=True)

    with _excel_com_lock:
        pythoncom.CoInitialize()
        excel = None
        excel_pid = None
        wb = None
        try:
            excel = win32com.client.DispatchEx("Excel.Application")
            excel.Visible = False
            excel.DisplayAlerts = False
            excel.ScreenUpdating = False
            try:  # remember the process so it can be ended even if Quit() leaves it running
                import win32process
                excel_pid = win32process.GetWindowThreadProcessId(excel.Hwnd)[1]
            except Exception:
                excel_pid = None

            wb = excel.Workbooks.Open(excel_abs, ReadOnly=True)

            # Export all active sheets to single PDF
            # xlTypePDF = 0, xlQualityStandard = 0, IncludeDocProperties = True, IgnorePrintAreas = False
            wb.ExportAsFixedFormat(0, pdf_abs, 0, True, False)
            wb.Close(SaveChanges=False)
            return pdf_abs
        finally:
            if wb is not None:
                try:
                    del wb
                except Exception:
                    pass
            if excel is not None:
                try:
                    excel.Quit()
                except Exception:
                    pass
                try:
                    del excel
                except Exception:
                    pass
            pythoncom.CoUninitialize()
            if excel_pid:
                _end_orphan_excel(excel_pid)


def _end_orphan_excel(pid: int, wait_seconds: float = 3.0) -> None:
    """Excel started by DispatchEx sometimes survives Quit(); end that one hidden instance (never the user's Excel)."""
    import time
    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        r = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True)
        if "EXCEL" not in r.stdout.upper():
            return
        time.sleep(0.3)
    subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)


def convert_excel_to_pdf_libreoffice(excel_path: str, pdf_path: str, timeout_seconds: int = 240) -> str:
    """
    Converter for Linux (and Windows without Excel) using LibreOffice headless.
    Converts in a private temp folder with its own LibreOffice profile (parallel calls never
    share a locked profile), runs at low CPU priority on Linux so teachers using the web app
    stay responsive, then atomically moves the PDF into place.
    """
    import tempfile
    soffice_cmd = shutil.which("soffice") or shutil.which("libreoffice")
    if not soffice_cmd:
        default_lo = Path(r"C:\Program Files\LibreOffice\program\soffice.exe")
        if default_lo.exists():
            soffice_cmd = str(default_lo)
        else:
            raise RuntimeError(
                "Neither Excel COM automation (pywin32) nor LibreOffice is available. "
                "Please install pywin32 or LibreOffice."
            )

    excel_abs = Path(excel_path).resolve()
    pdf_target = Path(pdf_path).resolve()
    with tempfile.TemporaryDirectory(prefix="pp5_lo_") as work:
        work_dir = Path(work)
        src = work_dir / f"source{excel_abs.suffix}"
        shutil.copy2(excel_abs, src)  # ASCII name avoids locale issues with Thai file names
        cmd = [
            soffice_cmd,
            f"-env:UserInstallation={(work_dir / 'profile').as_uri()}",
            "--headless", "--norestore", "--nologo",
            "--convert-to", "pdf",
            "--outdir", str(work_dir),
            str(src),
        ]
        preexec = (lambda: os.nice(10)) if hasattr(os, "nice") else None
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       timeout=timeout_seconds, preexec_fn=preexec)
        gen_pdf = work_dir / "source.pdf"
        if not gen_pdf.exists():
            raise RuntimeError(f"LibreOffice produced no PDF for {excel_abs.name}")
        pdf_target.parent.mkdir(parents=True, exist_ok=True)
        tmp_final = pdf_target.with_name(f".{pdf_target.stem}.{os.getpid()}.lo.tmp.pdf")
        shutil.move(str(gen_pdf), str(tmp_final))
        os.replace(tmp_final, pdf_target)
    return str(pdf_target)


def find_soffice() -> Optional[str]:
    """LibreOffice, if this machine has it (PATH, then the usual Windows location)."""
    cmd = shutil.which("soffice") or shutil.which("libreoffice")
    if cmd:
        return cmd
    for c in (r"C:\Program Files\LibreOffice\program\soffice.exe",
              r"C:\Program Files (x86)\LibreOffice\program\soffice.exe"):
        if Path(c).exists():
            return c
    return None


def pdf_engine() -> str:
    """Which converter makes the ปพ.5 PDF.

    'auto' (the default) prefers LibreOffice wherever it is installed, so Windows and Linux produce the
    same file. It is also the better output: Excel exports the date row of the attendance sheet as '###'
    (the column is narrower than the number), uses the printer's paper size instead of the template's A4,
    and writes a broken Thai text layer. Excel COM stays as the fallback, and PP5_PDF_ENGINE=excel forces it.
    """
    want = (os.environ.get("PP5_PDF_ENGINE") or "auto").strip().lower()
    if want in ("excel", "win32", "com"):
        return "excel"
    if want in ("libreoffice", "soffice", "lo"):
        return "libreoffice"
    return "libreoffice" if find_soffice() else "excel"


def export_excel_to_pdf(excel_path: str, pdf_path: Optional[str] = None) -> str:
    """
    High-level export wrapper: LibreOffice when installed, otherwise Windows Excel COM.
    Both write beside the target and swap, so viewers never read a partial PDF.
    """
    in_excel = Path(excel_path).resolve()
    if not in_excel.exists():
        raise FileNotFoundError(f"Source Excel not found: {in_excel}")

    out_pdf = pdf_path or str(in_excel.with_suffix(".pdf"))

    if pdf_engine() == "libreoffice":
        try:
            return convert_excel_to_pdf_libreoffice(str(in_excel), out_pdf)
        except Exception as e_lo:
            if sys.platform != "win32":
                raise
            print(f"[INFO] LibreOffice export failed ({e_lo}), trying Excel...", file=sys.stderr)

    if sys.platform == "win32":
        try:
            out_path = Path(out_pdf).resolve()
            tmp_pdf = out_path.with_name(f".{out_path.stem}.{os.getpid()}.{threading.get_ident()}.tmp.pdf")
            convert_excel_to_pdf_win32(str(in_excel), str(tmp_pdf))
            os.replace(tmp_pdf, out_path)
            return str(out_path)
        except Exception as e_win32:
            print(f"[INFO] Win32 Excel export unavailable ({e_win32}), trying LibreOffice...", file=sys.stderr)
    return convert_excel_to_pdf_libreoffice(str(in_excel), out_pdf)


def process_sgs_pdf(
    pdf_path: str,
    template_path: str = "template_ปพ5_blank.xlsx",
    output_excel_path: Optional[str] = None,
    output_pdf_path: Optional[str] = None,
    db_path: str = "school_archive.db",
    course_description: Optional[str] = None,
    override_term: Optional[str] = None,
    override_year: Optional[str] = None,
    override_teacher: Optional[str] = None
) -> Dict[str, Any]:
    """
    End-to-end full pipeline:
    1. Parse SGS PDF -> structured JSON.
    2. Save to SQLite database (`school_archive.db`).
    3. Inject into Blank Excel Template (`template_ปพ5_blank.xlsx`).
    4. Export clean print-ready combined PDF.
    """
    pdf_file = Path(pdf_path).resolve()
    if not pdf_file.exists():
        raise FileNotFoundError(f"PDF not found: {pdf_file}")

    # Derive default output paths
    base_stem = pdf_file.stem
    excel_out = output_excel_path or f"{base_stem}_ปพ5_filled.xlsx"
    pdf_out = output_pdf_path or f"{base_stem}_ปพ5_print_ready.pdf"

    print(f"[1/4] Parsing SGS PDF: {pdf_file.name} ...")
    if parse_sgs_pdf is None:
        raise RuntimeError("sgs_parser module is not available")
    parsed_data = parse_sgs_pdf(str(pdf_file))
    print(f"      Extracted {len(parsed_data['students'])} students.")

    # Apply overrides if provided
    if override_term:
        parsed_data.setdefault("header", {})["semester"] = str(override_term)
        parsed_data.setdefault("header", {})["term"] = str(override_term)
    if override_year:
        parsed_data.setdefault("header", {})["academic_year"] = str(override_year)
        parsed_data.setdefault("header", {})["year"] = str(override_year)
    if override_teacher:
        parsed_data.setdefault("header", {})["teacher"] = str(override_teacher)

    # Apply course description if provided or retrieved from DB
    c_code = parsed_data.get("header", {}).get("course_code")
    if course_description:
        parsed_data.setdefault("header", {})["course_description"] = course_description
    elif c_code and get_course_description is not None:
        db_desc = get_course_description(c_code, db_path=db_path)
        if db_desc:
            parsed_data.setdefault("header", {})["course_description"] = db_desc

    print(f"[2/4] Archiving into SQLite: {db_path} ...")
    if ingest_parsed_json is not None:
        db_summary = ingest_parsed_json(parsed_data, db_path=db_path)
        print(f"      Archived: {db_summary['students_upserted']} students for course {db_summary['course_code']}.")
    else:
        print("      [SKIP] database module not available.")

    print(f"[3/4] Injecting into Blank Excel Template: {template_path} ...")
    generated_excel = map_sgs_to_excel(
        parsed_data,
        template_path=template_path,
        output_excel_path=excel_out,
        course_description=course_description or parsed_data.get("header", {}).get("course_description")
    )
    print(f"      Saved Populated Excel: {generated_excel}")

    print(f"[4/4] Exporting Print-Ready PDF: {pdf_out} ...")
    generated_pdf = export_excel_to_pdf(generated_excel, pdf_out)
    print(f"      Saved Print-Ready PDF: {generated_pdf}")

    hdr = parsed_data.get("header", {})
    return {
        "course_code": hdr.get("course_code"),
        "course_name": hdr.get("course_name"),
        "teacher": hdr.get("teacher"),
        "term": hdr.get("semester") or hdr.get("term"),
        "year": hdr.get("academic_year") or hdr.get("year"),
        "total_students": len(parsed_data["students"]),
        "excel_path": generated_excel,
        "pdf_path": generated_pdf
    }


def update_course_description_in_file(
    course_code: str,
    description: str,
    term: Optional[str] = None,
    year: Optional[str] = None,
    db_path: str = "school_archive.db",
    outputs_dir: str = "outputs"
) -> Dict[str, Any]:
    """
    Update the course description in the database, inject it into the existing
    ปพ.5 Excel file for that course, and re-export the print-ready PDF.
    """
    from database import update_course_description
    
    # 1. Update SQLite DB
    updated_db = update_course_description(course_code, description, db_path=db_path)

    # 2. Compute fitting info
    formatted_text, font_size = format_and_fit_course_description(description)

    # 3. Locate existing Excel file in outputs or root
    out_dir_path = Path(outputs_dir).resolve()
    search_dirs = [out_dir_path, Path(".").resolve()]
    
    excel_file: Optional[Path] = None
    for d in search_dirs:
        excel_file = find_course_matching_file(d, course_code, term=term, year=year, ext=".xlsx")
        if excel_file:
            break

    excel_updated = False
    pdf_updated = False
    pdf_path_str: Optional[str] = None

    if excel_file and excel_file.exists():
        try:
            wb = openpyxl.load_workbook(str(excel_file), keep_vba=excel_file.suffix.lower() == ".xlsm")
            if "(6) ตัวชี้วัด" in wb.sheetnames:
                inject_course_description(wb["(6) ตัวชี้วัด"], description)
                save_workbook_atomic(wb, excel_file)
                excel_updated = True

            # Regenerate PDF
            pdf_target = excel_file.parent / f"{excel_file.stem.replace('_ปพ5_filled', '')}_ปพ5_print_ready.pdf"
            export_excel_to_pdf(str(excel_file), str(pdf_target))
            pdf_updated = True
            pdf_path_str = str(pdf_target)
        except Exception as e:
            print(f"[ERROR] Failed to update Excel/PDF files for {course_code}: {e}", file=sys.stderr)

    return {
        "course_code": course_code,
        "db_updated": updated_db,
        "font_size": font_size,
        "excel_updated": excel_updated,
        "pdf_updated": pdf_updated,
        "excel_path": str(excel_file) if excel_file else None,
        "pdf_path": pdf_path_str
    }


def update_course_attendance_in_file(
    course_code: str,
    records: List[Dict[str, Any]],
    term: Optional[str] = None,
    year: Optional[str] = None,
    db_path: str = "school_archive.db",
    outputs_dir: str = "outputs",
    start_date: Optional[str] = None,
    schedule: Optional[Dict[str, Any]] = None,
    regenerate_pdf: bool = True,
    write_db: bool = True
) -> Dict[str, Any]:
    """
    Update attendance in database and directly inject checkmarks ('/', 'ส', 'ล', blank)
    and summary counts (มาเรียน, ขาด, ลา, ร้อยละ) into the existing ปพ.5 Excel file
    and regenerate the print-ready PDF.

    Hours, holidays and totals come from database.get_course_attendance_context and the
    arithmetic from attendance_rules, so the file always matches the DB and the template.
    start_date / schedule are accepted for backward compatibility but no longer written:
    the semester start date and the teacher timetable own those values.
    """
    import attendance_rules
    from database import update_course_attendance_batch, get_course_attendance_context

    if not term or not year:
        try:
            with get_connection(db_path) as conn:
                row = conn.execute(
                    "SELECT term, year FROM courses WHERE course_code = ? ORDER BY year DESC, term DESC LIMIT 1;",
                    (course_code,)
                ).fetchone()
                if row:
                    term, year = term or row["term"], year or row["year"]
        except Exception:
            pass

    updated_rows = 0
    if write_db:
        updated_rows = update_course_attendance_batch(
            course_code=course_code,
            records=records,
            term=term,
            year=year,
            db_path=db_path
        )

    # Locate existing Excel file
    out_dir_path = Path(outputs_dir).resolve()
    search_dirs = [out_dir_path, Path(".").resolve()]
    excel_file: Optional[Path] = None
    for d in search_dirs:
        excel_file = find_course_matching_file(d, course_code, term=term, year=year, ext=".xlsx")
        if excel_file:
            break

    excel_updated = False
    pdf_updated = False
    pdf_path_str: Optional[str] = None

    if excel_file and excel_file.exists() and term and year:
        try:
            ctx = get_course_attendance_context(course_code, str(term), str(year), db_path=db_path)
            hours = ctx["hours"]
            activity = ctx["activity"]
            tot_hours = ctx["total"]
            legacy_schedule = {
                "mon": ctx["periods"][0], "tue": ctx["periods"][1], "wed": ctx["periods"][2],
                "thu": ctx["periods"][3], "fri": ctx["periods"][4], "holidays": sorted(ctx["holidays"]),
            }

            with workbook_lock(excel_file):
                wb = openpyxl.load_workbook(str(excel_file), keep_vba=excel_file.suffix.lower() == ".xlsm")
                ws_att1 = wb["(2) เวลาเรียน1"] if "(2) เวลาเรียน1" in wb.sheetnames else None
                ws_att2 = wb["(3) เวลาเรียน2"] if "(3) เวลาเรียน2" in wb.sheetnames else None

                semester_val = term
                level = ""
                # Cover metadata (fixes #N/A) and E42 approval date
                if "(1) ปกปพ." in wb.sheetnames:
                    ws_cov = wb["(1) ปกปพ."]
                    ws_cov["I7"] = clean_val(term)
                    ws_cov["L7"] = clean_val(year)
                    ws_cov["E42"] = get_approval_date_str(semester_val, year)
                    try:
                        ws_cov["E42"].alignment = openpyxl.styles.Alignment(horizontal="center", vertical="center")
                    except Exception:
                        pass
                    c_name = ws_cov["E9"].value or ""
                    level = ws_cov["E7"].value or ""
                    for ws in (ws_att1, ws_att2):
                        if not ws:
                            continue
                        if c_name:
                            ws["I2"] = c_name
                        ws["AF2"] = course_code
                        if level:
                            ws["AH3"] = level
                # N3 / AW8 = total hours actually taught (timetable minus holidays), matching row 8
                for ws in (ws_att1, ws_att2):
                    if ws:
                        ws["N3"] = tot_hours
                if ws_att2:
                    ws_att2["AW8"] = tot_hours

                weeks = calculate_schedule_dates(start_date=ctx["start_date"], term=semester_val, year_be=year)
                inject_schedule_calendar_and_hours(ws_att1, ws_att2, weeks, slot_hours=hours)

                rec_map = {}
                for r in records:
                    st_id = str(r.get("student_id") or "").strip()
                    if st_id:
                        rec_map[st_id] = r
                    st_no = r.get("student_no")
                    if st_no is not None:
                        rec_map[f"no_{st_no}"] = r

                # Teacher-chosen remarks (scores page); มส. on sheet (4) column S otherwise follows attendance
                ws_scores = wb["(4) รวมคะแนน"] if "(4) รวมคะแนน" in wb.sheetnames else None
                manual_remarks: Dict[str, str] = {}
                if ws_scores is not None:
                    with get_connection(db_path) as conn:
                        for g in conn.execute(
                            "SELECT student_id, scores_json FROM grades_history WHERE course_code = ? AND term = ? AND year = ?;",
                            (course_code, str(term), str(year))
                        ):
                            sc = attendance_rules._load(g["scores_json"])
                            manual_remarks[str(g["student_id"])] = str((sc or {}).get("remark") or "").strip() if isinstance(sc, dict) else ""

                if ws_att1 or ws_att2:
                    for r in range(9, 60):
                        st_id_val = ws_att1.cell(r, 2).value if ws_att1 else ws_att2.cell(r, 2).value
                        st_no_val = ws_att1.cell(r, 1).value if ws_att1 else ws_att2.cell(r, 1).value
                        if not st_id_val and not st_no_val:
                            break

                        rec = None
                        if st_id_val and str(st_id_val).strip() in rec_map:
                            rec = rec_map[str(st_id_val).strip()]
                        elif not st_id_val and st_no_val and f"no_{st_no_val}" in rec_map:
                            rec = rec_map[f"no_{st_no_val}"]
                        if not rec:
                            continue

                        att = rec.get("attendance") or rec
                        status_list = attendance_rules.normalize_status_list(att.get("status_list"))
                        if not any(status_list) and (att.get("present_count") or att.get("present")):
                            # Legacy imports only carry counts: lay them out over the teaching days
                            p_c = int(att.get("present_count") or att.get("present") or 0)
                            l_c = int(att.get("leave_count") or att.get("leave") or 0)
                            status_list = create_default_status_list(p_c, l_c, max(0, tot_hours - p_c - l_c), tot_hours, legacy_schedule)
                        summ = attendance_rules.summarize(status_list, hours, activity, ctx["elapsed"])
                        marks = summ["status_list"]

                        if ws_att1:
                            for p_i, c_idx in enumerate(ALL_P1_COLS):
                                ws_att1.cell(row=r, column=c_idx).value = marks[p_i] or None
                        if ws_att2:
                            for p_i, c_idx in enumerate(ALL_P2_COLS):
                                ws_att2.cell(row=r, column=c_idx).value = marks[55 + p_i] or None
                            ws_att2.cell(row=r, column=49).value = summ["present_count"]   # AW มาเรียน
                            ws_att2.cell(row=r, column=50).value = summ["absent_count"]    # AX ขาด
                            ws_att2.cell(row=r, column=51).value = summ["leave_count"]     # AY ลา
                            ws_att2.cell(row=r, column=52).value = clean_val(summ["percentage"])  # AZ ร้อยละ
                        if ws_scores is not None and st_id_val:
                            remark = attendance_rules.effective_remark(manual_remarks.get(str(st_id_val).strip()), summ)
                            ws_scores.cell(row=r + 1, column=19).value = remark or None  # S: R's grade formula shows it

                # Sync latest advisors to cover sheet
                if "(1) ปกปพ." in wb.sheetnames and get_advisor_for_class:
                    try:
                        ws_cover = wb["(1) ปกปพ."]
                        c_lvl = level or ws_cover["E7"].value or ""
                        if not c_lvl or str(c_lvl).strip() == "#N/A":
                            c_lvl = infer_class_level(course_code, str(c_lvl))
                        if c_lvl:
                            adv_info = get_advisor_for_class(term=str(semester_val), year=str(year), class_level=str(c_lvl))
                            if adv_info:
                                adv_list = [a.strip() for a in [adv_info.get("advisor1"), adv_info.get("advisor2"), adv_info.get("advisor3")] if a and a.strip()]
                                if len(adv_list) == 1:
                                    ws_cover["E12"] = adv_list[0]
                                    ws_cover["E13"] = ""
                                elif len(adv_list) == 2:
                                    ws_cover["E12"] = adv_list[0]
                                    ws_cover["E13"] = adv_list[1]
                                elif len(adv_list) >= 3:
                                    ws_cover["E12"] = f"1. {adv_list[0]}   2. {adv_list[1]}"
                                    ws_cover["E13"] = f"3. {adv_list[2]}"
                    except Exception as e:
                        print(f"[WARN] Failed to sync advisors in attendance update: {e}")

                save_workbook_atomic(wb, excel_file)
                excel_updated = True

            if regenerate_pdf:
                pdf_target = excel_file.parent / f"{excel_file.stem.replace('_ปพ5_filled', '')}_ปพ5_print_ready.pdf"
                with PDF_EXPORT_LOCK:
                    export_excel_to_pdf(str(excel_file), str(pdf_target))
                pdf_updated = True
                pdf_path_str = str(pdf_target)
        except Exception as e:
            print(f"[ERROR] Failed to update attendance in Excel/PDF for {course_code}: {e}", file=sys.stderr)

    return {
        "course_code": course_code,
        "db_updated": updated_rows,
        "excel_updated": excel_updated,
        "pdf_updated": pdf_updated,
        "excel_path": str(excel_file) if excel_file else None,
        "pdf_path": pdf_path_str
    }


def sync_cover_sheet_to_excel(
    excel_path: Union[str, Path],
    term: Optional[str] = None,
    year: Optional[str] = None,
    course_code: Optional[str] = None,
    class_level: Optional[str] = None,
    teacher: Optional[str] = None,
    course_name: Optional[str] = None,
    db_path: str = "school_archive.db"
) -> bool:
    """
    Ensure the cover sheet (1) ปกปพ. of an Excel ปพ.5 file has all fields completely populated:
    - Course Code (L9)
    - Course Name (E9)
    - Class Level (E7) e.g. ม.4
    - Department / Learning Area (E8) e.g. การงานอาชีพ
    - Course Type (L8) e.g. พื้นฐาน / เพิ่มเติม
    - Credits (F10) e.g. 0.5, 1.0, 1.5
    - Weekly Hours (K10) e.g. 1, 2, 3
    - Teacher Name (E11) and Teacher Signature (E26)
    - Class Advisors (E12, E13)
    - Term (I7) and Academic Year (L7)
    - Approval Date (E42)
    - Injects course into lookup table W5:AD130 so built-in formulas in Sheet (4) succeed.
    """
    path = Path(excel_path)
    if not path.is_file():
        return False
    try:
        wb = openpyxl.load_workbook(str(path))
        if "(1) ปกปพ." not in wb.sheetnames:
            return False
        ws_cover = wb["(1) ปกปพ."]

        c_code = (course_code or "").strip()
        if not c_code:
            existing_l9 = ws_cover["L9"].value
            if existing_l9 and not str(existing_l9).startswith("="):
                c_code = str(existing_l9).strip()
            else:
                m_code = re.search(r"([ก-ฮa-zA-Z]\d{5})", path.name)
                if m_code:
                    c_code = m_code.group(1).strip()

        c_term = str(term).strip() if term else ""
        c_year = str(year).strip() if year else ""
        if not c_term or not c_year:
            m_ty = re.search(r"[_-](\d)[_-](\d{4})[_-]", path.name)
            if m_ty:
                c_term = c_term or m_ty.group(1)
                c_year = c_year or m_ty.group(2)
            else:
                m_alt = re.search(r"-(\d{4})-(\d)-", path.name)
                if m_alt:
                    c_year = c_year or m_alt.group(1)
                    c_term = c_term or m_alt.group(2)

        if not c_term:
            raw_i7 = ws_cover["I7"].value
            if raw_i7 and str(raw_i7).isdigit():
                c_term = str(raw_i7).strip()
        if not c_year:
            raw_l7 = ws_cover["L7"].value
            if raw_l7 and str(raw_l7).isdigit():
                c_year = str(raw_l7).strip()

        c_name = (course_name or "").strip()
        c_teacher = (teacher or "").strip()

        # Query database to retrieve canonical course info
        if get_connection:
            try:
                with get_connection(db_path) as conn:
                    cur = conn.cursor()
                    if c_code:
                        if c_term and c_year:
                            cur.execute(
                                "SELECT course_name, teacher, term, year FROM courses WHERE course_code = ? AND term = ? AND year = ? LIMIT 1;",
                                (c_code, c_term, c_year)
                            )
                        else:
                            cur.execute(
                                "SELECT course_name, teacher, term, year FROM courses WHERE course_code = ? ORDER BY year DESC, term DESC LIMIT 1;",
                                (c_code,)
                            )
                        row = cur.fetchone()
                        if row:
                            if not c_name and row["course_name"]:
                                c_name = row["course_name"]
                            if not c_teacher and row["teacher"]:
                                c_teacher = row["teacher"]
                            if not c_term and row["term"]:
                                c_term = str(row["term"])
                            if not c_year and row["year"]:
                                c_year = str(row["year"])
            except Exception as e:
                print(f"[WARN] Failed to query courses for {c_code}: {e}")

        # Teacher normalization
        clean_teacher = ""
        if c_teacher:
            if normalize_teacher_name:
                clean_teacher = normalize_teacher_name(c_teacher)
            else:
                m_t = re.search(r"((?:นาย|นางสาว|นาง|ดร\.|ว่าที่\s*ร\.ต\.)\s*[^\s\d]+(?:\s+[^\s\d]+)?)", c_teacher)
                clean_teacher = m_t.group(1).strip() if m_t else c_teacher.strip()

        # Class level inference
        c_level = class_level or ""
        if not c_level or str(c_level).strip() == "#N/A" or str(c_level).startswith("="):
            c_level = infer_class_level(c_code, "")

        # Metadata inference
        meta = infer_course_metadata(c_code, c_name)
        dept = meta["department"]
        course_type = meta["course_type"]
        score_ratio = meta["score_ratio"]

        # Find or inject in template lookup table W5:AD130
        lookup_info = None
        target_row = None
        first_empty_row = None

        for r in range(5, 131):
            cell_code = ws_cover.cell(row=r, column=23).value
            if cell_code and str(cell_code).strip() == c_code:
                target_row = r
                lookup_info = {
                    "name": ws_cover.cell(row=r, column=24).value,
                    "credits": ws_cover.cell(row=r, column=25).value,
                    "ratio": ws_cover.cell(row=r, column=26).value,
                    "level": ws_cover.cell(row=r, column=27).value,
                    "type": ws_cover.cell(row=r, column=28).value,
                    "dept": ws_cover.cell(row=r, column=29).value,
                }
                break
            if not cell_code and first_empty_row is None:
                first_empty_row = r

        credits = None
        if lookup_info and lookup_info.get("credits") is not None:
            try:
                credits = float(lookup_info["credits"])
                if not c_name and lookup_info.get("name"):
                    c_name = str(lookup_info["name"]).strip()
                if lookup_info.get("dept") and lookup_info["dept"] != "-":
                    dept = lookup_info["dept"]
                if lookup_info.get("type"):
                    course_type = lookup_info["type"]
                if lookup_info.get("ratio") and lookup_info["ratio"] != "-":
                    score_ratio = lookup_info["ratio"]
            except Exception:
                pass

        if credits is None and c_code.endswith("2"):
            cp_code = c_code[:-1] + "1"
            for r in range(5, 131):
                if ws_cover.cell(row=r, column=23).value == cp_code:
                    try:
                        cr = ws_cover.cell(row=r, column=25).value
                        if cr is not None:
                            credits = float(cr)
                        if ws_cover.cell(row=r, column=26).value:
                            score_ratio = ws_cover.cell(row=r, column=26).value
                        if ws_cover.cell(row=r, column=29).value and ws_cover.cell(row=r, column=29).value != "-":
                            dept = ws_cover.cell(row=r, column=29).value
                        if ws_cover.cell(row=r, column=28).value:
                            course_type = ws_cover.cell(row=r, column=28).value
                    except Exception:
                        pass
                    break

        if credits is None:
            if c_code.startswith("ก"):
                credits = 0.5
            elif c_code.startswith("ง"):
                credits = 0.5
            elif len(c_code) >= 2 and c_code[1] == "2" and c_code[0] in ("ค", "ว", "ท", "ส"):
                credits = 1.5
            else:
                credits = 1.0

        # Ensure course is stored in lookup table W5:AD130
        row_to_write = target_row or first_empty_row
        if row_to_write and row_to_write <= 130 and c_code:
            ws_cover.cell(row_to_write, 23).value = c_code
            if c_name:
                ws_cover.cell(row_to_write, 24).value = c_name
            ws_cover.cell(row_to_write, 25).value = clean_val(credits)
            ws_cover.cell(row_to_write, 26).value = score_ratio
            if c_level:
                ws_cover.cell(row_to_write, 27).value = c_level
            ws_cover.cell(row_to_write, 28).value = course_type
            if dept:
                ws_cover.cell(row_to_write, 29).value = dept

        # ---------------------------------------------------------
        # Direct cell injections on (1) ปกปพ.
        # ---------------------------------------------------------
        if c_code:
            safe_set_cell_addr(ws_cover, "L9", c_code)
        if c_name:
            safe_set_cell_addr(ws_cover, "E9", c_name)
        if c_level:
            safe_set_cell_addr(ws_cover, "E7", c_level)
            safe_set_cell_addr(ws_cover, "O1", stage_label(c_level))
        if dept and dept != "-":
            safe_set_cell_addr(ws_cover, "E8", dept)
        if course_type:
            safe_set_cell_addr(ws_cover, "L8", course_type)
        if credits is not None:
            c_val = clean_val(credits)
            safe_set_cell_addr(ws_cover, "F10", c_val)
            try:
                c_flt = float(credits)
                safe_set_cell_addr(ws_cover, "K10", int(c_flt * 2) if (c_flt * 2).is_integer() else (c_flt * 2))
            except Exception:
                safe_set_cell_addr(ws_cover, "K10", "=F10*2")

        if clean_teacher:
            safe_set_cell_addr(ws_cover, "E11", clean_teacher)
            safe_set_cell_addr(ws_cover, "E26", clean_teacher)

        # Class advisors injection
        if get_advisor_for_class and c_level:
            adv_info = get_advisor_for_class(term=c_term or "1", year=c_year or "2568", class_level=c_level, db_path=db_path)
            if adv_info:
                adv_list = [
                    a.strip() for a in [
                        adv_info.get("advisor1"),
                        adv_info.get("advisor2"),
                        adv_info.get("advisor3")
                    ] if a and a.strip()
                ]
                if len(adv_list) == 1:
                    safe_set_cell_addr(ws_cover, "E12", adv_list[0])
                    safe_set_cell_addr(ws_cover, "E13", "")
                elif len(adv_list) == 2:
                    safe_set_cell_addr(ws_cover, "E12", adv_list[0])
                    safe_set_cell_addr(ws_cover, "E13", adv_list[1])
                elif len(adv_list) >= 3:
                    safe_set_cell_addr(ws_cover, "E12", f"1. {adv_list[0]}   2. {adv_list[1]}")
                    safe_set_cell_addr(ws_cover, "E13", f"3. {adv_list[2]}")

        if c_term:
            safe_set_cell_addr(ws_cover, "I7", clean_val(c_term))
        if c_year:
            safe_set_cell_addr(ws_cover, "L7", clean_val(c_year))

        # Ensure B5 never has duplicate 'โรงเรียน'
        curr_b5 = ws_cover["B5"].value
        if curr_b5 and "โรงเรียน" in str(curr_b5):
            safe_set_cell_addr(ws_cover, "B5", clean_cover_school_name(curr_b5))

        # School Signatories / Authorities injection
        if resolve_signatories_for_course:
            try:
                sigs = resolve_signatories_for_course(
                    course_code=c_code,
                    year=c_year or "2568",
                    dept_name=dept,
                    db_path=db_path
                )
                if sigs.get("school_name"):
                    safe_set_cell_addr(ws_cover, "B5", clean_cover_school_name(sigs["school_name"]))
                if sigs.get("dept_head_name"):
                    safe_set_cell_addr(ws_cover, "E29", sigs["dept_head_name"])
                if sigs.get("dept_head_title"):
                    safe_set_cell_addr(ws_cover, "K28", sigs["dept_head_title"])
                if sigs.get("registrar_name"):
                    safe_set_cell_addr(ws_cover, "E32", sigs["registrar_name"])
                if sigs.get("registrar_title"):
                    safe_set_cell_addr(ws_cover, "K31", sigs["registrar_title"])
                if sigs.get("academic_head_name"):
                    safe_set_cell_addr(ws_cover, "E36", sigs["academic_head_name"])
                if sigs.get("academic_head_title"):
                    safe_set_cell_addr(ws_cover, "K35", sigs["academic_head_title"])
                if sigs.get("director_name"):
                    safe_set_cell_addr(ws_cover, "E41", sigs["director_name"])
                if sigs.get("director_title"):
                    safe_set_cell_addr(ws_cover, "K40", sigs["director_title"])
            except Exception as e_sig:
                print(f"[WARN] Failed to resolve signatories in sync_cover_sheet_to_excel: {e_sig}")
        try:
            apply_school_address(ws_cover, db_path)
        except Exception as e_addr:
            print(f"[WARN] school address on the cover: {e_addr}")

        # Cover sheet approval date: Term 1 -> year, Term 2 -> year + 1
        date_str = get_approval_date_str(c_term or "1", c_year or "2568")
        safe_set_cell_addr(ws_cover, "E42", date_str)
        try:
            ws_cover["E42"].alignment = openpyxl.styles.Alignment(horizontal="center", vertical="center")
        except Exception:
            pass

        # Inject school / PP5 logo into cover sheet (1) ปกปพ.
        inject_cover_sheet_logo(ws_cover, db_path="school_archive.db")

        # Cross-sheet header injections
        if "(2) เวลาเรียน1" in wb.sheetnames and c_name:
            safe_set_cell_addr(wb["(2) เวลาเรียน1"], "I2", c_name)
        if "(3) เวลาเรียน2" in wb.sheetnames and c_name:
            safe_set_cell_addr(wb["(3) เวลาเรียน2"], "I2", c_name)
        if "(4) รวมคะแนน" in wb.sheetnames:
            if c_name:
                safe_set_cell_addr(wb["(4) รวมคะแนน"], "C2", c_name)
            if c_code:
                safe_set_cell_addr(wb["(4) รวมคะแนน"], "M2", c_code)
            if c_level:
                safe_set_cell_addr(wb["(4) รวมคะแนน"], "M3", c_level)
        if "(5) คุณลักษณะ" in wb.sheetnames:
            if c_name:
                safe_set_cell_addr(wb["(5) คุณลักษณะ"], "D2", c_name)
            if c_code:
                safe_set_cell_addr(wb["(5) คุณลักษณะ"], "L2", c_code)
        if "(6) ตัวชี้วัด" in wb.sheetnames:
            if c_name:
                safe_set_cell_addr(wb["(6) ตัวชี้วัด"], "E1", c_name)
            if c_code:
                safe_set_cell_addr(wb["(6) ตัวชี้วัด"], "I1", c_code)

        save_workbook_atomic(wb, path)
        return True
    except Exception as e:
        print(f"[WARN] Failed to sync cover sheet to {excel_path}: {e}")
        return False


def sync_advisors_to_excel(
    excel_path: Union[str, Path],
    term: str,
    year: str,
    course_code: str,
    class_level: str = ""
) -> bool:
    """Wrapper that calls full sync_cover_sheet_to_excel for backward compatibility."""
    return sync_cover_sheet_to_excel(
        excel_path=excel_path,
        term=term,
        year=year,
        course_code=course_code,
        class_level=class_level
    )


def sync_signatories_to_existing_excels(
    year: str,
    outputs_dir: Union[str, Path] = "outputs",
    db_path: str = "school_archive.db",
    re_export_pdf: bool = False
) -> int:
    """
    Sync newly configured signatories to all existing Excel workbooks for a given year.
    Updating the Excel files updates their modified time (mtime), ensuring that any
    preview or download automatically re-exports the print-ready PDF on demand.
    """
    out_dir = Path(outputs_dir)
    if not out_dir.is_dir():
        return 0

    count = 0
    target_year = str(year).strip()
    for f in out_dir.glob("*.xlsx"):
        if f.name.startswith("~$"):
            continue
        # Only files belonging to this year
        if target_year in f.name:
            try:
                ok = sync_cover_sheet_to_excel(f, year=target_year, db_path=db_path)
                if ok:
                    count += 1
                    if re_export_pdf:
                        pdf_path = f.with_name(f.name.replace("_filled.xlsx", "_print_ready.pdf").replace(".xlsx", ".pdf"))
                        if pdf_path.exists():
                            try:
                                export_excel_to_pdf(str(f), str(pdf_path))
                            except Exception as e_pdf:
                                print(f"[WARN] Failed to re-export PDF {pdf_path}: {e_pdf}")
            except Exception as e:
                print(f"[WARN] Failed to sync cover sheet for {f.name}: {e}")
    return count


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Map SGS JSON or PDF into blank ปพ.5 Excel & export PDF.")
    parser.add_argument("input_path", type=str, help="Path to parsed JSON or SGS PDF file")
    parser.add_argument("-t", "--template", type=str, default="template_ปพ5_blank.xlsx", help="Blank Excel Template path")
    parser.add_argument("-o", "--output-excel", type=str, default=None, help="Output Excel path")
    parser.add_argument("-p", "--output-pdf", type=str, default=None, help="Output PDF path")
    parser.add_argument("--create-blank", action="store_true", help="Generate a fresh blank template from source Excel")
    parser.add_argument("--pipeline", action="store_true", help="Run end-to-end PDF -> DB -> Excel -> PDF pipeline")

    args = parser.parse_args()

    try:
        if args.create_blank:
            blank_file = create_blank_template(args.input_path, args.template)
            print(f"[SUCCESS] Created Blank Template: {blank_file}")
            sys.exit(0)

        in_p = Path(args.input_path)
        if args.pipeline or in_p.suffix.lower() == ".pdf":
            res = process_sgs_pdf(
                str(in_p),
                template_path=args.template,
                output_excel_path=args.output_excel,
                output_pdf_path=args.output_pdf
            )
            print(f"\n[PIPELINE COMPLETED] {res['course_code']} ({res['total_students']} students)")
            print(f"Excel: {res['excel_path']}")
            print(f"PDF:   {res['pdf_path']}")
        else:
            out_xl = map_sgs_to_excel(str(in_p), template_path=args.template, output_excel_path=args.output_excel or "ปพ5_filled.xlsx")
            print(f"[SUCCESS] Populated Excel created: {out_xl}")
            if args.output_pdf:
                out_pdf = export_excel_to_pdf(out_xl, args.output_pdf)
                print(f"[SUCCESS] Print-ready PDF created: {out_pdf}")

    except Exception as e:
        print(f"[ERROR] {str(e)}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)
