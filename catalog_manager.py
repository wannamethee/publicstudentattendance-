"""
Master Course Catalog Manager (คลังรายชื่อวิชามาตรฐาน ภาคเรียนที่ 1 และ 2)
- Decodes Thai MOE course codes (e.g. ว33101, ค21102):
  - Prefix letter: ส, ว, ค, ง, พ, ท, อ, จ, ศ, ก, I -> Department (กลุ่มสาระการเรียนรู้)
  - Digit 1: 2 = ช่วงชั้นที่ 2 (ม.ต้น ม.1-ม.3), 3 = ช่วงชั้นที่ 3 (ม.ปลาย ม.4-ม.6)
  - Digit 2: 1/2/3 -> ม.1/ม.2/ม.3 (after 2) or ม.4/ม.5/ม.6 (after 3)
  - Digit 3: 1 = พื้นฐาน, 2 = เพิ่มเติม (ก = กิจกรรมพัฒนาผู้เรียน)
  - Digit 5: Odd (1,3,5,7,9) = เทอม 1, Even (0,2,4,6,8) = เทอม 2
- Stores canonical course_name, metadata, and reusable course_description.
- Automatically normalizes garbled SGS PDF course names when course_code matches.
"""

import re
import sqlite3
from pathlib import Path
from typing import Dict, Any, List, Optional
import openpyxl

DB_PATH = "school_archive.db"
OUTPUT_DIR = Path("outputs")


PREFIX_TO_DEPARTMENT = {
    "ท": "ภาษาไทย",
    "ค": "คณิตศาสตร์",
    "ว": "วิทยาศาสตร์และเทคโนโลยี",
    "ส": "สังคมศึกษา ศาสนา และวัฒนธรรม",
    "พ": "สุขศึกษาและพลศึกษา",
    "ศ": "ศิลปะศึกษาและดนตรีนาฏศิลป์",
    "ง": "การงานอาชีพ",
    "อ": "ภาษาต่างประเทศ (ภาษาอังกฤษ)",
    "จ": "ภาษาต่างประเทศ (ภาษาจีน)",
    "ก": "กิจกรรมพัฒนาผู้เรียน",
    "I": "การศึกษาค้นคว้าอิสระ (IS)",
}




def _reinit_after(fn):
    """Deleting catalog rows: let database.init_db run its seed-when-empty check again (as before caching)."""
    import functools

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        finally:
            import database
            database.invalidate_init_cache()
    return wrapper

def decode_course_code(course_code: str) -> Dict[str, Any]:
    """
    Decode a Thai course code (1 letter + 5 digits) into:
    - subject_prefix
    - department
    - stage ('2' for ม.ต้น, '3' for ม.ปลาย)
    - class_level ('ม.1' .. 'ม.6')
    - course_type ('พื้นฐาน', 'เพิ่มเติม', 'กิจกรรม')
    - term ('1' or '2')
    """
    code = str(course_code or "").strip()
    if not code:
        return {
            "subject_prefix": "",
            "department": "-",
            "stage": "2",
            "class_level": "ม.1",
            "course_type": "พื้นฐาน",
            "term": "1",
        }

    prefix = code[0].upper() if code[0].isascii() else code[0]
    dept = PREFIX_TO_DEPARTMENT.get(prefix, "-")

    m = re.match(r"^([ก-ฮA-Za-z])\s*(\d)(\d)(\d)(\d)(\d)", code)
    if not m:
        return {
            "subject_prefix": prefix,
            "department": dept,
            "stage": "2",
            "class_level": "ม.1",
            "course_type": "กิจกรรม" if prefix == "ก" else "พื้นฐาน",
            "term": "1",
        }

    _, d1, d2, d3, d4, d5 = m.groups()

    # Stage (ช่วงชั้น) & Class Level (ระดับชั้น)
    stage = "3" if d1 == "3" else "2"
    if d1 == "2":
        if d2 == "1":
            class_level = "ม.1"
        elif d2 == "2" or d2 == "0":
            class_level = "ม.2"
        elif d2 == "3":
            class_level = "ม.3"
        else:
            class_level = f"ม.{d2}"
    elif d1 == "3":
        if d2 == "1":
            class_level = "ม.4"
        elif d2 == "2" or d2 == "0":
            class_level = "ม.5"
        elif d2 == "3":
            class_level = "ม.6"
        else:
            class_level = "ม.4"
    else:
        class_level = "ม.1"

    # Course Type (ประเภทวิชา)
    if prefix == "ก":
        course_type = "กิจกรรม"
    elif d3 == "2":
        course_type = "เพิ่มเติม"
    else:
        course_type = "พื้นฐาน"

    # Term (ภาคเรียน): Odd = 1, Even = 2
    term = "1" if int(d5) % 2 == 1 else "2"

    return {
        "subject_prefix": prefix,
        "department": dept,
        "stage": stage,
        "class_level": class_level,
        "course_type": course_type,
        "term": term,
    }


