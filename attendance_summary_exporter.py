import school_profile
import io
import json
import os
import shutil
import datetime
from pathlib import Path
from typing import Dict, Any, List, Optional

import docx
from docx.shared import Inches, Pt, RGBColor, Cm
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_ALIGN_VERTICAL
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls, qn

from database import (
    DB_DEFAULT_PATH,
    get_connection,
    init_db,
    get_attendance_dashboard,
    compute_100_dates,
    get_class_students,
    get_daily_attendance_grid
)
from home_visit_exporter import convert_docx_to_pdf

THAI_MONTHS = [
    '', 'มกราคม', 'กุมภาพันธ์', 'มีนาคม', 'เมษายน', 'พฤษภาคม',
    'มิถุนายน', 'กรกฎาคม', 'สิงหาคม', 'กันยายน', 'ตุลาคม', 'พฤศจิกายน', 'ธันวาคม'
]


def set_cell_background(cell, fill_hex: str):
    """Set background color of a table cell."""
    tcPr = cell._tc.get_or_add_tcPr()
    shd = parse_xml(f'<w:shd {nsdecls("w")} w:fill="{fill_hex}"/>')
    tcPr.append(shd)


def set_cell_margins(cell, top=100, bottom=100, left=150, right=150):
    """Set inner padding for a table cell (in twips, 1pt = 20 twips)."""
    tcPr = cell._tc.get_or_add_tcPr()
    tcMar = parse_xml(
        f'<w:tcMar {nsdecls("w")}>'
        f'  <w:top w:w="{top}" w:type="dxa"/>'
        f'  <w:bottom w:w="{bottom}" w:type="dxa"/>'
        f'  <w:left w:w="{left}" w:type="dxa"/>'
        f'  <w:right w:w="{right}" w:type="dxa"/>'
        f'</w:tcMar>'
    )
    tcPr.append(tcMar)


def set_table_borders(table, color="D1D5DB", sz="4", val="single"):
    """Set clean subtle horizontal borders on table."""
    tblPr = table._tbl.tblPr
    borders = parse_xml(
        f'<w:tblBorders {nsdecls("w")}>'
        f'  <w:top w:val="{val}" w:sz="{sz}" w:space="0" w:color="{color}"/>'
        f'  <w:bottom w:val="{val}" w:sz="{sz}" w:space="0" w:color="{color}"/>'
        f'  <w:insideH w:val="{val}" w:sz="{sz}" w:space="0" w:color="{color}"/>'
        f'  <w:insideV w:val="none"/>'
        f'  <w:left w:val="none"/>'
        f'  <w:right w:val="none"/>'
        f'</w:tblBorders>'
    )
    tblPr.append(borders)


def format_thai_date(dt: Optional[datetime.date] = None) -> str:
    """Format date to official Thai date string."""
    if not dt:
        dt = datetime.date.today()
    y_be = dt.year + 543
    return f"{dt.day} {THAI_MONTHS[dt.month]} พ.ศ. {y_be}"


