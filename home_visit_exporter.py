"""
home_visit_exporter.py - Automated Word (.docx) & PDF Exporter for Home Visit Reports
(แบบรายงานการเยี่ยมบ้านนักเรียน)
"""

import school_profile
import os
import re
import shutil
import subprocess
import datetime
from pathlib import Path
from typing import Dict, Any, List, Optional
import docx
from docx.shared import Inches, Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_ALIGN_VERTICAL
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls, qn
from PIL import Image
import pythainlp

# Default directory paths
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data" / "home_visits"
OUTPUT_DIR = BASE_DIR / "output"
DATA_DIR.mkdir(parents=True, exist_ok=True)
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

THAI_MONTHS = [
    "มกราคม", "กุมภาพันธ์", "มีนาคม", "เมษายน", "พฤษภาคม", "มิถุนายน",
    "กรกฎาคม", "สิงหาคม", "กันยายน", "ตุลาคม", "พฤศจิกายน", "ธันวาคม"
]


def format_thai_date(raw_dt=None) -> str:
    """Format datetime string, date, or None into Thai standard: วันที่ D เดือน Month พ.ศ. Y"""
    if not raw_dt:
        return "วันที่.........เดือน...................พ.ศ.........."
    dt = None
    if isinstance(raw_dt, (datetime.datetime, datetime.date)):
        dt = raw_dt
    else:
        s = str(raw_dt).strip().replace("T", " ")
        if not s or s == "-":
            return "วันที่.........เดือน...................พ.ศ.........."
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
            try:
                dt = datetime.datetime.strptime(s.split(".")[0], fmt)
                break
            except Exception:
                pass
    if not dt:
        return "วันที่.........เดือน...................พ.ศ.........."
    day = dt.day
    month_name = THAI_MONTHS[dt.month - 1]
    be_year = dt.year + 543 if dt.year < 2400 else dt.year
    return f"วันที่ {day} เดือน {month_name} พ.ศ. {be_year}"


def set_cell_border(cell, **kwargs):
    """
    Set cell borders in python-docx table.
    kwargs: top, bottom, left, right (e.g. sz=4, val='single', color='D4AF37')
    """
    tcPr = cell._tc.get_or_add_tcPr()
    tcBorders = parse_xml(r'<w:tcBorders %s/>' % nsdecls('w'))
    for edge in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'):
        edge_data = kwargs.get(edge)
        if edge_data:
            tag = 'w:{}'.format(edge)
            element = parse_xml(r'<%s %s %s/>' % (
                tag,
                nsdecls('w'),
                ' '.join(['w:{}="{}"'.format(k, v) for k, v in edge_data.items()])
            ))
            tcBorders.append(element)
    tcPr.append(tcBorders)


def set_cell_background(cell, color_hex: str):
    """Set background color of a cell (e.g. 'FEF9C3' or 'F3E8FF')."""
    shading_elm = parse_xml(f'<w:shd {nsdecls("w")} w:fill="{color_hex}"/>')
    cell._tc.get_or_add_tcPr().append(shading_elm)


def apply_thai_font(run, font_name="TH Sarabun New", size_pt=14, bold=False, color_rgb=None):
    """Apply Thai-compatible font family and size to a run."""
    run.font.name = font_name
    run.font.size = Pt(size_pt)
    run.bold = bold
    if color_rgb:
        run.font.color.rgb = color_rgb
    rPr = run._r.get_or_add_rPr()
    rFonts = parse_xml(f'<w:rFonts {nsdecls("w")} w:eastAsia="{font_name}" w:cs="{font_name}"/>')
    rPr.append(rFonts)


def apply_thai_distributed(paragraph):
    """
    Apply Thai distributed justification (<w:jc w:val="thaiDistribute"/>)
    to a Word paragraph for optimal Thai text typography.
    """
    pPr = paragraph._p.get_or_add_pPr()
    for existing_jc in pPr.findall(qn('w:jc')):
        pPr.remove(existing_jc)
    jc = parse_xml(r'<w:jc %s w:val="thaiDistribute"/>' % nsdecls('w'))
    pPr.append(jc)


def tokenize_thai_softbreak(text: str) -> str:
    """
    Insert zero-width space (\u200b) at Thai word boundaries using PyThaiNLP
    to enable proper word wrapping in Microsoft Word / LibreOffice without cutting mid-word.
    """
    if not text:
        return ""
    try:
        lines = str(text).split("\n")
        out_lines = []
        for line in lines:
            if not line.strip():
                out_lines.append(line)
                continue
            words = pythainlp.word_tokenize(line, engine="newmm", keep_whitespace=True)
            tok = "\u200b".join(w for w in words if w)
            tok = re.sub(r'\u200b+', '\u200b', tok)
            tok = re.sub(r'\u200b?([ \t]+)\u200b?', r'\1', tok)
            out_lines.append(tok)
        return "\n".join(out_lines)
    except Exception:
        return str(text)


def convert_docx_to_pdf(docx_path: str, pdf_path: Optional[str] = None) -> str:
    """
    Convert a .docx document to .pdf using native Word COM (on Windows)
    with headless LibreOffice fallback.
    """
    in_docx = Path(docx_path).resolve()
    if not in_docx.exists():
        raise FileNotFoundError(f"DOCX not found: {in_docx}")

    out_pdf = Path(pdf_path or in_docx.with_suffix(".pdf")).resolve()
    out_pdf.parent.mkdir(parents=True, exist_ok=True)

    # 1. Try Windows Word COM
    try:
        import win32com.client
        import pythoncom
        pythoncom.CoInitialize()
        word = win32com.client.DispatchEx("Word.Application")
        word.Visible = False
        try:
            doc = word.Documents.Open(str(in_docx))
            # 17 = wdFormatPDF
            doc.SaveAs(str(out_pdf), FileFormat=17)
            doc.Close(SaveChanges=0)
            if out_pdf.exists() and out_pdf.stat().st_size > 0:
                return str(out_pdf)
        finally:
            word.Quit()
            pythoncom.CoUninitialize()
    except Exception as e:
        print(f"[WARN] Word COM conversion failed ({e}), falling back to LibreOffice...")

    # 2. Fallback to LibreOffice
    libreoffice_cmd = shutil.which("soffice") or shutil.which("libreoffice")
    if not libreoffice_cmd:
        candidates = [
            r"C:\Program Files\LibreOffice\program\soffice.exe",
            r"C:\Program Files (x86)\LibreOffice\program\soffice.exe",
        ]
        for c in candidates:
            if Path(c).exists():
                libreoffice_cmd = c
                break

    if libreoffice_cmd:
        try:
            out_dir = str(out_pdf.parent)
            subprocess.run([
                libreoffice_cmd,
                "--headless",
                "--convert-to", "pdf",
                str(in_docx),
                "--outdir", out_dir
            ], check=True, timeout=60)
            gen_pdf = Path(out_dir) / f"{in_docx.stem}.pdf"
            if gen_pdf.exists() and gen_pdf != out_pdf:
                shutil.move(str(gen_pdf), str(out_pdf))
            if out_pdf.exists():
                return str(out_pdf)
        except Exception as err:
            print(f"[WARN] LibreOffice conversion failed: {err}")

    if not out_pdf.exists():
        raise RuntimeError("Could not convert DOCX to PDF. Neither Word COM nor LibreOffice succeeded.")
    return str(out_pdf)


