"""
ข้อสอบกลางภาค / ปลายภาค.

Admin opens one school-wide window per exam type (midterm / final). In it, a logged-in student sees one
button per enrolled course code. The course teacher either attaches an external link (scores are typed in
later on the scores page) or builds a multiple-choice paper here: the server shuffles a copy of it for each
student, grades the submission and fills the student's midterm (sheet (4) column L) or final (column O),
scaled to that column's full score. Teacher edits on the scores page afterwards win.
"""
import json
import math
import random
import re
import hashlib
import threading
import unicodedata
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

import database
from attendance_rules import NO_EXAM_RIGHT, effective_remark

DB_PATH = "school_archive.db"
EXAM_TYPES = {"midterm": "กลางภาค", "final": "ปลายภาค"}
SCORE_FIELD = {"midterm": "midterm", "final": "final"}            # grades_history.scores_json keys
MAX_FIELD = {"midterm": "midterm_max", "final": "school_exam_max"}  # score_config keys (L9 / O9)
GRACE_SECONDS = 60
THAI_LETTERS = "กขคงจ"
QUESTION_TYPES = {"choice": "ปรนัย", "number": "เติมตัวเลข", "text": "เติมคำ", "truefalse": "ถูก / ผิด",
                  "match": "จับคู่", "cloze": "เติมคำในเรื่อง (cloze)", "photo": "เขียนตอบ ถ่ายภาพส่ง"}
# A set holds many parts (statements, pairs, blanks); its points are per part
SET_TYPES = ("truefalse", "match", "cloze")
SET_DEFAULT_Q = {"truefalse": "ข้อความต่อไปนี้ถูกหรือผิด", "match": "จับคู่ให้ถูกต้อง", "cloze": "เติมคำในช่องว่างให้ถูกต้อง"}
MATCH_LETTERS = {"thai": "กขคงจฉชซฌญฎฏฐฑฒณดตถท", "latin": "abcdefghijklmnopqrst"}
CHOICE_LABELS = {"latin": "abcde", "number": "12345"}   # a choice question printed with a. b. c. / 1. 2. 3. (ก ข ค is the default)
MAX_PARTS = 60
PHOTO_DIR = Path(__file__).resolve().parent / "data" / "exam_photos"
IMAGE_DIR = Path(__file__).resolve().parent / "data" / "exam_images"   # pictures in questions (teacher's)
_IMAGE_NAME = re.compile(r"[0-9a-f]{32}\.jpg")
_BLANK = re.compile(r"\[\[(.*?)\]\]")       # a cloze blank and its answer(s): [[tallest / the tallest]]
MAX_PHOTOS = 5

# Called with (term, year, [course_code]) after a graded submission; main.py wires it to the ปพ.5 writer
SCORES_CHANGED_HOOKS: List[Callable[[str, str, List[str]], None]] = []

_ready = 0  # INIT_EPOCH + 1 once the exam tables are checked
_ready_lock = threading.Lock()
_submit_lock = threading.Lock()


def now() -> datetime:
    return datetime.now()


