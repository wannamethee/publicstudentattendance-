"""
ตัวช่วย AI ออกข้อสอบ (Gemini) - owner's decisions 17 พ.ย. 2569:
  * Gemini, the key kept on this server (gemini_api_key.txt: git-ignored, never in the nightly backup, carried by the
    Linux migration bundle like auth_secret.txt). An admin sets it on the settings page; it is never sent back.
  * Only what the teacher chooses goes to Google: the topics (เรื่อง) they tick from the topic library
    (lesson_topics.py, with every chapter of that grade as context) or type, and the lesson content they attach
    or type.
    Never student data, never the exams/quizzes already stored here.
  * Every teacher may use it for the courses they teach, a daily limit per teacher (admin sets it, default 30).
    Students, guests and the director never reach it (auth.py: not in their lists; the director cannot write).
  * The AI only drafts: the teacher checks every question, its key and the worked solution (explain) before it goes
    into a quiz (saved as a draft, not shown to students) or is added after the questions of a midterm/final paper.
"""
import base64
import os
import json
import re
import threading
import time
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import database
import exams

KEY_FILE = Path(__file__).resolve().parent / "gemini_api_key.txt"
DB_PATH = "school_archive.db"
# Google's alias for its newest Flash model. Named versions stop working for new keys after a while
# (gemini-2.5-flash did by 2026-11), the alias never does. See FALLBACK_MODELS below.
DEFAULT_MODEL = "gemini-flash-latest"
DEFAULT_DAILY_LIMIT = 30
# When the chosen model is gone (404), over its free quota (429, counted per model) or busy (5xx, after one more
# try a few seconds later), the next of these answers instead. Google keeps both aliases on current models.
# (Pro is not here: the free tier gives it no quota.)
FALLBACK_MODELS = (DEFAULT_MODEL, "gemini-flash-lite-latest")
BUSY = (500, 503, 504)
BUSY_WAIT = 3
# A model that takes the request and then never answers is overloaded too (seen 17 พ.ย. 2569: no reply in 240 s
# while it gave 503 to small requests): the next model gets its turn, with a shorter wait so a teacher is not
# left looking at the spinner for more than about 6 minutes in the worst case.
FALLBACK_TIMEOUT = 120
# SCHOOL_AI_URL: only for the sandbox tests (a mock Gemini on this machine); never set on the live server
API_URL = os.environ.get("SCHOOL_AI_URL") or "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
MAX_QUESTIONS = 60
MAX_TEXT_CHARS = 60000
MAX_FILE_BYTES = 15 * 1024 * 1024
INLINE_TYPES = {".pdf": "application/pdf", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                ".webp": "image/webp"}
KINDS = {"choice": "ปรนัย", "number": "เติมตัวเลข", "text": "เติมคำ", "truefalse": "ถูก / ผิด",
         "match": "จับคู่", "cloze": "เติมคำในเรื่อง (cloze)", "photo": "เขียนตอบ (ถ่ายภาพส่ง)"}
QUIZ_KINDS = ("choice", "number", "text", "truefalse", "match", "cloze")   # a quiz is graded automatically
LEVELS = {"easy": "ง่าย (ความรู้ความจำ)", "medium": "ปานกลาง (เข้าใจ นำไปใช้)", "hard": "ยาก (วิเคราะห์ ประเมินค่า)",
          "mixed": "คละระดับ ง่าย:ปานกลาง:ยาก ประมาณ 3:5:2"}

_lock = threading.Lock()
_ready = [False]


# ---------------------------------------------------------------- settings

def _conn(db_path: str):
    conn = database.get_connection(db_path)
    if not _ready[0]:
        conn.execute("""CREATE TABLE IF NOT EXISTS ai_usage (
                            teacher_code TEXT NOT NULL, day TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0,
                            PRIMARY KEY (teacher_code, day));""")
        _ready[0] = True
    return conn


