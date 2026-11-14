"""
Server-side authentication and authorisation for the ปพ.5 API.

Sessions
  * Login (teacher code + PIN) returns a signed token (HMAC-SHA256, Python stdlib only).
    It is set as an HttpOnly cookie, so images, PDF links and downloads on the same site work
    without changes, and is also returned in the body for `Authorization: Bearer` use
    (e.g. a front end hosted on another domain).
  * The token carries a fingerprint of the teacher's current PIN: changing a PIN signs every
    old session of that teacher out.
  * The signing secret comes from SCHOOL_AUTH_SECRET or auth_secret.txt (created once, git-ignored,
    carried to the Linux server by deploy/make_migration_bundle.py) so sessions survive a move.

Roles
  guest    -> timetable only (no student data)
  teacher  -> reads everything; writes only own courses (see require_course_owner)
  director -> reads everything; no writes except own PIN
  admin    -> everything
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

COOKIE_NAME = "pp5_session"
SESSION_SECONDS = 14 * 24 * 3600
_SECRET_FILE = Path(__file__).resolve().parent / "auth_secret.txt"
_secret_lock = threading.Lock()
_secret: Optional[bytes] = None


def _get_secret() -> bytes:
    global _secret
    if _secret is not None:
        return _secret
    with _secret_lock:
        if _secret is None:
            env = os.environ.get("SCHOOL_AUTH_SECRET", "").strip()
            if env:
                _secret = env.encode()
            else:
                if not _SECRET_FILE.exists():
                    _SECRET_FILE.write_text(secrets.token_urlsafe(48), encoding="utf-8")
                    try:
                        os.chmod(_SECRET_FILE, 0o600)
                    except OSError:
                        pass
                _secret = _SECRET_FILE.read_text(encoding="utf-8").strip().encode()
    return _secret


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def pin_fingerprint(pin: str) -> str:
    """Short keyed hash of the PIN: lets a token be revoked by changing the PIN, without storing the PIN."""
    return hmac.new(_get_secret(), f"pin:{pin}".encode(), hashlib.sha256).hexdigest()[:16]


def issue_token(user: Dict[str, Any], pin: Optional[str]) -> str:
    payload = {
        "code": user.get("code") or "",
        "name": user.get("name") or "",
        "role": user["role"],
        "pv": pin_fingerprint(pin) if pin is not None else "",
        "exp": int(time.time()) + SESSION_SECONDS,
    }
    body = _b64(json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode())
    sig = _b64(hmac.new(_get_secret(), body.encode(), hashlib.sha256).digest())
    return f"{body}.{sig}"


def read_token(token: str) -> Optional[Dict[str, Any]]:
    try:
        body, sig = token.split(".", 1)
        expected = _b64(hmac.new(_get_secret(), body.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(sig, expected):
            return None
        payload = json.loads(_unb64(body))
        if int(payload.get("exp", 0)) < time.time():
            return None
        return payload
    except Exception:
        return None


# ---------------------------------------------------------------- PIN check cache
_pin_cache: Dict[str, Tuple[float, Optional[str]]] = {}
_PIN_CACHE_SECONDS = 30


def current_pin(code: str, db_path: str = "school_archive.db") -> Optional[str]:
    """The PIN a teacher logs in with now (login_pin, falling back to the code as the old system did)."""
    now = time.time()
    hit = _pin_cache.get(code)
    if hit and now - hit[0] < _PIN_CACHE_SECONDS:
        return hit[1]
    import database
    pin: Optional[str] = None
    with database.get_connection(db_path) as conn:
        row = conn.execute("SELECT code, login_pin FROM school_teachers WHERE code = ?;", (code,)).fetchone()
        if row:
            pin = (row["login_pin"] or row["code"] or "").strip() or code
        elif conn.execute("SELECT 1 FROM system_admins WHERE teacher_code = ?;", (code,)).fetchone():
            pin = code
    _pin_cache[code] = (now, pin)
    return pin


def forget_pin_cache(code: Optional[str] = None) -> None:
    """Call after PINs or admins change so sessions are re-checked immediately."""
    if code is None:
        _pin_cache.clear()
        _admin_cache.clear()
    else:
        _pin_cache.pop(code, None)
        _admin_cache.pop(code, None)


def user_from_token(token: Optional[str]) -> Optional[Dict[str, Any]]:
    if not token:
        return None
    payload = read_token(token)
    if not payload:
        return None
    if payload["role"] == "guest":
        return payload
    if payload["role"] == "student":
        # a student who was locked (ย้าย/พักการเรียน) or removed loses access at once
        return payload if student_can_log_in(payload["code"]) else None
    pin = current_pin(payload["code"])
    if pin is None or not hmac.compare_digest(pin_fingerprint(pin), payload.get("pv", "")):
        return None  # teacher removed or PIN changed since this session started
    # Admin rights follow system_admins now, not what they were at login
    if is_admin_now(payload["code"]):
        payload["role"] = "admin"
    elif payload["role"] == "admin":
        payload["role"] = "teacher"
    return payload


_admin_cache: Dict[str, Tuple[float, bool]] = {}
_student_cache: Dict[str, Tuple[float, Optional[Dict[str, Any]]]] = {}


def find_active_student(student_id: str, db_path: str = "school_archive.db") -> Optional[Dict[str, Any]]:
    """Latest-semester class record of an active, not-locked student (None if none)."""
    now = time.time()
    hit = _student_cache.get(student_id)
    if hit and now - hit[0] < _PIN_CACHE_SECONDS:
        return hit[1]
    import database
    with database.get_connection(db_path) as conn:
        row = conn.execute(
            """
            SELECT cs.student_id, cs.full_name, cs.class_level, cs.room, cs.student_no, cs.term, cs.year,
                   COALESCE(cs.is_locked, 0) AS is_locked, COALESCE(cs.is_active, 1) AS is_active
            FROM class_students cs
            WHERE cs.student_id = ?
            ORDER BY CAST(cs.year AS INTEGER) DESC, CAST(cs.term AS INTEGER) DESC LIMIT 1;
            """,
            (student_id,)
        ).fetchone()
    rec = dict(row) if row and not row["is_locked"] and row["is_active"] else None
    _student_cache[student_id] = (now, rec)
    return rec


def student_can_log_in(student_id: str) -> bool:
    return find_active_student(student_id) is not None


def check_student_password(student_id: str, password: str) -> bool:
    """Students log in with their student ID (with the leading 0) as both username and password."""
    sid = (student_id or "").strip()
    return bool(sid) and hmac.compare_digest(sid, (password or "").strip()) and student_can_log_in(sid)


def is_admin_now(code: str, db_path: str = "school_archive.db") -> bool:
    now = time.time()
    hit = _admin_cache.get(code)
    if hit and now - hit[0] < _PIN_CACHE_SECONDS:
        return hit[1]
    import database
    with database.get_connection(db_path) as conn:
        flag = conn.execute("SELECT 1 FROM system_admins WHERE teacher_code = ?;", (code,)).fetchone() is not None
    _admin_cache[code] = (now, flag)
    return flag


# ---------------------------------------------------------------- login throttling
_fail_lock = threading.Lock()
_failures: Dict[str, list] = {}
MAX_FAILURES = 5
LOCK_SECONDS = 5 * 60


def login_blocked_for(key: str) -> int:
    """Seconds left before this client/code may try again (0 = allowed)."""
    with _fail_lock:
        times = [t for t in _failures.get(key, []) if time.time() - t < LOCK_SECONDS]
        _failures[key] = times
        if len(times) >= MAX_FAILURES:
            return int(LOCK_SECONDS - (time.time() - times[0])) + 1
    return 0


def record_login_failure(*keys: str) -> None:
    with _fail_lock:
        for k in keys:
            _failures.setdefault(k, []).append(time.time())


def clear_login_failures(*keys: str) -> None:
    with _fail_lock:
        for k in keys:
            _failures.pop(k, None)


def client_ip(request) -> str:
    fwd = request.headers.get("x-forwarded-for", "")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "?"


# ---------------------------------------------------------------- request rules
READ_METHODS = {"GET", "HEAD", "OPTIONS"}

# Needed before anyone logs in (login screen: theme, logo, semesters)
PUBLIC_GET = [
    r"/api/health",
    r"/api/v1/current-semester",
    r"/api/v1/settings/school-theme",
    r"/api/v1/settings/school-logo(/info)?",
    r"/api/v1/settings/semesters",
    r"/api/v1/recovery/status",
    r"/api/v1/school-profile",                   # login page / report headers: school name and address                  # เครื่องลงใหม่ ฐานข้อมูลว่าง: เปิดหน้ากู้คืน
    r"/api/public/v1(/.*)?",                     # เว็บอื่นดึงแดชบอร์ด (ตัวเลขสรุป) + ตารางสอนครู — public_api.py
]
PUBLIC_WRITE = [
    r"/api/v1/auth/(login-teacher|login-student|guest|logout)",
    r"/api/v1/recovery/restore",
    r"/api/v1/setup/new-school",                 # endpoint checks: empty database + server screen only                 # endpoint ตรวจเอง: ฐานข้อมูลว่าง + หน้าจอเครื่องเซิร์ฟเวอร์เท่านั้น
]
# Guests (บุคคลทั่วไป): timetable + the dashboard with every student's name/ID masked
# (masking is done in those endpoints with mask_students_for_guest)
GUEST_GET = [
    r"/api/v1/timetables",
    r"/api/v1/timetables/master-roster",
    r"/api/v1/auth/me",
    r"/api/v1/dashboard/attendance-overview",
    r"/api/v1/dashboard/attendance-risk",
]
# Students: only their own attendance
STUDENT_GET = [
    r"/api/v1/auth/me",
    r"/api/v1/student-portal/me",
    r"/api/v1/student-portal/timetable",   # ตารางเรียนของชั้นตนเอง (ระดับชั้นมาจากรหัสที่ล็อกอิน)
    r"/api/v1/student-portal/exams",
    r"/api/v1/student-portal/exams/\d+/photo/[A-Za-z0-9_.]+",
    r"/api/v1/student-portal/quizzes",           # แบบทดสอบย่อยของวิชาที่ลงทะเบียน
    r"/api/v1/student-portal/photo",             # รูปของตนเองเท่านั้น (รหัสมาจากที่ล็อกอิน)
    r"/api/v1/exam-images/[0-9a-f]{32}\.jpg",     # pictures in the paper being sat
]
# Students sit their own exams (enrolment and the exam window are checked in exams.py)
STUDENT_WRITE = [
    r"/api/v1/student-portal/exams/\d+/(start|answers|submit|photo|photo/delete)",
    r"/api/v1/student-portal/quizzes/\d+/(start|answers|submit)",
]
# Writes a teacher may make; ownership is checked inside the endpoint where it applies
TEACHER_WRITE = [
    r"/api/v1/attendance",                       # own course (endpoint check)
    r"/api/v1/courses/scores",                   # own course (endpoint check)
    r"/api/v1/course-description",               # own course (endpoint check)
    r"/api/v1/process-pdf",
    r"/api/v1/process-multiple-pdfs",
    r"/api/v1/teachers/[^/]+/pin",               # own PIN (endpoint check)
    r"/api/v1/home-visits/[^/]+(/upload-photo|/photo)?",
    r"/api/v1/daily-attendance(/grid|/student/toggle-lock)?",  # class advisor (endpoint check)
    r"/api/v1/timetables/cascade-late",          # class advisor (endpoint check)
    r"/api/v1/timetables(/\d+(/move)?)?",          # own slots only (endpoint check)
    r"/api/v1/students/export-dmc",
    r"/api/v1/exams/(paper|paper/delete|parse-text|parse-file|image|reset-attempt|mark|permit|block-ms)",  # own course (endpoint check)
    r"/api/v1/exams/windows",                    # admin (endpoint check)
    r"/api/v1/quizzes(/links|/\d+/(delete|reset))?",  # own course (endpoint check)
    r"/api/v1/students/[^/]+/name",              # class advisor (endpoint check)
    r"/api/v1/students/[^/]+/photo(/delete)?",   # class advisor (endpoint check): upload one photo / delete
    r"/api/v1/student-photos/(stage|commit|cancel)",  # class advisor: own levels only (student_photos.py)
    r"/api/v1/settings/semesters/mark-mine",     # own view only
    r"/api/v1/leaves(/.*)?",                     # teacher leave / late arrival (endpoint check)
]
# ผู้อำนวยการ: ดูได้ทุกหน้า แต่แก้ไข อัปโหลด ดาวน์โหลดไม่ได้ และล็อกหน้าบันทึกคะแนนกับหน้าตั้งค่า
# Reads that hand over a file to keep (templates, exports, the ปพ.5 and home-visit files).
# Viewing on screen stays open: /api/v1/course-pdf-page (page images), the logos, exam photos, and
# /api/v1/course-file, which is left out of this list so the endpoint can allow its inline PDF view
# and refuse the rest itself.
DIRECTOR_NO_DOWNLOAD = [
    r"/api/v1/download/.*",
    r"/api/v1/dashboard/attendance-summary-pdf",
    r"/api/v1/students/(template|export-dmc|dmc-columns)",
    r"/api/v1/advisors/template",
    r"/api/v1/courses/template",
    r"/api/v1/timetables/template",
    r"/api/v1/home-visits/[^/]+/(docx|pdf|docx-frameless)",
    r"/api/v1/home-visits-summary/(docx|pdf|docx-frameless)",
]
# หน้าบันทึกคะแนน: ผู้อำนวยการและบุคคลทั่วไปเข้าไม่ได้ (เมนูถูกล็อกไว้อยู่แล้ว ฝั่งเซิร์ฟเวอร์กันซ้ำอีกชั้น)
DIRECTOR_NO_GET = [
    r"/api/v1/courses/scores",
]
# Reads only an admin may make
ADMIN_GET = [
    r"/api/v1/backups(/.*)?",
    r"/api/v1/school-import/template",           # carries เลขบัตรประชาชน
    r"/api/v1/system/admins",
    r"/api/v1/settings/public-api(/.*)?",        # การตั้งค่า API สาธารณะ + โค้ดสำหรับวาง
]
# เลขบัตรประชาชน is admin-only: endpoints that can carry it blank it for other roles
# (export-dmc). Keep scratch/scan_citizen_id.py passing when adding endpoints.


def _match(patterns, path: str) -> bool:
    return any(re.fullmatch(p, path) for p in patterns)


def check_access(method: str, path: str, user: Optional[Dict[str, Any]]) -> Optional[Tuple[int, str]]:
    """None when allowed, else (status, message)."""
    if not path.startswith("/api/"):
        return None  # web app files
    is_read = method in READ_METHODS
    if (is_read and _match(PUBLIC_GET, path)) or (not is_read and _match(PUBLIC_WRITE, path)):
        return None
    if user is None:
        return 401, "กรุณาเข้าสู่ระบบ"
    role = user["role"]
    if role == "admin":
        return None
    if role == "guest":
        if is_read and _match(GUEST_GET, path):
            return None
        return 403, "บุคคลทั่วไปดูได้เฉพาะแดชบอร์ด (ไม่แสดงชื่อ) และตารางสอน กรุณาเข้าสู่ระบบ"
    if role == "student":
        if (is_read and _match(STUDENT_GET, path)) or (not is_read and _match(STUDENT_WRITE, path)):
            return None
        return 403, "นักเรียนดูได้เฉพาะข้อมูลการมาเรียนและข้อสอบของตนเอง"
    if is_read:
        if _match(ADMIN_GET, path):
            return 403, "เฉพาะผู้ดูแลระบบ"
        if role == "director":
            if _match(DIRECTOR_NO_DOWNLOAD, path):
                return 403, "ผู้อำนวยการดูข้อมูลบนหน้าจอได้ แต่ดาวน์โหลดไฟล์ไม่ได้"
            if _match(DIRECTOR_NO_GET, path):
                return 403, "หน้าบันทึกคะแนนสงวนไว้สำหรับครูประจำวิชา"
        return None
    if role == "director":
        if re.fullmatch(r"/api/v1/teachers/[^/]+/pin", path) or path == "/api/v1/settings/semesters/mark-mine" or re.fullmatch(r"/api/v1/leaves/\d+/status", path):
            return None
        return 403, "ผู้อำนวยการดูข้อมูลได้อย่างเดียว แก้ไขหรืออัปโหลดไม่ได้"
    if _match(TEACHER_WRITE, path):
        return None
    return 403, "เฉพาะผู้ดูแลระบบ"


MASK = "******"
_IDENTITY_KEYS = {"full_name", "student_name", "first_name", "last_name", "student_id", "citizen_id", "prefix", "title"}


def mask_students_for_guest(data: Any) -> Any:
    """บุคคลทั่วไป: keep counts and class levels, hide who the students are."""
    if isinstance(data, list):
        return [mask_students_for_guest(x) for x in data]
    if isinstance(data, dict):
        is_student = "student_id" in data or "full_name" in data
        out = {}
        for k, v in data.items():
            if is_student and k in _IDENTITY_KEYS:
                out[k] = MASK
            elif is_student and k in ("student_no", "class_no"):
                out[k] = 0
            elif is_student and k in ("absence_pattern",):
                out[k] = None
            else:
                out[k] = mask_students_for_guest(v)
        return out
    return data


def role_for(user: Dict[str, Any]) -> str:
    if user.get("is_admin"):
        return "admin"
    if user.get("is_director"):
        return "director"
    return "teacher"


# ---------------------------------------------------------------- ownership checks (used in endpoints)
def _base_name(name: str) -> str:
    import database
    try:
        return database.normalize_teacher_base_name(name or "")
    except Exception:
        return re.sub(r"^(ครู|นางสาว|นาง|นาย|ว่าที่ร้อยตรี)\s*", "", (name or "").strip())


def owns_course(user: Dict[str, Any], course_code: str, term: Optional[str], year: Optional[str], db_path: str = "school_archive.db") -> bool:
    if user.get("role") == "admin":
        return True
    import database
    with database.get_connection(db_path) as conn:
        if term and year:
            rows = conn.execute("SELECT teacher, teacher_code FROM courses WHERE course_code = ? AND term = ? AND year = ?;", (course_code, str(term), str(year))).fetchall()
        else:
            rows = conn.execute("SELECT teacher, teacher_code FROM courses WHERE course_code = ?;", (course_code,)).fetchall()
    me = _base_name(user.get("name", ""))
    for r in rows:
        if (r["teacher_code"] or "").strip() and r["teacher_code"].strip() == user.get("code"):
            return True
        if me and _base_name(r["teacher"] or "") == me:
            return True
    return False


def advises_class(user: Dict[str, Any], class_level: str, term: str, year: str, db_path: str = "school_archive.db") -> bool:
    if user.get("role") == "admin":
        return True
    import database
    me = _base_name(user.get("name", ""))
    with database.get_connection(db_path) as conn:
        row = conn.execute(
            "SELECT advisor1, advisor2, advisor3 FROM class_advisors WHERE term = ? AND year = ? AND class_level = ?;",
            (str(term), str(year), str(class_level))
        ).fetchone()
        try:  # advisors of each room (import form) advise their level too
            rooms = conn.execute(
                "SELECT advisor1, advisor2, advisor3 FROM class_rooms WHERE term = ? AND year = ? AND class_level = ?;",
                (str(term), str(year), str(class_level))
            ).fetchall()
        except Exception:
            rooms = []
    names = [a for r in ([row] if row else []) + list(rooms) for a in (r["advisor1"], r["advisor2"], r["advisor3"])]
    return bool(me and any(_base_name(a or "") == me for a in names))