def resize_and_crop_photo(image_path: Path, target_w: int = 800, target_h: int = 600) -> Path:
    """
    Ensure photo has consistent 4:3 landscape ratio and uniform dimensions
    so photos in the document grid are 100% symmetric regardless of orientation.
    """
    try:
        with Image.open(image_path) as img:
            img = img.convert("RGB")
            orig_w, orig_h = img.size
            target_ratio = target_w / target_h
            orig_ratio = orig_w / orig_h

            if orig_ratio > target_ratio:
                # Wider than 4:3: crop left/right
                new_w = int(orig_h * target_ratio)
                left = (orig_w - new_w) // 2
                img = img.crop((left, 0, left + new_w, orig_h))
            else:
                # Taller than 4:3 (e.g. portrait): crop top/bottom
                new_h = int(orig_w / target_ratio)
                top = (orig_h - new_h) // 2
                img = img.crop((0, top, orig_w, top + new_h))

            resized = img.resize((target_w, target_h), Image.Resampling.LANCZOS)
            out_path = image_path.parent / f"norm_{image_path.name}"
            resized.save(out_path, format="JPEG", quality=85)
            return out_path
    except Exception as e:
        print(f"[WARN] Failed to normalize photo {image_path}: {e}")
        return image_path


def format_class_level_num(cl: str) -> str:
    """Strips 'ม.' or 'มัธยมศึกษาปีที่' prefix so 'ม.3' -> '3', 'ม.3/1' -> '3/1', 'ม 1' -> '1'."""
    s = str(cl or "").strip()
    s = re.sub(r"^(?:ระดับชั้น|ระดับ)?\s*(?:มัธยมศึกษาปีที่)?\s*(?:ม\.)?\s*", "", s)
    return s.strip() or s


# -------------------------------------------------------------
# 1. CLASS HOME VISIT REPORT EXPORTER (รายห้อง)
# -------------------------------------------------------------