def _key() -> str:
    try:
        return KEY_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def model(db_path: str = DB_PATH) -> str:
    m = database.get_app_setting("ai_model", "", db_path=db_path).strip()
    return m or DEFAULT_MODEL


def daily_limit(db_path: str = DB_PATH) -> int:
    try:
        return max(0, int(database.get_app_setting("ai_daily_limit", str(DEFAULT_DAILY_LIMIT), db_path=db_path)))
    except ValueError:
        return DEFAULT_DAILY_LIMIT


def used_today(code: str, db_path: str = DB_PATH) -> int:
    with _conn(db_path) as conn:
        r = conn.execute("SELECT count FROM ai_usage WHERE teacher_code = ? AND day = ?;",
                         (code, date.today().isoformat())).fetchone()
    return int(r[0]) if r else 0


def status(user: Dict[str, Any], db_path: str = DB_PATH) -> Dict[str, Any]:
    key = _key()
    limit = daily_limit(db_path)
    used = used_today(user.get("code") or "", db_path)
    out = {"configured": bool(key), "model": model(db_path), "daily_limit": limit, "used_today": used,
           "left_today": max(0, limit - used), "kinds": KINDS, "quiz_kinds": list(QUIZ_KINDS), "levels": LEVELS}
    if user.get("role") == "admin":
        out["key_hint"] = ("…" + key[-4:]) if len(key) >= 8 else ("ตั้งแล้ว" if key else "")
    return out


def save_settings(api_key: Optional[str], model_name: Optional[str], limit: Optional[int], clear_key: bool = False,
                  db_path: str = DB_PATH) -> None:
    if clear_key:
        try:
            KEY_FILE.unlink()
        except OSError:
            pass
    elif api_key is not None and api_key.strip():
        k = api_key.strip()
        # AI Studio gives the older AIza... form or the newer AQ.... form (with dots)
        if not re.fullmatch(r"[A-Za-z0-9._\-]{20,300}", k):
            raise ValueError("รูปแบบกุญแจ (API key) ไม่ถูกต้อง คัดลอกจาก Google AI Studio มาทั้งหมด")
        KEY_FILE.write_text(k, encoding="utf-8")
        try:
            import os
            os.chmod(KEY_FILE, 0o600)
        except OSError:
            pass
    if model_name is not None:
        m = model_name.strip()
        if m and not re.fullmatch(r"[a-z0-9][a-z0-9.\-]{2,60}", m):
            raise ValueError("ชื่อรุ่น AI ไม่ถูกต้อง (เช่น gemini-flash-latest หรือ gemini-3.8-flash)")
        database.set_app_setting("ai_model", m, db_path=db_path)
    if limit is not None:
        if not 0 <= int(limit) <= 1000:
            raise ValueError("จำนวนครั้งต่อวันต้องอยู่ระหว่าง 0–1000")
        database.set_app_setting("ai_daily_limit", str(int(limit)), db_path=db_path)


def _take_one(code: str, db_path: str) -> None:
    """Counts one use for today, or refuses when the teacher has none left."""
    limit = daily_limit(db_path)
    day = date.today().isoformat()
    with _lock, _conn(db_path) as conn:
        r = conn.execute("SELECT count FROM ai_usage WHERE teacher_code = ? AND day = ?;", (code, day)).fetchone()
        used = int(r[0]) if r else 0
        if used >= limit:
            raise PermissionError(f"วันนี้ใช้ตัวช่วย AI ครบ {limit} ครั้งแล้ว ใช้ได้อีกพรุ่งนี้ (ผู้ดูแลระบบปรับจำนวนได้ในหน้าตั้งค่า)")
        conn.execute("""INSERT INTO ai_usage (teacher_code, day, count) VALUES (?, ?, 1)
                        ON CONFLICT(teacher_code, day) DO UPDATE SET count = count + 1;""", (code, day))


