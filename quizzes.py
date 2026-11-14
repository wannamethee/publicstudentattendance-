"""
แบบทดสอบย่อย / แบบทดสอบหลังเรียน.

A course teacher makes any number of short quizzes for a course (ปรนัย and เติมตัวเลข only, so every one is
graded automatically). Each quiz may be linked to one of the eight indicator columns (ช่อง 1-8) of the scores
page. A column linked to several quizzes adds up the raw points of all of them (the best try of each, a quiz not
taken counts 0) and scales the sum to the column's full score; the scores page shows that column as automatic.
The teacher may still type over one student's cell there (e.g. to add marks): that cell is kept in scores_json
"unit_manual" and is never overwritten by quiz results until the teacher clears it (then it is automatic again).

When a student may sit a quiz is the teacher's choice per quiz: a date window (start / end, either may be empty)
and, optionally, only during this course's class period in the student's timetable. The teacher also sets how
many tries a student gets (0 = unlimited); the best try counts.
"""
import json
import random
import threading
from datetime import datetime, timedelta
from typing import Any, Callable, Dict, List, Optional

import database
import exams
from exams import _fmt, _parse


def now() -> datetime:
    return exams.now()   # one clock for exams and quizzes (tests move it)

DB_PATH = "school_archive.db"
SLOTS = 8
MAX_ATTEMPTS_LIMIT = 20
AUTO_TYPES = ("choice", "number", "text", "truefalse", "match", "cloze")

_ready = 0
_ready_lock = threading.Lock()
_lock = threading.Lock()


SCHEMA = """
                CREATE TABLE IF NOT EXISTS quizzes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uid TEXT NOT NULL UNIQUE,
                    course_code TEXT NOT NULL, term TEXT NOT NULL, year TEXT NOT NULL,
                    title TEXT NOT NULL,
                    unit_slot INTEGER,                      -- 0..7 = ช่อง 1..8 of the scores page, NULL = not linked
                    questions_json TEXT,
                    duration_min INTEGER,
                    start_at TEXT, end_at TEXT,
                    class_only INTEGER NOT NULL DEFAULT 0,  -- only during this course's period in the timetable
                    max_attempts INTEGER NOT NULL DEFAULT 1, -- 0 = unlimited
                    ready INTEGER NOT NULL DEFAULT 0,
                    mode TEXT NOT NULL DEFAULT 'quiz',       -- 'quiz' = made here, 'link' = an outside link (Google Form ...)
                    link_url TEXT,
                    created_by TEXT, created_at TEXT, updated_by TEXT, updated_at TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_quizzes_course ON quizzes(course_code, term, year);
                CREATE TABLE IF NOT EXISTS quiz_attempts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    quiz_id INTEGER NOT NULL REFERENCES quizzes(id) ON DELETE CASCADE,
                    student_id TEXT NOT NULL,
                    attempt_no INTEGER NOT NULL,
                    started_at TEXT NOT NULL, deadline_at TEXT NOT NULL, submitted_at TEXT,
                    paper_json TEXT NOT NULL, answers_json TEXT,
                    correct INTEGER, total INTEGER, earned REAL, max_points REAL,
                    UNIQUE (quiz_id, student_id, attempt_no)
                );
                CREATE INDEX IF NOT EXISTS idx_quiz_attempts_student ON quiz_attempts(student_id);
                """


def ensure(conn) -> None:
    """Creates the quiz tables on this connection if missing (school_data import/export uses its own connection).
    One statement at a time: executescript would commit the caller's open transaction."""
    for stmt in SCHEMA.split(";"):
        stmt = " ".join(ln.split("--")[0] for ln in stmt.splitlines()).strip()
        if stmt:
            conn.execute(stmt)
    have = {r[1] for r in conn.execute("PRAGMA table_info(quizzes);")}
    for col, decl in (("mode", "TEXT NOT NULL DEFAULT 'quiz'"), ("link_url", "TEXT")):
        if col not in have:
            conn.execute(f"ALTER TABLE quizzes ADD COLUMN {col} {decl};")


def _conn(db_path: str):
    global _ready
    conn = database.get_connection(db_path)
    if _ready != database.INIT_EPOCH[0] + 1:
        with _ready_lock:
            ensure(conn)
            _ready = database.INIT_EPOCH[0] + 1
    return conn


def _num(v: float):
    v = round(float(v), 2)
    return int(v) if v.is_integer() else v


# ---------------------------------------------------------------- questions

def clean_quiz_questions(raw: Any) -> List[Dict[str, Any]]:
    qs = exams.clean_questions(raw)
    for n, q in enumerate(qs, start=1):
        if q["type"] not in AUTO_TYPES:
            raise ValueError(f"ข้อ {n}: แบบทดสอบย่อยตรวจอัตโนมัติ ใช้ข้อเขียนตอบ ถ่ายภาพส่ง ไม่ได้")
    return qs


def _points(qs: List[Dict[str, Any]]) -> float:
    return sum(exams.question_points(q) for q in qs)


# ---------------------------------------------------------------- the scores page column (ช่อง 1-8)

_max_cache: Dict[tuple, tuple] = {}


