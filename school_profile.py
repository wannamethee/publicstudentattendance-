"""
ข้อมูลประจำโรงเรียน (school identity) in one place.

The values below are the fallbacks of the school this copy of the program belongs to. Each one can be overridden by
the admin in the settings page (app_settings), and a new school fills them in on the first-run setup page.

deploy/make_blank_edition.py rewrites this file for the public blank edition (ฉบับเปล่าสำหรับโรงเรียนอื่น):
every value empty and BUILTIN_DATA = False, so a fresh install starts with no school, no teacher and no timetable.
"""
import re
from typing import Dict


def builtin():
    """school_builtin_data (this school's seed data, roster, personnel head) or None in the blank edition."""
    try:
        import school_builtin_data
        return school_builtin_data
    except ImportError:
        return None


# Seed this school's signatories, first admin and built-in timetables when the database is empty.
BUILTIN_DATA = builtin() is not None

SCHOOL_NAME = ""  # without the word "โรงเรียน"
SUBDISTRICT = ""
DISTRICT = ""
PROVINCE = ""
AREA_OFFICE = ""
AREA_SHORT = ""
SCHOOL_ID = ""  # รหัสสถานศึกษา (DMC)

DIRECTOR_NAME = ""
ACADEMIC_HEAD_NAME = ""
REGISTRAR_NAME = ""
DEPT_HEAD_DEFAULT = ""

DB = "school_archive.db"

# app_settings key -> built-in fallback
_KEYS = {
    "school_name": "SCHOOL_NAME",
    "school_subdistrict": "SUBDISTRICT",
    "school_district": "DISTRICT",
    "school_province": "PROVINCE",
    "school_area_office": "AREA_OFFICE",
    "school_area_short": "AREA_SHORT",
    "school_id": "SCHOOL_ID",
}


def strip_prefix(name: str) -> str:
    return re.sub(r"^โรงเรียน\s*", "", str(name or "")).strip()


def get(key: str, db_path: str = DB) -> str:
    """A school identity value: the admin's setting if there is one, otherwise this copy's built-in value."""
    fallback = globals()[_KEYS[key]]
    try:
        from database import get_app_setting
        saved = (get_app_setting(key, "", db_path=db_path) or "").strip()
    except Exception:
        saved = ""
    if key == "school_name":
        saved = strip_prefix(saved)
    return saved or fallback


def short_name(db_path: str = DB) -> str:
    """ชื่อโรงเรียนไม่มีคำว่า "โรงเรียน" นำหน้า (ช่อง B5 หน้าปก ปพ.5)"""
    return get("school_name", db_path)


def full_name(db_path: str = DB) -> str:
    """"โรงเรียน…" or "" when the school has not been set up yet."""
    s = short_name(db_path)
    return f"โรงเรียน{s}" if s else ""


def director_title(db_path: str = DB) -> str:
    s = short_name(db_path)
    return f"ผู้อำนวยการโรงเรียน{s}" if s else "ผู้อำนวยการโรงเรียน"


def banner_line(db_path: str = DB) -> str:
    """โรงเรียน…  สำนักงานเขตพื้นที่การศึกษา… (หัวรายงาน)"""
    return "  ".join(x for x in (full_name(db_path), get("school_area_office", db_path)) if x)


def info(db_path: str = DB) -> Dict[str, str]:
    """Everything the app shows about the school, for the API."""
    out = {k: get(k, db_path) for k in _KEYS}
    out["full_school_name"] = full_name(db_path)
    out["director_title"] = director_title(db_path)
    return out


def personnel_head_code(db_path: str = DB) -> str:
    """รหัสครูหัวหน้าบุคคล (บันทึกการลาแทนครูทุกคน + พิมพ์รายงาน): setting, else this school's built-in one."""
    try:
        from database import get_app_setting
        saved = (get_app_setting("personnel_head_code", "", db_path=db_path) or "").strip()
    except Exception:
        saved = ""
    if saved:
        return saved
    b = builtin()
    return getattr(b, "PERSONNEL_HEAD_CODE", "") if b else ""


def is_personnel_head(code, db_path: str = DB) -> bool:
    head = personnel_head_code(db_path)
    return bool(head) and str(code or "").strip() == head


def default_advisors():
    """Class advisors seeded into an empty database (this school only)."""
    b = builtin()
    return list(getattr(b, "ADVISORS", [])) if b else []


def default_signatories() -> Dict[str, object]:
    """Signatories before the admin has saved any (blank edition: names empty, titles generic)."""
    return {
        "director_name": DIRECTOR_NAME,
        "director_title": f"ผู้อำนวยการโรงเรียน{SCHOOL_NAME}" if SCHOOL_NAME else "ผู้อำนวยการโรงเรียน",
        "academic_head_name": ACADEMIC_HEAD_NAME,
        "academic_head_title": "หัวหน้างานวิชาการ",
        "registrar_name": REGISTRAR_NAME,
        "registrar_title": "งานทะเบียน-วัดผล",
        "dept_head_default": DEPT_HEAD_DEFAULT,
        "dept_heads": {},
        "school_name": f"โรงเรียน{SCHOOL_NAME}" if SCHOOL_NAME else "",
    }