def generate_class_home_visit_docx(
    report_data: Dict[str, Any],
    school_name: str = "",
    logo_path: Optional[str] = None,
    output_docx_path: Optional[str] = None,
    director_name: Optional[str] = None,
    recorded_by_name: Optional[str] = None,
    advisors_list: Optional[List[str]] = None,
    recorded_date_str: Optional[str] = None,
    frameless: bool = False,
    photo_captions: Optional[Dict[str, str]] = None
) -> str:
    """
    Generate official Class Home Visit Report Word Document (.docx)
    - Page 1: Form Summary (18 Items from Google Form) with Repeating Table Header + Signatures
    - Page 2+: Symmetrical Centered 3-Column Photos Grid (All same uniform size)
    """
    term = str(report_data.get("term", "1")).strip()
    year = str(report_data.get("year", "2569")).strip()
    class_level = str(report_data.get("class_level", "ม.1")).strip()
    advisor_name = str(report_data.get("advisor_name", "")).strip()
    fields = report_data.get("fields", {})
    photos = report_data.get("photos", [])

    doc = docx.Document()

    # Set Margins (2.0 cm / 0.8 in)
    for section in doc.sections:
        section.top_margin = Inches(0.8)
        section.bottom_margin = Inches(0.8)
        section.left_margin = Inches(0.8)
        section.right_margin = Inches(0.8)

    # -------------------------------------------------------------
    # PAGE 1: HEADER & SCHOOL IDENTITY
    # -------------------------------------------------------------
    # 1. School Logo
    if logo_path and Path(logo_path).exists():
        try:
            p_logo = doc.add_paragraph()
            p_logo.alignment = WD_ALIGN_PARAGRAPH.CENTER
            run_logo = p_logo.add_run()
            run_logo.add_picture(str(logo_path), width=Inches(1.1))
            p_logo.paragraph_format.space_after = Pt(4)
        except Exception as e:
            print(f"[WARN] Failed to insert logo: {e}")

    # 2. Main Title
    p_title = doc.add_paragraph()
    p_title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_title.paragraph_format.space_after = Pt(2)
    run_t1 = p_title.add_run("แบบรายงานสรุปผลการเยี่ยมบ้านนักเรียน (รายห้องเรียน)")
    apply_thai_font(run_t1, size_pt=18, bold=True, color_rgb=RGBColor(53, 28, 117))

    # 3. Subtitle
    p_sub = doc.add_paragraph()
    p_sub.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_sub.paragraph_format.space_after = Pt(4)
    run_t2 = p_sub.add_run(f"ครั้งที่ 1 ภาคเรียนที่ {term} ปีการศึกษา {year}\n")
    apply_thai_font(run_t2, size_pt=15, bold=True)
    run_t3 = p_sub.add_run(f"โรงเรียน{school_name or school_profile.short_name()} {school_profile.get('school_area_office')}".strip())
    apply_thai_font(run_t3, size_pt=14, bold=True)

    class_num = format_class_level_num(class_level)

    # 4. Info Banner Box (ระดับชั้น & ครูที่ปรึกษา)
    banner_table = doc.add_table(rows=1, cols=2)
    banner_table.alignment = WD_TABLE_ALIGNMENT.CENTER
    banner_table.autofit = False

    row_b = banner_table.rows[0]
    cell_l = row_b.cells[0]
    cell_r = row_b.cells[1]
    cell_l.width = Inches(2.8)
    cell_r.width = Inches(4.0)

    if not frameless:
        set_cell_background(cell_l, "F5EEDB")
        set_cell_background(cell_r, "F5EEDB")

    cell_l.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
    cell_r.vertical_alignment = WD_ALIGN_VERTICAL.CENTER

    p_l = cell_l.paragraphs[0]
    p_l.paragraph_format.space_after = Pt(2)
    p_l.paragraph_format.space_before = Pt(2)
    r_lvl = p_l.add_run(f" ระดับชั้น: มัธยมศึกษาปีที่ {class_num}")
    apply_thai_font(r_lvl, size_pt=14, bold=True, color_rgb=RGBColor(53, 28, 117) if not frameless else RGBColor(0, 0, 0))

    p_r = cell_r.paragraphs[0]
    p_r.paragraph_format.space_after = Pt(2)
    p_r.paragraph_format.space_before = Pt(2)
    r_adv_title = p_r.add_run("ครูที่ปรึกษา:\n")
    apply_thai_font(r_adv_title, size_pt=13, bold=True, color_rgb=RGBColor(53, 28, 117) if not frameless else RGBColor(0, 0, 0))

    # Parse and list advisors on separate lines with numbered prefix
    adv_list = []
    if advisors_list:
        adv_list = [str(a).strip() for a in advisors_list if str(a).strip()]
    if not adv_list and advisor_name:
        for part in advisor_name.replace("\r", "").split("\n"):
            for sub in part.split(","):
                s = sub.strip()
                if s and s not in adv_list:
                    adv_list.append(s)

    if adv_list:
        for idx, adv in enumerate(adv_list, start=1):
            line = f"{idx}. {adv}" + ("\n" if idx < len(adv_list) else "")
            r_adv = p_r.add_run(line)
            apply_thai_font(r_adv, size_pt=12.5, bold=False)
    else:
        r_adv = p_r.add_run("1. ..................................................")
        apply_thai_font(r_adv, size_pt=12.5, bold=False)

    if not frameless:
        for c in (cell_l, cell_r):
            set_cell_border(c, top={"val": "single", "sz": "6", "color": "D4AF37"},
                               bottom={"val": "single", "sz": "6", "color": "D4AF37"})

    doc.add_paragraph().paragraph_format.space_after = Pt(4)

    # -------------------------------------------------------------
    # 5. DATA TABLE (18 รายการ) with REPEATING HEADER ROW
    # -------------------------------------------------------------
    data_items = [
        ("1. จำนวนนักเรียนที่ออกเยี่ยมบ้าน", fields.get("1. จำนวนนักเรียนที่ออกเยี่ยมบ้าน (คน)", "0"), "คน"),
        ("   1.1 ชาย", fields.get("1.1 ชาย (คน)", "0"), "คน"),
        ("   1.2 หญิง", fields.get("1.2 หญิง (คน)", "0"), "คน"),
        ("2. จำนวนนักเรียนที่ไม่ได้ออกเยี่ยมบ้าน", fields.get("2. จำนวนนักเรียนที่ไม่ได้ออกเยี่ยมบ้าน (คน)", "0"), "คน"),
        ("3. สาเหตุที่ไม่ได้ออกเยี่ยมบ้าน", fields.get("3. สาเหตุที่ไม่ได้ออกเยี่ยมบ้าน", "-") or "-", ""),
        ("4. ครอบครัวอบอุ่น", fields.get("4. ครอบครัวอบอุ่น (คน)", "0"), "คน"),
        ("5. ครอบครัวแตกแยก", fields.get("5. ครอบครัวแตกแยก (คน)", "0"), "คน"),
        ("6. นักเรียนที่บิดาและมารดาเสียชีวิต", fields.get("6. นักเรียนที่บิดาและมารดาเสียชีวิต (คน)", "0"), "คน"),
        ("7. นักเรียนที่บิดาหรือมารดาเสียชีวิต", fields.get("7. นักเรียนที่บิดาหรือมารดาเสียชีวิต (คน)", "0"), "คน"),
        ("8. นักเรียนที่บิดาหรือมารดาเลิกร้างกัน", fields.get("8. นักเรียนที่บิดาหรือมารดาเลิกร้างกัน (คน)", "0"), "คน"),
        ("9. นักเรียนไม่ได้อาศัยกับบิดาหรือมารดาตนเอง", fields.get("9. นักเรียนไม่ได้อาศัยกับบิดาหรือมารดาของตนเอง (คน)", "0"), "คน"),
        ("10. นักเรียนเสี่ยงหรือมีปัญหาด้านการเรียน", fields.get("10. นักเรียนเสี่ยงหรือมีปัญหาด้านการเรียน (คน)", "0"), "คน"),
        ("11. นักเรียนมีปัญหาด้านสุขภาพ", fields.get("11. นักเรียนมีปัญหาด้านสุขภาพ (คน)", "0"), "คน"),
        ("12. นักเรียนมีพฤติกรรมเสี่ยง", fields.get("12. นักเรียนมีพฤติกรรมเสี่ยง (คน)", "0"), "คน"),
        ("   12.1 เสี่ยงด้านสุขภาพ", fields.get("12.1 เสี่ยงด้านสุขภาพ (คน)", "0"), "คน"),
        ("   12.2 เสี่ยงด้านการใช้สารเสพติด", fields.get("12.2 เสี่ยงด้านการใช้สารเสพติด (คน)", "0"), "คน"),
        ("   12.3 เสี่ยงด้านความรุนแรง", fields.get("12.3 เสี่ยงด้านความรุนแรง", "0"), "คน"),
        ("   12.4 เสี่ยงด้านการเดินทางมาเรียน", fields.get("12.4 เสี่ยงด้านการเดินทางมาเรียน", "0"), "คน"),
        ("   12.5 เสี่ยงด้านเพศ", fields.get("12.5 เสี่ยงด้านเพศ", "0"), "คน"),
        ("   12.6 เสี่ยงติดเกม", fields.get("12.6 เสี่ยงติดเกม", "0"), "คน"),
        ("   12.7 เสี่ยงด้านอื่นๆ", fields.get("12.7 เสี่ยงด้านอื่นๆ (โปรดระบุ)", "-") or "-", ""),
        ("13. นักเรียนมีปัญหาด้านเศรษฐกิจ", fields.get("13. นักเรียนมีปัญหาด้านเศรษฐกิจ (คน)", "0"), "คน"),
        ("14. นักเรียนมีปัญหาอื่นๆ", fields.get("14. นักเรียนมีปัญหาอื่นๆ (คน)", "0"), "คน"),
        ("   14.1 ระบุปัญหาที่พบ", fields.get("14.1 ระบุปัญหาที่พบ", "-") or "-", ""),
        ("15. นักเรียนที่ต้องได้รับการช่วยเหลือเร่งด่วน", fields.get("15. นักเรียนที่ต้องได้รับการช่วยเหลือเร่งด่วน (คน)", "0"), "คน"),
        ("16. หน่วยงาน/สหวิชาชีพ/องค์กร ที่ร่วมเยี่ยมบ้าน", fields.get("16. หน่วยงาน/สหวิชาชีพ/องค์กร ที่ร่วมเยี่ยมบ้าน", "-") or "-", ""),
        ("17. การนำข้อมูลเยี่ยมบ้านไปใช้ประโยชน์", fields.get("17. การนำข้อมูลเยี่ยมบ้านไปใช้ประโยชน์อย่างไร", "-") or "-", ""),
        ("18. ข้อห่วงใยของผู้ปกครองที่มีต่อนักเรียน", fields.get("18. ข้อห่วงใยของผู้ปกครองที่มีต่อนักเรียน", "-") or "-", ""),
    ]

    table = doc.add_table(rows=len(data_items) + 1, cols=3)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False

    # Header Row
    hdr_cells = table.rows[0].cells
    hdr_cells[0].width = Inches(3.4)
    hdr_cells[1].width = Inches(2.2)
    hdr_cells[2].width = Inches(1.0)

    hdr_titles = ["รายการ / หัวข้อการสำรวจ", "ข้อมูลที่พบ", "หน่วย"]
    for idx, name in enumerate(hdr_titles):
        if not frameless:
            set_cell_background(hdr_cells[idx], "351C75")
        p = hdr_cells[idx].paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(3)
        p.paragraph_format.space_after = Pt(3)
        r = p.add_run(name)
        apply_thai_font(r, size_pt=13, bold=True, color_rgb=RGBColor(250, 204, 21) if not frameless else RGBColor(0, 0, 0))

    # Repeat header row on every new page!
    hdr_tr = table.rows[0]._tr.get_or_add_trPr()
    hdr_tr.append(parse_xml(f'<w:tblHeader {nsdecls("w")}/>'))

    # Prevent table rows from splitting across page breaks
    for r_obj in table.rows:
        trPr = r_obj._tr.get_or_add_trPr()
        trPr.append(parse_xml(f'<w:cantSplit {nsdecls("w")}/>'))

    # Content Rows
    for row_idx, (q_title, val, unit) in enumerate(data_items, start=1):
        cells = table.rows[row_idx].cells
        cells[0].width = Inches(3.4)
        cells[1].width = Inches(2.2)
        cells[2].width = Inches(1.0)

        # Subtle zebra striping
        if not frameless and row_idx % 2 == 1:
            set_cell_background(cells[0], "FCFAF2")
            set_cell_background(cells[1], "FCFAF2")
            set_cell_background(cells[2], "FCFAF2")

        # Question title
        p0 = cells[0].paragraphs[0]
        p0.paragraph_format.space_before = Pt(1.5)
        p0.paragraph_format.space_after = Pt(1.5)
        is_sub = q_title.startswith("   ")
        is_bold_header = not is_sub and any(q_title.startswith(f"{x}.") for x in ("1", "2", "3", "12", "14", "16", "17", "18"))
        tok_q_title = tokenize_thai_softbreak(q_title)
        r0 = p0.add_run(tok_q_title)
        apply_thai_font(r0, size_pt=12.5, bold=is_bold_header, color_rgb=RGBColor(30, 20, 60) if is_bold_header else None)

        val_str = str(val).strip()
        unit_str = str(unit).strip()

        # Value & Unit
        is_text_type = not unit_str
        is_narrative = is_text_type and val_str not in ("-", "", "ไม่มี", "ไม่พบ")

        if is_narrative:
            # Narrative text item: merge Col 1 & Col 2 for wider text area
            merged_val_cell = cells[1].merge(cells[2])
            lines = [l.strip() for l in val_str.split("\n") if l.strip()]
            for l_idx, line in enumerate(lines):
                c_text = re.sub(r'^[-\u00a0\s]+', '', line)
                tok = tokenize_thai_softbreak(c_text)

                p = merged_val_cell.paragraphs[0] if l_idx == 0 else merged_val_cell.add_paragraph()
                p.paragraph_format.space_before = Pt(1.5)
                p.paragraph_format.space_after = Pt(1.5)
                p.paragraph_format.line_spacing = 1.15
                # Hanging indent: locks '-' bullet cleanly at left margin and tabs to text (Option A standard)
                p.paragraph_format.left_indent = Inches(0.28)
                p.paragraph_format.first_line_indent = Inches(-0.28)

                r_b = p.add_run("-\t")
                apply_thai_font(r_b, size_pt=11.5)
                r_t = p.add_run(tok)
                apply_thai_font(r_t, size_pt=11.5)
                apply_thai_distributed(p)
        else:
            # Numbers or '-' symbol: Keep Col 1 and Col 2 separate so '-' aligns with numbers in Col 1
            p1 = cells[1].paragraphs[0]
            p1.paragraph_format.space_before = Pt(1.5)
            p1.paragraph_format.space_after = Pt(1.5)
            p1.alignment = WD_ALIGN_PARAGRAPH.CENTER
            display_val = "-" if val_str in ("-", "", "ไม่มี", "ไม่พบ") else val_str
            r1 = p1.add_run(display_val)
            apply_thai_font(
                r1,
                size_pt=12.5,
                bold=True if val_str not in ("0", "-", "", "ไม่มี", "ไม่พบ") else False,
                color_rgb=RGBColor(21, 128, 61) if val_str not in ("0", "-", "", "ไม่มี", "ไม่พบ") and unit_str else None
            )

            # Unit
            p2 = cells[2].paragraphs[0]
            p2.paragraph_format.space_before = Pt(1.5)
            p2.paragraph_format.space_after = Pt(1.5)
            p2.alignment = WD_ALIGN_PARAGRAPH.CENTER
            r2 = p2.add_run(unit_str if val_str not in ("-", "", "ไม่มี", "ไม่พบ") else (unit_str or ""))
            apply_thai_font(r2, size_pt=12)
            apply_thai_font(r2, size_pt=12)

        # Subtle border (omit if frameless)
        if not frameless:
            for c in cells:
                set_cell_border(c,
                    top={"val": "single", "sz": "4", "color": "E5E7EB"},
                    bottom={"val": "single", "sz": "4", "color": "E5E7EB"},
                    left={"val": "single", "sz": "4", "color": "E5E7EB"},
                    right={"val": "single", "sz": "4", "color": "E5E7EB"}
                )

    # -------------------------------------------------------------
    # 6. SIGN-OFF SIGNATURES (ตามจำนวนครูประจำชั้น และผู้อำนวยการ)
    # -------------------------------------------------------------
    doc.add_paragraph().paragraph_format.space_after = Pt(10)

    # Clean advisors list for signatures
    adv_signs = []
    if adv_list:
        adv_signs = [a.strip() for a in adv_list if a.strip()]
    if not adv_signs:
        name_fallback = recorded_by_name or report_data.get("recorded_by_name") or advisor_name or "......................................................."
        adv_signs = [name_fallback]

    # School Director name
    director_sign_name = (director_name or ".......................................................").strip()

    # Form submission date formatted in Thai
    raw_date = recorded_date_str or report_data.get("recorded_at") or report_data.get("updated_at")
    date_thai = format_thai_date(raw_date) if raw_date else "วันที่.........เดือน...................พ.ศ.........."

    num_adv = len(adv_signs)

    if num_adv >= 3:
        # กรณีครู 3 คน: จัดวาง 3 คนในบรรทัดเดียวกัน ผู้อำนวยการอยู่บรรทัดถัดไปตรงกับคนที่ 2 (ตรงกลาง)
        t_table = doc.add_table(rows=1, cols=3)
        t_table.alignment = WD_TABLE_ALIGNMENT.CENTER
        t_table.autofit = False
        col_w = Inches(2.26)

        for idx in range(3):
            cell = t_table.rows[0].cells[idx]
            cell.width = col_w
            p = cell.paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            adv_name = adv_signs[idx] if idx < len(adv_signs) else "............................................"
            r = p.add_run(
                "ลงชื่อ............................................\n"
                f"({adv_name})\n"
                "ครูประจำชั้น / ครูที่ปรึกษา\n"
                f"{date_thai}"
            )
            apply_thai_font(r, size_pt=11.5)

        # Spacing
        p_sp = doc.add_paragraph()
        p_sp.paragraph_format.space_before = Pt(8)
        p_sp.paragraph_format.space_after = Pt(2)

        # Director row aligned with Column 2 (center column)
        d_table = doc.add_table(rows=1, cols=3)
        d_table.alignment = WD_TABLE_ALIGNMENT.CENTER
        d_table.autofit = False
        for idx in range(3):
            d_table.rows[0].cells[idx].width = col_w

        p_dir = d_table.rows[0].cells[1].paragraphs[0]
        p_dir.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r_dir = p_dir.add_run(
            "ลงชื่อ............................................\n"
            f"({director_sign_name})\n"
            f"ผู้อำนวยการโรงเรียน{school_name}\n"
            f"{date_thai}"
        )
        apply_thai_font(r_dir, size_pt=11.5)

        for tbl in (t_table, d_table):
            for r_elm in tbl.rows:
                r_elm._tr.get_or_add_trPr().append(parse_xml(f'<w:cantSplit {nsdecls("w")}/>'))

    elif num_adv == 2:
        # กรณีครู 2 คน: จัดวาง 2 คนในบรรทัดเดียวกัน ผู้อำนวยการอยู่บรรทัดถัดไปจัดกึ่งกลาง
        t_table = doc.add_table(rows=1, cols=2)
        t_table.alignment = WD_TABLE_ALIGNMENT.CENTER
        t_table.autofit = False
        col_w = Inches(3.4)

        for idx in range(2):
            cell = t_table.rows[0].cells[idx]
            cell.width = col_w
            p = cell.paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            adv_name = adv_signs[idx]
            r = p.add_run(
                "ลงชื่อ.......................................................\n"
                f"({adv_name})\n"
                "ครูประจำชั้น / ครูที่ปรึกษา\n"
                f"{date_thai}"
            )
            apply_thai_font(r, size_pt=12.5)

        # Spacing
        p_sp = doc.add_paragraph()
        p_sp.paragraph_format.space_before = Pt(8)
        p_sp.paragraph_format.space_after = Pt(2)

        # Director row centered
        d_table = doc.add_table(rows=1, cols=1)
        d_table.alignment = WD_TABLE_ALIGNMENT.CENTER
        d_table.autofit = False
        d_table.rows[0].cells[0].width = Inches(3.6)

        p_dir = d_table.rows[0].cells[0].paragraphs[0]
        p_dir.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r_dir = p_dir.add_run(
            "ลงชื่อ.......................................................\n"
            f"({director_sign_name})\n"
            f"ผู้อำนวยการโรงเรียน{school_name}\n"
            f"{date_thai}"
        )
        apply_thai_font(r_dir, size_pt=12.5)

        for tbl in (t_table, d_table):
            for r_elm in tbl.rows:
                r_elm._tr.get_or_add_trPr().append(parse_xml(f'<w:cantSplit {nsdecls("w")}/>'))

    else:
        # กรณีครู 1 คน: ครู 1 คน บรรทัดถัดไปผู้อำนวยการจัดกึ่งกลาง
        t_table = doc.add_table(rows=1, cols=1)
        t_table.alignment = WD_TABLE_ALIGNMENT.CENTER
        t_table.autofit = False
        t_table.rows[0].cells[0].width = Inches(3.6)

        adv_name = adv_signs[0] if adv_signs else "......................................................."
        p = t_table.rows[0].cells[0].paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r = p.add_run(
            "ลงชื่อ.......................................................\n"
            f"({adv_name})\n"
            "ครูประจำชั้น / ครูที่ปรึกษา\n"
            f"{date_thai}"
        )
        apply_thai_font(r, size_pt=12.5)

        p_sp = doc.add_paragraph()
        p_sp.paragraph_format.space_before = Pt(8)
        p_sp.paragraph_format.space_after = Pt(2)

        d_table = doc.add_table(rows=1, cols=1)
        d_table.alignment = WD_TABLE_ALIGNMENT.CENTER
        d_table.autofit = False
        d_table.rows[0].cells[0].width = Inches(3.6)

        p_dir = d_table.rows[0].cells[0].paragraphs[0]
        p_dir.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r_dir = p_dir.add_run(
            "ลงชื่อ.......................................................\n"
            f"({director_sign_name})\n"
            f"ผู้อำนวยการโรงเรียน{school_name}\n"
            f"{date_thai}"
        )
        apply_thai_font(r_dir, size_pt=12.5)

        for tbl in (t_table, d_table):
            for r_elm in tbl.rows:
                r_elm._tr.get_or_add_trPr().append(parse_xml(f'<w:cantSplit {nsdecls("w")}/>'))

    # -------------------------------------------------------------
    # PAGE 2: SYMMETRICAL CENTERED 3-COLUMN PHOTOS GRID (ภาพกิจกรรมการเยี่ยมบ้าน)
    # -------------------------------------------------------------
    if photos:
        doc.add_page_break()

        p_ph_hdr = doc.add_paragraph()
        p_ph_hdr.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p_ph_hdr.paragraph_format.space_after = Pt(2)
        p_ph_hdr.paragraph_format.space_before = Pt(4)
        r_ph1 = p_ph_hdr.add_run(f"ภาพกิจกรรมการเยี่ยมบ้านนักเรียน ระดับชั้นมัธยมศึกษาปีที่ {class_num}")
        apply_thai_font(r_ph1, size_pt=18, bold=True, color_rgb=RGBColor(53, 28, 117) if not frameless else RGBColor(0, 0, 0))

        p_ph_sub = doc.add_paragraph()
        p_ph_sub.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p_ph_sub.paragraph_format.space_after = Pt(14)
        r_ph2 = p_ph_sub.add_run(f"ภาคเรียนที่ {term} ปีการศึกษา {year} โรงเรียน{school_name or school_profile.short_name()} {school_profile.get('school_area_short')}".strip())
        apply_thai_font(r_ph2, size_pt=13.5, bold=True)

        def get_photo_caption(p_i: int, p_name: str) -> str:
            c = ""
            if photo_captions:
                c = photo_captions.get(p_name) or photo_captions.get(str(p_i + 1)) or photo_captions.get(str(p_i)) or ""
            c = str(c or "").strip()
            if not c:
                c = f"ภาพที่ {p_i + 1}: การเยี่ยมบ้านนักเรียน"
            return c

        if frameless:
            # Word แบบไม่มีกรอบ (จัดหน้าอิสระ):
            # แทรกรูปภาพและคำอธิบายลงใน Paragraph ปกติโดยตรง ไม่ครอบด้วยตารางหรือเส้นขอบใดๆ
            # เพื่อให้คุณครูสามารถคลิกเลือกรูปภาพ เปลี่ยน Wrap Text (เช่น ลอยเหนือข้อความ / จัตุรัส) และขยับปรับตำแหน่งได้อย่างอิสระใน Word
            for p_idx, photo_name in enumerate(photos):
                photo_abs = DATA_DIR / f"{year}_{term}" / class_level / photo_name
                if not photo_abs.exists():
                    continue
                cap_text = get_photo_caption(p_idx, photo_name)
                try:
                    norm_photo = resize_and_crop_photo(photo_abs, target_w=800, target_h=600)
                    p_img = doc.add_paragraph()
                    p_img.alignment = WD_ALIGN_PARAGRAPH.CENTER
                    p_img.paragraph_format.space_before = Pt(8)
                    p_img.paragraph_format.space_after = Pt(2)
                    r_img = p_img.add_run()
                    r_img.add_picture(str(norm_photo), width=Inches(3.2))

                    p_cap = doc.add_paragraph()
                    p_cap.alignment = WD_ALIGN_PARAGRAPH.CENTER
                    p_cap.paragraph_format.space_before = Pt(2)
                    p_cap.paragraph_format.space_after = Pt(14)
                    r_cap = p_cap.add_run(cap_text)
                    apply_thai_font(r_cap, size_pt=12, bold=False, color_rgb=RGBColor(0, 0, 0))
                except Exception as e:
                    print(f"[WARN] Failed inserting frameless photo {photo_abs}: {e}")
        else:
            # Build Symmetrical 3-Column Grid Table (บรรทัดละ 3 รูป แบบสมมาตร ขนาดเท่ากันทุกแนว พร้อมกรอบทอง)
            num_photos = len(photos)
            num_rows = (num_photos + 2) // 3

            photo_table = doc.add_table(rows=num_rows * 2, cols=3)
            photo_table.alignment = WD_TABLE_ALIGNMENT.CENTER
            photo_table.autofit = False

            col_w = Inches(2.22)
            img_w = Inches(2.10)
            img_h = Inches(1.575)  # 4:3 ratio: 2.10 * 3 / 4 = 1.575 in

            for r_idx in range(num_rows):
                img_row = photo_table.rows[r_idx * 2]
                cap_row = photo_table.rows[r_idx * 2 + 1]

                for r_obj in (img_row, cap_row):
                    r_obj._tr.get_or_add_trPr().append(parse_xml(f'<w:cantSplit {nsdecls("w")}/>'))

                for c_idx in range(3):
                    p_idx = r_idx * 3 + c_idx
                    cell_img = img_row.cells[c_idx]
                    cell_cap = cap_row.cells[c_idx]

                    cell_img.width = col_w
                    cell_cap.width = col_w
                    cell_img.vertical_alignment = WD_ALIGN_VERTICAL.CENTER

                    if p_idx < num_photos:
                        set_cell_border(cell_img,
                            top={"val": "single", "sz": "6", "color": "D4AF37"},
                            bottom={"val": "single", "sz": "4", "color": "E5E7EB"},
                            left={"val": "single", "sz": "6", "color": "D4AF37"},
                            right={"val": "single", "sz": "6", "color": "D4AF37"}
                        )
                        set_cell_border(cell_cap,
                            bottom={"val": "single", "sz": "6", "color": "D4AF37"},
                            left={"val": "single", "sz": "6", "color": "D4AF37"},
                            right={"val": "single", "sz": "6", "color": "D4AF37"}
                        )
                        set_cell_background(cell_img, "FAFAF9")
                        set_cell_background(cell_cap, "FBF4E2")

                        photo_name = photos[p_idx]
                        photo_abs = DATA_DIR / f"{year}_{term}" / class_level / photo_name
                        if photo_abs.exists():
                            try:
                                # Normalize photo to uniform 4:3 landscape ratio for perfect symmetry
                                norm_photo = resize_and_crop_photo(photo_abs, target_w=800, target_h=600)
                                p_cell = cell_img.paragraphs[0]
                                p_cell.alignment = WD_ALIGN_PARAGRAPH.CENTER
                                p_cell.paragraph_format.space_before = Pt(3)
                                p_cell.paragraph_format.space_after = Pt(3)
                                r_img = p_cell.add_run()
                                r_img.add_picture(str(norm_photo), width=img_w, height=img_h)
                            except Exception as e:
                                print(f"[WARN] Failed inserting photo {photo_abs}: {e}")

                        # Caption row
                        cap_text = get_photo_caption(p_idx, photo_name)
                        p_cap = cell_cap.paragraphs[0]
                        p_cap.alignment = WD_ALIGN_PARAGRAPH.CENTER
                        p_cap.paragraph_format.space_before = Pt(2)
                        p_cap.paragraph_format.space_after = Pt(3)
                        r_cap = p_cap.add_run(cap_text)
                        apply_thai_font(r_cap, size_pt=10.5, bold=True, color_rgb=RGBColor(69, 26, 3))

    # Save output DOCX
    suffix = "_ไม่มีกรอบ" if frameless else ""
    out_file = output_docx_path or str(OUTPUT_DIR / f"แบบรายงานเยี่ยมบ้าน_{class_level}_{year}_เทอม{term}{suffix}.docx")
    doc.save(out_file)
    return out_file