def forget_unit_max(course_code: str, term: str, year: str) -> None:
    """The teacher saved the scores page (full scores may have changed)."""
    for k in [k for k in _max_cache if k[:3] == (course_code, str(term), str(year))]:
        _max_cache.pop(k, None)


def unit_max(course_code: str, term: str, year: str, db_path: str = DB_PATH) -> List[Optional[float]]:
    """Full score of ช่อง 1-8 as the scores page shows it; cached briefly (reading it opens the ปพ.5 file
    and a whole class submits at once)."""
    key = (course_code, str(term), str(year), db_path)
    hit = _max_cache.get(key)
    if hit and (now() - hit[0]).total_seconds() < 120:
        return list(hit[1])
    from course_importer import get_course_scores_sheet
    sheet = get_course_scores_sheet(course_code, term, year, db_path=db_path) or {}
    um = list(((sheet.get("score_config") or {}).get("unit_max")) or [])
    um = (um + [None] * SLOTS)[:SLOTS]
    _max_cache[key] = (now(), um)
    return list(um)


def _check_slot(slot: Any, course_code: str, term: str, year: str, db_path: str) -> Optional[int]:
    if slot in (None, "", -1):
        return None
    try:
        slot = int(slot)
    except (TypeError, ValueError):
        raise ValueError("ช่องคะแนนไม่ถูกต้อง")
    if not 0 <= slot < SLOTS:
        raise ValueError("เลือกช่องคะแนน 1–8")
    full = unit_max(course_code, term, year, db_path)[slot]
    if not full:
        raise ValueError(f"ช่อง {slot + 1} ยังไม่ได้ตั้งคะแนนเต็ม — ตั้งคะแนนเต็มช่องนี้ในหน้าบันทึกคะแนนก่อน")
    return slot


def _best(conn, quiz_ids: List[int], student_id: Optional[str] = None) -> Dict[tuple, float]:
    """(quiz_id, student_id) -> best points earned in a submitted try"""
    if not quiz_ids:
        return {}
    q = (f"SELECT quiz_id, student_id, MAX(earned) FROM quiz_attempts WHERE submitted_at IS NOT NULL "
         f"AND quiz_id IN ({','.join('?' * len(quiz_ids))})")
    args: List[Any] = list(quiz_ids)
    if student_id:
        q += " AND student_id = ?"
        args.append(student_id)
    return {(r[0], r[1]): float(r[2] or 0) for r in conn.execute(q + " GROUP BY quiz_id, student_id;", args)}


def slot_scores(course_code: str, term: str, year: str, db_path: str = DB_PATH,
                student_id: Optional[str] = None) -> Dict[int, Dict[str, Any]]:
    """
    slot -> {quizzes, full, points_max, scores: {student_id: score}} for every linked column. The sum of the
    best points of each linked quiz (0 when not taken) over the sum of their full points, of the column's full score.
    """
    um = unit_max(course_code, term, year, db_path)
    with _conn(db_path) as conn:
        quizzes = [dict(r) for r in conn.execute(
            "SELECT id, title, unit_slot, questions_json FROM quizzes WHERE course_code = ? AND term = ? AND year = ? "
            "AND ready = 1 AND unit_slot IS NOT NULL AND COALESCE(mode, 'quiz') = 'quiz' ORDER BY id;", (course_code, str(term), str(year)))]
        students = [s["student_id"] for s in exams._enrolled(conn, course_code, term, year)]
        if student_id:
            students = [s for s in students if s == student_id]
        best = _best(conn, [q["id"] for q in quizzes], student_id)
    out: Dict[int, Dict[str, Any]] = {}
    for q in quizzes:
        q["points"] = _points(json.loads(q["questions_json"] or "[]"))
        slot = int(q["unit_slot"])
        if not (0 <= slot < SLOTS) or not q["points"]:
            continue
        s = out.setdefault(slot, {"quizzes": [], "full": um[slot], "points_max": 0.0, "scores": {}})
        s["quizzes"].append({"id": q["id"], "title": q["title"], "points": _num(q["points"])})
        s["points_max"] += q["points"]
    for slot, s in out.items():
        full = float(s["full"] or 0)
        for sid in students:
            earned = sum(best.get((q["id"], sid), 0.0) for q in s["quizzes"])
            s["scores"][sid] = _num(exams.scale_score(earned, s["points_max"], full)) if full else None
        s["points_max"] = _num(s["points_max"])
    return out


def manual_slots(sc: Any) -> set:
    """Columns (0..7) of one student's scores_json the teacher typed over on the scores page ("unit_manual")."""
    out = set()
    for v in ((sc or {}).get("unit_manual") or []) if isinstance(sc, dict) else []:
        try:
            i = int(v)
        except (TypeError, ValueError):
            continue
        if 0 <= i < SLOTS:
            out.add(i)
    return out


SCORES_CHANGED_HOOKS: List[Callable[[str, str, List[str]], None]] = exams.SCORES_CHANGED_HOOKS


