import os
# openpyxl imports numpy, and numpy's OpenBLAS then starts one idle thread per CPU core and reserves memory for each
# (measured 2026-11-11 on Windows: 19 threads / 555 MB committed, 4 threads / 69 MB with this). The server does no
# matrix maths, so one thread is enough. It must be set before the first import that pulls in openpyxl.
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
import database
import attendance_rules
import auth
import home_visit_exporter
import exams
import quizzes
import exam_import
import exam_timetable
import student_photos
import pp5_labels
import school_profile
from urllib.parse import quote
# CRITICAL WDAC WORKAROUND for pdfplumber parsing on Windows
os.environ["CHARSET_NORMALIZER_USE_MYPYC"] = "0"

import re
import sqlite3
import time
import threading
import io
from PIL import Image, ImageOps
import sys
import shutil
from pathlib import Path
from typing import Optional, List, Dict, Any
from pydantic import BaseModel
from fastapi import FastAPI, UploadFile, File, Form, HTTPException, BackgroundTasks, Query, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
import uvicorn

# Set console encoding to UTF-8
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

import json
from datetime import datetime

# Import the core logic
from excel_mapper import (
    process_sgs_pdf,
    update_course_description_in_file,
    update_course_attendance_in_file,
    format_and_fit_course_description,
    normalize_attendance_status_list,
    create_default_status_list,
    calculate_schedule_dates,
    sync_advisors_to_excel,
    sync_cover_sheet_to_excel,
    infer_class_level,
    _get_periods_for_day,
    find_course_matching_file,
    get_approval_date_str,
    sync_signatories_to_existing_excels,
    get_effective_pp5_logo_path,
    sync_all_excel_logos
)
from database import (
    init_db,
    query_grades_by_semester,
    query_student_transcript,
    get_connection,
    get_course_description,
    update_course_description,
    update_course_attendance_batch,
    get_course_schedule,
    update_course_schedule,
    get_semester_configs,
    set_default_semester,
    upsert_semester_config,
    delete_semester_config,
    reset_semester_configs_to_defaults,
    delete_semester_data,
    reset_all_data,
    get_class_advisors,
    get_advisor_for_class,
    upsert_class_advisor,
    delete_class_advisor,
    bulk_upsert_class_advisors,
    copy_class_advisors_from_semester,
    update_course_teacher,
    normalize_teacher_name,
    get_school_teachers,
    get_school_teachers_with_code,
    add_school_teacher,
    update_school_teacher,
    bulk_add_school_teachers,
    delete_school_teacher,
    sync_school_teachers_from_system,
    get_school_signatories,
    get_all_school_signatories,
    upsert_school_signatories,
    copy_school_signatories,
    resolve_signatories_for_course,
    get_class_levels_for_semester,
    get_students_for_class_level,
    get_daily_attendance_records,
    save_daily_attendance_batch,
    get_daily_attendance_school_summary,
    get_daily_attendance_dates_map,
    get_class_students,
    add_class_student,
    remove_class_student,
    get_daily_attendance_grid,
    save_daily_attendance_grid,
    get_all_levels_attendance_summary,
    copy_class_students_from_semester,
    get_attendance_dashboard,
    get_student_monthly_attendance_detail,
    preview_dmc_file,
    import_students_from_dmc,
    toggle_class_student_lock,
    get_app_setting,
    set_app_setting
)
from excel_parser import ingest_excel_file, batch_ingest_excel_folder

# Initialize and ensure DB migration
init_db("school_archive.db")

app = FastAPI(
    title="SGS to ปพ.5 API",
    description="Offline/Online School Grading Management System API",
    version="1.0.0"
)

# FastAPI's API pages list every endpoint of the system: an admin only (owner's decision 9 พ.ย. 2569)
_DOCS_PATHS = {"/docs", "/docs/oauth2-redirect", "/redoc", "/openapi.json"}


@app.middleware("http")
async def require_login(request: Request, call_next):
    """
    Every /api request needs a session (auth.py): cookie set at login, `Authorization: Bearer`
    or `?access_token=` (for links opened outside the app). Roles decide what is allowed;
    course/class ownership is checked inside the endpoints that write.
    """
    token = request.cookies.get(auth.COOKIE_NAME)
    header = request.headers.get("authorization", "")
    if header.lower().startswith("bearer "):
        token = header[7:].strip()
    elif not token:
        token = request.query_params.get("access_token")
    user = auth.user_from_token(token) if token else None
    request.state.user = user
    if request.url.path in _DOCS_PATHS and (user or {}).get("role") != "admin":
        return JSONResponse(status_code=404, content={"detail": "Not Found"})
    denied = auth.check_access(request.method, request.url.path, user)
    if denied:
        return JSONResponse(status_code=denied[0], content={"detail": denied[1]})
    return await call_next(request)


def current_user(request: Request) -> Dict[str, Any]:
    return getattr(request.state, "user", None) or {}


def require_course_owner(request: Request, course_code: str, term: Optional[str], year: Optional[str]) -> None:
    """Teachers may change only the courses they teach; admins any course."""
    if not auth.owns_course(current_user(request), course_code, term, year):
        raise HTTPException(status_code=403, detail=f"บันทึกได้เฉพาะวิชาที่ท่านสอน ({course_code} ไม่ใช่วิชาของท่าน)")


def require_class_advisor(request: Request, class_level: str, term: str, year: str) -> None:
    """Homeroom (daily) attendance is kept by the class advisors of that level, or an admin."""
    if not auth.advises_class(current_user(request), class_level, term, year):
        raise HTTPException(status_code=403, detail=f"บันทึกเวลาเรียนรวมได้เฉพาะครูที่ปรึกษาชั้น {class_level} หรือผู้ดูแลระบบ")


def hide_pins_unless_admin(request: Request, data: Any) -> Any:
    """Teacher lists include login PINs: only admins may see them."""
    if current_user(request).get("role") == "admin":
        return data
    if isinstance(data, list):
        return [hide_pins_unless_admin(request, x) for x in data]
    if isinstance(data, dict):
        return {k: hide_pins_unless_admin(request, v) for k, v in data.items() if k != "login_pin"}
    return data


# Enable CORS for Flutter Web / Desktop frontend. No cross-site cookies: another origin
# (e.g. a front end on Cloudflare Pages) authenticates with the Bearer token instead.
# Added after require_login so CORS headers also wrap its 401/403 answers.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.middleware("http")
async def add_cache_control_headers(request, call_next):
    """
    Web app files are revalidated with their ETag on every load ("no-cache"): unchanged files
    answer 304 with no body, so a reload no longer re-downloads ~15 MB of JS/WASM, yet a new
    build is picked up immediately. Fonts and images under /assets/ change rarely: cache 1 day.
    """
    response = await call_next(request)
    path = request.url.path
    if path.startswith("/api/"):
        return response
    if path.startswith("/assets/") and any(path.endswith(ext) for ext in (".otf", ".ttf", ".woff", ".woff2", ".png", ".jpg", ".svg")):
        response.headers["Cache-Control"] = "public, max-age=86400"
    elif path == "/" or any(path.endswith(ext) for ext in (".html", ".js", ".json", ".otf", ".ttf", ".woff", ".woff2", ".wasm", ".css", ".map", ".mjs")):
        response.headers["Cache-Control"] = "no-cache"
    return response


# Browsers that installed Flutter's service worker kept running the old app after an update. The app no longer
# registers one (frontend/web/flutter_bootstrap.js); this script replaces the old worker: it clears its caches,
# unregisters itself and reloads the page, so the next visit loads the current build.
_SW_KILL = """// no service worker: remove the old one and its caches, then reload with the current app
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const k of await caches.keys()) { await caches.delete(k); }
    await self.registration.unregister();
    for (const c of await self.clients.matchAll({ type: 'window' })) { c.navigate(c.url); }
  })());
});
"""


@app.get("/flutter_service_worker.js", include_in_schema=False)
def flutter_service_worker_kill():
    return Response(_SW_KILL, media_type="application/javascript", headers={"Cache-Control": "no-cache, no-store, must-revalidate"})


# Compress JSON / JS / WASM (main.dart.js ~4 MB, Excel preview JSON ~750 KB) — large win over ngrok
from fastapi.middleware.gzip import GZipMiddleware
app.add_middleware(GZipMiddleware, minimum_size=1024, compresslevel=6)

def compute_current_semester_from_clock(dt=None) -> tuple[str, str]:
    """
    Calculate current academic semester and BE year from system clock:
    - 1 เม.ย. - 10 ต.ค. เป็น ภาคเรียนที่ 1 ของปีนั้น
    - 11 ต.ค. - 30 มี.ค. เป็น ภาคเรียนที่ 2 ของปีการศึกษานั้น
    """
    if dt is None:
        dt = datetime.now()
    year_be = dt.year + 543
    m, d = dt.month, dt.day
    # 1 เม.ย. - 10 ต.ค. (ตั้งแต่ 1 เมษายน จนถึง 10 ตุลาคม)
    if (m > 4 or (m == 4 and d >= 1)) and (m < 10 or (m == 10 and d <= 10)):
        return "1", str(year_be)
    else:
        # 11 ต.ค. - 30 มี.ค. (ถ้าเดือน 1-3 ปีการศึกษาคือปีที่แล้ว)
        if m <= 3:
            return "2", str(year_be - 1)
        else:
            return "2", str(year_be)

@app.get("/api/v1/current-semester")
def get_current_semester_api():
    try:
        saved_def = get_app_setting("default_semester", db_path="school_archive.db")
        if saved_def and "-" in saved_def:
            parts = saved_def.strip().split("-", 1)
            if len(parts) == 2 and parts[0] and parts[1]:
                t_def, y_def = parts[0].strip(), parts[1].strip()
                return {
                    "status": "success",
                    "term": t_def,
                    "year": y_def,
                    "title": f"ปีการศึกษา {y_def} ภาคเรียนที่ {t_def}"
                }
    except Exception:
        pass
    term, year = compute_current_semester_from_clock()
    return {
        "status": "success",
        "term": term,
        "year": year,
        "title": f"ปีการศึกษา {year} ภาคเรียนที่ {term}"
    }


# ---------------------------------------------------------------- API สาธารณะ: แดชบอร์ด (ตัวเลขสรุป) + ตารางสอนครู บนเว็บอื่น
import public_api


def _current_semester_tuple() -> tuple:
    d = get_current_semester_api()
    return str(d["term"]), str(d["year"])


app.include_router(public_api.make_router(_current_semester_tuple))


class PublicApiSettingsRequest(BaseModel):
    dashboard: Optional[bool] = None
    timetable: Optional[bool] = None
    base_url: Optional[str] = None


@app.get("/api/v1/settings/public-api")
def get_public_api_settings():
    """ผู้ดูแลระบบ: ชุดข้อมูลที่เปิดให้เว็บอื่นดึง + ที่อยู่เว็บของระบบที่ใส่ในโค้ดสำหรับวาง"""
    st = public_api.settings()
    return {"status": "success", "data": {**st, "default_base_url": public_api.default_base_url(),
                                          "effective_base_url": public_api.base_url()}}


@app.post("/api/v1/settings/public-api")
def save_public_api_settings(payload: PublicApiSettingsRequest):
    st = public_api.save_settings(payload.dict())
    return {"status": "success", "data": {**st, "default_base_url": public_api.default_base_url(),
                                          "effective_base_url": public_api.base_url()}}


@app.get("/api/v1/settings/public-api/snippet")
def get_public_api_snippet(view: str = Query("dashboard")):
    """โค้ด HTML สำหรับวางในเว็บอื่น (ใช้ที่อยู่เว็บที่ตั้งไว้)"""
    base = public_api.base_url()
    if not base:
        raise HTTPException(status_code=400, detail="ยังไม่ได้ตั้งที่อยู่เว็บของระบบ")
    return {"status": "success", "view": view, "base_url": base, "code": public_api.embed_snippet(view, base)}

UPLOAD_DIR = Path("uploads")
OUTPUT_DIR = Path("outputs")
UPLOAD_DIR.mkdir(exist_ok=True)
OUTPUT_DIR.mkdir(exist_ok=True)

class CourseDescriptionRequest(BaseModel):
    course_code: str
    description: str


class StudentAttendanceItem(BaseModel):
    student_id: str
    student_no: Optional[int] = None
    full_name: Optional[str] = None
    present_count: Optional[int] = 40
    absent_count: Optional[int] = 0
    leave_count: Optional[int] = 0
    percentage: Optional[float] = 100.0
    status_list: Optional[List[str]] = None


class CourseAttendanceRequest(BaseModel):
    course_code: str
    term: Optional[str] = None
    year: Optional[str] = None
    start_date: Optional[str] = None
    schedule: Optional[Dict[str, Any]] = None
    students: List[StudentAttendanceItem]


class DailyAttendanceStudentItem(BaseModel):
    student_id: str
    status: str = "present"
    note: Optional[str] = ""


class SaveDailyAttendanceRequest(BaseModel):
    term: str
    year: str
    class_level: str
    date: str
    records: List[DailyAttendanceStudentItem]


class SaveDailyAttendanceGridRequest(BaseModel):
    term: str
    year: str
    class_level: str
    start_date: str
    holidays: List[int] = []
    locked_counted: List[int] = []
    students: List[Dict[str, Any]]


class UpdateSemesterStartDateRequest(BaseModel):
    term: str
    year: str
    start_date: str


class ResetAllDailyAttendanceRequest(BaseModel):
    term: str
    year: str
    mode: Optional[str] = "empty"
    class_levels: Optional[List[str]] = None


class ImportClassStudentsRequest(BaseModel):
    from_term: str
    from_year: str
    to_term: str
    to_year: str
    from_class_level: Optional[str] = None
    to_class_level: Optional[str] = None
    all_levels: Optional[bool] = False
    overwrite: Optional[bool] = False


class AddClassStudentRequest(BaseModel):
    term: str
    year: str
    class_level: str
    student_id: str
    full_name: str
    student_no: Optional[int] = None
    note: Optional[str] = ""


class SemesterConfigRequest(BaseModel):
    id: Optional[int] = None
    term: str
    year: str
    title: str
    display_order: Optional[int] = 0
    is_active: Optional[bool] = True


class SemesterDataDeleteRequest(BaseModel):
    term: str
    year: str
    delete_files: Optional[bool] = False
    backup_first: Optional[bool] = False
    backup_label: Optional[str] = None


class ResetAllDataRequest(BaseModel):
    delete_files: Optional[bool] = False
    backup_first: Optional[bool] = False
    backup_label: Optional[str] = None


class BackupCreateRequest(BaseModel):
    label: Optional[str] = None
    term: Optional[str] = None
    year: Optional[str] = None
    backup_type: Optional[str] = "full"


class BackupRestoreRequest(BaseModel):
    backup_id: str
    mode: Optional[str] = "full"
    target_term: Optional[str] = None
    target_year: Optional[str] = None
    src_term: Optional[str] = None
    src_year: Optional[str] = None


class ClassAdvisorRequest(BaseModel):
    id: Optional[int] = None
    term: str
    year: str
    class_level: str
    advisor1: Optional[str] = ""
    advisor2: Optional[str] = ""
    advisor3: Optional[str] = ""


class CopyAdvisorsRequest(BaseModel):
    from_term: str
    from_year: str
    to_term: str
    to_year: str


class UpdateSignatoriesRequest(BaseModel):
    year: str
    school_name: Optional[str] = None
    director_name: Optional[str] = None
    director_title: Optional[str] = None
    academic_head_name: Optional[str] = None
    academic_head_title: Optional[str] = "หัวหน้างานวิชาการ"
    registrar_name: Optional[str] = None
    registrar_title: Optional[str] = "งานทะเบียน-วัดผล"
    dept_head_default: Optional[str] = None
    dept_heads: Optional[Dict[str, str]] = None
    sync_existing_files: Optional[bool] = True


class CopySignatoriesRequest(BaseModel):
    from_year: str
    to_year: str
    sync_existing_files: Optional[bool] = True


class UpdateCourseTeacherRequest(BaseModel):
    course_code: str
    teacher: str
    term: Optional[str] = None
    year: Optional[str] = None


@app.get("/api/health")
def health():
    # node: short fingerprint of the machine serving (Linux main / Windows standby), used by standby_sync.py
    from standby_sync import node_id
    return {"status": "ok", "message": "SGS Processing API is running.", "node": node_id()}


@app.post("/api/v1/process-pdf")
def upload_and_process_pdf(
    file: UploadFile = File(...),
    description: Optional[str] = Form(None),
    term: Optional[str] = Form(None),
    year: Optional[str] = Form(None),
    teacher: Optional[str] = Form(None)
):
    """
    Accepts an SGS PDF file, parses it, archives data in SQLite,
    injects into the Blank Excel template, and generates a print-ready PDF.
    """
    safe_name = Path((file.filename or "").replace("\\", "/")).name
    if not safe_name.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="Only PDF files are supported.")

    file_path = UPLOAD_DIR / safe_name
    try:
        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to save uploaded file: {str(e)}")

    try:
        base_name = file_path.stem
        excel_out = OUTPUT_DIR / f"{base_name}_ปพ5_filled.xlsx"
        pdf_out = OUTPUT_DIR / f"{base_name}_ปพ5_print_ready.pdf"
        
        # Call the core pipeline
        result = process_sgs_pdf(
            pdf_path=str(file_path),
            template_path="template_ปพ5_blank.xlsx",
            output_excel_path=str(excel_out),
            output_pdf_path=str(pdf_out),
            db_path="school_archive.db",
            course_description=description,
            override_term=term,
            override_year=year,
            override_teacher=teacher
        )
        
        # Add generated filenames for easy download linking
        result["excel_filename"] = excel_out.name
        result["pdf_filename"] = pdf_out.name
        
        return {"status": "success", "data": result}
        
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Processing failed: {str(e)}")


@app.post("/api/v1/process-multiple-pdfs")
def upload_and_process_multiple_pdfs(
    files: List[UploadFile] = File(...),
    term: Optional[str] = Form(None),
    year: Optional[str] = Form(None),
    teacher: Optional[str] = Form(None)
):
    """
    Accepts multiple SGS PDF files, processes each sequentially,
    archives in SQLite, populates Excel ปพ.5 and exports print-ready PDFs.
    Returns array of results with status for each file.
    """
    results = []
    for file in files:
        safe_name = Path((file.filename or "").replace("\\", "/")).name
        if not safe_name.lower().endswith(".pdf"):
            results.append({
                "filename": safe_name,
                "status": "error",
                "message": "Only PDF files are supported."
            })
            continue

        file_path = UPLOAD_DIR / safe_name
        try:
            with open(file_path, "wb") as buffer:
                shutil.copyfileobj(file.file, buffer)

            base_name = file_path.stem
            excel_out = OUTPUT_DIR / f"{base_name}_ปพ5_filled.xlsx"
            pdf_out = OUTPUT_DIR / f"{base_name}_ปพ5_print_ready.pdf"

            res = process_sgs_pdf(
                pdf_path=str(file_path),
                template_path="template_ปพ5_blank.xlsx",
                output_excel_path=str(excel_out),
                output_pdf_path=str(pdf_out),
                db_path="school_archive.db",
                override_term=term,
                override_year=year,
                override_teacher=teacher
            )
            res["excel_filename"] = excel_out.name
            res["pdf_filename"] = pdf_out.name
            results.append({
                "filename": safe_name,
                "status": "success",
                "data": res
            })
        except Exception as e:
            results.append({
                "filename": safe_name,
                "status": "error",
                "message": str(e)
            })
    return {"status": "success", "results": results}


@app.post("/api/v1/import-excel")
async def import_excel_endpoint(
    files: List[UploadFile] = File(...),
    term: Optional[str] = Form(None),
    year: Optional[str] = Form(None),
    teacher: Optional[str] = Form(None)
):
    """
    Import one or multiple Excel files (.xlsx) into the database/archive.
    Parses course headers, student lists, attendance marks, and grades.
    """
    results = []
    total_courses = 0
    total_students = 0

    for file in files:
        safe_name = Path((file.filename or "").replace("\\", "/")).name
        if not (safe_name.lower().endswith(".xlsx") or safe_name.lower().endswith(".xls")):
            results.append({
                "filename": safe_name,
                "status": "error",
                "message": "รองรับเฉพาะไฟล์ Excel (.xlsx, .xls) เท่านั้น"
            })
            continue

        try:
            content = await file.read()
            res = ingest_excel_file(
                content,
                filename=safe_name,
                override_term=term,
                override_year=year,
                override_teacher=teacher,
                db_path="school_archive.db"
            )
            results.append({
                "filename": safe_name,
                "status": "success",
                "course_code": res["course_code"],
                "course_name": res["course_name"],
                "term": res["term"],
                "year": res["year"],
                "teacher": res["teacher"],
                "students_count": res["students_upserted"],
                "output_excel": res["output_excel"]
            })
            total_courses += 1
            total_students += res["students_upserted"]
        except Exception as e:
            results.append({
                "filename": safe_name,
                "status": "error",
                "message": str(e)
            })

    return {
        "status": "success",
        "message": f"นำเข้าข้อมูลจาก Excel สำเร็จ {total_courses} รายวิชา (นักเรียนรวม {total_students} คน)",
        "total_courses": total_courses,
        "total_students": total_students,
        "results": results
    }


class ImportFolderRequest(BaseModel):
    folder_path: str
    term: Optional[str] = None
    year: Optional[str] = None
    teacher: Optional[str] = None


@app.post("/api/v1/import-excel-folder")
def import_excel_folder_endpoint(req: ImportFolderRequest):
    """
    Scan a local or OneDrive folder path for Excel files (.xlsx) and import all into archive.
    """
    try:
        data = batch_ingest_excel_folder(
            folder_path=req.folder_path,
            override_term=req.term,
            override_year=req.year,
            override_teacher=req.teacher,
            db_path="school_archive.db"
        )
        return {
            "status": "success",
            "message": f"สแกนและนำเข้าสำเร็จ {data['total_courses']} รายวิชา จากทั้งหมด {data['total_files']} ไฟล์",
            "data": data
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"การนำเข้าจากโฟลเดอร์ล้มเหลว: {str(e)}")


