"""
คลังเรื่องของตัวช่วย AI ออกข้อสอบ: subject -> grade -> chapters (บท), each with its group and sub-topics. The teacher
ticks "เรื่อง" instead of typing ตัวชี้วัด, and Gemini also sees every chapter of that grade so it knows the
context (owner, 17 พ.ย. 2569: "เอาทุกบทของแต่ละวิชา แต่ละชั้นมาด้วย จะได้รู้บริบทเนื้อหา").

  * Imported from Academic Hub's lesson library, the same file its Google Apps Script build serves
    (academic-module/src/data/lesson-curriculum.lazy.js):
        python lesson_topics.py import "<path>/lesson-curriculum.lazy.js"
    Node runs the file the way the browser does (some subjects are built by code). Every subject and grade is kept.
  * lesson_topics.json is this school's copy. The library belongs to the Academic Hub program the school is licensed
    to use, so the file is git-ignored and never goes into the public blank edition; the nightly backup and the
    Linux move kit carry it. Without it the AI page still works with topics the teacher types.
"""
import json
import os
import re
import subprocess
import sys
import threading
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

DATA_FILE = Path(__file__).resolve().parent / "lesson_topics.json"
MAX_CHAPTERS = 30       # chapters picked in one request
MAX_EXTRA = 20          # typed topic lines
MAX_CONTEXT = 12000     # characters of the whole-grade list sent with the request

# course name -> library subject, most specific first; then the first letter of the course code
NAME_RULES = [
    ("olymp", r"โอลิมปิก|สอวน"),
    ("phy", r"ฟิสิกส์"),
    ("chem", r"เคมี"),
    ("bio", r"ชีววิทยา"),
    ("earth", r"ดาราศาสตร์|อวกาศ|ธรณี"),
    ("work", r"การงาน"),
    ("tech", r"วิทยาการคำนวณ|คอมพิวเตอร์|ออกแบบ|เทคโนโลยี|โค้ด|โปรแกรม"),
    ("hist", r"ประวัติศาสตร์"),
    ("dance", r"นาฏ|ละคร"),
    ("music", r"ดนตรี|เปียโน|ขับร้อง|กีตาร์|อังกะลุง|โปงลาง|ระนาด"),
    ("cn", r"จีน"),
    ("eng", r"อังกฤษ|โฟนิกส์|english"),
    ("thai", r"ภาษาไทย"),
    ("guide", r"แนะแนว"),
    ("is", r"ค้นคว้า|นำเสนอ|บริการสังคม|\bis\s*\d?\b"),
    ("health", r"สุขศึกษา|พลศึกษา|มวย|กีฬา|ฟุตบอล|วอลเลย์|บาสเกตบอล|ตะกร้อ|แบดมินตัน|เปตอง"),
    ("soc", r"สังคม|พลเมือง|ทุจริต|ศาสนา|พระพุทธ|เศรษฐศาสตร์|ภูมิศาสตร์"),
    ("art", r"ศิลป|วาด"),
    ("math", r"คณิต"),
    ("sci", r"วิทยาศาสตร์"),
]
CODE_LETTER = {"ท": "thai", "ค": "math", "ว": "sci", "ส": "soc", "พ": "health", "ศ": "art", "ง": "work",
               "อ": "eng", "จ": "cn", "ก": "guide", "I": "is"}
# words in a course name -> the group of chapters it most likely teaches (only groups the grade has count)
GROUP_HINTS = [
    (r"ทุจริต|พลเมือง", "หน้าที่พลเมือง"), (r"ศาสนา|พระพุทธ", "ศาสนา"), (r"เศรษฐ", "เศรษฐศาสตร์"),
    (r"ภูมิศาสตร์", "ภูมิศาสตร์"), (r"สุขศึกษา", "สุขศึกษา"),
    (r"พลศึกษา|มวย|กีฬา|ฟุตบอล|วอลเลย์|บาสเกตบอล|ตะกร้อ|แบดมินตัน|เปตอง", "พลศึกษา"),
    (r"ออกแบบ", "การออกแบบ"), (r"วิทยาการคำนวณ|คอมพิวเตอร์|โค้ด|โปรแกรม", "วิทยาการคำนวณ"),
    (r"ค้นคว้า", "IS1"), (r"นำเสนอ", "IS2"), (r"บริการสังคม", "IS3"), (r"ชีวภาพ", "ชีวภาพ"), (r"กายภาพ", "กายภาพ"),
]