def apply_scores(course_code: str, term: str, year: str, db_path: str = DB_PATH,
                 student_id: Optional[str] = None, notify: bool = True) -> int:
    """Writes the linked columns into grades_history (only values that differ); the ปพ.5 file follows via the hooks."""
    slots = slot_scores(course_code, term, year, db_path, student_id)
    if not slots:
        return 0
    sheet_units: Optional[Dict[str, list]] = None
    changed = 0
    with _conn(db_path) as conn:
        sids = set()
        for s in slots.values():
            sids |= set(s["scores"])
        for sid in sorted(sids):
            row = conn.execute("SELECT scores_json FROM grades_history WHERE student_id = ? AND course_code = ? AND term = ? AND year = ?;",
                               (sid, course_code, str(term), str(year))).fetchone()
            if not row:
                continue
            try:
                sc = json.loads(row["scores_json"] or "{}") or {}
            except Exception:
                sc = {}
            if "units" not in sc:
                # the scores page falls back to the ปพ.5 file's columns: start from what it shows, not from blanks
                if sheet_units is None:
                    from course_importer import get_course_scores_sheet
                    sheet = get_course_scores_sheet(course_code, term, year, db_path=db_path) or {}
                    sheet_units = {st["student_id"]: st.get("units") or [] for st in sheet.get("students") or []}
                units = list(sheet_units.get(sid) or [])
            else:
                units = list(sc.get("units") or [])
            units = (units + [None] * SLOTS)[:SLOTS]
            before = list(units)
            manual = manual_slots(sc)
            for slot, s in slots.items():
                if slot in manual:
                    continue  # the teacher typed this cell on the scores page: it stays until they clear it
                if sid in s["scores"] and s["scores"][sid] is not None:
                    units[slot] = s["scores"][sid]
            if units != before or "units" not in sc:
                sc["units"] = units
                conn.execute("UPDATE grades_history SET scores_json = ? WHERE student_id = ? AND course_code = ? AND term = ? AND year = ?;",
                             (json.dumps(sc, ensure_ascii=False), sid, course_code, str(term), str(year)))
                changed += 1
    if changed and notify:
        for hook in SCORES_CHANGED_HOOKS:
            try:
                hook(str(term), str(year), [course_code])
            except Exception as e:
                print(f"[WARN] quiz score hook failed for {course_code}: {e}")
    return changed


# ---------------------------------------------------------------- teacher side

def _row(conn, quiz_id: int):
    r = conn.execute("SELECT * FROM quizzes WHERE id = ?;", (int(quiz_id),)).fetchone()
    if not r:
        raise LookupError("ไม่พบแบบทดสอบ")
    return r


def quiz_course(quiz_id: int, db_path: str = DB_PATH) -> Dict[str, str]:
    with _conn(db_path) as conn:
        r = _row(conn, quiz_id)
    return {"course_code": r["course_code"], "term": r["term"], "year": r["year"]}


def _window(r, t: Optional[datetime] = None) -> Dict[str, Any]:
    t = t or now()
    s, e = _parse(r["start_at"]), _parse(r["end_at"])
    return {"start_at": r["start_at"], "end_at": r["end_at"],
            "not_yet": bool(s and t < s), "has_ended": bool(e and t > e)}


def _dict(r, with_questions: bool = False) -> Dict[str, Any]:
    qs = json.loads(r["questions_json"] or "[]")
    d = {"id": r["id"], "course_code": r["course_code"], "term": r["term"], "year": r["year"], "title": r["title"],
         "unit_slot": r["unit_slot"], "duration_min": r["duration_min"], "start_at": r["start_at"], "end_at": r["end_at"],
         "class_only": bool(r["class_only"]), "max_attempts": r["max_attempts"], "ready": bool(r["ready"]),
         "question_count": len(qs), "points": _num(_points(qs)), "updated_by": r["updated_by"], "updated_at": r["updated_at"],
         "mode": r["mode"] or "quiz", "link_url": r["link_url"] or ""}
    if with_questions:
        d["questions"] = qs
    return d


def list_quizzes(course_code: str, term: str, year: str, db_path: str = DB_PATH) -> Dict[str, Any]:
    finalize_expired(db_path=db_path)
    with _conn(db_path) as conn:
        rows = conn.execute("SELECT * FROM quizzes WHERE course_code = ? AND term = ? AND year = ? ORDER BY id;",
                            (course_code, str(term), str(year))).fetchall()
        done = {r[0]: r[1] for r in conn.execute(
            """SELECT a.quiz_id, COUNT(DISTINCT a.student_id) FROM quiz_attempts a JOIN quizzes q ON q.id = a.quiz_id
               WHERE q.course_code = ? AND q.term = ? AND q.year = ? AND a.submitted_at IS NOT NULL GROUP BY a.quiz_id;""",
            (course_code, str(term), str(year)))}
        enrolled = len(exams._enrolled(conn, course_code, term, year))
    items = []
    for r in rows:
        d = _dict(r)
        d.update(_window(r), submitted_count=done.get(r["id"], 0), student_count=enrolled)
        items.append(d)
    return {"quizzes": items, "unit_max": unit_max(course_code, term, year, db_path), "student_count": enrolled}


def course_quiz_counts(term: str, year: str, db_path: str = DB_PATH) -> Dict[str, Dict[str, int]]:
    """course_code -> {count, ready} for the exams page cards"""
    with _conn(db_path) as conn:
        return {r[0]: {"count": r[1], "ready": r[2] or 0} for r in conn.execute(
            "SELECT course_code, COUNT(*), SUM(ready) FROM quizzes WHERE term = ? AND year = ? GROUP BY course_code;",
            (str(term), str(year)))}