@app.get("/api/v1/course-description")
def get_course_description_api(course_code: str = Query(...)):
    """Retrieve stored course description and its auto-fitting metrics."""
    try:
        desc = get_course_description(course_code, db_path="school_archive.db") or ""
        _, font_size = format_and_fit_course_description(desc)
        return {
            "status": "success",
            "data": {
                "course_code": course_code,
                "description": desc,
                "font_size": font_size,
                "length": len(desc),
                "is_empty": not bool(desc.strip())
            }
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/course-description")
def save_course_description_api(payload: CourseDescriptionRequest, request: Request):
    """
    Save course description into database, auto-fit and inject into sheet (6) ตัวชี้วัด
    of the existing Excel file for this course, and regenerate the print-ready PDF.
    """
    require_course_owner(request, payload.course_code, getattr(payload, "term", None), getattr(payload, "year", None))
    try:
        result = update_course_description_in_file(
            course_code=payload.course_code,
            description=payload.description,
            db_path="school_archive.db",
            outputs_dir=str(OUTPUT_DIR)
        )
        return {"status": "success", "data": result}
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Failed to save course description: {str(e)}")


@app.get("/api/v1/attendance")
def get_attendance_api(
    course_code: str = Query(..., description="Course code (e.g. 'ค32202')"),
    term: Optional[str] = Query(None),
    year: Optional[str] = Query(None),
    sync_from_daily: bool = Query(False, description="Discard teacher overrides and take the daily attendance table as-is")
):
    """Retrieve the ปพ.5 roster (locked students excluded) and each student's course attendance."""
    try:
        db = "school_archive.db"
        with get_connection(db) as conn:
            cursor = conn.cursor()
            if not term or not year:
                cursor.execute("SELECT term, year FROM courses WHERE course_code = ? ORDER BY year DESC, term DESC LIMIT 1;", (course_code,))
                c_row = cursor.fetchone()
                if c_row:
                    term, year = c_row["term"], c_row["year"]
            term, year = str(term or "1"), str(year or "")

            roster = database.get_porpor5_roster(course_code, term, year, db_path=db)
            if not roster:
                # Legacy semesters may have grades without a class roster
                cursor.execute(
                    """
                    SELECT g.student_id, s.full_name FROM grades_history g
                    JOIN students s ON g.student_id = s.student_id
                    WHERE g.course_code = ? AND g.term = ? AND g.year = ?
                      AND g.student_id NOT IN (SELECT student_id FROM class_students WHERE term = ? AND year = ? AND is_locked = 1)
                    ORDER BY g.student_id ASC;
                    """,
                    (course_code, term, year, term, year)
                )
                roster = [{"student_no": None, "student_id": r["student_id"], "full_name": r["full_name"]} for r in cursor.fetchall()]

            cursor.execute(
                "SELECT student_id, attendance_json FROM grades_history WHERE course_code = ? AND term = ? AND year = ?;",
                (course_code, term, year)
            )
            att_by_id = {r["student_id"]: r["attendance_json"] for r in cursor.fetchall()}

        ctx = database.get_course_attendance_context(course_code, term, year, db_path=db)
        hours, activity, total = ctx["hours"], ctx["activity"], ctx["total"]
        student_ids = [st["student_id"] for st in roster]
        daily = database.get_daily_attendance_records_map(student_ids, ctx["dates"], db_path=db)
        has_daily = any(daily.values())
        legacy_schedule = {
            "mon": ctx["periods"][0], "tue": ctx["periods"][1], "wed": ctx["periods"][2],
            "thu": ctx["periods"][3], "fri": ctx["periods"][4], "holidays": sorted(ctx["holidays"]),
        }

        students_out = []
        for idx, st in enumerate(roster, start=1):
            sid = st["student_id"]
            try:
                att = json.loads(att_by_id.get(sid) or "{}") or {}
            except Exception:
                att = {}
            auto = attendance_rules.auto_status_list(daily.get(sid, {}), ctx["dates"], hours, activity, ctx["period_numbers"], ctx["elapsed"])
            status_list, manual = attendance_rules.resolve_status_list(att, auto, has_daily=has_daily, from_daily=sync_from_daily)
            if not any(status_list) and not has_daily and (att.get("present_count") or att.get("present")):
                # Imported semesters only carry counts
                p_c = int(att.get("present_count") or att.get("present") or 0)
                l_c = int(att.get("leave_count") or att.get("leave") or 0)
                status_list = create_default_status_list(p_c, l_c, max(0, total - p_c - l_c), total, schedule_dict=legacy_schedule)
            summ = attendance_rules.summarize(status_list, hours, activity, ctx["elapsed"])
            students_out.append({
                "student_id": sid,
                "student_no": idx,  # row number printed in the ปพ.5
                "class_no": st.get("student_no"),
                "full_name": st.get("full_name"),
                "present_count": summ["present_count"],
                "absent_count": summ["absent_count"],
                "leave_count": summ["leave_count"],
                "late_count": summ["late_count"],
                "percentage": summ["percentage"],
                "status_list": summ["status_list"],
                "manual_slots": manual,
                "total_periods": total,
                "elapsed_periods": summ["elapsed_periods"],
                "total_slots": attendance_rules.SLOTS
            })

        normalized_schedule = {
            "mon": ctx["periods"][0],
            "tue": ctx["periods"][1],
            "wed": ctx["periods"][2],
            "thu": ctx["periods"][3],
            "fri": ctx["periods"][4],
            "holidays": sorted(ctx["holidays"]),
            "locked_counted": sorted(activity),
            "slots": ctx["schedule_slots"],
            "slot_hours": hours
        }

        return {
            "status": "success",
            "data": {
                "course_code": course_code,
                "term": term,
                "year": year,
                "total_periods": total,
                "elapsed_slots": ctx["elapsed"],  # day-slots up to today: ขาด / ร้อยละ are counted up to here
                "elapsed_periods": sum(hours[:ctx["elapsed"]]),
                "today": attendance_rules.today_iso(),
                "total_slots": attendance_rules.SLOTS,
                "start_date": ctx["start_date"],
                "schedule": normalized_schedule,
                "slot_hours": hours,
                "computed_weeks": calculate_schedule_dates(start_date=ctx["start_date"], term=term, year_be=year),
                "students": students_out
            }
        }
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/attendance")
def save_attendance_api(payload: CourseAttendanceRequest, request: Request):
    """
    Save the teacher's ปพ.5 attendance: slots that differ from the daily table are kept as
    teacher overrides (manual_slots), totals follow attendance_rules, and the Excel file
    (sheets 2 & 3) plus the print-ready PDF are regenerated.
    """
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    try:
        db = "school_archive.db"
        course_code = payload.course_code
        term, year = payload.term, payload.year
        if not term or not year:
            with get_connection(db) as conn:
                c_row = conn.execute("SELECT term, year FROM courses WHERE course_code = ? ORDER BY year DESC, term DESC LIMIT 1;", (course_code,)).fetchone()
                if c_row:
                    term, year = term or c_row["term"], year or c_row["year"]
        term, year = str(term), str(year)

        # Holidays / activity days ticked in the dialog beyond the class calendar belong to this course only
        sched = payload.schedule or {}
        base_ctx = database.get_course_attendance_context(course_code, term, year, db_path=db)
        class_h, class_a = database.get_class_calendar(term, year, base_ctx["class_level"], db_path=db)
        req_h = attendance_rules.parse_slot_set(sched.get("holidays"))
        req_a = attendance_rules.parse_slot_set(sched.get("locked_counted"))
        database.set_course_attendance_config(course_code, term, year, req_h - class_h, req_a - class_a - req_h, db_path=db)

        ctx = database.get_course_attendance_context(course_code, term, year, db_path=db)
        hours, activity, total = ctx["hours"], ctx["activity"], ctx["total"]
        daily = database.get_daily_attendance_records_map([st.student_id for st in payload.students], ctx["dates"], db_path=db)
        has_daily = any(daily.values())
        legacy_schedule = {
            "mon": ctx["periods"][0], "tue": ctx["periods"][1], "wed": ctx["periods"][2],
            "thu": ctx["periods"][3], "fri": ctx["periods"][4], "holidays": sorted(ctx["holidays"]),
        }

        records = []
        for st in payload.students:
            submitted = attendance_rules.normalize_status_list(st.status_list)
            if not any(submitted) and not has_daily and st.present_count:
                submitted = create_default_status_list(
                    st.present_count, st.leave_count or 0, max(0, total - st.present_count - (st.leave_count or 0)),
                    total, schedule_dict=legacy_schedule
                )
            submitted = attendance_rules.clean_status_list(submitted, hours, activity, ctx["elapsed"])
            auto = attendance_rules.auto_status_list(daily.get(st.student_id, {}), ctx["dates"], hours, activity, ctx["period_numbers"], ctx["elapsed"])
            summ = attendance_rules.summarize(submitted, hours, activity, ctx["elapsed"])
            summ["manual_slots"] = attendance_rules.manual_slots_from(submitted, auto, hours) if has_daily else []
            records.append({"student_id": st.student_id, "student_no": st.student_no, "attendance": summ})

        result = update_course_attendance_in_file(
            course_code=course_code,
            records=records,
            term=term,
            year=year,
            outputs_dir=str(OUTPUT_DIR),
            db_path=db,
            regenerate_pdf=False  # Excel COM export takes ~7 s: done in the background instead
        )
        porpor5_refresh_queue.enqueue(term, year, [course_code], pdf_only=True)
        result["pdf_pending"] = True
        return {"status": "success", "data": result}
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Failed to update attendance: {str(e)}")


# -------------------------------------------------------------
# Daily School Attendance (เช็คเวลาเรียนรวมประจำวัน) Endpoints
# -------------------------------------------------------------
@app.get("/api/v1/daily-attendance/class-levels")
def get_daily_attendance_class_levels_api(
    term: str = Query(...),
    year: str = Query(...)
):
    """List available class levels for a semester."""
    try:
        levels = get_class_levels_for_semester(term=term, year=year, db_path="school_archive.db")
        return {"status": "success", "data": levels}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/daily-attendance")
def get_daily_attendance_api(
    term: str = Query(...),
    year: str = Query(...),
    class_level: str = Query(...),
    date: str = Query(..., description="Date formatted as YYYY-MM-DD")
):
    """Retrieve daily attendance records for a class level on a specific date."""
    try:
        data = get_daily_attendance_records(
            term=term,
            year=year,
            class_level=class_level,
            date_str=date,
            db_path="school_archive.db"
        )
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/daily-attendance")
def save_daily_attendance_api(payload: SaveDailyAttendanceRequest, request: Request):
    """Save daily attendance records for a class level on a specific date."""
    require_class_advisor(request, payload.class_level, payload.term, payload.year)
    try:
        records = [r.dict() for r in payload.records]
        count = save_daily_attendance_batch(
            term=payload.term,
            year=payload.year,
            class_level=payload.class_level,
            date_str=payload.date,
            records=records,
            db_path="school_archive.db"
        )
        return {
            "status": "success",
            "message": f"บันทึกข้อมูลการมาเรียนประจำวัน {payload.class_level} ({payload.date}) เรียบร้อยแล้ว ({count} คน)",
            "count": count
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/daily-attendance/summary")
def get_daily_attendance_summary_api(
    term: str = Query(...),
    year: str = Query(...),
    date: str = Query(...)
):
    """Retrieve school-wide attendance overview for all class levels on a specific date."""
    try:
        data = get_daily_attendance_school_summary(
            term=term,
            year=year,
            date_str=date,
            db_path="school_archive.db"
        )
        data["school_summary"] = data.get("class_summaries", [])
        data["school_total"] = {
            "total_students": data.get("total_students", 0),
            "present": data.get("present_count", 0),
            "absent": data.get("absent_count", 0),
            "leave": data.get("leave_count", 0),
            "late": data.get("late_count", 0),
            "percentage": data.get("attendance_percentage", 100.0)
        }
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/daily-attendance/grid")
def get_daily_attendance_grid_api(
    term: str = Query(...),
    year: str = Query(...),
    class_level: str = Query(...),
    room: Optional[str] = Query(None),
    start_date: Optional[str] = Query(None)
):
    """Retrieve 20-week (100 slots, Mon-Fri) attendance grid for a class level with optional room filter."""
    try:
        data = get_daily_attendance_grid(
            term=term,
            year=year,
            class_level=class_level,
            room=room,
            start_date_override=start_date,
            db_path="school_archive.db"
        )
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/daily-attendance/grid")
def save_daily_attendance_grid_api(payload: SaveDailyAttendanceGridRequest, request: Request):
    """Save 20-week attendance grid for a class level."""
    require_class_advisor(request, payload.class_level, payload.term, payload.year)
    try:
        res = save_daily_attendance_grid(
            term=payload.term,
            year=payload.year,
            class_level=payload.class_level,
            start_date=payload.start_date,
            holidays=payload.holidays,
            locked_counted=payload.locked_counted,
            students=payload.students,
            db_path="school_archive.db"
        )
        return res
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/daily-attendance/start-date")
def get_daily_attendance_start_date_api(
    term: str = Query(...),
    year: str = Query(...)
):
    """Retrieve the unified semester start date across all class levels."""
    try:
        sd = database.get_semester_start_date(term=term, year=year, db_path="school_archive.db")
        return {"status": "success", "start_date": sd}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/daily-attendance/start-date")
def set_daily_attendance_start_date_api(payload: UpdateSemesterStartDateRequest):
    """Update and unify the semester start date across all class levels for that semester."""
    try:
        before = database.get_semester_start_date(payload.term, payload.year, db_path="school_archive.db")
        sd = database.set_semester_start_date(
            term=payload.term,
            year=payload.year,
            start_date=payload.start_date,
            db_path="school_archive.db"
        )
        if sd != before:  # every slot now falls on another date: recount all courses (and their ปพ.5 rows 6-8)
            database.sync_semester_attendance_to_courses(payload.term, payload.year, db_path="school_archive.db")
        return {"status": "success", "start_date": sd}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/daily-attendance/reset-all-levels")
def reset_all_daily_attendance_api(payload: ResetAllDailyAttendanceRequest):
    """Reset daily attendance for all 6 class levels or selected levels in a semester."""
    try:
        res = database.reset_all_daily_attendance(
            term=payload.term,
            year=payload.year,
            mode=payload.mode or "empty",
            class_levels=payload.class_levels,
            db_path="school_archive.db"
        )
        return res
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/daily-attendance/student")
def add_class_student_api(payload: AddClassStudentRequest):
    """Add or transfer student into a class level (+ button)."""
    try:
        res = add_class_student(
            term=payload.term,
            year=payload.year,
            class_level=payload.class_level,
            student_id=payload.student_id,
            full_name=payload.full_name,
            student_no=payload.student_no,
            note=payload.note or "",
            db_path="school_archive.db"
        )
        # A student joining mid-semester belongs in every course of the class: enrol, take the
        # attendance from the daily table, and let the refresh queue rebuild those ปพ.5 rosters
        from timetable_manager import enroll_student_in_level_courses
        t, y, cl, sid = payload.term.strip(), payload.year.strip(), payload.class_level.strip(), payload.student_id.strip()
        enroll_student_in_level_courses(t, y, cl, sid, db_path="school_archive.db")
        database.sync_daily_attendance_to_courses(t, y, cl, student_ids=[sid], db_path="school_archive.db")
        # a new name on the roster changes every one of their ปพ.5 files, even before any attendance is counted
        database.notify_courses_changed(t, y, database.student_course_codes(sid, t, y, db_path="school_archive.db"))
        return res
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class ToggleStudentLockRequest(BaseModel):
    term: str
    year: str
    class_level: str
    student_id: str
    locked: Optional[bool] = None


@app.post("/api/v1/daily-attendance/student/toggle-lock")
def toggle_student_lock_api(payload: ToggleStudentLockRequest, request: Request):
    """Toggle or set student lock status. Locked students are not calculated and suppressed in PorPor5."""
    require_class_advisor(request, payload.class_level, payload.term, payload.year)
    try:
        res = toggle_class_student_lock(
            term=payload.term.strip(),
            year=payload.year.strip(),
            class_level=payload.class_level.strip(),
            student_id=payload.student_id.strip(),
            locked=payload.locked,
            db_path="school_archive.db"
        )
        # Lock changes the ปพ.5 roster: recompute course attendance and rebuild that student's course files
        t, y, cl, sid = payload.term.strip(), payload.year.strip(), payload.class_level.strip(), payload.student_id.strip()
        database.sync_daily_attendance_to_courses(t, y, cl, db_path="school_archive.db")
        with get_connection("school_archive.db") as conn:
            codes = [r["course_code"] for r in conn.execute(
                "SELECT course_code FROM grades_history WHERE student_id = ? AND term = ? AND year = ?;", (sid, t, y)
            )]
        porpor5_refresh_queue.enqueue(t, y, codes)
        return res
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.delete("/api/v1/daily-attendance/student")
def remove_class_student_api(
    term: str = Query(...),
    year: str = Query(...),
    class_level: str = Query(...),
    student_id: str = Query(...)
):
    """Remove or transfer out student from a class level (- button)."""
    try:
        t, y, cl, sid = term.strip(), year.strip(), class_level.strip(), student_id.strip()
        # their courses, read before they leave the roster
        codes = database.student_course_codes(sid, t, y, db_path="school_archive.db")
        res = remove_class_student(
            term=term,
            year=year,
            class_level=class_level,
            student_id=student_id,
            db_path="school_archive.db"
        )
        # The student leaves the ปพ.5 roster of each course, which rebuilds those files (their own numbers no
        # longer move anything, so the recount alone would not notice)
        database.sync_daily_attendance_to_courses(t, y, cl, student_ids=[sid], db_path="school_archive.db")
        database.notify_courses_changed(t, y, codes)
        return res
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/daily-attendance/students")
def get_class_students_api(
    term: str = Query(...),
    year: str = Query(...),
    class_level: str = Query(...),
    room: Optional[str] = Query(None)
):
    """Retrieve active student roster for a class level in a semester."""
    try:
        data = get_class_students(term=term, year=year, class_level=class_level, room=room, db_path="school_archive.db")
        return {"status": "success", "count": len(data), "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/daily-attendance/preview-dmc")
async def preview_dmc_api(
    file: UploadFile = File(...),
    term: Optional[str] = Form(None),
    year: Optional[str] = Form(None)
):
    """Preview student roster from DMC Excel or CSV file without modifying database
    (with term/year: compared with that semester's roster, see database.compare_dmc_roster)."""
    try:
        content = await file.read()
        res = preview_dmc_file(content, file.filename or "dmc_roster.xlsx",
                               term=(term or "").strip() or None, year=(year or "").strip() or None,
                               db_path="school_archive.db")
        return res
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/v1/daily-attendance/import-dmc")
async def import_dmc_api(
    file: UploadFile = File(...),
    term: str = Form(...),
    year: str = Form(...),
    overwrite: bool = Form(True)
):
    """Import students from DMC file and automatically distribute into rooms and class levels.
    overwrite=false adds only students new to the semester; true makes the class rosters match the file."""
    try:
        content = await file.read()
        if overwrite:
            import backup_manager
            backup_manager.create_backup(label=f"ก่อนนำเข้า DMC แบบปรับรายชื่อตามไฟล์ {term.strip()}/{year.strip()}",
                                         term=term.strip(), year=year.strip())
        res = import_students_from_dmc(
            file_content=content,
            filename=file.filename or "dmc_roster.xlsx",
            term=term.strip(),
            year=year.strip(),
            overwrite=bool(overwrite),
            db_path="school_archive.db"
        )
        return res
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


class ExportDmcRequest(BaseModel):
    term: str = "1"
    year: str = "2569"
    class_level: str = "ม.1"
    room: str = "all"
    student_ids: Optional[List[str]] = None
    columns_subset: Optional[List[str]] = None


@app.get("/api/v1/students/template")
def download_students_template_api():
    """Download standard blank/sample student roster import template (.xlsx)."""
    from database import generate_students_template_excel
    import urllib.parse
    try:
        xlsx_bytes = generate_students_template_excel(db_path="school_archive.db")
        filename = "แบบฟอร์มนำเข้ารายชื่อนักเรียน_มาตรฐาน.xlsx"
        encoded_filename = urllib.parse.quote(filename)
        return Response(
            content=xlsx_bytes,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={
                "Content-Disposition": f"attachment; filename*=UTF-8''{encoded_filename}",
                "Cache-Control": "no-cache"
            }
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/students/dmc-columns")
def get_dmc_columns_api():
    """Retrieve available DMC columns and category groups for selective export."""
    from database import get_dmc_columns_definition
    return {"status": "success", "data": get_dmc_columns_definition()}


@app.get("/api/v1/students/export-dmc")
def export_students_dmc_get_api(
    request: Request,
    term: str = Query("1"),
    year: str = Query("2569"),
    class_level: str = Query("ม.1"),
    room: str = Query("all"),
    student_ids: Optional[str] = Query(None),
    columns: Optional[str] = Query(None)
):
    """Export student roster formatted in exact official DMC template via GET download link (citizen IDs for admins only)."""
    from database import export_students_dmc_excel
    import urllib.parse
    try:
        sids = [s.strip() for s in student_ids.split(",") if s.strip()] if student_ids else None
        cols = [c.strip() for c in columns.split(",") if c.strip()] if columns else None
        xlsx_bytes = export_students_dmc_excel(
            term=term,
            year=year,
            class_level=class_level,
            room=room,
            student_ids=sids,
            columns_subset=cols,
            db_path="school_archive.db",
            hide_citizen_id=current_user(request).get("role") != "admin"
        )
        lvl_tag = class_level if class_level != "all" else "ทุกระดับชั้น"
        room_tag = f"_ห้อง{room}" if room != "all" else ""
        filename = f"รายชื่อนักเรียน_DMC_{lvl_tag}{room_tag}_{term}_{year}.xlsx"
        encoded_filename = urllib.parse.quote(filename)
        return Response(
            content=xlsx_bytes,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={
                "Content-Disposition": f"attachment; filename*=UTF-8''{encoded_filename}",
                "Access-Control-Expose-Headers": "Content-Disposition"
            }
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/students/export-dmc")
def export_students_dmc_api(payload: ExportDmcRequest, request: Request):
    """Export student roster formatted in exact official DMC template with selective scopes & columns (citizen IDs for admins only)."""
    from database import export_students_dmc_excel
    import urllib.parse
    try:
        xlsx_bytes = export_students_dmc_excel(
            term=payload.term,
            year=payload.year,
            class_level=payload.class_level,
            room=payload.room,
            student_ids=payload.student_ids,
            columns_subset=payload.columns_subset,
            db_path="school_archive.db",
            hide_citizen_id=current_user(request).get("role") != "admin"
        )
        lvl_tag = payload.class_level if payload.class_level != "all" else "ทุกระดับชั้น"
        room_tag = f"_ห้อง{payload.room}" if payload.room != "all" else ""
        filename = f"รายชื่อนักเรียน_DMC_{lvl_tag}{room_tag}_{payload.term}_{payload.year}.xlsx"
        encoded_filename = urllib.parse.quote(filename)
        return Response(
            content=xlsx_bytes,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={
                "Content-Disposition": f"attachment; filename*=UTF-8''{encoded_filename}",
                "Access-Control-Expose-Headers": "Content-Disposition"
            }
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/daily-attendance/import-students")
def import_class_students_api(payload: ImportClassStudentsRequest):
    """Import/copy students from another semester."""
    try:
        res = copy_class_students_from_semester(
            from_term=payload.from_term.strip(),
            from_year=payload.from_year.strip(),
            to_term=payload.to_term.strip(),
            to_year=payload.to_year.strip(),
            from_class_level=payload.from_class_level.strip() if payload.from_class_level else None,
            to_class_level=payload.to_class_level.strip() if payload.to_class_level else None,
            all_levels=bool(payload.all_levels),
            overwrite=bool(payload.overwrite),
            db_path="school_archive.db"
        )
        return res
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


def _guest_safe(request: Request, data: Any) -> Any:
    """บุคคลทั่วไป see the dashboard with every student's name and ID replaced by ******."""
    return auth.mask_students_for_guest(data) if current_user(request).get("role") == "guest" else data


@app.get("/api/v1/dashboard/attendance-risk")
def get_attendance_risk_api(
    request: Request,
    term: str = Query(...),
    year: str = Query(...),
    class_level: Optional[str] = Query(None),
    as_of: Optional[str] = Query(None, description="YYYY-MM-DD, default today")
):
    """Early warning for มส. (< 80%): Beta-Binomial forecast per student x course, plus weekday absence patterns."""
    try:
        from attendance_risk import compute_attendance_risk
        data = compute_attendance_risk(term, year, class_level=class_level, today=as_of, db_path="school_archive.db")
        return {"status": "success", "data": _guest_safe(request, data)}
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/dashboard/attendance-overview")
def get_attendance_dashboard_api(
    request: Request,
    term: str = Query("1"),
    year: str = Query("2568"),
    mode: str = Query("subject"),
    month: Optional[str] = Query(None)
):
    """Retrieve comprehensive attendance dashboard data with top 3 absentees per class level, with optional monthly filter."""
    try:
        data = get_attendance_dashboard(term=term, year=year, mode=mode, month=month, db_path="school_archive.db")
        return {"status": "success", "data": _guest_safe(request, data)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/dashboard/student-monthly-attendance")
def get_student_monthly_attendance_api(
    term: str = Query(...),
    year: str = Query(...),
    student_id: str = Query(...),
    mode: str = Query("subject")
):
    """Retrieve month-by-month attendance trend and breakdown for a student."""
    try:
        data = get_student_monthly_attendance_detail(term=term, year=year, student_id=student_id, mode=mode, db_path="school_archive.db")
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/dashboard/attendance-summary-data")
def get_attendance_summary_data_api(
    term: str = Query(...),
    year: str = Query(...),
    mode: str = Query("daily"),
    threshold: str = Query("all"),
    class_level: str = Query("all"),
    eval_scope: str = Query("current")
):
    """Retrieve attendance evaluation data (80% and 60% thresholds) for all students."""
    try:
        from attendance_summary_exporter import get_attendance_summary_report_data
        data = get_attendance_summary_report_data(
            term=term,
            year=year,
            mode=mode,
            threshold=threshold,
            class_level=class_level,
            eval_scope=eval_scope,
            db_path="school_archive.db"
        )
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/dashboard/attendance-summary-pdf")
def get_attendance_summary_pdf_api(
    term: str = Query(...),
    year: str = Query(...),
    mode: str = Query("daily"),
    threshold: str = Query("all"),
    class_level: str = Query("all"),
    eval_scope: str = Query("current"),
    inline: bool = Query(False)
):
    """Generate and stream publication-grade landscape PDF for attendance summary."""
    try:
        from attendance_summary_exporter import generate_attendance_summary_pdf
        import urllib.parse
        pdf_bytes = generate_attendance_summary_pdf(
            term=term,
            year=year,
            mode=mode,
            threshold=threshold,
            class_level=class_level,
            eval_scope=eval_scope,
            db_path="school_archive.db"
        )
        lvl_tag = class_level if class_level != "all" else "ทุกระดับชั้น"
        thresh_tag = "" if threshold == "all" else (f"_{threshold}")
        filename = f"รายงานสรุปเวลาเรียน_80_60_{lvl_tag}{thresh_tag}_{term}_{year}.pdf"
        encoded_filename = urllib.parse.quote(filename)
        disp = "inline" if inline else f"attachment; filename*=UTF-8''{encoded_filename}"
        return Response(
            content=pdf_bytes,
            media_type="application/pdf",
            headers={
                "Content-Disposition": disp,
                "Access-Control-Expose-Headers": "Content-Disposition"
            }
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/daily-attendance/all-levels-summary")
def get_all_levels_attendance_summary_api(
    term: str = Query(...),
    year: str = Query(...)
):
    """Retrieve student counts and summary for all 6 class levels."""
    try:
        data = get_all_levels_attendance_summary(
            term=term,
            year=year,
            db_path="school_archive.db"
        )
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/download/{filename}")
def download_file(filename: str):
    """Serve the generated Excel or PDF files."""
    output_root = OUTPUT_DIR.resolve()
    file_path = (output_root / Path(filename).name).resolve()
    if file_path.parent != output_root or not file_path.is_file():
        raise HTTPException(status_code=404, detail="File not found")

    return FileResponse(
        path=str(file_path),
        filename=file_path.name,
        media_type="application/octet-stream"
    )

def ensure_standby_excel_file(course_code: str, term: Optional[str] = None, year: Optional[str] = None) -> Optional[Path]:
    """Ensures that a standby PorPor 5 Excel file exists for a course with complete pre-filled cover, students, and advisors."""
    output_root = OUTPUT_DIR.resolve()
    target_excel = find_course_matching_file(output_root, course_code, term=term, year=year, ext=".xlsx")
    if target_excel and target_excel.exists():
        return target_excel

    try:
        with get_connection("school_archive.db") as conn:
            conn.row_factory = sqlite3.Row
            c = conn.cursor()
            if term and year:
                c.execute("SELECT * FROM courses WHERE course_code = ? AND term = ? AND year = ?;", (course_code, str(term), str(year)))
            else:
                c.execute("SELECT * FROM courses WHERE course_code = ? ORDER BY year DESC, term DESC LIMIT 1;", (course_code,))
            crs = c.fetchone()
            if not crs:
                return None

            c_term = str(crs["term"])
            c_year = str(crs["year"])
            c_name = crs["course_name"] or ""
            c_teacher = crs["teacher"] or ""
            c_level = crs["class_level"] or infer_class_level(course_code, c_name)
            c_credits = crs["credits"] if "credits" in crs.keys() and crs["credits"] else 1.0
            dept = crs["department"] if "department" in crs.keys() and crs["department"] else ""
            c_type = crs["course_type"] if "course_type" in crs.keys() and crs["course_type"] else "พื้นฐาน"
            ratio = crs["score_ratio"] if "score_ratio" in crs.keys() and crs["score_ratio"] else "70:30"
            desc = crs["course_description"] if "course_description" in crs.keys() and crs["course_description"] else ""

            # Fetch school name (without 'โรงเรียน' prefix for cover B5)
            c.execute("SELECT school_name FROM school_signatories WHERE year = ?", (c_year,))
            s_row = c.fetchone()
            school_name = s_row["school_name"] if s_row and s_row["school_name"] else school_profile.short_name()
            school_name = re.sub(r"^โรงเรียน\s*", "", school_name).strip() or school_profile.short_name()

            # Fetch students
            c.execute("""
                SELECT student_no, student_id, full_name
                FROM class_students
                WHERE term = ? AND year = ? AND class_level = ?
                  AND COALESCE(is_locked, 0) = 0 AND COALESCE(is_active, 1) = 1
                ORDER BY student_no ASC
            """, (c_term, c_year, c_level))
            s_rows = c.fetchall()
            if not s_rows:
                c.execute("""
                    SELECT student_no, student_id, full_name
                    FROM class_students
                    WHERE year = ? AND class_level = ?
                      AND COALESCE(is_locked, 0) = 0 AND COALESCE(is_active, 1) = 1
                    ORDER BY student_no ASC
                """, (c_year, c_level))
                s_rows = c.fetchall()

            students = [{"student_no": r["student_no"], "student_id": r["student_id"], "full_name": r["full_name"]} for r in s_rows]
            # Enrolled roster when available (excludes locked/inactive), carrying stored scores so a rebuild loses nothing
            enrolled = database.get_porpor5_roster(course_code, c_term, c_year, db_path="school_archive.db")
            if enrolled:
                c.execute(
                    "SELECT student_id, scores_json, attributes_json, final_grade FROM grades_history WHERE course_code = ? AND term = ? AND year = ?;",
                    (course_code, c_term, c_year)
                )
                gh = {r["student_id"]: r for r in c.fetchall()}
                students = []
                for r in enrolled:
                    g = gh.get(r["student_id"])
                    item = {"student_no": r["student_no"], "student_id": r["student_id"], "full_name": r["full_name"]}
                    if g:
                        try:
                            item["scores"] = json.loads(g["scores_json"]) if g["scores_json"] else {}
                            item["attributes"] = json.loads(g["attributes_json"]) if g["attributes_json"] else {}
                        except Exception:
                            pass
                        item["grade"] = g["final_grade"] or ""
                    students.append(item)

            filename_base = f"{c_year}-{c_term} ({c_level}) {course_code} {c_name} - {c_teacher}"
            clean_filename_base = re.sub(r'[\\/*?:"<>|]', "_", filename_base)
            excel_out = output_root / f"{clean_filename_base}_ปพ5_filled.xlsx"

            data = {
                "header": {
                    "school_name": school_name,
                    "semester": c_term,
                    "academic_year": c_year,
                    "course_code": course_code,
                    "course_name": c_name,
                    "credits": c_credits,
                    "class_level": c_level,
                    "teacher": c_teacher,
                    "department": dept,
                    "course_type": c_type,
                    "score_ratio": ratio,
                },
                "students": students,
            }

            from excel_mapper import map_sgs_to_excel
            map_sgs_to_excel(data, template_path="template_ปพ5_blank.xlsx", output_excel_path=str(excel_out), course_description=desc)
            sync_cover_sheet_to_excel(excel_out, term=c_term, year=c_year, course_code=course_code, class_level=c_level, teacher=c_teacher, course_name=c_name)
        # The generator lays out placeholder marks; overwrite them with the real attendance from the DB
        write_course_attendance_from_db(course_code, c_term, c_year)
        return excel_out
    except Exception as e:
        print(f"[ERROR] Failed to ensure standby Excel for {course_code}: {e}")
        return None


def write_course_attendance_from_db(course_code: str, term: str, year: str) -> Dict[str, Any]:
    """Write grades_history attendance (already canonical) into the course's ปพ.5 file without touching the DB."""
    with get_connection("school_archive.db") as conn:
        rows = conn.execute(
            "SELECT student_id, attendance_json FROM grades_history WHERE course_code = ? AND term = ? AND year = ?;",
            (course_code, str(term), str(year))
        ).fetchall()
    records = []
    for r in rows:
        try:
            att = json.loads(r["attendance_json"]) if r["attendance_json"] else {}
        except Exception:
            att = {}
        records.append({"student_id": r["student_id"], "attendance": att})
    return update_course_attendance_in_file(
        course_code=course_code, records=records, term=str(term), year=str(year),
        outputs_dir=str(OUTPUT_DIR), db_path="school_archive.db", regenerate_pdf=False, write_db=False
    )


def porpor5_file_is_usable(course_code: str, term: str, year: str) -> bool:
    """False when the course's ปพ.5 Excel is missing or not a readable .xlsx (a half-written or damaged file).
    Only reads the zip directory, so it is cheap enough to run over every course once a night."""
    xl = find_course_matching_file(OUTPUT_DIR.resolve(), course_code, term=term, year=year, ext=".xlsx")
    if not xl or not xl.exists():
        return False
    import zipfile
    try:
        with zipfile.ZipFile(xl) as z:
            return "[Content_Types].xml" in z.namelist()
    except Exception:
        return False


def porpor5_file_roster_is_stale(course_code: str, term: str, year: str) -> bool:
    """True when the student rows in the ปพ.5 file differ from the DB roster: someone joined, left or was
    locked, or a name was corrected (ชื่อในไฟล์ต้องตามฐานข้อมูลเสมอ)."""
    xl = find_course_matching_file(OUTPUT_DIR.resolve(), course_code, term=term, year=year, ext=".xlsx")
    if not xl or not xl.exists():
        return False
    import openpyxl
    from excel_mapper import workbook_lock
    expected = [(str(r["student_id"]), re.sub(r"\s+", "", str(r["full_name"] or "")))
                for r in database.get_porpor5_roster(course_code, term, year, db_path="school_archive.db")]
    if not expected:
        return False
    try:
        with workbook_lock(xl):
            wb = openpyxl.load_workbook(str(xl), read_only=True)
            ws = wb["(2) เวลาเรียน1"]
            in_file = [(str(sid).strip(), re.sub(r"\s+", "", str(name or "")))
                       for sid, name in ws.iter_rows(min_row=9, max_row=60, min_col=2, max_col=3, values_only=True) if sid]
            wb.close()
    except Exception:
        return True  # unreadable / corrupted file: rebuild it
    return in_file != expected


def rebuild_course_porpor5(course_code: str, term: str, year: str) -> Optional[Path]:
    """Regenerate a course's ปพ.5 from the DB (roster, scores, attendance). The old file is kept in backups/."""
    output_root = OUTPUT_DIR.resolve()
    stale_dir = Path("backups") / "replaced_porpor5" / datetime.now().strftime("%Y%m%d")
    moved = []
    for ext in (".xlsx", ".pdf"):
        old = find_course_matching_file(output_root, course_code, term=term, year=year, ext=ext)
        if old and old.exists() and old.parent == output_root:
            stale_dir.mkdir(parents=True, exist_ok=True)
            dest = stale_dir / f"{datetime.now().strftime('%H%M%S')}_{old.name}"
            shutil.move(str(old), str(dest))
            moved.append((dest, old))
    new_file = ensure_standby_excel_file(course_code, term=term, year=year)
    if not new_file:
        for dest, old in moved:  # generation failed: put the previous files back
            shutil.move(str(dest), str(old))
    return new_file


class PorPor5RefreshQueue:
    """
    Single background worker that keeps ปพ.5 files in step with the DB after daily attendance
    changes. Requests are de-duplicated and debounced, so a burst of saves costs one write per
    course, and only one thread ever writes, which avoids the concurrent-write corruption.
    PDFs are pre-exported in the background on Linux (LibreOffice headless, low CPU priority).
    On Windows it is off: Excel COM shows a "Publishing..." window on the server desktop for
    every file, so PDFs are made only when someone opens / prints one.
    """

    PRE_EXPORT_PDF = sys.platform != "win32"

    def __init__(self, debounce_seconds: float = 2.0):
        # (course_code, term, year) -> "full" (rewrite Excel + PDF) or "pdf" (PDF only)
        self._pending: Dict[tuple, str] = {}
        # (course_code, term, year) whose sheet (4) scores changed outside the scores page (exam submissions)
        self._scores: set = set()
        self._cv = threading.Condition()
        self._debounce = debounce_seconds
        self._thread: Optional[threading.Thread] = None

    def enqueue(self, term: str, year: str, course_codes: List[str], pdf_only: bool = False) -> None:
        with self._cv:
            for code in course_codes:
                key = (code, str(term), str(year))
                self._pending[key] = "full" if self._pending.get(key) == "full" or not pdf_only else "pdf"
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="porpor5-refresh", daemon=True)
                self._thread.start()
            self._cv.notify()

    def enqueue_scores(self, term: str, year: str, course_codes: List[str]) -> None:
        with self._cv:
            for code in course_codes:
                self._scores.add((code, str(term), str(year)))
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="porpor5-refresh", daemon=True)
                self._thread.start()
            self._cv.notify()

    def pending_count(self) -> int:
        with self._cv:
            return len(self._pending) + len(self._scores)

    def _run(self) -> None:
        while True:
            with self._cv:
                while not self._pending and not self._scores:
                    self._cv.wait()
            time.sleep(self._debounce)
            with self._cv:
                batch = dict(self._pending)
                self._pending.clear()
                scores = set(self._scores)
                self._scores.clear()
            for key in scores:
                try:
                    exams.flush_scores_to_porpor5(*key)
                except Exception as e:
                    print(f"[WARN] exam scores -> ปพ.5 failed for {key[0]} {key[1]}/{key[2]}: {e}")
                batch.setdefault(key, "pdf")
            # Excel files first (fast), so previews are current within seconds ...
            for (code, term, year), kind in batch.items():
                if kind == "full":
                    try:
                        self.refresh(code, term, year, export_pdf=False)
                    except Exception as e:
                        print(f"[WARN] ปพ.5 refresh failed for {code} {term}/{year}: {e}")
            # ... then the slow Excel->PDF exports; newly queued Excel work jumps ahead of them
            todo = list(batch) if self.PRE_EXPORT_PDF else []
            while todo:
                with self._cv:
                    if any(k == "full" for k in self._pending.values()):
                        for key in todo:
                            self._pending.setdefault(key, "pdf")
                        break
                code, term, year = todo.pop(0)
                try:
                    self.export_pdf(code, term, year)
                except Exception as e:
                    print(f"[WARN] ปพ.5 PDF export failed for {code} {term}/{year}: {e}")

    @staticmethod
    def refresh(course_code: str, term: str, year: str, export_pdf: bool = True) -> None:
        if porpor5_file_roster_is_stale(course_code, term, year):
            rebuild_course_porpor5(course_code, term, year)
        else:
            write_course_attendance_from_db(course_code, term, year)
        if export_pdf:
            PorPor5RefreshQueue.export_pdf(course_code, term, year)

    @staticmethod
    def export_pdf(course_code: str, term: str, year: str) -> None:
        """Export the PDF if the Excel is newer and pre-render its page images for the viewer."""
        pdf = resolve_or_create_course_pdf(course_code, term=term, year=year)
        if pdf and pdf.exists():
            render_and_cache_pdf_pages(pdf, dpi=140)


porpor5_refresh_queue = PorPor5RefreshQueue()
database.COURSE_ATTENDANCE_CHANGED_HOOKS.append(porpor5_refresh_queue.enqueue)
exams.SCORES_CHANGED_HOOKS.append(porpor5_refresh_queue.enqueue_scores)


def run_attendance_day_rollover(today: str, force: bool = False) -> int:
    """
    ขาด / ร้อยละ are counted up to today, so the stored course summaries (and the ปพ.5 files)
    move forward once per day. Re-syncs every class level of each semester in progress;
    the sync hook then refreshes Excel and PDFs in the background.
    """
    db = "school_archive.db"
    if not force and get_app_setting("attendance_rollover_date", "", db_path=db) == today:
        return 0
    synced = 0
    with get_connection(db) as conn:
        levels = conn.execute("SELECT DISTINCT term, year, class_level FROM daily_attendance_config;").fetchall()
    # คำนำหน้าตามอายุ: ตรวจวันละครั้งพร้อมกับการนับเวลาเรียนของวันใหม่
    try:
        database.refresh_student_prefixes(db_path=db)
    except Exception as e:
        print(f"[WARN] refresh_student_prefixes failed: {e}")
    live = set()
    for r in levels:
        t, y, lvl = str(r["term"]), str(r["year"]), r["class_level"]
        dates = database.compute_100_dates(database.get_semester_start_date(t, y, db_path=db), t, y)
        # in progress, or ended within the last week (so the final day gets counted)
        if dates and dates[0] <= today and (datetime.strptime(dates[-1], "%Y-%m-%d").date().toordinal() + 7) >= datetime.strptime(today, "%Y-%m-%d").date().toordinal():
            synced += database.sync_daily_attendance_to_courses(t, y, lvl, db_path=db)
            live.add((t, y))
    # The recount above queues only the courses whose numbers moved. Once a night, also pick up a course whose
    # ปพ.5 Excel is missing or unreadable (deleted by hand, never built, or damaged), so it is not left broken.
    missing = []
    for t, y in sorted(live):
        with get_connection(db) as conn:
            codes = [r["course_code"] for r in conn.execute(
                "SELECT course_code FROM courses WHERE term = ? AND year = ?;", (t, y))]
        gone = [c for c in codes if not porpor5_file_is_usable(c, t, y)]
        if gone:
            missing.append((t, y, gone))
    for t, y, gone in missing:
        print(f"[INFO] ปพ.5 Excel missing or damaged for {len(gone)} course(s) in {t}/{y}: rebuilding")
        porpor5_refresh_queue.enqueue(t, y, gone)
    set_app_setting("attendance_rollover_date", today, db_path=db)
    # สำรองทั้งระบบ (.zip) วันละครั้ง: วันอาทิตย์รวม ปพ.5 (ทำในเธรดแยก ไม่ให้การนับเวลาเรียนรอ)
    if not os.environ.get("SCHOOL_NO_BACKGROUND"):
        def _nightly_archive():
            try:
                gone = exams.sweep_images()
                if gone:
                    print(f"[INFO] removed {gone} unused exam picture(s)")
            except Exception as e:
                print(f"[WARN] exam picture sweep failed: {e}")
            try:
                import archive_backup
                info = archive_backup.nightly()
                print(f"[INFO] nightly backup {info['name']} ({info['size_mb']} MB)")
            except Exception as e:
                print(f"[WARN] nightly backup failed: {e}")
        threading.Thread(target=_nightly_archive, daemon=True).start()
    return synced


def _attendance_day_rollover_loop() -> None:
    last = None
    # ตรวจคำนำหน้าตามอายุหนึ่งครั้งตอนเปิดเครื่อง เผื่อวันนี้นับเวลาเรียนไปแล้วก่อนรีสตาร์ต
    try:
        database.refresh_student_prefixes(db_path="school_archive.db")
    except Exception as e:
        print(f"[WARN] refresh_student_prefixes at startup failed: {e}")
    while True:
        today = attendance_rules.today_iso()
        if today != last:
            try:
                n = run_attendance_day_rollover(today)
                if n:
                    print(f"[INFO] Attendance day rollover {today}: {n} course rows recounted")
                last = today
            except Exception as e:
                print(f"[WARN] Attendance day rollover failed: {e}")
        time.sleep(30)


if os.environ.get("SCHOOL_NO_BACKGROUND") != "1":  # maintenance scripts import main without the ticker
    threading.Thread(target=_attendance_day_rollover_loop, name="attendance-day-rollover", daemon=True).start()


@app.get("/api/v1/course-file")
def get_course_file(
    request: Request,
    course_code: str = Query(..., description="Course code (e.g., 'ค22102')"),
    term: Optional[str] = Query(None),
    year: Optional[str] = Query(None),
    format: str = Query("excel"),
    inline: bool = Query(False)
):
    """Find and serve the generated ปพ.5 Excel or PDF file for a given course.
    ผู้อำนวยการเปิดดู PDF บนหน้าจอได้ (inline) แต่บันทึกไฟล์ลงเครื่องไม่ได้ (auth.DIRECTOR_NO_DOWNLOAD
    blocks this path, so the viewer's inline request is let back in here)."""
    if current_user(request).get("role") == "director" and not (inline and format == "pdf"):
        raise HTTPException(status_code=403, detail="ผู้อำนวยการดูข้อมูลบนหน้าจอได้ แต่ดาวน์โหลดไฟล์ไม่ได้")
    ext = ".xlsx" if format == "excel" else ".pdf"
    output_root = OUTPUT_DIR.resolve()

    t = term
    y = year
    if not t or not y:
        try:
            with get_connection("school_archive.db") as conn:
                c = conn.cursor()
                c.execute("SELECT term, year FROM courses WHERE course_code = ? ORDER BY year DESC, term DESC LIMIT 1;", (course_code,))
                row = c.fetchone()
                if row:
                    t = t or row["term"]
                    y = y or row["year"]
        except Exception:
            pass

    target = find_course_matching_file(output_root, course_code, term=t, year=y, ext=ext)
    if not target or not target.exists():
        excel_target = ensure_standby_excel_file(course_code, term=t, year=y)
        if format == "excel":
            target = excel_target
        elif format == "pdf" and excel_target:
            target = resolve_or_create_course_pdf(course_code, term=t, year=y)

    # If format is PDF and no PDF exists yet or it is outdated, generate it from the matching Excel file
    if format == "pdf":
        excel_target = find_course_matching_file(output_root, course_code, term=t, year=y, ext=".xlsx")
        if excel_target:
            need_rebuild = False
            if not target or not target.exists():
                pdf_name = f"{excel_target.stem.replace('_ปพ5_filled', '')}_ปพ5_print_ready.pdf"
                target = output_root / pdf_name
                need_rebuild = True
            elif excel_target.stat().st_mtime > target.stat().st_mtime:
                need_rebuild = True

            if need_rebuild:
                try:
                    sync_cover_sheet_to_excel(excel_target, term=t, year=y, course_code=course_code)
                    from excel_mapper import export_excel_to_pdf
                    export_excel_to_pdf(str(excel_target), str(target))
                except Exception as e:
                    print(f"[WARN] Failed to auto-generate PDF for {course_code}: {e}")
    elif format == "excel" and target and target.exists():
        try:
            sync_cover_sheet_to_excel(target, term=t, year=y, course_code=course_code)
        except Exception as e:
            print(f"[WARN] Failed to sync cover sheet on download: {e}")

    if target and target.exists():
        media_type = "application/pdf" if format == "pdf" else "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        disposition = "inline" if (inline and format == "pdf") else "attachment"

        return FileResponse(
            path=str(target),
            filename=target.name,
            media_type=media_type,
            content_disposition_type=disposition
        )
    raise HTTPException(status_code=404, detail=f"No {format} file found for course {course_code} ({t}/{y})")


PAGE_TITLES_MAP = [
    "(1) ปกปพ. (แบบบันทึกผลการพัฒนาคุณภาพผู้เรียน)",
    "(2) เวลาเรียน 1 (สัปดาห์ที่ 1 - 11)",
    "(3) เวลาเรียน 2 (สัปดาห์ที่ 12 - 20)",
    "(4) รวมคะแนน (คะแนนตามตัวชี้วัด & สรุปผลการเรียน)",
    "(5) คุณลักษณะ (คุณลักษณะอันพึงประสงค์ & อ่านคิดวิเคราะห์)",
    "(6) ตัวชี้วัด (คำอธิบายรายวิชา & ตัวชี้วัด)",
    "(7) คำชี้แจง (เกณฑ์การประเมินผลการเรียน)"
]


from excel_mapper import PDF_EXPORT_LOCK as _course_pdf_export_lock  # shared with the attendance writer
PDF_PAGE_CACHE_DIR = Path("data/pdf_page_cache")
PDF_PAGE_CACHE_DIR.mkdir(parents=True, exist_ok=True)
# ปพ.5 viewer data, per file: path -> ((mtime_ns, size), parsed sheets). One entry is about 4 MB, so only the newest
# version of a file is kept (an older one is replaced, not piled up) and only the files opened most recently.
from collections import OrderedDict
_EXCEL_SHEETS_CACHE_MAX = 8
_excel_sheets_cache: "OrderedDict[str, tuple]" = OrderedDict()
_excel_sheets_cache_lock = threading.Lock()


def render_and_cache_pdf_pages(pdf_path: Path, dpi: Any = 140) -> Path:
    """
    Renders all pages of a PDF into high-res PNG images in a disk cache directory.
    Uses PyMuPDF to batch-render all pages in ~300ms so subsequent requests respond in < 3ms.
    """
    try:
        actual_dpi = int(dpi) if not hasattr(dpi, 'default') else 140
    except Exception:
        actual_dpi = 140

    mtime = int(pdf_path.stat().st_mtime)
    cache_dir = PDF_PAGE_CACHE_DIR / f"{pdf_path.stem}_{mtime}"
    cache_dir.mkdir(parents=True, exist_ok=True)

    try:
        import fitz
        doc = fitz.open(str(pdf_path))
        for i, page in enumerate(doc):
            png_path = cache_dir / f"page_{i}_{actual_dpi}.png"
            if not png_path.exists() or png_path.stat().st_size == 0:
                pix = page.get_pixmap(dpi=actual_dpi)
                pix.save(str(png_path))
        doc.close()
    except Exception as e:
        print(f"[WARN] Failed to batch-render PDF pages for {pdf_path}: {e}")
    return cache_dir


def resolve_or_create_course_pdf(course_code: str, term: Optional[str] = None, year: Optional[str] = None, force_export: bool = False) -> Optional[Path]:
    output_root = OUTPUT_DIR.resolve()
    t = term
    y = year
    if not t or not y:
        try:
            with get_connection("school_archive.db") as conn:
                c = conn.cursor()
                c.execute("SELECT term, year FROM courses WHERE course_code = ? ORDER BY year DESC, term DESC LIMIT 1;", (course_code,))
                row = c.fetchone()
                if row:
                    t = t or row["term"]
                    y = y or row["year"]
        except Exception:
            pass

    target_excel = find_course_matching_file(output_root, course_code, term=t, year=y, ext=".xlsx")
    if not target_excel or not target_excel.exists():
        target_excel = ensure_standby_excel_file(course_code, term=t, year=y)
    target_pdf = find_course_matching_file(output_root, course_code, term=t, year=y, ext=".pdf")

    # Check if we should re-export (missing or outdated or forced)
    need_export = force_export
    if target_excel:
        if not target_pdf or not target_pdf.exists():
            need_export = True
            pdf_name = f"{target_excel.stem.replace('_ปพ5_filled', '')}_ปพ5_print_ready.pdf"
            target_pdf = output_root / pdf_name
        elif target_excel.stat().st_mtime > target_pdf.stat().st_mtime:
            need_export = True

    if need_export and target_excel:
        with _course_pdf_export_lock:
            # Double check under lock in case another thread exported while waiting
            if not force_export and target_pdf and target_pdf.exists() and target_pdf.stat().st_mtime >= target_excel.stat().st_mtime:
                return target_pdf
            try:
                sync_cover_sheet_to_excel(target_excel, term=t, year=y, course_code=course_code)
                from excel_mapper import export_excel_to_pdf
                export_excel_to_pdf(str(target_excel), str(target_pdf))
            except Exception as e:
                print(f"[WARN] Failed to export PDF for {course_code}: {e}")

    if target_pdf and target_pdf.exists():
        return target_pdf
    return None


@app.get("/api/v1/course-pdf-pages")
def get_course_pdf_pages_api(
    course_code: str = Query(...),
    term: Optional[str] = Query(None),
    year: Optional[str] = Query(None),
    force: bool = Query(False)
):
    """
    Returns metadata for all real PDF pages of a course ปพ.5:
    - Page count and dimensions
    - Page titles matching the 7 sheets of PorPor.5
    - Image URLs for high-resolution page rendering
    - Direct PDF URL, Excel URL, and Print URL
    - Immediately warms up the high-res PNG image cache in ~300ms
    """
    is_forced = bool(force) if not hasattr(force, 'default') else bool(force.default)
    pdf_path = resolve_or_create_course_pdf(course_code, term, year, force_export=is_forced)
    if not pdf_path or not pdf_path.exists():
        raise HTTPException(status_code=404, detail=f"No PDF file found for course {course_code}")

    try:
        import fitz
        from urllib.parse import quote
        doc = fitz.open(str(pdf_path))
        pages = []
        safe_code = quote(course_code)
        for i, page in enumerate(doc):
            title = PAGE_TITLES_MAP[i] if i < len(PAGE_TITLES_MAP) else f"หน้า {i+1}"
            rect = page.rect
            img_url = f"/api/v1/course-pdf-page?course_code={safe_code}&page={i}"
            if term:
                img_url += f"&term={quote(str(term))}"
            if year:
                img_url += f"&year={quote(str(year))}"

            pages.append({
                "page_index": i,
                "page_num": i + 1,
                "title": title,
                "width": round(rect.width, 1),
                "height": round(rect.height, 1),
                "is_landscape": rect.width > rect.height,
                "image_url": img_url
            })
        doc.close()

        # Pre-warm disk cache for all pages so browser requests return in < 3ms
        try:
            render_and_cache_pdf_pages(pdf_path, dpi=140)
        except Exception:
            pass

        t_param = f"&term={quote(str(term))}" if term else ""
        y_param = f"&year={quote(str(year))}" if year else ""
        pdf_dl_url = f"/api/v1/course-file?course_code={safe_code}&format=pdf{t_param}{y_param}"
        print_url = f"/api/v1/print-pdf?course_code={safe_code}{t_param}{y_param}"
        excel_dl_url = f"/api/v1/course-file?course_code={safe_code}&format=excel{t_param}{y_param}"
        excel_view_url = f"/api/v1/course-excel-view?course_code={safe_code}{t_param}{y_param}"

        return {
            "status": "success",
            "course_code": course_code,
            "term": term,
            "year": year,
            "total_pages": len(pages),
            "pages": pages,
            "pdf_url": pdf_dl_url,
            "print_url": print_url,
            "excel_url": excel_dl_url,
            "excel_view_url": excel_view_url,
            "pdf_filename": pdf_path.name
        }
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Failed to inspect PDF: {str(e)}")


@app.get("/api/v1/course-pdf-page")
def get_course_pdf_page_image_api(
    course_code: str = Query(...),
    page: int = Query(0, description="0-based page index"),
    term: Optional[str] = Query(None),
    year: Optional[str] = Query(None),
    dpi: int = Query(140)
):
    """
    Renders and streams a high-resolution PNG image of a specific PDF page.
    Uses multi-tier disk caching so cached pages return in < 3ms!
    """
    try:
        actual_dpi = int(dpi) if not hasattr(dpi, 'default') else 140
    except Exception:
        actual_dpi = 140

    output_root = OUTPUT_DIR.resolve()
    target_pdf = find_course_matching_file(output_root, course_code, term=term, year=year, ext=".pdf")
    if target_pdf and target_pdf.exists():
        mtime = int(target_pdf.stat().st_mtime)
        cache_png = PDF_PAGE_CACHE_DIR / f"{target_pdf.stem}_{mtime}" / f"page_{page}_{actual_dpi}.png"
        if cache_png.exists() and cache_png.stat().st_size > 0:
            return FileResponse(str(cache_png), media_type="image/png")

    pdf_path = resolve_or_create_course_pdf(course_code, term, year)
    if not pdf_path or not pdf_path.exists():
        raise HTTPException(status_code=404, detail=f"No PDF file found for course {course_code}")

    mtime = int(pdf_path.stat().st_mtime)
    cache_png = PDF_PAGE_CACHE_DIR / f"{pdf_path.stem}_{mtime}" / f"page_{page}_{actual_dpi}.png"
    if cache_png.exists() and cache_png.stat().st_size > 0:
        return FileResponse(str(cache_png), media_type="image/png")

    # Render all pages to cache in one fast PyMuPDF pass (~300ms)
    render_and_cache_pdf_pages(pdf_path, dpi=actual_dpi)

    if cache_png.exists() and cache_png.stat().st_size > 0:
        return FileResponse(str(cache_png), media_type="image/png")

    # Fallback direct render if cache write had an issue
    try:
        import fitz
        doc = fitz.open(str(pdf_path))
        if page < 0 or page >= len(doc):
            raise HTTPException(status_code=400, detail=f"Invalid page index {page} (document has {len(doc)} pages)")
        pix = doc[page].get_pixmap(dpi=actual_dpi)
        png_bytes = pix.tobytes("png")
        doc.close()
        return Response(content=png_bytes, media_type="image/png")
    except HTTPException:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Failed to render PDF page {page}: {str(e)}")


def col_letter(col_idx: int) -> str:
    """Converts 1-based column index to Excel column letters (1 -> A, 27 -> AA)."""
    res = ""
    while col_idx > 0:
        col_idx, rem = divmod(col_idx - 1, 26)
        res = chr(65 + rem) + res
    return res


SHEET_SHORT_NAMES_MAP = {
    "(1) ปกปพ.": "หน้าปก",
    "(2) เวลาเรียน1": "เวลาเรียน 1",
    "(3) เวลาเรียน2": "เวลาเรียน 2",
    "(4) รวมคะแนน": "รวมคะแนน",
    "(5) คุณลักษณะ": "คุณลักษณะ",
    "(6) ตัวชี้วัด": "ตัวชี้วัด",
    "(7) คำชี้แจง": "คำชี้แจง"
}


def get_course_excel_sheets_data(course_code: str, term: Optional[str] = None, year: Optional[str] = None) -> Dict[str, Any]:
    """
    Parses all sheets of a course PorPor.5 Excel file into high-fidelity read-only data
    including merged ranges, column dimensions, and pre-rendered HTML tables.
    Results are cached in memory until the file changes (only its newest version, at most
    _EXCEL_SHEETS_CACHE_MAX files) for instant retrieval.
    """
    output_root = OUTPUT_DIR.resolve()
    t = term
    y = year
    if not t or not y:
        try:
            with get_connection("school_archive.db") as conn:
                c = conn.cursor()
                c.execute("SELECT term, year FROM courses WHERE course_code = ? ORDER BY year DESC, term DESC LIMIT 1;", (course_code,))
                row = c.fetchone()
                if row:
                    t = t or row["term"]
                    y = y or row["year"]
        except Exception:
            pass

    target_excel = find_course_matching_file(output_root, course_code, term=t, year=y, ext=".xlsx")
    if not target_excel or not target_excel.exists():
        target_excel = ensure_standby_excel_file(course_code, term=t, year=y)

    if not target_excel or not target_excel.exists():
        raise FileNotFoundError(f"Excel file not found for course {course_code}")

    st = target_excel.stat()
    stamp = (st.st_mtime_ns, st.st_size)
    cache_key = str(target_excel.resolve())
    with _excel_sheets_cache_lock:
        hit = _excel_sheets_cache.get(cache_key)
        if hit and hit[0] == stamp:
            _excel_sheets_cache.move_to_end(cache_key)
            return hit[1]

    import openpyxl
    import html as html_lib

    wb = openpyxl.load_workbook(target_excel, data_only=True)
    sheets = []

    for idx, sname in enumerate(wb.sheetnames):
        ws = wb[sname]
        top_left_merges = {}
        horiz_covered = set()
        vert_continuation = {}

        for rng in ws.merged_cells.ranges:
            rspan = rng.max_row - rng.min_row + 1
            cspan = rng.max_col - rng.min_col + 1
            top_left_merges[(rng.min_row, rng.min_col)] = (rspan, cspan)
            for r in range(rng.min_row, rng.max_row + 1):
                for c in range(rng.min_col, rng.max_col + 1):
                    if c > rng.min_col:
                        horiz_covered.add((r, c))
                    elif r > rng.min_row and c == rng.min_col:
                        vert_continuation[(r, c)] = cspan

        # Detect content bounds
        max_r = 0
        max_c = 0
        for r in range(1, min(ws.max_row + 1, 150)):
            for c in range(1, min(ws.max_column + 1, 75)):
                if ws.cell(row=r, column=c).value is not None:
                    if r > max_r: max_r = r
                    if c > max_c: max_c = c

        max_r = max(max_r, 1)
        max_c = max(max_c, 1)

        # Build column headers HTML
        header_th = ['<th class="cell-row-num"></th>']
        for c in range(1, max_c + 1):
            header_th.append(f'<th class="col-header">{col_letter(c)}</th>')
        header_html = '<thead><tr>' + ''.join(header_th) + '</tr></thead>'

        rows = []
        tbody_rows = []

        for r in range(1, max_r + 1):
            row_cells = []
            tds = [f'<th class="row-num">{r}</th>']

            for c in range(1, max_c + 1):
                if (r, c) in horiz_covered:
                    row_cells.append({'c': True})
                    continue

                if (r, c) in vert_continuation:
                    cspan = vert_continuation[(r, c)]
                    row_cells.append({'v': '', 'cs': cspan, 'vc': True})
                    continue

                cell = ws.cell(row=r, column=c)
                v = cell.value
                if v is not None:
                    if isinstance(v, float) and v.is_integer():
                        v_str = str(int(v))
                    else:
                        v_str = str(v)
                else:
                    v_str = ''

                # Special handling for Sheet (1) ปกปพ. Row 2 school logo placement (Columns F..H)
                if idx == 0 and r == 2:
                    if c in (7, 8):
                        row_cells.append({'c': True})
                        continue
                    elif c == 6:
                        c_info = {'v': '', 'cs': 3, 'is_logo': True}
                        row_cells.append(c_info)
                        tds.append('<td colspan="3" data-coord="F2" style="text-align:center; vertical-align:middle; height:72px; padding:4px;"><img src="/api/v1/settings/school-logo" alt="ตราโรงเรียน" style="height:64px; max-width:220px; object-fit:contain; display:inline-block;" /></td>')
                        continue

                c_info = {'v': v_str}
                attrs = [f'data-coord="{col_letter(c)}{r}"', f'data-val="{html_lib.escape(v_str)}"']
                styles = []

                if idx == 0 and r == 2:
                    styles.append('height:72px;')

                if (r, c) in top_left_merges:
                    rs, cs = top_left_merges[(r, c)]
                    if rs > 1:
                        c_info['rs'] = rs
                        attrs.append(f'rowspan="{rs}"')
                    if cs > 1:
                        c_info['cs'] = cs
                        attrs.append(f'colspan="{cs}"')

                if cell.font and cell.font.bold:
                    c_info['b'] = True
                    styles.append('font-weight:bold;')

                align = cell.alignment.horizontal if (cell.alignment and cell.alignment.horizontal) else None
                if align:
                    c_info['a'] = align
                    styles.append(f'text-align:{align};')

                # text written upwards (the vertical ตัวชี้วัด / คุณลักษณะ headers)
                if v_str and cell.alignment and cell.alignment.textRotation == 90:
                    c_info['rot'] = 90
                    styles.append('writing-mode:vertical-rl; transform:rotate(180deg); white-space:nowrap;')

                # header cells the teacher can type into from the app (pp5_labels)
                for g, (lab_sheet, lab_row, lab_col0) in pp5_labels.CELLS.items():
                    if sname == lab_sheet and r == lab_row and lab_col0 <= c < lab_col0 + pp5_labels.GROUPS[g]:
                        c_info['lab'] = f"{g}:{c - lab_col0}"

                row_cells.append(c_info)

                v_esc = html_lib.escape(v_str)
                style_attr = f' style="{" ".join(styles)}"' if styles else ''
                attr_str = (' ' + ' '.join(attrs)) if attrs else ''
                tds.append(f'<td{attr_str}{style_attr}>{v_esc}</td>')

            rows.append(row_cells)
            tbody_rows.append('<tr>' + ''.join(tds) + '</tr>')

        html_table = f'<table class="excel-sheet-table">{header_html}<tbody>{"".join(tbody_rows)}</tbody></table>'

        sheets.append({
            'index': idx,
            'sheet_name': sname,
            'short_name': SHEET_SHORT_NAMES_MAP.get(sname, f"ชีท {idx+1}"),
            'max_row': max_r,
            'max_col': max_c,
            'rows': rows,
            'html_table': html_table
        })

    wb.close()

    result = {
        'status': 'success',
        'course_code': course_code,
        'term': t,
        'year': y,
        'filename': target_excel.name,
        'total_sheets': len(sheets),
        'sheets': sheets
    }
    with _excel_sheets_cache_lock:
        _excel_sheets_cache[cache_key] = (stamp, result)  # replaces the older version of this file
        _excel_sheets_cache.move_to_end(cache_key)
        while len(_excel_sheets_cache) > _EXCEL_SHEETS_CACHE_MAX:
            _excel_sheets_cache.popitem(last=False)
    return result


@app.get("/api/v1/course-excel-sheets")
def get_course_excel_sheets_api(
    course_code: str = Query(...),
    term: Optional[str] = Query(None),
    year: Optional[str] = Query(None)
):
    """
    Returns structured data for all sheets of the course PorPor.5 Excel workbook
    for read-only verification:
    - Sheet index, names, and dimensions
    - Formatted cell values, alignments, bold weights, and merged cells
    - Direct URLs for downloading or full-screen viewing
    """
    try:
        from urllib.parse import quote
        data = dict(get_course_excel_sheets_data(course_code, term, year))  # a copy: the cached entry stays as parsed
        safe_code = quote(course_code)
        t_param = f"&term={quote(str(term))}" if term else ""
        y_param = f"&year={quote(str(year))}" if year else ""
        data["excel_download_url"] = f"/api/v1/course-file?course_code={safe_code}&format=excel{t_param}{y_param}"
        data["excel_viewer_url"] = f"/api/v1/course-excel-view?course_code={safe_code}{t_param}{y_param}"
        data["pdf_download_url"] = f"/api/v1/course-file?course_code={safe_code}&format=pdf{t_param}{y_param}"
        return data
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Failed to read course Excel sheets: {str(e)}")


@app.get("/api/v1/course-excel-view")
def get_course_excel_view_api(
    course_code: str = Query(...),
    term: Optional[str] = Query(None),
    year: Optional[str] = Query(None)
):
    """
    Renders a high-fidelity, interactive read-only Excel workbook viewer HTML page:
    - Displays all 7 sheets of the PorPor.5 workbook with native Excel tabs
    - Full-fidelity cell values, formulas, merged headers, and borders
    - Strictly read-only for inspection (cannot be edited)
    - Formula bar with selected cell coordinates and content
    - Action buttons for downloading Excel, viewing PDF, and printing
    """
    try:
        from urllib.parse import quote
        data = get_course_excel_sheets_data(course_code, term, year)
        safe_code = quote(course_code)
        t_param = f"&term={quote(str(term))}" if term else ""
        y_param = f"&year={quote(str(year))}" if year else ""
        excel_dl_url = f"/api/v1/course-file?course_code={safe_code}&format=excel{t_param}{y_param}"
        pdf_dl_url = f"/api/v1/course-file?course_code={safe_code}&format=pdf{t_param}{y_param}"
        print_url = f"/api/v1/print-pdf?course_code={safe_code}{t_param}{y_param}"

        sheets = data.get("sheets", [])
        tabs_html = []
        sheets_container_html = []

        for s in sheets:
            idx = s["index"]
            sname = s["sheet_name"]
            stitle = s["short_name"]
            active_class = "active" if idx == 0 else ""
            display_style = "display: block;" if idx == 0 else "display: none;"

            tabs_html.append(
                f'<button class="tab-btn {active_class}" onclick="selectSheet({idx})" id="tab-btn-{idx}">'
                f'  <span class="tab-num">{idx+1}</span> {stitle}'
                f'</button>'
            )

            sheets_container_html.append(
                f'<div class="sheet-pane" id="sheet-pane-{idx}" style="{display_style}">'
                f'  <div class="sheet-info-pill">'
                f'    <span>📋 <strong>{sname}</strong> ({stitle})</span>'
                f'    <span>📐 {s["max_row"]} แถว × {s["max_col"]} คอลัมน์</span>'
                f'    <span class="read-only-tag">🔒 ตรวจสอบได้ แต่แก้ไขไม่ได้</span>'
                f'  </div>'
                f'  <div class="table-scroll-wrapper">'
                f'    {s["html_table"]}'
                f'  </div>'
                f'</div>'
            )

        html_content = f"""<!DOCTYPE html>
<html lang="th">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ตรวจสอบหน้า Excel จริง ปพ.5 - {course_code}</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{
            font-family: 'Sarabun', 'Segoe UI', Tahoma, sans-serif;
            background: #f4f5f7;
            color: #212529;
            height: 100vh;
            display: flex;
            flex-direction: column;
            overflow: hidden;
            line-height: 1.5;
        }}
        /* Excel Green Ribbon Header */
        .excel-ribbon {{
            background: #107C41;
            color: white;
            padding: 8px 18px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            box-shadow: 0 2px 6px rgba(0,0,0,0.18);
            z-index: 20;
            flex-shrink: 0;
        }}
        .ribbon-brand {{
            display: flex;
            align-items: center;
            gap: 12px;
        }}
        .excel-icon {{
            background: #0B5A2E;
            width: 34px;
            height: 34px;
            border-radius: 6px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 18px;
            font-weight: bold;
            color: white;
            border: 1px solid rgba(255,255,255,0.25);
        }}
        .ribbon-titles h1 {{
            font-size: 15px;
            font-weight: 700;
            display: flex;
            align-items: center;
            gap: 8px;
        }}
        .ribbon-titles p {{
            font-size: 12px;
            opacity: 0.9;
        }}
        .readonly-badge {{
            background: #FFF3CD;
            color: #856404;
            padding: 4px 10px;
            border-radius: 20px;
            font-size: 11px;
            font-weight: bold;
            display: inline-flex;
            align-items: center;
            gap: 5px;
            border: 1px solid #FFEBAA;
        }}
        .ribbon-actions {{
            display: flex;
            align-items: center;
            gap: 8px;
        }}
        .btn {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 6px 14px;
            border-radius: 6px;
            font-size: 12px;
            font-weight: 600;
            cursor: pointer;
            border: none;
            text-decoration: none;
            transition: all 0.15s ease;
        }}
        .btn-excel {{
            background: #ffffff;
            color: #107C41;
            border: 1px solid #ffffff;
        }}
        .btn-excel:hover {{
            background: #e8f5e9;
        }}
        .btn-pdf {{
            background: rgba(255,255,255,0.15);
            color: white;
            border: 1px solid rgba(255,255,255,0.3);
        }}
        .btn-pdf:hover {{
            background: rgba(255,255,255,0.25);
        }}
        .btn-close {{
            background: rgba(0,0,0,0.2);
            color: #eee;
            border: 1px solid rgba(255,255,255,0.2);
        }}
        .btn-close:hover {{
            background: rgba(0,0,0,0.35);
        }}

        /* Formula / Inspection Bar */
        .formula-bar {{
            background: #ffffff;
            border-bottom: 1px solid #dcdfe4;
            padding: 6px 16px;
            display: flex;
            align-items: center;
            gap: 12px;
            font-size: 13px;
            flex-shrink: 0;
            z-index: 10;
        }}
        .coord-box {{
            background: #f1f3f5;
            border: 1px solid #ced4da;
            border-radius: 4px;
            padding: 2px 10px;
            font-family: monospace;
            font-weight: bold;
            min-width: 60px;
            text-align: center;
            color: #107C41;
        }}
        .fx-label {{
            font-style: italic;
            font-weight: bold;
            color: #6c757d;
        }}
        .formula-val {{
            flex: 1;
            background: #f8f9fa;
            border: 1px solid #ced4da;
            border-radius: 4px;
            padding: 2px 10px;
            color: #333;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
            user-select: text;
        }}
        .inspector-hint {{
            font-size: 11px;
            color: #6c757d;
        }}

        /* Main Spreadsheet Area */
        .excel-body {{
            flex: 1;
            overflow: hidden;
            display: flex;
            flex-direction: column;
            position: relative;
        }}
        .sheet-pane {{
            flex: 1;
            height: 100%;
            overflow: hidden;
            display: flex;
            flex-direction: column;
        }}
        .sheet-info-pill {{
            padding: 6px 16px;
            background: #fdfefe;
            border-bottom: 1px solid #e2e8f0;
            display: flex;
            align-items: center;
            gap: 16px;
            font-size: 12px;
            color: #4a5568;
            flex-shrink: 0;
        }}
        .read-only-tag {{
            background: #edf2f7;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 11px;
            color: #4a5568;
        }}
        .table-scroll-wrapper {{
            flex: 1;
            overflow: auto;
            position: relative;
            background: #ffffff;
        }}

        /* Table Spreadsheet Grid Styling */
        table.excel-sheet-table {{
            border-collapse: separate;
            border-spacing: 0;
            width: max-content;
            background: #ffffff;
            font-size: 12px;
        }}
        table.excel-sheet-table th,
        table.excel-sheet-table td {{
            border-right: 1px solid #d4d4d4;
            border-bottom: 1px solid #d4d4d4;
            padding: 4px 8px;
            white-space: nowrap;
            height: 24px;
            vertical-align: middle;
            user-select: text;
            -webkit-user-select: text;
        }}
        table.excel-sheet-table th.col-header {{
            background: #e9ecef;
            color: #495057;
            text-align: center;
            font-weight: 600;
            position: sticky;
            top: 0;
            z-index: 5;
            border-top: 1px solid #ced4da;
            min-width: 50px;
        }}
        table.excel-sheet-table th.row-num {{
            background: #e9ecef;
            color: #495057;
            text-align: center;
            font-weight: 600;
            position: sticky;
            left: 0;
            z-index: 4;
            border-left: 1px solid #ced4da;
            min-width: 36px;
        }}
        table.excel-sheet-table th.cell-row-num {{
            background: #dee2e6;
            position: sticky;
            top: 0;
            left: 0;
            z-index: 6;
            min-width: 36px;
            border-top: 1px solid #ced4da;
            border-left: 1px solid #ced4da;
        }}
        table.excel-sheet-table td {{
            color: #1a1a1a;
            cursor: cell;
        }}
        table.excel-sheet-table td:hover {{
            background-color: #f1f8e9 !important;
        }}
        table.excel-sheet-table td.selected-cell {{
            outline: 2px solid #107C41;
            background-color: #e8f5e9 !important;
        }}

        /* Bottom Sheet Tab Strip */
        .sheet-tab-strip {{
            background: #e9ecef;
            border-top: 1px solid #ced4da;
            display: flex;
            align-items: center;
            gap: 2px;
            padding: 4px 12px 0 12px;
            overflow-x: auto;
            flex-shrink: 0;
            z-index: 10;
        }}
        .tab-btn {{
            background: #dee2e6;
            border: 1px solid #ced4da;
            border-bottom: none;
            padding: 6px 16px;
            border-radius: 6px 6px 0 0;
            font-size: 12px;
            font-weight: 600;
            color: #495057;
            cursor: pointer;
            transition: all 0.1s ease;
            white-space: nowrap;
            display: flex;
            align-items: center;
            gap: 6px;
        }}
        .tab-btn:hover {{
            background: #f8f9fa;
        }}
        .tab-btn.active {{
            background: #ffffff;
            color: #107C41;
            border-color: #ced4da;
            border-bottom: 2px solid #ffffff;
            margin-bottom: -1px;
            padding-bottom: 7px;
            box-shadow: 0 -2px 5px rgba(0,0,0,0.05);
        }}
        .tab-num {{
            background: rgba(0,0,0,0.08);
            border-radius: 10px;
            padding: 1px 6px;
            font-size: 10px;
        }}
        .tab-btn.active .tab-num {{
            background: #107C41;
            color: white;
        }}
    </style>
</head>
<body>
    <!-- Top Ribbon -->
    <header class="excel-ribbon">
        <div class="ribbon-brand">
            <div class="excel-icon">X</div>
            <div class="ribbon-titles">
                <h1>
                    <span>{course_code}</span> {data.get("filename", "")}
                    <span class="readonly-badge">🔒 ตรวจสอบได้ แต่แก้ไขไม่ได้</span>
                </h1>
                <p>สมุด ปพ.5 ฉบับจริง (ครบทั้ง {len(sheets)} ชีท) • ภาคเรียนที่ {term}/{year}</p>
            </div>
        </div>
        <div class="ribbon-actions">
            <a class="btn btn-excel" href="{excel_dl_url}">⬇️ ดาวน์โหลด .xlsx</a>
            <a class="btn btn-pdf" href="{pdf_dl_url}" target="_blank">📄 เปิดดู PDF จริง</a>
            <a class="btn btn-pdf" href="{print_url}" target="_blank">🖨️ สั่งพิมพ์</a>
            <button class="btn btn-close" onclick="window.close()">✖️ ปิดหน้านี้</button>
        </div>
    </header>

    <!-- Formula Bar -->
    <div class="formula-bar">
        <div class="coord-box" id="selectedCoord">A1</div>
        <span class="fx-label">fx</span>
        <div class="formula-val" id="selectedVal">-</div>
        <span class="inspector-hint">💡 คลิกเซลล์ใดก็ได้เพื่อตรวจสอบค่าและสูตร</span>
    </div>

    <!-- Main Spreadsheet Panes -->
    <main class="excel-body">
        {"".join(sheets_container_html)}
    </main>

    <!-- Bottom Sheet Tabs Strip -->
    <footer class="sheet-tab-strip">
        {"".join(tabs_html)}
    </footer>

    <script>
        let currentSheetIdx = 0;
        let selectedCellEl = null;

        function selectSheet(idx) {{
            document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
            document.querySelectorAll('.sheet-pane').forEach(pane => pane.style.display = 'none');

            const btn = document.getElementById('tab-btn-' + idx);
            const pane = document.getElementById('sheet-pane-' + idx);
            if (btn) btn.classList.add('active');
            if (pane) pane.style.display = 'flex';
            currentSheetIdx = idx;
        }}

        document.addEventListener('click', function(e) {{
            const td = e.target.closest('td');
            if (!td) return;
            if (selectedCellEl) selectedCellEl.classList.remove('selected-cell');
            selectedCellEl = td;
            selectedCellEl.classList.add('selected-cell');

            const coord = td.getAttribute('data-coord') || 'Cell';
            const val = td.getAttribute('data-val') || td.innerText || '';
            document.getElementById('selectedCoord').innerText = coord;
            document.getElementById('selectedVal').innerText = val;
        }});
    </script>
</body>
</html>"""
        return Response(content=html_content, media_type="text/html; charset=utf-8")
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Failed to render course Excel view: {str(e)}")


@app.get("/api/v1/print-pdf")
def print_pdf_view(
    course_code: str = Query(...),
    term: Optional[str] = Query(None),
    year: Optional[str] = Query(None)
):
    """
    Renders an HTML print viewer page that embeds the print-ready PDF and triggers print.
    """
    pdf_url = f"/api/v1/course-file?course_code={course_code}&format=pdf&inline=true"
    if term:
        pdf_url += f"&term={term}"
    if year:
        pdf_url += f"&year={year}"

    dl_url = f"/api/v1/course-file?course_code={course_code}&format=pdf"
    if term:
        dl_url += f"&term={term}"
    if year:
        dl_url += f"&year={year}"

    html_content = f"""<!DOCTYPE html>
<html lang="th">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>พิมพ์เอกสาร ปพ.5 - {course_code}</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{
            font-family: 'Sarabun', 'TH SarabunPSK', sans-serif;
            background: #2b2b2b;
            height: 100vh;
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }}
        .toolbar {{
            background: #1e1e1e;
            color: #ffffff;
            padding: 10px 20px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            box-shadow: 0 2px 8px rgba(0,0,0,0.4);
            z-index: 10;
        }}
        .toolbar h1 {{
            font-size: 16px;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 8px;
        }}
        .actions {{
            display: flex;
            align-items: center;
            gap: 12px;
        }}
        .btn {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 8px 16px;
            border-radius: 6px;
            font-size: 13px;
            font-weight: bold;
            cursor: pointer;
            border: none;
            text-decoration: none;
            transition: all 0.2s ease;
        }}
        .btn-print {{
            background: #2e7d32;
            color: white;
        }}
        .btn-print:hover {{
            background: #1b5e20;
        }}
        .btn-download {{
            background: #0288d1;
            color: white;
        }}
        .btn-download:hover {{
            background: #01579b;
        }}
        .btn-close {{
            background: #424242;
            color: #eeeeee;
        }}
        .btn-close:hover {{
            background: #616161;
        }}
        .pdf-container {{
            flex: 1;
            width: 100%;
            height: calc(100vh - 54px);
        }}
        iframe {{
            width: 100%;
            height: 100%;
            border: none;
        }}
    </style>
</head>
<body>
    <div class="toolbar">
        <h1>
            <span>📄</span> พิมพ์เอกสาร ปพ.5 รายวิชา {course_code} {f'(ภาคเรียนที่ {term}/{year})' if term and year else ''}
        </h1>
        <div class="actions">
            <button class="btn btn-print" onclick="triggerPrint()">🖨️ สั่งพิมพ์เอกสาร (Print)</button>
            <a class="btn btn-download" href="{dl_url}">⬇️ ดาวน์โหลด PDF</a>
            <button class="btn btn-close" onclick="window.close()">✖️ ปิดหน้านี้</button>
        </div>
    </div>
    <div class="pdf-container">
        <iframe id="pdfFrame" src="{pdf_url}" onload="onPdfLoaded()"></iframe>
    </div>
    <script>
        function triggerPrint() {{
            const frame = document.getElementById('pdfFrame');
            try {{
                frame.contentWindow.focus();
                frame.contentWindow.print();
            }} catch(e) {{
                window.print();
            }}
        }}
        function onPdfLoaded() {{
            setTimeout(function() {{
                triggerPrint();
            }}, 800);
        }}
    </script>
</body>
</html>"""
    return Response(content=html_content, media_type="text/html")


@app.get("/api/v1/course-preview")
def get_course_preview(
    course_code: str = Query(...),
    term: Optional[str] = Query(None),
    year: Optional[str] = Query(None)
):
    """
    Returns full verification data for a course before download or printing:
    - Cover metadata (course info, teacher, class level, advisors)
    - Grade distribution summary (counts for 4, 3.5, 3, 2.5, 2, 1.5, 1, 0, ร, มส)
    - Student roster with scores, attendance percentage, and grade
    - Ready status of Excel and PDF files
    """
    try:
        with get_connection("school_archive.db") as conn:
            cursor = conn.cursor()

            # Find course
            if term and year:
                cursor.execute(
                    "SELECT * FROM courses WHERE course_code = ? AND term = ? AND year = ? LIMIT 1;",
                    (course_code, str(term), str(year))
                )
            else:
                cursor.execute(
                    "SELECT * FROM courses WHERE course_code = ? ORDER BY year DESC, term DESC LIMIT 1;",
                    (course_code,)
                )
            c_row = cursor.fetchone()
            if not c_row:
                raise HTTPException(status_code=404, detail="Course not found")

            c_term = c_row["term"]
            c_year = c_row["year"]
            c_name = c_row["course_name"]
            c_teacher = c_row["teacher"] or ""
            c_desc = c_row["course_description"] or ""

            # Infer class level
            lvl = infer_class_level(course_code, "")

            # Get advisors for this class level
            advisors_list = []
            adv_info = get_advisor_for_class(term=c_term, year=c_year, class_level=lvl)
            if adv_info:
                advisors_list = [
                    a.strip() for a in [
                        adv_info.get("advisor1"),
                        adv_info.get("advisor2"),
                        adv_info.get("advisor3")
                    ] if a and a.strip()
                ]

            # Query students and grades
            query = """
            SELECT 
                g.id,
                g.student_id,
                s.full_name,
                g.scores_json,
                g.attendance_json,
                g.final_grade
            FROM grades_history g
            JOIN students s ON g.student_id = s.student_id
            WHERE g.course_code = ? AND g.term = ? AND g.year = ?
            ORDER BY g.student_id ASC;
            """
            cursor.execute(query, (course_code, c_term, c_year))
            g_rows = cursor.fetchall()

            students_data = []
            grade_dist: Dict[str, int] = {
                "4": 0, "3.5": 0, "3": 0, "2.5": 0, "2": 0, "1.5": 0, "1": 0, "0": 0,
                "ร": 0, "มส": 0, "ผ": 0, "มผ": 0
            }

            # Locked students = ห้อง 2 (โปรแกรม 3 รูปแบบ, เรียนและทำงาน): no check-in, so no attendance to show.
            # Their grades_history still holds the SGS figure (e.g. 95%) because the daily sync skips them;
            # the owner (14 พ.ย. 2569): "นักเรียนที่อยู่ห้อง 2 ไม่ต้องแสดงเวลาเรียน ให้เป็น - ได้เลย ทุกคน".
            cursor.execute(
                "SELECT student_id FROM class_students WHERE term = ? AND year = ? AND COALESCE(is_locked, 0) = 1;",
                (c_term, c_year)
            )
            no_attendance_ids = {row["student_id"] for row in cursor.fetchall()}

            for idx, r in enumerate(g_rows, start=1):
                sc = json.loads(r["scores_json"]) if r["scores_json"] else {}
                att = json.loads(r["attendance_json"]) if r["attendance_json"] else {}
                gr = str(r["final_grade"] or "").strip()
                if gr in grade_dist:
                    grade_dist[gr] += 1

                st_no = sc.get("student_no") or idx
                st_id = r["student_id"]
                fn = r["full_name"]
                tot = sc.get("total", "")
                if st_id in no_attendance_ids:
                    att = {}  # shown as "-"
                att_pct = att.get("percentage")

                students_data.append({
                    "student_no": st_no,
                    "student_id": st_id,
                    "full_name": fn,
                    "total_score": str(tot) if tot != "" else "-",
                    "final_grade": gr if gr else "-",
                    "attendance_percentage": att_pct,
                    "present_count": att.get("present_count"),
                    "absent_count": att.get("absent_count"),
                    "leave_count": att.get("leave_count")
                })

            students_data.sort(key=lambda s: s["student_no"])

            # Check existing files
            excel_match = find_course_matching_file(OUTPUT_DIR, course_code, term=c_term, year=c_year, ext=".xlsx")
            if not excel_match:
                excel_match = ensure_standby_excel_file(course_code, term=c_term, year=c_year)
            pdf_match = find_course_matching_file(OUTPUT_DIR, course_code, term=c_term, year=c_year, ext=".pdf")

            return {
                "status": "success",
                "data": {
                    "course_code": course_code,
                    "course_name": c_name,
                    "term": c_term,
                    "year": c_year,
                    "teacher": c_teacher,
                    "class_level": lvl,
                    "advisors": advisors_list,
                    "has_description": bool(c_desc.strip()),
                    "course_description": c_desc,
                    "total_students": len(students_data),
                    "grade_distribution": grade_dist,
                    "students": students_data,
                    "has_excel": excel_match is not None,
                    "has_pdf": pdf_match is not None,
                    "excel_filename": excel_match.name if excel_match else None,
                    "pdf_filename": pdf_match.name if pdf_match else None,
                    "excel_url": f"/api/v1/course-file?course_code={course_code}&term={c_term}&year={c_year}&format=excel",
                    "pdf_url": f"/api/v1/course-file?course_code={course_code}&term={c_term}&year={c_year}&format=pdf",
                    "print_url": f"/api/v1/print-pdf?course_code={course_code}&term={c_term}&year={c_year}"
                }
            }
    except HTTPException:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/course/teacher")
def update_course_teacher_api(payload: UpdateCourseTeacherRequest):
    """Update teacher name for a course."""
    try:
        ok = update_course_teacher(
            course_code=payload.course_code.strip(),
            teacher=payload.teacher.strip(),
            term=payload.term.strip() if payload.term else None,
            year=payload.year.strip() if payload.year else None,
            db_path="school_archive.db"
        )
        if not ok:
            raise HTTPException(status_code=404, detail="Course not found")

        # Also sync to existing Excel files
        norm_t = normalize_teacher_name(payload.teacher.strip())
        target_excel = find_course_matching_file(
            OUTPUT_DIR,
            payload.course_code,
            term=payload.term.strip() if payload.term else None,
            year=payload.year.strip() if payload.year else None,
            ext=".xlsx"
        )
        if target_excel:
            try:
                sync_cover_sheet_to_excel(
                    target_excel,
                    teacher=norm_t,
                    course_code=payload.course_code,
                    term=payload.term.strip() if payload.term else None,
                    year=payload.year.strip() if payload.year else None
                )
            except Exception:
                pass
        else:
            for f in OUTPUT_DIR.glob(f"*{payload.course_code}*.xlsx"):
                if not f.name.startswith("~$"):
                    try:
                        sync_cover_sheet_to_excel(
                            f,
                            teacher=norm_t,
                            course_code=payload.course_code,
                            term=payload.term.strip() if payload.term else None,
                            year=payload.year.strip() if payload.year else None
                        )
                    except Exception:
                        pass
        # the Excel cover was updated in place; its print-ready PDF still shows the old teacher
        if payload.term and payload.year:
            porpor5_refresh_queue.enqueue(payload.term.strip(), payload.year.strip(), [payload.course_code.strip()], pdf_only=True)

        return {
            "status": "success",
            "message": f"อัปเดตชื่อครูผู้สอนเป็น '{norm_t}' เรียบร้อยแล้ว",
            "teacher": norm_t
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/courses")
def get_courses():
    """List all archived courses with student count."""
    try:
        with get_connection("school_archive.db") as conn:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT 
                    c.course_code,
                    c.course_name,
                    c.term,
                    c.year,
                    c.teacher,
                    c.course_description,
                    c.class_level,
                    c.credits,
                    c.teacher_code,
                    COALESCE(
                        NULLIF((SELECT COUNT(*) FROM grades_history g WHERE g.course_code = c.course_code AND g.term = c.term AND g.year = c.year), 0),
                        NULLIF((SELECT COUNT(*) FROM class_students cs WHERE cs.term = c.term AND cs.year = c.year AND cs.class_level = c.class_level AND COALESCE(cs.is_locked, 0) = 0 AND COALESCE(cs.is_active, 1) = 1), 0),
                        (SELECT COUNT(*) FROM class_students cs WHERE cs.term = '1' AND cs.year = c.year AND cs.class_level = c.class_level AND COALESCE(cs.is_locked, 0) = 0 AND COALESCE(cs.is_active, 1) = 1),
                        0
                    ) AS student_count
                FROM courses c 
                ORDER BY c.year DESC, c.term DESC, c.course_code ASC;
            """)
            rows = cursor.fetchall()
            return {"status": "success", "data": [dict(r) for r in rows]}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database query failed: {str(e)}")

@app.get("/api/v1/students")
def get_students():
    """List all students."""
    try:
        with get_connection("school_archive.db") as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT student_id, full_name FROM students ORDER BY student_id ASC;")
            rows = cursor.fetchall()
            return {"status": "success", "data": [dict(r) for r in rows]}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database query failed: {str(e)}")


@app.get("/api/v1/grades")
def get_grades_api(
    term: str = Query(...),
    year: str = Query(...),
    course_code: Optional[str] = Query(None)
):
    """Fetch grade history by term and year, optionally filtered by course_code."""
    try:
        data = query_grades_by_semester(
            term=str(term),
            year=str(year),
            course_code=course_code,
            db_path="school_archive.db"
        )
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch grades: {str(e)}")


@app.get("/api/v1/student/{student_id}/transcript")
def get_student_transcript_api(student_id: str):
    """Fetch a student's full academic transcript across all terms."""
    try:
        data = query_student_transcript(student_id=student_id, db_path="school_archive.db")
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch student transcript: {str(e)}")


# -------------------------------------------------------------
# Semester Buttons Configuration & Data Reset Endpoints
# -------------------------------------------------------------
@app.get("/api/v1/settings/semesters")
def list_semester_configs_api(request: Request):
    """List all semester button configurations with live course counts.
    my_mark = ภาคเรียนที่ผู้ใช้คนนี้ mark ไว้ดูเอง (ว่าง = ใช้ของโรงเรียนที่ผู้ดูแลระบบตั้งไว้)"""
    try:
        data = get_semester_configs(db_path="school_archive.db")
        me = current_user(request)
        mine = None
        if me.get("code") and me.get("role") not in ("guest", "student"):
            mine = database.get_user_preference(str(me["code"]).strip(), "semester", db_path="school_archive.db")
        return {"status": "success", "data": data, "my_mark": mine}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/settings/semesters")
def save_semester_config_api(payload: SemesterConfigRequest):
    """Create or update a semester button configuration."""
    try:
        res = upsert_semester_config(
            term=payload.term.strip(),
            year=payload.year.strip(),
            title=payload.title.strip(),
            display_order=payload.display_order or 0,
            is_active=1 if payload.is_active else 0,
            config_id=payload.id,
            db_path="school_archive.db"
        )
        return {"status": "success", "data": res}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/api/v1/settings/semesters/{config_id}")
def delete_semester_config_api(config_id: int):
    """Delete a semester button configuration."""
    try:
        ok = delete_semester_config(config_id, db_path="school_archive.db")
        if not ok:
            raise HTTPException(status_code=404, detail="Semester config not found")
        return {"status": "success", "message": "Deleted semester configuration"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class StudentNameRequest(BaseModel):
    prefix: Optional[str] = None
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    term: Optional[str] = None
    year: Optional[str] = None
    class_level: Optional[str] = None


@app.get("/api/v1/students/{student_id}/name")
def get_student_name_api(student_id: str):
    """คำนำหน้า / ชื่อ / สกุล ที่ระบบใช้อยู่ของนักเรียนคนนี้ (แยกช่อง)"""
    data = database.get_student_name(student_id, db_path="school_archive.db")
    if not data["first_name"]:
        raise HTTPException(status_code=404, detail="ไม่พบนักเรียนรหัสนี้")
    return {"status": "success", "data": data}


@app.post("/api/v1/students/{student_id}/name")
def set_student_name_api(student_id: str, payload: StudentNameRequest, request: Request):
    """แก้ชื่อนักเรียน (ครูที่ปรึกษาของชั้นนั้น หรือผู้ดูแลระบบ) แล้วอัปเดตให้ทุกหน้าและ ปพ.5 ทันที"""
    sid = student_id.strip()
    with get_connection("school_archive.db") as conn:
        row = conn.execute(
            """SELECT term, year, class_level FROM class_students WHERE student_id = ?
               ORDER BY CAST(year AS INTEGER) DESC, CAST(term AS INTEGER) DESC LIMIT 1;""", (sid,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="ไม่พบนักเรียนรหัสนี้")
    require_class_advisor(request, payload.class_level or row["class_level"], payload.term or row["term"], payload.year or row["year"])
    try:
        data = database.set_student_name(sid, payload.prefix, payload.first_name, payload.last_name, db_path="school_archive.db")
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {"status": "success", "data": data,
            "message": f"บันทึกชื่อ {data['full_name']} แล้ว ระบบอัปเดตให้ทุกหน้าและ ปพ.5 เรียบร้อย"}


# ---------------------------------------------------------------- รูปนักเรียน + หน้าต่างข้อมูลนักเรียน (student_photos.py)
# Seen by teachers, the director and admins; a student sees only their own (/student-portal/photo);
# guests never (auth.py). Upload: admin any student, a class advisor the levels they advise.

class StudentPhotoTokenRequest(BaseModel):
    token: str


class StudentPhotoDeleteRequest(BaseModel):
    term: str
    year: str


def _photo_response(path: Path, versioned: bool) -> FileResponse:
    # with ?v=<version> the URL changes whenever the photo does: the browser may keep it for good
    cache = "private, max-age=31536000, immutable" if versioned else "private, no-cache"
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": cache})


@app.get("/api/v1/students/{student_id}/profile")
def student_profile_api(student_id: str, request: Request, term: str = Query(...), year: str = Query(...)):
    """ข้อมูลนักเรียนในหน้าต่างนักเรียน: ชื่อ ชั้น ข้อมูลพื้นฐาน ที่อยู่ ผู้ปกครอง (จาก DMC) และรูป
    เลขบัตรประชาชนส่งให้เฉพาะผู้ดูแลระบบ"""
    u = current_user(request)
    sid = student_id.strip()
    data = student_photos.student_profile(sid, term, year, include_citizen=u.get("role") == "admin",
                                          db_path="school_archive.db")
    if not data:
        raise HTTPException(status_code=404, detail="ไม่พบนักเรียนรหัสนี้")
    data["can_edit_photo"] = student_photos.can_edit(u, sid, term, year, "school_archive.db")
    return {"status": "success", "data": data}


@app.get("/api/v1/students/{student_id}/photo")
def student_photo_api(student_id: str, v: Optional[str] = None):
    p = student_photos.photo_path(student_id.strip())
    if not p:
        raise HTTPException(status_code=404, detail="ยังไม่มีรูปนักเรียน")
    return _photo_response(p, bool(v))


@app.post("/api/v1/students/{student_id}/photo")
async def student_photo_upload_api(student_id: str, request: Request, term: str = Form(...), year: str = Form(...),
                                   file: UploadFile = File(...)):
    """รูปของนักเรียนคนเดียวจากหน้าต่างนักเรียน (ถ่ายจากกล้อง หรือเลือกรูปจากเครื่อง) แทนรูปเดิมทันที"""
    from starlette.concurrency import run_in_threadpool
    sid = student_id.strip()
    if not student_photos.can_edit(current_user(request), sid, term, year, "school_archive.db"):
        raise HTTPException(status_code=403, detail="อัปโหลดรูปได้เฉพาะครูประจำชั้นของนักเรียนคนนี้ หรือผู้ดูแลระบบ")
    if (file.size or 0) > student_photos.MAX_FILE_BYTES:  # refuse before reading it into memory
        raise HTTPException(status_code=400, detail="ไฟล์ใหญ่เกิน 40 MB")
    data = await file.read()
    try:
        res = await run_in_threadpool(student_photos.save_photo, sid, data)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {"status": "success", "data": res,
            "message": "เปลี่ยนรูปนักเรียนแล้ว" if res["replaced"] else "บันทึกรูปนักเรียนแล้ว"}


@app.post("/api/v1/students/{student_id}/photo/delete")
def student_photo_delete_api(student_id: str, payload: StudentPhotoDeleteRequest, request: Request):
    sid = student_id.strip()
    if not student_photos.can_edit(current_user(request), sid, payload.term, payload.year, "school_archive.db"):
        raise HTTPException(status_code=403, detail="ลบรูปได้เฉพาะครูประจำชั้นของนักเรียนคนนี้ หรือผู้ดูแลระบบ")
    if not student_photos.delete_photo(sid):
        raise HTTPException(status_code=404, detail="ยังไม่มีรูปนักเรียน")
    return {"status": "success", "message": "ลบรูปนักเรียนแล้ว"}


@app.get("/api/v1/student-photos/scope")
def student_photo_scope_api(request: Request, term: str = Query(...), year: str = Query(...)):
    """ใครอัปโหลดรูปให้ชั้นไหนได้ + มีรูปแล้วกี่คน ใครยังไม่มี"""
    scope = student_photos.upload_scope(current_user(request), term, year, "school_archive.db")
    return {"status": "success", "data": {**scope, **student_photos.coverage(scope, term, year, "school_archive.db")}}


@app.post("/api/v1/student-photos/stage")
async def student_photo_stage_api(request: Request, term: str = Form(...), year: str = Form(...),
                                  token: Optional[str] = Form(None), files: List[UploadFile] = File(...)):
    """ขั้นที่ 1: รับรูป/ZIP (ชื่อไฟล์ = รหัสนักเรียน) ย่อรูป จับคู่ แล้วพักไว้ให้ตรวจก่อนบันทึก
    ส่งหลายรอบด้วย token เดิมได้ (ไฟล์จำนวนมาก)"""
    from starlette.concurrency import run_in_threadpool
    # every upload already sits in a temp file (Starlette spools anything over 1 MB to disk): pass the open files,
    # not their bytes, so a big ZIP is read one photo at a time instead of all at once into RAM
    sources = [(f.filename or "", f.file) for f in files]
    try:
        res = await run_in_threadpool(student_photos.stage, sources, current_user(request), term, year,
                                      token or None, "school_archive.db")
    except PermissionError as e:
        raise HTTPException(status_code=403, detail=str(e))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {"status": "success", "data": res}


@app.get("/api/v1/student-photos/stage/{token}/{student_id}.jpg")
def student_photo_staged_api(token: str, student_id: str, request: Request):
    try:
        p = student_photos.staged_photo(token, student_id, current_user(request))
    except PermissionError as e:
        raise HTTPException(status_code=403, detail=str(e))
    except (ValueError, FileNotFoundError):
        raise HTTPException(status_code=404, detail="ไม่พบรูป")
    return FileResponse(p, media_type="image/jpeg", headers={"Cache-Control": "no-store"})


@app.post("/api/v1/student-photos/commit")
def student_photo_commit_api(payload: StudentPhotoTokenRequest, request: Request):
    """ขั้นที่ 2: บันทึกรูปที่ตรวจแล้วเข้าระบบ (data/student_photos/)"""
    try:
        res = student_photos.commit(payload.token, current_user(request), "school_archive.db")
    except PermissionError as e:
        raise HTTPException(status_code=403, detail=str(e))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {"status": "success", "data": res, "message": res["message"]}


@app.post("/api/v1/student-photos/cancel")
def student_photo_cancel_api(payload: StudentPhotoTokenRequest, request: Request):
    try:
        student_photos.cancel(payload.token, current_user(request))
    except PermissionError as e:
        raise HTTPException(status_code=403, detail=str(e))
    except ValueError:
        pass
    return {"status": "success"}


@app.get("/api/v1/student-portal/photo")
def student_portal_photo_api(request: Request, v: Optional[str] = None):
    """นักเรียนเห็นเฉพาะรูปของตนเอง"""
    p = student_photos.photo_path(str(current_user(request).get("code", "")))
    if not p:
        raise HTTPException(status_code=404, detail="ยังไม่มีรูปนักเรียน")
    return _photo_response(p, bool(v))


@app.post("/api/v1/students/refresh-prefixes")
def refresh_student_prefixes_api():
    """ผู้ดูแลระบบ: ไล่เปลี่ยนคำนำหน้าของนักเรียนที่อายุครบ 15 ปีแล้วทันที (ปกติระบบทำให้เองทุกวัน)"""
    done = database.refresh_student_prefixes(db_path="school_archive.db")
    return {"status": "success", "data": done,
            "message": f"เปลี่ยนคำนำหน้าให้ {len(done)} คน" if done else "ทุกคนมีคำนำหน้าตรงกับอายุแล้ว"}


class MarkSemesterRequest(BaseModel):
    term: Optional[str] = None
    year: Optional[str] = None
    clear: bool = False


@app.post("/api/v1/settings/semesters/mark-mine")
def mark_my_semester_api(payload: MarkSemesterRequest, request: Request):
    """ภาคเรียนที่ผู้ใช้คนนี้ mark ไว้ดูเอง (ไม่กระทบคนอื่น) — ว่างไว้ = ใช้ของโรงเรียนที่ผู้ดูแลระบบตั้ง"""
    me = current_user(request)
    code = str(me.get("code") or "").strip()
    if not code or me.get("role") in ("guest", "student"):
        raise HTTPException(status_code=403, detail="ต้องเข้าสู่ระบบด้วยรหัสครูก่อน")
    if payload.clear or not (payload.term and payload.year):
        database.clear_user_preference(code, "semester", db_path="school_archive.db")
        return {"status": "success", "data": {"my_mark": None}, "message": "กลับไปใช้ภาคเรียนเริ่มต้นของโรงเรียนแล้ว"}
    value = f"{payload.term.strip()}-{payload.year.strip()}"
    database.set_user_preference(code, "semester", value, db_path="school_archive.db")
    return {"status": "success", "data": {"my_mark": value},
            "message": f"Mark ภาคเรียนที่ {payload.term}/{payload.year} ไว้ดูเองแล้ว (เฉพาะบัญชีของท่าน)"}


class SetDefaultSemesterRequest(BaseModel):
    term: str
    year: str


@app.post("/api/v1/settings/semesters/set-default")
def set_default_semester_api(payload: SetDefaultSemesterRequest):
    """Mark a specific semester as the default semester shown on Dashboard & refresh."""
    try:
        t = payload.term.strip()
        y = payload.year.strip()
        data = set_default_semester(term=t, year=y, db_path="school_archive.db")
        return {
            "status": "success",
            "term": t,
            "year": y,
            "data": data,
            "message": f"ปักหมุด ปีการศึกษา {y} ภาคเรียนที่ {t} เป็นเทอมหลักที่แสดงเสมอเรียบร้อยแล้ว"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/settings/semesters/reset-defaults")
def reset_semester_configs_api():
    """Reset semester buttons to standard 4 defaults."""
    try:
        data = reset_semester_configs_to_defaults(db_path="school_archive.db")
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/settings/semesters/delete-data")
def delete_semester_data_api(payload: SemesterDataDeleteRequest):
    """
    Delete all grades, courses, and related data for a specific semester.
    Allows teachers to clear test or outdated data and import fresh records for that semester.
    Optionally backs up the semester before deletion.
    """
    try:
        backup_info = None
        if payload.backup_first:
            import backup_manager
            b_label = payload.backup_label or f"สำรองข้อมูลก่อนล้างเทอม {payload.term}/{payload.year}"
            backup_info = backup_manager.create_backup(
                label=b_label,
                term=payload.term.strip(),
                year=payload.year.strip(),
                backup_type="semester"
            )

        res = delete_semester_data(
            term=payload.term.strip(),
            year=payload.year.strip(),
            delete_files=bool(payload.delete_files),
            db_path="school_archive.db",
            outputs_dir=str(OUTPUT_DIR)
        )
        if backup_info:
            res["backup_created"] = backup_info
        return {"status": "success", "data": res}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/settings/reset-all-data")
def reset_all_data_api(payload: ResetAllDataRequest):
    """
    Reset all database records (all courses, grades, students).
    Optionally backs up all data before resetting.
    """
    try:
        backup_info = None
        if payload.backup_first:
            import backup_manager
            now_str = datetime.now().strftime("%d/%m/%Y %H:%M")
            b_label = payload.backup_label or f"สำรองข้อมูลระบบทั้งหมดก่อนรีเซ็ต ({now_str})"
            backup_info = backup_manager.create_backup(
                label=b_label,
                backup_type="full"
            )

        res = reset_all_data(
            delete_files=bool(payload.delete_files),
            db_path="school_archive.db",
            outputs_dir=str(OUTPUT_DIR)
        )
        if backup_info:
            res["backup_created"] = backup_info
        return {"status": "success", "data": res}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# -------------------------------------------------------------
# Backup & Archive Endpoints (การจัดเก็บและกู้คืนข้อมูลสำรอง)
# -------------------------------------------------------------
class ArchiveCreateRequest(BaseModel):
    include_outputs: bool = False
    label: Optional[str] = ""


def _is_local_request(request: Request) -> bool:
    """The browser on the server itself (http://localhost:8000). The ngrok tunnel also connects from 127.0.0.1,
    so a forwarded header or a public Host name means the request came from outside."""
    host = (request.client.host if request.client else "") or ""
    if host not in ("127.0.0.1", "::1", "localhost"):
        return False
    if any(h in request.headers for h in ("x-forwarded-for", "x-forwarded-host", "x-real-ip", "forwarded")):
        return False
    name = (request.headers.get("host", "") or "").split(":")[0].strip("[]").lower()
    return name in ("localhost", "127.0.0.1", "::1")


@app.get("/api/v1/recovery/status")
def recovery_status_api(request: Request):
    """เครื่องที่ลงใหม่ (ฐานข้อมูลว่าง ยังไม่มีใครล็อกอินได้): หน้าเว็บเปิดหน้า "กู้คืนระบบ" แทนหน้าเข้าสู่ระบบ"""
    import archive_backup
    return {"status": "success", "needs_recovery": archive_backup.needs_recovery(), "local": _is_local_request(request)}


class NewSchoolSetupRequest(BaseModel):
    school_name: str                      # ชื่อโรงเรียน (มีหรือไม่มีคำว่า "โรงเรียน" ก็ได้)
    subdistrict: Optional[str] = ""
    district: Optional[str] = ""
    province: Optional[str] = ""
    area_office: Optional[str] = ""       # สังกัด เช่น สำนักงานเขตพื้นที่การศึกษามัธยมศึกษา...
    area_short: Optional[str] = ""        # ชื่อย่อสังกัด เช่น สพม.…
    school_id: Optional[str] = ""         # รหัสสถานศึกษา (DMC)
    director_name: Optional[str] = ""
    admin_name: str                       # ผู้ดูแลระบบคนแรก (ครู)
    admin_code: str                       # รหัสครูที่ใช้เข้าสู่ระบบ
    admin_pin: str


@app.get("/api/v1/school-profile")
def school_profile_api():
    """ชื่อโรงเรียน สังกัด ที่ตั้ง (หน้าเข้าสู่ระบบ หัวรายงาน หัวตาราง); before setup everything is empty."""
    return {"status": "success", "data": school_profile.info()}


@app.post("/api/v1/setup/new-school")
def setup_new_school_api(payload: NewSchoolSetupRequest, request: Request):
    """
    First run of a new school (ฉบับเปล่า): nobody can log in yet, so this is open without a session, but only while the
    database has no teacher and no student, and only from the server's own screen (like the recovery upload).
    Saves the school's identity, creates the first admin (a teacher with a PIN) and the director as signatory.
    """
    import archive_backup
    if not archive_backup.needs_recovery():
        raise HTTPException(status_code=403, detail="ระบบตั้งค่าโรงเรียนไว้แล้ว ให้ผู้ดูแลระบบเข้าสู่ระบบแล้วแก้ที่หน้าตั้งค่า")
    if not _is_local_request(request):
        raise HTTPException(status_code=403, detail="ตั้งค่าครั้งแรกได้จากหน้าจอเครื่องเซิร์ฟเวอร์เท่านั้น (เปิด http://localhost:8000 บนเครื่องนั้น)")
    name = school_profile.strip_prefix(payload.school_name)
    code = (payload.admin_code or "").strip()
    pin = (payload.admin_pin or "").strip()
    admin = " ".join((payload.admin_name or "").split())
    if not name:
        raise HTTPException(status_code=400, detail="กรุณากรอกชื่อโรงเรียน")
    if not admin or not code:
        raise HTTPException(status_code=400, detail="กรุณากรอกชื่อและรหัสของผู้ดูแลระบบ")
    if not pin.isdigit() or not 4 <= len(pin) <= 6:
        raise HTTPException(status_code=400, detail="PIN ต้องเป็นตัวเลข 4–6 หลัก")
    full = f"โรงเรียน{name}"
    db = "school_archive.db"
    settings = {
        "school_name": name, "full_school_name": full, "sidebar_footer_subtitle": full,
        "web_title": f"{full} ระบบบันทึกเวลาเรียน",
        "school_subdistrict": payload.subdistrict, "school_district": payload.district,
        "school_province": payload.province, "school_area_office": payload.area_office,
        "school_area_short": payload.area_short, "school_id": payload.school_id,
    }
    for k, v in settings.items():
        set_app_setting(k, " ".join(str(v or "").split()), db_path=db)
    with get_connection(db) as conn:
        conn.execute("INSERT INTO school_teachers (name, code, login_pin) VALUES (?, ?, ?);", (admin, code, pin))
        conn.execute("INSERT OR REPLACE INTO system_admins (teacher_code, teacher_name) VALUES (?, ?);", (code, admin))
        conn.commit()
    year = str(datetime.now().year + 543)
    database.upsert_school_signatories({
        "year": year, "school_name": full,
        "director_name": " ".join((payload.director_name or "").split()),
        "director_title": f"ผู้อำนวยการ{full}",
    }, db_path=db)
    auth.forget_pin_cache()
    return {"status": "success", "school": school_profile.info(),
            "message": f"ตั้งค่า{full}แล้ว เข้าสู่ระบบด้วยรหัสครู {code} และ PIN ที่ตั้งไว้"}


@app.get("/api/v1/timetables/master-roster")
def master_roster_api(term: str = Query(...), year: str = Query(...)):
    """
    ตารางสอนรวม: the teachers in order with their กลุ่มสาระ. This school keeps its official order (school_builtin_data);
    any other school gets every teacher of the database ordered by code, กลุ่มสาระ = the department they teach most.
    """
    b = school_profile.builtin()
    roster = list(getattr(b, "MASTER_ROSTER", []) if b else [])
    if not roster:
        with get_connection("school_archive.db") as conn:
            teachers = conn.execute(
                "SELECT code, name FROM school_teachers WHERE TRIM(COALESCE(name, '')) <> '' AND TRIM(COALESCE(code, '')) <> '' "
                "ORDER BY CAST(code AS INTEGER), code, name;").fetchall()
            dept: Dict[str, str] = {}
            for r in conn.execute(
                    "SELECT teacher_code, department, COUNT(*) AS n FROM courses WHERE term = ? AND year = ? "
                    "AND TRIM(COALESCE(teacher_code, '')) <> '' GROUP BY teacher_code, department ORDER BY n DESC;",
                    (term, year)):
                dept.setdefault(str(r["teacher_code"]).strip(), (r["department"] or "").strip())
        for i, t in enumerate(teachers, start=1):
            formal = " ".join(t["name"].split())
            bare = re.sub(r"^(ว่าที่\s*ร(้อย)?\.?\s*ต(รี)?\.?\s*|นางสาว|นาง|นาย|น\.ส\.|ครู)", "", formal).strip()
            roster.append({"no": str(i), "key": f"ครู{bare}", "formal": formal,
                           "base": bare.split()[0] if bare else formal, "code": str(t["code"] or "-"),
                           "dept": dept.get(str(t["code"] or "").strip()) or "อื่นๆ"})
    return {"status": "success", "roster": roster}


@app.post("/api/v1/recovery/restore")
def recovery_restore_api(request: Request, file: UploadFile = File(...)):
    """กู้คืนเครื่องใหม่จากไฟล์ .zip โดยไม่ต้องล็อกอิน: ทำได้เฉพาะตอนฐานข้อมูลว่าง และจากหน้าจอเครื่องเซิร์ฟเวอร์เท่านั้น"""
    import archive_backup
    if not archive_backup.needs_recovery():
        raise HTTPException(status_code=403, detail="ระบบมีข้อมูลอยู่แล้ว ให้ผู้ดูแลระบบเข้าสู่ระบบแล้วกู้คืนที่หน้าตั้งค่า")
    if not _is_local_request(request):
        raise HTTPException(status_code=403, detail="กู้คืนเครื่องใหม่ได้จากหน้าจอเครื่องเซิร์ฟเวอร์เท่านั้น (เปิด http://localhost:8000 บนเครื่องนั้น)")
    archive_backup.ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
    dest = archive_backup.ARCHIVE_DIR / ("school_backup_" + datetime.now().strftime("%Y%m%d_%H%M%S") + "_manual_recovery.zip")
    with open(dest, "wb") as f:
        shutil.copyfileobj(file.file, f)
    try:
        res = archive_backup.restore_archive(str(dest))
    except (ValueError, Exception) as e:
        dest.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail=f"กู้คืนไม่สำเร็จ: {e}")
    auth.forget_pin_cache()
    return {"status": "success", "data": res,
            "message": f"กู้คืนข้อมูลวันที่ {res.get('created_at')} แล้ว ครูเข้าสู่ระบบด้วยรหัสครูแล้วตั้ง PIN ใหม่"}


class OffsiteConfigRequest(BaseModel):
    remote: str = ""


@app.get("/api/v1/backups/offsite")
def offsite_status_api():
    import archive_backup
    return {"status": "success", "data": archive_backup.offsite_status()}


@app.post("/api/v1/backups/offsite")
def offsite_config_api(payload: OffsiteConfigRequest):
    """ตั้งชื่อที่เก็บของ rclone เช่น gdrive:SchoolBackup (ว่าง = ปิดการส่งขึ้น Drive)"""
    import archive_backup, re as _re
    remote = (payload.remote or "").strip()
    if remote and not _re.fullmatch(r"[A-Za-z0-9_\-]+:[^\s;&|`$<>]*", remote):
        raise HTTPException(status_code=400, detail="รูปแบบต้องเป็น ชื่อremote:โฟลเดอร์ เช่น gdrive:SchoolBackup")
    archive_backup.set_setting("offsite_remote", remote)
    return {"status": "success", "data": archive_backup.offsite_status()}


@app.post("/api/v1/backups/offsite/run")
def offsite_run_api():
    """ส่งไฟล์สำรองทั้งหมดขึ้น Drive ตอนนี้ (ทดสอบการตั้งค่า)"""
    import archive_backup
    res = archive_backup.offsite_sync()
    return {"status": "success", "data": res, "offsite": archive_backup.offsite_status()}


@app.get("/api/v1/backups/archives")
def list_archives_api():
    """ไฟล์สำรองทั้งระบบ (.zip) ทั้งหมด ใหม่สุดก่อน"""
    import archive_backup
    return {"status": "success", "data": archive_backup.list_archives()}


@app.post("/api/v1/backups/archives/create")
def create_archive_api(payload: ArchiveCreateRequest):
    import archive_backup
    try:
        return {"status": "success", "data": archive_backup.create_archive(payload.include_outputs, payload.label or "")}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"สร้างไฟล์สำรองไม่สำเร็จ: {e}")


@app.get("/api/v1/backups/archives/{name}/download")
def download_archive_api(name: str):
    import archive_backup
    try:
        p = archive_backup.archive_path(name)
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))
    return FileResponse(str(p), media_type="application/zip", filename=p.name)


@app.post("/api/v1/backups/archives/upload")
def upload_archive_api(file: UploadFile = File(...)):
    """รับไฟล์ .zip จากเครื่องอื่นเข้ารายการ (ยังไม่กู้คืน จนกว่าจะกดกู้คืน)"""
    import archive_backup, zipfile
    name = os.path.basename(file.filename or "")
    if not name.endswith(".zip"):
        raise HTTPException(status_code=400, detail="ต้องเป็นไฟล์ .zip ที่ได้จากปุ่มสำรองทั้งระบบ")
    archive_backup.ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
    if not name.startswith("school_backup_"):
        name = "school_backup_" + datetime.now().strftime("%Y%m%d_%H%M%S") + "_manual_uploaded.zip"
    dest = archive_backup.ARCHIVE_DIR / name
    with open(dest, "wb") as f:
        shutil.copyfileobj(file.file, f)
    try:
        with zipfile.ZipFile(dest) as z:
            ok = "school_archive.db" in z.namelist()
    except zipfile.BadZipFile:
        ok = False
    if not ok:
        dest.unlink()
        raise HTTPException(status_code=400, detail="ไฟล์นี้ไม่ใช่ไฟล์สำรองทั้งระบบ (ไม่มี school_archive.db)")
    return {"status": "success", "data": archive_backup._info(dest)}


@app.post("/api/v1/backups/archives/{name}/restore")
def restore_archive_api(name: str):
    """กู้คืนทั้งระบบ: สำรองฐานข้อมูลปัจจุบันก่อน, PIN ของครูในเครื่องนี้คงเดิม"""
    import archive_backup
    try:
        res = archive_backup.restore_archive(str(archive_backup.archive_path(name)))
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    auth.forget_pin_cache()
    return {"status": "success", "data": res,
            "message": f"กู้คืนจากไฟล์สำรองวันที่ {res.get('created_at')} แล้ว (สำรองข้อมูลก่อนกู้คืนไว้ให้: {res.get('safety_backup_id')})"}


@app.get("/api/v1/backups")
def get_backups_api():
    """List all available backups in the system."""
    try:
        import backup_manager
        data = backup_manager.list_backups()
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/backups/create")
def create_backup_api(payload: BackupCreateRequest):
    """Create a new backup snapshot."""
    try:
        import backup_manager
        b = backup_manager.create_backup(
            label=payload.label,
            term=payload.term,
            year=payload.year,
            backup_type=payload.backup_type or "full"
        )
        return {"status": "success", "data": b}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/backups/restore")
def restore_backup_api(payload: BackupRestoreRequest):
    """Restore from a backup (either full DB restore or semester-specific import)."""
    try:
        import backup_manager
        database.invalidate_init_cache()  # the restored file may predate the current schema
        res = backup_manager.restore_backup(
            backup_id=payload.backup_id,
            mode=payload.mode or "full",
            target_term=payload.target_term,
            target_year=payload.target_year,
            src_term=payload.src_term,
            src_year=payload.src_year
        )
        database.invalidate_init_cache()
        return {"status": "success", "data": res}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/api/v1/backups/{backup_id}")
def delete_backup_api(backup_id: str):
    """Delete a backup file."""
    try:
        import backup_manager
        ok = backup_manager.delete_backup(backup_id)
        if ok:
            return {"status": "success", "message": "ลบไฟล์สำรองข้อมูลเรียบร้อยแล้ว"}
        else:
            raise HTTPException(status_code=404, detail="ไม่พบไฟล์สำรองข้อมูลนี้")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/backups/{backup_id}/download")
def download_backup_api(backup_id: str):
    """Download a backup .db file."""
    try:
        from fastapi.responses import FileResponse
        import backup_manager
        backup_file = backup_manager.BACKUPS_DIR / f"{backup_id}.db"
        if not backup_file.exists():
            matches = list(backup_manager.BACKUPS_DIR.glob(f"*{backup_id}*.db"))
            if matches:
                backup_file = matches[0]
            else:
                raise HTTPException(status_code=404, detail="ไม่พบไฟล์สำรองข้อมูล")
        return FileResponse(
            path=str(backup_file),
            filename=backup_file.name,
            media_type="application/octet-stream"
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# -------------------------------------------------------------
# School Signatories Configuration Endpoints (ผู้ลงนามหน้าปก ปพ.5)
# -------------------------------------------------------------
@app.get("/api/v1/settings/signatories")
def get_school_signatories_api(year: Optional[str] = Query(None)):
    """Retrieve school signatories configuration for an academic year."""
    try:
        data = get_school_signatories(year=year, db_path="school_archive.db")
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/settings/signatories/all")
def get_all_school_signatories_api():
    """Retrieve all configured school signatories across years."""
    try:
        data = get_all_school_signatories(db_path="school_archive.db")
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/settings/signatories")
def save_school_signatories_api(payload: UpdateSignatoriesRequest):
    """Save or update school signatories for a specific academic year."""
    try:
        if payload.school_name:
            set_app_setting("school_name", payload.school_name.strip(), db_path="school_archive.db")
        data = upsert_school_signatories(payload.dict(), db_path="school_archive.db")
        synced_count = 0
        if payload.sync_existing_files:
            synced_count = sync_signatories_to_existing_excels(
                year=payload.year,
                outputs_dir=str(OUTPUT_DIR),
                db_path="school_archive.db"
            )
        return {
            "status": "success",
            "message": f"บันทึกข้อมูลผู้ลงนามปีการศึกษา {payload.year} เรียบร้อยแล้ว (อัปเดตไฟล์ {synced_count} ไฟล์)",
            "data": data,
            "synced_files": synced_count
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/settings/signatories/copy")
def copy_school_signatories_api(payload: CopySignatoriesRequest):
    """Copy school signatories from one year to another."""
    try:
        data = copy_school_signatories(
            from_year=payload.from_year.strip(),
            to_year=payload.to_year.strip(),
            db_path="school_archive.db"
        )
        synced_count = 0
        if payload.sync_existing_files:
            synced_count = sync_signatories_to_existing_excels(
                year=payload.to_year,
                outputs_dir=str(OUTPUT_DIR),
                db_path="school_archive.db"
            )
        return {
            "status": "success",
            "message": f"คัดลอกข้อมูลผู้ลงนามจากปี {payload.from_year} ไปยังปี {payload.to_year} เรียบร้อยแล้ว (อัปเดตไฟล์ {synced_count} ไฟล์)",
            "data": data,
            "synced_files": synced_count
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# -------------------------------------------------------------
# School Logo & Identity Endpoints
# -------------------------------------------------------------
class SchoolInfoRequest(BaseModel):
    school_name: str
    sidebar_footer_title: Optional[str] = None
    sidebar_footer_subtitle: Optional[str] = None


class WebTitleRequest(BaseModel):
    web_title: str


def _get_web_title() -> str:
    """Browser tab title (ชื่อหน้าเว็บ). Falls back to 'SGS ปพ.5 Manager - <ชื่อโรงเรียน>'."""
    saved = (get_app_setting("web_title", "", db_path="school_archive.db") or "").strip()
    if saved:
        return saved
    full_name = get_app_setting("full_school_name", "", db_path="school_archive.db") or school_profile.full_name() or "ระบบ ปพ.5"
    return f"SGS ปพ.5 Manager - {full_name}"


@app.post("/api/v1/settings/web-title")
def update_web_title_api(payload: WebTitleRequest):
    """Save the browser tab title (ชื่อหน้าเว็บ). Empty string resets to the default."""
    title = (payload.web_title or "").strip()
    if len(title) > 120:
        raise HTTPException(status_code=400, detail="ชื่อหน้าเว็บยาวเกินไป (ไม่เกิน 120 ตัวอักษร)")
    set_app_setting("web_title", title, db_path="school_archive.db")
    return {
        "status": "success",
        "message": "บันทึกชื่อหน้าเว็บเรียบร้อยแล้ว",
        "web_title": _get_web_title(),
    }


class SchoolThemeRequest(BaseModel):
    menu_color: Optional[str] = "#24114F"
    body_color: Optional[str] = "#F7ECC2"
    primary_color: Optional[str] = "#351C75"
    secondary_color: Optional[str] = "#D4AF37"
    font_family: Optional[str] = "Sarabun"


def _get_school_theme() -> Dict[str, str]:
    """Retrieve saved school theme configuration or return defaults."""
    menu_color = get_app_setting("theme_menu_color", "#24114F", db_path="school_archive.db") or "#24114F"
    body_color = get_app_setting("theme_body_color", "#F7ECC2", db_path="school_archive.db") or "#F7ECC2"
    primary_color = get_app_setting("theme_primary_color", "#351C75", db_path="school_archive.db") or "#351C75"
    secondary_color = get_app_setting("theme_secondary_color", "#D4AF37", db_path="school_archive.db") or "#D4AF37"
    font_family = get_app_setting("theme_font_family", "Sarabun", db_path="school_archive.db") or "Sarabun"
    return {
        "menu_color": menu_color,
        "body_color": body_color,
        "primary_color": primary_color,
        "secondary_color": secondary_color,
        "font_family": font_family,
    }


@app.get("/api/v1/settings/school-theme")
def get_school_theme_api():
    """Get active school theme colors and typography."""
    return {
        "status": "success",
        "theme": _get_school_theme(),
    }


@app.post("/api/v1/settings/school-theme")
def update_school_theme_api(payload: SchoolThemeRequest):
    """Save custom school theme colors and typography."""
    m_color = (payload.menu_color or "#24114F").strip()
    b_color = (payload.body_color or "#F7ECC2").strip()
    p_color = (payload.primary_color or "#351C75").strip()
    s_color = (payload.secondary_color or "#D4AF37").strip()
    f_family = (payload.font_family or "Sarabun").strip()

    valid_fonts = ["Sarabun", "Prompt", "Kanit", "Mitr", "Chakra Petch", "Noto Sans Thai"]
    if f_family not in valid_fonts:
        f_family = "Sarabun"

    set_app_setting("theme_menu_color", m_color, db_path="school_archive.db")
    set_app_setting("theme_body_color", b_color, db_path="school_archive.db")
    set_app_setting("theme_primary_color", p_color, db_path="school_archive.db")
    set_app_setting("theme_secondary_color", s_color, db_path="school_archive.db")
    set_app_setting("theme_font_family", f_family, db_path="school_archive.db")

    return {
        "status": "success",
        "message": "บันทึกการปรับแต่งสีประจำโรงเรียนและฟอนต์เรียบร้อยแล้ว",
        "theme": _get_school_theme(),
    }


@app.post("/api/v1/settings/school-theme/reset")
def reset_school_theme_api():
    """Reset school theme back to default Royal Purple & Gold."""
    set_app_setting("theme_menu_color", "#24114F", db_path="school_archive.db")
    set_app_setting("theme_body_color", "#F7ECC2", db_path="school_archive.db")
    set_app_setting("theme_primary_color", "#351C75", db_path="school_archive.db")
    set_app_setting("theme_secondary_color", "#D4AF37", db_path="school_archive.db")
    set_app_setting("theme_font_family", "Sarabun", db_path="school_archive.db")
    return {
        "status": "success",
        "message": "รีเซ็ตธีมกลับสู่ค่าเริ่มต้นเรียบร้อยแล้ว",
        "theme": _get_school_theme(),
    }


WEB_LOGO_MAX_PX = 256  # the biggest logo on a page is 80 px wide (settings): 256 px stays sharp on a 3x phone screen
_web_logo_cache: Dict[str, Any] = {}


def _school_logo_file() -> Optional[Path]:
    logo_path = get_app_setting("school_logo_path", "", db_path="school_archive.db")
    p = Path(logo_path) if logo_path else None
    return p if p and p.exists() else None


def _school_logo_version(p: Path) -> str:
    """Follows the file itself, so it changes with every upload, restore or script that replaces the logo."""
    return str(p.stat().st_mtime_ns // 1_000_000)


def _school_logo_url(p: Optional[Path] = None) -> Optional[str]:
    """The one URL of the school logo for every page (tab icon, sidebar, login, settings, ปพ.5 viewer): the browser
    downloads it once and keeps it, and gets a new URL the moment the file changes."""
    p = p or _school_logo_file()
    return f"/api/v1/settings/school-logo?v={_school_logo_version(p)}" if p else None


def _web_logo_png(p: Path) -> Optional[tuple]:
    """(PNG bytes, ETag) of the logo shrunk to WEB_LOGO_MAX_PX for the web pages: ~60 KB instead of the ~700 KB
    upload. The uploaded file stays as it is for the ปพ.5 and PDFs. None when it is small already or not a picture
    Pillow can open (the file is then sent as it is)."""
    st = p.stat()
    key = (str(p.resolve()), st.st_mtime_ns, st.st_size)
    if _web_logo_cache.get("key") == key:
        return _web_logo_cache["png"]
    png = None
    try:
        with Image.open(p) as im:
            if max(im.size) > WEB_LOGO_MAX_PX:
                small = im.convert("RGBA")
                small.thumbnail((WEB_LOGO_MAX_PX, WEB_LOGO_MAX_PX), Image.Resampling.LANCZOS)
                buf = io.BytesIO()
                small.save(buf, format="PNG", optimize=True)
                png = (buf.getvalue(), f'"logo-{st.st_mtime_ns:x}-{st.st_size:x}-{WEB_LOGO_MAX_PX}"')
    except Exception:
        png = None
    _web_logo_cache.update(key=key, png=png)
    return png


@app.get("/api/v1/settings/school-logo/info")
def get_school_logo_info_api():
    logo_file = _school_logo_file()
    has_logo = logo_file is not None
    ts = get_app_setting("school_logo_updated", "0", db_path="school_archive.db")
    school_name = get_app_setting("school_name", "", db_path="school_archive.db")
    if not school_name:
        sigs = get_school_signatories(db_path="school_archive.db")
        school_name = sigs.get("school_name") or school_profile.short_name()
    raw_name = re.sub(r"^โรงเรียน\s*", "", school_name).strip() or school_profile.short_name()
    full_name = f"โรงเรียน{raw_name}"
    sidebar_footer_title = get_app_setting(
        "sidebar_footer_title",
        "ระบบงาน ปพ.5 & ทะเบียนวัดผล",
        db_path="school_archive.db",
    ) or "ระบบงาน ปพ.5 & ทะเบียนวัดผล"
    sidebar_footer_subtitle = get_app_setting(
        "sidebar_footer_subtitle",
        "",
        db_path="school_archive.db",
    ) or full_name
    return {
        "status": "success",
        "has_logo": has_logo,
        "updated_at": ts,
        "school_name": raw_name,
        "full_school_name": full_name,
        "sidebar_footer_title": sidebar_footer_title,
        "sidebar_footer_subtitle": sidebar_footer_subtitle,
        "web_title": _get_web_title(),
        "logo_url": _school_logo_url(logo_file),
    }


@app.post("/api/v1/settings/school-info")
def update_school_info_api(payload: SchoolInfoRequest):
    name = payload.school_name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="กรุณาระบุชื่อสถานศึกษา")
    raw_name = re.sub(r"^โรงเรียน\s*", "", name).strip() or name
    full_name = f"โรงเรียน{raw_name}"
    set_app_setting("school_name", raw_name, db_path="school_archive.db")
    set_app_setting("full_school_name", full_name, db_path="school_archive.db")

    if payload.sidebar_footer_title is not None:
        ft = payload.sidebar_footer_title.strip() or "ระบบงาน ปพ.5 & ทะเบียนวัดผล"
        set_app_setting("sidebar_footer_title", ft, db_path="school_archive.db")
    else:
        ft = get_app_setting("sidebar_footer_title", "ระบบงาน ปพ.5 & ทะเบียนวัดผล", db_path="school_archive.db") or "ระบบงาน ปพ.5 & ทะเบียนวัดผล"

    if payload.sidebar_footer_subtitle is not None:
        fs = payload.sidebar_footer_subtitle.strip() or full_name
        set_app_setting("sidebar_footer_subtitle", fs, db_path="school_archive.db")
    else:
        fs = get_app_setting("sidebar_footer_subtitle", "", db_path="school_archive.db") or full_name

    try:
        with get_connection("school_archive.db") as conn:
            cursor = conn.cursor()
            cursor.execute("UPDATE school_signatories SET school_name = ?;", (raw_name,))
            conn.commit()
    except Exception:
        pass
    return {
        "status": "success",
        "message": "บันทึกข้อมูลชื่อสถานศึกษาและข้อความแถบเมนูเรียบร้อยแล้ว",
        "school_name": raw_name,
        "full_school_name": full_name,
        "sidebar_footer_title": ft,
        "sidebar_footer_subtitle": fs,
    }


@app.get("/api/v1/settings/school-logo")
def get_school_logo_api(request: Request, v: Optional[str] = None):
    p = _school_logo_file()
    if not p:
        raise HTTPException(status_code=404, detail="No school logo found")
    # ?v= = the file's version: that URL always means this very picture, so the browser may keep it for good;
    # any other URL is checked with the server on every use (ETag -> 304, no download)
    cache = "public, max-age=31536000, immutable" if v and v == _school_logo_version(p) else "no-cache"
    small = _web_logo_png(p) if p.suffix.lower() != ".svg" else None
    if small:
        body, etag = small
        if etag in request.headers.get("if-none-match", ""):
            return Response(status_code=304, headers={"ETag": etag, "Cache-Control": cache})
        return Response(content=body, media_type="image/png", headers={"ETag": etag, "Cache-Control": cache})
    suffix = p.suffix.lower()
    media_types = {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
        ".svg": "image/svg+xml",
        ".gif": "image/gif",
    }
    media_type = media_types.get(suffix, "image/png")
    return FileResponse(p, media_type=media_type, headers={"Cache-Control": cache})


def remove_fake_transparency_or_solid_bg(img: Image.Image) -> Image.Image:
    """
    Detect and remove fake checkerboard transparency pattern or solid light background
    from borders, turning it into true alpha transparency.
    """
    import numpy as np
    from collections import deque
    
    im = img.convert("RGBA")
    arr = np.array(im)
    h, w = arr.shape[:2]
    
    alpha = arr[:, :, 3]
    # If image already has substantial true transparent pixels, keep it as is
    if (alpha < 128).sum() > 0.05 * (h * w):
        return im

    r = arr[:, :, 0].astype(int)
    g = arr[:, :, 1].astype(int)
    b = arr[:, :, 2].astype(int)

    border_mask = np.zeros((h, w), dtype=bool)
    border_mask[0, :] = True
    border_mask[-1, :] = True
    border_mask[:, 0] = True
    border_mask[:, -1] = True

    border_r = r[border_mask]
    border_g = g[border_mask]
    border_b = b[border_mask]

    is_border_gray = (np.abs(border_r - border_g) <= 15) & (np.abs(border_g - border_b) <= 15) & (border_r > 150)

    # If >70% of border pixels are bright grayscale (checkerboard or white/light-gray)
    if is_border_gray.mean() > 0.7:
        is_bg = (np.abs(r - g) <= 15) & (np.abs(g - b) <= 15) & (np.abs(r - b) <= 15) & (r > 150)
        
        visited = np.zeros((h, w), dtype=bool)
        q = deque()
        for x in range(w):
            if is_bg[0, x]: visited[0, x] = True; q.append((0, x))
            if is_bg[h-1, x]: visited[h-1, x] = True; q.append((h-1, x))
        for y in range(h):
            if is_bg[y, 0] and not visited[y, 0]: visited[y, 0] = True; q.append((y, 0))
            if is_bg[y, w-1] and not visited[y, w-1]: visited[y, w-1] = True; q.append((y, w-1))

        while q:
            cy, cx = q.popleft()
            for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                ny, nx = cy + dy, cx + dx
                if 0 <= ny < h and 0 <= nx < w and not visited[ny, nx]:
                    if is_bg[ny, nx]:
                        visited[ny, nx] = True
                        q.append((ny, nx))

        arr[visited, 3] = 0
        return Image.fromarray(arr, "RGBA")

    return im


@app.post("/api/v1/settings/school-logo")
async def upload_school_logo_api(file: UploadFile = File(...)):
    if not file.filename:
        raise HTTPException(status_code=400, detail="กรุณาเลือกไฟล์รูปภาพโลโก้")
    ext = Path(file.filename).suffix.lower()
    allowed_exts = [".png", ".jpg", ".jpeg", ".webp", ".svg", ".gif", ".bmp", ".tiff"]
    if ext not in allowed_exts:
        raise HTTPException(status_code=400, detail="รองรับเฉพาะไฟล์รูปภาพ (.png, .jpg, .jpeg, .webp, .svg, .gif, .bmp)")
    
    upload_dir = Path("uploads")
    upload_dir.mkdir(parents=True, exist_ok=True)
    
    content = await file.read()
    if len(content) == 0:
        raise HTTPException(status_code=400, detail="ไฟล์รูปภาพว่างเปล่า (0 bytes)")
    if len(content) > 50 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="ขนาดไฟล์ใหญ่เกินไป (กรุณาใช้ไฟล์ไม่เกิน 50MB)")

    # Clean up any existing school_logo.* files first to avoid conflicting extensions
    for old_file in upload_dir.glob("school_logo.*"):
        try:
            old_file.unlink()
        except Exception:
            pass

    target_path = None
    if ext == ".svg":
        target_path = upload_dir / "school_logo.svg"
        with open(target_path, "wb") as f:
            f.write(content)
    else:
        # Raster image: Auto resize & optimize with Pillow
        Image.MAX_IMAGE_PIXELS = 200_000_000
        try:
            img = Image.open(io.BytesIO(content))
            img = ImageOps.exif_transpose(img)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"ไม่สามารถประมวลผลไฟล์รูปภาพได้: {e}")
        
        # Remove fake checkerboard or light solid background automatically
        img = remove_fake_transparency_or_solid_bg(img)
        
        # Format emblem with true proportions padded symmetrically to Excel aspect ratio (1.452)
        from excel_mapper import format_logo_for_excel_and_web
        img = format_logo_for_excel_and_web(img)
        
        # Save as optimized PNG with true alpha transparency
        target_path = upload_dir / "school_logo.png"
        img.save(target_path, format="PNG", optimize=True)

        # Also sync directly to favicon files for web browser tabs
        try:
            for web_base in [Path("frontend/build/web"), Path("frontend/web")]:
                if web_base.exists():
                    fav_64 = img.resize((64, 64), Image.Resampling.LANCZOS)
                    fav_64.save(web_base / "favicon.png", format="PNG")
                    img.save(web_base / "favicon.ico", format="ICO", sizes=[(16, 16), (32, 32), (48, 48), (64, 64)])
                    icons_dir = web_base / "icons"
                    if icons_dir.exists():
                        for sz in [192, 512]:
                            pwa = img.resize((sz, sz), Image.Resampling.LANCZOS)
                            pwa.save(icons_dir / f"Icon-{sz}.png", format="PNG")
                            pwa.save(icons_dir / f"Icon-maskable-{sz}.png", format="PNG")
        except Exception as e:
            print("Error syncing favicon from uploaded logo:", e)

    ts = str(int(time.time()))
    set_app_setting("school_logo_path", str(target_path), db_path="school_archive.db")
    set_app_setting("school_logo_updated", ts, db_path="school_archive.db")
    try:
        custom_pp5 = get_app_setting("pp5_logo_path", "", db_path="school_archive.db")
        if not custom_pp5:
            sync_all_excel_logos(db_path="school_archive.db", custom_logo_path=str(target_path), run_async=True)
    except Exception as _sync_err:
        print("Error syncing school logo to Excel:", _sync_err)
    return {
        "status": "success",
        "message": "อัปโหลด ปรับขนาด และทำพื้นหลังโปร่งใสเรียบร้อยแล้ว",
        "logo_url": _school_logo_url(target_path),
    }


@app.delete("/api/v1/settings/school-logo")
def delete_school_logo_api():
    upload_dir = Path("uploads")
    for old_file in upload_dir.glob("school_logo.*"):
        try:
            old_file.unlink()
        except Exception:
            pass
    set_app_setting("school_logo_path", "", db_path="school_archive.db")
    set_app_setting("school_logo_updated", str(int(time.time())), db_path="school_archive.db")
    try:
        custom_pp5 = get_app_setting("pp5_logo_path", "", db_path="school_archive.db")
        if not custom_pp5:
            sync_all_excel_logos(db_path="school_archive.db", run_async=True)
    except Exception as _sync_err:
        print("Error syncing cleared logo to Excel:", _sync_err)
    return {"status": "success", "message": "ลบโลโก้โรงเรียนเรียบร้อยแล้ว"}


@app.get("/api/v1/settings/pp5-logo/info")
def get_pp5_logo_info_api():
    """Returns PP5 logo status, whether custom or defaulting to school logo, and active image URLs."""
    custom_logo_path = get_app_setting("pp5_logo_path", "", db_path="school_archive.db")
    has_custom_pp5_logo = bool(custom_logo_path and Path(custom_logo_path).exists())
    pp5_ts = get_app_setting("pp5_logo_updated", "0", db_path="school_archive.db")
    
    school_logo_path = get_app_setting("school_logo_path", "", db_path="school_archive.db")
    has_school_logo = bool(school_logo_path and Path(school_logo_path).exists())
    school_ts = get_app_setting("school_logo_updated", "0", db_path="school_archive.db")
    
    effective_path = get_effective_pp5_logo_path(db_path="school_archive.db")
    has_effective_logo = bool(effective_path and Path(effective_path).exists())
    active_source = "custom" if has_custom_pp5_logo else "school_default"
    
    return {
        "status": "success",
        "has_custom_pp5_logo": has_custom_pp5_logo,
        "has_school_logo": has_school_logo,
        "has_effective_logo": has_effective_logo,
        "active_logo_source": active_source,
        "effective_logo_url": f"/api/v1/settings/pp5-logo?v={pp5_ts if has_custom_pp5_logo else school_ts}" if has_effective_logo else None,
        "custom_pp5_logo_url": f"/api/v1/settings/pp5-logo/custom?v={pp5_ts}" if has_custom_pp5_logo else None,
        "school_logo_url": _school_logo_url() if has_school_logo else None,
        "effective_path": effective_path,
        "updated_at": pp5_ts if has_custom_pp5_logo else school_ts,
    }


@app.get("/api/v1/settings/pp5-logo")
def get_pp5_logo_api():
    """Serves the effective logo used for ปพ.5 (custom PP5 logo if set, else school logo)."""
    effective_path = get_effective_pp5_logo_path(db_path="school_archive.db")
    if not effective_path or not Path(effective_path).exists():
        raise HTTPException(status_code=404, detail="No PP5 or school logo found")
    p = Path(effective_path)
    suffix = p.suffix.lower()
    media_types = {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
        ".svg": "image/svg+xml",
        ".gif": "image/gif",
    }
    media_type = media_types.get(suffix, "image/png")
    return FileResponse(p, media_type=media_type)


@app.get("/api/v1/settings/pp5-logo/custom")
def get_custom_pp5_logo_api():
    """Serves the custom PP5 logo specifically (404 if not set)."""
    custom_path = get_app_setting("pp5_logo_path", "", db_path="school_archive.db")
    if not custom_path or not Path(custom_path).exists():
        raise HTTPException(status_code=404, detail="No custom PP5 logo uploaded")
    p = Path(custom_path)
    suffix = p.suffix.lower()
    media_types = {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
        ".svg": "image/svg+xml",
    }
    media_type = media_types.get(suffix, "image/png")
    return FileResponse(p, media_type=media_type)


@app.post("/api/v1/settings/pp5-logo")
async def upload_pp5_logo_api(file: UploadFile = File(...)):
    """Uploads and optimizes a custom logo for ปพ.5 documents and updates templates."""
    if not file.filename:
        raise HTTPException(status_code=400, detail="กรุณาเลือกไฟล์รูปภาพตรา ปพ.5")
    ext = Path(file.filename).suffix.lower()
    allowed_exts = [".png", ".jpg", ".jpeg", ".webp", ".svg", ".gif", ".bmp", ".tiff"]
    if ext not in allowed_exts:
        raise HTTPException(status_code=400, detail="รองรับเฉพาะไฟล์รูปภาพ (.png, .jpg, .jpeg, .webp, .svg, .gif, .bmp)")

    upload_dir = Path("uploads")
    upload_dir.mkdir(parents=True, exist_ok=True)

    content = await file.read()
    if len(content) == 0:
        raise HTTPException(status_code=400, detail="ไฟล์รูปภาพว่างเปล่า (0 bytes)")
    if len(content) > 50 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="ขนาดไฟล์ใหญ่เกินไป (กรุณาใช้ไฟล์ไม่เกิน 50MB)")

    for old_file in upload_dir.glob("pp5_logo.*"):
        try:
            old_file.unlink()
        except Exception:
            pass

    target_path = None
    if ext == ".svg":
        target_path = upload_dir / "pp5_logo.svg"
        with open(target_path, "wb") as f:
            f.write(content)
    else:
        Image.MAX_IMAGE_PIXELS = 200_000_000
        try:
            img = Image.open(io.BytesIO(content))
            img = ImageOps.exif_transpose(img)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"ไม่สามารถประมวลผลไฟล์รูปภาพได้: {e}")

        img = remove_fake_transparency_or_solid_bg(img)

        from excel_mapper import format_logo_for_excel_and_web
        img = format_logo_for_excel_and_web(img)

        target_path = upload_dir / "pp5_logo.png"
        img.save(target_path, format="PNG", optimize=True)

    ts = str(int(time.time()))
    set_app_setting("pp5_logo_path", str(target_path), db_path="school_archive.db")
    set_app_setting("pp5_logo_updated", ts, db_path="school_archive.db")

    sync_res = sync_all_excel_logos(db_path="school_archive.db", custom_logo_path=str(target_path), run_async=True)

    return {
        "status": "success",
        "message": "อัปโหลดตรา ปพ.5 และอัปเดตแบบฟอร์มเอกสารเรียบร้อยแล้ว",
        "logo_url": f"/api/v1/settings/pp5-logo?v={ts}",
        "sync_result": sync_res,
    }


@app.delete("/api/v1/settings/pp5-logo")
def delete_pp5_logo_api():
    """Resets the PP5 logo to use the default School Logo."""
    upload_dir = Path("uploads")
    for old_file in upload_dir.glob("pp5_logo.*"):
        try:
            old_file.unlink()
        except Exception:
            pass
    set_app_setting("pp5_logo_path", "", db_path="school_archive.db")
    ts = str(int(time.time()))
    set_app_setting("pp5_logo_updated", ts, db_path="school_archive.db")

    sync_res = sync_all_excel_logos(db_path="school_archive.db", run_async=True)

    return {
        "status": "success",
        "message": "คืนค่าเริ่มต้นเรียบร้อยแล้ว (จะใช้ตราโรงเรียนสำหรับเล่ม ปพ.5 โดยอัตโนมัติ)",
        "sync_result": sync_res,
    }



# -------------------------------------------------------------
# Class Advisors (ครูที่ปรึกษา / ครูประจำชั้น) Endpoints
# -------------------------------------------------------------
@app.get("/api/v1/advisors")
def list_advisors_api(
    term: Optional[str] = Query(None, description="Semester (e.g., '1' or '2')"),
    year: Optional[str] = Query(None, description="Academic year (e.g., '2568')")
):
    """Retrieve all class advisors, optionally filtered by term and year."""
    try:
        data = get_class_advisors(term=term, year=year, db_path="school_archive.db")
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/advisors")
def save_advisor_api(payload: ClassAdvisorRequest):
    """Create or update class advisors for a class level in a semester."""
    try:
        row_id = upsert_class_advisor(
            term=payload.term.strip(),
            year=payload.year.strip(),
            class_level=payload.class_level.strip(),
            advisor1=(payload.advisor1 or "").strip(),
            advisor2=(payload.advisor2 or "").strip(),
            advisor3=(payload.advisor3 or "").strip(),
            db_path="school_archive.db"
        )
        return {
            "status": "success",
            "id": row_id,
            "message": f"บันทึกข้อมูลครูที่ปรึกษา {payload.class_level} เรียบร้อยแล้ว"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/api/v1/advisors/{advisor_id}")
def delete_advisor_api(advisor_id: int):
    """Delete a class advisor record."""
    try:
        ok = delete_class_advisor(advisor_id, db_path="school_archive.db")
        if not ok:
            raise HTTPException(status_code=404, detail="Advisor not found")
        return {"status": "success", "message": "ลบข้อมูลครูที่ปรึกษาเรียบร้อยแล้ว"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/advisors/copy")
def copy_advisors_api(payload: CopyAdvisorsRequest):
    """Copy all class advisors from another semester into the target semester."""
    try:
        copied = copy_class_advisors_from_semester(
            from_term=payload.from_term.strip(),
            from_year=payload.from_year.strip(),
            to_term=payload.to_term.strip(),
            to_year=payload.to_year.strip(),
            db_path="school_archive.db"
        )
        return {
            "status": "success",
            "copied_count": copied,
            "message": f"คัดลอกรายชื่อครูที่ปรึกษาจากเทอม {payload.from_term}/{payload.from_year} สำเร็จ {copied} ระดับชั้น"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/advisors/template")
def download_advisors_template():
    """Download an Excel template for bulk class advisors upload."""
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    import io

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "รายชื่อครูที่ปรึกษา"

    headers = ["ระดับชั้น", "ครูที่ปรึกษาคนที่ 1", "ครูที่ปรึกษาคนที่ 2", "ครูที่ปรึกษาคนที่ 3"]
    ws.append(headers)

    sample_rows = [list(r) for r in school_profile.default_advisors()] or [
        [f"ม.{i}", "", "", ""] for i in range(1, 7)
    ]
    for row in sample_rows:
        ws.append(row)

    header_font = Font(name="TH SarabunPSK", size=16, bold=True, color="FFFFFF")
    header_fill = PatternFill(start_color="1B5E20", end_color="1B5E20", fill_type="solid")
    thin = Side(border_style="thin", color="D0D0D0")
    border = Border(top=thin, left=thin, right=thin, bottom=thin)

    for col_idx in range(1, 5):
        c = ws.cell(1, col_idx)
        c.font = header_font
        c.fill = header_fill
        c.alignment = Alignment(horizontal="center", vertical="center")

    for r_idx in range(2, len(sample_rows) + 2):
        for c_idx in range(1, 5):
            cell = ws.cell(r_idx, c_idx)
            cell.font = Font(name="TH SarabunPSK", size=15)
            cell.border = border
            cell.alignment = Alignment(vertical="center", horizontal="center" if c_idx == 1 else "left")

    ws.column_dimensions["A"].width = 16
    ws.column_dimensions["B"].width = 30
    ws.column_dimensions["C"].width = 30
    ws.column_dimensions["D"].width = 30

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)

    return Response(
        content=buf.getvalue(),
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": 'attachment; filename="template_class_advisors.xlsx"'}
    )


@app.post("/api/v1/advisors/upload")
async def upload_advisors_file(
    file: UploadFile = File(...),
    term: str = Form(...),
    year: str = Form(...)
):
    """
    Upload an Excel (.xlsx) or CSV file with homeroom teachers / class advisors
    and bulk import them for the specified semester.
    """
    content = await file.read()
    filename = file.filename or ""
    ext = Path(filename).suffix.lower()

    items = []
    if ext in [".xlsx", ".xlsm", ".xls"]:
        import openpyxl, io
        wb = openpyxl.load_workbook(io.BytesIO(content), data_only=True)
        ws = wb.active
        rows = list(ws.iter_rows(values_only=True))
        if rows:
            header_row = [str(c or "").strip() for c in rows[0]]
            col_class = 0
            col_a1 = 1
            col_a2 = 2
            col_a3 = 3
            for idx, col_name in enumerate(header_row):
                if re.search(r"ชั้น|ระดับ|ห้อง|level|class", col_name, re.I):
                    col_class = idx
                elif re.search(r"(?:1|คนที่\s*1|หนึ่ง)", col_name) and re.search(r"ครู|ที่ปรึกษา|ประจำชั้น|ชื่อ", col_name):
                    col_a1 = idx
                elif re.search(r"(?:2|คนที่\s*2|สอง)", col_name) and re.search(r"ครู|ที่ปรึกษา|ประจำชั้น|ชื่อ", col_name):
                    col_a2 = idx
                elif re.search(r"(?:3|คนที่\s*3|สาม)", col_name) and re.search(r"ครู|ที่ปรึกษา|ประจำชั้น|ชื่อ", col_name):
                    col_a3 = idx

            for r in rows[1:]:
                if not any(r):
                    continue
                cl = str(r[col_class] if col_class < len(r) and r[col_class] is not None else "").strip()
                if not cl or cl.lower() in ["none", ""]:
                    continue
                a1 = str(r[col_a1] if col_a1 < len(r) and r[col_a1] is not None else "").strip()
                a2 = str(r[col_a2] if col_a2 < len(r) and r[col_a2] is not None else "").strip()
                a3 = str(r[col_a3] if col_a3 < len(r) and r[col_a3] is not None else "").strip()
                items.append({
                    "class_level": cl,
                    "advisor1": "" if a1.lower() == "none" else a1,
                    "advisor2": "" if a2.lower() == "none" else a2,
                    "advisor3": "" if a3.lower() == "none" else a3,
                })
    elif ext == ".csv":
        import io, csv
        decoded = content.decode("utf-8-sig", errors="replace")
        reader = list(csv.reader(io.StringIO(decoded)))
        if reader:
            header_row = [str(c or "").strip() for c in reader[0]]
            col_class = 0
            col_a1 = 1
            col_a2 = 2
            col_a3 = 3
            for idx, col_name in enumerate(header_row):
                if re.search(r"ชั้น|ระดับ|ห้อง|level|class", col_name, re.I):
                    col_class = idx
                elif re.search(r"(?:1|คนที่\s*1|หนึ่ง)", col_name) and re.search(r"ครู|ที่ปรึกษา|ประจำชั้น|ชื่อ", col_name):
                    col_a1 = idx
                elif re.search(r"(?:2|คนที่\s*2|สอง)", col_name) and re.search(r"ครู|ที่ปรึกษา|ประจำชั้น|ชื่อ", col_name):
                    col_a2 = idx
                elif re.search(r"(?:3|คนที่\s*3|สาม)", col_name) and re.search(r"ครู|ที่ปรึกษา|ประจำชั้น|ชื่อ", col_name):
                    col_a3 = idx

            for r in reader[1:]:
                if not any(r):
                    continue
                cl = str(r[col_class] if col_class < len(r) else "").strip()
                if not cl:
                    continue
                a1 = str(r[col_a1] if col_a1 < len(r) else "").strip()
                a2 = str(r[col_a2] if col_a2 < len(r) else "").strip()
                a3 = str(r[col_a3] if col_a3 < len(r) else "").strip()
                items.append({
                    "class_level": cl,
                    "advisor1": a1,
                    "advisor2": a2,
                    "advisor3": a3,
                })
    else:
        raise HTTPException(status_code=400, detail="รองรับเฉพาะไฟล์ Excel (.xlsx) หรือ CSV เท่านั้น")

    if not items:
        raise HTTPException(status_code=400, detail="ไม่พบข้อมูลระดับชั้นหรือรายชื่อครูในไฟล์ที่อัปโหลด")

    saved = bulk_upsert_class_advisors(term=term.strip(), year=year.strip(), items=items, db_path="school_archive.db")
    return {
        "status": "success",
        "saved_count": saved,
        "items": items,
        "message": f"นำเข้าข้อมูลครูที่ปรึกษาเรียบร้อยแล้ว {saved} ระดับชั้น"
    }


# ==============================================================================
# AUTHENTICATION & SYSTEM ADMIN MANAGEMENT ENDPOINTS
# ==============================================================================

class TeacherLoginRequest(BaseModel):
    code: str
    pin: Optional[str] = None


class TeacherPinUpdateRequest(BaseModel):
    pin: str


class AdminManageRequest(BaseModel):
    teacher_code: str


def _session_response(request: Request, body: Dict[str, Any], token: str) -> JSONResponse:
    resp = JSONResponse(content={**body, "token": token})
    secure = request.headers.get("x-forwarded-proto", request.url.scheme) == "https"
    resp.set_cookie(auth.COOKIE_NAME, token, max_age=auth.SESSION_SECONDS, httponly=True,
                    samesite="lax", secure=secure, path="/")
    return resp


@app.post("/api/v1/auth/login-teacher")
def login_teacher_api(payload: TeacherLoginRequest, request: Request):
    """Teacher code + PIN (always required). Returns a session cookie and token; never the PIN."""
    code = (payload.code or "").strip()
    pin = (payload.pin or "").strip()
    keys = (f"ip:{auth.client_ip(request)}", f"code:{code}")
    wait = max(auth.login_blocked_for(k) for k in keys)
    if wait:
        raise HTTPException(status_code=429, detail=f"ใส่รหัสผิดหลายครั้ง กรุณารอ {max(1, wait // 60)} นาทีแล้วลองใหม่")
    if not code or not pin:
        raise HTTPException(status_code=401, detail="กรุณาระบุรหัสประจำตัวครูและรหัสใช้งาน (PIN)")
    try:
        from database import login_teacher_with_code
        ok, user, msg = login_teacher_with_code(code, pin, "school_archive.db")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    if not ok or not user:
        auth.record_login_failure(*keys)
        raise HTTPException(status_code=401, detail=msg)
    auth.clear_login_failures(*keys)
    user = {k: v for k, v in user.items() if k != "login_pin"}
    user["role"] = auth.role_for(user)
    token = auth.issue_token(user, auth.current_pin(user["code"]))
    return _session_response(request, {
        "status": "success",
        "success": True,
        "teacher": user,
        "is_admin": user.get("is_admin", False),
        "is_director": user.get("is_director", False),
        "is_personnel_head": school_profile.is_personnel_head(user.get("code")) or user.get("is_personnel_head", False),
        "message": msg
    }, token)


@app.post("/api/v1/auth/guest")
def login_guest_api(request: Request):
    """บุคคลทั่วไป: a session that can only read the timetable."""
    token = auth.issue_token({"code": "GUEST", "name": "บุคคลทั่วไป", "role": "guest"}, None)
    return _session_response(request, {"status": "success", "teacher": {"code": "GUEST", "name": "บุคคลทั่วไป", "is_guest": True}}, token)


@app.get("/api/v1/auth/me")
def auth_me_api(request: Request):
    """Who the current session belongs to (used to restore the session when the app opens)."""
    u = current_user(request)
    role = u.get("role")
    return {
        "status": "success",
        "teacher": {"code": u.get("code"), "name": u.get("name"), "is_guest": role == "guest",
                    "is_student": role == "student"},
        "is_admin": role == "admin",
        "is_director": role == "director",
        "is_personnel_head": school_profile.is_personnel_head(u.get("code")) or u.get("is_personnel_head", False),
        "role": "personnel_head" if school_profile.is_personnel_head(u.get("code")) else role,
    }


class StudentLoginRequest(BaseModel):
    student_id: str
    password: str


@app.post("/api/v1/auth/login-student")
def login_student_api(payload: StudentLoginRequest, request: Request):
    """Student login: student ID (with the leading 0) as both username and password. Sees only own attendance."""
    sid = (payload.student_id or "").strip()
    keys = (f"ip:{auth.client_ip(request)}", f"student:{sid}")
    wait = max(auth.login_blocked_for(k) for k in keys)
    if wait:
        raise HTTPException(status_code=429, detail=f"ใส่รหัสผิดหลายครั้ง กรุณารอ {max(1, wait // 60)} นาทีแล้วลองใหม่")
    if not auth.check_student_password(sid, payload.password):
        auth.record_login_failure(*keys)
        raise HTTPException(status_code=401, detail="รหัสประจำตัวนักเรียนหรือรหัสผ่านไม่ถูกต้อง (ใส่ 0 นำหน้าด้วย เช่น 01234)")
    auth.clear_login_failures(*keys)
    st = auth.find_active_student(sid)
    token = auth.issue_token({"code": sid, "name": st["full_name"], "role": "student"}, sid)
    return _session_response(request, {
        "status": "success",
        "role": "student",
        "teacher": {"code": sid, "name": st["full_name"], "is_student": True,
                    "class_level": st["class_level"], "room": st["room"]},
    }, token)


# ================================================================ ข้อสอบกลางภาค / ปลายภาค (exams.py)

class ExamWindowRequest(BaseModel):
    term: str
    year: str
    exam_type: str
    start_at: Optional[str] = None
    end_at: Optional[str] = None


class SaveExamRequest(BaseModel):
    course_code: str
    term: str
    year: str
    exam_type: str
    mode: str = "quiz"
    title: Optional[str] = ""
    link_url: Optional[str] = ""
    duration_min: Optional[int] = None
    questions: Optional[List[Dict[str, Any]]] = None
    ready: bool = True
    block_ms: Optional[bool] = None


class ExamRefRequest(BaseModel):
    course_code: str
    term: str
    year: str
    exam_type: str
    student_id: Optional[str] = None


class ExamCourseTimeRequest(BaseModel):
    term: str
    year: str
    course_code: str
    exam_type: str
    start_at: Optional[str] = None
    end_at: Optional[str] = None


class ExamOpenEarlyRequest(BaseModel):
    term: str
    year: str
    course_codes: List[str]
    exam_type: str
    opened: bool


class ExamTimetableRequest(BaseModel):
    term: str
    year: str
    exam_type: str
    days: List[Dict[str, Any]] = []


class ExamPermitRequest(BaseModel):
    course_code: str
    term: str
    year: str
    student_id: str
    allowed: bool


class ExamBlockMsRequest(BaseModel):
    course_code: str
    term: str
    year: str
    exam_type: str
    block_ms: bool


class ExamLockRequest(BaseModel):
    term: str
    year: str
    course_codes: List[str]
    exam_types: List[str]
    locked: bool


class ParseExamTextRequest(BaseModel):
    text: str


class ExamMarkRequest(BaseModel):
    course_code: str
    term: str
    year: str
    exam_type: str
    student_id: str
    marks: Dict[str, Any] = {}


class ExamPhotoDeleteRequest(BaseModel):
    question: int
    name: str


class ExamAnswersRequest(BaseModel):
    answers: Dict[str, Any] = {}


def _exam_error(e: Exception):
    if isinstance(e, PermissionError):
        raise HTTPException(status_code=403, detail=str(e))
    if isinstance(e, LookupError):
        raise HTTPException(status_code=404, detail=str(e))
    raise HTTPException(status_code=400, detail=str(e))


def _semester_or_current(term: Optional[str], year: Optional[str]):
    if term and year:
        return str(term), str(year)
    cur = get_current_semester_api()
    return str(cur["term"]), str(cur["year"])


@app.get("/api/v1/exams/windows")
def exam_windows_api(term: Optional[str] = None, year: Optional[str] = None):
    t, y = _semester_or_current(term, year)
    return {"status": "success", "term": t, "year": y, "data": exams.get_windows(t, y), "server_now": exams._fmt(exams.now())}


@app.post("/api/v1/exams/windows")
def save_exam_window_api(payload: ExamWindowRequest, request: Request):
    """Only an admin opens the exam period (one window per exam type for the whole school)."""
    if current_user(request).get("role") != "admin":
        raise HTTPException(status_code=403, detail="ตั้งวันเวลาสอบได้เฉพาะผู้ดูแลระบบ")
    try:
        exams.set_window(payload.term, payload.year, payload.exam_type, payload.start_at, payload.end_at)
    except ValueError as e:
        _exam_error(e)
    return {"status": "success", "data": exams.get_windows(payload.term, payload.year)}


@app.post("/api/v1/exams/course-time")
def save_exam_course_time_api(payload: ExamCourseTimeRequest, request: Request):
    """Admin: one course's own exam time (ตารางสอบ); empty = follow the school-wide window."""
    if current_user(request).get("role") != "admin":
        raise HTTPException(status_code=403, detail="ตั้งเวลาสอบรายวิชาได้เฉพาะผู้ดูแลระบบ")
    try:
        exams.set_course_time(payload.term, payload.year, payload.course_code, payload.exam_type, payload.start_at, payload.end_at)
    except ValueError as e:
        _exam_error(e)
    return {"status": "success"}


@app.post("/api/v1/exams/open-early")
def open_exam_early_api(payload: ExamOpenEarlyRequest, request: Request):
    """Admin: ปลดล็อกให้สอบได้ก่อนเวลา (or take it back)."""
    if current_user(request).get("role") != "admin":
        raise HTTPException(status_code=403, detail="ปลดล็อกก่อนเวลาได้เฉพาะผู้ดูแลระบบ")
    try:
        exams.set_opened_early(payload.term, payload.year, payload.course_codes, payload.exam_type, payload.opened,
                               current_user(request).get("name") or "")
    except ValueError as e:
        _exam_error(e)
    return {"status": "success"}


@app.get("/api/v1/exams/timetable")
def exam_timetable_api(term: str, year: str, exam_type: str):
    """ตารางสอบ grid with each course's name, teacher and open state."""
    if exam_type not in exams.EXAM_TYPES:
        raise HTTPException(status_code=400, detail="ประเภทข้อสอบไม่ถูกต้อง")
    return {"status": "success", "data": exam_timetable.get_timetable(term, year, exam_type)}


@app.post("/api/v1/exams/timetable")
def save_exam_timetable_api(payload: ExamTimetableRequest, request: Request):
    """Admin: save the grid; every course in it gets its exam time from it."""
    if current_user(request).get("role") != "admin":
        raise HTTPException(status_code=403, detail="แก้ตารางสอบได้เฉพาะผู้ดูแลระบบ")
    try:
        data = exam_timetable.save_timetable(payload.term, payload.year, payload.exam_type, payload.days,
                                             current_user(request).get("name") or "")
    except ValueError as e:
        _exam_error(e)
    return {"status": "success", "data": data}


@app.post("/api/v1/exams/timetable/upload")
async def upload_exam_timetable_api(request: Request, term: str = Form(...), year: str = Form(...),
                                    exam_type: str = Form(...), file: UploadFile = File(...)):
    """Admin: the timetable form as an image or PDF. A PDF with text comes back as a draft grid to check and save."""
    if current_user(request).get("role") != "admin":
        raise HTTPException(status_code=403, detail="อัปโหลดตารางสอบได้เฉพาะผู้ดูแลระบบ")
    data = await file.read()
    try:
        res = exam_timetable.store_upload(term, year, exam_type, file.filename or "", data, current_user(request).get("name") or "")
    except ValueError as e:
        _exam_error(e)
    return {"status": "success", "data": res}


@app.get("/api/v1/exams/timetable/file")
def exam_timetable_file_api(term: str, year: str, exam_type: str):
    """The uploaded original (image or PDF)."""
    p = exam_timetable.file_path_for(term, year, exam_type)
    if not p:
        raise HTTPException(status_code=404, detail="ยังไม่ได้อัปโหลดตารางสอบ")
    return FileResponse(str(p), media_type=exam_timetable.ALLOWED.get(p.suffix.lower(), "application/octet-stream"),
                        headers={"Cache-Control": "no-store"})


@app.get("/api/v1/exams/no-exam-right")
def exam_no_exam_right_api(request: Request, course_code: str, term: str, year: str):
    """Students of a course who are มส. (attendance below 80% or marked มส.) and whether the teacher let them sit."""
    data = exams.no_exam_right(course_code, term, year)
    data["can_edit"] = auth.owns_course(current_user(request), course_code, term, year)
    return {"status": "success", "data": data}


@app.get("/api/v1/exams/no-exam-right-counts")
def exam_no_exam_right_counts_api(term: str, year: str):
    """course_code -> {count, allowed} for the archive table."""
    return {"status": "success", "data": {k: {"count": v[0], "allowed": v[1]} for k, v in exams.ms_counts(term, year).items()}}


@app.post("/api/v1/exams/permit")
def exam_permit_api(payload: ExamPermitRequest, request: Request):
    """The course teacher ticks a มส. student who may sit this course's exams (unticked = cannot)."""
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    try:
        exams.set_permit(payload.course_code, payload.term, payload.year, payload.student_id, payload.allowed,
                         current_user(request).get("name") or "")
    except LookupError as e:
        _exam_error(e)
    return {"status": "success"}


@app.post("/api/v1/exams/block-ms")
def exam_block_ms_api(payload: ExamBlockMsRequest, request: Request):
    """Per paper: students with มส. cannot sit (True) or everyone sits (False)."""
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    try:
        exams.set_block_ms(payload.course_code, payload.term, payload.year, payload.exam_type, payload.block_ms)
    except (LookupError, PermissionError) as e:
        _exam_error(e)
    return {"status": "success"}


@app.post("/api/v1/exams/locks")
def save_exam_locks_api(payload: ExamLockRequest, request: Request):
    """Admin: which courses sit the midterm / final. A locked slot is read-only on the teacher's page and hidden from students."""
    if current_user(request).get("role") != "admin":
        raise HTTPException(status_code=403, detail="กำหนดวิชาที่สอบได้เฉพาะผู้ดูแลระบบ")
    try:
        n = exams.set_locked(payload.term, payload.year, payload.course_codes, payload.exam_types, payload.locked,
                             current_user(request).get("name") or "")
    except ValueError as e:
        _exam_error(e)
    return {"status": "success", "changed": n}


@app.get("/api/v1/exams/courses")
def exam_courses_api(request: Request, term: Optional[str] = None, year: Optional[str] = None,
                     teacher_code: Optional[str] = None):
    """
    A teacher always gets only the courses they teach (teacher_code is ignored); an admin gets every course,
    or one teacher's with teacher_code. `teachers` feeds the row of teacher buttons; `viewer` is who the
    server thinks is asking (the page follows it, not the browser's own idea of the user).
    """
    t, y = _semester_or_current(term, year)
    user = current_user(request)
    is_admin = user.get("role") == "admin"
    teachers = exams.teacher_course_map(t, y)
    selected = (teacher_code or "").strip() if is_admin else str(user.get("code") or "")
    if is_admin and not selected:
        keep = lambda c: True
    elif is_admin:
        mine = set(next((x["course_codes"] for x in teachers if x["code"] == selected), []))
        keep = lambda c: c["course_code"] in mine
    else:
        keep = lambda c: auth.owns_course(user, c["course_code"], t, y)
    return {"status": "success", "term": t, "year": y, "windows": exams.get_windows(t, y),
            "viewer": {"code": user.get("code"), "name": user.get("name"), "is_admin": is_admin},
            "selected_teacher": selected or None,
            "teachers": [{"code": x["code"], "name": x["name"], "course_count": len(x["course_codes"])} for x in teachers],
            "semesters": [{"term": r[0], "year": r[1]} for r in database.get_connection().execute(
                "SELECT DISTINCT term, year FROM courses ORDER BY CAST(year AS INTEGER) DESC, CAST(term AS INTEGER) DESC;")],
            "data": exams.list_courses(t, y, keep)}


@app.get("/api/v1/exams/paper")
def exam_paper_api(request: Request, course_code: str, term: str, year: str, exam_type: str):
    """The full paper with answers: the course teacher or an admin only."""
    require_course_owner(request, course_code, term, year)
    return {"status": "success", "data": exams.get_exam(course_code, term, year, exam_type)}


@app.post("/api/v1/exams/paper")
def save_exam_paper_api(payload: SaveExamRequest, request: Request):
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    try:
        data = exams.save_exam(payload.course_code, payload.term, payload.year, payload.exam_type, payload.mode,
                               payload.title or "", payload.link_url or "", payload.duration_min, payload.questions,
                               payload.ready, current_user(request).get("name") or "", block_ms=payload.block_ms)
    except (ValueError, PermissionError) as e:
        _exam_error(e)
    return {"status": "success", "data": data}


@app.post("/api/v1/exams/paper/delete")
def delete_exam_paper_api(payload: ExamRefRequest, request: Request):
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    try:
        exams.delete_exam(payload.course_code, payload.term, payload.year, payload.exam_type)
    except PermissionError as e:
        _exam_error(e)
    return {"status": "success"}


@app.post("/api/v1/exams/parse-text")
def parse_exam_text_api(payload: ParseExamTextRequest):
    """Questions pasted from Word ("1. ... / ก. ... / ตอบ ข") or Excel (tab separated rows)."""
    try:
        return {"status": "success", "data": exams.parse_questions_text(payload.text)}
    except ValueError as e:
        _exam_error(e)


_parse_jobs: Dict[str, Dict[str, Any]] = {}
_parse_jobs_lock = threading.Lock()


@app.post("/api/v1/exams/parse-file")
async def parse_exam_file_api(request: Request, file: UploadFile = File(...)):
    """A teacher's paper as Word (.docx / .doc), PDF or a photo -> questions for the editor (กลางภาค ปลายภาค
    แบบทดสอบย่อย). Lenient: questions without a key come back with answer = null for the teacher to pick.
    A quick file answers at once; a scan read by OCR (minutes) answers {"job": id} -> GET .../parse-file/{id}."""
    import uuid
    from starlette.concurrency import run_in_threadpool
    data = await file.read()
    user = current_user(request)
    job_id = uuid.uuid4().hex
    job = {"owner": user.get("code") or "", "status": "running", "progress": "กำลังอ่านไฟล์...", "result": None,
           "error": None, "at": time.time()}
    with _parse_jobs_lock:
        for k in [k for k, j in _parse_jobs.items() if time.time() - j["at"] > 3600]:
            _parse_jobs.pop(k, None)
        _parse_jobs[job_id] = job

    def run():
        try:
            job["result"] = exam_import.questions_from_file(file.filename or "", data, progress=lambda m: job.update(progress=m))
            job["status"] = "done"
        except ValueError as e:
            job["status"], job["error"] = "error", str(e)
        except Exception as e:
            print(f"[WARN] parse-file failed: {e}")
            job["status"], job["error"] = "error", "อ่านไฟล์ไม่สำเร็จ — ลองบันทึกเป็น PDF แล้วอัปโหลดใหม่"

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    await run_in_threadpool(worker.join, 8)
    if job["status"] == "done":
        _parse_jobs.pop(job_id, None)
        return {"status": "success", "data": job["result"]}
    if job["status"] == "error":
        _parse_jobs.pop(job_id, None)
        raise HTTPException(status_code=400, detail=job["error"])
    return {"status": "success", "data": {"job": job_id, "progress": job["progress"]}}


@app.get("/api/v1/exams/parse-file/{job_id}")
def parse_exam_file_job_api(job_id: str, request: Request):
    """How far the reading of an uploaded paper is; the questions once done (only for whoever uploaded it)."""
    job = _parse_jobs.get(job_id)
    user = current_user(request)
    if not job or (job["owner"] != (user.get("code") or "") and user.get("role") != "admin"):
        raise HTTPException(status_code=404, detail="ไม่พบงานอ่านไฟล์นี้ (อาจหมดเวลาแล้ว) — อัปโหลดใหม่")
    if job["status"] == "error":
        _parse_jobs.pop(job_id, None)
        raise HTTPException(status_code=400, detail=job["error"])
    if job["status"] == "done":
        _parse_jobs.pop(job_id, None)
        return {"status": "success", "data": {"done": True, "result": job["result"]}}
    return {"status": "success", "data": {"done": False, "progress": job["progress"]}}


@app.post("/api/v1/exams/image")
async def exam_image_upload_api(file: UploadFile = File(...)):
    """A picture for a question or a matching choice (teachers); returns its name for the paper."""
    from starlette.concurrency import run_in_threadpool
    data = await file.read()
    try:
        name = await run_in_threadpool(exams.save_image, data)
    except ValueError as e:
        _exam_error(e)
    return {"status": "success", "data": {"name": name}}


@app.get("/api/v1/exam-images/{name}")
def exam_image_api(name: str):
    """Pictures in papers: names are content hashes, so only someone who was given the paper can ask for one."""
    try:
        path = exams.image_path(name)
    except LookupError as e:
        _exam_error(e)
    return FileResponse(str(path), media_type="image/jpeg", headers={"Cache-Control": "private, max-age=86400"})


@app.get("/api/v1/exams/results")
def exam_results_api(request: Request, course_code: str, term: str, year: str, exam_type: str):
    require_course_owner(request, course_code, term, year)
    return {"status": "success", "data": exams.exam_results(course_code, term, year, exam_type)}


@app.post("/api/v1/exams/reset-attempt")
def reset_exam_attempt_api(payload: ExamRefRequest, request: Request):
    """Let one student sit the paper again."""
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    try:
        done = bool(payload.student_id) and exams.reset_attempt(payload.course_code, payload.term, payload.year, payload.exam_type, payload.student_id)
    except PermissionError as e:
        _exam_error(e)
    if not done:
        raise HTTPException(status_code=404, detail="ไม่พบการสอบของนักเรียนคนนี้")
    return {"status": "success"}


@app.get("/api/v1/exams/attempt")
def exam_attempt_detail_api(request: Request, course_code: str, term: str, year: str, exam_type: str, student_id: str):
    """One student's answers next to the key (เฉลย), with the photos to mark: the course teacher or an admin."""
    require_course_owner(request, course_code, term, year)
    try:
        return {"status": "success", "data": exams.attempt_detail(course_code, term, year, exam_type, student_id)}
    except LookupError as e:
        _exam_error(e)


@app.post("/api/v1/exams/mark")
def exam_mark_api(payload: ExamMarkRequest, request: Request):
    """The teacher's points for photo (written) answers; the score in the scores page follows."""
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    try:
        res = exams.mark_photos(payload.course_code, payload.term, payload.year, payload.exam_type, payload.student_id,
                                payload.marks, current_user(request).get("name") or "")
    except (ValueError, LookupError) as e:
        _exam_error(e)
    return {"status": "success", "data": res}


@app.get("/api/v1/exams/photo")
def exam_photo_api(request: Request, course_code: str, term: str, year: str, exam_type: str, student_id: str, name: str):
    require_course_owner(request, course_code, term, year)
    try:
        path = exams.teacher_photo_path(course_code, term, year, exam_type, student_id, name)
    except LookupError as e:
        _exam_error(e)
    return FileResponse(str(path), media_type="image/jpeg", headers={"Cache-Control": "private, max-age=3600"})


def _portal_student(request: Request) -> Dict[str, Any]:
    st = auth.find_active_student(current_user(request).get("code", ""))
    if not st:
        raise HTTPException(status_code=404, detail="ไม่พบข้อมูลนักเรียน")
    return st


@app.get("/api/v1/student-portal/exams")
def student_exams_api(request: Request):
    """Exam buttons (one per course code) for the logged-in student, grouped into กลางภาค / ปลายภาค."""
    return {"status": "success", "data": exams.student_exams(_portal_student(request))}


@app.post("/api/v1/student-portal/exams/{exam_id}/start")
def student_exam_start_api(exam_id: int, request: Request):
    try:
        return {"status": "success", "data": exams.start_attempt(exam_id, _portal_student(request))}
    except (ValueError, LookupError, PermissionError) as e:
        _exam_error(e)


@app.post("/api/v1/student-portal/exams/{exam_id}/photo")
async def student_exam_photo_api(exam_id: int, request: Request, question: int = Form(...), file: UploadFile = File(...)):
    """A photo of a written answer (เขียนบนกระดาษแล้วถ่ายรูปส่ง)."""
    data = await file.read()
    try:
        return {"status": "success", "data": exams.add_photo(exam_id, _portal_student(request), question, data)}
    except (ValueError, LookupError, PermissionError) as e:
        _exam_error(e)


@app.post("/api/v1/student-portal/exams/{exam_id}/photo/delete")
def student_exam_photo_delete_api(exam_id: int, payload: ExamPhotoDeleteRequest, request: Request):
    try:
        return {"status": "success", "data": exams.delete_photo(exam_id, _portal_student(request), payload.question, payload.name)}
    except (ValueError, LookupError, PermissionError) as e:
        _exam_error(e)


@app.get("/api/v1/student-portal/exams/{exam_id}/photo/{name}")
def student_exam_photo_get_api(exam_id: int, name: str, request: Request):
    try:
        path = exams.student_photo_path(exam_id, _portal_student(request), name)
    except (LookupError, PermissionError) as e:
        _exam_error(e)
    return FileResponse(str(path), media_type="image/jpeg", headers={"Cache-Control": "private, max-age=3600"})


@app.post("/api/v1/student-portal/exams/{exam_id}/answers")
def student_exam_answers_api(exam_id: int, payload: ExamAnswersRequest, request: Request):
    try:
        return {"status": "success", "data": exams.save_answers(exam_id, _portal_student(request), payload.answers)}
    except (ValueError, LookupError, PermissionError) as e:
        _exam_error(e)


@app.post("/api/v1/student-portal/exams/{exam_id}/submit")
def student_exam_submit_api(exam_id: int, payload: ExamAnswersRequest, request: Request):
    try:
        return {"status": "success", "data": exams.submit_attempt(exam_id, _portal_student(request), payload.answers)}
    except (ValueError, LookupError, PermissionError) as e:
        _exam_error(e)


# ================================================================ แบบทดสอบย่อย / หลังเรียน (quizzes.py)

class SaveQuizRequest(BaseModel):
    course_code: str
    term: str
    year: str
    id: Optional[int] = None
    title: str = ""
    unit_slot: Optional[int] = None
    questions: List[Dict[str, Any]] = []
    duration_min: Optional[int] = None
    start_at: Optional[str] = None
    end_at: Optional[str] = None
    class_only: bool = False
    max_attempts: int = 1
    ready: bool = False
    mode: str = "quiz"          # 'quiz' = made here, 'link' = an outside form (Google Form ...)
    link_url: Optional[str] = None


class QuizLinksRequest(BaseModel):
    course_code: str
    term: str
    year: str
    links: Dict[str, Optional[int]] = {}


class QuizResetRequest(BaseModel):
    student_id: str


def _quiz_owner(request: Request, quiz_id: int) -> Dict[str, str]:
    try:
        c = quizzes.quiz_course(quiz_id)
    except LookupError as e:
        _exam_error(e)
    require_course_owner(request, c["course_code"], c["term"], c["year"])
    return c


@app.get("/api/v1/quizzes")
def list_quizzes_api(request: Request, course_code: str, term: str, year: str):
    """A course's quizzes with how many students have sent each, and the full score of ช่อง 1-8."""
    require_course_owner(request, course_code, term, year)
    return {"status": "success", "data": quizzes.list_quizzes(course_code, term, year)}


@app.get("/api/v1/quizzes/counts")
def quiz_counts_api(term: str, year: str):
    return {"status": "success", "data": quizzes.course_quiz_counts(term, year)}


@app.get("/api/v1/quizzes/linked-slots")
def quiz_linked_slots_api(request: Request, course_code: str, term: str, year: str):
    """Scores page: which of ช่อง 1-8 are filled by quizzes (the teacher may still type over a cell: scores_json unit_manual)."""
    require_course_owner(request, course_code, term, year)
    return {"status": "success", "data": quizzes.linked_slots(course_code, term, year)}


@app.get("/api/v1/quizzes/{quiz_id}")
def get_quiz_api(quiz_id: int, request: Request):
    """The quiz with its answers: the course teacher or an admin only."""
    _quiz_owner(request, quiz_id)
    return {"status": "success", "data": quizzes.get_quiz(quiz_id)}


@app.post("/api/v1/quizzes")
def save_quiz_api(payload: SaveQuizRequest, request: Request):
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    if payload.id:
        _quiz_owner(request, payload.id)
    try:
        data = quizzes.save_quiz(payload.course_code, payload.term, payload.year, payload.model_dump(),
                                 current_user(request).get("name") or "", quiz_id=payload.id)
    except (ValueError, PermissionError, LookupError) as e:
        _exam_error(e)
    return {"status": "success", "data": data}


@app.post("/api/v1/quizzes/links")
def save_quiz_links_api(payload: QuizLinksRequest, request: Request):
    """Scores page: which column (ช่อง 1-8) each quiz fills; the columns are recomputed."""
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    try:
        data = quizzes.set_links(payload.course_code, payload.term, payload.year, payload.links,
                                 current_user(request).get("name") or "")
    except (ValueError, PermissionError, LookupError) as e:
        _exam_error(e)
    return {"status": "success", "data": data}


@app.post("/api/v1/quizzes/{quiz_id}/delete")
def delete_quiz_api(quiz_id: int, request: Request):
    _quiz_owner(request, quiz_id)
    quizzes.delete_quiz(quiz_id)
    return {"status": "success"}


@app.get("/api/v1/quizzes/{quiz_id}/results")
def quiz_results_api(quiz_id: int, request: Request):
    _quiz_owner(request, quiz_id)
    return {"status": "success", "data": quizzes.quiz_results(quiz_id)}


@app.post("/api/v1/quizzes/{quiz_id}/reset")
def reset_quiz_api(quiz_id: int, payload: QuizResetRequest, request: Request):
    """Clear one student's tries so they can sit the quiz again."""
    _quiz_owner(request, quiz_id)
    if not quizzes.reset_attempts(quiz_id, payload.student_id):
        raise HTTPException(status_code=404, detail="นักเรียนคนนี้ยังไม่ได้ทำแบบทดสอบนี้")
    return {"status": "success"}


@app.get("/api/v1/student-portal/quizzes")
def student_quizzes_api(request: Request):
    """แบบทดสอบย่อย of the logged-in student's enrolled courses."""
    return {"status": "success", "data": quizzes.student_quizzes(_portal_student(request))}


@app.post("/api/v1/student-portal/quizzes/{quiz_id}/start")
def student_quiz_start_api(quiz_id: int, request: Request):
    try:
        return {"status": "success", "data": quizzes.start_attempt(quiz_id, _portal_student(request))}
    except (ValueError, LookupError, PermissionError) as e:
        _exam_error(e)


@app.post("/api/v1/student-portal/quizzes/{quiz_id}/answers")
def student_quiz_answers_api(quiz_id: int, payload: ExamAnswersRequest, request: Request):
    try:
        return {"status": "success", "data": quizzes.save_answers(quiz_id, _portal_student(request), payload.answers)}
    except (ValueError, LookupError, PermissionError) as e:
        _exam_error(e)


@app.post("/api/v1/student-portal/quizzes/{quiz_id}/submit")
def student_quiz_submit_api(quiz_id: int, payload: ExamAnswersRequest, request: Request):
    try:
        return {"status": "success", "data": quizzes.submit_attempt(quiz_id, _portal_student(request), payload.answers)}
    except (ValueError, LookupError, PermissionError) as e:
        _exam_error(e)


THAI_WEEKDAYS = ["จันทร์", "อังคาร", "พุธ", "พฤหัสบดี", "ศุกร์", "เสาร์", "อาทิตย์"]


@app.get("/api/v1/student-portal/timetable")
def student_portal_timetable_api(request: Request):
    """ตารางเรียนของชั้นที่นักเรียนคนนี้อยู่ (ของตัวเองเท่านั้น: ระดับชั้นมาจากรหัสที่ล็อกอิน ไม่รับพารามิเตอร์)."""
    u = current_user(request)
    st = auth.find_active_student(u.get("code", ""))
    if not st:
        raise HTTPException(status_code=404, detail="ไม่พบข้อมูลนักเรียน")
    t, y, cl = str(st["term"]), str(st["year"]), st["class_level"]
    from timetable_manager import PERIOD_CONFIGS, get_timetables
    slots = get_timetables(term=t, year=y, class_level=cl, db_path="school_archive.db")
    # the teacher of a course the student is enrolled in, so a shared slot still shows their own teacher
    with get_connection("school_archive.db") as conn:
        mine = {r["course_code"]: {"teacher": r["teacher"] or "", "course_name": r["course_name"] or ""} for r in conn.execute(
            """SELECT c.course_code, c.course_name, c.teacher FROM courses c
               JOIN grades_history g ON g.course_code = c.course_code AND g.term = c.term AND g.year = c.year
               WHERE g.student_id = ? AND c.term = ? AND c.year = ?;""", (st["student_id"], t, y))}
    out = []
    for s in slots:
        code = (s.get("course_code") or "").strip()
        info = mine.get(code)
        out.append({
            "day_of_week": s.get("day_of_week"),
            "period_num": s.get("period_num"),
            "period_span": s.get("period_span") or 1,
            "course_code": code,
            "course_name": (info or {}).get("course_name") or (s.get("course_name") or ""),
            "teacher_name": (info or {}).get("teacher") or (s.get("teacher_name") or ""),
            "room": s.get("room") or "",
            "mine": info is not None,   # วิชาที่นักเรียนลงทะเบียนเรียนจริง (กิจกรรมรวมจะเป็น false)
        })
    return {"status": "success", "data": {
        "student_id": st["student_id"],
        "full_name": st["full_name"],
        "class_level": cl,
        "room": st.get("room") or "",
        "term": t,
        "year": y,
        "weekdays": THAI_WEEKDAYS[:5],
        "period_configs": PERIOD_CONFIGS,
        "slots": out,
    }}


@app.get("/api/v1/student-portal/me")
def student_portal_me_api(request: Request):
    """The logged-in student's own attendance: daily check-ins up to today, absent/leave/late days, per-course summary."""
    u = current_user(request)
    st = auth.find_active_student(u.get("code", ""))
    if not st:
        raise HTTPException(status_code=404, detail="ไม่พบข้อมูลนักเรียน")
    sid, t, y, cl = st["student_id"], str(st["term"]), str(st["year"]), st["class_level"]
    db = "school_archive.db"
    grid = database.get_daily_attendance_grid(t, y, cl, db_path=db)
    rec = next((s for s in grid.get("students", []) if s["student_id"] == sid), None)
    if rec is None:
        raise HTTPException(status_code=404, detail="ไม่พบข้อมูลการเช็คชื่อ")
    dates = database.compute_100_dates(grid.get("start_date"), t, y)
    holidays = {int(h) for h in grid.get("holidays", [])}
    today = attendance_rules.today_iso()
    labels = {"/": "มา", "ส": "สาย", "ล": "ลา", "": "ขาด"}
    days = []
    for i, d in enumerate(dates):
        if d > today:
            break
        if i in holidays:
            continue
        mark = rec["status_list"][i] if i < len(rec["status_list"]) else ""
        days.append({"date": d, "weekday": THAI_WEEKDAYS[datetime.strptime(d, "%Y-%m-%d").weekday()],
                     "mark": mark, "status": labels.get(mark, "ขาด")})

    with get_connection(db) as conn:
        rows = conn.execute(
            """
            SELECT g.course_code, c.course_name, c.teacher, g.attendance_json
            FROM grades_history g JOIN courses c ON c.course_code = g.course_code AND c.term = g.term AND c.year = g.year
            WHERE g.student_id = ? AND g.term = ? AND g.year = ? ORDER BY g.course_code;
            """,
            (sid, t, y)
        ).fetchall()
    courses = []
    for r in rows:
        try:
            a = json.loads(r["attendance_json"] or "{}")
        except Exception:
            a = {}
        courses.append({
            "course_code": r["course_code"], "course_name": r["course_name"], "teacher": r["teacher"],
            "present_count": a.get("present_count", 0), "absent_count": a.get("absent_count", 0),
            "leave_count": a.get("leave_count", 0), "late_count": a.get("late_count", 0),
            "elapsed_periods": a.get("elapsed_periods", 0), "total_periods": a.get("total_periods", 0),
            "percentage": a.get("percentage", 100.0),
        })

    return {"status": "success", "data": {
        "student": {"student_id": sid, "full_name": st["full_name"], "class_level": cl, "room": st["room"],
                    "student_no": st["student_no"], "term": t, "year": y,
                    "photo_version": student_photos.photo_version(sid)},
        "as_of": today,
        "summary": {"school_days": len(days), "present": rec["present_count"], "late": rec["late_count"],
                    "leave": rec["leave_count"], "absent": rec["absent_count"], "percentage": rec["percentage"]},
        "absent_dates": [d for d in days if d["status"] == "ขาด"],
        "leave_dates": [d for d in days if d["status"] == "ลา"],
        "late_dates": [d for d in days if d["status"] == "สาย"],
        "days": days,
        "courses": courses,
    }}


@app.post("/api/v1/auth/logout")
def logout_api():
    resp = JSONResponse(content={"status": "success"})
    resp.delete_cookie(auth.COOKIE_NAME, path="/")
    return resp


@app.get("/api/v1/system/admins")
def get_system_admins_api():
    """Get list of current system administrators (max 3)."""
    try:
        from database import get_system_admins
        admins = get_system_admins("school_archive.db")
        return {
            "status": "success",
            "admins": admins,
            "max_limit": 3,
            "count": len(admins)
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/system/admins")
def add_system_admin_api(payload: AdminManageRequest):
    """Appoint a teacher as administrator (max 3)."""
    try:
        from database import add_system_admin, get_system_admins
        ok, msg = add_system_admin(payload.teacher_code, "school_archive.db")
        auth.forget_pin_cache()
        if not ok:
            raise HTTPException(status_code=400, detail=msg)
        return {
            "status": "success",
            "message": msg,
            "admins": get_system_admins("school_archive.db")
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/api/v1/system/admins/{teacher_code}")
def remove_system_admin_api(teacher_code: str):
    """Remove administrator privilege from a teacher (at least 1 must remain)."""
    try:
        from database import remove_system_admin, get_system_admins
        ok, msg = remove_system_admin(teacher_code, "school_archive.db")
        auth.forget_pin_cache()
        if not ok:
            raise HTTPException(status_code=400, detail=msg)
        return {
            "status": "success",
            "message": msg,
            "admins": get_system_admins("school_archive.db")
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))



# ==============================================================================
# MASTER SCHOOL TEACHERS ROSTER ENDPOINTS
# ==============================================================================

class TeacherManageRequest(BaseModel):
    name: Optional[str] = None
    names: Optional[List[str]] = None
    code: Optional[str] = None
    login_pin: Optional[str] = None


@app.get("/api/v1/teachers")
def get_teachers_api(request: Request):
    """Retrieve all teachers in the school master roster with codes (login PINs for admins only)."""
    try:
        teachers = get_school_teachers("school_archive.db")
        teachers_structured = get_school_teachers_with_code("school_archive.db")
        return {
            "status": "success",
            "data": teachers,
            "teachers": hide_pins_unless_admin(request, teachers_structured)
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/teachers")
def add_teachers_api(payload: TeacherManageRequest):
    """Add a single teacher with code/login_pin or bulk import teachers."""
    try:
        added_count = 0
        if payload.names:
            added_count = bulk_add_school_teachers(payload.names, "school_archive.db")
        elif payload.name:
            ok = add_school_teacher(payload.name, code=payload.code, login_pin=payload.login_pin, db_path="school_archive.db")
            if ok:
                added_count = 1
        auth.forget_pin_cache()

        teachers = get_school_teachers("school_archive.db")
        teachers_structured = get_school_teachers_with_code("school_archive.db")
        return {
            "status": "success",
            "added_count": added_count,
            "data": teachers,
            "teachers": teachers_structured,
            "message": f"บันทึกข้อมูลครูสำเร็จ {added_count} ท่าน"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.put("/api/v1/teachers/{teacher_id}")
def update_teacher_api(teacher_id: int, payload: TeacherManageRequest):
    """Update teacher name, code, and optional login PIN."""
    try:
        if not payload.name:
            raise HTTPException(status_code=400, detail="กรุณาระบุชื่อครู")
        ok = update_school_teacher(teacher_id, payload.name, code=payload.code, login_pin=payload.login_pin, db_path="school_archive.db")
        auth.forget_pin_cache()  # a changed PIN signs that teacher's old sessions out
        teachers = get_school_teachers("school_archive.db")
        teachers_structured = get_school_teachers_with_code("school_archive.db")
        return {
            "status": "success",
            "updated": ok,
            "data": teachers,
            "teachers": teachers_structured,
            "message": f"อัปเดตข้อมูลครู {payload.name} เรียบร้อยแล้ว"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.put("/api/v1/teachers/{teacher_code}/pin")
def update_teacher_pin_api(teacher_code: str, payload: TeacherPinUpdateRequest, request: Request):
    """Update a teacher's login PIN (1 to 4 digits): one's own PIN, or anyone's for an admin."""
    me = current_user(request)
    is_self = me.get("code") == teacher_code
    if not is_self and me.get("role") != "admin":
        raise HTTPException(status_code=403, detail="เปลี่ยนได้เฉพาะ PIN ของตนเอง")
    try:
        from database import update_teacher_login_pin, get_school_teachers_with_code, get_school_teachers
        ok, msg = update_teacher_login_pin(teacher_code, payload.pin, "school_archive.db")
        if not ok:
            raise HTTPException(status_code=400, detail=msg)
        auth.forget_pin_cache(teacher_code)
        teachers = get_school_teachers("school_archive.db")
        teachers_structured = get_school_teachers_with_code("school_archive.db")
        body = {
            "status": "success",
            "message": msg,
            "data": teachers,
            "teachers": hide_pins_unless_admin(request, teachers_structured)
        }
        if is_self:  # the new PIN invalidates the current session: hand out a fresh one
            return _session_response(request, body, auth.issue_token(me, auth.current_pin(teacher_code)))
        return body
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/api/v1/teachers/{teacher_identifier}")
def delete_teacher_api(teacher_identifier: str):
    """Delete a teacher from the master roster by ID or name."""
    try:
        from urllib.parse import unquote
        clean = unquote(teacher_identifier).strip()
        ok = delete_school_teacher(clean, "school_archive.db")
        teachers = get_school_teachers("school_archive.db")
        teachers_structured = get_school_teachers_with_code("school_archive.db")
        return {
            "status": "success",
            "deleted": ok,
            "data": teachers,
            "teachers": teachers_structured,
            "message": f"ลบข้อมูลเรียบร้อยแล้ว"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/teachers/sync")
def sync_teachers_api():
    """Sync and discover all teacher names from courses and class advisors in the system."""
    try:
        newly_added = sync_school_teachers_from_system("school_archive.db")
        teachers = get_school_teachers("school_archive.db")
        teachers_structured = get_school_teachers_with_code("school_archive.db")
        return {
            "status": "success",
            "newly_added": newly_added,
            "total_count": len(teachers),
            "data": teachers,
            "teachers": teachers_structured,
            "message": f"ดึงข้อมูลรายชื่อครูจากระบบสำเร็จ พบครูใหม่ {newly_added} ท่าน (รวมทั้งหมด {len(teachers)} ท่าน)"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# -------------------------------------------------------------
# Teacher -> Courses management (view & fix imported assignments)
# -------------------------------------------------------------

class CourseEditRequest(BaseModel):
    course_code: str
    course_name: str
    term: str
    year: str
    class_level: Optional[str] = ""
    teacher: Optional[str] = ""
    teacher_code: Optional[str] = ""
    credits: Optional[float] = 1.0
    department: Optional[str] = ""
    course_type: Optional[str] = "พื้นฐาน"
    score_ratio: Optional[str] = "70:30"
    periods_per_week: Optional[int] = None
    old_course_code: Optional[str] = None
    old_term: Optional[str] = None
    old_year: Optional[str] = None
    regenerate_porpor5: bool = True


@app.get("/api/v1/teachers/courses")
def get_teacher_courses_api(
    teacher: str = Query(...),
    term: Optional[str] = Query(None),
    year: Optional[str] = Query(None),
):
    """List all courses (subject + class level) taught by a teacher (by name or code)."""
    try:
        from course_importer import get_courses_by_teacher
        rows = get_courses_by_teacher(teacher, term=term, year=year, db_path="school_archive.db")
        return {"status": "success", "data": rows}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/courses/item")
def upsert_course_item_api(payload: CourseEditRequest):
    """Create or update a single course assignment and regenerate its PorPor 5 template."""
    try:
        from course_importer import update_or_create_course
        data = payload.dict()
        old_keys = None
        if payload.old_course_code:
            old_keys = {
                "course_code": payload.old_course_code,
                "term": payload.old_term or payload.term,
                "year": payload.old_year or payload.year,
            }
        if data.get("periods_per_week") is None:
            data.pop("periods_per_week", None)
        res = update_or_create_course(
            data,
            old_keys=old_keys,
            regenerate_porpor5=payload.regenerate_porpor5,
            db_path="school_archive.db",
        )
        return res
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/api/v1/courses/item")
def delete_course_item_api(
    course_code: str = Query(...),
    term: str = Query(...),
    year: str = Query(...),
):
    """Delete a single course assignment (e.g. imported by mistake)."""
    try:
        from course_importer import delete_course
        ok = delete_course(course_code, term, year, db_path="school_archive.db")
        return {"status": "success", "deleted": ok, "message": f"ลบรายวิชา {course_code} เรียบร้อยแล้ว" if ok else "ไม่พบรายวิชา"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# -------------------------------------------------------------
# Course Structure & Teacher Assignment Import Endpoints
# -------------------------------------------------------------

@app.post("/api/v1/courses/import")
def import_courses_endpoint(
    file: Optional[UploadFile] = File(None),
    csv_text: Optional[str] = Form(None),
    term: str = Form("2"),
    year: str = Form("2569"),
    generate_excel: bool = Form(True),
    generate_pdf: bool = Form(False)
):
    """
    Upload Excel/CSV or paste CSV data with course structure and teacher assignments.
    Automatically resolves teachers by code, saves courses, and generates PorPor 5 Excel & PDF.
    """
    try:
        from course_importer import import_courses_and_generate
        if file is not None and file.filename:
            content = file.file.read()
        elif csv_text and csv_text.strip():
            content = csv_text.strip()
        else:
            raise HTTPException(status_code=400, detail="กรุณาเลือกไฟล์ (.xlsx หรือ .csv) หรือวางข้อความตารางรายวิชา")

        res = import_courses_and_generate(
            content,
            term=term,
            year=year,
            db_path="school_archive.db",
            generate_excel=generate_excel,
            generate_pdf=generate_pdf
        )
        return res
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/courses/template")
def download_courses_template(format: str = "xlsx"):
    """Download blank/example course import template in Excel or CSV format."""
    from fastapi.responses import FileResponse
    if format == "csv":
        p = Path("courses_2569_term2.csv")
        if not p.exists():
            raise HTTPException(status_code=404, detail="Template not found")
        return FileResponse(p, media_type="text/csv", filename="แบบฟอร์มนำเข้ารายวิชาและครูผู้สอน.csv")
    else:
        p = Path("courses_2569_term2.xlsx")
        if not p.exists():
            raise HTTPException(status_code=404, detail="Template not found")
        return FileResponse(
            p,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            filename="แบบฟอร์มนำเข้ารายวิชาและครูผู้สอน.xlsx"
        )

# -------------------------------------------------------------
# ฟอร์มนำเข้าข้อมูลโรงเรียน (school_import.py): teachers, programmes, rooms, students, courses,
# sections, timetable and enrolment by name in one workbook. Admin only (auth: writes + ADMIN_GET).
# -------------------------------------------------------------

@app.get("/api/v1/school-import/template")
def school_import_template_api(term: str = Query(...), year: str = Query(...), prefill: bool = Query(True), full: bool = Query(False)):
    """full=true: ไฟล์ข้อมูลทั้งหมดของภาคเรียน (แผ่น 1-8 + คะแนน เวลาเรียน ตั้งค่า ...) นำเข้ากลับได้ไฟล์เดียว (ผู้ดูแลระบบเท่านั้น ไม่มี PIN)"""
    import school_import
    from urllib.parse import quote
    try:
        data = school_import.build_template(term.strip(), year.strip(), prefill=prefill, db_path="school_archive.db", full=full)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    name = (f"ไฟล์ข้อมูลโรงเรียนทั้งหมด_{term}-{year}_{datetime.now().strftime('%Y%m%d_%H%M')}.xlsx" if full and prefill else
            f"แบบฟอร์มนำเข้าข้อมูลโรงเรียน_{term}-{year}{'_ข้อมูลปัจจุบัน' if prefill else ''}.xlsx")
    return Response(
        content=data,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}", "Cache-Control": "no-store"},
    )


@app.post("/api/v1/school-import/preview")
def school_import_preview_api(file: UploadFile = File(...), term: str = Form(...), year: str = Form(...)):
    """Checks every row against the database; writes nothing."""
    import school_import
    try:
        return {"status": "success", "data": school_import.preview(file.file.read(), term.strip(), year.strip(), db_path="school_archive.db")}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/v1/school-import/commit")
def school_import_commit_api(request: Request, file: UploadFile = File(...), term: str = Form(...), year: str = Form(...)):
    """Same checks as preview; with no error left: backup, write in one transaction, recount attendance (ปพ.5 refresh)."""
    import school_import
    try:
        res = school_import.commit(file.file.read(), term.strip(), year.strip(), db_path="school_archive.db",
                                   by=current_user(request).get("name", ""))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    if res.get("committed"):
        auth.forget_pin_cache()
    return {"status": "success", "data": res}


class SaveCourseScoresRequest(BaseModel):
    course_code: str
    term: str
    year: str
    score_ratio: Optional[str] = None
    score_config: Dict[str, Any]
    students: List[Dict[str, Any]]


class SaveCatalogCourseRequest(BaseModel):
    course_code: str
    course_name: str
    term: Optional[str] = None
    stage: Optional[str] = None
    class_level: Optional[str] = None
    course_type: Optional[str] = None
    department: Optional[str] = None
    subject_prefix: Optional[str] = None
    credits: Optional[float] = 1.0
    score_ratio: Optional[str] = "70:30"
    course_description: Optional[str] = ""
    old_course_code: Optional[str] = None


@app.get("/api/v1/catalog")
def get_course_catalog_endpoint(
    term: Optional[str] = Query(None, description="1 or 2"),
    stage: Optional[str] = Query(None, description="2 (ม.ต้น) or 3 (ม.ปลาย)"),
    course_type: Optional[str] = Query(None, description="พื้นฐาน, เพิ่มเติม, or กิจกรรม"),
    subject_prefix: Optional[str] = Query(None, description="ท, ค, ว, ส, พ, ศ, ง, อ, จ, ก, I"),
    department: Optional[str] = Query(None, description="Department name"),
    search: Optional[str] = Query(None, description="Search query")
):
    """Retrieve Master Course Catalog with filters."""
    try:
        from catalog_manager import get_course_catalog
        rows = get_course_catalog(
            term=term,
            stage=stage,
            course_type=course_type,
            department=department,
            subject_prefix=subject_prefix,
            search=search,
            db_path="school_archive.db"
        )
        return {
            "status": "success",
            "total": len(rows),
            "courses": rows
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/catalog/decode")
def decode_course_code_endpoint(course_code: str = Query(..., description="Course code")):
    """Decode Thai MOE course code into department, stage, class_level, course_type, term."""
    try:
        from catalog_manager import decode_course_code, lookup_catalog_course
        decoded = decode_course_code(course_code)
        existing = lookup_catalog_course(course_code, db_path="school_archive.db")
        return {
            "status": "success",
            "decoded": decoded,
            "existing": existing
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/catalog")
def save_catalog_course_endpoint(payload: SaveCatalogCourseRequest):
    """Upsert course in Master Course Catalog and sync to semester courses & Excel files."""
    try:
        from catalog_manager import upsert_catalog_course
        res = upsert_catalog_course(
            data=payload.model_dump(),
            old_course_code=payload.old_course_code,
            sync_files=True,
            db_path="school_archive.db"
        )
        if res.get("status") == "error":
            raise HTTPException(status_code=400, detail=res.get("message", "Failed to save catalog course"))
        return res
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/api/v1/catalog/{course_code}")
def delete_catalog_course_endpoint(course_code: str):
    """Delete a course from Master Course Catalog."""
    try:
        from catalog_manager import delete_catalog_course
        deleted = delete_catalog_course(course_code, db_path="school_archive.db")
        return {
            "status": "success",
            "deleted": deleted,
            "message": f"ลบรายวิชา {course_code} ออกจากคลังรายวิชามาตรฐานเรียบร้อยแล้ว" if deleted else "ไม่พบรายวิชาในคลัง"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/courses/scores")
def get_course_scores_endpoint(
    course_code: str = Query(..., description="Course code"),
    term: str = Query("2", description="Semester term"),
    year: str = Query("2569", description="Academic year")
):
    """Retrieve Sheet (4) รวมคะแนน max scores and student scores for a course."""
    try:
        from course_importer import get_course_scores_sheet
        res = get_course_scores_sheet(course_code=course_code, term=term, year=year, db_path="school_archive.db")
        if res.get("status") == "error":
            raise HTTPException(status_code=404, detail=res.get("message", "Course not found"))
        return res
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/courses/scores")
def save_course_scores_endpoint(payload: SaveCourseScoresRequest, request: Request):
    """Save Sheet (4) รวมคะแนน max scores, student scores, and remark overrides, syncing to DB and Excel."""
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    try:
        from course_importer import save_course_scores_sheet
        res = save_course_scores_sheet(
            course_code=payload.course_code,
            term=payload.term,
            year=payload.year,
            score_config=payload.score_config,
            students=payload.students,
            score_ratio=payload.score_ratio,
            db_path="school_archive.db"
        )
        if res.get("status") == "error":
            raise HTTPException(status_code=400, detail=res.get("message", "Failed to save scores"))
        if payload.term and payload.year:
            # ช่องที่เชื่อมแบบทดสอบย่อย: คะแนนเต็มอาจเปลี่ยน -> คำนวณใหม่ (เขียนไฟล์ ปพ.5 ซ้ำเฉพาะเมื่อค่าเปลี่ยน)
            quizzes.forget_unit_max(payload.course_code, payload.term, payload.year)
            try:
                quizzes.apply_scores(payload.course_code, payload.term, payload.year)
            except Exception as e:
                print(f"[WARN] quiz columns for {payload.course_code}: {e}")
            porpor5_refresh_queue.enqueue(payload.term, payload.year, [payload.course_code], pdf_only=True)
        return res
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class SavePp5LabelsRequest(BaseModel):
    course_code: str
    term: str
    year: str
    indicators: Optional[List[str]] = None  # ตัวชี้วัด of score slots 1-8 (sheet 4)
    attributes: Optional[List[str]] = None  # คุณลักษณะอันพึงประสงค์ items 1-8 (sheet 5)
    reading: Optional[List[str]] = None     # อ่าน คิด วิเคราะห์ เขียน items 1-5 (sheet 5)


@app.get("/api/v1/courses/pp5-labels")
def get_pp5_labels_endpoint(request: Request, course_code: str = Query(...), term: str = Query(...), year: str = Query(...)):
    """The vertical header labels of a course's ปพ.5 (sheet 4 ตัวชี้วัด, sheet 5 item names) and whether this user may edit them."""
    return {
        "status": "success",
        "labels": pp5_labels.get_labels(course_code, term, year),
        "can_edit": auth.owns_course(current_user(request), course_code, term, year),
        "standard_attributes": pp5_labels.STANDARD_ATTRIBUTES,
        "max_len": pp5_labels.MAX_LEN,
    }


@app.post("/api/v1/courses/pp5-labels")
def save_pp5_labels_endpoint(payload: SavePp5LabelsRequest, request: Request):
    """Save the labels, write them into the course's ปพ.5 Excel at once, and re-render its PDF in the background."""
    require_course_owner(request, payload.course_code, payload.term, payload.year)
    changes = {g: v for g, v in (("indicators", payload.indicators), ("attributes", payload.attributes),
                                 ("reading", payload.reading)) if v is not None}
    labels = pp5_labels.save_labels(payload.course_code, payload.term, payload.year, changes)
    if labels is None:
        raise HTTPException(status_code=404, detail=f"ไม่พบรายวิชา {payload.course_code} ในภาคเรียนที่ {payload.term}/{payload.year}")
    xl = pp5_labels.write_to_file(payload.course_code, payload.term, payload.year, labels, output_dir=OUTPUT_DIR)
    if xl is None:
        xl = ensure_standby_excel_file(payload.course_code, term=payload.term, year=payload.year)  # generated with the labels
    porpor5_refresh_queue.enqueue(payload.term, payload.year, [payload.course_code], pdf_only=True)
    return {"status": "success", "labels": labels, "excel_updated": bool(xl)}


# =========================================================
# TEACHER TIMETABLES & SMART LATE PERIOD INTEGRATION API
# =========================================================

class UpsertTimetableSlotRequest(BaseModel):
    term: str
    year: str
    teacher_name: str
    day_of_week: int
    period_num: int
    period_span: int = 1
    course_code: str
    course_name: Optional[str] = ""
    class_level: Optional[str] = ""
    room: Optional[str] = ""
    note: Optional[str] = ""
    force: bool = False   # ยืนยันบันทึกแม้ชั้นนั้นมีคาบของครูคนอื่นอยู่แล้วในเวลาเดียวกัน


class CascadeLateRequest(BaseModel):
    term: str
    year: str
    class_level: str
    student_id: str
    date: str
    arrived_period: int
    slot_idx: Optional[int] = None
    day_of_week: Optional[int] = None


@app.get("/api/v1/timetables")
def get_timetables_endpoint(
    term: str = Query("1"),
    year: str = Query("2569"),
    teacher_name: Optional[str] = Query(None),
    class_level: Optional[str] = Query(None)
):
    """Retrieve teacher timetables, available teachers, and period configs."""
    try:
        from timetable_manager import (
            get_timetables,
            get_teachers_with_timetables,
            PERIOD_CONFIGS
        )
        slots = get_timetables(
            term=term,
            year=year,
            teacher_name=teacher_name,
            class_level=class_level,
            db_path="school_archive.db"
        )
        tt_teachers = get_teachers_with_timetables(term=term, year=year, db_path="school_archive.db")
        all_school_teachers = get_school_teachers(db_path="school_archive.db")
        return {
            "status": "success",
            "data": slots,
            "teachers_with_timetables": tt_teachers,
            "all_teachers": all_school_teachers,
            "period_configs": PERIOD_CONFIGS
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


def _after_timetable_change(term: str, year: str) -> None:
    """ตารางสอนเปลี่ยน -> รายวิชาในคลังข้อมูล, ตารางเรียนของนักเรียน, เวลาเรียนทั้งเทอม และ ปพ.5 ต้องตามทันที
    (เจ้าของเลือกให้ตารางใหม่มีผลทั้งเทอม 6 พ.ย. 2569)"""
    from timetable_manager import sync_timetables_to_archive_courses
    sync_timetables_to_archive_courses(term=term, year=year, db_path="school_archive.db")
    database.sync_semester_attendance_to_courses(term, year, db_path="school_archive.db")


def _check_combined_slot(course_code: str, class_level: str) -> None:
    """สอนรวมหลายชั้นในคาบเดียว: รหัสวิชากับชั้นต้องจับคู่ตามลำดับ เช่น "ค31102, ค32102" กับ "ม.4, ม.5"."""
    import re as _re
    codes = [c.strip() for c in str(course_code or "").split(",") if c.strip()]
    levels = [l.strip() for l in str(class_level or "").split(",") if l.strip()]
    real = [c for c in codes if _re.fullmatch(r"[ก-ฮA-Z]\d{5}", c.replace(" ", ""))]
    if len(real) > 1 and len(real) != len(levels):
        raise HTTPException(status_code=400, detail=f"สอนรวม {len(real)} วิชา ต้องเลือกชั้นให้ครบ {len(real)} ชั้นตามลำดับรหัสวิชา")


def _require_own_timetable(request: Request, teacher_name: str) -> None:
    """ครูแก้ได้เฉพาะคาบของตัวเอง ผู้ดูแลระบบแก้ได้ทุกคน"""
    me = current_user(request)
    if me.get("role") == "admin":
        return
    if me.get("role") != "teacher" or auth._base_name(me.get("name", "")) != auth._base_name(teacher_name or ""):
        raise HTTPException(status_code=403, detail="แก้ไขได้เฉพาะคาบสอนของตัวเอง")


def _shared_class_note(clash: List[Dict[str, Any]]) -> str:
    """ชั้นนั้นมีวิชาของครูคนอื่นในคาบเดียวกัน: ไม่ห้าม (ถือว่าครูตกลงกันแล้ว) แสดงสองวิชาในคาบนั้น"""
    if not clash:
        return ""
    c = clash[0]
    return f" • {c['class_level']} มี {c['course_code']} ของ{c['teacher_name']} ในคาบเดียวกันด้วย จะแสดงทั้งสองวิชา"


@app.post("/api/v1/timetables")
def upsert_timetable_endpoint(payload: UpsertTimetableSlotRequest, request: Request):
    """Insert or update a timetable slot. ชั้นนั้นมีคาบของครูคนอื่นอยู่แล้ว -> บันทึกได้ แสดงสองวิชาในคาบนั้น"""
    _require_own_timetable(request, payload.teacher_name)
    _check_combined_slot(payload.course_code, payload.class_level or "")
    from timetable_manager import timetable_clashes
    clash = timetable_clashes(payload.term, payload.year, payload.teacher_name, payload.day_of_week,
                              payload.period_num, payload.period_span or 1, payload.class_level or "",
                              db_path="school_archive.db")["class"]
    try:
        from timetable_manager import upsert_timetable_entry
        entry_id = upsert_timetable_entry(
            term=payload.term,
            year=payload.year,
            teacher_name=payload.teacher_name,
            day_of_week=payload.day_of_week,
            period_num=payload.period_num,
            course_code=payload.course_code,
            course_name=payload.course_name,
            class_level=payload.class_level,
            room=payload.room,
            note=payload.note,
            period_span=payload.period_span,
            db_path="school_archive.db"
        )
        _after_timetable_change(payload.term, payload.year)
        return {
            "status": "success",
            "id": entry_id,
            "message": f"บันทึกตารางสอน {payload.teacher_name} คาบที่ {payload.period_num} ({payload.course_code}) เรียบร้อยแล้ว"
                       + _shared_class_note(clash),
            "shared_with": clash,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/api/v1/timetables/{entry_id}")
def delete_timetable_endpoint(entry_id: int, request: Request):
    """Delete a timetable slot by ID (ครูลบได้เฉพาะคาบของตัวเอง)."""
    from timetable_manager import delete_timetable_entry
    with get_connection("school_archive.db") as conn:
        row = conn.execute("SELECT term, year, teacher_name FROM teacher_timetables WHERE id = ?;", (entry_id,)).fetchone()
    if not row:
        # เดิมตอบว่าลบสำเร็จแม้ไม่มีคาบนี้แล้ว ทำให้ดูเหมือนลบได้ทั้งที่ไม่ได้ลบ
        raise HTTPException(status_code=404, detail="ไม่พบคาบนี้แล้ว (อาจถูกแก้ไขไปก่อนหน้า) กรุณารีเฟรชหน้าตารางสอน")
    _require_own_timetable(request, row["teacher_name"])
    try:
        delete_timetable_entry(entry_id, db_path="school_archive.db")
        _after_timetable_change(row["term"], row["year"])
        return {"status": "success", "deleted": True, "message": "ลบคาบสอนเรียบร้อยแล้ว"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class MoveTimetableSlotRequest(BaseModel):
    day_of_week: int
    period_num: int
    force: bool = False   # ยืนยันรวมเข้ากับคาบเดิมของครูคนเดียวกันเป็นคาบสอนรวม


@app.post("/api/v1/timetables/{entry_id}/move")
def move_timetable_endpoint(entry_id: int, payload: MoveTimetableSlotRequest, request: Request):
    """ย้ายคาบสอนไปวัน/คาบใหม่ในขั้นตอนเดียว (ครูย้ายได้เฉพาะคาบของตัวเอง)
    - ครูคนเดิมมีคาบอยู่แล้วที่เวลานั้น -> ถามยืนยัน (409 needs_confirm) แล้วรวมเป็นคาบสอนรวม; รวมไม่ได้ -> 409
    - ชั้นนั้นมีคาบของครูคนอื่นอยู่แล้ว -> ย้ายได้ แสดงสองวิชาในคาบนั้น (ถือว่าครูตกลงกันแล้ว)"""
    from timetable_manager import move_timetable_entry, timetable_clashes
    if not (1 <= payload.day_of_week <= 5 and 1 <= payload.period_num <= 12):
        raise HTTPException(status_code=400, detail="วันต้องเป็นจันทร์-ศุกร์ และคาบต้องอยู่ระหว่าง 1-12")
    with get_connection("school_archive.db") as conn:
        row = conn.execute("SELECT * FROM teacher_timetables WHERE id = ?;", (entry_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="ไม่พบคาบนี้แล้ว กรุณารีเฟรชหน้าตารางสอน")
    _require_own_timetable(request, row["teacher_name"])
    if row["day_of_week"] == payload.day_of_week and row["period_num"] == payload.period_num:
        return {"status": "success", "data": dict(row), "message": "คาบนี้อยู่ที่เวลานี้อยู่แล้ว"}
    clash = timetable_clashes(row["term"], row["year"], row["teacher_name"], payload.day_of_week, payload.period_num,
                              row["period_span"] or 1, row["class_level"] or "", ignore_id=entry_id, db_path="school_archive.db")
    days = ["", "จันทร์", "อังคาร", "พุธ", "พฤหัสบดี", "ศุกร์"]
    when = f"วัน{days[payload.day_of_week]} คาบ {payload.period_num}"
    if clash["teacher"]:
        # ครูคนเดิมมีคาบที่เวลานั้นอยู่แล้ว: ถ้าเป็นรายวิชาที่ช่วงคาบตรงกัน รวมเป็น "สอนรวมหลายชั้น" ได้ (ถามยืนยันก่อน)
        from timetable_manager import can_merge_timetable_entries, merge_timetable_entries
        c = clash["teacher"][0]
        with get_connection("school_archive.db") as conn:
            target = conn.execute("SELECT * FROM teacher_timetables WHERE id = ?;", (c["id"],)).fetchone()
        mergeable = (len(clash["teacher"]) == 1 and target is not None
                     and target["period_num"] == payload.period_num and can_merge_timetable_entries(row, target))
        if not mergeable:
            raise HTTPException(status_code=409, detail=f"{row['teacher_name']} มีคาบ {c['course_code']} ({c['class_level']}) อยู่แล้วที่{when}"
                                                        " (รวมเป็นคาบสอนรวมไม่ได้ เพราะเป็นกิจกรรม รหัสซ้ำ หรือจำนวนคาบไม่เท่ากัน)")
        if not payload.force:
            return JSONResponse(status_code=409, content={
                "needs_confirm": True,
                "detail": f"{row['teacher_name']} มีคาบ {c['course_code']} ({c['class_level']}) อยู่แล้วที่{when}\n"
                          f"ต้องการรวม {row['course_code']} ({row['class_level']}) เข้าไปเป็นคาบสอนรวม (เรียนพร้อมกันในคาบเดียว) หรือไม่?"})
        merged = merge_timetable_entries(entry_id, c["id"], db_path="school_archive.db")
        if not merged:
            raise HTTPException(status_code=409, detail="รวมคาบไม่สำเร็จ ตารางอาจถูกแก้ไขไปก่อนหน้า กรุณารีเฟรชหน้าตารางสอน")
        _after_timetable_change(row["term"], row["year"])
        return {"status": "success", "data": merged, "merged": True, "shared_with": clash["class"],
                "message": f"รวม {row['course_code']} เข้ากับ {c['course_code']} ที่{when} เป็นคาบสอนรวม "
                           f"{merged['course_code']} ({merged['class_level']}) แล้ว ระบบปรับตารางเรียน เวลาเรียน และ ปพ.5 ให้แล้ว"
                           + _shared_class_note(clash["class"])}
    moved = move_timetable_entry(entry_id, payload.day_of_week, payload.period_num, db_path="school_archive.db")
    _after_timetable_change(row["term"], row["year"])
    return {"status": "success", "data": moved,
            "message": f"ย้าย {row['course_code']} ไป{when} แล้ว ระบบปรับตารางเรียน เวลาเรียน และ ปพ.5 ให้แล้ว"
                       + _shared_class_note(clash["class"]),
            "shared_with": clash["class"]}


@app.get("/api/v1/timetables/teacher-courses")
def get_teacher_courses_endpoint(
    term: str = Query("1"),
    year: str = Query("2569"),
    teacher_name: str = Query(...)
):
    """Get courses taught by a specific teacher + catalog courses for filtering."""
    try:
        from timetable_manager import get_teacher_courses
        from catalog_manager import get_course_catalog
        teacher_courses = get_teacher_courses(
            term=term,
            year=year,
            teacher_name=teacher_name,
            db_path="school_archive.db"
        )
        catalog_courses = get_course_catalog(term=term, db_path="school_archive.db")
        return {
            "status": "success",
            "teacher_courses": teacher_courses,
            "catalog_courses": catalog_courses
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/timetables/preview-late")
def preview_late_cascade_endpoint(
    term: str = Query("1"),
    year: str = Query("2569"),
    class_level: str = Query(...),
    day_of_week: int = Query(...),
    arrived_period: int = Query(...)
):
    """Preview which course the student arrived at and which earlier courses will be marked absent."""
    try:
        from timetable_manager import preview_late_cascade
        res = preview_late_cascade(
            term=term,
            year=year,
            class_level=class_level,
            day_of_week=day_of_week,
            arrived_period=arrived_period,
            db_path="school_archive.db"
        )
        return {"status": "success", "data": res}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/timetables/cascade-late")
def cascade_late_student_endpoint(payload: CascadeLateRequest, request: Request):
    """Execute cascading absence for missed periods when a student arrives late."""
    require_class_advisor(request, payload.class_level, payload.term, payload.year)
    try:
        from timetable_manager import cascade_late_student
        res = cascade_late_student(
            term=payload.term,
            year=payload.year,
            class_level=payload.class_level,
            student_id=payload.student_id,
            date_str=payload.date,
            arrived_period=payload.arrived_period,
            slot_idx=payload.slot_idx,
            day_of_week_override=payload.day_of_week,
            outputs_dir="outputs",
            db_path="school_archive.db"
        )
        return res
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/timetables/template")
def download_timetable_template_endpoint(
    term: str = Query("1"),
    year: str = Query("2569"),
    teacher_name: Optional[str] = Query(None),
    class_level: Optional[str] = Query(None)
):
    """Download Excel template for teacher or class timetable."""
    try:
        from timetable_manager import generate_timetable_template_excel
        from urllib.parse import quote
        xlsx_bytes = generate_timetable_template_excel(
            term=term,
            year=year,
            teacher_name=teacher_name or "ครูผู้สอน",
            class_level=class_level,
            db_path="school_archive.db"
        )
        if class_level and class_level.strip():
            filename = f"แบบฟอร์มตารางเรียน_{class_level.strip()}_{term}_{year}.xlsx"
        else:
            t_name = teacher_name or "ครูผู้สอน"
            filename = f"แบบฟอร์มตารางสอน_{t_name}_{term}_{year}.xlsx"
        encoded_fn = quote(filename)
        return Response(
            content=xlsx_bytes,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={
                "Content-Disposition": f"attachment; filename*=UTF-8''{encoded_fn}"
            }
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/timetables/upload")
async def upload_timetable_endpoint(
    file: UploadFile = File(...),
    term: str = Form("1"),
    year: str = Form("2569"),
    teacher_name: Optional[str] = Form(None)
):
    """Upload and import teacher timetable from Excel file."""
    try:
        from timetable_manager import import_timetables_from_file
        content = await file.read()
        res = import_timetables_from_file(
            file_content=content,
            term=term,
            year=year,
            teacher_name_override=teacher_name if teacher_name and teacher_name.strip() else None,
            db_path="school_archive.db"
        )
        return res
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/timetables/sync-archive")
def sync_archive_courses_endpoint(
    term: str = Query("1"),
    year: str = Query("2569")
):
    """Synchronize teacher timetable courses into the courses repository and enroll active students."""
    try:
        from timetable_manager import sync_timetables_to_archive_courses
        res = sync_timetables_to_archive_courses(
            term=term,
            year=year,
            db_path="school_archive.db"
        )
        # New periods / new enrolments: recount every course from the daily table and refresh the ปพ.5 files
        database.sync_semester_attendance_to_courses(term, year, db_path="school_archive.db")
        return res
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))



# -------------------------------------------------------------
# HOME VISIT SYSTEM API (ระบบเยี่ยมบ้าน)
# -------------------------------------------------------------

HOME_VISIT_DATA_DIR = Path(__file__).resolve().parent / "data" / "home_visits"
HOME_VISIT_DATA_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/api/v1/home-visit-photos", StaticFiles(directory=str(HOME_VISIT_DATA_DIR)), name="home_visit_photos")


class HomeVisitSaveRequest(BaseModel):
    term: str
    year: str
    advisor_name: Optional[str] = ""
    fields: Dict[str, Any]
    photos: Optional[List[str]] = None
    photo_captions: Optional[Dict[str, str]] = None
    recorded_by_name: Optional[str] = ""


@app.get("/api/v1/home-visits")
def api_get_home_visit_summary(
    term: str = Query("1"),
    year: str = Query("2569")
):
    try:
        data = database.get_home_visit_summary(term=term, year=year, db_path="school_archive.db")
        return {"status": "success", "data": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/home-visits/{class_level}")
def api_get_home_visit_class(
    class_level: str,
    term: str = Query("1"),
    year: str = Query("2569")
):
    try:
        cl = class_level.strip()
        rep = database.get_home_visit_report(term=term, year=year, class_level=cl, db_path="school_archive.db")

        # If no report yet, find advisors and student count to prefill
        advisor_name = ""
        student_count = 0
        advisors_list = database.get_class_advisors(term=term, year=year, db_path="school_archive.db")
        for adv in advisors_list:
            if adv.get("class_level") == cl:
                names = [adv.get("advisor1"), adv.get("advisor2"), adv.get("advisor3")]
                advisor_name = ", ".join(filter(None, names))
                break

        with database.get_connection("school_archive.db") as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT COUNT(*) as cnt FROM class_students WHERE term = ? AND year = ? AND class_level = ? AND is_active = 1;", (term, year, cl))
            row = cursor.fetchone()
            if row:
                student_count = row["cnt"]

        # Prioritize evaluated student count from report fields if available
        f = (rep and rep.get("fields")) or {}
        try:
            c_vis = int(float(str(f.get("1. จำนวนนักเรียนที่ออกเยี่ยมบ้าน (คน)") or 0)))
            c_not = int(float(str(f.get("2. จำนวนนักเรียนที่ไม่ได้ออกเยี่ยมบ้าน (คน)") or 0)))
            if (c_vis + c_not) > 0:
                student_count = c_vis + c_not
        except Exception:
            pass

        return {
            "status": "success",
            "data": rep,
            "meta": {
                "class_level": cl,
                "term": term,
                "year": year,
                "advisor_name": advisor_name or (rep and rep.get("advisor_name")) or "",
                "student_count": student_count
            }
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/home-visits/{class_level}")
def api_save_home_visit_class(
    class_level: str,
    req: HomeVisitSaveRequest
):
    try:
        rep = database.upsert_home_visit_report(
            term=req.term,
            year=req.year,
            class_level=class_level.strip(),
            advisor_name=req.advisor_name or "",
            fields=req.fields,
            photo_paths=req.photos,
            photo_captions=req.photo_captions,
            recorded_by_name=req.recorded_by_name or "",
            db_path="school_archive.db"
        )
        return {"status": "success", "message": "บันทึกข้อมูลการเยี่ยมบ้านเรียบร้อยแล้ว", "data": rep}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/home-visits/{class_level}/upload-photo")
async def api_upload_home_visit_photo(
    class_level: str,
    term: str = Form("1"),
    year: str = Form("2569"),
    file: UploadFile = File(...)
):
    try:
        cl = class_level.strip()
        t = term.strip()
        y = year.strip()

        target_dir = HOME_VISIT_DATA_DIR / f"{y}_{t}" / cl
        target_dir.mkdir(parents=True, exist_ok=True)

        # Read and resize image with Pillow
        contents = await file.read()
        img = Image.open(io.BytesIO(contents))
        img = ImageOps.exif_transpose(img)
        img = img.convert("RGB")

        # Max dimension 1280px
        max_dim = 1280
        if img.width > max_dim or img.height > max_dim:
            img.thumbnail((max_dim, max_dim), Image.Resampling.LANCZOS)

        timestamp = int(time.time() * 1000)
        ext = "jpg"
        filename = f"visit_{timestamp}.{ext}"
        save_path = target_dir / filename
        img.save(save_path, format="JPEG", quality=85)

        # Update database photo list
        rep = database.get_home_visit_report(t, y, cl, db_path="school_archive.db")
        photos = (rep and rep.get("photos")) or []
        photos.append(filename)

        updated = database.update_home_visit_photos(t, y, cl, photos, db_path="school_archive.db")
        photo_url = f"/api/v1/home-visit-photos/{y}_{t}/{cl}/{filename}"

        return {
            "status": "success",
            "message": "อัปโหลดรูปภาพเยี่ยมบ้านสำเร็จ",
            "filename": filename,
            "url": photo_url,
            "photos": updated.get("photos", [])
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"อัปโหลดรูปภาพไม่สำเร็จ: {e}")


@app.delete("/api/v1/home-visits/{class_level}/photo")
def api_delete_home_visit_photo(
    class_level: str,
    term: str = Query(...),
    year: str = Query(...),
    photo_name: str = Query(...)
):
    try:
        cl = class_level.strip()
        t = term.strip()
        y = year.strip()
        fn = photo_name.strip()

        file_path = HOME_VISIT_DATA_DIR / f"{y}_{t}" / cl / fn
        if file_path.exists():
            file_path.unlink()

        rep = database.get_home_visit_report(t, y, cl, db_path="school_archive.db")
        photos = (rep and rep.get("photos")) or []
        photos = [p for p in photos if p != fn]

        updated = database.update_home_visit_photos(t, y, cl, photos, db_path="school_archive.db")
        return {"status": "success", "message": "ลบรูปภาพเรียบร้อยแล้ว", "photos": updated.get("photos", [])}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/home-visits/{class_level}/docx")
def api_download_home_visit_class_docx(
    class_level: str,
    term: str = Query("1"),
    year: str = Query("2569"),
    recorded_by: Optional[str] = Query(None),
    frameless: bool = Query(False)
):
    try:
        cl = class_level.strip()
        rep = database.get_home_visit_report(term=term, year=year, class_level=cl, db_path="school_archive.db")
        if not rep:
            rep = {
                "term": term,
                "year": year,
                "class_level": cl,
                "advisor_name": "",
                "fields": {},
                "photos": [],
                "photo_captions": {}
            }

        school_name = school_profile.short_name()
        sigs = database.get_school_signatories(year=year, db_path="school_archive.db")
        director_name = sigs.get("director_name") or ""

        advisors_list = []
        adv_rows = database.get_class_advisors(term=term, year=year, db_path="school_archive.db")
        for adv in adv_rows:
            if adv.get("class_level") == cl:
                for k in ["advisor1", "advisor2", "advisor3"]:
                    val = (adv.get(k) or "").strip()
                    if val and val not in advisors_list:
                        advisors_list.append(val)
                break
        if advisors_list:
            rep["advisor_name"] = ", ".join(advisors_list)

        rec_name = (recorded_by or rep.get("recorded_by_name") or rep.get("advisor_name") or "").strip()
        rec_date = rep.get("recorded_at") or rep.get("updated_at") or ""

        logo_path = Path("school_logo.png")
        if not logo_path.exists():
            logo_path = None

        photo_captions = rep.get("photo_captions") or {}

        out_docx = home_visit_exporter.generate_class_home_visit_docx(
            report_data=rep,
            school_name=school_name,
            logo_path=str(logo_path) if logo_path else None,
            director_name=director_name,
            recorded_by_name=rec_name,
            advisors_list=advisors_list,
            recorded_date_str=rec_date,
            frameless=frameless,
            photo_captions=photo_captions
        )
        suffix = "_ไม่มีกรอบ" if frameless else ""
        safe_filename = f"แบบรายงานเยี่ยมบ้าน_{cl}_{year}_เทอม{term}{suffix}.docx"
        return FileResponse(
            out_docx,
            media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(safe_filename)}"}
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/home-visits/{class_level}/pdf")
def api_download_home_visit_class_pdf(
    class_level: str,
    term: str = Query("1"),
    year: str = Query("2569"),
    recorded_by: Optional[str] = Query(None)
):
    try:
        cl = class_level.strip()
        rep = database.get_home_visit_report(term=term, year=year, class_level=cl, db_path="school_archive.db")
        if not rep:
            rep = {
                "term": term,
                "year": year,
                "class_level": cl,
                "advisor_name": "",
                "fields": {},
                "photos": []
            }

        school_name = school_profile.short_name()
        sigs = database.get_school_signatories(year=year, db_path="school_archive.db")
        director_name = sigs.get("director_name") or ""

        advisors_list = []
        adv_rows = database.get_class_advisors(term=term, year=year, db_path="school_archive.db")
        for adv in adv_rows:
            if adv.get("class_level") == cl:
                for k in ["advisor1", "advisor2", "advisor3"]:
                    val = (adv.get(k) or "").strip()
                    if val and val not in advisors_list:
                        advisors_list.append(val)
                break
        if advisors_list:
            rep["advisor_name"] = ", ".join(advisors_list)

        rec_name = (recorded_by or rep.get("recorded_by_name") or rep.get("advisor_name") or "").strip()
        rec_date = rep.get("recorded_at") or rep.get("updated_at") or ""

        logo_path = Path("school_logo.png")
        if not logo_path.exists():
            logo_path = None

        out_docx = home_visit_exporter.generate_class_home_visit_docx(
            report_data=rep,
            school_name=school_name,
            logo_path=str(logo_path) if logo_path else None,
            director_name=director_name,
            recorded_by_name=rec_name,
            advisors_list=advisors_list,
            recorded_date_str=rec_date
        )
        out_pdf = home_visit_exporter.convert_docx_to_pdf(out_docx)
        safe_filename = f"แบบรายงานเยี่ยมบ้าน_{cl}_{year}_เทอม{term}.pdf"
        return FileResponse(
            out_pdf,
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(safe_filename)}"}
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/home-visits/{class_level}/pdf-preview")
def api_preview_home_visit_class_pdf(
    class_level: str,
    term: str = Query("1"),
    year: str = Query("2569"),
    recorded_by: Optional[str] = Query(None)
):
    """Serve PDF directly inline for in-browser preview without forcing download."""
    try:
        cl = class_level.strip()
        rep = database.get_home_visit_report(term=term, year=year, class_level=cl, db_path="school_archive.db")
        if not rep:
            rep = {
                "term": term,
                "year": year,
                "class_level": cl,
                "advisor_name": "",
                "fields": {},
                "photos": []
            }

        school_name = school_profile.short_name()
        sigs = database.get_school_signatories(year=year, db_path="school_archive.db")
        director_name = sigs.get("director_name") or ""

        advisors_list = []
        adv_rows = database.get_class_advisors(term=term, year=year, db_path="school_archive.db")
        for adv in adv_rows:
            if adv.get("class_level") == cl:
                for k in ["advisor1", "advisor2", "advisor3"]:
                    val = (adv.get(k) or "").strip()
                    if val and val not in advisors_list:
                        advisors_list.append(val)
                break
        if advisors_list:
            rep["advisor_name"] = ", ".join(advisors_list)

        rec_name = (recorded_by or rep.get("recorded_by_name") or rep.get("advisor_name") or "").strip()
        rec_date = rep.get("recorded_at") or rep.get("updated_at") or ""

        logo_path = Path("school_logo.png")
        if not logo_path.exists():
            logo_path = None

        out_docx = home_visit_exporter.generate_class_home_visit_docx(
            report_data=rep,
            school_name=school_name,
            logo_path=str(logo_path) if logo_path else None,
            director_name=director_name,
            recorded_by_name=rec_name,
            advisors_list=advisors_list,
            recorded_date_str=rec_date
        )
        out_pdf = home_visit_exporter.convert_docx_to_pdf(out_docx)
        safe_filename = f"แบบรายงานเยี่ยมบ้าน_{cl}_{year}_เทอม{term}.pdf"
        return FileResponse(
            out_pdf,
            media_type="application/pdf",
            headers={"Content-Disposition": f"inline; filename*=UTF-8''{quote(safe_filename)}"}
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/home-visits-summary/docx")
def api_download_home_visit_summary_docx(
    term: str = Query("1"),
    year: str = Query("2569"),
    frameless: bool = Query(False)
):
    try:
        sum_data = database.get_home_visit_summary(term=term, year=year, db_path="school_archive.db")
        school_name = school_profile.short_name()
        logo_path = Path("school_logo.png")
        if not logo_path.exists():
            logo_path = None

        sigs = database.get_school_signatories(year=year, db_path="school_archive.db")
        director_name = sigs.get("director_name") or ""

        out_docx = home_visit_exporter.generate_school_summary_docx(
            summary_data=sum_data,
            school_name=school_name,
            logo_path=str(logo_path) if logo_path else None,
            director_name=director_name,
            frameless=frameless
        )
        suffix = "_ไม่มีกรอบ" if frameless else ""
        safe_filename = f"แบบรายงานสรุปเยี่ยมบ้านทั้งโรงเรียน_{year}_เทอม{term}{suffix}.docx"
        return FileResponse(
            out_docx,
            media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(safe_filename)}"}
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/home-visits-summary/pdf")
def api_download_home_visit_summary_pdf(
    term: str = Query("1"),
    year: str = Query("2569")
):
    try:
        sum_data = database.get_home_visit_summary(term=term, year=year, db_path="school_archive.db")
        school_name = school_profile.short_name()
        sigs = database.get_school_signatories(year=year, db_path="school_archive.db")
        director_name = sigs.get("director_name") or ""

        logo_path = Path("school_logo.png")
        if not logo_path.exists():
            logo_path = None

        out_docx = home_visit_exporter.generate_school_summary_docx(
            summary_data=sum_data,
            school_name=school_name,
            logo_path=str(logo_path) if logo_path else None,
            director_name=director_name
        )
        out_pdf = home_visit_exporter.convert_docx_to_pdf(out_docx)
        safe_filename = f"แบบรายงานสรุปเยี่ยมบ้านทั้งโรงเรียน_{year}_เทอม{term}.pdf"
        return FileResponse(
            out_pdf,
            media_type="application/pdf",
            headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(safe_filename)}"}
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/home-visits-summary/pdf-preview")
def api_preview_home_visit_summary_pdf(
    term: str = Query("1"),
    year: str = Query("2569")
):
    try:
        sum_data = database.get_home_visit_summary(term=term, year=year, db_path="school_archive.db")
        school_name = school_profile.short_name()
        sigs = database.get_school_signatories(year=year, db_path="school_archive.db")
        director_name = sigs.get("director_name") or ""

        logo_path = Path("school_logo.png")
        if not logo_path.exists():
            logo_path = None

        out_docx = home_visit_exporter.generate_school_summary_docx(
            summary_data=sum_data,
            school_name=school_name,
            logo_path=str(logo_path) if logo_path else None,
            director_name=director_name
        )
        out_pdf = home_visit_exporter.convert_docx_to_pdf(out_docx)
        safe_filename = f"แบบรายงานสรุปเยี่ยมบ้านทั้งโรงเรียน_{year}_เทอม{term}.pdf"
        return FileResponse(
            out_pdf,
            media_type="application/pdf",
            headers={"Content-Disposition": f"inline; filename*=UTF-8''{quote(safe_filename)}"}
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))



# -------------------------------------------------------------
# TEACHER LEAVE & LATE ARRIVAL ROUTES (ระบบบันทึกการลา / ขอเข้าสาย)
# -------------------------------------------------------------
import leave_manager

class LeaveCreateRequest(BaseModel):
    leave_type: str  # 'ลากิจ', 'ลาป่วย', 'ขอเข้าสาย'
    start_date: str  # YYYY-MM-DD
    end_date: Optional[str] = None
    expected_arrival_time: Optional[str] = None
    late_time: Optional[str] = None
    reason: Optional[str] = None
    contact_phone: Optional[str] = None
    phone: Optional[str] = None
    teacher_code: Optional[str] = None
    teacher_name: Optional[str] = None

class LeaveStatusUpdateRequest(BaseModel):
    status: str  # 'approved', 'rejected', 'pending'

@app.get("/api/v1/leaves/my")
def get_my_leaves(request: Request):
    user = current_user(request)
    code = (user.get("code") or "").strip()
    if not code:
        raise HTTPException(status_code=401, detail="กรุณาเข้าสู่ระบบครู")
    leaves = leave_manager.get_leaves_for_teacher(code)
    return {"status": "success", "data": leaves}

@app.post("/api/v1/leaves")
def create_leave(request: Request, payload: LeaveCreateRequest):
    user = current_user(request)
    code = (user.get("code") or "").strip()
    name = (user.get("name") or "").strip()
    if not code:
        raise HTTPException(status_code=401, detail="กรุณาเข้าสู่ระบบครู")
    try:
        exp_time = payload.expected_arrival_time or payload.late_time
        c_phone = payload.contact_phone or payload.phone

        target_code = code
        target_name = name

        # หัวหน้าบุคคล (school_profile.personnel_head_code) หรือผู้ดูแลระบบ สามารถบันทึกแทนครูคนอื่นได้
        is_personnel_head = (school_profile.is_personnel_head(code) or user.get("is_personnel_head") == True)
        is_admin = user.get("role") in ("admin", "director")
        if (is_personnel_head or is_admin) and payload.teacher_code and payload.teacher_code.strip():
            target_code = payload.teacher_code.strip()
            if payload.teacher_name and payload.teacher_name.strip():
                target_name = payload.teacher_name.strip()
            else:
                with database.get_connection("school_archive.db") as conn:
                    r = conn.execute("SELECT name FROM school_teachers WHERE code = ?", (target_code,)).fetchone()
                    if r and r["name"]:
                        target_name = r["name"].strip()

        record = leave_manager.create_leave_record(
            teacher_code=target_code,
            teacher_name=target_name,
            leave_type=payload.leave_type,
            start_date=payload.start_date,
            end_date=payload.end_date,
            expected_arrival_time=exp_time,
            reason=payload.reason,
            contact_phone=c_phone
        )
        return {"status": "success", "message": "บันทึกข้อมูลเรียบร้อยแล้ว", "data": record}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"เกิดข้อผิดพลาด: {e}")

def _can_view_all_leaves(user: Dict[str, Any]) -> bool:
    """รายการลาของครูทุกคน (เหตุผล เบอร์โทร) ดูได้เฉพาะผู้ดูแลระบบ ผู้อำนวยการ และหัวหน้างานบุคคล
    ครูคนอื่นดูได้เฉพาะของตัวเองผ่าน /api/v1/leaves/my"""
    return user.get("role") in ("admin", "director") or school_profile.is_personnel_head(user.get("code")) or user.get("is_personnel_head") is True


@app.get("/api/v1/leaves/all")
def get_all_leaves_route(
    request: Request,
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    leave_type: Optional[str] = None
):
    user = current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="กรุณาเข้าสู่ระบบ")
    if not _can_view_all_leaves(user):
        raise HTTPException(status_code=403, detail="รายการลาของครูทุกคนดูได้เฉพาะผู้บริหารและหัวหน้างานบุคคล")
    leaves = leave_manager.get_all_leaves(start_date=start_date, end_date=end_date, leave_type=leave_type)
    return {"status": "success", "data": leaves}

class LeaveUpdateRequest(BaseModel):
    leave_type: Optional[str] = None
    start_date: Optional[str] = None
    end_date: Optional[str] = None
    expected_arrival_time: Optional[str] = None
    late_time: Optional[str] = None
    reason: Optional[str] = None
    contact_phone: Optional[str] = None
    phone: Optional[str] = None

@app.put("/api/v1/leaves/{leave_id}")
def update_leave_route(request: Request, leave_id: int, payload: LeaveUpdateRequest):
    user = current_user(request)
    code = (user.get("code") or "").strip()
    if not code:
        raise HTTPException(status_code=401, detail="กรุณาเข้าสู่ระบบ")

    # Check permission: owner or หัวหน้าบุคคล (school_profile.personnel_head_code) or admin
    with database.get_connection("school_archive.db") as conn:
        conn.row_factory = sqlite3.Row
        rec = conn.execute("SELECT teacher_code FROM teacher_leaves WHERE id = ?", (leave_id,)).fetchone()
        if not rec:
            raise HTTPException(status_code=404, detail="ไม่พบรายการลาที่ต้องการแก้ไข")
        rec_owner = rec["teacher_code"]

    is_owner = (rec_owner == code)
    is_privileged = (school_profile.is_personnel_head(code) or user.get("role") in ("admin", "director") or user.get("is_personnel_head") == True)
    if not (is_owner or is_privileged):
        raise HTTPException(status_code=403, detail="ไม่มีสิทธิ์แก้ไขรายการลานี้")

    exp_time = payload.expected_arrival_time or payload.late_time
    c_phone = payload.contact_phone or payload.phone

    updated = leave_manager.update_leave_record(
        leave_id=leave_id,
        leave_type=payload.leave_type,
        start_date=payload.start_date,
        end_date=payload.end_date,
        expected_arrival_time=exp_time,
        reason=payload.reason,
        contact_phone=c_phone
    )
    if not updated:
        raise HTTPException(status_code=404, detail="ไม่สามารถแก้ไขรายการลาได้")
    return {"status": "success", "message": "แก้ไขข้อมูลการลาเรียบร้อยแล้ว", "data": updated}

@app.delete("/api/v1/leaves/{leave_id}")
def delete_leave(request: Request, leave_id: int):
    user = current_user(request)
    code = (user.get("code") or "").strip()
    is_privileged = (user.get("role") in ("admin", "director") or school_profile.is_personnel_head(code) or user.get("is_personnel_head") == True)
    if not code and not is_privileged:
        raise HTTPException(status_code=401, detail="กรุณาเข้าสู่ระบบ")
    ok = leave_manager.delete_leave_record(leave_id, teacher_code=code, is_admin=is_privileged)
    if not ok:
        raise HTTPException(status_code=404, detail="ไม่พบรายการหรือไม่มีสิทธิ์ลบรายการนี้")
    return {"status": "success", "message": "ยกเลิกคำขอเรียบร้อยแล้ว"}

@app.patch("/api/v1/leaves/{leave_id}/status")
def update_leave_status_route(request: Request, leave_id: int, payload: LeaveStatusUpdateRequest):
    user = current_user(request)
    is_admin = user.get("role") in ("admin", "director")
    if not is_admin:
        raise HTTPException(status_code=403, detail="สงวนสิทธิ์เฉพาะผู้บริหารและผู้ดูแลระบบ")
    name = (user.get("name") or "").strip()
    ok = leave_manager.update_leave_status(leave_id, status=payload.status, approved_by=name)
    if not ok:
        raise HTTPException(status_code=404, detail="ไม่พบรายการที่ต้องการอัปเดต")
    return {"status": "success", "message": "อัปเดตสถานะเรียบร้อยแล้ว"}

@app.get("/api/v1/leaves/summary-by-teacher")
def get_leaves_summary_by_teacher(request: Request):
    user = current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="กรุณาเข้าสู่ระบบ")
    if not _can_view_all_leaves(user):
        raise HTTPException(status_code=403, detail="สถิติการลาของครูทุกคนดูได้เฉพาะผู้บริหารและหัวหน้างานบุคคล")
    summary = leave_manager.get_teacher_leaves_summary()
    return {"status": "success", "data": summary}

@app.get("/api/v1/leaves/report-print")
def print_leaves_report(
    request: Request,
    teacher_code: Optional[str] = None,
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    leave_type: Optional[str] = None
):
    from fastapi.responses import HTMLResponse
    user = current_user(request)
    if not user:
        raise HTTPException(status_code=401, detail="กรุณาเข้าสู่ระบบ")
    # ครูทั่วไปพิมพ์ได้เฉพาะรายงานของตัวเอง
    if not _can_view_all_leaves(user):
        if not teacher_code or str(teacher_code).strip() != str(user.get("code") or "").strip():
            raise HTTPException(status_code=403, detail="พิมพ์ได้เฉพาะรายงานการลาของตัวเอง")

    # Fetch school signatory info
    school_name = "โรงเรียน"
    director_name = "ผู้อำนวยการโรงเรียน"
    try:
        with database.get_connection("school_archive.db") as conn:
            sig = conn.execute("SELECT * FROM school_signatories LIMIT 1;").fetchone()
            if sig:
                school_name = sig["school_name"] or school_name
                director_name = sig["director_name"] or director_name
    except Exception:
        pass

    # Fetch leaves
    all_leaves = leave_manager.get_all_leaves(start_date=start_date, end_date=end_date, leave_type=leave_type)
    t_code = (teacher_code or "").strip()
    if t_code and t_code.lower() != "all":
        all_leaves = [l for l in all_leaves if l.get("teacher_code") == t_code]

    target_teacher_name = "คณะครูและบุคลากรทุกคน"
    # the personnel head signs the report (school_profile.personnel_head_code)
    head_code = school_profile.personnel_head_code()
    head_name = ""
    if head_code:
        with get_connection("school_archive.db") as _conn:
            _r = _conn.execute("SELECT name FROM school_teachers WHERE code = ?;", (head_code,)).fetchone()
            head_name = (_r["name"] if _r else "") or ""
    if t_code and t_code.lower() != "all" and all_leaves:
        target_teacher_name = all_leaves[0].get("teacher_name", t_code)

    # Compute summary
    kij_leaves = [l for l in all_leaves if l.get("leave_type") == "ลากิจ"]
    puay_leaves = [l for l in all_leaves if l.get("leave_type") == "ลาป่วย"]
    late_leaves = [l for l in all_leaves if l.get("leave_type") == "ขอเข้าสาย"]

    kij_times = len(kij_leaves)
    kij_days = sum(l.get("days_count", 1) for l in kij_leaves)

    puay_times = len(puay_leaves)
    puay_days = sum(l.get("days_count", 1) for l in puay_leaves)

    late_times = len(late_leaves)

    total_times = kij_times + puay_times
    total_days = kij_days + puay_days

    # Format Thai Dates
    thai_months = ['', 'มกราคม', 'กุมภาพันธ์', 'มีนาคม', 'เมษายน', 'พฤษภาคม', 'มิถุนายน',
                   'กรกฎาคม', 'สิงหาคม', 'กันยายน', 'ตุลาคม', 'พฤศจิกายน', 'ธันวาคม']
    now = datetime.now()
    now_th = f"{now.day} {thai_months[now.month]} พ.ศ. {now.year + 543}"

    def fmt_date(d_str):
        if not d_str: return "-"
        try:
            parts = d_str.split('-')
            return f"{int(parts[2])} {thai_months[int(parts[1])]} {int(parts[0]) + 543}"
        except Exception:
            return d_str

    rows_html = ""
    for idx, l in enumerate(all_leaves, 1):
        l_type = l.get("leave_type", "-")
        t_name = l.get("teacher_name", "-")
        s_date = l.get("start_date", "-")
        e_date = l.get("end_date") or s_date
        d_count = l.get("days_count", 1)
        reason = l.get("reason") or "-"
        phone = l.get("phone") or l.get("contact_phone") or "-"
        late_t = l.get("late_time") or l.get("expected_arrival_time") or ""

        date_disp = fmt_date(s_date) if s_date == e_date else f"{fmt_date(s_date)} ถึง {fmt_date(e_date)}"
        count_disp = f"1 ครั้ง ({d_count} วัน)" if l_type != "ขอเข้าสาย" else f"ขอเข้าสาย 1 ครั้ง (เวลา {late_t} น.)" if late_t else "1 ครั้ง"
        status_disp = "อนุมัติแล้ว" if l.get("status") == "approved" else ("ไม่อนุมัติ" if l.get("status") == "rejected" else "รออนุมัติ")

        rows_html += f"""
        <tr>
            <td style="text-align: center;">{idx}</td>
            <td>{t_name}</td>
            <td style="text-align: center;"><strong>{l_type}</strong></td>
            <td>{date_disp}</td>
            <td style="text-align: center;">{count_disp}</td>
            <td>{reason}</td>
            <td style="text-align: center;">{phone}</td>
            <td style="text-align: center;">{status_disp}</td>
        </tr>
        """

    if not rows_html:
        rows_html = '<tr><td colspan="8" style="text-align: center; padding: 20px; color: #666;">ไม่พบรายการขอลาหรือขอเข้าสายในช่วงเวลาดังกล่าว</td></tr>'

    html = f"""<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="utf-8">
<title>แบบรายงานข้อมูลสถิติการลาและการขอเข้าสาย - {school_name}</title>
<style>
  @page {{ size: A4 landscape; margin: 12mm 15mm; }}
  body {{ font-family: 'Sarabun', 'TH Sarabun New', Tahoma, sans-serif; font-size: 11pt; line-height: 1.4; color: #1e293b; margin: 0; padding: 20px; background: #fff; }}
  .header {{ text-align: center; margin-bottom: 16px; border-bottom: 2px solid #0f172a; padding-bottom: 12px; }}
  .school-title {{ font-size: 16pt; font-weight: bold; color: #0f172a; margin-bottom: 4px; }}
  .sub-title {{ font-size: 13pt; font-weight: bold; color: #334155; margin-bottom: 6px; }}
  .meta {{ font-size: 10.5pt; color: #64748b; }}
  .summary-bar {{ display: flex; gap: 12px; justify-content: space-between; margin-bottom: 16px; }}
  .sum-card {{ flex: 1; border: 1px solid #cbd5e1; border-radius: 8px; padding: 8px 12px; background: #f8fafc; text-align: center; }}
  .sum-title {{ font-size: 10pt; font-weight: bold; color: #475569; }}
  .sum-val {{ font-size: 14pt; font-weight: 900; margin-top: 2px; }}
  table {{ width: 100%; border-collapse: collapse; margin-bottom: 24px; }}
  th, td {{ border: 1px solid #94a3b8; padding: 6px 8px; font-size: 10pt; vertical-align: middle; }}
  th {{ background-color: #f1f5f9; font-weight: bold; color: #0f172a; text-align: center; }}
  tr:nth-child(even) {{ background-color: #f8fafc; }}
  .signatures {{ margin-top: 35px; display: flex; justify-content: space-between; page-break-inside: avoid; }}
  .sig-block {{ text-align: center; width: 42%; }}
  .sig-line {{ margin-top: 45px; border-bottom: 1px dotted #475569; width: 85%; margin-left: auto; margin-right: auto; }}
  .no-print {{ margin-bottom: 15px; text-align: right; }}
  .print-btn {{ font-family: inherit; font-size: 11pt; padding: 8px 20px; background: #1b0b38; color: #ffd95a; border: 1px solid #eab308; border-radius: 6px; cursor: pointer; font-weight: bold; }}
  @media print {{
    .no-print {{ display: none !important; }}
    body {{ padding: 0; }}
  }}
</style>
</head>
<body>
<div class="no-print">
  <button class="print-btn" onclick="window.print()">🖨️ สั่งพิมพ์รายงาน / บันทึกเป็น PDF (Print / Save as PDF)</button>
</div>

<div class="header">
  <div class="school-title">{school_name}</div>
  <div class="sub-title">แบบรายงานข้อมูลสถิติการลาและการขอเข้าสายของข้าราชการครูและบุคลากรทางการศึกษา</div>
  <div class="meta">เป้าหมาย: <strong>{target_teacher_name}</strong> • ข้อมูล ณ วันที่ {now_th} • ออกรายงานโดย: นางสาว{head_name or 'หัวหน้างานบุคคล'} (หัวหน้างานบุคคล)</div>
</div>

<div class="summary-bar">
  <div class="sum-card" style="border-left: 4px solid #d97706;">
    <div class="sum-title">ลากิจสะสม</div>
    <div class="sum-val" style="color: #b45309;">{kij_times} ครั้ง ({kij_days} วัน)</div>
  </div>
  <div class="sum-card" style="border-left: 4px solid #dc2626;">
    <div class="sum-title">ลาป่วยสะสม</div>
    <div class="sum-val" style="color: #b91c1c;">{puay_times} ครั้ง ({puay_days} วัน)</div>
  </div>
  <div class="sum-card" style="border-left: 4px solid #4f46e5;">
    <div class="sum-title">ขอเข้าสายสะสม</div>
    <div class="sum-val" style="color: #4338ca;">{late_times} ครั้ง</div>
  </div>
  <div class="sum-card" style="border-left: 4px solid #059669;">
    <div class="sum-title">รวมการลาทั้งหมด</div>
    <div class="sum-val" style="color: #047857;">{total_times} ครั้ง ({total_days} วัน)</div>
  </div>
</div>

<table>
  <thead>
    <tr>
      <th style="width: 5%;">ลำดับ</th>
      <th style="width: 18%;">ชื่อ - นามสกุลครู</th>
      <th style="width: 10%;">ประเภท</th>
      <th style="width: 18%;">ช่วงวันที่ลา / วันที่ขอเข้าสาย</th>
      <th style="width: 13%;">จำนวน (ครั้ง/วัน)</th>
      <th style="width: 20%;">เหตุผลในการขอลา / ขอเข้าสาย</th>
      <th style="width: 10%;">เบอร์ติดต่อ</th>
      <th style="width: 6%;">สถานะ</th>
    </tr>
  </thead>
  <tbody>
    {rows_html}
  </tbody>
</table>

<div class="signatures">
  <div class="sig-block">
    <div>ขอรับรองว่าข้อมูลถูกต้องตามความเป็นจริง</div>
    <div class="sig-line"></div>
    <div style="margin-top: 6px;">( {head_name or "." * 40} )</div>
    <div style="font-size: 10pt; color: #475569;">ตำแหน่ง หัวหน้างานบุคคล</div>
    <div style="font-size: 10pt; color: #64748b; margin-top: 2px;">วันที่ ........ เดือน .................... พ.ศ. ...........</div>
  </div>
  <div class="sig-block">
    <div>ทราบและพิจารณาอนุมัติ</div>
    <div class="sig-line"></div>
    <div style="margin-top: 6px;">( {director_name} )</div>
    <div style="font-size: 10pt; color: #475569;">ตำแหน่ง ผู้อำนวยการ{school_name}</div>
    <div style="font-size: 10pt; color: #64748b; margin-top: 2px;">วันที่ ........ เดือน .................... พ.ศ. ...........</div>
  </div>
</div>

</body>
</html>"""
    return HTMLResponse(content=html)


# Mount Flutter Web frontend if built
WEB_DIR = Path(__file__).resolve().parent / "frontend" / "build" / "web"
if WEB_DIR.exists() and (WEB_DIR / "index.html").exists():
    def _serve_index_with_title():
        """Serve index.html with the saved web title and school logo favicon."""
        import html as _html
        raw = (WEB_DIR / "index.html").read_text(encoding="utf-8")
        title = _html.escape(_get_web_title())
        raw = re.sub(r"<title>.*?</title>", f"<title>{title}</title>", raw, count=1, flags=re.S)
        
        # Inject school logo favicon so browser tab displays school logo. The app reads this same URL from
        # #app-favicon for its own logo, so the browser downloads the logo once for the tab and the app.
        logo_ts = get_app_setting("school_logo_updated", "0", db_path="school_archive.db")
        favicon_url = _school_logo_url() or f"/favicon.png?v={logo_ts}"

        raw = re.sub(r'\s*<link\s+rel="shortcut icon"[^>]*>', "", raw, flags=re.S)  # one icon link, one URL
        raw = re.sub(
            r'<link\s+rel="icon"[^>]*>',
            f'<link rel="icon" type="image/png" href="{favicon_url}" id="app-favicon"/>',
            raw,
            count=1,
            flags=re.S
        )
        raw = re.sub(
            r'<link\s+rel="apple-touch-icon"[^>]*>',
            f'<link rel="apple-touch-icon" href="{favicon_url}">',
            raw,
            count=1,
            flags=re.S
        )
        return Response(
            content=raw,
            media_type="text/html; charset=utf-8",
            headers={"Cache-Control": "no-cache, no-store, must-revalidate"},
        )

    @app.get("/favicon.ico", include_in_schema=False)
    @app.get("/favicon.png", include_in_schema=False)
    def serve_favicon():
        logo_path = get_app_setting("school_logo_path", "", db_path="school_archive.db")
        if logo_path and Path(logo_path).exists():
            p = Path(logo_path)
            media_type = "image/svg+xml" if p.suffix.lower() == ".svg" else "image/png"
            return FileResponse(p, media_type=media_type, headers={"Cache-Control": "no-cache, must-revalidate"})
        default_fav = WEB_DIR / "favicon.png"
        if default_fav.exists():
            return FileResponse(default_fav, media_type="image/png")
        return Response(status_code=404)

    @app.get("/", include_in_schema=False)
    def web_index_root():
        return _serve_index_with_title()

    @app.get("/index.html", include_in_schema=False)
    def web_index_file():
        return _serve_index_with_title()

    class _PrecompressedStatic(StaticFiles):
        """
        The Flutter build: each text file is gzipped once and kept next to it (made again when the build changes)
        instead of GZipMiddleware compressing the 4 MB main.dart.js on every request. Everything is revalidated
        (ETag -> 304) so a rebuilt app reaches every browser at the next load.
        """
        GZ_SUFFIXES = {".js", ".mjs", ".css", ".json", ".html", ".wasm", ".svg", ".otf", ".ttf", ".txt", ".map", ".bin", ".frag"}

        @staticmethod
        def gz_for(path: Path, stat_result) -> Optional[Path]:
            import gzip as _gzip
            gz = path.with_name(path.name + ".gz")
            try:
                if gz.exists() and gz.stat().st_mtime >= stat_result.st_mtime:
                    return gz
                tmp = path.with_name(path.name + ".gz.tmp")
                with open(path, "rb") as src, _gzip.open(tmp, "wb", compresslevel=9) as dst:
                    shutil.copyfileobj(src, dst)
                os.replace(tmp, gz)
                return gz
            except OSError:
                return None

        def file_response(self, full_path, stat_result, scope, status_code=200):
            from starlette.datastructures import Headers
            from starlette.staticfiles import NotModifiedResponse
            import mimetypes
            request_headers = Headers(scope=scope)
            path = Path(full_path)
            if (path.suffix.lower() in self.GZ_SUFFIXES and stat_result.st_size > 1024
                    and "gzip" in request_headers.get("accept-encoding", "")):
                gz = self.gz_for(path, stat_result)
                if gz is not None:
                    media_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
                    if media_type.startswith("text/") or media_type in ("application/javascript", "application/json"):
                        media_type += "; charset=utf-8"
                    response = FileResponse(gz, status_code=status_code, stat_result=os.stat(gz), media_type=media_type,
                                            headers={"Content-Encoding": "gzip", "Vary": "Accept-Encoding", "Cache-Control": "no-cache"})
                    if self.is_not_modified(response.headers, request_headers):
                        return NotModifiedResponse(response.headers)
                    return response
            response = super().file_response(full_path, stat_result, scope, status_code)
            response.headers["Cache-Control"] = "no-cache"
            return response

    def _pregzip_web_build():
        """Compress the build in the background at startup so the first visitor after a rebuild does not wait."""
        for f in WEB_DIR.rglob("*"):
            if f.is_file() and f.suffix.lower() in _PrecompressedStatic.GZ_SUFFIXES and f.stat().st_size > 1024:
                _PrecompressedStatic.gz_for(f, f.stat())

    if os.environ.get("SCHOOL_NO_BACKGROUND") != "1":
        threading.Thread(target=_pregzip_web_build, name="pregzip-web", daemon=True).start()

    app.mount("/", _PrecompressedStatic(directory=str(WEB_DIR), html=True), name="static_web")
else:
    @app.get("/")
    def root():
        return {"message": "SGS Processing API is running. Ready for Flutter UI."}

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