def _give_back(code: str, db_path: str) -> None:
    """The call failed on Google's side or gave nothing usable: it does not count."""
    with _lock, _conn(db_path) as conn:
        conn.execute("UPDATE ai_usage SET count = MAX(0, count - 1) WHERE teacher_code = ? AND day = ?;",
                     (code, date.today().isoformat()))


# ---------------------------------------------------------------- lesson material

def material_part(filename: str, data: bytes) -> Tuple[Dict[str, Any], str]:
    """
    One attached file as a Gemini request part, and a short note. PDFs and pictures go as they are (Gemini reads
    them, scans too); Word and text files as their text.
    """
    name = filename or "file"
    ext = Path(name).suffix.lower()
    if len(data) > MAX_FILE_BYTES:
        raise ValueError(f"{name}: ไฟล์ใหญ่เกิน 15 MB")
    if ext in INLINE_TYPES:
        return {"inline_data": {"mime_type": INLINE_TYPES[ext], "data": base64.b64encode(data).decode()}}, name
    if ext in (".docx", ".doc"):
        if ext == ".doc":
            from exam_import import _doc_to_docx
            data = _doc_to_docx(data)
        text = docx_text(data)
    elif ext in (".txt", ".md", ".csv"):
        text = data.decode("utf-8-sig", errors="replace")
    else:
        raise ValueError(f"{name}: รองรับ PDF, Word, รูปภาพ (jpg/png) และไฟล์ข้อความ")
    text = text.strip()
    if not text:
        raise ValueError(f"{name}: ไม่พบข้อความในไฟล์")
    return {"text": f"เนื้อหาจากไฟล์ {name}:\n{text[:MAX_TEXT_CHARS]}"}, name


def docx_text(data: bytes) -> str:
    """Paragraphs and table rows of a Word file, in order (pictures are left out)."""
    import io
    from docx import Document
    from docx.table import Table
    from docx.text.paragraph import Paragraph
    doc = Document(io.BytesIO(data))
    lines: List[str] = []
    for child in doc.element.body.iterchildren():
        tag = child.tag.rsplit("}", 1)[-1]
        if tag == "p":
            t = Paragraph(child, doc).text.strip()
            if t:
                lines.append(t)
        elif tag == "tbl":
            for row in Table(child, doc).rows:
                cells, seen = [], set()
                for c in row.cells:
                    if id(c._tc) not in seen:
                        seen.add(id(c._tc))
                        cells.append(c.text.strip())
                if any(cells):
                    lines.append(" | ".join(cells))
    return "\n".join(lines)


# ---------------------------------------------------------------- the request

SCHEMA_HELP = """รูปแบบ JSON ของแต่ละชนิด (ทุกข้อต้องมี "explain" และ "topic"):
- ปรนัย: {"type":"choice","q":"โจทย์","choices":["ตัวเลือก1","ตัวเลือก2","ตัวเลือก3","ตัวเลือก4"],"answer":0,"points":1,"explain":"...","topic":1}
  answer = ลำดับของตัวเลือกที่ถูก เริ่มที่ 0, ไม่ต้องใส่ ก. ข. ค. หน้าตัวเลือก, ตัวลวงต้องสมเหตุสมผล
- เติมตัวเลข: {"type":"number","q":"โจทย์","answer":"12.5","tolerance":0,"unit":"เซนติเมตร","points":1,"explain":"...","topic":1}
  answer เป็นตัวเลขล้วน (เศษส่วนเขียน 3/4 ได้)
- เติมคำ: {"type":"text","q":"โจทย์ ... ______","answer":"คำตอบ / คำตอบอื่นที่ยอมรับ","points":1,"explain":"...","topic":1}
- ถูก/ผิด: {"type":"truefalse","q":"ข้อความต่อไปนี้ถูกหรือผิด","items":[{"text":"ข้อความ","answer":true}],"points":1,"explain":"...","topic":1}
  points คือคะแนนต่อข้อความ
- จับคู่: {"type":"match","q":"จับคู่ให้ถูกต้อง","items":[{"text":"ด้านซ้าย","answer":0}],"options":[{"text":"ด้านขวา"}],"points":1,"explain":"...","topic":1}
  answer ของแต่ละข้อย่อย = ลำดับใน options เริ่มที่ 0, options ควรมีมากกว่า items 1-2 ตัว, points ต่อคู่
- เติมคำในเรื่อง: {"type":"cloze","q":"เติมคำในช่องว่าง","text":"เนื้อเรื่อง ... [[คำตอบ]] ... [[คำตอบ / คำที่ยอมรับ]] ...","bank":[],"points":1,"explain":"...","topic":1}
  points ต่อช่อง, bank ว่างได้ ถ้าใส่ต้องมีทุกคำตอบอยู่ใน bank
- เขียนตอบ: {"type":"photo","q":"โจทย์ให้แสดงวิธีทำ/อธิบาย","guide":"แนวคำตอบและเกณฑ์ให้คะแนน","points":5,"explain":"...","topic":1}"""