def get_quiz(quiz_id: int, db_path: str = DB_PATH) -> Dict[str, Any]:
    with _conn(db_path) as conn:
        r = _row(conn, quiz_id)
        d = _dict(r, with_questions=True)
        d["attempt_count"] = conn.execute("SELECT COUNT(DISTINCT student_id) FROM quiz_attempts WHERE quiz_id = ?;", (r["id"],)).fetchone()[0]
    return d


def save_quiz(course_code: str, term: str, year: str, data: Dict[str, Any], by: str, db_path: str = DB_PATH,
              quiz_id: Optional[int] = None) -> Dict[str, Any]:
    title = str(data.get("title") or "").strip()
    if not title:
        raise ValueError("ใส่ชื่อแบบทดสอบ")
    mode = str(data.get("mode") or "quiz")
    if mode not in ("quiz", "link"):
        raise ValueError("รูปแบบแบบทดสอบไม่ถูกต้อง")
    ready = bool(data.get("ready"))
    link = str(data.get("link_url") or "").strip()
    if mode == "link":
        # an outside form grades itself: its score is typed on the scores page, so it fills no column here
        import re
        if not re.match(r"^https?://\S+$", link):
            raise ValueError("ลิงก์ต้องขึ้นต้นด้วย http:// หรือ https://")
        qs, slot = [], None
    else:
        link = ""
        qs = clean_quiz_questions(data.get("questions"))
        if ready and not qs:
            raise ValueError("ยังไม่มีข้อสอบ (ใส่อย่างน้อย 1 ข้อ หรือยกเลิก 'เปิดให้นักเรียนเห็น')")
        slot = _check_slot(data.get("unit_slot"), course_code, term, year, db_path)
    dur = data.get("duration_min")
    dur = int(dur) if dur not in (None, "", 0) else None
    if dur is not None and not (1 <= dur <= 600):
        raise ValueError("เวลาทำต้องอยู่ระหว่าง 1–600 นาที")
    s, e = _parse(data.get("start_at")), _parse(data.get("end_at"))
    if (data.get("start_at") and not s) or (data.get("end_at") and not e):
        raise ValueError("รูปแบบวันเวลาไม่ถูกต้อง")
    if s and e and e <= s:
        raise ValueError("เวลาปิดต้องหลังเวลาเปิด")
    try:
        tries = int(data.get("max_attempts") if data.get("max_attempts") not in (None, "") else 1)
    except (TypeError, ValueError):
        raise ValueError("จำนวนครั้งที่ทำได้ต้องเป็นตัวเลข")
    if not 0 <= tries <= MAX_ATTEMPTS_LIMIT:
        raise ValueError(f"จำนวนครั้งที่ทำได้ 1–{MAX_ATTEMPTS_LIMIT} (0 = ไม่จำกัด)")
    vals = (title, slot, json.dumps(qs, ensure_ascii=False), dur, _fmt(s) if s else None, _fmt(e) if e else None,
            1 if data.get("class_only") else 0, tries, 1 if ready else 0, by, _fmt(now()), mode, link)
    with _conn(db_path) as conn:
        if quiz_id:
            old = _row(conn, quiz_id)
            if (old["course_code"], str(old["term"]), str(old["year"])) != (course_code, str(term), str(year)):
                raise PermissionError("แบบทดสอบนี้ไม่ใช่ของรายวิชานี้")
            conn.execute(
                """UPDATE quizzes SET title = ?, unit_slot = ?, questions_json = ?, duration_min = ?, start_at = ?, end_at = ?,
                          class_only = ?, max_attempts = ?, ready = ?, updated_by = ?, updated_at = ?, mode = ?, link_url = ? WHERE id = ?;""",
                vals + (int(quiz_id),))
        else:
            import uuid
            cur = conn.execute(
                """INSERT INTO quizzes (title, unit_slot, questions_json, duration_min, start_at, end_at, class_only, max_attempts,
                                        ready, updated_by, updated_at, mode, link_url, uid, course_code, term, year, created_by, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);""",
                vals + (uuid.uuid4().hex, course_code, str(term), str(year), by, _fmt(now())))
            quiz_id = cur.lastrowid
    apply_scores(course_code, term, year, db_path)
    return get_quiz(quiz_id, db_path)


def delete_quiz(quiz_id: int, db_path: str = DB_PATH) -> None:
    with _conn(db_path) as conn:
        r = _row(conn, quiz_id)
        conn.execute("DELETE FROM quiz_attempts WHERE quiz_id = ?;", (r["id"],))
        conn.execute("DELETE FROM quizzes WHERE id = ?;", (r["id"],))
    # the column keeps its last values when no quiz is linked to it any more (the teacher types it again)
    apply_scores(r["course_code"], r["term"], r["year"], db_path)