# -------------------------------------------------------------
# 2. SCHOOL-WIDE HOME VISIT SUMMARY EXPORTER (รายงานสรุปภาพรวมโรงเรียน)
# -------------------------------------------------------------

def generate_school_summary_docx(
    summary_data: Dict[str, Any],
    school_name: str = "",
    logo_path: Optional[str] = None,
    output_docx_path: Optional[str] = None,
    director_name: Optional[str] = None,
    recorded_date_str: Optional[str] = None,
    frameless: bool = False
) -> str:
    """
    Generate official School-wide Home Visit Summary Report Word Document (.docx)
    Displays comparison table across all classes (ม.1 - ม.6) + School Totals.
    """
    term = str(summary_data.get("term", "1")).strip()
    year = str(summary_data.get("year", "2569")).strip()
    summary = summary_data.get("summary", {})
    classes = summary_data.get("classes", [])

    doc = docx.Document()
    for section in doc.sections:
        section.top_margin = Inches(0.8)
        section.bottom_margin = Inches(0.8)
        section.left_margin = Inches(0.8)
        section.right_margin = Inches(0.8)

    # 1. School Logo
    if logo_path and Path(logo_path).exists():
        try:
            p_logo = doc.add_paragraph()
            p_logo.alignment = WD_ALIGN_PARAGRAPH.CENTER
            run_logo = p_logo.add_run()
            run_logo.add_picture(str(logo_path), width=Inches(1.1))
            p_logo.paragraph_format.space_after = Pt(4)
        except Exception as e:
            print(f"[WARN] Failed inserting logo in summary: {e}")

    # 2. Title
    p_title = doc.add_paragraph()
    p_title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_title.paragraph_format.space_after = Pt(2)
    r_t1 = p_title.add_run("แบบสรุปรายงานผลการเยี่ยมบ้านนักเรียน (ภาพรวมระดับโรงเรียน)")
    apply_thai_font(r_t1, size_pt=18, bold=True, color_rgb=RGBColor(53, 28, 117))

    p_sub = doc.add_paragraph()
    p_sub.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_sub.paragraph_format.space_after = Pt(8)
    r_t2 = p_sub.add_run(f"ครั้งที่ 1 ภาคเรียนที่ {term} ปีการศึกษา {year}\n")
    apply_thai_font(r_t2, size_pt=15, bold=True)
    r_t3 = p_sub.add_run(f"โรงเรียน{school_name or school_profile.short_name()} {school_profile.get('school_area_office')}".strip())
    apply_thai_font(r_t3, size_pt=14, bold=True)

    # 3. Overall 4 Stat Summary Cards
    stat_table = doc.add_table(rows=1, cols=4)
    stat_table.alignment = WD_TABLE_ALIGNMENT.CENTER
    stat_table.autofit = False

    stat_cards = [
        ("นักเรียนทั้งหมด", f"{summary.get('total_students', 0)} คน", "581C87"),
        ("ออกเยี่ยมบ้านแล้ว", f"{summary.get('total_visited', 0)} คน", "15803D"),
        ("คิดเป็นร้อยละ", f"{summary.get('average_percentage', 0)}%", "D97706"),
        ("ยังไม่ได้ออกเยี่ยม", f"{summary.get('total_not_visited', 0)} คน", "DC2626"),
    ]

    for idx, (label, val, hex_col) in enumerate(stat_cards):
        cell = stat_table.rows[0].cells[idx]
        cell.width = Inches(1.7)
        if not frameless:
            set_cell_background(cell, "F5EEDB")
            set_cell_border(cell,
                top={"val": "single", "sz": "6", "color": "D4AF37"},
                bottom={"val": "single", "sz": "6", "color": "D4AF37"},
                left={"val": "single", "sz": "6", "color": "D4AF37"},
                right={"val": "single", "sz": "6", "color": "D4AF37"}
            )
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(4)
        p.paragraph_format.space_after = Pt(2)
        r_l = p.add_run(f"{label}\n")
        apply_thai_font(r_l, size_pt=12, bold=False, color_rgb=RGBColor(75, 85, 99))
        r_v = p.add_run(val)
        c_rgb = RGBColor(int(hex_col[:2], 16), int(hex_col[2:4], 16), int(hex_col[4:], 16))
        apply_thai_font(r_v, size_pt=16, bold=True, color_rgb=c_rgb)

    doc.add_paragraph().paragraph_format.space_after = Pt(8)

    # 4. Class Breakdown Table
    table = doc.add_table(rows=len(classes) + 2, cols=7)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False

    # Repeat header row on every page
    hdr_tr = table.rows[0]._tr.get_or_add_trPr()
    hdr_tr.append(parse_xml(f'<w:tblHeader {nsdecls("w")}/>'))

    col_widths = [Inches(0.9), Inches(2.2), Inches(0.8), Inches(0.9), Inches(0.8), Inches(0.9), Inches(0.6)]
    hdr_titles = ["ระดับชั้น", "ครูที่ปรึกษา", "จำนวน", "เยี่ยมแล้ว", "ร้อยละ", "ยังไม่เยี่ยม", "รูปถ่าย"]

    for idx, name in enumerate(hdr_titles):
        c = table.rows[0].cells[idx]
        c.width = col_widths[idx]
        if not frameless:
            set_cell_background(c, "351C75")
        p = c.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(3)
        p.paragraph_format.space_after = Pt(3)
        r = p.add_run(name)
        apply_thai_font(r, size_pt=12, bold=True, color_rgb=RGBColor(250, 204, 21) if not frameless else RGBColor(0, 0, 0))

    for r_idx, c_info in enumerate(classes, start=1):
        cells = table.rows[r_idx].cells
        for idx in range(7):
            cells[idx].width = col_widths[idx]
            if not frameless and r_idx % 2 == 1:
                set_cell_background(cells[idx], "FCFAF2")

        row_vals = [
            c_info.get("class_level", ""),
            c_info.get("advisor_name", "-") or "-",
            f"{c_info.get('student_count', 0)}",
            f"{c_info.get('visited_count', 0)}",
            f"{c_info.get('percentage', 0)}%",
            f"{c_info.get('not_visited_count', 0)}",
            f"{c_info.get('photos_count', 0)}",
        ]

        for idx, val in enumerate(row_vals):
            p = cells[idx].paragraphs[0]
            p.paragraph_format.space_before = Pt(2)
            p.paragraph_format.space_after = Pt(2)
            p.alignment = WD_ALIGN_PARAGRAPH.LEFT if idx == 1 else WD_ALIGN_PARAGRAPH.CENTER
            r = p.add_run(val)
            apply_thai_font(r, size_pt=12, bold=True if idx in (0, 3, 4) else False)

        if not frameless:
            for cell in cells:
                set_cell_border(cell,
                    top={"val": "single", "sz": "4", "color": "E5E7EB"},
                    bottom={"val": "single", "sz": "4", "color": "E5E7EB"},
                    left={"val": "single", "sz": "4", "color": "E5E7EB"},
                    right={"val": "single", "sz": "4", "color": "E5E7EB"}
                )

    # Total Row
    tot_row_idx = len(classes) + 1
    tot_cells = table.rows[tot_row_idx].cells
    for idx in range(7):
        tot_cells[idx].width = col_widths[idx]
        if not frameless:
            set_cell_background(tot_cells[idx], "F5EEDB")

    tot_vals = [
        "รวมทั้งโรงเรียน",
        "6 ระดับชั้น",
        str(summary.get("total_students", 0)),
        f"{summary.get('total_visited', 0)} คน",
        f"{summary.get('average_percentage', 0)}%",
        f"{summary.get('total_not_visited', 0)} คน",
        f"{sum(c.get('photos_count', 0) for c in classes)} รูป",
    ]

    for idx, val in enumerate(tot_vals):
        p = tot_cells[idx].paragraphs[0]
        p.paragraph_format.space_before = Pt(3)
        p.paragraph_format.space_after = Pt(3)
        p.alignment = WD_ALIGN_PARAGRAPH.LEFT if idx == 1 else WD_ALIGN_PARAGRAPH.CENTER
        r = p.add_run(val)
        apply_thai_font(r, size_pt=12.5, bold=True, color_rgb=RGBColor(53, 28, 117) if not frameless else RGBColor(0, 0, 0))

    if not frameless:
        for cell in tot_cells:
            set_cell_border(cell,
                top={"val": "single", "sz": "6", "color": "D4AF37"},
                bottom={"val": "single", "sz": "6", "color": "D4AF37"},
                left={"val": "single", "sz": "6", "color": "D4AF37"},
                right={"val": "single", "sz": "6", "color": "D4AF37"}
            )

    for r_obj in table.rows:
        r_obj._tr.get_or_add_trPr().append(parse_xml(f'<w:cantSplit {nsdecls("w")}/>'))

    # -------------------------------------------------------------
    # 5. SCREENING DATA SUMMARY (รวมทุกระดับชั้น)
    # -------------------------------------------------------------
    doc.add_page_break()

    p_sc_title = doc.add_paragraph()
    p_sc_title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_sc_title.paragraph_format.space_before = Pt(4)
    p_sc_title.paragraph_format.space_after = Pt(2)
    r_sct = p_sc_title.add_run("ตารางสรุปผลการคัดกรองข้อมูลนักเรียนจากการเยี่ยมบ้าน (รวมทุกระดับชั้น)")
    apply_thai_font(r_sct, size_pt=16, bold=True, color_rgb=RGBColor(53, 28, 117))

    p_sc_sub = doc.add_paragraph()
    p_sc_sub.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_sc_sub.paragraph_format.space_after = Pt(8)
    r_scsub = p_sc_sub.add_run(f"โรงเรียน{school_name} ครั้งที่ 1 ภาคเรียนที่ {term} ปีการศึกษา {year}")
    apply_thai_font(r_scsub, size_pt=13, bold=False, color_rgb=RGBColor(75, 85, 99))

    screening_totals = summary_data.get("screening_totals", [])
    if not screening_totals:
        try:
            from database import HOME_VISIT_SCREENING_ITEMS
            screening_totals = []
            for item in HOME_VISIT_SCREENING_ITEMS:
                screening_totals.append({
                    "num": item["num"],
                    "key": item["key"],
                    "label": item["label"],
                    "value": "0" if item["type"] == "number" else "-",
                    "unit": item["unit"],
                    "type": item["type"],
                    "is_sub": item.get("is_sub", False)
                })
        except Exception:
            screening_totals = []

    if screening_totals:
        sc_table = doc.add_table(rows=len(screening_totals) + 1, cols=3)
        sc_table.alignment = WD_TABLE_ALIGNMENT.CENTER
        sc_table.autofit = False

        # Header
        sc_hdr_cells = sc_table.rows[0].cells
        sc_hdr_cells[0].width = Inches(3.4)
        sc_hdr_cells[1].width = Inches(2.2)
        sc_hdr_cells[2].width = Inches(1.0)

        sc_hdr_titles = ["รายการ / หัวข้อการคัดกรอง", "ข้อมูลรวมทั้งโรงเรียน", "หน่วย"]
        for idx, name in enumerate(sc_hdr_titles):
            if not frameless:
                set_cell_background(sc_hdr_cells[idx], "351C75")
            p = sc_hdr_cells[idx].paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p.paragraph_format.space_before = Pt(3)
            p.paragraph_format.space_after = Pt(3)
            r = p.add_run(name)
            apply_thai_font(r, size_pt=13, bold=True, color_rgb=RGBColor(250, 204, 21) if not frameless else RGBColor(0, 0, 0))

        # Repeat header row on every new page!
        sc_hdr_tr = sc_table.rows[0]._tr.get_or_add_trPr()
        sc_hdr_tr.append(parse_xml(f'<w:tblHeader {nsdecls("w")}/>'))

        for r_idx, item in enumerate(screening_totals, start=1):
            row_cells = sc_table.rows[r_idx].cells
            row_cells[0].width = Inches(3.4)
            row_cells[1].width = Inches(2.2)
            row_cells[2].width = Inches(1.0)

            if not frameless and r_idx % 2 == 1:
                set_cell_background(row_cells[0], "FCFAF2")
                set_cell_background(row_cells[1], "FCFAF2")
                set_cell_background(row_cells[2], "FCFAF2")

            is_sub = item.get("is_sub", False)
            i_type = item.get("type", "number")
            val_str = str(item.get("value", "0")).strip()
            unit_str = str(item.get("unit", "")).strip()

            # Col 0: Label
            p0 = row_cells[0].paragraphs[0]
            p0.paragraph_format.space_before = Pt(2)
            p0.paragraph_format.space_after = Pt(2)
            p0.alignment = WD_ALIGN_PARAGRAPH.LEFT
            tok_label = tokenize_thai_softbreak(item.get("label", ""))
            r0 = p0.add_run(tok_label)
            apply_thai_font(
                r0,
                size_pt=12.5 if not is_sub else 12,
                bold=not is_sub,
                color_rgb=RGBColor(53, 28, 117) if not is_sub and item.get("num") in ("1", "4", "10", "12", "15", "16") else None
            )

            # Col 1 & 2: Value & Unit
            is_text_type = (i_type == "text" or not unit_str)
            is_narrative = is_text_type and val_str not in ("-", "", "ไม่มี", "ไม่พบ")

            if is_narrative:
                # Merge Col 1 and Col 2 because there is actual narrative text
                merged_val_cell = row_cells[1].merge(row_cells[2])
                lines = [l.strip() for l in val_str.split("\n") if l.strip()]
                for l_idx, line in enumerate(lines):
                    c_text = re.sub(r'^[-\u00a0\s]+', '', line)
                    tok = tokenize_thai_softbreak(c_text)

                    p = merged_val_cell.paragraphs[0] if l_idx == 0 else merged_val_cell.add_paragraph()
                    p.paragraph_format.space_before = Pt(1.5)
                    p.paragraph_format.space_after = Pt(1.5)
                    p.paragraph_format.line_spacing = 1.15
                    # Hanging indent so '-' bullet is aligned and text wraps under text at tab
                    p.paragraph_format.left_indent = Inches(0.28)
                    p.paragraph_format.first_line_indent = Inches(-0.28)

                    r_b = p.add_run("-\t")
                    apply_thai_font(r_b, size_pt=11.5)
                    r_t = p.add_run(tok)
                    apply_thai_font(r_t, size_pt=11.5)
                    apply_thai_distributed(p)
            else:
                # Numbers or '-' symbol: Keep Col 1 and Col 2 separate so '-' aligns with numbers in Col 1
                p1 = row_cells[1].paragraphs[0]
                p1.paragraph_format.space_before = Pt(2)
                p1.paragraph_format.space_after = Pt(2)
                p1.alignment = WD_ALIGN_PARAGRAPH.CENTER
                display_val = "-" if val_str in ("-", "", "ไม่มี", "ไม่พบ") else val_str
                r1 = p1.add_run(display_val)
                apply_thai_font(
                    r1,
                    size_pt=12.5 if i_type == "number" else 11.5,
                    bold=True if i_type == "number" and display_val not in ("0", "-") else False,
                    color_rgb=RGBColor(21, 128, 61) if i_type == "number" and display_val not in ("0", "-") else None
                )

                # Col 2: Unit
                p2 = row_cells[2].paragraphs[0]
                p2.paragraph_format.space_before = Pt(2)
                p2.paragraph_format.space_after = Pt(2)
                p2.alignment = WD_ALIGN_PARAGRAPH.CENTER
                r2 = p2.add_run(unit_str if val_str not in ("-", "", "ไม่มี", "ไม่พบ") else (unit_str or ""))
                apply_thai_font(r2, size_pt=12)

            if not frameless:
                for cell in row_cells:
                    set_cell_border(cell,
                        top={"val": "single", "sz": "4", "color": "E5E7EB"},
                        bottom={"val": "single", "sz": "4", "color": "E5E7EB"},
                        left={"val": "single", "sz": "4", "color": "E5E7EB"},
                        right={"val": "single", "sz": "4", "color": "E5E7EB"}
                    )

        for r_elm in sc_table.rows:
            r_elm._tr.get_or_add_trPr().append(parse_xml(f'<w:cantSplit {nsdecls("w")}/>'))

    # 6. Signatures (วางต่อจากตารางสรุปข้อมูลคัดกรอง)
    doc.add_paragraph().paragraph_format.space_after = Pt(14)
    sig_table = doc.add_table(rows=1, cols=2)
    sig_table.alignment = WD_TABLE_ALIGNMENT.CENTER
    sig_table.autofit = False

    sig_row = sig_table.rows[0]
    sig_l = sig_row.cells[0]
    sig_r = sig_row.cells[1]
    sig_l.width = Inches(3.4)
    sig_r.width = Inches(3.4)

    sum_date_thai = format_thai_date(recorded_date_str) if recorded_date_str else format_thai_date()
    dir_sign_name = (director_name or ".......................................................").strip()

    p_sl = sig_l.paragraphs[0]
    p_sl.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r_sl = p_sl.add_run(
        "ลงชื่อ.......................................................\n"
        "(.......................................................)\n"
        "หัวหน้างานระบบดูแลช่วยเหลือนักเรียน\n"
        f"{sum_date_thai}"
    )
    apply_thai_font(r_sl, size_pt=13)

    p_sr = sig_r.paragraphs[0]
    p_sr.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r_sr = p_sr.add_run(
        "ลงชื่อ.......................................................\n"
        f"({dir_sign_name})\n"
        f"ผู้อำนวยการโรงเรียน{school_name}\n"
        f"{sum_date_thai}"
    )
    apply_thai_font(r_sr, size_pt=13)

    for r_elm in sig_table.rows:
        r_elm._tr.get_or_add_trPr().append(parse_xml(f'<w:cantSplit {nsdecls("w")}/>'))

    suffix = "_ไม่มีกรอบ" if frameless else ""
    out_file = output_docx_path or str(OUTPUT_DIR / f"แบบรายงานสรุปเยี่ยมบ้านทั้งโรงเรียน_{year}_เทอม{term}{suffix}.docx")
    doc.save(out_file)
    return out_file