def build_prompt(spec: Dict[str, Any]) -> str:
    target = {"quiz": "แบบทดสอบย่อย (ตรวจอัตโนมัติ)", "midterm": "ข้อสอบกลางภาค", "final": "ข้อสอบปลายภาค"}[spec["target"]]
    topics = spec.get("topics") or []
    scope = "\n".join(f"{i}. {t['text']}" for i, t in enumerate(topics, start=1)) or "(ครูไม่ได้เลือกเรื่อง ให้ยึดตามเนื้อหาที่ให้มา)"
    context = spec.get("topic_context") or ""
    counts = "\n".join(f"- {KINDS[k]} ({k}): {n} ข้อ" for k, n in spec["kinds"].items())
    content = spec.get("content_text") or ""
    rules = [
        "ภาษาไทยที่ถูกต้อง เหมาะกับวัยผู้เรียน (ถ้าเป็นวิชาภาษาต่างประเทศ ใช้ภาษานั้นในโจทย์ได้)",
        "ออกข้อสอบเฉพาะเรื่องที่ต้องออกข้างบน ยึดเนื้อหาที่ครูให้มาเป็นหลัก ถ้าเนื้อหาไม่พอ ให้ออกตามหลักสูตรแกนกลางของเรื่องนั้น"
        "ในชั้นนี้ ห้ามแต่งข้อเท็จจริงที่ไม่แน่ใจ",
        "เฉลยต้องถูกต้อง ตรวจคำตอบซ้ำก่อนส่ง ข้อคำนวณให้คิดเลขทีละขั้นแล้วตรวจผลอีกครั้ง",
        '"explain" = วิธีทำหรือเหตุผลของเฉลยให้ครูตรวจ ถ้าเป็นข้อคำนวณต้องแสดงวิธีทำทีละขั้น พร้อมผลลัพธ์',
        "กระจายข้อให้ครอบคลุมทุกเรื่องและหัวข้อย่อยที่เลือก ไม่ถามซ้ำเรื่องเดียวกัน ตัวเลือกที่ถูกในข้อปรนัยกระจายตำแหน่งกัน",
        "ห้ามใส่ชื่อจริงของบุคคล ใช้ชื่อสมมติ",
    ]
    if context:
        rules.append("รายชื่อบทเรียนทั้งชั้นมีไว้ให้รู้บริบท: บทก่อนหน้าคือสิ่งที่นักเรียนเรียนมาแล้ว ใช้เป็นพื้นฐานของโจทย์ได้ "
                     "แต่ห้ามออกข้อสอบจากบทที่ไม่ได้เลือก และโจทย์ห้ามใช้ความรู้จากบทที่เรียนหลังเรื่องที่เลือก")
    if spec.get("instructions"):
        rules.append("คำสั่งเพิ่มเติมจากครู: " + spec["instructions"])
    rule_text = "\n".join(f"{i}. {r}" for i, r in enumerate(rules, start=1))
    if content:
        material = "เนื้อหาบทเรียนที่ครูพิมพ์มา:\n" + content[:MAX_TEXT_CHARS]
    elif spec.get("has_files"):
        material = "เนื้อหาบทเรียนอยู่ในไฟล์ที่แนบ"
    else:
        material = "ครูไม่ได้แนบเนื้อหา ให้ออกตามเรื่องที่เลือกและหลักสูตรของชั้นนี้"
    return f"""คุณเป็นผู้ช่วยครูไทย ออก{target} รายวิชา {spec['course_code']} {spec.get('course_name') or ''} ชั้น {spec.get('level') or '-'}

เรื่องที่ต้องออกข้อสอบ (ใช้ลำดับตัวเลขนี้ในช่อง "topic"):
{scope}
{(chr(10) + context + chr(10)) if context else ''}
จำนวนข้อที่ต้องการ:
{counts}
ระดับความยาก: {LEVELS.get(spec.get('difficulty') or 'mixed', LEVELS['mixed'])}

กติกา:
{rule_text}

{SCHEMA_HELP}

ตอบเป็น JSON อย่างเดียว รูปแบบ {{"questions":[...]}} ไม่ต้องมีข้อความอื่น

{material}"""