def set_links(course_code: str, term: str, year: str, links: Dict[Any, Any], by: str, db_path: str = DB_PATH) -> Dict[str, Any]:
    """From the scores page: quiz id -> column (0..7) or None."""
    clean = {}
    for k, v in (links or {}).items():
        clean[int(k)] = _check_slot(v, course_code, term, year, db_path)
    with _conn(db_path) as conn:
        for qid, slot in clean.items():
            r = _row(conn, qid)
            if (r["course_code"], str(r["term"]), str(r["year"])) != (course_code, str(term), str(year)):
                raise PermissionError("แบบทดสอบนี้ไม่ใช่ของรายวิชานี้")
            if slot is not None and (r["mode"] or "quiz") == "link":
                raise ValueError(f"\"{r['title']}\" เป็นลิงก์ภายนอก ระบบไม่รู้คะแนน จึงเชื่อมช่องไม่ได้ (ครูกรอกคะแนนเองในหน้าบันทึกคะแนน)")
            conn.execute("UPDATE quizzes SET unit_slot = ?, updated_by = ?, updated_at = ? WHERE id = ?;", (slot, by, _fmt(now()), qid))
    changed = apply_scores(course_code, term, year, db_path)
    return {**list_quizzes(course_code, term, year, db_path), "changed": changed}


def linked_slots(course_code: str, term: str, year: str, db_path: str = DB_PATH) -> Dict[str, Any]:
    """For the scores page: which columns are filled by quizzes, and every student's quiz breakdown."""
    slots = slot_scores(course_code, term, year, db_path)
    return {str(k): {"quizzes": v["quizzes"], "full": v["full"], "points_max": v["points_max"]} for k, v in slots.items()}


def quiz_results(quiz_id: int, db_path: str = DB_PATH) -> Dict[str, Any]:
    finalize_expired(db_path=db_path)
    with _conn(db_path) as conn:
        r = _row(conn, quiz_id)
        students = exams._enrolled(conn, r["course_code"], r["term"], r["year"])
        tries: Dict[str, List[Any]] = {}
        for a in conn.execute("SELECT * FROM quiz_attempts WHERE quiz_id = ? ORDER BY attempt_no;", (r["id"],)):
            tries.setdefault(a["student_id"], []).append(a)
    rows = []
    for st in students:
        mine = tries.get(st["student_id"], [])
        done = [a for a in mine if a["submitted_at"]]
        best = max(done, key=lambda a: (a["earned"] or 0)) if done else None
        status = "ยังไม่ทำ" if not mine else ("กำลังทำ" if any(not a["submitted_at"] for a in mine) else "ส่งแล้ว")
        rows.append({**st, "status": status, "tries": len(done),
                     "best": _num(best["earned"] or 0) if best else None,
                     "max_points": _num(best["max_points"] or 0) if best else None,
                     "last_at": done[-1]["submitted_at"] if done else None,
                     "history": [_num(a["earned"] or 0) for a in done]})
    return {"quiz": _dict(r), "students": rows}


def reset_attempts(quiz_id: int, student_id: str, db_path: str = DB_PATH) -> bool:
    """Clears one student's tries of this quiz (they may sit it again); the column is recomputed."""
    with _conn(db_path) as conn:
        r = _row(conn, quiz_id)
        n = conn.execute("DELETE FROM quiz_attempts WHERE quiz_id = ? AND student_id = ?;", (r["id"], student_id)).rowcount
    if n:
        apply_scores(r["course_code"], r["term"], r["year"], db_path, student_id=student_id)
    return n > 0


# ---------------------------------------------------------------- the timetable: is this course's period on now?

def _period_bounds() -> Dict[int, tuple]:
    from timetable_manager import PERIOD_CONFIGS
    out = {}
    for p in PERIOD_CONFIGS:
        if p["period"] > 0:
            h1, m1 = map(int, p["time_start"].split(":"))
            h2, m2 = map(int, p["time_end"].split(":"))
            out[p["period"]] = (h1 * 60 + m1, h2 * 60 + m2)
    return out


def _course_periods(student: Dict[str, Any], course_code: str, db_path: str) -> Dict[int, List[int]]:
    """weekday (1..5) -> the periods this student has this course, from their class's timetable."""
    from timetable_manager import get_class_schedule_for_day
    out: Dict[int, List[int]] = {}
    for d in range(1, 6):
        try:
            sched = get_class_schedule_for_day(str(student["term"]), str(student["year"]), str(student["class_level"]), d, db_path=db_path)
        except Exception:
            continue
        for p, slot in sched.items():
            for o in [slot] + list(slot.get("alternatives") or []):
                if course_code in [c.strip() for c in str(o.get("course_code") or "").split(",")]:
                    out.setdefault(d, []).append(int(p))
                    break
    return {d: sorted(set(v)) for d, v in out.items()}


DAY_SHORT = {1: "จันทร์", 2: "อังคาร", 3: "พุธ", 4: "พฤหัสบดี", 5: "ศุกร์"}


