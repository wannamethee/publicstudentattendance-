# -*- coding: utf-8 -*-
"""
Backup and Archive Manager for School Transcription System.
Handles full database snapshots, semester archives, manifest indexing,
and restoration across multi-year school operations.
"""

import os
import sqlite3
import json
import shutil
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Any, Optional

BACKUPS_DIR = Path(__file__).resolve().parent / "backups"
MANIFEST_PATH = BACKUPS_DIR / "manifest.json"
DEFAULT_DB_PATH = Path(__file__).resolve().parent / "school_archive.db"


def _ensure_dir():
    BACKUPS_DIR.mkdir(parents=True, exist_ok=True)
    if not MANIFEST_PATH.exists():
        with open(MANIFEST_PATH, "w", encoding="utf-8") as f:
            json.dump([], f, ensure_ascii=False, indent=2)


def _load_manifest() -> List[Dict[str, Any]]:
    _ensure_dir()
    try:
        with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []


def _save_manifest(items: List[Dict[str, Any]]):
    _ensure_dir()
    with open(MANIFEST_PATH, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=2)


def inspect_backup_db(db_file: Path) -> Dict[str, Any]:
    """Inspects a SQLite backup file and returns counts and contained semesters."""
    info = {
        "courses_count": 0,
        "grades_count": 0,
        "students_count": 0,
        "semesters": [],
    }
    if not db_file.exists():
        return info

    try:
        conn = sqlite3.connect(str(db_file))
        cursor = conn.cursor()
        
        # Check tables
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table';")
        tables = [r[0] for r in cursor.fetchall()]

        if "courses" in tables:
            cursor.execute("SELECT count(*) FROM courses;")
            info["courses_count"] = cursor.fetchone()[0]
            cursor.execute("SELECT DISTINCT term, year FROM courses WHERE term IS NOT NULL AND year IS NOT NULL;")
            info["semesters"] = [f"{r[0]}/{r[1]}" for r in cursor.fetchall()]

        if "grades_history" in tables:
            cursor.execute("SELECT count(*) FROM grades_history;")
            info["grades_count"] = cursor.fetchone()[0]

        if "students" in tables:
            cursor.execute("SELECT count(*) FROM students;")
            info["students_count"] = cursor.fetchone()[0]

        conn.close()
    except Exception as e:
        print(f"Error inspecting backup {db_file}: {e}")
    return info