def get_attendance_summary_report_data(
    term: str = "1",
    year: str = "2569",
    mode: str = "daily",
    threshold: str = "all",  # "all", "under80", "under60"
    class_level: str = "all",
    eval_scope: str = "current",  # "current" (วันปัจจุบัน) or "full_100" (เกณฑ์เต็ม 100 วัน)
    db_path: str = DB_DEFAULT_PATH
) -> Dict[str, Any]:
    """
    Retrieve comprehensive attendance evaluation data for all students
    evaluating against standard 80% and 60% school attendance criteria.
    Calculated from Daily Attendance (หน้าเช็คเวลาเรียน) based on days up to current date.
    Locked students (is_locked = True) are automatically excluded.
    """
    init_db(db_path)
    t = str(term).strip()
    y = str(year).strip()
    full_term_criterion = 100

    full_students = []

    if mode == "daily":
        with get_connection(db_path) as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT DISTINCT attendance_date FROM daily_attendance WHERE term = ? AND year = ? ORDER BY attendance_date;",
                (t, y)
            )
            rec_dates = [r["attendance_date"] for r in cursor.fetchall()]

            cursor.execute(
                "SELECT start_date FROM daily_attendance_config WHERE term = ? AND year = ? LIMIT 1;",
                (t, y)
            )
            cfg_row = cursor.fetchone()

        start_date = cfg_row["start_date"] if cfg_row and cfg_row["start_date"] else None
        dates_100 = compute_100_dates(start_date, t, y)

        today_str = datetime.date.today().strftime("%Y-%m-%d")

        if eval_scope == "full_100":
            eval_slots = len(dates_100)
        else:
            if dates_100 and dates_100[0] <= today_str <= dates_100[-1]:
                eval_slots = max(1, len([d for d in dates_100 if d <= today_str]))
            elif rec_dates:
                matching_indices = [dates_100.index(d) for d in rec_dates if d in dates_100]
                if matching_indices:
                    max_idx = max(matching_indices)
                    # Align to at least the end of that school week (5 slots per week)
                    week_end_idx = min(len(dates_100) - 1, ((max_idx // 5) + 1) * 5 - 1)
                    eval_slots = week_end_idx + 1
                else:
                    eval_slots = full_term_criterion
            else:
                eval_slots = full_term_criterion

        levels_to_process = [class_level] if class_level and class_level != "all" else ["ม.1", "ม.2", "ม.3", "ม.4", "ม.5", "ม.6"]

        for lvl in levels_to_process:
            grid = get_daily_attendance_grid(t, y, lvl, db_path=db_path)
            students_grid = grid.get("students", [])
            holidays = set(grid.get("holidays", []))
            locked_counted = set(grid.get("locked_counted", []))

            for s in students_grid:
                if s.get("is_locked"):
                    continue  # Exclude locked students per requirement A3

                st_list = s.get("status_list", [])
                p = 0
                l = 0
                a = 0
                lt = 0
                crit = 0

                for i in range(eval_slots):
                    if i in holidays:
                        continue
                    crit += 1
                    if i in locked_counted:
                        p += 1
                        continue
                    val = st_list[i] if i < len(st_list) else ""
                    if val in ("/", "present"):
                        p += 1
                    elif val in ("ส", "late"):
                        p += 1  # สาย นับเป็นมาเรียน
                        lt += 1
                    elif val in ("ล", "leave"):
                        l += 1
                    else:
                        a += 1

                pct = round((p / crit * 100), 1) if crit > 0 else 100.0
                if pct < 60.0:
                    status_code = "critical"
                    status_text = "เวลาเรียนไม่ถึง 60% (หมดสิทธิ์สอบ)"
                elif pct < 80.0:
                    status_code = "warning"
                    status_text = "เวลาเรียนไม่ถึง 80% (เสี่ยง มส.)"
                else:
                    status_code = "pass"
                    status_text = "ผ่านเกณฑ์"

                item = {
                    "student_no": s.get("student_no", 0),
                    "student_id": s.get("student_id", ""),
                    "full_name": s.get("full_name", ""),
                    "class_level": lvl,
                    "room": s.get("room", "1"),
                    "total_periods": crit,
                    "present": p,
                    "absent": a,
                    "leave": l,
                    "late": lt,
                    "percentage": pct,
                    "status_code": status_code,
                    "status_text": status_text,
                    "unit": "วัน",
                    "evaluated_days": crit,
                    "full_term_criterion": full_term_criterion,
                }
                full_students.append(item)
    else:
        # Subject mode (grades_history)
        eval_slots = 100
        with get_connection(db_path) as conn:
            cursor = conn.cursor()
            cursor.execute(
                """
                SELECT student_id, course_code, attendance_json 
                FROM grades_history 
                WHERE term = ? AND year = ? AND attendance_json IS NOT NULL;
                """,
                (t, y)
            )
            subject_att_map = {}
            for row in cursor.fetchall():
                sid = row["student_id"]
                try:
                    att = json.loads(row["attendance_json"])
                    if isinstance(att, dict) and (att.get("present_count", 0) > 0 or (att.get("absent_count", 0) > 0 and att.get("percentage", 0) > 0)):
                        if sid not in subject_att_map:
                            subject_att_map[sid] = {"absent": 0, "present": 0, "leave": 0, "late": 0, "courses_count": 0}
                        subject_att_map[sid]["absent"] += att.get("absent_count", 0)
                        subject_att_map[sid]["present"] += att.get("present_count", 0)
                        subject_att_map[sid]["leave"] += att.get("leave_count", 0)
                        subject_att_map[sid]["late"] += att.get("late_count", 0)
                        subject_att_map[sid]["courses_count"] += 1
                except Exception:
                    pass

            q = """
                SELECT student_no, student_id, full_name, class_level, room, is_locked
                FROM class_students
                WHERE term = ? AND year = ? AND is_active = 1
            """
            params = [t, y]
            if class_level and class_level != "all":
                q += " AND class_level = ?"
                params.append(str(class_level).strip())
            q += " ORDER BY class_level, CAST(room AS INTEGER), student_no, student_id;"
            cursor.execute(q, params)
            students_db = cursor.fetchall()

        for s in students_db:
            if s["is_locked"]:
                continue
            sid = s["student_id"]
            lvl = s["class_level"]
            rm = s["room"] or "1"
            s_att = subject_att_map.get(sid, {"absent": 0, "present": 0, "leave": 0, "late": 0, "courses_count": 0})
            s_tot = s_att["absent"] + s_att["present"] + s_att["leave"]
            s_pct = round((s_att["present"] / s_tot * 100), 1) if s_tot > 0 else 100.0

            if s_pct < 60.0:
                status_code = "critical"
                status_text = "เวลาเรียนไม่ถึง 60% (หมดสิทธิ์สอบ)"
            elif s_pct < 80.0:
                status_code = "warning"
                status_text = "เวลาเรียนไม่ถึง 80% (เสี่ยง มส.)"
            else:
                status_code = "pass"
                status_text = "ผ่านเกณฑ์"

            item = {
                "student_no": s["student_no"],
                "student_id": sid,
                "full_name": s["full_name"],
                "class_level": lvl,
                "room": rm,
                "total_periods": s_tot if s_tot > 0 else s_att["present"],
                "present": s_att["present"],
                "absent": s_att["absent"],
                "leave": s_att["leave"],
                "late": s_att.get("late", 0),
                "percentage": s_pct,
                "status_code": status_code,
                "status_text": status_text,
                "unit": "คาบ",
                "evaluated_days": 100,
                "full_term_criterion": 100,
            }
            full_students.append(item)

    # Filter by threshold
    filtered_students = []
    for st in full_students:
        if threshold == "under60":
            if st["status_code"] == "critical":
                filtered_students.append(st)
        elif threshold == "under80":
            if st["status_code"] in ("warning", "critical"):
                filtered_students.append(st)
        else:
            filtered_students.append(st)

    tot = len(full_students)
    pass_cnt = sum(1 for s in full_students if s["status_code"] == "pass")
    warn_cnt = sum(1 for s in full_students if s["status_code"] == "warning")
    crit_cnt = sum(1 for s in full_students if s["status_code"] == "critical")
    avg_pct = round(sum(s["percentage"] for s in full_students) / tot, 1) if tot > 0 else 100.0

    actual_eval_days = full_students[0]["evaluated_days"] if full_students else eval_slots

    return {
        "term": t,
        "year": y,
        "mode": mode,
        "threshold": threshold,
        "class_level": class_level,
        "eval_scope": eval_scope,
        "evaluated_days": actual_eval_days,
        "full_term_criterion": full_term_criterion,
        "generated_date": format_thai_date(),
        "summary": {
            "total_students": tot,
            "pass_count": pass_cnt,
            "pass_pct": round((pass_cnt / tot * 100), 1) if tot > 0 else 100.0,
            "warning_count": warn_cnt,
            "warning_pct": round((warn_cnt / tot * 100), 1) if tot > 0 else 0.0,
            "critical_count": crit_cnt,
            "critical_pct": round((crit_cnt / tot * 100), 1) if tot > 0 else 0.0,
            "average_attendance_pct": avg_pct,
            "evaluated_days": actual_eval_days,
            "full_term_criterion": full_term_criterion
        },
        "students": filtered_students
    }


def generate_attendance_summary_pdf(
    term: str = "1",
    year: str = "2569",
    mode: str = "daily",
    threshold: str = "all",
    class_level: str = "all",
    eval_scope: str = "current",
    db_path: str = DB_DEFAULT_PATH
) -> bytes:
    """
    Generate an official landscape PDF attendance report evaluating 80% & 60% thresholds.
    """
    data = get_attendance_summary_report_data(
        term=term,
        year=year,
        mode=mode,
        threshold=threshold,
        class_level=class_level,
        eval_scope=eval_scope,
        db_path=db_path
    )

    doc = docx.Document()

    # Configure Page Setup: A4 Landscape with 1.2 cm margins
    section = doc.sections[0]
    section.page_width = Cm(29.7)
    section.page_height = Cm(21.0)
    section.top_margin = Cm(1.2)
    section.bottom_margin = Cm(1.2)
    section.left_margin = Cm(1.2)
    section.right_margin = Cm(1.2)

    # 1. Header with Logo & School Title
    header_tbl = doc.add_table(rows=1, cols=2)
    header_tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
    header_tbl.autofit = False

    logo_cell = header_tbl.rows[0].cells[0]
    logo_cell.width = Cm(2.4)
    logo_cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER

    title_cell = header_tbl.rows[0].cells[1]
    title_cell.width = Cm(24.9)
    title_cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER

    # Insert logo if available
    logo_path = Path("uploads/school_logo.png")
    if logo_path.exists():
        try:
            p_logo = logo_cell.paragraphs[0]
            p_logo.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p_logo.paragraph_format.space_before = Pt(0)
            p_logo.paragraph_format.space_after = Pt(0)
            run_logo = p_logo.add_run()
            run_logo.add_picture(str(logo_path), width=Cm(2.0))
        except Exception:
            pass

    # Title text
    p_title = title_cell.paragraphs[0]
    p_title.paragraph_format.space_before = Pt(0)
    p_title.paragraph_format.space_after = Pt(2)
    r1 = p_title.add_run(school_profile.banner_line() + "\n")
    r1.font.name = "TH Sarabun New"
    r1.font.size = Pt(16)
    r1.font.bold = True
    r1.font.color.rgb = RGBColor(36, 17, 79)  # AppColors.purpleDark

    r2 = p_title.add_run(f"แบบรายงานสรุปสถิติเวลาเรียนของนักเรียน (เกณฑ์ประเมินเวลาเรียน 80% และ 60%)\n")
    r2.font.name = "TH Sarabun New"
    r2.font.size = Pt(14)
    r2.font.bold = True
    r2.font.color.rgb = RGBColor(180, 83, 9)  # Deep Amber Gold

    lvl_desc = "ทุกระดับชั้น (ม.1 – ม.6)" if class_level == "all" else f"ระดับชั้น {class_level}"
    mode_desc = "เวลาเรียนประจำวัน (โฮมรูม หน้าเช็คเวลาเรียน เกณฑ์ 100 วัน)" if mode == "daily" else "เวลาเรียนรายวิชา (ปพ.5)"
    filter_desc = "นักเรียนทั้งหมด" if threshold == "all" else ("เฉพาะกลุ่มเวลาเรียนไม่ถึง 80%" if threshold == "under80" else "เฉพาะกลุ่มเวลาเรียนไม่ถึง 60% (หมดสิทธิ์สอบ)")
    eval_days = data.get("evaluated_days", 100)
    full_crit = data.get("full_term_criterion", 100)

    r3 = p_title.add_run(f"ภาคเรียนที่ {term} ปีการศึกษา {year}  •  {lvl_desc}  •  {mode_desc}  •  ประเมินสะสมถึงปัจจุบัน: {eval_days} วัน (จากเกณฑ์เต็ม {full_crit} วัน)  •  เงื่อนไข: {filter_desc}\n")
    r3.font.name = "TH Sarabun New"
    r3.font.size = Pt(11)
    r3.font.color.rgb = RGBColor(71, 85, 105)

    r4 = p_title.add_run(f"ข้อมูล ณ วันที่ {data['generated_date']}")
    r4.font.name = "TH Sarabun New"
    r4.font.size = Pt(10)
    r4.font.italic = True
    r4.font.color.rgb = RGBColor(100, 116, 139)

    doc.add_paragraph().paragraph_format.space_after = Pt(4)

    # 2. Executive KPI Summary Cards Table
    sm = data["summary"]
    kpi_tbl = doc.add_table(rows=1, cols=4)
    kpi_tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
    kpi_tbl.autofit = False
    set_table_borders(kpi_tbl, color="E2E8F0", sz="6")

    kpi_items = [
        ("นักเรียนทั้งหมด", f"{sm['total_students']} คน", f"เฉลี่ย {sm['average_attendance_pct']}%", "F8FAFC", "1E293B"),
        ("ผ่านเกณฑ์ (80% ขึ้นไป)", f"{sm['pass_count']} คน", f"{sm['pass_pct']}% ของทั้งหมด", "F0FDF4", "15803D"),
        ("เสี่ยง มส. (60% – 79.9%)", f"{sm['warning_count']} คน", f"{sm['warning_pct']}% เวลาเรียนไม่ถึง 80%", "FFFBEB", "B45309"),
        ("หมดสิทธิ์สอบ (ต่ำกว่า 60%)", f"{sm['critical_count']} คน", f"{sm['critical_pct']}% เวลาเรียนไม่ถึง 60%", "FEF2F2", "B91C1C"),
    ]

    for idx, (lbl, val, sub, bg_hex, fg_hex) in enumerate(kpi_items):
        cell = kpi_tbl.rows[0].cells[idx]
        cell.width = Cm(6.8)
        set_cell_background(cell, bg_hex)
        set_cell_margins(cell, top=120, bottom=120, left=140, right=140)

        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(0)
        p.paragraph_format.space_after = Pt(1)

        r_lbl = p.add_run(f"{lbl}\n")
        r_lbl.font.name = "TH Sarabun New"
        r_lbl.font.size = Pt(11)
        r_lbl.font.bold = True
        r_lbl.font.color.rgb = RGBColor(71, 85, 105)

        r_val = p.add_run(f"{val}\n")
        r_val.font.name = "TH Sarabun New"
        r_val.font.size = Pt(18)
        r_val.font.bold = True
        # Convert hex to RGBColor
        r_val.font.color.rgb = RGBColor(int(fg_hex[:2], 16), int(fg_hex[2:4], 16), int(fg_hex[4:], 16))

        r_sub = p.add_run(sub)
        r_sub.font.name = "TH Sarabun New"
        r_sub.font.size = Pt(9.5)
        r_sub.font.color.rgb = RGBColor(100, 116, 139)

    doc.add_paragraph().paragraph_format.space_after = Pt(6)

    # 3. Students Table
    cols_def = [
        ("ลำดับ", Cm(1.2), WD_ALIGN_PARAGRAPH.CENTER),
        ("ชั้น/ห้อง", Cm(1.8), WD_ALIGN_PARAGRAPH.CENTER),
        ("เลขที่", Cm(1.2), WD_ALIGN_PARAGRAPH.CENTER),
        ("รหัสนักเรียน", Cm(2.2), WD_ALIGN_PARAGRAPH.CENTER),
        ("ชื่อ - นามสกุล", Cm(5.8), WD_ALIGN_PARAGRAPH.LEFT),
        ("เวลาเรียนรวม", Cm(2.0), WD_ALIGN_PARAGRAPH.RIGHT),
        ("มาเรียน", Cm(1.8), WD_ALIGN_PARAGRAPH.RIGHT),
        ("ขาด", Cm(1.6), WD_ALIGN_PARAGRAPH.RIGHT),
        ("ลา", Cm(1.4), WD_ALIGN_PARAGRAPH.RIGHT),
        ("สาย", Cm(1.4), WD_ALIGN_PARAGRAPH.RIGHT),
        ("ร้อยละ (%)", Cm(2.1), WD_ALIGN_PARAGRAPH.RIGHT),
        ("ผลการประเมินเวลาเรียน", Cm(4.8), WD_ALIGN_PARAGRAPH.CENTER),
    ]

    students = data["students"]
    st_table = doc.add_table(rows=len(students) + 1, cols=len(cols_def))
    st_table.alignment = WD_TABLE_ALIGNMENT.CENTER
    st_table.autofit = False
    set_table_borders(st_table, color="CBD5E1", sz="4")

    # Repeat header row on every page
    header_tr = st_table.rows[0]._tr.get_or_add_trPr()
    header_tr.append(parse_xml(f'<w:tblHeader {nsdecls("w")}/>'))

    # Header Row
    for idx, (col_name, col_w, align) in enumerate(cols_def):
        cell = st_table.rows[0].cells[idx]
        cell.width = col_w
        cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
        set_cell_background(cell, "24114F")  # Dark Royal Purple
        set_cell_margins(cell, top=140, bottom=140, left=80, right=80)

        p = cell.paragraphs[0]
        p.alignment = align
        p.paragraph_format.space_before = Pt(0)
        p.paragraph_format.space_after = Pt(0)
        run = p.add_run(col_name)
        run.font.name = "TH Sarabun New"
        run.font.size = Pt(11)
        run.font.bold = True
        run.font.color.rgb = RGBColor(255, 255, 255)

    # Student Rows
    unit_str = " คาบ" if mode == "subject" else " วัน"
    for r_idx, s in enumerate(students, start=1):
        row = st_table.rows[r_idx]
        status_code = s["status_code"]

        # Row background highlight
        if status_code == "critical":
            row_bg = "FEE2E2"  # Soft Red
            status_fg = RGBColor(185, 28, 28)
        elif status_code == "warning":
            row_bg = "FEF3C7"  # Soft Amber
            status_fg = RGBColor(180, 83, 9)
        else:
            row_bg = "FFFFFF" if r_idx % 2 == 1 else "F8FAFC"
            status_fg = RGBColor(21, 128, 61)

        row_vals = [
            (str(r_idx), cols_def[0][1], cols_def[0][2], RGBColor(30, 41, 59), False),
            (f"{s['class_level']}/{s['room']}", cols_def[1][1], cols_def[1][2], RGBColor(30, 41, 59), True),
            (str(s["student_no"]), cols_def[2][1], cols_def[2][2], RGBColor(71, 85, 105), False),
            (str(s["student_id"]), cols_def[3][1], cols_def[3][2], RGBColor(71, 85, 105), False),
            (str(s["full_name"]), cols_def[4][1], cols_def[4][2], RGBColor(15, 23, 42), True),
            (f"{s['total_periods']}", cols_def[5][1], cols_def[5][2], RGBColor(71, 85, 105), False),
            (f"{s['present']}", cols_def[6][1], cols_def[6][2], RGBColor(21, 128, 61), False),
            (f"{s['absent']}", cols_def[7][1], cols_def[7][2], RGBColor(185, 28, 28) if s["absent"] > 0 else RGBColor(148, 163, 184), s["absent"] > 0),
            (f"{s['leave']}", cols_def[8][1], cols_def[8][2], RGBColor(100, 116, 139), False),
            (f"{s['late']}", cols_def[9][1], cols_def[9][2], RGBColor(100, 116, 139), False),
            (f"{s['percentage']}%", cols_def[10][1], cols_def[10][2], status_fg, True),
            (s["status_text"], cols_def[11][1], cols_def[11][2], status_fg, True),
        ]

        for c_idx, (val_str, col_w, align, fg_color, is_bold) in enumerate(row_vals):
            cell = row.cells[c_idx]
            cell.width = col_w
            cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
            set_cell_background(cell, row_bg)
            set_cell_margins(cell, top=80, bottom=80, left=80, right=80)

            p = cell.paragraphs[0]
            p.alignment = align
            p.paragraph_format.space_before = Pt(0)
            p.paragraph_format.space_after = Pt(0)
            run = p.add_run(val_str)
            run.font.name = "TH Sarabun New"
            run.font.size = Pt(10.5)
            run.font.bold = is_bold
            run.font.color.rgb = fg_color

    doc.add_paragraph().paragraph_format.space_after = Pt(12)

    # 4. Official Signature Block (3 Columns)
    sig_tbl = doc.add_table(rows=1, cols=3)
    sig_tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
    sig_tbl.autofit = False

    sig_roles = [
        ("ครูประจำชั้น / ครูผู้สอน", "ผู้รายงานข้อมูล"),
        ("นายทะเบียน / งานวัดผลและประเมินผล", "ผู้ตรวจสอบข้อมูล"),
        (school_profile.director_title(), "ผู้อนุมัติผลการประเมิน"),
    ]

    for idx, (role_title, role_sub) in enumerate(sig_roles):
        cell = sig_tbl.rows[0].cells[idx]
        cell.width = Cm(9.1)
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.line_spacing = 1.3
        p.paragraph_format.space_before = Pt(0)
        p.paragraph_format.space_after = Pt(0)

        r_sig = p.add_run(
            "ลงชื่อ ....................................................\n"
            "( .................................................... )\n"
            f"ตำแหน่ง {role_title}\n"
            f"วันที่ ..... / ..... / .....\n"
        )
        r_sig.font.name = "TH Sarabun New"
        r_sig.font.size = Pt(10.5)
        r_sig.font.color.rgb = RGBColor(51, 65, 85)

    # Save to temp docx and convert to PDF
    tmp_dir = Path("tmp")
    tmp_dir.mkdir(exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    tmp_docx = tmp_dir / f"attendance_summary_{stamp}.docx"
    tmp_pdf = tmp_dir / f"attendance_summary_{stamp}.pdf"

    doc.save(str(tmp_docx))

    try:
        convert_docx_to_pdf(str(tmp_docx), str(tmp_pdf))
        pdf_bytes = tmp_pdf.read_bytes()
        return pdf_bytes
    finally:
        # Cleanup temp files
        try:
            if tmp_docx.exists():
                tmp_docx.unlink()
            if tmp_pdf.exists():
                tmp_pdf.unlink()
        except Exception:
            pass