def class_window(student: Dict[str, Any], course_code: str, t: Optional[datetime] = None, db_path: str = DB_PATH,
                 periods: Optional[Dict[int, List[int]]] = None) -> Dict[str, Any]:
    """{in_class, ends_at (end of the running block of periods), next: "จันทร์ คาบ 5 (13:00)"}"""
    t = t or now()
    periods = _course_periods(student, course_code, db_path) if periods is None else periods
    bounds = _period_bounds()
    mins = t.hour * 60 + t.minute
    today = periods.get(t.isoweekday(), [])
    for p in today:
        s, e = bounds.get(p, (0, 0))
        if s <= mins < e:
            q = p
            while q + 1 in today and q + 1 in bounds:
                q += 1
            end = bounds[q][1]
            return {"in_class": True, "ends_at": _fmt(t.replace(hour=end // 60, minute=end % 60, second=0, microsecond=0)), "next": None}
    nxt = None
    for k in range(0, 8):
        day = t + timedelta(days=k)
        wd = day.isoweekday()
        for p in periods.get(wd, []):
            s = bounds.get(p, (0, 0))[0]
            if k > 0 or s > mins:
                nxt = f"{'วันนี้' if k == 0 else 'วัน' + DAY_SHORT[wd]} คาบ {p} ({s // 60:02d}:{s % 60:02d})"
                break
        if nxt:
            break
    return {"in_class": False, "ends_at": None, "next": nxt, "has_periods": bool(periods)}


# ---------------------------------------------------------------- student side

def _enrolled_in(conn, student: Dict[str, Any], course_code: str, term: str, year: str) -> bool:
    return bool(conn.execute("SELECT 1 FROM grades_history WHERE student_id = ? AND course_code = ? AND term = ? AND year = ?;",
                             (student["student_id"], course_code, str(term), str(year))).fetchone())


def _open_quiz_for(conn, quiz_id: int, student: Dict[str, Any]):
    r = conn.execute("SELECT * FROM quizzes WHERE id = ?;", (int(quiz_id),)).fetchone()
    if not r or not r["ready"] or str(r["term"]) != str(student["term"]) or str(r["year"]) != str(student["year"]):
        raise LookupError("ไม่พบแบบทดสอบ")
    if not _enrolled_in(conn, student, r["course_code"], r["term"], r["year"]):
        raise PermissionError("ไม่ใช่รายวิชาที่ลงทะเบียนเรียน")
    return r


def _availability(r, student: Dict[str, Any], db_path: str, t: Optional[datetime] = None,
                  periods: Optional[Dict[int, List[int]]] = None) -> Dict[str, Any]:
    """is_open plus why not, and when a try started now would have to end."""
    t = t or now()
    w = _window(r, t)
    out = {"is_open": False, "reason": "", "ends_at": r["end_at"], "start_at": r["start_at"], "end_at": r["end_at"],
           "class_only": bool(r["class_only"])}
    if w["has_ended"]:
        out["reason"] = "ปิดแล้ว"
        return out
    if w["not_yet"]:
        out["reason"] = f"เปิด {r['start_at']}"
        out["opens_at"] = r["start_at"]
        return out
    if r["class_only"]:
        cw = class_window(student, r["course_code"], t, db_path, periods)
        if not cw["in_class"]:
            out["reason"] = ("ทำได้เฉพาะในคาบเรียนวิชานี้" + (f" • คาบถัดไป {cw['next']}" if cw.get("next") else "")
                             if cw.get("has_periods") else "ทำได้เฉพาะในคาบเรียน (ยังไม่พบวิชานี้ในตารางเรียน)")
            return out
        ends = [x for x in (cw["ends_at"], r["end_at"]) if x]
        out["ends_at"] = min(ends) if ends else None
    out["is_open"] = True
    return out


def _attempts(conn, quiz_id: int, student_id: str) -> List[Any]:
    return conn.execute("SELECT * FROM quiz_attempts WHERE quiz_id = ? AND student_id = ? ORDER BY attempt_no;",
                        (quiz_id, student_id)).fetchall()


def _result(att) -> Dict[str, Any]:
    return {"correct": att["correct"], "total": att["total"], "earned": _num(att["earned"] or 0),
            "max_points": _num(att["max_points"] or 0), "submitted_at": att["submitted_at"], "attempt_no": att["attempt_no"]}


def _time_ends(r, tries: List[Any]) -> Optional[datetime]:
    """เวลาทำ (duration_min) is for all the tries together, counted from the first start (owner 9 พ.ย. 2569:
    "ใน 50 นาที ทำได้แค่ 3 ครั้ง แล้วปิด"); None when there is no time limit or no try yet."""
    starts = [s for s in (_parse(a["started_at"]) for a in tries if a["started_at"]) if s]
    if not r["duration_min"] or not starts:
        return None
    return min(starts) + timedelta(minutes=int(r["duration_min"]))


def _summary(r, tries: List[Any]) -> Dict[str, Any]:
    done = [a for a in tries if a["submitted_at"]]
    best = max(done, key=lambda a: (a["earned"] or 0)) if done else None
    left = None if not r["max_attempts"] else max(0, int(r["max_attempts"]) - len(done))
    running = next((a for a in tries if not a["submitted_at"]), None)
    ends = _time_ends(r, tries)
    t = now()
    time_up = bool(ends and t >= ends)
    return {"tries": len(done), "tries_left": left, "best": _result(best) if best else None,
            "status": "in_progress" if running else ("submitted" if done else "not_started"),
            "time_ends_at": _fmt(ends) if ends else None, "time_up": time_up,
            "time_left_min": max(0, int((ends - t).total_seconds() // 60)) if ends else None,
            "can_start": bool(running) or ((left is None or left > 0) and not time_up)}


def student_quizzes(student: Dict[str, Any], db_path: str = DB_PATH) -> Dict[str, Any]:
    """The student's enrolled courses, each with its published quizzes and what each offers right now."""
    sid, t, y = student["student_id"], str(student["term"]), str(student["year"])
    finalize_expired(student_id=sid, db_path=db_path)
    with _conn(db_path) as conn:
        courses = [dict(r) for r in conn.execute(
            """SELECT g.course_code, c.course_name, c.teacher FROM grades_history g
               JOIN courses c ON c.course_code = g.course_code AND c.term = g.term AND c.year = g.year
               WHERE g.student_id = ? AND g.term = ? AND g.year = ? ORDER BY g.course_code;""", (sid, t, y))]
        rows = conn.execute("SELECT * FROM quizzes WHERE term = ? AND year = ? AND ready = 1 ORDER BY id;", (t, y)).fetchall()
        tries: Dict[int, List[Any]] = {}
        for a in conn.execute("SELECT * FROM quiz_attempts WHERE student_id = ? ORDER BY attempt_no;", (sid,)):
            tries.setdefault(a["quiz_id"], []).append(a)
    by_course: Dict[str, List[Any]] = {}
    for r in rows:
        by_course.setdefault(r["course_code"], []).append(r)
    when = now()
    out = []
    for c in courses:
        mine = by_course.get(c["course_code"], [])
        if not mine:
            continue
        periods = _course_periods(student, c["course_code"], db_path) if any(r["class_only"] for r in mine) else {}
        items = []
        for r in mine:
            av = _availability(r, student, db_path, when, periods)
            sm = _summary(r, tries.get(r["id"], []))
            if sm["time_up"] and sm["status"] != "in_progress":
                av = {**av, "is_open": False, "opens_at": None,
                      "reason": f"หมดเวลา {r['duration_min']} นาทีแล้ว (นับจากครั้งแรกที่เริ่มทำ)"}
            if (r["mode"] or "quiz") == "link":
                items.append({"quiz_id": r["id"], "title": r["title"], "mode": "link", "question_count": 0, "points": 0,
                              "duration_min": None, "max_attempts": 0, "unit_slot": None, **av,
                              "link_url": r["link_url"] if av["is_open"] else None,
                              "tries": 0, "tries_left": None, "best": None, "status": "not_started", "can_start": True})
                continue
            items.append({"quiz_id": r["id"], "title": r["title"], "mode": "quiz", "question_count": len(json.loads(r["questions_json"] or "[]")),
                          "points": _num(_points(json.loads(r["questions_json"] or "[]"))), "duration_min": r["duration_min"],
                          "max_attempts": r["max_attempts"], "unit_slot": r["unit_slot"], **av, **sm})
        out.append({**c, "quizzes": items})
    return {"server_now": _fmt(when), "courses": out}


def _paper_for_student(att) -> Dict[str, Any]:
    qs = [exams.student_question(p) for p in json.loads(att["paper_json"])]
    return {"questions": qs, "answers": json.loads(att["answers_json"] or "{}"), "photos": {},
            "started_at": att["started_at"], "deadline_at": att["deadline_at"], "server_now": _fmt(now()),
            "attempt_no": att["attempt_no"]}


NO_DEADLINE_HOURS = 3  # a quiz with no time limit and no closing time still ends this long after starting


def start_attempt(quiz_id: int, student: Dict[str, Any], db_path: str = DB_PATH) -> Dict[str, Any]:
    """Resumes the running try, or opens a new shuffled copy (correct answers never leave the server)."""
    sid = student["student_id"]
    finalize_expired(student_id=sid, db_path=db_path)
    with _lock, _conn(db_path) as conn:
        r = _open_quiz_for(conn, quiz_id, student)
        tries = _attempts(conn, r["id"], sid)
        running = next((a for a in tries if not a["submitted_at"]), None)
        if running:
            return {"status": "in_progress", **_paper_for_student(running)}
        if (r["mode"] or "quiz") == "link":
            raise ValueError("แบบทดสอบนี้เป็นลิงก์ภายนอก")
        sm = _summary(r, tries)
        if not sm["can_start"]:
            raise PermissionError(f"หมดเวลา {r['duration_min']} นาทีแล้ว (นับจากครั้งแรกที่เริ่มทำ)" if sm["time_up"]
                                  else f"ทำครบ {r['max_attempts']} ครั้งแล้ว")
        av = _availability(r, student, db_path)
        if not av["is_open"]:
            raise PermissionError(av["reason"] or "ยังไม่เปิดให้ทำ")
        source = json.loads(r["questions_json"] or "[]")
        if not source:
            raise ValueError("ครูยังไม่ได้ใส่ข้อสอบ")
        rng = random.Random(f"quiz:{r['id']}:{sid}:{random.random()}")
        order = list(range(len(source)))
        rng.shuffle(order)
        paper = []
        for qi in order:
            q = dict(source[qi], src=qi)
            q.setdefault("points", 1)
            paper.append(exams.shuffle_question(q, rng))
        started = now()
        ends = [x for x in (_parse(av["ends_at"]),) if x]
        if r["duration_min"]:
            # a new try gets what is left of the time of all tries (from the first start), not a fresh one
            ends.append(_time_ends(r, tries) or started + timedelta(minutes=int(r["duration_min"])))
        deadline = min(ends) if ends else started + timedelta(hours=NO_DEADLINE_HOURS)
        no = (max((a["attempt_no"] for a in tries), default=0)) + 1
        conn.execute(
            "INSERT INTO quiz_attempts (quiz_id, student_id, attempt_no, started_at, deadline_at, paper_json, answers_json) VALUES (?, ?, ?, ?, ?, ?, '{}');",
            (r["id"], sid, no, _fmt(started), _fmt(deadline), json.dumps(paper, ensure_ascii=False)))
        att = conn.execute("SELECT * FROM quiz_attempts WHERE quiz_id = ? AND student_id = ? AND attempt_no = ?;", (r["id"], sid, no)).fetchone()
        return {"status": "in_progress", **_paper_for_student(att)}


def _running(conn, r, sid: str):
    att = next((a for a in _attempts(conn, r["id"], sid) if not a["submitted_at"]), None)
    if not att:
        raise LookupError("ยังไม่ได้เริ่มทำแบบทดสอบ")
    return att


def save_answers(quiz_id: int, student: Dict[str, Any], answers: Any, db_path: str = DB_PATH) -> Dict[str, Any]:
    with _lock, _conn(db_path) as conn:
        r = _open_quiz_for(conn, quiz_id, student)
        att = _running(conn, r, student["student_id"])
        if now() > _parse(att["deadline_at"]) + timedelta(seconds=exams.GRACE_SECONDS):
            raise PermissionError("หมดเวลาทำแบบทดสอบแล้ว")
        clean = exams._clean_answers(answers, json.loads(att["paper_json"]))
        conn.execute("UPDATE quiz_attempts SET answers_json = ? WHERE id = ?;", (json.dumps(clean), att["id"]))
    return {"status": "saved", "answered": len(clean)}


def _grade(conn, att, answers: Dict[str, Any]) -> None:
    paper = json.loads(att["paper_json"])
    correct, earned, total, _ = exams._tally(paper, answers, {}, {})
    conn.execute("UPDATE quiz_attempts SET answers_json = ?, submitted_at = ?, correct = ?, total = ?, earned = ?, max_points = ? WHERE id = ?;",
                 (json.dumps(answers, ensure_ascii=False), _fmt(now()), correct, exams.part_total(paper), earned, total, att["id"]))


def _student_result(conn, r, sid: str, att_id: int) -> Dict[str, Any]:
    att = conn.execute("SELECT * FROM quiz_attempts WHERE id = ?;", (att_id,)).fetchone()
    return {"status": "submitted", "result": _result(att), **_summary(r, _attempts(conn, r["id"], sid))}


def submit_attempt(quiz_id: int, student: Dict[str, Any], answers: Any, db_path: str = DB_PATH) -> Dict[str, Any]:
    sid = student["student_id"]
    with _lock:
        with _conn(db_path) as conn:
            r = _open_quiz_for(conn, quiz_id, student)
            tries = _attempts(conn, r["id"], sid)
            att = next((a for a in tries if not a["submitted_at"]), None)
            if att is None:
                done = [a for a in tries if a["submitted_at"]]
                if not done:
                    raise LookupError("ยังไม่ได้เริ่มทำแบบทดสอบ")
                return _student_result(conn, r, sid, done[-1]["id"])   # sent twice (double tap / retry)
            late = now() > _parse(att["deadline_at"]) + timedelta(seconds=exams.GRACE_SECONDS)
            final = json.loads(att["answers_json"] or "{}") if late else exams._clean_answers(answers, json.loads(att["paper_json"]))
            _grade(conn, att, final)
            res = _student_result(conn, r, sid, att["id"])
        apply_scores(r["course_code"], r["term"], r["year"], db_path, student_id=sid)
    return res


def finalize_expired(student_id: Optional[str] = None, db_path: str = DB_PATH) -> int:
    """Grades tries whose time ran out with the answers saved so far."""
    cutoff = _fmt(now() - timedelta(seconds=exams.GRACE_SECONDS))
    todo: Dict[tuple, set] = {}
    with _lock:
        with _conn(db_path) as conn:
            q = ("SELECT a.*, z.course_code, z.term, z.year FROM quiz_attempts a JOIN quizzes z ON z.id = a.quiz_id "
                 "WHERE a.submitted_at IS NULL AND a.deadline_at < ?")
            args: List[Any] = [cutoff]
            if student_id:
                q += " AND a.student_id = ?"
                args.append(student_id)
            for att in conn.execute(q + ";", args).fetchall():
                _grade(conn, att, json.loads(att["answers_json"] or "{}"))
                todo.setdefault((att["course_code"], att["term"], att["year"]), set()).add(att["student_id"])
        for (code, term, year), sids in todo.items():
            for sid in sids:
                apply_scores(code, term, year, db_path, student_id=sid)
    return sum(len(v) for v in todo.values())