def init_course_catalog(db_path: str = DB_PATH) -> None:
    """Create course_catalog table and seed initial Term 1 & Term 2 catalog if empty."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()

    c.execute(
        """
        CREATE TABLE IF NOT EXISTS course_catalog (
            course_code TEXT PRIMARY KEY,
            course_name TEXT NOT NULL,
            term TEXT NOT NULL DEFAULT '1',
            stage TEXT NOT NULL DEFAULT '2',
            class_level TEXT NOT NULL DEFAULT 'ม.1',
            course_type TEXT NOT NULL DEFAULT 'พื้นฐาน',
            department TEXT NOT NULL DEFAULT '-',
            subject_prefix TEXT NOT NULL DEFAULT '',
            credits REAL DEFAULT 1.0,
            score_ratio TEXT DEFAULT '70:30',
            course_description TEXT DEFAULT '',
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        """
    )

    c.execute("SELECT COUNT(*) AS cnt FROM course_catalog;")
    cnt = c.fetchone()["cnt"]

    if cnt == 0:
        _seed_catalog_from_existing_sources(conn)

    conn.commit()
    conn.close()


def _clean_garbled_course_name(code: str, name: str) -> str:
    """Fix known garbled Thai course names from SGS PDFs."""
    n = re.sub(r"\s+", " ", str(name or "").strip())
    if code == "ว33101" or "โลกดาราศาสตร์พ" in n:
        return "โลกดาราศาสตร์พื้นฐาน"
    n = n.replace("พื นฐาน", "พื้นฐาน").replace("พี นฐาน", "พื้นฐาน")
    n = n.replace("วิทยาการคำนวน", "วิทยาการคำนวณ")
    n = n.replace("วิทยาศาตร์", "วิทยาศาสตร์")
    return n


def _seed_catalog_from_existing_sources(conn: sqlite3.Connection) -> None:
    c = conn.cursor()

    # 1. Seed Term 1 from template_ปพ5_blank.xlsx (W5:AD130)
    tpl_path = Path("template_ปพ5_blank.xlsx")
    if tpl_path.exists():
        try:
            wb = openpyxl.load_workbook(str(tpl_path), data_only=True)
            if "(1) ปกปพ." in wb.sheetnames:
                ws = wb["(1) ปกปพ."]
                for r in range(5, 135):
                    code = str(ws.cell(r, 23).value or "").strip()
                    name = str(ws.cell(r, 24).value or "").strip()
                    if not code or not name:
                        continue
                    decoded = decode_course_code(code)
                    clean_name = _clean_garbled_course_name(code, name)
                    try:
                        credits = float(ws.cell(r, 25).value or 1.0)
                    except Exception:
                        credits = 1.0
                    ratio_raw = str(ws.cell(r, 26).value or "70:30").strip().replace(" ", "")
                    lvl = str(ws.cell(r, 27).value or decoded["class_level"]).strip()

                    c.execute(
                        """
                        INSERT OR IGNORE INTO course_catalog (
                            course_code, course_name, term, stage, class_level,
                            course_type, department, subject_prefix, credits, score_ratio
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        (
                            code,
                            clean_name,
                            decoded["term"],
                            decoded["stage"],
                            lvl or decoded["class_level"],
                            decoded["course_type"],
                            decoded["department"],
                            decoded["subject_prefix"],
                            credits,
                            ratio_raw,
                        )
                    )
        except Exception as e:
            print(f"[WARN] Seeding Term 1 from template failed: {e}")

    # 2. Seed Term 2 (and any additional courses + descriptions) from `courses` table (2/2569 and 1/2569)
    c.execute(
        """
        SELECT course_code, course_name, term, credits, class_level,
               score_ratio, course_description
        FROM courses
        ORDER BY year DESC, term DESC;
        """
    )
    for row in c.fetchall():
        code = str(row["course_code"] or "").strip()
        if not code:
            continue
        decoded = decode_course_code(code)
        raw_name = str(row["course_name"] or "").strip()
        clean_name = _clean_garbled_course_name(code, raw_name)
        credits = float(row["credits"] if row["credits"] is not None else 1.0)
        lvl = str(row["class_level"] or decoded["class_level"]).strip()
        ratio = str(row["score_ratio"] or "70:30").strip().replace(" ", "")
        desc = str(row["course_description"] or "").strip()

        c.execute(
            """
            INSERT INTO course_catalog (
                course_code, course_name, term, stage, class_level,
                course_type, department, subject_prefix, credits, score_ratio, course_description
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(course_code) DO UPDATE SET
                course_name = CASE
                    WHEN excluded.term = '2' THEN excluded.course_name
                    WHEN course_catalog.course_code = 'ว33101' THEN 'โลกดาราศาสตร์พื้นฐาน'
                    ELSE course_catalog.course_name
                END,
                credits = COALESCE(excluded.credits, course_catalog.credits),
                class_level = CASE WHEN excluded.class_level != '' THEN excluded.class_level ELSE course_catalog.class_level END,
                course_description = CASE
                    WHEN excluded.course_description != '' THEN excluded.course_description
                    ELSE course_catalog.course_description
                END;
            """,
            (
                code,
                clean_name,
                decoded["term"],
                decoded["stage"],
                lvl or decoded["class_level"],
                decoded["course_type"],
                decoded["department"],
                decoded["subject_prefix"],
                credits,
                ratio,
                desc,
            )
        )

    # Ensure ว33101 is explicitly 'โลกดาราศาสตร์พื้นฐาน'
    c.execute(
        "UPDATE course_catalog SET course_name = 'โลกดาราศาสตร์พื้นฐาน' WHERE course_code = 'ว33101';"
    )


def sync_courses_from_catalog(db_path: str = DB_PATH) -> int:
    """
    Sync all rows in `courses` table with canonical course_name, class_level,
    course_type, department, credits, and course_description from `course_catalog`.
    """
    init_course_catalog(db_path)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()

    c.execute("SELECT * FROM course_catalog;")
    cat_rows = [dict(r) for r in c.fetchall()]
    updated_count = 0

    for item in cat_rows:
        code = item["course_code"]
        c.execute(
            """
            UPDATE courses
            SET course_name = ?,
                class_level = COALESCE(NULLIF(class_level, ''), ?),
                course_type = COALESCE(NULLIF(course_type, ''), ?),
                department = COALESCE(NULLIF(department, ''), ?),
                credits = COALESCE(credits, ?),
                course_description = CASE
                    WHEN (course_description IS NULL OR course_description = '') AND ? != ''
                    THEN ?
                    ELSE course_description
                END
            WHERE course_code = ?;
            """,
            (
                item["course_name"],
                item["class_level"],
                item["course_type"],
                item["department"],
                item["credits"],
                item["course_description"] or "",
                item["course_description"] or "",
                code,
            )
        )
        updated_count += c.rowcount

    conn.commit()
    conn.close()
    return updated_count


def lookup_catalog_course(course_code: str, db_path: str = DB_PATH) -> Optional[Dict[str, Any]]:
    """Return the canonical catalog entry for course_code, or None if not found."""
    init_course_catalog(db_path)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute("SELECT * FROM course_catalog WHERE course_code = ?;", (str(course_code or "").strip(),))
    row = c.fetchone()
    conn.close()
    return dict(row) if row else None


def get_course_catalog(
    term: Optional[str] = None,
    stage: Optional[str] = None,
    course_type: Optional[str] = None,
    department: Optional[str] = None,
    subject_prefix: Optional[str] = None,
    search: Optional[str] = None,
    db_path: str = DB_PATH
) -> List[Dict[str, Any]]:
    """Query course_catalog with optional filters."""
    init_course_catalog(db_path)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()

    query = "SELECT * FROM course_catalog WHERE 1=1"
    params: List[Any] = []

    if term and term not in ("all", ""):
        query += " AND term = ?"
        params.append(str(term).strip())
    if stage and stage not in ("all", ""):
        query += " AND stage = ?"
        params.append(str(stage).strip())
    if course_type and course_type not in ("all", ""):
        query += " AND course_type = ?"
        params.append(str(course_type).strip())
    if subject_prefix and subject_prefix not in ("all", ""):
        query += " AND subject_prefix = ?"
        params.append(str(subject_prefix).strip())
    if department and department not in ("all", ""):
        query += " AND department = ?"
        params.append(str(department).strip())
    if search and search.strip():
        q = f"%{search.strip()}%"
        query += " AND (course_code LIKE ? OR course_name LIKE ? OR department LIKE ?)"
        params.extend([q, q, q])

    query += " ORDER BY term ASC, stage ASC, class_level ASC, course_code ASC;"
    c.execute(query, params)
    rows = [dict(r) for r in c.fetchall()]
    conn.close()
    return rows


@_reinit_after
def upsert_catalog_course(
    data: Dict[str, Any],
    old_course_code: Optional[str] = None,
    sync_files: bool = False,
    db_path: str = DB_PATH
) -> Dict[str, Any]:
    """
    Insert or update a course in course_catalog and propagate canonical name,
    metadata, and course_description to `courses` table and Excel files.
    """
    init_course_catalog(db_path)
    code = str(data.get("course_code") or "").strip()
    name = str(data.get("course_name") or "").strip()
    if not code or not name:
        return {"status": "error", "message": "กรุณาระบุรหัสวิชาและชื่อรายวิชา"}

    decoded = decode_course_code(code)
    term = str(data.get("term") or decoded["term"]).strip()
    stage = str(data.get("stage") or decoded["stage"]).strip()
    class_level = str(data.get("class_level") or decoded["class_level"]).strip()
    course_type = str(data.get("course_type") or decoded["course_type"]).strip()
    department = str(data.get("department") or decoded["department"]).strip()
    subject_prefix = str(data.get("subject_prefix") or decoded["subject_prefix"]).strip()
    try:
        credits = float(data.get("credits") if data.get("credits") is not None else 1.0)
    except Exception:
        credits = 1.0
    score_ratio = str(data.get("score_ratio") or "70:30").strip()
    course_description = str(data.get("course_description") or "").strip()

    conn = sqlite3.connect(db_path)
    c = conn.cursor()

    if old_course_code and old_course_code.strip() and old_course_code.strip() != code:
        c.execute("DELETE FROM course_catalog WHERE course_code = ?;", (old_course_code.strip(),))

    c.execute(
        """
        INSERT INTO course_catalog (
            course_code, course_name, term, stage, class_level,
            course_type, department, subject_prefix, credits, score_ratio, course_description, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(course_code) DO UPDATE SET
            course_name = excluded.course_name,
            term = excluded.term,
            stage = excluded.stage,
            class_level = excluded.class_level,
            course_type = excluded.course_type,
            department = excluded.department,
            subject_prefix = excluded.subject_prefix,
            credits = excluded.credits,
            score_ratio = excluded.score_ratio,
            course_description = excluded.course_description,
            updated_at = CURRENT_TIMESTAMP;
        """,
        (
            code, name, term, stage, class_level,
            course_type, department, subject_prefix, credits, score_ratio, course_description
        )
    )

    # Propagate to `courses` table across all semesters
    c.execute(
        """
        UPDATE courses
        SET course_name = ?,
            class_level = ?,
            course_type = ?,
            department = ?,
            credits = ?,
            score_ratio = ?,
            course_description = CASE WHEN ? != '' THEN ? ELSE course_description END
        WHERE course_code = ?;
        """,
        (
            name, class_level, course_type, department, credits, score_ratio,
            course_description, course_description, code
        )
    )

    conn.commit()
    conn.close()

    if sync_files and OUTPUT_DIR.exists():
        try:
            from excel_mapper import inject_course_description, safe_set_cell_addr
            for p in OUTPUT_DIR.glob(f"*{code}*.xlsx"):
                if p.name.startswith("~$"):
                    continue
                wb = openpyxl.load_workbook(str(p))
                if "(1) ปกปพ." in wb.sheetnames:
                    safe_set_cell_addr(wb["(1) ปกปพ."], "E9", name)
                if "(2) เวลาเรียน1" in wb.sheetnames:
                    safe_set_cell_addr(wb["(2) เวลาเรียน1"], "I2", name)
                if "(3) เวลาเรียน2" in wb.sheetnames:
                    safe_set_cell_addr(wb["(3) เวลาเรียน2"], "I2", name)
                if "(4) รวมคะแนน" in wb.sheetnames:
                    safe_set_cell_addr(wb["(4) รวมคะแนน"], "C2", name)
                if "(5) คุณลักษณะ" in wb.sheetnames:
                    safe_set_cell_addr(wb["(5) คุณลักษณะ"], "D2", name)
                if "(6) ตัวชี้วัด" in wb.sheetnames:
                    safe_set_cell_addr(wb["(6) ตัวชี้วัด"], "E1", name)
                    if course_description:
                        inject_course_description(wb["(6) ตัวชี้วัด"], course_description)
                wb.save(str(p))
            for pdf_p in OUTPUT_DIR.glob(f"*{code}*.pdf"):
                try:
                    pdf_p.unlink()
                except Exception:
                    pass
        except Exception as e_sync:
            print(f"[WARN] Could not sync Excel files for catalog update {code}: {e_sync}")

    return {
        "status": "success",
        "course_code": code,
        "course_name": name,
        "term": term,
        "stage": stage,
        "class_level": class_level,
        "course_type": course_type,
        "department": department,
        "credits": credits,
        "score_ratio": score_ratio,
        "course_description": course_description,
        "message": f"บันทึกรายวิชา {code} {name} ลงในคลังรายวิชามาตรฐานเรียบร้อยแล้ว"
    }


@_reinit_after
def delete_catalog_course(course_code: str, db_path: str = DB_PATH) -> bool:
    init_course_catalog(db_path)
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    c.execute("DELETE FROM course_catalog WHERE course_code = ?;", (str(course_code or "").strip(),))
    deleted = c.rowcount > 0
    conn.commit()
    conn.close()
    return deleted


# Alias for backward compatibility
get_catalog_courses = get_course_catalog