def _post(model_name: str, body: Dict[str, Any], key: str, timeout: int) -> Dict[str, Any]:
    req = urllib.request.Request(API_URL.format(model=model_name), data=json.dumps(body).encode("utf-8"),
                                 headers={"Content-Type": "application/json", "x-goog-api-key": key}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _http_error(e: urllib.error.HTTPError, name: str) -> str:
    try:
        msg = json.loads(e.read().decode("utf-8")).get("error", {}).get("message", "")
    except Exception:
        msg = ""
    hint = {400: "คำขอไม่ถูกต้อง (ไฟล์อาจใหญ่หรือชนิดไม่รองรับ)", 401: "กุญแจไม่ถูกต้อง", 403: "กุญแจไม่มีสิทธิ์ใช้รุ่นนี้",
            404: f"ไม่พบรุ่น AI \"{name}\" (แก้ชื่อรุ่นในหน้าตั้งค่า)", 429: "ใช้เกินโควตาของ Google (ต่อนาทีหรือต่อวัน) ลองใหม่ภายหลัง",
            500: "ระบบของ Google ขัดข้องชั่วคราว ลองใหม่อีกสักครู่", 503: "Google มีผู้ใช้มากชั่วคราว ลองใหม่อีกสักครู่",
            504: "Google ตอบช้าเกินไป ลองลดจำนวนข้อหรือลองใหม่"}.get(e.code, f"Google ตอบรหัส {e.code}")
    return f"AI ทำงานไม่สำเร็จ: {hint}" + (f" ({msg[:200]})" if msg else "")


def answer_timeout(n_questions: int, has_files: bool) -> int:
    """
    Seconds to wait for the first model: about 3 s a question (9 questions took 29 s on 17 พ.ย.), more when it has
    to read files, and room for a slow start. A small quiz then waits 90 s, not 4 minutes, on a model that took the
    request and hangs before the next model gets it (FALLBACK_TIMEOUT).
    """
    return max(90, min(240, 60 + 4 * n_questions + (30 if has_files else 0)))


def ask(parts: List[Dict[str, Any]], db_path: str = DB_PATH, timeout: int = 240) -> Tuple[str, str]:
    """Gemini's text reply, and the model that wrote it: the chosen one, or the next of FALLBACK_MODELS."""
    key = _key()
    if not key:
        raise RuntimeError("ยังไม่ได้ตั้งค่ากุญแจ AI — ผู้ดูแลระบบตั้งได้ที่หน้าตั้งค่า > ตัวช่วย AI")
    body = {"contents": [{"role": "user", "parts": parts}],
            "generationConfig": {"temperature": 0.6, "responseMimeType": "application/json", "maxOutputTokens": 32768}}
    chosen = model(db_path)
    plan = [chosen] + [m for m in FALLBACK_MODELS if m != chosen]
    for i, name in enumerate(plan):
        wait = timeout if i == 0 else min(timeout, FALLBACK_TIMEOUT)
        try:
            try:
                res = _post(name, body, key, wait)
            except urllib.error.HTTPError as e:
                if e.code not in BUSY:
                    raise
                time.sleep(BUSY_WAIT)   # most spikes are short: once more before trying the next model
                res = _post(name, body, key, wait)
            break
        except urllib.error.HTTPError as e:
            if e.code in (404, 429) + BUSY and i + 1 < len(plan):
                continue                # a wrong key or a bad request: another model would not help
            raise RuntimeError(_http_error(e, name)) from None
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            timed_out = isinstance(e, TimeoutError) or isinstance(getattr(e, "reason", None), TimeoutError)
            if timed_out and i + 1 < len(plan):
                continue                # no answer in time: that model is overloaded, not the line
            raise RuntimeError(f"ติดต่อ AI ไม่ได้ (เครื่องเซิร์ฟเวอร์ต่ออินเทอร์เน็ตไม่ได้หรือหมดเวลา): {e}") from None
    cands = res.get("candidates") or []
    if not cands:
        why = (res.get("promptFeedback") or {}).get("blockReason") or "ไม่มีคำตอบ"
        raise RuntimeError(f"AI ไม่ตอบ ({why})")
    text = "".join(p.get("text", "") for p in ((cands[0].get("content") or {}).get("parts") or []))
    if not text.strip():
        raise RuntimeError(f"AI ไม่ตอบ ({cands[0].get('finishReason') or 'ว่าง'})")
    return text, name


def parse_reply(text: str) -> List[Dict[str, Any]]:
    t = text.strip()
    t = re.sub(r"^```(?:json)?\s*|\s*```$", "", t)
    try:
        data = json.loads(t)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}|\[.*\]", t, re.S)
        if not m:
            raise RuntimeError("อ่านคำตอบของ AI ไม่ได้ ลองกดสร้างใหม่อีกครั้ง")
        try:
            data = json.loads(m.group(0))
        except json.JSONDecodeError:
            raise RuntimeError("คำตอบของ AI ไม่ครบ (อาจยาวเกินไป) ลองลดจำนวนข้อ")
    qs = data.get("questions") if isinstance(data, dict) else data
    if not isinstance(qs, list):
        raise RuntimeError("คำตอบของ AI ไม่มีรายการข้อสอบ")
    return [q for q in qs if isinstance(q, dict)]