def list_backups() -> List[Dict[str, Any]]:
    """List all available backups, auto-syncing with the filesystem."""
    _ensure_dir()
    manifest = _load_manifest()
    manifest_by_id = {item.get("id"): item for item in manifest}

    # Scan directory for any .db files
    existing_files = list(BACKUPS_DIR.glob("*.db"))
    updated_manifest = []

    for file_path in existing_files:
        bid = file_path.stem
        file_size = file_path.stat().st_size
        mtime = datetime.fromtimestamp(file_path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")

        if bid in manifest_by_id:
            item = manifest_by_id[bid]
            item["size_bytes"] = file_size
            item["size_mb"] = round(file_size / (1024 * 1024), 2)
            updated_manifest.append(item)
        else:
            # Unindexed file found on disk, auto-index
            inspected = inspect_backup_db(file_path)
            auto_item = {
                "id": bid,
                "filename": file_path.name,
                "label": f"ข้อมูลสำรอง {file_path.stem}",
                "term": "",
                "year": "",
                "backup_type": "full",
                "created_at": mtime,
                "size_bytes": file_size,
                "size_mb": round(file_size / (1024 * 1024), 2),
                **inspected
            }
            updated_manifest.append(auto_item)

    # Sort newest first
    updated_manifest.sort(key=lambda x: x.get("created_at", ""), reverse=True)
    _save_manifest(updated_manifest)
    return updated_manifest


def create_backup(
    label: Optional[str] = None,
    term: Optional[str] = None,
    year: Optional[str] = None,
    backup_type: str = "full",
    db_path: str = str(DEFAULT_DB_PATH)
) -> Dict[str, Any]:
    """
    Creates an atomic SQLite backup of the active database into backups/ directory.
    """
    _ensure_dir()
    now = datetime.now()
    timestamp_str = now.strftime("%Y%m%d_%H%M%S")
    backup_id = f"backup_{timestamp_str}"
    filename = f"{backup_id}.db"
    dest_path = BACKUPS_DIR / filename

    if not label:
        if term and year:
            label = f"ปีการศึกษา {year} ภาคเรียนที่ {term}"
        else:
            label = f"สำรองข้อมูลระบบทั้งหมด ({now.strftime('%d/%m/%Y %H:%M')})"

    # Atomic SQLite backup
    src_conn = sqlite3.connect(db_path)
    dst_conn = sqlite3.connect(str(dest_path))
    with dst_conn:
        src_conn.backup(dst_conn)
    dst_conn.close()
    src_conn.close()

    # Inspect stats
    inspected = inspect_backup_db(dest_path)
    file_size = dest_path.stat().st_size

    record = {
        "id": backup_id,
        "filename": filename,
        "label": label,
        "term": str(term) if term else "",
        "year": str(year) if year else "",
        "backup_type": backup_type,
        "created_at": now.strftime("%Y-%m-%d %H:%M:%S"),
        "size_bytes": file_size,
        "size_mb": round(file_size / (1024 * 1024), 2),
        **inspected
    }

    manifest = _load_manifest()
    manifest.insert(0, record)
    _save_manifest(manifest)

    return record


def restore_backup(
    backup_id: str,
    mode: str = "full",
    target_term: Optional[str] = None,
    target_year: Optional[str] = None,
    src_term: Optional[str] = None,
    src_year: Optional[str] = None,
    db_path: str = str(DEFAULT_DB_PATH)
) -> Dict[str, Any]:
    """
    Restores data from a backup.
    If mode == 'full': auto-saves a safety snapshot of current DB, then restores the backup DB.
    If mode == 'semester': extracts courses, grades, rosters from the backup DB and merges/inserts into active DB for (target_term, target_year).
    """
    _ensure_dir()
    backup_file = BACKUPS_DIR / f"{backup_id}.db"
    if not backup_file.exists():
        # Try matching filename directly
        matches = list(BACKUPS_DIR.glob(f"*{backup_id}*.db"))
        if matches:
            backup_file = matches[0]
        else:
            raise FileNotFoundError(f"ไม่พบไฟล์สำรองข้อมูลรหัส {backup_id}")

    if mode == "full":
        # Create safety backup of active DB first!
        safety_time = datetime.now().strftime("%Y%m%d_%H%M%S")
        safety_id = f"auto_safety_before_restore_{safety_time}"
        create_backup(
            label=f"สำรองอัตโนมัติก่อนกู้คืนข้อมูล ({datetime.now().strftime('%d/%m/%Y %H:%M')})",
            db_path=db_path
        )

        # Restore: Copy backup file over active DB atomically
        src_conn = sqlite3.connect(str(backup_file))
        dst_conn = sqlite3.connect(db_path)
        with dst_conn:
            src_conn.backup(dst_conn)
        dst_conn.close()
        src_conn.close()

        return {
            "status": "success",
            "message": f"กู้คืนข้อมูลทั้งหมดจาก '{backup_file.name}' เรียบร้อยแล้ว (ระบบได้สำรองข้อมูลก่อนหน้าไว้ให้เพื่อความปลอดภัย)",
            "mode": "full",
            "safety_backup_id": safety_id
        }

    elif mode == "semester":
        # Import semester data from backup into active DB
        if not target_term or not target_year:
            raise ValueError("ต้องระบุภาคเรียน (term) และปีการศึกษา (year) ปลายทางสำหรับการนำเข้า")

        s_term = str(src_term) if src_term else str(target_term)
        s_year = str(src_year) if src_year else str(target_year)
        t_term = str(target_term)
        t_year = str(target_year)

        b_conn = sqlite3.connect(str(backup_file))
        b_conn.row_factory = sqlite3.Row
        b_cur = b_conn.cursor()

        a_conn = sqlite3.connect(db_path)
        a_conn.row_factory = sqlite3.Row
        a_cur = a_conn.cursor()

        # 1. Fetch courses
        b_cur.execute(
            "SELECT * FROM courses WHERE term = ? AND year = ?;",
            (s_term, s_year)
        )
        b_courses = [dict(r) for r in b_cur.fetchall()]

        # 2. Fetch grades_history
        b_cur.execute(
            "SELECT * FROM grades_history WHERE term = ? AND year = ?;",
            (s_term, s_year)
        )
        b_grades = [dict(r) for r in b_cur.fetchall()]

        # 3. Fetch class_students
        b_cur.execute(
            "SELECT * FROM class_students WHERE term = ? AND year = ?;",
            (s_term, s_year)
        )
        b_class_students = [dict(r) for r in b_cur.fetchall()]

        # 4. Fetch timetables
        b_timetables = []
        try:
            b_cur.execute(
                "SELECT * FROM teacher_timetables WHERE term = ? AND year = ?;",
                (s_term, s_year)
            )
            b_timetables = [dict(r) for r in b_cur.fetchall()]
        except Exception:
            pass

        # 5. Fetch students info for all students in grades/class_students
        all_sids = set([g.get("student_id") for g in b_grades if g.get("student_id")])
        all_sids.update([c.get("student_id") for c in b_class_students if c.get("student_id")])
        
        b_students = []
        if all_sids:
            placeholders = ",".join("?" * len(all_sids))
            b_cur.execute(f"SELECT * FROM students WHERE student_id IN ({placeholders});", list(all_sids))
            b_students = [dict(r) for r in b_cur.fetchall()]

        b_conn.close()

        if not b_courses and not b_grades and not b_class_students:
            a_conn.close()
            return {
                "status": "warning",
                "message": f"ไม่พบข้อมูลของเทอม {s_term}/{s_year} ในไฟล์สำรองนี้",
                "imported_courses": 0,
                "imported_grades": 0,
            }

        # Clear existing data in target semester before importing
        a_cur.execute("DELETE FROM courses WHERE term = ? AND year = ?;", (t_term, t_year))
        a_cur.execute("DELETE FROM grades_history WHERE term = ? AND year = ?;", (t_term, t_year))
        a_cur.execute("DELETE FROM class_students WHERE term = ? AND year = ?;", (t_term, t_year))
        try:
            a_cur.execute("DELETE FROM teacher_timetables WHERE term = ? AND year = ?;", (t_term, t_year))
        except Exception:
            pass

        # Insert Students (upsert)
        for s in b_students:
            a_cur.execute("""
                INSERT INTO students (student_id, student_no, prefix, first_name, last_name, class_level, national_id, birth_date)
                VALUES (:student_id, :student_no, :prefix, :first_name, :last_name, :class_level, :national_id, :birth_date)
                ON CONFLICT(student_id) DO UPDATE SET
                    student_no=excluded.student_no,
                    first_name=excluded.first_name,
                    last_name=excluded.last_name,
                    class_level=excluded.class_level;
            """, s)

        # Insert Courses (remapped to target_term, target_year)
        courses_imported = 0
        for c in b_courses:
            c["term"] = t_term
            c["year"] = t_year
            c_cols = [k for k in c.keys() if k != "id"]
            placeholders = ", ".join([f":{k}" for k in c_cols])
            col_names = ", ".join(c_cols)
            a_cur.execute(f"INSERT OR REPLACE INTO courses ({col_names}) VALUES ({placeholders});", c)
            courses_imported += 1

        # Insert Grades
        grades_imported = 0
        for g in b_grades:
            g["term"] = t_term
            g["year"] = t_year
            g_cols = [k for k in g.keys() if k != "id"]
            placeholders = ", ".join([f":{k}" for k in g_cols])
            col_names = ", ".join(g_cols)
            a_cur.execute(f"INSERT OR REPLACE INTO grades_history ({col_names}) VALUES ({placeholders});", g)
            grades_imported += 1

        # Insert Class Students
        for cs in b_class_students:
            cs["term"] = t_term
            cs["year"] = t_year
            cs_cols = [k for k in cs.keys() if k != "id"]
            placeholders = ", ".join([f":{k}" for k in cs_cols])
            col_names = ", ".join(cs_cols)
            a_cur.execute(f"INSERT OR REPLACE INTO class_students ({col_names}) VALUES ({placeholders});", cs)

        # Insert Timetables
        for tt in b_timetables:
            tt["term"] = t_term
            tt["year"] = t_year
            tt_cols = [k for k in tt.keys() if k != "id"]
            placeholders = ", ".join([f":{k}" for k in tt_cols])
            col_names = ", ".join(tt_cols)
            a_cur.execute(f"INSERT OR REPLACE INTO teacher_timetables ({col_names}) VALUES ({placeholders});", tt)

        a_conn.commit()
        a_conn.close()

        return {
            "status": "success",
            "message": f"นำเข้าข้อมูลภาคเรียน {t_term}/{t_year} จากคลังสำรองสำเร็จ (วิชา: {courses_imported}, ผลคะแนน: {grades_imported})",
            "imported_courses": courses_imported,
            "imported_grades": grades_imported,
            "target_term": t_term,
            "target_year": t_year
        }

    else:
        raise ValueError(f"Unknown restore mode: {mode}")


def delete_backup(backup_id: str) -> bool:
    """Deletes a backup file and removes it from the manifest."""
    _ensure_dir()
    manifest = _load_manifest()
    new_manifest = [m for m in manifest if m.get("id") != backup_id]
    _save_manifest(new_manifest)

    backup_file = BACKUPS_DIR / f"{backup_id}.db"
    if backup_file.exists():
        backup_file.unlink()
        return True
    return False