_lock = threading.Lock()
_cache: Dict[str, Any] = {}


def load() -> Dict[str, Any]:
    """The library ({} when it was never imported), read again whenever the file changes."""
    try:
        st = DATA_FILE.stat()
    except OSError:
        return {}
    key = (str(DATA_FILE), st.st_mtime_ns, st.st_size)
    with _lock:
        if _cache.get("key") != key:
            try:
                data = json.loads(DATA_FILE.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                data = {}
            ok = isinstance(data, dict) and isinstance(data.get("subjects"), list)
            _cache["key"], _cache["data"] = key, data if ok else {}
        return _cache["data"]


def _subjects() -> Dict[str, Dict[str, Any]]:
    return {s["id"]: s for s in load().get("subjects") or [] if isinstance(s, dict) and s.get("id")}


def chapters(sid: str, grade: str) -> List[Dict[str, Any]]:
    """[{group, name, topics: [...]}] in the order they are taught."""
    s = _subjects().get(sid or "")
    return list(((s or {}).get("grades") or {}).get(grade or "") or [])


def catalog() -> Dict[str, Any]:
    """What the pickers need: every subject with its grades (no chapters), and how big the library is."""
    d = load()
    subs = list(_subjects().values())
    return {"subjects": [{"id": s["id"], "name": s.get("name") or s["id"], "grades": list((s.get("grades") or {}).keys())}
                         for s in subs],
            "chapters": sum(len(cs) for s in subs for cs in (s.get("grades") or {}).values()),
            "imported_at": d.get("imported_at") or "", "source": d.get("source") or ""}


def guess(code: str, name: str, level: str) -> Dict[str, str]:
    """The library subject and grade of a course: by its name first (ฟิสิกส์, ดนตรี, ...), then by the first letter
    of its code; a subject that has the course's grade wins over one that has not."""
    subs = _subjects()
    cands = [sid for sid, pat in NAME_RULES if sid in subs and re.search(pat, name or "", re.I)]
    letter = CODE_LETTER.get((code or "").strip()[:1])
    if letter in subs:
        cands.append(letter)
    for sid in cands:
        if level in (subs[sid].get("grades") or {}):
            return {"subject": sid, "grade": level}
    return {"subject": cands[0] if cands else "", "grade": ""}


def suggest_groups(sid: str, grade: str, code: str, name: str, term: str) -> List[str]:
    """Groups of the grade this course most likely teaches (ภาคเรียนที่ 2, เพิ่มเติม, พลศึกษา, ...): the page opens
    them and folds the rest. [] = no idea, show everything."""
    groups: List[str] = []
    for c in chapters(sid, grade):
        g = c.get("group") or ""
        if g and g not in groups:
            groups.append(g)
    if len(groups) < 2:
        return []
    name, code = name or "", (code or "").strip()
    kind = code[3:4] if re.match(r"^\D\d{5}", code) else ""      # ค31202: 1 = พื้นฐาน, 2 = เพิ่มเติม
    want = {g for g in groups if g in name or g == f"ภาคเรียนที่ {term}"
            or (g == "พื้นฐาน" and kind == "1") or (g == "เพิ่มเติม" and kind == "2")}
    for pat, part in GROUP_HINTS:
        if re.search(pat, name):
            want |= {g for g in groups if part in g}
    return [g for g in groups if g in want]


def resolve(sid: str, grade: str, picked: Any, extra: str) -> Dict[str, Any]:
    """
    The teacher's choice checked against the library. topics = [{label, text}]: the picked chapters in library
    order (only sub-topics the chapter really has; none picked = the whole chapter), then the typed lines.
    context = every chapter of that grade, the picked ones marked, so the AI knows what comes before and after.
    """
    s = _subjects().get(sid or "") or {}
    chs = chapters(sid, grade)
    want: Dict[str, Optional[List[str]]] = {}
    for it in (picked if isinstance(picked, list) else [])[:MAX_CHAPTERS]:
        if isinstance(it, dict) and str(it.get("name") or "").strip():
            subs = it.get("topics")
            want[str(it["name"]).strip()] = [str(t).strip() for t in subs] if isinstance(subs, list) else None
    topics, marked = [], set()
    for i, c in enumerate(chs):
        if c.get("name") not in want:
            continue
        marked.add(i)
        every = c.get("topics") or []
        sel = [t for t in every if want[c["name"]] and t in want[c["name"]]]
        if sel and len(sel) < len(every):
            text = f"{c['name']} (เฉพาะหัวข้อย่อย: {'; '.join(sel)})"
        else:
            text = f"{c['name']} (ทุกหัวข้อย่อย: {'; '.join(every)})" if every else c["name"]
        topics.append({"label": c["name"], "text": text})
    for line in (extra or "").splitlines():
        if line.strip() and len(topics) < MAX_CHAPTERS + MAX_EXTRA:
            topics.append({"label": line.strip()[:80], "text": line.strip()[:600]})
    grade_full = ((load().get("grade_full") or {}).get(grade) or grade or "")
    return {"topics": topics, "subject_name": s.get("name") or "", "grade_full": grade_full,
            "context": _context(s.get("name") or "", grade_full, chs, marked)}


def _context(subject: str, grade_full: str, chs: List[Dict[str, Any]], marked: set) -> str:
    if not chs:
        return ""

    def lines(with_topics: bool) -> List[str]:
        out, group = [], None
        for i, c in enumerate(chs):
            if (c.get("group") or "") != group:
                group = c.get("group") or ""
                if group:
                    out.append(f"[{group}]")
            sub = "; ".join(c.get("topics") or [])
            star = "★ " if i in marked else ""
            out.append(f"{star}{i + 1}. {c['name']}" + (f": {sub}" if sub and (with_topics or i in marked) else ""))
        return out

    head = f"บทเรียนทั้งหมดของวิชา{subject} ชั้น{grade_full} ตามลำดับในหลักสูตร (★ = เรื่องที่ครูเลือก):"
    body = "\n".join(lines(True))
    if len(body) > MAX_CONTEXT:          # very long grades: names only for the chapters not picked
        body = "\n".join(lines(False))[:MAX_CONTEXT]
    return head + "\n" + body


# ---------------------------------------------------------------- import from Academic Hub

NODE_DUMP = r"""
const fs = require('fs'), vm = require('vm');
const ctx = { window: {} };
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1], 'utf8'), ctx, { timeout: 20000 });
const L = ctx.window.LSD;
if (!L || !Array.isArray(L.SUBJ)) throw new Error('window.LSD not found in this file');
const subjects = L.SUBJ.map(s => {
  const grades = {};
  for (const g of L.grades(s.id)) grades[g] = L.chapters(s.id, g).map(c => ({ group: c.g || '', name: c.n, topics: c.t || [] }));
  return { id: s.id, name: s.n, desc: s.d || '', grades };
});
process.stdout.write(JSON.stringify({ grade_full: L.GRADE_FULL || {}, subjects }));
"""


def import_academic_hub(js_path: str) -> Dict[str, int]:
    """Read Academic Hub's lesson-curriculum.lazy.js with Node and replace lesson_topics.json."""
    src = Path(js_path)
    if not src.is_file():
        raise RuntimeError(f"ไม่พบไฟล์ {src}")
    try:
        r = subprocess.run(["node", "-e", NODE_DUMP, str(src)], capture_output=True, timeout=120)
    except FileNotFoundError:
        raise RuntimeError("ต้องมี Node.js ในเครื่องเพื่ออ่านไฟล์ของ Academic Hub") from None
    if r.returncode != 0:
        raise RuntimeError("อ่านไฟล์ไม่สำเร็จ: " + r.stderr.decode("utf-8", "replace").strip()[-600:])
    data = json.loads(r.stdout.decode("utf-8"))
    subs = [s for s in data.get("subjects") or [] if s.get("id") and s.get("grades")]
    n_ch = sum(len(cs) for s in subs for cs in s["grades"].values())
    n_t = sum(len(c["topics"]) for s in subs for cs in s["grades"].values() for c in cs)
    if not n_ch:
        raise RuntimeError("ไฟล์นี้ไม่มีบทเรียน")
    out = {"source": f"Academic Hub ({src.name})", "imported_at": datetime.now().isoformat(timespec="seconds"),
           "grade_full": data.get("grade_full") or {}, "subjects": subs}
    tmp = DATA_FILE.with_name(DATA_FILE.name + ".tmp")
    tmp.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, DATA_FILE)
    return {"subjects": len(subs), "chapters": n_ch, "topics": n_t}


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    if len(sys.argv) == 3 and sys.argv[1] == "import":
        n = import_academic_hub(sys.argv[2])
        print(f"นำเข้าแล้ว {n['subjects']} วิชา {n['chapters']:,} บท {n['topics']:,} หัวข้อย่อย -> {DATA_FILE.name}")
    else:
        print(__doc__)