def _fmt(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%S")


def _parse(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    try:
        return datetime.fromisoformat(str(s).replace(" ", "T"))
    except ValueError:
        return None


def ensure_columns(conn) -> None:
    """ครูเลือกได้ว่าจะสลับลำดับข้อ / สลับตัวเลือกให้นักเรียนแต่ละคนหรือไม่ (default: สลับทั้งสองอย่าง)."""
    have = {r[1] for r in conn.execute("PRAGMA table_info(exams);")}
    if not have:
        return
    for col in ("shuffle_questions", "shuffle_choices"):
        if col not in have:
            conn.execute(f"ALTER TABLE exams ADD COLUMN {col} INTEGER NOT NULL DEFAULT 1;")


def _conn(db_path: str):
    global _ready
    conn = database.get_connection(db_path)
    if _ready != database.INIT_EPOCH[0] + 1:
        with _ready_lock:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS exam_windows (
                    term TEXT NOT NULL, year TEXT NOT NULL, exam_type TEXT NOT NULL,
                    start_at TEXT, end_at TEXT,
                    PRIMARY KEY (term, year, exam_type)
                );
                CREATE TABLE IF NOT EXISTS exams (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    course_code TEXT NOT NULL, term TEXT NOT NULL, year TEXT NOT NULL, exam_type TEXT NOT NULL,
                    mode TEXT NOT NULL DEFAULT 'quiz',
                    title TEXT, link_url TEXT, duration_min INTEGER, questions_json TEXT,
                    ready INTEGER NOT NULL DEFAULT 1,
                    updated_by TEXT, updated_at TEXT,
                    UNIQUE (course_code, term, year, exam_type)
                );
                CREATE TABLE IF NOT EXISTS exam_course_times (
                    course_code TEXT NOT NULL, term TEXT NOT NULL, year TEXT NOT NULL, exam_type TEXT NOT NULL,
                    start_at TEXT, end_at TEXT,
                    opened_early_at TEXT, opened_by TEXT,
                    PRIMARY KEY (course_code, term, year, exam_type)
                );
                CREATE TABLE IF NOT EXISTS exam_locks (
                    course_code TEXT NOT NULL, term TEXT NOT NULL, year TEXT NOT NULL, exam_type TEXT NOT NULL,
                    locked_by TEXT, locked_at TEXT,
                    PRIMARY KEY (course_code, term, year, exam_type)
                );
                CREATE TABLE IF NOT EXISTS exam_attempts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    exam_id INTEGER NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
                    student_id TEXT NOT NULL,
                    started_at TEXT NOT NULL, deadline_at TEXT NOT NULL, submitted_at TEXT,
                    paper_json TEXT NOT NULL, answers_json TEXT,
                    correct INTEGER, total INTEGER, score REAL, score_max REAL,
                    written INTEGER NOT NULL DEFAULT 0,
                    UNIQUE (exam_id, student_id)
                );
                """
            )
            # อัตนัย: points earned automatically, teacher marks for photo answers, the photos themselves
            have = {r[1] for r in conn.execute("PRAGMA table_info(exam_attempts);")}
            for col, decl in (("earned", "REAL"), ("max_points", "REAL"), ("manual_json", "TEXT"), ("photos_json", "TEXT"),
                              ("pending", "INTEGER NOT NULL DEFAULT 0"), ("graded_by", "TEXT"), ("graded_at", "TEXT")):
                if col not in have:
                    conn.execute(f"ALTER TABLE exam_attempts ADD COLUMN {col} {decl};")
            # มส.: whether the paper shuts out students below 80% (default yes), and the teacher's ticks letting one sit
            if "block_ms" not in {r[1] for r in conn.execute("PRAGMA table_info(exams);")}:
                conn.execute("ALTER TABLE exams ADD COLUMN block_ms INTEGER NOT NULL DEFAULT 1;")
            ensure_columns(conn)
            conn.execute(
                """CREATE TABLE IF NOT EXISTS exam_permits (
                       course_code TEXT NOT NULL, term TEXT NOT NULL, year TEXT NOT NULL, student_id TEXT NOT NULL,
                       allowed INTEGER NOT NULL DEFAULT 0, updated_by TEXT, updated_at TEXT,
                       PRIMARY KEY (course_code, term, year, student_id)
                   );""")
            # where a course's exam time came from: 'timetable' (ตารางสอบ) or 'manual' (ตั้งเวลาวิชานี้)
            if "source" not in {r[1] for r in conn.execute("PRAGMA table_info(exam_course_times);")}:
                conn.execute("ALTER TABLE exam_course_times ADD COLUMN source TEXT;")
            _ready = database.INIT_EPOCH[0] + 1
    return conn


# ---------------------------------------------------------------- questions

_THAI_DIGITS = str.maketrans("๐๑๒๓๔๕๖๗๘๙", "0123456789")


def to_number(text: Any) -> Optional[float]:
    """A typed number: Thai digits, thousands commas, spaces, a fraction ("3/4") or a mixed number ("1 1/2")."""
    t = str(text if text is not None else "").translate(_THAI_DIGITS).strip().replace(",", "").replace("−", "-")
    if not t:
        return None
    m = re.fullmatch(r"(-?\s*\d+(?:\.\d+)?)\s*(?:[xX×*]\s*10\s*\^\s*|[eE])([-+]?\d{1,3})", t)
    if m:
        try:
            return float(m.group(1).replace(" ", "")) * 10 ** int(m.group(2))
        except (OverflowError, ValueError):
            return None
    m = re.fullmatch(r"(-?)\s*(\d+)\s+(\d+)\s*/\s*(\d+)", t)
    if m and int(m.group(4)):
        v = int(m.group(2)) + int(m.group(3)) / int(m.group(4))
        return -v if m.group(1) else v
    m = re.fullmatch(r"(-?\s*\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)", t)
    if m and float(m.group(2)):
        return float(m.group(1).replace(" ", "")) / float(m.group(2))
    try:
        return float(t.replace(" ", ""))
    except ValueError:
        return None


def number_matches(given: Any, key: Any, tolerance: float = 0.0) -> bool:
    g, k = to_number(given), to_number(key)
    return g is not None and k is not None and abs(g - k) <= max(float(tolerance or 0), 1e-9 * max(1.0, abs(k)))


# ---------------------------------------------------------------- words, pictures, sets

def norm_text(s: Any) -> str:
    """A typed word as it is compared: no case, spaces or punctuation; Thai digits and sara am made uniform."""
    t = unicodedata.normalize("NFC", str(s if s is not None else "")).translate(_THAI_DIGITS).lower()
    t = t.replace("\u0e4d\u0e32", "\u0e33").replace("\u200b", "")
    t = re.sub(r"[\s.,;:!?\"'“”‘’()\[\]{}…\-–—_]+", "", t)
    return t


def split_accepts(v: Any) -> List[str]:
    """The accepted answers of a word blank: a list, or text with / (or |) between the forms."""
    parts = v if isinstance(v, list) else re.split(r"[/|]", str(v if v is not None else ""))
    out: List[str] = []
    for p in parts:
        p = re.sub(r"\s+", " ", str(p)).strip()
        if p and norm_text(p) and p not in out:
            out.append(p)
    return out


def text_matches(given: Any, accepts: List[str]) -> bool:
    g = norm_text(given)
    return bool(g) and any(g == norm_text(a) for a in accepts)


def cloze_blanks(text: str) -> List[List[str]]:
    return [split_accepts(b) for b in _BLANK.findall(text or "")]


def cloze_segments(text: str) -> List[str]:
    """The passage around the blanks: len = blanks + 1."""
    return _BLANK.split(text or "")[::2]


def clean_image(v: Any) -> str:
    v = str(v or "").strip()
    return v if _IMAGE_NAME.fullmatch(v) else ""


def save_image(data: bytes) -> str:
    """A picture for a question (teacher's upload or cut from an imported file): JPEG, at most 1200 px."""
    from PIL import Image, ImageOps
    import io
    if len(data) > 20 * 1024 * 1024:
        raise ValueError("รูปใหญ่เกิน 20 MB")
    try:
        img = ImageOps.exif_transpose(Image.open(io.BytesIO(data)))
        img.load()
    except Exception:
        raise ValueError("ไฟล์นี้ไม่ใช่รูปภาพ")
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        bg = Image.new("RGB", img.size, (255, 255, 255))
        bg.paste(img, mask=img.split()[-1])
        img = bg
    img = img.convert("RGB")
    img.thumbnail((1200, 1200))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85, optimize=True)
    body = buf.getvalue()
    name = hashlib.sha256(body).hexdigest()[:32] + ".jpg"
    IMAGE_DIR.mkdir(parents=True, exist_ok=True)
    path = IMAGE_DIR / name
    if not path.exists():
        path.write_bytes(body)
    return name


def sweep_images(db_path: str = DB_PATH, older_than_days: int = 7) -> int:
    """Pictures no paper uses any more (a file read but not saved, a question removed), after a week."""
    import time as _time
    if not IMAGE_DIR.exists():
        return 0
    texts: List[str] = []
    with _conn(db_path) as conn:
        for sql in ("SELECT questions_json FROM exams", "SELECT paper_json FROM exam_attempts",
                    "SELECT questions_json FROM quizzes", "SELECT paper_json FROM quiz_attempts"):
            try:
                texts += [r[0] or "" for r in conn.execute(sql)]
            except Exception:
                pass
    used = set(_IMAGE_NAME.findall(" ".join(texts)))
    cutoff = _time.time() - older_than_days * 86400
    gone = 0
    for f in IMAGE_DIR.glob("*.jpg"):
        try:
            if f.name not in used and f.stat().st_mtime < cutoff:
                f.unlink()
                gone += 1
        except OSError:
            pass
    return gone


def image_path(name: str) -> Path:
    if not _IMAGE_NAME.fullmatch(name or "") or not (IMAGE_DIR / name).exists():
        raise LookupError("ไม่พบรูป")
    return IMAGE_DIR / name


def part_count(p: Dict[str, Any]) -> int:
    t = p.get("type") or "choice"
    if t in ("truefalse", "match"):
        return len(p.get("items") or [])
    if t == "cloze":
        return len(_BLANK.findall(p.get("text") or ""))
    return 1


def question_points(p: Dict[str, Any]) -> float:
    return float(p.get("points", 1)) * part_count(p)


def _side(o: Any, what: str, n: int, k: int) -> Dict[str, str]:
    o = o if isinstance(o, dict) else {"text": o}
    d = {"text": re.sub(r"\s+", " ", str(o.get("text") or "")).strip()}
    if clean_image(o.get("image")):
        d["image"] = clean_image(o.get("image"))
    return d


def clean_questions(raw: Any) -> List[Dict[str, Any]]:
    """
    Validated questions, blanks dropped; raises ValueError on an unusable one.
      choice:    {type, q, choices[2..5], answer: index, points}
      number:    {type, q, answer: "12.5", tolerance, unit, points}      (เติมตัวเลข, graded automatically)
      text:      {type, q, answer: [accepted words], unit, points}       (เติมคำ, case/space/punctuation ignored)
      truefalse: {type, q, items: [{text, answer: bool}], points per statement}
      match:     {type, q, items: [{text, image?, answer: option index}], options: [{text, image?}], letters, points per pair}
      cloze:     {type, q, text: "... [[answer / other]] ...", bank: [words] (pick from it when given), points per blank}
      photo:     {type, q, guide: เฉลย / แนวคำตอบ for the teacher, points} (written on paper, photographed, teacher marks)
    Any question may carry image (a picture name from save_image).
    """
    out = []
    for n, item in enumerate(raw or [], start=1):
        item = item or {}
        kind = str(item.get("type") or "choice")
        if kind not in QUESTION_TYPES:
            raise ValueError(f"ข้อ {n}: ชนิดข้อสอบไม่ถูกต้อง")
        q = str(item.get("q") or "").strip()
        choices = [str(c).strip() for c in (item.get("choices") or [])] if kind == "choice" else []
        filled = bool(q or any(choices) or str(item.get("answer") or "").strip() or str(item.get("text") or "").strip()
                      or any(((x or {}).get("text") if isinstance(x, dict) else x) for x in (item.get("items") or [])))
        if not filled:
            continue
        if not q and kind in SET_TYPES:
            q = SET_DEFAULT_Q[kind]
        if not q and item.get("as_image") is True and clean_image(item.get("image")):
            q = "ดูโจทย์จากภาพ"            # the question is the picture (as printed)
        if not q:
            raise ValueError(f"ข้อ {n}: ยังไม่มีโจทย์")
        try:
            points = float(item.get("points") if item.get("points") not in (None, "") else 1)
        except (TypeError, ValueError):
            raise ValueError(f"ข้อ {n}: คะแนนของข้อต้องเป็นตัวเลข")
        if not (0 < points <= 100):
            raise ValueError(f"ข้อ {n}: คะแนนของข้อต้องมากกว่า 0 และไม่เกิน 100")
        points = int(points) if points.is_integer() else points
        image = clean_image(item.get("image"))
        before = len(out)
        if kind in SET_TYPES:
            out.append(_clean_set(n, kind, q, item, points))
        elif kind == "text":
            acc = split_accepts(item.get("answer"))
            if not acc:
                raise ValueError(f"ข้อ {n}: ใส่เฉลย (ถ้าตอบได้หลายแบบ คั่นด้วย / เช่น tallest / the tallest)")
            out.append({"type": kind, "q": q, "answer": acc, "unit": str(item.get("unit") or "").strip(), "points": points})
        elif kind == "choice":
            answer = item.get("answer")
            keep = [c for c in choices if c]
            if len(keep) < 2:
                raise ValueError(f"ข้อ {n}: ต้องมีตัวเลือกอย่างน้อย 2 ตัว")
            if len(keep) > len(THAI_LETTERS):
                raise ValueError(f"ข้อ {n}: ตัวเลือกได้ไม่เกิน {len(THAI_LETTERS)} ตัว")
            if not isinstance(answer, int) or not (0 <= answer < len(choices)) or not choices[answer]:
                raise ValueError(f"ข้อ {n}: ยังไม่ได้เลือกคำตอบที่ถูก")
            out.append({"type": kind, "q": q, "choices": keep, "answer": keep.index(choices[answer]), "points": points,
                        **({"labels": item["labels"]} if item.get("labels") in ("latin", "number") else {})})
        elif kind == "number":
            key = str(item.get("answer") if item.get("answer") is not None else "").strip()
            if to_number(key) is None:
                raise ValueError(f"ข้อ {n}: ใส่เฉลยเป็นตัวเลข (เช่น 12, -3.5, 3/4)")
            try:
                tol = abs(float(item.get("tolerance") or 0))
            except (TypeError, ValueError):
                raise ValueError(f"ข้อ {n}: ค่าคลาดเคลื่อนต้องเป็นตัวเลข")
            out.append({"type": kind, "q": q, "answer": key, "tolerance": int(tol) if tol.is_integer() else tol,
                        "unit": str(item.get("unit") or "").strip(), "points": points})
        else:
            out.append({"type": kind, "q": q, "guide": str(item.get("guide") or "").strip(), "points": points})
        explain = str(item.get("explain") or "").strip()
        if explain and len(out) > before:
            out[-1]["explain"] = explain[:4000]   # วิธีทำ / คำอธิบายเฉลย: the teacher's view only
        if image and len(out) > before:
            out[-1]["image"] = image
            if item.get("as_image") is True:
                out[-1]["as_image"] = True    # the student sees the picture (as printed) instead of the text
    return out


def _clean_set(n: int, kind: str, q: str, item: Dict[str, Any], points) -> Dict[str, Any]:
    if kind == "cloze":
        text = str(item.get("text") or "").strip()
        blanks = cloze_blanks(text)
        if not blanks:
            raise ValueError(f"ข้อ {n}: ยังไม่มีช่องว่าง — ใส่คำตอบในวงเล็บเหลี่ยมคู่ เช่น Giraffes are the [[tallest]] animal")
        if len(blanks) > MAX_PARTS:
            raise ValueError(f"ข้อ {n}: ช่องว่างได้ไม่เกิน {MAX_PARTS} ช่อง")
        bank: List[str] = []
        for w in item.get("bank") or []:
            w = re.sub(r"\s+", " ", str(w)).strip()
            if w and norm_text(w) not in [norm_text(x) for x in bank]:
                bank.append(w)
        for k, acc in enumerate(blanks, start=1):
            if not acc:
                raise ValueError(f"ข้อ {n} ช่องที่ {k}: ยังไม่มีคำตอบ (ใส่ใน [[ ]])")
            if bank and not any(text_matches(w, acc) for w in bank):
                raise ValueError(f"ข้อ {n} ช่องที่ {k}: คำตอบ “{' / '.join(acc)}” ไม่อยู่ในกล่องคำ")
        return {"type": kind, "q": q, "text": text, "bank": bank, "points": points}
    raw_items = [x if isinstance(x, dict) else {"text": x} for x in (item.get("items") or [])]
    if kind == "truefalse":
        items = []
        for k, it in enumerate(raw_items, start=1):
            t = re.sub(r"\s+", " ", str(it.get("text") or "")).strip()
            if not t:
                continue
            if not isinstance(it.get("answer"), bool):
                raise ValueError(f"ข้อ {n} ข้อย่อย {k}: ยังไม่ได้เลือกว่าถูก (✓) หรือผิด (✗)")
            items.append({"text": t, "answer": it["answer"]})
        if not items:
            raise ValueError(f"ข้อ {n}: ยังไม่มีข้อความให้ตอบถูก/ผิด")
        if len(items) > MAX_PARTS:
            raise ValueError(f"ข้อ {n}: ข้อย่อยได้ไม่เกิน {MAX_PARTS} ข้อ")
        return {"type": kind, "q": q, "items": items, "points": points}
    # match
    letters = item.get("letters") if item.get("letters") in MATCH_LETTERS else "thai"
    opts_raw = [_side(o, "ตัวเลือก", n, k) for k, o in enumerate(item.get("options") or [], start=1)]
    remap, options = {}, []
    for k, o in enumerate(opts_raw):
        if o["text"] or o.get("image"):
            remap[k] = len(options)
            options.append(o)
    if len(options) < 2:
        raise ValueError(f"ข้อ {n}: ชุดจับคู่ต้องมีตัวเลือก (ด้านขวา) อย่างน้อย 2 ตัว")
    if len(options) > len(MATCH_LETTERS[letters]):
        raise ValueError(f"ข้อ {n}: ตัวเลือกได้ไม่เกิน {len(MATCH_LETTERS[letters])} ตัว")
    items = []
    for k, it in enumerate(raw_items, start=1):
        side = _side(it, "ข้อ", n, k)
        if not side["text"] and not side.get("image"):
            continue
        a = it.get("answer")
        if not isinstance(a, int) or isinstance(a, bool) or a not in remap:
            raise ValueError(f"ข้อ {n} ข้อย่อย {k}: ยังไม่ได้เลือกคู่ที่ถูก")
        items.append({**side, "answer": remap[a]})
    if not items:
        raise ValueError(f"ข้อ {n}: ยังไม่มีข้อให้จับคู่")
    if len(items) > MAX_PARTS:
        raise ValueError(f"ข้อ {n}: ข้อย่อยได้ไม่เกิน {MAX_PARTS} ข้อ")
    return {"type": kind, "q": q, "items": items, "options": options, "letters": letters, "points": points}


_Q_START = re.compile(r"^\s*(\d{1,3})\s*[.)]\s*(.+)$")
_CHOICE = re.compile(r"^\s*\(?([กขคงจabcdeABCDE])\s*[.)]\s*(.+)$")
_ANSWER = re.compile(r"^\s*(?:ตอบ|เฉลย|answer|ans)\s*[:：.]?\s*(.+?)\s*$", re.IGNORECASE)


def _choice_index(token: str) -> int:
    t = token.strip()
    if t in THAI_LETTERS:
        return THAI_LETTERS.index(t)
    if t.isdigit():
        return int(t) - 1
    return "abcde".index(t.lower())


def parse_questions_text(text: str) -> List[Dict[str, Any]]:
    """
    Paste from Word:              or from Excel (one row per question, tab separated):
      1. โจทย์ ...                  โจทย์ <tab> ตัวเลือก ก <tab> ข <tab> ค <tab> ง <tab> คำตอบ (ก / 1)
      ก. ...   ข. ...  (one per line)
      ตอบ ข
    A question without choices whose answer is a number becomes เติมตัวเลข ("ตอบ 12.5");
    one without choices and without an answer becomes เขียนตอบ ถ่ายภาพส่ง. Excel: "โจทย์ <tab> 12.5" = เติมตัวเลข.
    """
    rows = [ln for ln in (text or "").replace("\r", "").split("\n")]
    if sum(1 for ln in rows if "\t" in ln) >= max(1, len([ln for ln in rows if ln.strip()]) // 2):
        out = []
        for ln in rows:
            cells = [c.strip() for c in ln.split("\t")]
            while cells and not cells[-1]:
                cells.pop()
            if len(cells) < 2 or not cells[0]:
                continue
            if len(cells) == 2:
                if to_number(cells[1]) is not None:
                    out.append({"type": "number", "q": cells[0], "answer": cells[1]})
                continue  # header row
            try:
                ans = _choice_index(cells[-1])
            except ValueError:
                continue  # header row
            out.append({"type": "choice", "q": cells[0], "choices": cells[1:-1], "answer": ans})
        return clean_questions(out)

    out, cur = [], None
    for ln in rows:
        if not ln.strip():
            continue
        m = _ANSWER.match(ln)
        if m and cur is not None:
            cur["answer_text"] = m.group(1).strip().strip("()")
            continue
        m = _CHOICE.match(ln)
        if m and cur is not None:
            # Word often keeps several choices on one line: "ก. 1   ข. 2"
            parts = re.split(r"\s+(?=\(?[กขคงจabcdeABCDE]\s*[.)]\s)", ln.strip())
            for p in parts:
                pm = _CHOICE.match(p)
                if pm:
                    cur["choices"].append(pm.group(2).strip())
                elif cur["choices"]:
                    cur["choices"][-1] += " " + p.strip()
            continue
        m = _Q_START.match(ln)
        if m:
            cur = {"q": m.group(2).strip(), "choices": [], "answer": None}
            out.append(cur)
        elif cur is not None:
            if cur["choices"]:
                cur["choices"][-1] += " " + ln.strip()
            else:
                cur["q"] += "\n" + ln.strip()
    for cur in out:
        ans = cur.pop("answer_text", None)
        if cur["choices"]:
            cur["type"] = "choice"
            if ans:
                try:
                    cur["answer"] = _choice_index(ans[0])
                except ValueError:
                    pass
        elif ans is not None and to_number(ans) is not None:
            cur.update(type="number", answer=ans)
        else:
            cur.update(type="photo", guide=ans or "")
    return clean_questions(out)


# ---------------------------------------------------------------- windows

def get_windows(term: str, year: str, db_path: str = DB_PATH) -> Dict[str, Dict[str, Any]]:
    with _conn(db_path) as conn:
        rows = {r["exam_type"]: r for r in conn.execute(
            "SELECT * FROM exam_windows WHERE term = ? AND year = ?;", (str(term), str(year)))}
    t = now()
    out = {}
    for et, label in EXAM_TYPES.items():
        r = rows.get(et)
        s, e = (_parse(r["start_at"]), _parse(r["end_at"])) if r else (None, None)
        out[et] = {"exam_type": et, "label": label, "start_at": _fmt(s) if s else None, "end_at": _fmt(e) if e else None,
                   "is_open": bool(s and e and s <= t <= e), "has_ended": bool(e and t > e)}
    return out


def set_window(term: str, year: str, exam_type: str, start_at: Optional[str], end_at: Optional[str], db_path: str = DB_PATH) -> None:
    if exam_type not in EXAM_TYPES:
        raise ValueError("ประเภทข้อสอบไม่ถูกต้อง")
    s, e = _parse(start_at), _parse(end_at)
    if (start_at and not s) or (end_at and not e):
        raise ValueError("รูปแบบวันเวลาไม่ถูกต้อง")
    if s and e and e <= s:
        raise ValueError("เวลาปิดต้องหลังเวลาเปิด")
    with _conn(db_path) as conn:
        conn.execute(
            """INSERT INTO exam_windows (term, year, exam_type, start_at, end_at) VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(term, year, exam_type) DO UPDATE SET start_at = excluded.start_at, end_at = excluded.end_at;""",
            (str(term), str(year), exam_type, _fmt(s) if s else None, _fmt(e) if e else None))


# ---------------------------------------------------------------- per-course exam times (ตารางสอบ)
# A course's own slot (from the exam timetable) overrides the school-wide window; without one the window
# applies. The admin may open a course before its time ("ปลดล็อกก่อนเวลา"): it stays open until its end time.

EARLY_DEFAULT_HOURS = 3  # an early-opened course with no end time anywhere closes this long after opening


def course_times(term: str, year: str, db_path: str = DB_PATH) -> Dict[tuple, Dict[str, Any]]:
    with _conn(db_path) as conn:
        return {(r["course_code"], r["exam_type"]): dict(r) for r in conn.execute(
            "SELECT * FROM exam_course_times WHERE term = ? AND year = ?;", (str(term), str(year)))}


def slot_window(windows: Dict[str, Dict[str, Any]], times: Dict[tuple, Dict[str, Any]], course_code: str, exam_type: str) -> Dict[str, Any]:
    """When one course's exam is open: its own time if set, else the school window; early opening wins."""
    ct = times.get((course_code, exam_type)) or {}
    own = bool(ct.get("start_at") and ct.get("end_at"))
    w = windows[exam_type]
    s, e = (_parse(ct.get("start_at")), _parse(ct.get("end_at"))) if own else (_parse(w["start_at"]), _parse(w["end_at"]))
    early = _parse(ct.get("opened_early_at"))
    t = now()
    if early and not e:
        e = early + timedelta(hours=EARLY_DEFAULT_HOURS)
    ended = bool(e and t > e)
    is_open = (bool(early) and early <= t and not ended) or bool(s and e and s <= t <= e)
    return {"start_at": _fmt(s) if s else None, "end_at": _fmt(e) if e else None, "source": "course" if own else "school",
            "opened_early": bool(early), "is_open": is_open, "has_ended": ended and not is_open}


def set_course_time(term: str, year: str, course_code: str, exam_type: str, start_at: Optional[str], end_at: Optional[str],
                    db_path: str = DB_PATH) -> None:
    """Admin: one course's exam slot (both empty = follow the school window)."""
    if exam_type not in EXAM_TYPES:
        raise ValueError("ประเภทข้อสอบไม่ถูกต้อง")
    s, e = _parse(start_at), _parse(end_at)
    if (start_at and not s) or (end_at and not e) or (bool(s) != bool(e)):
        raise ValueError("ระบุวันเวลาเริ่มและสิ้นสุดให้ครบ")
    if s and e and e <= s:
        raise ValueError("เวลาสิ้นสุดต้องหลังเวลาเริ่ม")
    with _conn(db_path) as conn:
        conn.execute(
            """INSERT INTO exam_course_times (course_code, term, year, exam_type, start_at, end_at, source) VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(course_code, term, year, exam_type) DO UPDATE SET
                 start_at = excluded.start_at, end_at = excluded.end_at, source = excluded.source;""",
            (course_code, str(term), str(year), exam_type, _fmt(s) if s else None, _fmt(e) if e else None, "manual" if s else None))


def set_opened_early(term: str, year: str, course_codes: List[str], exam_type: str, opened: bool, by: str,
                     db_path: str = DB_PATH) -> None:
    """Admin: let students sit these courses now (before their time), or take that back."""
    if exam_type not in EXAM_TYPES:
        raise ValueError("ประเภทข้อสอบไม่ถูกต้อง")
    with _conn(db_path) as conn:
        for code in course_codes:
            conn.execute(
                """INSERT INTO exam_course_times (course_code, term, year, exam_type, opened_early_at, opened_by) VALUES (?, ?, ?, ?, ?, ?)
                   ON CONFLICT(course_code, term, year, exam_type) DO UPDATE SET
                     opened_early_at = excluded.opened_early_at, opened_by = excluded.opened_by;""",
                (code, str(term), str(year), exam_type, _fmt(now()) if opened else None, by if opened else None))


# ---------------------------------------------------------------- admin: which courses sit which exam

LOCKED_MESSAGE = "ผู้ดูแลระบบตั้งให้วิชานี้ไม่มีสอบ{label} (ล็อกไว้) จึงแก้ไขข้อสอบไม่ได้"


def locked_slots(term: str, year: str, db_path: str = DB_PATH) -> set:
    """{(course_code, exam_type)} the admin marked as "ไม่สอบ"."""
    with _conn(db_path) as conn:
        return {(r[0], r[1]) for r in conn.execute(
            "SELECT course_code, exam_type FROM exam_locks WHERE term = ? AND year = ?;", (str(term), str(year)))}


def is_locked(course_code: str, term: str, year: str, exam_type: str, db_path: str = DB_PATH) -> bool:
    return (course_code, exam_type) in locked_slots(term, year, db_path)


def set_locked(term: str, year: str, course_codes: List[str], exam_types: List[str], locked: bool, by: str,
               db_path: str = DB_PATH) -> int:
    """Admin: mark courses as sitting (unlocked) or not sitting (locked) the given exams."""
    if not exam_types or any(et not in EXAM_TYPES for et in exam_types):
        raise ValueError("ประเภทข้อสอบไม่ถูกต้อง")
    n = 0
    with _conn(db_path) as conn:
        for code in course_codes:
            for et in exam_types:
                if locked:
                    n += conn.execute(
                        "INSERT OR IGNORE INTO exam_locks (course_code, term, year, exam_type, locked_by, locked_at) VALUES (?, ?, ?, ?, ?, ?);",
                        (code, str(term), str(year), et, by, _fmt(now()))).rowcount
                else:
                    n += conn.execute("DELETE FROM exam_locks WHERE course_code = ? AND term = ? AND year = ? AND exam_type = ?;",
                                      (code, str(term), str(year), et)).rowcount
    return n


def _refuse_if_locked(course_code: str, term: str, year: str, exam_type: str, db_path: str) -> None:
    if is_locked(course_code, term, year, exam_type, db_path):
        raise PermissionError(LOCKED_MESSAGE.format(label=EXAM_TYPES.get(exam_type, "")))


# ---------------------------------------------------------------- teacher side

def _exam_row(conn, course_code: str, term: str, year: str, exam_type: str):
    return conn.execute("SELECT * FROM exams WHERE course_code = ? AND term = ? AND year = ? AND exam_type = ?;",
                        (course_code, str(term), str(year), exam_type)).fetchone()


def _exam_dict(r, with_answers: bool) -> Dict[str, Any]:
    qs = json.loads(r["questions_json"] or "[]")
    d = {"id": r["id"], "course_code": r["course_code"], "term": r["term"], "year": r["year"],
         "exam_type": r["exam_type"], "label": EXAM_TYPES[r["exam_type"]], "mode": r["mode"],
         "title": r["title"] or "", "link_url": r["link_url"] or "", "duration_min": r["duration_min"],
         "question_count": len(qs), "ready": bool(r["ready"]), "updated_by": r["updated_by"], "updated_at": r["updated_at"],
         "block_ms": bool(r["block_ms"]) if "block_ms" in r.keys() else True,
         "shuffle_questions": flag_on(r["shuffle_questions"]) if "shuffle_questions" in r.keys() else True,
         "shuffle_choices": flag_on(r["shuffle_choices"]) if "shuffle_choices" in r.keys() else True}
    if with_answers:
        d["questions"] = qs
    return d


def get_exam(course_code: str, term: str, year: str, exam_type: str, db_path: str = DB_PATH) -> Optional[Dict[str, Any]]:
    with _conn(db_path) as conn:
        r = _exam_row(conn, course_code, term, year, exam_type)
        if not r:
            return None
        d = _exam_dict(r, with_answers=True)
        d["attempt_count"] = conn.execute("SELECT COUNT(*) FROM exam_attempts WHERE exam_id = ?;", (r["id"],)).fetchone()[0]
    return d


def save_exam(course_code: str, term: str, year: str, exam_type: str, mode: str, title: str, link_url: str,
              duration_min: Optional[int], questions: Any, ready: bool, updated_by: str, db_path: str = DB_PATH,
              block_ms: Optional[bool] = None, shuffle_questions: Optional[bool] = None,
              shuffle_choices: Optional[bool] = None) -> Dict[str, Any]:
    """block_ms: True = students with มส. cannot sit (unless ticked), False = everyone sits, None = keep as is.
    shuffle_questions / shuffle_choices: each student's own order of the questions / of the choices inside them
    (True = shuffle, the default for a new paper; None = keep as is)."""
    if exam_type not in EXAM_TYPES:
        raise ValueError("ประเภทข้อสอบไม่ถูกต้อง")
    if mode not in ("link", "quiz"):
        raise ValueError("รูปแบบข้อสอบไม่ถูกต้อง")
    _refuse_if_locked(course_code, term, year, exam_type, db_path)
    link_url = (link_url or "").strip()
    qs: List[Dict[str, Any]] = []
    if mode == "link":
        if not re.match(r"^https?://\S+$", link_url):
            raise ValueError("ลิงก์ต้องขึ้นต้นด้วย http:// หรือ https://")
    else:
        qs = clean_questions(questions)
        if ready and not qs:
            raise ValueError("ยังไม่มีข้อสอบ (ใส่อย่างน้อย 1 ข้อ หรือยกเลิก 'พร้อมสอบ')")
    dur = int(duration_min) if duration_min not in (None, "", 0) else None
    if dur is not None and not (1 <= dur <= 600):
        raise ValueError("เวลาทำข้อสอบต้องอยู่ระหว่าง 1–600 นาที")
    with _conn(db_path) as conn:
        old = _exam_row(conn, course_code, term, year, exam_type)
        block = (1 if old is None else old["block_ms"]) if block_ms is None else (1 if block_ms else 0)
        keep_q = flag_on(old["shuffle_questions"]) if old is not None else True
        keep_c = flag_on(old["shuffle_choices"]) if old is not None else True
        sh_q = 1 if (keep_q if shuffle_questions is None else shuffle_questions) else 0
        sh_c = 1 if (keep_c if shuffle_choices is None else shuffle_choices) else 0
        conn.execute(
            """INSERT INTO exams (course_code, term, year, exam_type, mode, title, link_url, duration_min, questions_json, ready, updated_by, updated_at, block_ms,
                                  shuffle_questions, shuffle_choices)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(course_code, term, year, exam_type) DO UPDATE SET
                 mode = excluded.mode, title = excluded.title, link_url = excluded.link_url, duration_min = excluded.duration_min,
                 questions_json = excluded.questions_json, ready = excluded.ready,
                 updated_by = excluded.updated_by, updated_at = excluded.updated_at, block_ms = excluded.block_ms,
                 shuffle_questions = excluded.shuffle_questions, shuffle_choices = excluded.shuffle_choices;""",
            (course_code, str(term), str(year), exam_type, mode, (title or "").strip(), link_url if mode == "link" else "",
             dur, json.dumps(qs, ensure_ascii=False), 1 if ready else 0, updated_by, _fmt(now()), block, sh_q, sh_c))
    return get_exam(course_code, term, year, exam_type, db_path)


def delete_exam(course_code: str, term: str, year: str, exam_type: str, db_path: str = DB_PATH) -> None:
    _refuse_if_locked(course_code, term, year, exam_type, db_path)
    with _conn(db_path) as conn:
        conn.execute("DELETE FROM exams WHERE course_code = ? AND term = ? AND year = ? AND exam_type = ?;",
                     (course_code, str(term), str(year), exam_type))


def _enrolled(conn, course_code: str, term: str, year: str) -> List[Dict[str, Any]]:
    rows = conn.execute(
        """SELECT cs.student_id, cs.full_name, cs.class_level, cs.room, cs.student_no
           FROM grades_history g
           JOIN class_students cs ON cs.student_id = g.student_id AND cs.term = g.term AND cs.year = g.year
           WHERE g.course_code = ? AND g.term = ? AND g.year = ?
             AND COALESCE(cs.is_active, 1) = 1 AND COALESCE(cs.is_locked, 0) = 0
           ORDER BY cs.class_level, CAST(cs.room AS INTEGER), CAST(cs.student_no AS INTEGER), cs.student_id;""",
        (course_code, str(term), str(year))).fetchall()
    return [dict(r) for r in rows]


def list_courses(term: str, year: str, course_filter: Callable[[Dict[str, Any]], bool], db_path: str = DB_PATH) -> List[Dict[str, Any]]:
    """Courses of the semester the caller may manage, with both exam slots summarised."""
    finalize_expired(db_path=db_path)
    with _conn(db_path) as conn:
        courses = [dict(r) for r in conn.execute(
            "SELECT course_code, course_name, class_level, teacher, department FROM courses WHERE term = ? AND year = ? ORDER BY class_level, course_code;",
            (str(term), str(year)))]
        courses = [c for c in courses if course_filter(c)]
        exams = {(r["course_code"], r["exam_type"]): r for r in conn.execute(
            "SELECT * FROM exams WHERE term = ? AND year = ?;", (str(term), str(year)))}
        counts = {(r[0], r[1]): r[2] for r in conn.execute(
            """SELECT e.course_code, e.exam_type, COUNT(a.submitted_at) FROM exams e
               JOIN exam_attempts a ON a.exam_id = e.id WHERE e.term = ? AND e.year = ? GROUP BY e.id;""",
            (str(term), str(year)))}
        enrolled = {r[0]: r[1] for r in conn.execute(
            """SELECT g.course_code, COUNT(*) FROM grades_history g
               JOIN class_students cs ON cs.student_id = g.student_id AND cs.term = g.term AND cs.year = g.year
               WHERE g.term = ? AND g.year = ? AND COALESCE(cs.is_active, 1) = 1 AND COALESCE(cs.is_locked, 0) = 0
               GROUP BY g.course_code;""", (str(term), str(year)))}
    locks = locked_slots(term, year, db_path)
    windows, times = get_windows(term, year, db_path), course_times(term, year, db_path)
    ms = ms_counts(term, year, db_path)
    for c in courses:
        c["student_count"] = enrolled.get(c["course_code"], 0)
        c["ms_count"], c["ms_allowed"] = ms.get(c["course_code"], (0, 0))
        c["locked"] = {et: (c["course_code"], et) in locks for et in EXAM_TYPES}
        c["schedule"] = {et: slot_window(windows, times, c["course_code"], et) for et in EXAM_TYPES}
        for et in EXAM_TYPES:
            r = exams.get((c["course_code"], et))
            c[et] = None if r is None else {**_exam_dict(r, with_answers=False),
                                            "submitted_count": counts.get((c["course_code"], et), 0)}
    return courses


def teacher_course_map(term: str, year: str, db_path: str = DB_PATH) -> List[Dict[str, Any]]:
    """Every teacher with the course codes they teach this semester (same rule as auth.owns_course)."""
    import auth
    with _conn(db_path) as conn:
        courses = [dict(r) for r in conn.execute(
            "SELECT course_code, teacher, teacher_code FROM courses WHERE term = ? AND year = ?;", (str(term), str(year)))]
        teachers = [dict(r) for r in conn.execute(
            "SELECT name, code FROM school_teachers WHERE code IS NOT NULL AND TRIM(code) <> '' ORDER BY name;")]
    out = []
    for t in teachers:
        me = auth._base_name(t["name"] or "")
        codes = sorted({c["course_code"] for c in courses
                        if ((c["teacher_code"] or "").strip() and c["teacher_code"].strip() == t["code"])
                        or (me and auth._base_name(c["teacher"] or "") == me)})
        if codes:
            out.append({"code": t["code"], "name": t["name"], "course_codes": codes})
    return out


def exam_results(course_code: str, term: str, year: str, exam_type: str, db_path: str = DB_PATH) -> Dict[str, Any]:
    finalize_expired(db_path=db_path)
    with _conn(db_path) as conn:
        r = _exam_row(conn, course_code, term, year, exam_type)
        students = _enrolled(conn, course_code, term, year)
        attempts = {} if not r else {a["student_id"]: a for a in conn.execute(
            "SELECT * FROM exam_attempts WHERE exam_id = ?;", (r["id"],))}
    rows = []
    for st in students:
        a = attempts.get(st["student_id"])
        status = "ยังไม่สอบ" if a is None else ("ส่งแล้ว" if a["submitted_at"] else "กำลังทำ")
        if a is not None and a["submitted_at"] and a["pending"]:
            status = "รอครูตรวจ"
        rows.append({**st, "status": status,
                     "started_at": a["started_at"] if a else None, "submitted_at": a["submitted_at"] if a else None,
                     "correct": a["correct"] if a else None, "total": a["total"] if a else None,
                     "earned": a["earned"] if a else None, "max_points": a["max_points"] if a else None,
                     "pending": (a["pending"] or 0) if a else 0,
                     "score": a["score"] if a else None, "score_max": a["score_max"] if a else None})
    return {"exam": _exam_dict(r, with_answers=False) if r else None, "students": rows}


def reset_attempt(course_code: str, term: str, year: str, exam_type: str, student_id: str, db_path: str = DB_PATH) -> bool:
    """Lets one student sit the exam again (the score already in the scores page stays until the new submission)."""
    _refuse_if_locked(course_code, term, year, exam_type, db_path)
    with _conn(db_path) as conn:
        r = _exam_row(conn, course_code, term, year, exam_type)
        if not r:
            return False
        att = conn.execute("SELECT id FROM exam_attempts WHERE exam_id = ? AND student_id = ?;", (r["id"], student_id)).fetchone()
        done = conn.execute("DELETE FROM exam_attempts WHERE exam_id = ? AND student_id = ?;", (r["id"], student_id)).rowcount > 0
    if att:
        import shutil
        shutil.rmtree(PHOTO_DIR / str(att["id"]), ignore_errors=True)
    return done


# ---------------------------------------------------------------- student side

def _qtype(p: Dict[str, Any]) -> str:
    return p.get("type") or "choice"


def student_question(p: Dict[str, Any]) -> Dict[str, Any]:
    """One question as the student sees it: never a key."""
    t = _qtype(p)
    q: Dict[str, Any] = {"type": t, "q": p["q"], "points": p.get("points", 1), "parts": part_count(p)}
    if p.get("image"):
        q["image"] = p["image"]
        if p.get("as_image"):
            q["as_image"] = True
    if t == "choice":
        q["choices"] = p["choices"]
        if p.get("labels") in CHOICE_LABELS:
            q["labels"] = CHOICE_LABELS[p["labels"]][:len(p["choices"])]
    elif t in ("number", "text"):
        q["unit"] = p.get("unit") or ""
    elif t == "truefalse":
        q["items"] = [it["text"] for it in p["items"]]
    elif t == "match":
        q["items"] = [{k: v for k, v in it.items() if k != "answer"} for it in p["items"]]
        q["options"] = p["options"]
        q["letters"] = MATCH_LETTERS[p.get("letters") or "thai"][:len(p["options"])]
    elif t == "cloze":
        q["segments"] = cloze_segments(p["text"])
        q["bank"] = p.get("bank") or []
    return q


# A choice whose meaning depends on where it stands.
#  - "ถูกทุกข้อ" / "ไม่มีข้อใดถูก" / "all of the above" only make sense after the others: they stay last, in the order
#    the teacher gave them, and the rest are shuffled in front of them.
#  - A choice that names other choices ("ข้อ ก และ ข ถูก", "a and b") would point at the wrong ones once the letters
#    move, so a question holding one keeps all its choices where they are.
_TAIL_TH = re.compile(
    r"ทุกข้อ|ทุกตัวเลือก|ทุกคำตอบ|ไม่มีข้อ(?:ใด|ถูก|ผิด)|ไม่มี(?:ตัวเลือก|คำตอบ)|ถูกทั้งหมด|ผิดทั้งหมด|ทั้งหมดถูก|ทั้งหมดผิด|"
    r"ถูกหมด|ผิดหมด|ข้างต้น|ข้างบน|^\s*ทั้งหมด\s*$")
# ASCII word edges on purpose: Python's word boundary also counts Thai letters, Dart's (the hint in the editor) does not
_W0, _W1 = r"(?<![A-Za-z0-9_])", r"(?![A-Za-z0-9_])"
_TAIL_EN = re.compile(_W0 + r"(?:all|none|neither|both)\s+of\s+(?:the|these|those|them)" + _W1 + "|"
                      + _W0 + r"(?:all|none)\s+the\s+above" + _W1, re.I)
_NAMES_TH = (
    re.compile(r"(?:ข้อ|ตัวเลือก|คำตอบ)\s*(?:ที่\s*)?[กขคงจ](?![ก-๙])"),
    re.compile(r"(?<![ก-๙])[กขคงจ]\s*(?:และ|กับ|หรือ|,|/|-|–|ถึง)\s*[กขคงจ](?![ก-๙])"),
    re.compile(r"(?:ข้อ|ตัวเลือก|คำตอบ)\s*(?:ที่\s*)?[1-9๑-๙]"),
    re.compile(_W0 + r"(?:option|choice|answer)s?\s*[A-Ea-e1-5]" + _W1, re.I),
)
_NAMES_UPPER = re.compile(_W0 + r"[A-E]\s*(?:and|or|&|,)\s*[A-E]" + _W1)
_NAMES_LOWER = re.compile(_W0 + r"[a-e]\s*(?:and|or|&|,)\s*[a-e]" + _W1)
_NAMES_NUMBER = re.compile(_W0 + r"[1-5]\s*(?:and|or|&|,)\s*[1-5]" + _W1)


def _is_tail_choice(text: str) -> bool:
    return bool(_TAIL_TH.search(text) or _TAIL_EN.search(text))


def _names_other_choices(text: str, labels: Optional[str] = None) -> bool:
    if any(p.search(text) for p in _NAMES_TH) or _NAMES_UPPER.search(text):
        return True
    return bool((labels == "latin" and _NAMES_LOWER.search(text)) or (labels == "number" and _NAMES_NUMBER.search(text)))


def choice_shuffle_kind(q: Dict[str, Any]) -> Optional[str]:
    """How a choice question's choices are treated: 'fixed' (kept in order), 'tail' (some stay last), None (all shuffled)."""
    if _qtype(q) != "choice" or q.get("as_image"):
        return None
    texts = [str(c) for c in q.get("choices") or []]
    if any(_names_other_choices(t, q.get("labels")) for t in texts):
        return "fixed"
    tail = [_is_tail_choice(t) for t in texts]
    if all(tail):
        return "fixed"
    return "tail" if any(tail) else None


def shuffle_question(q: Dict[str, Any], rng: random.Random, choices: bool = True) -> Dict[str, Any]:
    """A student's own order: choices, statements and pairs move; letters of a matching set stay as on paper.
    choices=False (the teacher switched it off for this paper) leaves all of them as written."""
    t = _qtype(q)
    if not choices:
        return q
    if t == "choice" and not q.get("as_image"):          # in a picture the letters are printed: keep their order
        kind = choice_shuffle_kind(q)
        n = len(q["choices"])
        if kind == "fixed":
            return q
        tail = [i for i, c in enumerate(q["choices"]) if _is_tail_choice(str(c))] if kind == "tail" else []
        perm = [i for i in range(n) if i not in tail]
        rng.shuffle(perm)
        perm += tail
        q.update(choices=[q["choices"][p] for p in perm], answer=perm.index(q["answer"]))
    elif t in ("truefalse", "match"):
        items = list(q["items"])
        rng.shuffle(items)
        q["items"] = items
    return q


def flag_on(v: Any) -> bool:
    """A switch stored as 0/1 (an empty cell from a data file counts as on, the default)."""
    return v not in (0, "0", False)


def shuffled_paper(source: List[Dict[str, Any]], rng: random.Random, questions: bool = True,
                   choices: bool = True) -> List[Dict[str, Any]]:
    """One student's copy of the teacher's questions (each keeps `src`, its place in the teacher's list)."""
    order = list(range(len(source)))
    if questions:
        rng.shuffle(order)
    paper = []
    for qi in order:
        q = dict(source[qi], src=qi)
        q.setdefault("points", 1)
        paper.append(shuffle_question(q, rng, choices))
    return paper


def _paper_for_student(conn, att) -> Dict[str, Any]:
    """The student's copy without any key: choices, the unit of a number answer, and points."""
    paper = json.loads(att["paper_json"])
    answers = json.loads(att["answers_json"] or "{}")
    qs = [student_question(p) for p in paper]
    return {"questions": qs, "answers": answers, "photos": json.loads(att["photos_json"] or "{}"),
            "started_at": att["started_at"], "deadline_at": att["deadline_at"], "server_now": _fmt(now())}


def _result(att) -> Dict[str, Any]:
    return {"correct": att["correct"], "total": att["total"], "score": att["score"], "score_max": att["score_max"],
            "earned": att["earned"], "max_points": att["max_points"], "pending": att["pending"] or 0,
            "submitted_at": att["submitted_at"]}


def student_exams(student: Dict[str, Any], db_path: str = DB_PATH) -> Dict[str, Any]:
    """The student's enrolled courses with what each exam slot offers right now."""
    sid, t, y = student["student_id"], str(student["term"]), str(student["year"])
    finalize_expired(student_id=sid, db_path=db_path)
    windows = get_windows(t, y, db_path)
    with _conn(db_path) as conn:
        courses = [dict(r) for r in conn.execute(
            """SELECT g.course_code, c.course_name, c.teacher FROM grades_history g
               JOIN courses c ON c.course_code = g.course_code AND c.term = g.term AND c.year = g.year
               WHERE g.student_id = ? AND g.term = ? AND g.year = ? ORDER BY g.course_code;""", (sid, t, y))]
        exams = {(r["course_code"], r["exam_type"]): r for r in conn.execute(
            "SELECT * FROM exams WHERE term = ? AND year = ? AND ready = 1;", (t, y))}
        attempts = {r["exam_id"]: r for r in conn.execute("SELECT * FROM exam_attempts WHERE student_id = ?;", (sid,))}
    locks = locked_slots(t, y, db_path)
    times = course_times(t, y, db_path)
    with _conn(db_path) as conn:
        barred = {code for (code, s_id), info in _ms_students(conn, t, y, student_id=sid).items() if not info["allowed"]}
    groups = []
    for et, label in EXAM_TYPES.items():
        w = windows[et]
        items = []
        for c in courses:
            r = exams.get((c["course_code"], et))
            # no paper and no link: the teacher examines on paper / outside the timetable -> no button
            if r is None or (c["course_code"], et) in locks:
                continue
            sw = slot_window(windows, times, c["course_code"], et)
            a = attempts.get(r["id"])
            item = {"exam_id": r["id"], "course_code": c["course_code"], "course_name": c["course_name"], "teacher": c["teacher"],
                    "mode": r["mode"], "title": r["title"] or "", "duration_min": r["duration_min"],
                    "question_count": len(json.loads(r["questions_json"] or "[]")),
                    "status": "submitted" if a and a["submitted_at"] else ("in_progress" if a else "not_started"),
                    "start_at": sw["start_at"], "end_at": sw["end_at"], "is_open": sw["is_open"], "has_ended": sw["has_ended"]}
            # ติด มส. in this course and the paper shuts มส. out (a sitting already started or done is kept)
            if r["block_ms"] and c["course_code"] in barred and not a:
                item["blocked"] = True
                item["blocked_reason"] = BLOCKED_MESSAGE.format(teacher=c["teacher"] or "ครูประจำวิชา")
            if sw["is_open"] and r["mode"] == "link" and not item.get("blocked"):
                item["link_url"] = r["link_url"]
            if a and a["submitted_at"]:
                item["result"] = _result(a)
            items.append(item)
        groups.append({**w, "exams": items})
    return {"student": {k: student[k] for k in ("student_id", "full_name", "class_level", "room", "term", "year")},
            "server_now": _fmt(now()), "groups": groups}


def _open_exam_for(conn, exam_id: int, student: Dict[str, Any]):
    r = conn.execute("SELECT * FROM exams WHERE id = ?;", (exam_id,)).fetchone()
    if not r or not r["ready"] or str(r["term"]) != str(student["term"]) or str(r["year"]) != str(student["year"]):
        raise LookupError("ไม่พบข้อสอบ")
    if not conn.execute("SELECT 1 FROM grades_history WHERE student_id = ? AND course_code = ? AND term = ? AND year = ?;",
                        (student["student_id"], r["course_code"], r["term"], r["year"])).fetchone():
        raise PermissionError("ไม่ใช่รายวิชาที่ลงทะเบียนเรียน")
    return r


def start_attempt(exam_id: int, student: Dict[str, Any], db_path: str = DB_PATH) -> Dict[str, Any]:
    """Opens (or resumes) the student's own shuffled copy of the paper. Correct answers never leave the server."""
    sid = student["student_id"]
    finalize_expired(student_id=sid, db_path=db_path)
    with _submit_lock, _conn(db_path) as conn:
        r = _open_exam_for(conn, exam_id, student)
        att = conn.execute("SELECT * FROM exam_attempts WHERE exam_id = ? AND student_id = ?;", (exam_id, sid)).fetchone()
        if att and att["submitted_at"]:
            return {"status": "submitted", "result": _result(att)}
        if att:
            return {"status": "in_progress", **_paper_for_student(conn, att)}
        if r["mode"] != "quiz":
            raise ValueError("ข้อสอบวิชานี้เป็นลิงก์ภายนอก")
        if is_locked(r["course_code"], r["term"], r["year"], r["exam_type"], db_path):
            raise PermissionError(f"วิชานี้ไม่มีสอบ{EXAM_TYPES[r['exam_type']]}")
        if r["block_ms"]:
            info = _ms_students(conn, r["term"], r["year"], course_code=r["course_code"], student_id=sid).get((r["course_code"], sid))
            if info and not info["allowed"]:
                teacher = conn.execute("SELECT teacher FROM courses WHERE course_code = ? AND term = ? AND year = ?;",
                                       (r["course_code"], r["term"], r["year"])).fetchone()
                raise PermissionError(BLOCKED_MESSAGE.format(teacher=(teacher and teacher["teacher"]) or "ครูประจำวิชา"))
        w = slot_window(get_windows(r["term"], r["year"], db_path), course_times(r["term"], r["year"], db_path),
                        r["course_code"], r["exam_type"])
        if not w["is_open"]:
            raise PermissionError("หมดเวลาสอบแล้ว" if w["has_ended"] else
                                  f"ยังไม่ถึงเวลาสอบ (เริ่ม {w['start_at'] or 'ยังไม่กำหนด'})")
        source = json.loads(r["questions_json"] or "[]")
        if not source:
            raise ValueError("ครูยังไม่ได้ใส่ข้อสอบ")
        rng = random.Random(f"{exam_id}:{sid}:{random.random()}")
        paper = shuffled_paper(source, rng, flag_on(r["shuffle_questions"]), flag_on(r["shuffle_choices"]))
        started = now()
        deadline = _parse(w["end_at"])
        if r["duration_min"]:
            deadline = min(deadline, started + timedelta(minutes=int(r["duration_min"])))
        conn.execute(
            "INSERT INTO exam_attempts (exam_id, student_id, started_at, deadline_at, paper_json, answers_json) VALUES (?, ?, ?, ?, ?, '{}');",
            (exam_id, sid, _fmt(started), _fmt(deadline), json.dumps(paper, ensure_ascii=False)))
        att = conn.execute("SELECT * FROM exam_attempts WHERE exam_id = ? AND student_id = ?;", (exam_id, sid)).fetchone()
        return {"status": "in_progress", **_paper_for_student(conn, att)}


def _clean_answers(answers: Any, paper: List[Dict[str, Any]]) -> Dict[str, Any]:
    """choice -> index, number -> the text typed (kept as typed, checked when graded); photos are stored apart."""
    out: Dict[str, Any] = {}
    for k, v in (answers or {}).items():
        try:
            i = int(k)
        except (TypeError, ValueError):
            continue
        if not 0 <= i < len(paper):
            continue
        kind = _qtype(paper[i])
        if kind == "choice":
            try:
                c = int(v)
            except (TypeError, ValueError):
                continue
            if 0 <= c < len(paper[i]["choices"]):
                out[str(i)] = c
        elif kind == "number":
            t = str(v if v is not None else "").strip()[:40]
            if t:
                out[str(i)] = t
        elif kind == "text":
            t = re.sub(r"\s+", " ", str(v if v is not None else "")).strip()[:80]
            if t:
                out[str(i)] = t
        elif kind in SET_TYPES:
            n = part_count(paper[i])
            if isinstance(v, dict):
                v = [v.get(str(j)) for j in range(n)]
            if not isinstance(v, list):
                continue
            v = (list(v) + [None] * n)[:n]
            if kind == "truefalse":
                got = [x if isinstance(x, bool) else None for x in v]
            elif kind == "match":
                m = len(paper[i]["options"])
                got = [x if isinstance(x, int) and not isinstance(x, bool) and 0 <= x < m else None for x in v]
            else:
                got = [(re.sub(r"\s+", " ", str(x)).strip()[:60] or None) if x is not None else None for x in v]
            if any(x is not None for x in got):
                out[str(i)] = got
    return out


def save_answers(exam_id: int, student: Dict[str, Any], answers: Any, db_path: str = DB_PATH) -> Dict[str, Any]:
    with _submit_lock, _conn(db_path) as conn:
        _open_exam_for(conn, exam_id, student)
        att = conn.execute("SELECT * FROM exam_attempts WHERE exam_id = ? AND student_id = ?;", (exam_id, student["student_id"])).fetchone()
        if not att:
            raise LookupError("ยังไม่ได้เริ่มทำข้อสอบ")
        if att["submitted_at"]:
            return {"status": "submitted", "result": _result(att)}
        if now() > _parse(att["deadline_at"]) + timedelta(seconds=GRACE_SECONDS):
            raise PermissionError("หมดเวลาทำข้อสอบแล้ว")
        clean = _clean_answers(answers, json.loads(att["paper_json"]))
        conn.execute("UPDATE exam_attempts SET answers_json = ? WHERE id = ?;", (json.dumps(clean), att["id"]))
    return {"status": "saved", "answered": len(clean)}


_max_cache: Dict[tuple, tuple] = {}


def _score_max(course_code: str, term: str, year: str, exam_type: str, db_path: str) -> float:
    """Full score of column L (midterm) or O (final) as the scores page shows it; cached briefly
    because reading it opens the ปพ.5 file and a class submits all at once."""
    key = (course_code, str(term), str(year), db_path)
    hit = _max_cache.get(key)
    if not hit or (now() - hit[0]).total_seconds() > 120:
        from course_importer import get_course_scores_sheet
        cfg = (get_course_scores_sheet(course_code, term, year, db_path=db_path) or {}).get("score_config") or {}
        hit = (now(), cfg)
        _max_cache[key] = hit
    m = hit[1].get(MAX_FIELD[exam_type])
    return float(m) if m else 20.0


def scale_score(correct: float, total: float, score_max: float) -> float:
    """
    correct/total of the column's full score, to 1 decimal place, always rounded up (owner's rule 17 พ.ย. 2569,
    for quizzes and midterm/final alike): 2/3 of 5 = 3.333 -> 3.4, 7/10 of 5 = 3.5.
    """
    if not total:
        return 0.0
    x = correct / total * score_max
    return min(float(score_max), math.ceil(round(x * 10, 6)) / 10)


def part_results(p: Dict[str, Any], given: Any) -> List[bool]:
    """Right or wrong for each part of a question (one part unless it is a set); [] for a photo answer."""
    t = _qtype(p)
    if t == "choice":
        return [given == p["answer"]]
    if t == "number":
        return [number_matches(given, p["answer"], p.get("tolerance") or 0)]
    if t == "text":
        return [text_matches(given, p["answer"])]
    g = given if isinstance(given, list) else []
    g = g + [None] * (part_count(p) - len(g))
    if t == "truefalse":
        return [isinstance(g[k], bool) and g[k] == it["answer"] for k, it in enumerate(p["items"])]
    if t == "match":
        return [g[k] == it["answer"] for k, it in enumerate(p["items"])]
    if t == "cloze":
        return [g[k] is not None and text_matches(g[k], acc) for k, acc in enumerate(cloze_blanks(p["text"]))]
    return []


def _part_marks(i: int, p: Dict[str, Any], given: Any, manual: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Each part's automatic result and the teacher's change of it (manual "i:j" -> True / False)."""
    out = []
    for j, ok in enumerate(part_results(p, given)):
        ov = manual.get(f"{i}:{j}")
        ov = ov if isinstance(ov, bool) else None
        out.append({"auto": ok, "override": ov, "correct": ok if ov is None else ov})
    return out


def _is_correct(p: Dict[str, Any], given: Any) -> bool:
    res = part_results(p, given)
    return bool(res) and all(res)


def part_total(paper: List[Dict[str, Any]]) -> int:
    return sum(part_count(p) for p in paper)


def _tally(paper: List[Dict[str, Any]], answers: Dict[str, Any], photos: Dict[str, Any], manual: Dict[str, Any]):
    """(parts right, points earned, total points, photo answers still waiting for the teacher)"""
    correct, earned, total, pending = 0, 0.0, 0.0, 0
    for i, p in enumerate(paper):
        pts = float(p.get("points", 1))
        if _qtype(p) == "photo":
            total += pts
            if str(i) in manual:
                earned += min(pts, max(0.0, float(manual[str(i)])))
            elif photos.get(str(i)):
                pending += 1
            continue
        for m in _part_marks(i, p, answers.get(str(i)), manual):
            total += pts
            if m["correct"]:
                correct += 1
                earned += pts
    return correct, earned, total, pending


def _grade(conn, att, answers: Dict[str, Any], db_path: str, keep_submitted: bool = False) -> None:
    """Scores choice and number questions now; photo answers count once the teacher marks them (0 if no photo)."""
    paper = json.loads(att["paper_json"])
    photos = json.loads(att["photos_json"] or "{}")
    manual = json.loads(att["manual_json"] or "{}")
    correct, earned, total, pending = _tally(paper, answers, photos, manual)
    ex = conn.execute("SELECT * FROM exams WHERE id = ?;", (att["exam_id"],)).fetchone()
    smax = _score_max(ex["course_code"], ex["term"], ex["year"], ex["exam_type"], db_path)
    score = scale_score(earned, total, smax)
    conn.execute(
        """UPDATE exam_attempts SET answers_json = ?, submitted_at = ?, correct = ?, total = ?, earned = ?, max_points = ?,
                  pending = ?, score = ?, score_max = ?, written = 0 WHERE id = ?;""",
        (json.dumps(answers, ensure_ascii=False), att["submitted_at"] if keep_submitted else _fmt(now()),
         correct, part_total(paper), earned, total, pending, score, smax, att["id"]))
    _write_score(conn, ex, att["student_id"], score)


def _write_score(conn, ex, student_id: str, score: float) -> None:
    """Puts the score into grades_history now; the ปพ.5 file (and totals/grade) follow through the hooks."""
    row = conn.execute("SELECT scores_json FROM grades_history WHERE student_id = ? AND course_code = ? AND term = ? AND year = ?;",
                       (student_id, ex["course_code"], ex["term"], ex["year"])).fetchone()
    if not row:
        return
    try:
        sc = json.loads(row["scores_json"] or "{}")
    except Exception:
        sc = {}
    sc[SCORE_FIELD[ex["exam_type"]]] = int(score) if float(score).is_integer() else score
    conn.execute("UPDATE grades_history SET scores_json = ? WHERE student_id = ? AND course_code = ? AND term = ? AND year = ?;",
                 (json.dumps(sc, ensure_ascii=False), student_id, ex["course_code"], ex["term"], ex["year"]))


def _notify(changed: Dict[tuple, None]) -> None:
    for (code, term, year) in changed:
        for hook in SCORES_CHANGED_HOOKS:
            try:
                hook(term, year, [code])
            except Exception as e:
                print(f"[WARN] exam score hook failed for {code}: {e}")


def submit_attempt(exam_id: int, student: Dict[str, Any], answers: Any, db_path: str = DB_PATH) -> Dict[str, Any]:
    with _submit_lock:
        with _conn(db_path) as conn:
            ex = _open_exam_for(conn, exam_id, student)
            att = conn.execute("SELECT * FROM exam_attempts WHERE exam_id = ? AND student_id = ?;", (exam_id, student["student_id"])).fetchone()
            if not att:
                raise LookupError("ยังไม่ได้เริ่มทำข้อสอบ")
            if not att["submitted_at"]:
                paper = json.loads(att["paper_json"])
                late = now() > _parse(att["deadline_at"]) + timedelta(seconds=GRACE_SECONDS)
                # after the deadline only what was saved in time counts
                final = json.loads(att["answers_json"] or "{}") if late else _clean_answers(answers, paper)
                _grade(conn, att, final, db_path)
            att = conn.execute("SELECT * FROM exam_attempts WHERE id = ?;", (att["id"],)).fetchone()
        _notify({(ex["course_code"], ex["term"], ex["year"]): None})
    return {"status": "submitted", "result": _result(att)}


def finalize_expired(student_id: Optional[str] = None, db_path: str = DB_PATH) -> int:
    """Grades attempts whose time ran out with the answers saved so far."""
    cutoff = _fmt(now() - timedelta(seconds=GRACE_SECONDS))
    changed: Dict[tuple, None] = {}
    with _submit_lock:
        with _conn(db_path) as conn:
            q = "SELECT a.*, e.course_code, e.term, e.year FROM exam_attempts a JOIN exams e ON e.id = a.exam_id WHERE a.submitted_at IS NULL AND a.deadline_at < ?"
            args: list = [cutoff]
            if student_id:
                q += " AND a.student_id = ?"
                args.append(student_id)
            for att in conn.execute(q + ";", args).fetchall():
                _grade(conn, att, json.loads(att["answers_json"] or "{}"), db_path)
                changed[(att["course_code"], att["term"], att["year"])] = None
        _notify(changed)
    return len(changed)


def flush_scores_to_porpor5(course_code: str, term: str, year: str, db_path: str = DB_PATH) -> int:
    """
    Recomputes totals/grades and rewrites sheet (4) from the DB for one course (the same path as the teacher's
    Save on the scores page). Run by the single ปพ.5 writer thread; marks the attempts as written.
    """
    from course_importer import get_course_scores_sheet, save_course_scores_sheet
    sheet = get_course_scores_sheet(course_code, term, year, db_path=db_path)
    if sheet.get("status") == "error":
        return 0
    keys = ("student_no", "student_id", "full_name", "units", "midterm", "central_exam", "final", "remark")
    students = [{k: s.get(k) for k in keys} for s in sheet["students"]]
    save_course_scores_sheet(course_code, term, year, sheet["score_config"], students,
                             score_ratio=sheet["course"].get("score_ratio"), db_path=db_path)
    with _conn(db_path) as conn:
        return conn.execute(
            """UPDATE exam_attempts SET written = 1 WHERE written = 0 AND submitted_at IS NOT NULL
               AND exam_id IN (SELECT id FROM exams WHERE course_code = ? AND term = ? AND year = ?);""",
            (course_code, str(term), str(year))).rowcount


# ---------------------------------------------------------------- อัตนัย: photo answers and the teacher's marks

def _attempt_for(conn, exam_id: int, student: Dict[str, Any]):
    _open_exam_for(conn, exam_id, student)
    att = conn.execute("SELECT * FROM exam_attempts WHERE exam_id = ? AND student_id = ?;", (exam_id, student["student_id"])).fetchone()
    if not att:
        raise LookupError("ยังไม่ได้เริ่มทำข้อสอบ")
    return att


def add_photo(exam_id: int, student: Dict[str, Any], qidx: int, data: bytes, db_path: str = DB_PATH) -> Dict[str, Any]:
    """A photo of the student's written answer (resized to keep phones' 5 MB pictures small)."""
    from PIL import Image, ImageOps
    import io
    with _submit_lock, _conn(db_path) as conn:
        att = _attempt_for(conn, exam_id, student)
        if att["submitted_at"]:
            raise PermissionError("ส่งข้อสอบแล้ว แก้ไขไม่ได้")
        if now() > _parse(att["deadline_at"]) + timedelta(seconds=GRACE_SECONDS):
            raise PermissionError("หมดเวลาทำข้อสอบแล้ว")
        paper = json.loads(att["paper_json"])
        if not (0 <= qidx < len(paper)) or _qtype(paper[qidx]) != "photo":
            raise ValueError("ข้อนี้ไม่ใช่ข้อที่ส่งรูป")
        photos = json.loads(att["photos_json"] or "{}")
        mine = photos.get(str(qidx), [])
        if len(mine) >= MAX_PHOTOS:
            raise ValueError(f"ส่งได้ไม่เกิน {MAX_PHOTOS} รูปต่อข้อ")
        if len(data) > 20 * 1024 * 1024:
            raise ValueError("รูปใหญ่เกิน 20 MB")
        try:
            img = ImageOps.exif_transpose(Image.open(io.BytesIO(data))).convert("RGB")
        except Exception:
            raise ValueError("ไฟล์นี้ไม่ใช่รูปภาพ")
        img.thumbnail((1600, 1600))
        folder = PHOTO_DIR / str(att["id"])
        folder.mkdir(parents=True, exist_ok=True)
        name = f"q{qidx}_{uuid.uuid4().hex[:10]}.jpg"
        img.save(folder / name, "JPEG", quality=80, optimize=True)
        mine.append(name)
        photos[str(qidx)] = mine
        conn.execute("UPDATE exam_attempts SET photos_json = ? WHERE id = ?;", (json.dumps(photos), att["id"]))
    return {"name": name, "photos": photos}


def delete_photo(exam_id: int, student: Dict[str, Any], qidx: int, name: str, db_path: str = DB_PATH) -> Dict[str, Any]:
    with _submit_lock, _conn(db_path) as conn:
        att = _attempt_for(conn, exam_id, student)
        if att["submitted_at"]:
            raise PermissionError("ส่งข้อสอบแล้ว แก้ไขไม่ได้")
        photos = json.loads(att["photos_json"] or "{}")
        if name in photos.get(str(qidx), []):
            photos[str(qidx)].remove(name)
            (PHOTO_DIR / str(att["id"]) / name).unlink(missing_ok=True)
            conn.execute("UPDATE exam_attempts SET photos_json = ? WHERE id = ?;", (json.dumps(photos), att["id"]))
    return {"photos": photos}


def _photo_file(att, name: str) -> Path:
    photos = json.loads(att["photos_json"] or "{}")
    if not any(name in v for v in photos.values()):
        raise LookupError("ไม่พบรูป")
    return PHOTO_DIR / str(att["id"]) / name


def student_photo_path(exam_id: int, student: Dict[str, Any], name: str, db_path: str = DB_PATH) -> Path:
    with _conn(db_path) as conn:
        att = _attempt_for(conn, exam_id, student)
    return _photo_file(att, name)


def _teacher_attempt(conn, course_code: str, term: str, year: str, exam_type: str, student_id: str):
    r = _exam_row(conn, course_code, term, year, exam_type)
    att = r and conn.execute("SELECT * FROM exam_attempts WHERE exam_id = ? AND student_id = ?;", (r["id"], student_id)).fetchone()
    if not att:
        raise LookupError("ไม่พบการสอบของนักเรียนคนนี้")
    return r, att


def teacher_photo_path(course_code: str, term: str, year: str, exam_type: str, student_id: str, name: str,
                       db_path: str = DB_PATH) -> Path:
    with _conn(db_path) as conn:
        _, att = _teacher_attempt(conn, course_code, term, year, exam_type, student_id)
    return _photo_file(att, name)


def attempt_detail(course_code: str, term: str, year: str, exam_type: str, student_id: str, db_path: str = DB_PATH) -> Dict[str, Any]:
    """One student's paper for the teacher: each answer next to the key (เฉลย), photos to mark."""
    with _conn(db_path) as conn:
        _, att = _teacher_attempt(conn, course_code, term, year, exam_type, student_id)
        st = conn.execute("SELECT full_name, class_level, room, student_no FROM class_students WHERE student_id = ? AND term = ? AND year = ?;",
                          (student_id, str(term), str(year))).fetchone()
    paper = json.loads(att["paper_json"])
    answers = json.loads(att["answers_json"] or "{}")
    photos = json.loads(att["photos_json"] or "{}")
    manual = json.loads(att["manual_json"] or "{}")
    items = []
    for i, p in enumerate(paper):
        kind, given = _qtype(p), answers.get(str(i))
        it = {"index": i, "type": kind, "q": p["q"], "points": p.get("points", 1)}
        if p.get("image"):
            it["image"] = p["image"]
        if kind != "photo":
            marks = _part_marks(i, p, given, manual)
            it.update(given=given, parts=marks, correct=all(m["correct"] for m in marks))
        if kind == "choice":
            it.update(choices=p["choices"], key=p["answer"], labels=CHOICE_LABELS.get(p.get("labels"), THAI_LETTERS))
        elif kind in ("number", "text"):
            it.update(key=p["answer"], tolerance=p.get("tolerance") or 0, unit=p.get("unit") or "")
        elif kind == "truefalse":
            it.update(items=p["items"])
        elif kind == "match":
            it.update(items=p["items"], options=p["options"],
                      letters=MATCH_LETTERS[p.get("letters") or "thai"][:len(p["options"])])
        elif kind == "cloze":
            it.update(segments=cloze_segments(p["text"]), blanks=cloze_blanks(p["text"]), bank=p.get("bank") or [])
        else:
            it.update(guide=p.get("guide") or "", photos=photos.get(str(i), []), mark=manual.get(str(i)))
        items.append(it)
    return {"student": {"student_id": student_id, **(dict(st) if st else {})}, "submitted_at": att["submitted_at"],
            "result": _result(att), "items": items}


def mark_photos(course_code: str, term: str, year: str, exam_type: str, student_id: str, marks: Dict[str, Any], by: str,
                db_path: str = DB_PATH) -> Dict[str, Any]:
    """The teacher's points for photo answers; the total is rescaled and written to the scores page again."""
    with _submit_lock:
        with _conn(db_path) as conn:
            ex, att = _teacher_attempt(conn, course_code, term, year, exam_type, student_id)
            if not att["submitted_at"]:
                raise ValueError("นักเรียนยังไม่ได้ส่งข้อสอบ")
            paper = json.loads(att["paper_json"])
            manual = json.loads(att["manual_json"] or "{}")
            for k, v in (marks or {}).items():
                m = re.fullmatch(r"(\d+):(\d+)", str(k))
                if m:
                    # a part graded automatically, marked right / wrong by the teacher (None = back to automatic)
                    i, j = int(m.group(1)), int(m.group(2))
                    if not (0 <= i < len(paper)) or _qtype(paper[i]) == "photo" or not (0 <= j < part_count(paper[i])):
                        continue
                    if v is None or v == "":
                        manual.pop(f"{i}:{j}", None)
                    elif isinstance(v, bool):
                        manual[f"{i}:{j}"] = v
                    continue
                try:
                    i = int(k)
                except (TypeError, ValueError):
                    continue
                if not (0 <= i < len(paper)) or _qtype(paper[i]) != "photo":
                    continue
                if v in (None, ""):
                    manual.pop(str(i), None)
                    continue
                try:
                    pts = float(v)
                except (TypeError, ValueError):
                    raise ValueError(f"ข้อ {i + 1}: คะแนนต้องเป็นตัวเลข")
                if not (0 <= pts <= float(paper[i].get("points", 1))):
                    raise ValueError(f"ข้อ {i + 1}: ให้คะแนนได้ 0 ถึง {paper[i].get('points', 1)}")
                manual[str(i)] = int(pts) if pts.is_integer() else pts
            conn.execute("UPDATE exam_attempts SET manual_json = ?, graded_by = ?, graded_at = ? WHERE id = ?;",
                         (json.dumps(manual), by, _fmt(now()), att["id"]))
            att = conn.execute("SELECT * FROM exam_attempts WHERE id = ?;", (att["id"],)).fetchone()
            _grade(conn, att, json.loads(att["answers_json"] or "{}"), db_path, keep_submitted=True)
            att = conn.execute("SELECT * FROM exam_attempts WHERE id = ?;", (att["id"],)).fetchone()
        _notify({(ex["course_code"], ex["term"], ex["year"]): None})
    return _result(att)


# ---------------------------------------------------------------- ไม่มีสิทธิ์สอบ (มส.)

BLOCKED_MESSAGE = "ติด มส. (เวลาเรียนไม่ถึง 80%) ยังไม่มีสิทธิ์สอบวิชานี้ กรุณาติดต่อครูประจำวิชา ({teacher})"


def _ms_students(conn, term: str, year: str, course_code: Optional[str] = None, student_id: Optional[str] = None) -> Dict[tuple, Dict[str, Any]]:
    """
    (course_code, student_id) -> details for every enrolled student whose result is มส.: the same rule as the scores
    page and sheet (4) column S (attendance cannot reach 80%, or the teacher marked มส.); with the teacher's tick.
    """
    q = """SELECT g.course_code, g.student_id, g.attendance_json, g.scores_json, cs.full_name, cs.class_level, cs.room, cs.student_no,
                  p.allowed, p.updated_by, p.updated_at
           FROM grades_history g
           JOIN class_students cs ON cs.student_id = g.student_id AND cs.term = g.term AND cs.year = g.year
           LEFT JOIN exam_permits p ON p.course_code = g.course_code AND p.term = g.term AND p.year = g.year AND p.student_id = g.student_id
           WHERE g.term = ? AND g.year = ? AND COALESCE(cs.is_active, 1) = 1 AND COALESCE(cs.is_locked, 0) = 0"""
    args: List[Any] = [str(term), str(year)]
    if course_code:
        q += " AND g.course_code = ?"
        args.append(course_code)
    if student_id:
        q += " AND g.student_id = ?"
        args.append(student_id)
    out = {}
    for r in conn.execute(q + ";", args):
        try:
            att = json.loads(r["attendance_json"] or "{}")
        except Exception:
            att = {}
        try:
            remark = (json.loads(r["scores_json"] or "{}") or {}).get("remark")
        except Exception:
            remark = None
        if effective_remark(remark, att if isinstance(att, dict) else {}) != NO_EXAM_RIGHT:
            continue
        out[(r["course_code"], r["student_id"])] = {
            "student_id": r["student_id"], "full_name": r["full_name"], "class_level": r["class_level"], "room": r["room"],
            "student_no": r["student_no"],
            "present": att.get("present_count"), "absent": att.get("absent_count"), "leave": att.get("leave_count"),
            "elapsed": att.get("elapsed_periods"), "total": att.get("total_periods"), "percentage": att.get("percentage"),
            "by_teacher": bool(str(remark or "").strip() == NO_EXAM_RIGHT),
            "allowed": bool(r["allowed"]), "allowed_by": r["updated_by"] if r["allowed"] else None,
            "allowed_at": r["updated_at"] if r["allowed"] else None,
        }
    return out


def ms_counts(term: str, year: str, db_path: str = DB_PATH) -> Dict[str, tuple]:
    """course_code -> (students ติด มส., of whom the teacher ticked to sit)"""
    out: Dict[str, List[int]] = {}
    with _conn(db_path) as conn:
        for (code, _), info in _ms_students(conn, term, year).items():
            c = out.setdefault(code, [0, 0])
            c[0] += 1
            c[1] += 1 if info["allowed"] else 0
    return {k: (v[0], v[1]) for k, v in out.items()}


def no_exam_right(course_code: str, term: str, year: str, db_path: str = DB_PATH) -> Dict[str, Any]:
    with _conn(db_path) as conn:
        rows = sorted(_ms_students(conn, term, year, course_code=course_code).values(),
                      key=lambda x: (str(x["class_level"]), int(x["room"] or 0) if str(x["room"] or "").isdigit() else 0,
                                     int(x["student_no"] or 0) if str(x["student_no"] or "").isdigit() else 0, x["student_id"]))
        c = conn.execute("SELECT course_name, teacher, class_level FROM courses WHERE course_code = ? AND term = ? AND year = ?;",
                         (course_code, str(term), str(year))).fetchone()
        papers = {et: None for et in EXAM_TYPES}
        for r in conn.execute("SELECT exam_type, block_ms FROM exams WHERE course_code = ? AND term = ? AND year = ?;",
                              (course_code, str(term), str(year))):
            papers[r["exam_type"]] = bool(r["block_ms"])
    return {"course_code": course_code, "course_name": c["course_name"] if c else "", "teacher": c["teacher"] if c else "",
            "class_level": c["class_level"] if c else "", "block_ms": papers, "students": rows}


def set_permit(course_code: str, term: str, year: str, student_id: str, allowed: bool, by: str, db_path: str = DB_PATH) -> None:
    """The course teacher's tick: a student with มส. may still sit this course's exams."""
    with _conn(db_path) as conn:
        if not conn.execute("SELECT 1 FROM grades_history WHERE course_code = ? AND term = ? AND year = ? AND student_id = ?;",
                            (course_code, str(term), str(year), student_id)).fetchone():
            raise LookupError("ไม่พบนักเรียนในรายวิชานี้")
        conn.execute(
            """INSERT INTO exam_permits (course_code, term, year, student_id, allowed, updated_by, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(course_code, term, year, student_id) DO UPDATE SET
                 allowed = excluded.allowed, updated_by = excluded.updated_by, updated_at = excluded.updated_at;""",
            (course_code, str(term), str(year), student_id, 1 if allowed else 0, by, _fmt(now())))


def set_block_ms(course_code: str, term: str, year: str, exam_type: str, block: bool, db_path: str = DB_PATH) -> None:
    _refuse_if_locked(course_code, term, year, exam_type, db_path)
    with _conn(db_path) as conn:
        if conn.execute("UPDATE exams SET block_ms = ? WHERE course_code = ? AND term = ? AND year = ? AND exam_type = ?;",
                        (1 if block else 0, course_code, str(term), str(year), exam_type)).rowcount == 0:
            raise LookupError("ยังไม่ได้ตั้งข้อสอบวิชานี้")