def clean_generated(raw: List[Dict[str, Any]], allowed: List[str], n_topics: int) -> Tuple[List[Dict[str, Any]], List[str]]:
    """Each question through the same check as a typed one; a broken one is dropped with a note, not the whole set."""
    out, notes = [], []
    for n, item in enumerate(raw, start=1):
        kind = str(item.get("type") or "")
        if kind not in allowed:
            notes.append(f"ข้อที่ AI ร่างลำดับ {n}: ชนิด \"{kind}\" ไม่ได้ขอไว้ ตัดออก")
            continue
        if kind == "choice" and isinstance(item.get("answer"), str) and item["answer"].strip().isdigit():
            item["answer"] = int(item["answer"].strip())
        try:
            q = exams.clean_questions([item])
        except ValueError as e:
            notes.append(f"ข้อที่ AI ร่างลำดับ {n}: {str(e).split(':', 1)[-1].strip()} ตัดออก")
            continue
        if not q:
            continue
        q = q[0]
        try:
            tn = int(item.get("topic"))
        except (TypeError, ValueError):
            tn = 0
        if 1 <= tn <= n_topics:
            q["topic"] = tn             # shown on the review card, removed before saving
        out.append(q)
    return out[:MAX_QUESTIONS], notes


def generate(spec: Dict[str, Any], files: List[Tuple[str, bytes]], user: Dict[str, Any],
             db_path: str = DB_PATH) -> Dict[str, Any]:
    """
    spec: target (quiz|midterm|final), course_code, course_name, level, topics [{label, text}] and topic_context
          (lesson_topics.resolve), kinds {kind: count}, difficulty, content_text, instructions
    """
    if spec.get("target") not in ("quiz", "midterm", "final"):
        raise ValueError("เลือกว่าจะออกแบบทดสอบย่อย กลางภาค หรือปลายภาค")
    allowed = list(QUIZ_KINDS) if spec["target"] == "quiz" else list(KINDS)
    kinds = {}
    for k, n in (spec.get("kinds") or {}).items():
        try:
            n = int(n)
        except (TypeError, ValueError):
            continue
        if k in allowed and n > 0:
            kinds[k] = min(n, 40)
    if not kinds:
        raise ValueError("เลือกชนิดข้อสอบและจำนวนข้ออย่างน้อย 1 ชนิด" + (" (แบบทดสอบย่อยใช้ข้อเขียนตอบไม่ได้)" if spec["target"] == "quiz" else ""))
    if sum(kinds.values()) > MAX_QUESTIONS:
        raise ValueError(f"ขอได้ครั้งละไม่เกิน {MAX_QUESTIONS} ข้อ")
    spec["kinds"] = kinds
    parts, names = [], []
    for fname, data in files:
        part, note = material_part(fname, data)
        parts.append(part)
        names.append(note)
    if not parts and not (spec.get("content_text") or "").strip() and not spec.get("topics"):
        raise ValueError("เลือกเรื่องที่จะออกข้อสอบ หรือแนบ/พิมพ์เนื้อหาบทเรียนอย่างน้อย 1 อย่าง")
    spec["has_files"] = bool(parts)
    code = user.get("code") or ""
    _take_one(code, db_path)
    try:
        reply, used = ask([{"text": build_prompt(spec)}] + parts, db_path, answer_timeout(sum(kinds.values()), bool(parts)))
        raw = parse_reply(reply)
    except Exception:
        _give_back(code, db_path)
        raise
    topics = spec.get("topics") or []
    qs, notes = clean_generated(raw, allowed, len(topics))
    if not qs:
        _give_back(code, db_path)
        raise RuntimeError("AI ร่างข้อสอบที่ใช้ได้ไม่ได้เลย ลองเพิ่มเนื้อหาหรือกดสร้างใหม่" + (f" ({notes[0]})" if notes else ""))
    chosen = model(db_path)
    return {"questions": qs, "notes": notes, "files": names, "topics": [t["label"] for t in topics], "model": used,
            "model_note": "" if used == chosen else f"รุ่น {chosen} ใช้ไม่ได้ตอนนี้ จึงให้รุ่นสำรอง {used} ร่างแทน ตรวจเฉลยให้ละเอียด",
            "left_today": max(0, daily_limit(db_path) - used_today(code, db_path))}


def test_connection(db_path: str = DB_PATH) -> str:
    reply, used = ask([{"text": 'ตอบเป็น JSON {"ok": true, "msg": "พร้อมช่วยครูออกข้อสอบ"} เท่านั้น'}], db_path, timeout=60)
    try:
        msg = str(json.loads(re.sub(r"^```(?:json)?\s*|\s*```$", "", reply.strip())).get("msg") or "พร้อมใช้งาน")
    except Exception:
        msg = "พร้อมใช้งาน"
    chosen = model(db_path)
    return f"{msg} (รุ่น {used})" if used == chosen else f"{msg} (รุ่น {chosen} ใช้ไม่ได้ตอนนี้ ตอบโดยรุ่นสำรอง {used})"
