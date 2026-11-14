"""
ข้อสอบจากไฟล์ Word (.docx / .doc) หรือ PDF -> ข้อสอบในฟอร์มของโปรแกรม (กลางภาค ปลายภาค และแบบทดสอบย่อย).

What a teacher's paper usually looks like, and what is understood:
  - questions "1." "1)" "ข้อ 1." "ข้อที่ 1" (also Word's automatic numbering and Thai digits ๑ ๒ ๓)
  - choices "ก." "(ก)" "ก)" "a." one per line or several on a line, or Word's automatic ก ข ค lists;
    choices written on the question's own line are split off
  - the correct answer:   a line "ตอบ ข" / "เฉลย ข" / "คำตอบ ข" under the question,
                          a "*" or "✓" at the choice,
                          the choice made bold / underlined / highlighted / coloured (exactly one of them),
                          or an answer key anywhere: "เฉลย" then "1. ข  2. ค ..." (or a table 1 | ข)
  - no choices + "ตอบ 45 ซม." = เติมตัวเลข (unit kept); no choices otherwise = เขียนตอบ ถ่ายภาพส่ง
    (the "เฉลย ..." text becomes the teacher's guide)
  - "ตอนที่ 2 ..." / "คำชี้แจง ..." end the question before them
  - a table of rows  โจทย์ | ก | ข | ค | ง | คำตอบ  (like the Excel paste)
Nothing is refused here: questions without a key come back with answer = None for the teacher to pick
(the editor marks them), with notes on what to check.
"""
import io
import re
import shutil
import os
import subprocess
import tempfile
import threading
import unicodedata
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

import exams

MAX_BYTES = 25 * 1024 * 1024
EM_ON, EM_OFF = "\x01", "\x02"   # emphasised text (bold / underline / highlight / colour) in the extracted lines
THAI_ALPHA = "กขคงจฉชซฌญฎฏฐฑฒณดตถทธนบปผฝพฟภมยรลวศษสหฬอฮ"
_THAI_DIGITS = str.maketrans("๐๑๒๓๔๕๖๗๘๙", "0123456789")
LETTERS = "กขคงจ"
_LAT = "abcde"


# ---------------------------------------------------------------- OCR (scanned PDF pages and photos of a paper)
# Tesseract with the Thai model: tools/tessdata/tha.traineddata (tessdata_best) when present, else the system's
# (Linux: apt install tesseract-ocr tesseract-ocr-tha; Windows: winget install UB-Mannheim.TesseractOCR).
TESSDATA = Path(__file__).resolve().parent / "tools" / "tessdata"
OCR_MAX_PAGES = 60
# One page at a time on one core: the school server (Ryzen 3 U, 2 cores) must keep serving the web while a
# teacher's scan is read; Tesseract is no faster with more threads here (1.4 s/page either way on the i9).
_OCR_LOCK = threading.Lock()
_OCR_ENV = {**os.environ, "OMP_THREAD_LIMIT": "1"}
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff", ".heic"}


def find_tesseract() -> Optional[str]:
    for c in (shutil.which("tesseract"), r"C:\Program Files\Tesseract-OCR\tesseract.exe",
              str(Path(__file__).resolve().parent / "tools" / "tesseract" / "tesseract.exe")):
        if c and Path(c).exists():
            return c
    return None


def _ocr_args() -> List[str]:
    if (TESSDATA / "tha.traineddata").exists():
        return ["--tessdata-dir", str(TESSDATA)]
    return []


def ocr_status() -> Dict[str, Any]:
    exe = find_tesseract()
    langs: List[str] = []
    if exe:
        try:
            r = subprocess.run([exe, *_ocr_args(), "--list-langs"], capture_output=True, timeout=30)
            langs = [x.strip() for x in r.stdout.decode("utf-8", "replace").splitlines()[1:] if x.strip()]
        except Exception:
            pass
    return {"available": bool(exe) and "tha" in langs, "engine": exe, "languages": langs}


# ---------------------------------------------------------------- OCR with positions (scanned pages): lines + the page picture

LAYOUT_W = 1240          # page pictures kept for cutting question figures (about 150 dpi for A4)
_job = threading.local()  # the reading in progress: .progress (callback) and .layout


class Layout:
    """Pages read by OCR: a small copy of each page, every word's box, and the kept lines (by id)."""

    def __init__(self):
        self.pages: Dict[int, Any] = {}
        self.words: Dict[int, List[Tuple[int, int, int, int]]] = {}
        self.lines: List[Dict[str, Any]] = []


def _progress(msg: str) -> None:
    cb = getattr(_job, "progress", None)
    if cb:
        try:
            cb(msg)
        except Exception:
            pass


def _tesseract_words(img) -> Tuple[List[Dict[str, Any]], List[str]]:
    """Every word with its box (TSV) and the text lines as Tesseract spaces them (Thai words kept whole)."""
    import csv
    exe = find_tesseract()
    if not exe:
        raise ValueError("ยังไม่ได้ติดตั้งโปรแกรมอ่านภาพ (OCR) — แจ้งผู้ดูแลระบบ หรือใช้ไฟล์ Word")
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / "page.png"
        img.save(src)
        with _OCR_LOCK:
            r = subprocess.run([exe, str(src), str(Path(d) / "out"), "-l", "tha+eng", "--psm", "6", *_ocr_args(),
                                "-c", "preserve_interword_spaces=1", "-c", "tessedit_create_tsv=1", "-c", "tessedit_create_txt=1"],
                               capture_output=True, timeout=180, env=_OCR_ENV)
        if r.returncode != 0 or not (Path(d) / "out.tsv").exists():
            raise ValueError("อ่านภาพไม่สำเร็จ: " + r.stderr.decode("utf-8", "replace")[-200:])
        tsv = (Path(d) / "out.tsv").read_text(encoding="utf-8", errors="replace")
        txt = (Path(d) / "out.txt").read_text(encoding="utf-8", errors="replace") if (Path(d) / "out.txt").exists() else ""
    out = []
    for w in csv.DictReader(io.StringIO(tsv), delimiter="\t", quoting=csv.QUOTE_NONE):
        t = (w.get("text") or "").strip()
        if w.get("level") != "5" or not t:
            continue
        try:
            out.append({"key": (int(w["block_num"]), int(w["par_num"]), int(w["line_num"])), "text": t,
                        "x0": int(w["left"]), "y0": int(w["top"]), "x1": int(w["left"]) + int(w["width"]),
                        "y1": int(w["top"]) + int(w["height"]), "conf": float(w["conf"])})
        except (KeyError, ValueError):
            continue
    return out, [ln.rstrip() for ln in txt.splitlines() if ln.strip()]


def _spaced(line: str, ws: List[Dict[str, Any]]) -> Optional[List[str]]:
    """The spaces Tesseract wrote before each word of a line, or None if the line and the words do not match."""
    out, i = [], 0
    for w in ws:
        j = i
        while j < len(line) and line[j] == " ":
            j += 1
        if line[j:j + len(w["text"])] != w["text"]:
            return None
        out.append(line[i:j])
        i = j + len(w["text"])
    return out if not line[i:].strip() else None


def _median(xs: List[float]) -> float:
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else 0.0


_ITEM_MARK = re.compile(r"^\(?[\d๐-๙]{1,3}[.)]$|^\(?[ก-ฮA-Ea-e][.)]$")


def _margin_strip(groups: Dict[tuple, List[Dict[str, Any]]], W: int) -> Dict[tuple, List[tuple]]:
    """A strip down the edge of the page: a book title printed sideways, side tabs ("คณิตศาสตร์"). OCR reads it
    as a few letters at the start (or end) of many lines, far from the text ("a        8. นักเรียน…"), and the
    question number no longer starts the line. Those words are taken out of the lines (in place);
    returns {line: [(side, removed words)]}."""
    gone: Dict[tuple, List[tuple]] = {}
    for side in ("left", "right"):
        cands = []
        for k, ws in groups.items():
            ws = sorted(ws, key=lambda w: w["x0"])
            h = max(8.0, _median([w["y1"] - w["y0"] for w in ws]))
            wide = max(2.5 * h, 0.03 * W)
            if side == "left":
                j = 1
                while j < len(ws) and ws[j]["x0"] - max(w["x1"] for w in ws[:j]) <= wide:
                    j += 1
                part = ws[:j]
                outside = max(w["x1"] for w in part) < 0.2 * W
            else:
                j = len(ws) - 1
                while j > 0 and min(w["x0"] for w in ws[j:]) - ws[j - 1]["x1"] <= wide:
                    j -= 1
                part = ws[j:]
                outside = min(w["x0"] for w in part) > 0.8 * W
            text = "".join(w["text"] for w in part)
            if outside and len(text) <= 4 and not _ITEM_MARK.match(text):
                cands.append((k, part))
        if len(cands) < 3:
            continue
        keys = {k for k, _ in cands}
        if side == "left":
            edge = max(w["x1"] for _, part in cands for w in part)
            inside = [k for k, ws in groups.items() if k not in keys and min(w["x0"] for w in ws) < edge]
        else:
            edge = min(w["x0"] for _, part in cands for w in part)
            inside = [k for k, ws in groups.items() if k not in keys and max(w["x1"] for w in ws) > edge]
        if len(inside) > max(1, len(cands) // 4):
            continue                          # text reaches there: the page's own lines, not a strip
        junk = {id(w) for _, part in cands for w in part}
        for k in list(groups):
            out = [w for w in groups[k] if id(w) in junk]
            if not out:
                continue
            keep = [w for w in groups[k] if all(w is not o for o in out)]
            gone.setdefault(k, []).append((side, sorted(out, key=lambda w: w["x0"])))
            if keep:
                groups[k] = keep
            else:
                del groups[k]
    return gone


def _missed_rows(img, words: List[Dict[str, Any]], hl: float, lines: List[Tuple[int, int, int, int]]) -> List[Tuple[int, int, int, int]]:
    """Rows of ink with a text line's shape that no word box covers: Tesseract sometimes skips a whole line that
    shares its height with a drawing ("24. จงหาค่าของ y − x" beside two slanted lines)."""
    import numpy as np
    a = (np.asarray(img.convert("L")) < 150).copy()
    H, W = a.shape
    for w in words:
        a[max(0, w["y0"] - 3):w["y1"] + 3, max(0, w["x0"] - 3):w["x1"] + 3] = False
    c = max(3, int(hl / 6))
    gh, gw = H // c, W // c
    if gh < 3 or gw < 3:
        return []
    grid = a[:gh * c, :gw * c].reshape(gh, c, gw, c).sum(axis=(1, 3)) >= 2
    # the letters of a line joined: gaps up to about one letter height closed along each row
    g = max(1, int(round(1.2 * hl / c)))
    pad = np.pad(grid, ((0, 0), (g, g))).astype(np.int32)
    cs = np.concatenate([np.zeros((gh, 1), np.int32), pad.cumsum(axis=1)], axis=1)
    near = (cs[:, 2 * g + 1:] - cs[:, :-2 * g - 1]) > 0                      # ink within g cells
    pad2 = np.pad(near, ((0, 0), (g, g)), constant_values=True).astype(np.int32)
    cs2 = np.concatenate([np.zeros((gh, 1), np.int32), pad2.cumsum(axis=1)], axis=1)
    closed = (cs2[:, 2 * g + 1:] - cs2[:, :-2 * g - 1]) == 2 * g + 1
    seen = np.zeros_like(closed, dtype=bool)
    found = []
    for i, j in zip(*np.nonzero(closed)):
        if seen[i, j]:
            continue
        stack, y0, y1, x0, x1, n = [(i, j)], i, i, j, j, 0
        seen[i, j] = True
        while stack:
            y, x = stack.pop()
            n += 1
            y0, y1, x0, x1 = min(y0, y), max(y1, y), min(x0, x), max(x1, x)
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < gh and 0 <= nx < gw and closed[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        bh, bw = (y1 - y0 + 1) * c, (x1 - x0 + 1) * c
        if 0.5 * hl <= bh <= 2.0 * hl and bw >= 2.5 * hl and grid[y0:y1 + 1, x0:x1 + 1].mean() >= 0.15:
            box = (x0 * c, y0 * c, (x1 + 1) * c, (y1 + 1) * c)
            mid = (box[1] + box[3]) / 2
            # ink of a line that was read (letters its word boxes miss) is not a missed line
            if not any(ly0 - 0.3 * hl <= mid <= ly1 + 0.3 * hl and box[0] < lx1 and box[2] > lx0 for lx0, ly0, lx1, ly1 in lines):
                found.append(box)
    return found


def _read_missed(img, words: List[Dict[str, Any]], hl: float, lines: List[Tuple[int, int, int, int]]):
    """Read the rows _missed_rows found, all in one picture (one OCR run): {line key: (words, text)}."""
    from PIL import Image
    rows = _missed_rows(img, words, hl, lines)
    if not rows or len(rows) > 24:          # none, or a page full of specks (a photo): leave it
        return {}
    p = int(hl * 0.6)
    crops = [(max(0, x0 - p), max(0, y0 - p), min(img.width, x1 + p), min(img.height, y1 + p)) for x0, y0, x1, y1 in rows]
    gap = int(hl * 1.5)
    sheet = Image.new("L", (max(b[2] - b[0] for b in crops) + 2 * gap, sum(b[3] - b[1] + gap for b in crops) + gap), 255)
    at, y = [], gap
    for b in crops:
        sheet.paste(img.convert("L").crop(b), (gap, y))
        at.append((y, y + b[3] - b[1], b))
        y += b[3] - b[1] + gap
    got, txt = _tesseract_words(sheet)
    groups: Dict[tuple, List[Dict[str, Any]]] = {}
    for w in got:
        groups.setdefault(w["key"], []).append(w)
    texts = dict(zip(groups.keys(), txt)) if len(txt) == len(groups) else {}
    out = {}
    for k, ws in groups.items():
        mid = _median([(w["y0"] + w["y1"]) / 2 for w in ws])
        for n, (t0, t1, b) in enumerate(at):
            if t0 - gap / 2 <= mid <= t1 + gap / 2:
                dx, dy = b[0] - gap, b[1] - t0
                out[(1000 + n,) + k] = ([dict(w, x0=w["x0"] + dx, x1=w["x1"] + dx, y0=w["y0"] + dy, y1=w["y1"] + dy, key=(1000 + n,) + k)
                                         for w in ws], texts.get(k))
                break
    return out


def _ocr_lines(img, ox: int = 0):
    """OCR one picture (a page or one column of it) -> ([(text, words, height)], every word box), x shifted by ox.
    Stray vowel / tone marks that Tesseract puts on lines of their own (much shorter than the text lines) and
    specks are left out."""
    words, txt_lines = _tesseract_words(img)
    groups: Dict[tuple, List[Dict[str, Any]]] = {}
    for w in words:
        groups.setdefault(w["key"], []).append(w)
    texts = dict(zip(groups.keys(), txt_lines)) if len(txt_lines) == len(groups) else {}
    # lines Tesseract skipped (beside a drawing): read again on their own
    ext = sorted(max(w["y1"] for w in ws) - min(w["y0"] for w in ws) for ws in groups.values()
                 if len(ws) >= 4 and sum(w["conf"] for w in ws) / len(ws) >= 80)
    if ext:
        boxes = [(min(w["x0"] for w in ws), min(w["y0"] for w in ws), max(w["x1"] for w in ws), max(w["y1"] for w in ws))
                 for ws in groups.values()]
        for k, (ws, t) in _read_missed(img, words, ext[len(ext) // 2], boxes).items():
            groups[k] = ws
            words.extend(ws)
            if t is not None:
                texts[k] = t
    for k, cuts in _margin_strip(groups, img.width).items():
        t = texts.pop(k, None)
        for side, out in cuts:            # the same words off Tesseract's text line, so its spacing is kept
            if t is None:
                break
            if side == "left":
                i = 0
                for w in out:
                    j = t.find(w["text"], i)
                    i = j + len(w["text"]) if j >= 0 else -1
                    if i < 0:
                        break
                t = t[i:] if i >= 0 else None
            else:
                i = len(t)
                for w in reversed(out):
                    i = t.rfind(w["text"], 0, i)
                    if i < 0:
                        break
                t = t[:i] if i >= 0 else None
        if t is not None and k in groups:
            texts[k] = t
    heights = {k: _median([w["y1"] - w["y0"] for w in ws]) for k, ws in groups.items()}
    # the height of a text line: stray mark lines are as many as the text lines on a scan, so not the median
    full = sorted(heights[k] for k, ws in groups.items() if len(ws) >= 3) or sorted(heights.values()) or [1]
    med = full[int(len(full) * 0.7)] if len(full) > 1 else full[0]
    out = []
    for k, ws in groups.items():
        h = heights[k]
        conf = sum(w["conf"] for w in ws) / len(ws)
        size = sum(len(w["text"]) for w in ws)
        has_digit = any(ch.isdigit() for w in ws for ch in w["text"])
        # letters and digits, not the marks above / below them: a line of stray marks has (almost) none.
        # Some fonts are read one letter per box, and a box of ก is much lower than one of ที่ — a line read
        # clearly with many letters is text whatever its boxes' height
        solid = sum(1 for w in ws for ch in w["text"] if unicodedata.category(ch)[0] in "LN")
        clear = solid >= 6 and solid >= 0.5 * size and sum(1 for w in ws if w["conf"] >= 80) >= 0.7 * len(ws)
        if not clear and (h < 0.6 * med or (h < 0.8 * med and conf < 85)):
            continue
        if (conf < 65 and size <= 12 and not has_digit) or (conf < 60 and size <= 3) or not solid:
            continue
        spaces = _spaced(texts[k], ws) if k in texts else None
        if spaces is None:
            ws = sorted(ws, key=lambda w: w["x0"])
            spaces, prev = [], None
            for w in ws:
                gap = w["x0"] - prev["x1"] if prev is not None else 0
                spaces.append("" if prev is None else ("   " if gap > 1.6 * h else (" " if gap > 0.6 * h else "")))
                prev = w
        # a drawing read as letters at the end of a line ("rrr รรรร"): low-confidence words after a wide gap
        while len(ws) > 1:
            cut = max(j for j in range(len(ws)) if j == 0 or len(spaces[j]) >= 3)
            tail = ws[cut:]
            if cut == 0 or any(re.search(r"[\d()]", w["text"]) for w in tail) or sum(w["conf"] for w in tail) / len(tail) >= 60:
                break
            ws, spaces = ws[:cut], spaces[:cut]
        text = "".join(sp + w["text"] for sp, w in zip(spaces, ws)).strip()
        # a short line starting in the right half with no digits: a label in a drawing ("น้ำมัน") or a drawing
        # read as letters — it stays in the picture, not in the question's text
        if (min(w["x0"] for w in ws) > 0.45 * img.width and len(text) <= 14 and not has_digit and not text.startswith("(")
                and not _CHOICE.match(text) and not _Q_START.match(text)):
            continue
        out.append((text, [dict(w, x0=w["x0"] + ox, x1=w["x1"] + ox) for w in ws], h))
    out.sort(key=lambda t: min(w["y0"] for w in t[1]))
    return out, [(w["x0"] + ox, w["y0"], w["x1"] + ox, w["y1"]) for w in words]


def ocr_page(img, layout: Optional["Layout"] = None) -> List[Tuple[str, Optional[int]]]:
    """One page image -> [(line text, line id in layout)]. Two columns of questions are read one after the other."""
    from PIL import ImageOps
    img = ImageOps.exif_transpose(img).convert("L")
    if img.width < 1600:                       # small phone photos read better enlarged
        k = 2000 / img.width
        img = img.resize((int(img.width * k), int(img.height * k)))
    W, H = img.size
    parts = None
    split = _ink_gutter(img)
    if split:
        left, lw = _ocr_lines(img.crop((0, 0, split, H)), 0)
        right, rw = _ocr_lines(img.crop((split, 0, W, H)), split)
        if any(_NUM_LINE.match(t) for t, _, _ in right) and any(_NUM_LINE.match(t) for t, _, _ in left):
            parts, all_words = [(left, (0, split)), (right, (split, W))], lw + rw
    if parts is None:
        whole, all_words = _ocr_lines(img, 0)
        parts = [(whole, (0, W))]
    page, scale = None, 1.0
    if layout is not None:
        page = len(layout.pages)
        scale = min(1.0, LAYOUT_W / img.width)
        layout.pages[page] = img.resize((int(img.width * scale), int(img.height * scale))) if scale < 1 else img.copy()
        layout.words[page] = [tuple(int(v * scale) for v in b) for b in all_words]
    out: List[Tuple[str, Optional[int]]] = []
    for lines_, col in parts:
        for text, ws, h in lines_:
            lid = None
            if layout is not None:
                lid = len(layout.lines)
                layout.lines.append({"page": page, "h": h * scale, "col": (int(col[0] * scale), int(col[1] * scale)), "ocr": True,
                                     "box": tuple(int(v * scale) for v in (min(w["x0"] for w in ws), min(w["y0"] for w in ws),
                                                                           max(w["x1"] for w in ws), max(w["y1"] for w in ws))),
                                     "words": [(w["text"], *(int(v * scale) for v in (w["x0"], w["y0"], w["x1"], w["y1"]))) for w in ws]})
            out.append((text, lid))
    return out


def ocr_image(img) -> List[str]:
    """Lines of text in one page image (PIL)."""
    return [t for t, _ in ocr_page(img)]


def image_lines(data: bytes) -> Tuple[List[str], Dict[str, Any]]:
    from PIL import Image
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
    except Exception:
        raise ValueError("เปิดไฟล์ภาพไม่ได้")
    _progress("กำลังอ่านภาพ...")
    got = ocr_page(img, getattr(_job, "layout", None))
    return [t for t, _ in got], {"images": 0, "ocr_pages": 1, "pos": [p for _, p in got]}


_NUM_LINE = re.compile(r"^\s*(?:ข้อ\s*)?\d{1,3}\s*[.)]")


def _layout_words(words: List[tuple], k: float, num_end: Dict[tuple, float]) -> List[tuple]:
    """Boxes of a PDF line's pieces for the page picture; a leading question number gets a box of its own."""
    out = []
    for n, s in enumerate(words):
        y0, y1 = int((s[0] - s[4] / 2) * k), int((s[0] + s[4] / 2) * k)
        nx = num_end.get((round(s[0], 2), round(s[1], 2))) if n == 0 else None
        text = _plain(s[3])
        if nx is not None and nx < s[2]:
            m = re.match(r"\s*(?:ข้อ\s*)?\d{1,3}\s*[.)]", text)
            out.append((m.group(0).strip() if m else text, int(s[1] * k), y0, int(nx * k), y1))
            out.append((text[m.end():].strip() if m else "", int(nx * k), y0, int(s[2] * k), y1))
        else:
            out.append((text, int(s[1] * k), y0, int(s[2] * k), y1))
    return out


def _text_gutter(spans: List[tuple], width: float) -> Optional[float]:
    """x of the gap between two columns of questions (text PDF), or None for one column.
    Both sides must start questions ("12. ...") so a drawing beside the text is not a column."""
    real = [s for s in spans if s[4] and _plain(s[3]).strip()]
    if len(real) < 12:
        return None
    W = int(width) + 1
    cover = [0] * (W + 1)
    for s in real:
        for x in range(max(0, int(s[1])), min(W, int(s[2]) + 1)):
            cover[x] += 1
    lo, hi = int(W * 0.3), int(W * 0.7)
    tol = max(1, int(len(real) * 0.03))
    best, run, start = None, 0, None
    for x in range(lo, hi + 1):
        if cover[x] <= tol:
            if start is None:
                start = x
            run = x - start + 1
            if best is None or run > best[1]:
                best = (start, run)
        else:
            start, run = None, 0
    if not best or best[1] < W * 0.015:
        return None
    # inside that band, the middle of the stretch with the fewest letters (the real gap between the columns)
    low = min(cover[x] for x in range(best[0], best[0] + best[1]))
    run2, start2, top2 = None, None, None
    for x in range(best[0], best[0] + best[1] + 1):
        if x < best[0] + best[1] and cover[x] == low:
            start2 = x if start2 is None else start2
        elif start2 is not None:
            if top2 is None or x - start2 > top2[1]:
                top2 = (start2, x - start2)
            start2 = None
    split = top2[0] + top2[1] / 2 if top2 else best[0] + best[1] / 2
    left = [s for s in real if s[2] <= split + 2]
    right = [s for s in real if s[1] >= split - 2]
    if len(left) < len(real) * 0.2 or len(right) < len(real) * 0.2:
        return None
    # a question number at the start of a line on both sides
    def starts(ss):
        rows: Dict[int, tuple] = {}
        for s in ss:
            key = round(s[0])
            if key not in rows or s[1] < rows[key][1]:
                rows[key] = s
        return sum(1 for s in rows.values() if _NUM_LINE.match(_plain(s[3])))
    if starts(left) < 1 or starts(right) < 1:
        return None
    return split


def _ink_gutter(img) -> Optional[int]:
    """x of a white band down the middle of a scanned page (two columns), or None."""
    import numpy as np
    a = np.asarray(img.convert("L")) < 150
    H, W = a.shape
    body = a[int(H * 0.08):int(H * 0.95)]
    rows_with_ink = body.any(axis=1)
    n = max(1, int(rows_with_ink.sum()))
    # how many text rows touch each x (in bands of 8 rows to ignore specks)
    bands = body[:body.shape[0] // 8 * 8].reshape(-1, 8, W).any(axis=1)
    cover = bands.sum(axis=0) / max(1, bands.any(axis=1).sum())
    lo, hi = int(W * 0.3), int(W * 0.7)
    best, start = None, None
    for x in range(lo, hi + 1):
        if cover[x] <= 0.03:
            start = x if start is None else start
            if best is None or x - start + 1 > best[1]:
                best = (start, x - start + 1)
        else:
            start = None
    if not best or best[1] < W * 0.02 or n < 50:
        return None
    split = int(best[0] + best[1] / 2)
    left, right = body[:, :split].sum(), body[:, split:].sum()
    total = max(1, left + right)
    if left < 0.2 * total or right < 0.2 * total:
        return None
    return split


def _figure_parts(gray, boxes: List[Tuple[int, int, int, int]]) -> List[Tuple[int, int, int, int]]:
    """Drawings in a cut of the page: dark ink that is not a word, as big connected parts (coarse 8 px cells)."""
    import numpy as np
    a = (np.asarray(gray) < 150).copy()
    H, W = a.shape
    for (x0, y0, x1, y1) in boxes:
        a[max(0, y0 - 3):max(0, y1 + 3), max(0, x0 - 3):max(0, x1 + 3)] = False
    c = 8
    gh, gw = H // c, W // c
    if gh < 3 or gw < 3:
        return []
    grid = a[:gh * c, :gw * c].reshape(gh, c, gw, c).sum(axis=(1, 3)) >= 3
    seen = np.zeros_like(grid, dtype=bool)
    found = []
    for i in range(gh):
        for j in range(gw):
            if grid[i, j] and not seen[i, j]:
                stack, cells = [(i, j)], []
                seen[i, j] = True
                while stack:
                    y, x = stack.pop()
                    cells.append((y, x))
                    for dy in (-1, 0, 1):
                        for dx in (-1, 0, 1):
                            ny, nx = y + dy, x + dx
                            if 0 <= ny < gh and 0 <= nx < gw and grid[ny, nx] and not seen[ny, nx]:
                                seen[ny, nx] = True
                                stack.append((ny, nx))
                ys = [p[0] for p in cells]
                xs = [p[1] for p in cells]
                if len(cells) >= 30 and max(ys) - min(ys) >= 4 and max(xs) - min(xs) >= 4:
                    found.append((min(xs) * c, min(ys) * c, (max(xs) + 1) * c, (max(ys) + 1) * c))
    return found


def _answer_boxes(line: Dict[str, Any], took_answer: bool = False) -> List[Tuple[int, int, int, int]]:
    """The answer printed at the right end of a line, "(0.16 kg/m3)" / "(ข้อ 4)", to blank out in the picture.
    took_answer: the parser read an answer from this line, so its last bracket is the answer even without a gap."""
    ws = line["words"]
    h = line["h"] or 10
    for j in range(len(ws) - 1, -1, -1):
        if ws[j][0].startswith("("):
            if j == 0 and (not took_answer or len(ws) > 6):
                break                     # "(มช 41) ..." opening a line is not an answer
            if not re.match(r"^\(\s*[0-9A-Za-zก-๛]", "".join(w[0] for w in ws[j:])):
                break                     # "(|": an angle of a drawing read as a bracket
            far = j > 0 and ws[j][1] - ws[j - 1][3] > 1.2 * h
            if far or took_answer or re.match(r"^\(\s*ข้อ", "".join(w[0] for w in ws[j:j + 2])):
                return [(ws[j][1], min(w[2] for w in ws[j:]), max(w[3] for w in ws[j:]), max(w[4] for w in ws[j:]))]
            break
    return []


def _attach_figures(out: List[Dict[str, Any]], layout: "Layout", notes: List[str]) -> None:
    """Each question read from a page picture gets the drawing beside it (cut from the page) and a picture of the
    whole question as printed; answers in brackets are blanked."""
    from PIL import ImageDraw, ImageOps
    if not layout.lines:
        return
    by_page: Dict[int, List[int]] = {}
    for i, ln in enumerate(layout.lines):
        by_page.setdefault(ln["page"], []).append(i)
    cut = 0
    for q in out:
        ids = [i for i in q.get("_lines") or [] if i is not None]
        if not ids:
            continue
        page = layout.lines[ids[0]]["page"]
        mine = [i for i in ids if layout.lines[i]["page"] == page]
        mine_set = set(mine)
        img = layout.pages[page]
        boxes = [layout.lines[i]["box"] for i in mine]
        y0 = min(b[1] for b in boxes)
        y1 = max(b[3] for b in boxes)
        col = layout.lines[mine[0]].get("col") or (0, img.width)
        cw = col[1] - col[0]

        def same_col(i):
            c = layout.lines[i].get("col") or (0, img.width)
            return c == col or (c[1] - c[0]) > cw * 1.5          # a full-width line bounds both columns
        others = [i for i in by_page[page] if i not in mine_set and same_col(i)]
        later = [layout.lines[i]["box"][1] for i in others if layout.lines[i]["box"][1] > y1 - 2]
        bottom = min(later) - 4 if later else img.height - 10
        stop = q.get("_stop")
        if stop is not None and layout.lines[stop]["page"] == page:
            bottom = min(bottom, layout.lines[stop]["box"][1] - 4)
        # a drawing beside the question may start above its first line: up to the text line before it
        # (only lines starting in the left half count: labels of a drawing on the right are not a boundary)
        above = [layout.lines[i]["box"][3] for i in others
                 if layout.lines[i]["box"][3] <= y0 + 2 and layout.lines[i]["box"][0] < col[0] + cw * 0.5]
        top_ext = max(above) + 4 if above else 0
        x0 = col[0] + 4 if col[0] > 0 else int(img.width * 0.03)
        x1 = col[1] - 4 if col[1] < img.width else int(img.width * 0.97)
        top = max(0, y0 - 8)
        if bottom <= top + 10:
            continue
        # where the paper's text runs on this page (column): a strip down the margin (a title printed sideways,
        # side tabs) or a page number with a tree at the foot is not part of any question
        span = [layout.lines[i]["box"] for i in by_page[page] if (layout.lines[i].get("col") or (0, img.width)) == col] or boxes
        lo, hi = min(b[0] for b in span), max(b[2] for b in span)
        lh = _median([b[3] - b[1] for b in boxes]) or 10
        own_words = [w[1:] for i in mine for w in layout.lines[i]["words"]]
        page_words = layout.words.get(page, [])
        inside = [b for b in page_words if b[3] > top_ext and b[1] < bottom and b[2] > x0 and b[0] < x1]
        area = img.crop((x0, top_ext, x1, bottom)).copy()
        parts = [p for p in _figure_parts(area, [(b[0] - x0, b[1] - top_ext, b[2] - x0, b[3] - top_ext) for b in inside])
                 if p[3] + top_ext > y0 and p[1] + top_ext < y1 + 2 * lh       # beside / just under the question's lines
                 and not ((p[2] + x0 <= lo or p[0] + x0 >= hi)                  # not out in the margin
                          and (p[2] + x0 <= img.width * 0.15 or p[0] + x0 >= img.width * 0.85))]
        draw = ImageDraw.Draw(area)
        # the paper's own number ("2.") would not match the student's order (questions are shuffled)
        first = layout.lines[mine[0]]["words"]
        if first and re.fullmatch(r"(?:ข้อ)?\s*\d{1,3}\s*[.),]?", first[0][0].strip()):     # "4," = "4." read by OCR
            fx0_, fy0_, fx1_, fy1_ = first[0][1:]
            draw.rectangle((fx0_ - x0 - 2, fy0_ - top_ext - 2, fx1_ - x0 + 2, fy1_ - top_ext + 2), fill=255)
        for i in mine:
            took = i in (q.get("_ans_lines") or ())
            for (a0, b0, a1, b1) in _answer_boxes(layout.lines[i], took):
                draw.rectangle((a0 - x0 - 3, b0 - top_ext - 3, a1 - x0 + 3, b1 - top_ext + 3), fill=255)
        fig = None
        if parts:
            fx0, fy0 = min(p[0] for p in parts), min(p[1] for p in parts)
            fx1, fy1 = max(p[2] for p in parts), max(p[3] for p in parts)
            # labels written in / next to the drawing ("10 cm", "น้ำมัน"), not the question's own words
            own = {tuple(w) for w in own_words}
            for b in inside:
                if tuple(b) in own:
                    continue
                bx0, by0, bx1, by1 = b[0] - x0, b[1] - top_ext, b[2] - x0, b[3] - top_ext
                if bx1 > fx0 - 30 and bx0 < fx1 + 30 and by1 > fy0 - 30 and by0 < fy1 + 30:
                    fx0, fy0, fx1, fy1 = min(fx0, bx0), min(fy0, by0), max(fx1, bx1), max(fy1, by1)
            fig = (max(0, fx0 - 12), max(0, fy0 - 12), min(area.width, fx1 + 12), min(area.height, fy1 + 12))
        # the whole question as printed (with its drawing): the teacher may show it instead of the OCR text
        wy0 = min(top - top_ext, fig[1] if fig else top - top_ext)
        wx0 = max(0, min(lo - x0 - 10, fig[0] if fig else area.width))
        wx1 = min(area.width, max(hi - x0 + 10, fig[2] if fig else 0))
        # down to its last line or drawing, and the rows of ink right under them (a line OCR left out);
        # a blank gap ends the question (not the page's foot)
        import numpy as np
        rows = (np.asarray(area.crop((wx0, 0, max(wx0 + 1, wx1), area.height))) < 150).any(axis=1)
        wy1, gap = max(y1 - top_ext, fig[3] if fig else 0), 0
        while wy1 + gap < area.height and gap < 0.8 * lh:
            if rows[wy1 + gap]:
                wy1, gap = wy1 + gap + 1, 0
            else:
                gap += 1
        whole = area.crop((wx0, max(0, wy0), max(wx0 + 1, wx1), min(area.height, wy1 + 6)))
        ink = ImageOps.invert(whole).point(lambda v: 255 if v > 90 else 0).getbbox()
        if ink:
            whole = whole.crop((max(0, ink[0] - 10), max(0, ink[1] - 8), min(whole.width, ink[2] + 10), min(whole.height, ink[3] + 8)))
            q["_scan"] = _save_png(whole)
        if not fig:
            continue
        name = _save_png(area.crop(fig))
        if name:
            q["_figures"] = (q.get("_figures") or []) + [name]
            cut += 1
    if cut:
        notes.append(f"ตัดรูปประกอบจากหน้ากระดาษให้ {cut} ข้อ (ปิดคำตอบในวงเล็บไว้แล้ว) — ตรวจว่ารูปตรงกับข้อ")


def _save_png(img) -> Optional[str]:
    buf = io.BytesIO()
    img.save(buf, "PNG")
    try:
        return exams.save_image(buf.getvalue())
    except Exception:
        return None


def _compose(names: List[str]) -> str:
    """Several pictures of one question as one (stacked)."""
    from PIL import Image
    imgs = []
    for n in names[:4]:
        try:
            imgs.append(Image.open(exams.IMAGE_DIR / n).convert("RGB"))
        except Exception:
            pass
    if not imgs:
        return names[0]
    if len(imgs) == 1:
        return names[0]
    w = max(i.width for i in imgs)
    h = sum(i.height for i in imgs) + 12 * (len(imgs) - 1)
    out = Image.new("RGB", (w, h), (255, 255, 255))
    y = 0
    for i in imgs:
        out.paste(i, (0, y))
        y += i.height + 12
    buf = io.BytesIO()
    out.save(buf, "PNG")
    return exams.save_image(buf.getvalue())


# ---------------------------------------------------------------- reading the file

def _fmt_num(n: int, fmt: str) -> str:
    if fmt in ("thaiLetters",):
        return THAI_ALPHA[(n - 1) % len(THAI_ALPHA)]
    if fmt in ("lowerLetter",):
        return "abcdefghijklmnopqrstuvwxyz"[(n - 1) % 26]
    if fmt in ("upperLetter",):
        return "ABCDEFGHIJKLMNOPQRSTUVWXYZ"[(n - 1) % 26]
    if fmt in ("bullet", "none"):
        return ""
    return str(n)  # decimal, thaiNumbers, thaiCounting ... -> a plain number


class _Numbering:
    """Word's automatic list numbers (not part of the paragraph text): rebuilt from numbering.xml."""

    def __init__(self, doc):
        from docx.oxml.ns import qn
        self.qn = qn
        self.num_abs: Dict[str, str] = {}
        self.levels: Dict[str, Dict[int, Tuple[str, str, int]]] = {}
        self.count: Dict[str, Dict[int, int]] = {}
        try:
            root = doc.part.numbering_part.element
        except Exception:
            return
        for a in root.findall(qn("w:abstractNum")):
            aid = a.get(qn("w:abstractNumId"))
            lv = {}
            for l in a.findall(qn("w:lvl")):
                il = int(l.get(qn("w:ilvl")) or 0)
                fmt = l.find(qn("w:numFmt"))
                txt = l.find(qn("w:lvlText"))
                st = l.find(qn("w:start"))
                lv[il] = (fmt.get(qn("w:val")) if fmt is not None else "decimal",
                          txt.get(qn("w:val")) if txt is not None else f"%{il + 1}.",
                          int(st.get(qn("w:val"))) if st is not None else 1)
            self.levels[aid] = lv
        for n in root.findall(qn("w:num")):
            a = n.find(qn("w:abstractNumId"))
            if a is not None:
                self.num_abs[n.get(qn("w:numId"))] = a.get(qn("w:val"))

    def _numpr(self, p):
        qn = self.qn
        ppr = p._p.pPr
        np_ = ppr.find(qn("w:numPr")) if ppr is not None else None
        if np_ is None:
            try:
                sp = p.style.element.pPr
                np_ = sp.find(qn("w:numPr")) if sp is not None else None
            except Exception:
                np_ = None
        if np_ is None:
            return None
        nid = np_.find(qn("w:numId"))
        il = np_.find(qn("w:ilvl"))
        nid = nid.get(qn("w:val")) if nid is not None else None
        if not nid or nid == "0":
            return None
        return nid, int(il.get(qn("w:val"))) if il is not None else 0

    def label(self, p) -> str:
        np_ = self._numpr(p)
        if not np_:
            return ""
        nid, il = np_
        aid = self.num_abs.get(nid, nid)
        lv = self.levels.get(aid, {})
        cnt = self.count.setdefault(aid, {})
        start = lv.get(il, ("decimal", "", 1))[2]
        cnt[il] = cnt.get(il, start - 1) + 1
        for deeper in [k for k in cnt if k > il]:
            del cnt[deeper]
        fmt, text, _ = lv.get(il, ("decimal" if il == 0 else "thaiLetters", f"%{il + 1}.", 1))
        if fmt == "bullet":
            return ""

        def sub(m):
            k = int(m.group(1)) - 1
            f = lv.get(k, ("decimal", "", 1))[0]
            return _fmt_num(cnt.get(k, lv.get(k, ("", "", 1))[2]), f)
        out = re.sub(r"%(\d)", sub, text or "").strip()
        if out and not out.endswith((".", ")")):
            out += "."
        return out + " " if out else ""


class _Pics:
    """Pictures met while reading, saved as question pictures (at most MAX_IMAGES per file)."""

    def __init__(self):
        self.used = 0

    def add(self, data: bytes) -> str:
        if self.used >= MAX_IMAGES:
            return ""
        try:
            name = exams.save_image(data)
        except Exception:
            return ""                     # EMF / WMF drawings and the like: not a picture we can show
        self.used += 1
        return IMG + name + IMG


def _run_pictures(run, pics: Optional[_Pics]) -> str:
    if pics is None:
        return ""
    out = ""
    for el in run._r.iter():
        if el.tag.endswith("}blip"):
            rid = el.get("{http://schemas.openxmlformats.org/officeDocument/2006/relationships}embed")
            part = run.part.related_parts.get(rid) if rid else None
            if part is not None:
                out += pics.add(part.blob)
    return out


def _run_text(run, pics: Optional[_Pics] = None) -> str:
    t = run.text or ""
    pic = _run_pictures(run, pics)
    if not t.strip():
        if run.underline and len(t) >= 3:
            return "_" * len(t) + pic          # a blank made of underlined spaces
        return t + pic
    f = run.font
    color = None
    try:
        color = f.color.rgb if f.color is not None and f.color.type is not None else None
    except Exception:
        color = None
    em = bool(run.bold) or bool(getattr(f, "cs_bold", None)) or bool(run.underline) or f.highlight_color is not None or (color is not None and str(color) not in ("000000", "auto"))
    return (f"{EM_ON}{t}{EM_OFF}" if em else t) + pic


def _para_text(p, numbering: Optional[_Numbering], pics: Optional[_Pics] = None) -> str:
    text = "".join(_run_text(r, pics) for r in p.runs)
    if not text.strip():
        text = p.text or ""
    label = numbering.label(p) if numbering else ""
    return (label + text).replace(EM_OFF + EM_ON, "")


def docx_lines(data: bytes) -> Tuple[List[str], Dict[str, Any]]:
    from docx import Document
    from docx.table import Table
    from docx.text.paragraph import Paragraph
    doc = Document(io.BytesIO(data))
    numbering = _Numbering(doc)
    pics = _Pics()
    lines: List[str] = []
    for child in doc.element.body.iterchildren():
        tag = child.tag.rsplit("}", 1)[-1]
        if tag == "p":
            p = Paragraph(child, doc)
            for part in _para_text(p, numbering, pics).split("\n"):
                lines.append(part)
        elif tag == "tbl":
            for row in Table(child, doc).rows:
                seen, cells = set(), []
                for c in row.cells:
                    if id(c._tc) in seen:
                        continue
                    seen.add(id(c._tc))
                    cells.append(" ".join(_para_text(p, numbering, pics) for p in c.paragraphs).strip())
                filled = [c for c in cells if c.strip()]
                if len(filled) >= 2:
                    lines.append("\t".join(cells))
                elif filled:
                    lines.append(filled[0])
    try:
        images = len(doc.inline_shapes)
    except Exception:
        images = 0
    return lines, {"images": max(images, pics.used)}


def _margin_band(x0: float, y0: float, x1: float, y1: float, W: float, H: float) -> bool:
    return x0 >= 0.85 * W or x1 <= 0.15 * W or y1 <= 0.08 * H or y0 >= 0.93 * H


def _page_decorations(doc) -> set:
    """Text printed at the same spot of the margin on several pages: side tabs ("ชุดที่ 3"), running heads,
    a book title down the margin. Not part of any question."""
    seen: Dict[tuple, set] = {}
    for page in doc:
        W, H = page.rect.width, page.rect.height
        try:
            blocks = page.get_text("dict").get("blocks", [])
        except Exception:
            continue
        for b in blocks:
            for ln in b.get("lines", []):
                for sp in ln.get("spans", []):
                    t = (sp.get("text") or "").strip()
                    x0, y0, x1, y1 = sp["bbox"]
                    if t and _margin_band(x0, y0, x1, y1, W, H):
                        seen.setdefault((t, round(x0 / 3), round(y0 / 3)), set()).add(page.number)
    return {k for k, v in seen.items() if len(v) >= 2}


def pdf_lines(data: bytes, force_ocr: bool = False) -> Tuple[List[str], Dict[str, Any]]:
    """Text lines of a PDF; pages without text (scans) are read by OCR. force_ocr: every page (a Word file
    converted from a scan, whose own text is unreadable)."""
    import fitz
    doc = fitz.open(stream=data, filetype="pdf")
    lines: List[str] = []
    pos: List[Optional[int]] = []
    chars = images = ocr_pages = drawn = 0
    pics_seen: List[str] = []
    deco = _page_decorations(doc)
    for pno, page in enumerate(doc):
        if force_ocr or len(page.get_text("text").strip()) < 30:
            # a scanned page: no text in the file -> read the picture
            if not find_tesseract():
                doc.close()
                raise ValueError("PDF นี้เป็นภาพสแกน (ไม่มีตัวอักษรในไฟล์) และยังไม่ได้ติดตั้งโปรแกรมอ่านภาพ (OCR) — ใช้ไฟล์ Word")
            if ocr_pages >= OCR_MAX_PAGES:
                continue
            from PIL import Image
            _progress(f"กำลังอ่านภาพหน้า {pno + 1}/{len(doc)}")
            pix = page.get_pixmap(dpi=300)
            got = ocr_page(Image.frombytes("RGB", (pix.width, pix.height), pix.samples) if pix.n == 3
                           else Image.open(io.BytesIO(pix.tobytes("png"))), getattr(_job, "layout", None))
            ocr_pages += 1
            chars += sum(len(t.strip()) for t, _ in got)
            lines += [t for t, _ in got]
            pos += [p for _, p in got]
            continue
        images += len(page.get_images(full=False))
        # highlighted text = a small coloured box drawn behind it; underline = a thin line just under the words
        marks, ulines, drs = [], [], []
        try:
            drs = page.get_drawings()
            drawn += len(drs)
            for dr in drs:
                for it in dr.get("items") or []:
                    if it[0] == "l" and abs(it[1].y - it[2].y) < 0.8 and abs(it[2].x - it[1].x) > 3:
                        ulines.append([min(it[1].x, it[2].x), max(it[1].x, it[2].x), (it[1].y + it[2].y) / 2, 0.0])
                    elif it[0] == "re" and it[1].height < 1.6 and it[1].width > 3:
                        ulines.append([it[1].x0, it[1].x1, (it[1].y0 + it[1].y1) / 2, 0.0])
                fill = dr.get("fill")
                if not fill or min(fill) > 0.92 or max(fill) - min(fill) < 0.15:
                    continue   # white / grey shading of tables
                r = dr.get("rect")
                if r is not None and r.height < 40:
                    marks.append(r)
        except Exception:
            marks, ulines = [], []
        spans = []
        try:
            for w in page.widgets() or []:
                v = w.field_value
                if v in (None, "", "Off", False) or not str(v).strip():
                    continue
                kind = w.field_type_string
                if kind in ("ComboBox", "ListBox"):
                    t = str(v).strip()
                elif kind == "Text":
                    t = f"[[{str(v).strip()}]]"
                else:
                    continue
                r = w.rect
                spans.append(((r.y0 + r.y1) / 2, r.x0, r.x1, t, min(r.y1 - r.y0, 14)))
        except Exception:
            pass
        raw = []
        tabs_x = float("inf")                 # left edge of side tabs ("ชุดที่ 3") on this page
        num_end: Dict[tuple, float] = {}   # where a leading "12." ends inside a span (to blank it in the picture)
        for b in page.get_text("rawdict").get("blocks", []):
            if b.get("type") != 0:
                continue
            for ln in b.get("lines", []):
                d = ln.get("dir") or (1, 0)
                if abs(d[1]) > 0.2 or d[0] < 0:
                    continue                  # text turned sideways (a title down the margin)
                for sp in ln.get("spans", []):
                    chs = [c for c in sp.get("chars") or [] if c.get("c")]
                    txt = "".join(c["c"] for c in chs).strip()
                    if not chs or not txt:
                        continue
                    bx0, by0 = sp["bbox"][0], sp["bbox"][1]
                    if any((txt, round(bx0 / 3) + dx, round(by0 / 3) + dy) in deco for dx in (-1, 0, 1) for dy in (-1, 0, 1)):
                        if bx0 >= 0.85 * page.rect.width:
                            tabs_x = min(tabs_x, bx0)
                        continue              # the same text in the same margin spot on other pages
                    raw.append((sp, chs))

        def under(c, y1):
            cx = (c["bbox"][0] + c["bbox"][2]) / 2
            return next((u for u in ulines if u[0] - 0.5 <= cx <= u[1] + 0.5 and y1 - 3.5 <= u[2] <= y1 + 3), None)
        if ulines:
            # a line much longer than the words on it is a table border or a drawn blank, not an underline
            for sp, chs in raw:
                for c in chs:
                    u = under(c, sp["bbox"][3])
                    if u is not None and c["c"].strip():
                        u[3] += c["bbox"][2] - c["bbox"][0]
            ulines = [u for u in ulines if u[3] >= 0.6 * (u[1] - u[0])]
        for sp, chs in raw:
            x0, y0, x1, y1 = sp["bbox"]
            col = int(sp.get("color") or 0)
            r, g, bl = (col >> 16) & 255, (col >> 8) & 255, col & 255
            coloured = max(r, g, bl) - min(r, g, bl) > 60           # red / blue / green ink, not grey
            font = str(sp.get("font") or "").lower()
            cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
            lit = any(m.x0 <= cx <= m.x1 and m.y0 <= cy <= m.y1 for m in marks)
            em = bool(int(sp.get("flags") or 0) & 16) or "bold" in font or "-bd" in font or coloured or lit
            t, on = "", False
            for c in chs:
                e = em or (bool(ulines) and under(c, y1) is not None)
                if e != on:
                    t += EM_ON if e else EM_OFF
                    on = e
                t += c["c"]
            if on:
                t += EM_OFF
            # where the letters are (a span's box also covers its leading / trailing spaces)
            vis = [c for c in chs if c["c"].strip()]
            lead = re.match(r"\s*(?:ข้อ\s*)?\d{1,3}\s*[.)]", "".join(c["c"] for c in chs))
            if lead:
                num_end[(round((y0 + y1) / 2, 2), round(vis[0]["bbox"][0], 2))] = chs[lead.end() - 1]["bbox"][2]
            spans.append(((y0 + y1) / 2, vis[0]["bbox"][0], vis[-1]["bbox"][2], t.strip(" "), y1 - y0))
        # two columns of questions: read the left column, then the right (a full-width title in between ends a band)
        split = _text_gutter(spans, page.rect.width)
        groups: Dict[str, List[tuple]] = {"left": [], "right": [], "full": []}
        for s in spans:
            if split is None:
                groups["full"].append(s)
            elif s[2] <= split + 6:
                groups["left"].append(s)
            elif s[1] >= split - 6:
                groups["right"].append(s)
            elif s[2] - split < 20 or split - s[1] < 20:
                # only just across the gap: the side with most of it
                groups["left" if split - s[1] > s[2] - split else "right"].append(s)
            else:
                groups["full"].append(s)

        def make_rows(ss):
            ss = sorted(ss, key=lambda s: (round(s[0]), s[1]))
            rows_: List[List[tuple]] = []
            for s in ss:
                if rows_:
                    f = rows_[-1][0]
                    # same line: close middles, or heights overlapping by half (a raised "2" in s²)
                    over = min(f[0] + f[4] / 2, s[0] + s[4] / 2) - max(f[0] - f[4] / 2, s[0] - s[4] / 2)
                    if abs(f[0] - s[0]) <= max(2.5, s[4] * 0.35) or (f[4] and s[4] and over >= 0.5 * min(f[4], s[4])):
                        rows_[-1].append(s)
                        continue
                rows_.append([s])
            return rows_
        rows_by = {g: make_rows(ss) for g, ss in groups.items()}
        # pictures: on the row of text nearest their middle (a matching choice "a." beside its picture)
        try:
            infos = page.get_image_info() if len(pics_seen) < MAX_IMAGES else []
        except Exception:
            infos = []
        area = page.rect.width * page.rect.height
        for inf in infos:
            bb = fitz.Rect(inf["bbox"]) & page.rect
            if bb.width < 24 or bb.height < 24 or bb.width * bb.height > 0.6 * area or len(pics_seen) >= MAX_IMAGES:
                continue
            try:
                name = exams.save_image(page.get_pixmap(clip=bb, dpi=150).tobytes("png"))
            except Exception:
                continue
            pics_seen.append(name)
            cy = (bb.y0 + bb.y1) / 2
            g = "full" if split is None else ("left" if bb.x1 <= split + 2 else ("right" if bb.x0 >= split - 2 else "full"))
            rows = rows_by[g]
            near = [k for k, rw in enumerate(rows) if bb.y0 <= rw[0][0] <= bb.y1]
            tok = (cy, bb.x0, bb.x1, IMG + name + IMG, 0)
            if near:
                rows[min(near, key=lambda k: abs(rows[k][0][0] - cy))].append(tok)
            else:
                rows.append([tok])
        for rows in rows_by.values():
            rows.sort(key=lambda rw: rw[0][0])
        ordered: List[Tuple[str, List[tuple]]] = []
        lefts, rights = list(rows_by["left"]), list(rows_by["right"])
        for full in rows_by["full"] + [None]:
            limit = full[0][0] if full else float("inf")
            ordered += [("left", r) for r in lefts if r[0][0] < limit]
            ordered += [("right", r) for r in rights if r[0][0] < limit]
            lefts = [r for r in lefts if r[0][0] >= limit]
            rights = [r for r in rights if r[0][0] >= limit]
            if full:
                ordered.append(("full", full))
        # where the paper's content is (not the margin tabs and drawings): pictures of questions stay inside it
        PW, PH = page.rect.width, page.rect.height
        xs = [(s[1], s[2]) for s in spans if s[4]]
        xs += [(i["bbox"][0], i["bbox"][2]) for i in (infos or []) if not _margin_band(*i["bbox"], PW, PH)]
        for dr in drs:
            r = dr.get("rect")
            if r is not None and r.width < PW * 0.9 and not _margin_band(r.x0, r.y0, r.x1, r.y1, PW, PH):
                xs.append((r.x0, r.x1))
        lo = max(0.0, min((a for a, _ in xs), default=0.0) - 10)
        hi = min(PW, max((b for _, b in xs), default=PW) + 10, tabs_x - 14)
        # the page as a picture, to cut each question from it (formulas, drawings) — see _attach_figures
        layout = getattr(_job, "layout", None)
        pidx, k = None, 1.0
        if layout is not None:
            from PIL import Image
            k = LAYOUT_W / page.rect.width
            pix = page.get_pixmap(matrix=fitz.Matrix(k, k), colorspace=fitz.csGRAY, alpha=False)
            pidx = len(layout.pages)
            layout.pages[pidx] = Image.frombytes("L", (pix.width, pix.height), pix.samples)
            layout.words[pidx] = [tuple(int(v * k) for v in (s[1], s[0] - s[4] / 2, s[2], s[0] + s[4] / 2)) for s in spans]
        for g, row in ordered:
            row.sort(key=lambda s: s[1])
            text, last = "", None
            for s in row:
                if last is not None:
                    text += "  " if s[1] - last > 6 else ("" if s[1] - last < 1.5 else " ")
                text += s[3]
                last = s[2]
            # Thai fonts that lose the nikhahit of sara am: "ก าหนด" -> "กำหนด" (a space before า is never Thai)
            text = re.sub(r"([ก-ฮ][\u0e48-\u0e4b]?)[ \u00a0]+\u0e32", "\\1\u0e33", text)
            chars += len(_IMG_TOKEN.sub("", text).strip())
            lines.append(text.replace(EM_OFF + EM_ON, ""))
            lid = None
            if layout is not None:
                words = [s for s in row if s[4]]
                if words:
                    lid = len(layout.lines)
                    cx0, cx1 = ((lo, split) if g == "left" else (split, hi) if g == "right" else (lo, hi)) \
                        if split is not None else (lo, hi)
                    layout.lines.append({
                        "page": pidx, "h": _median([s[4] for s in words]) * k * 0.8,
                        "box": (int(min(s[1] for s in words) * k), int(min(s[0] - s[4] / 2 for s in words) * k),
                                int(max(s[2] for s in words) * k), int(max(s[0] + s[4] / 2 for s in words) * k)),
                        "words": _layout_words(words, k, num_end),
                        "col": (int(cx0 * k), int(cx1 * k)),
                    })
            pos.append(lid)
    pages = len(doc)
    doc.close()
    if chars < 30 and pages:
        raise ValueError("อ่านตัวอักษรในไฟล์ PDF นี้ไม่ได้ (ภาพไม่ชัดหรือว่าง) — ใช้ไฟล์ Word หรือสแกนใหม่ให้ชัด")
    info = {"images": images, "ocr_pages": ocr_pages, "pos": pos, "drawn": drawn}
    if pages - ocr_pages > OCR_MAX_PAGES and ocr_pages >= OCR_MAX_PAGES:
        info["ocr_skipped"] = True
    return lines, info


def _has_math(data: bytes) -> bool:
    """Word equations (OMML) or old Equation Editor / MathType objects in the paper."""
    import zipfile
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            xml = z.read("word/document.xml").decode("utf-8", "replace")
    except Exception:
        return False
    return "<m:oMath" in xml or "Equation." in xml or "<w:object" in xml


def _looks_scanned(lines: List[str], info: Dict[str, Any]) -> bool:
    """A Word file made from a scanned PDF: pictures of the page and broken OCR text ("ข" / "' ข ข" lines,
    vowels missing) -> its own text is not worth reading."""
    text = [_IMG_TOKEN.sub("", _plain(x)).strip() for x in lines]
    text = [t for t in text if t]
    if info.get("images", 0) < 1:
        return False
    if sum(len(t) for t in text) < 200:
        return True                       # pages are pictures only
    junk = 0
    for t in text:
        toks = t.split()
        if toks and len(t) <= 50 and sum(1 for k in toks if len(k) <= 1) >= 0.6 * len(toks):
            junk += 1
    return junk >= 5 and junk >= 0.15 * len(text)


def _office_to_pdf(data: bytes, ext: str) -> bytes:
    soffice = shutil.which("soffice") or shutil.which("libreoffice")
    if not soffice and Path(r"C:\Program Files\LibreOffice\program\soffice.exe").exists():
        soffice = r"C:\Program Files\LibreOffice\program\soffice.exe"
    if not soffice:
        raise ValueError("แปลงไฟล์ไม่ได้ (ไม่มี LibreOffice)")
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / f"exam{ext}"
        src.write_bytes(data)
        subprocess.run([soffice, f"-env:UserInstallation=file:///{Path(d, 'profile').as_posix()}", "--headless",
                        "--convert-to", "pdf", "--outdir", d, str(src)], capture_output=True, timeout=300)
        out = Path(d) / "exam.pdf"
        if not out.exists():
            raise ValueError("แปลงไฟล์เป็น PDF ไม่สำเร็จ")
        return out.read_bytes()


def _doc_to_docx(data: bytes) -> bytes:
    """Old Word (.doc) through LibreOffice when it is installed."""
    soffice = shutil.which("soffice") or shutil.which("libreoffice")
    if not soffice and Path(r"C:\Program Files\LibreOffice\program\soffice.exe").exists():
        soffice = r"C:\Program Files\LibreOffice\program\soffice.exe"
    if not soffice:
        raise ValueError("ไฟล์ .doc แบบเก่า: เปิดใน Word แล้ว 'บันทึกเป็น' .docx ก่อน")
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / "exam.doc"
        src.write_bytes(data)
        subprocess.run([soffice, f"-env:UserInstallation=file:///{Path(d, 'profile').as_posix()}", "--headless",
                        "--convert-to", "docx", "--outdir", d, str(src)], capture_output=True, timeout=120)
        out = Path(d) / "exam.docx"
        if not out.exists():
            raise ValueError("แปลงไฟล์ .doc ไม่สำเร็จ — เปิดใน Word แล้ว 'บันทึกเป็น' .docx ก่อน")
        return out.read_bytes()


# ---------------------------------------------------------------- understanding the lines

_CH = r"[กขคงจabcdeABCDE]"
_MARK = r"[*✓✔√]"
# "1." "1)" "ข้อ 1" "15(มช 41)" (where the question came from)
_Q_START = re.compile(r"^\s*(?:ข้อ(?:ที่)?\s*)?(\d{1,3})\s*(?:\.|[):]|,(?=\s)|(?=\(\s*[A-Za-zก-๛][^()]{0,15}\)))\s*(.*)$")
_LOOSE_CHOICE = re.compile(r"^\s*([^\d\sก-๛()\[\]{}\-–—=+*/\|_.,:;'\"])\s*[.)]\s*(\S.*)$")   # OCR: "n.3,4,5" for ก.
_DECIMAL_START = re.compile(r"^\s*\d{1,3}\s*\.\d")
_NUM_CHOICE = re.compile(r"^\s*([1-6])\s*[.)]\s*(.*)$")                                      # a choice "1." / "1.925" / "1)"
_Q_KHO = re.compile(r"^\s*ข้อ(?:ที่)?\s*(\d{1,3})\s*$")
_CHOICE = re.compile(rf"^\s*({_MARK})?\s*\(?({_CH})\s*[.)]\s*(.*)$")
_SPLIT = re.compile(rf"\s+(?={_MARK}?\s*\(?{_CH}\s*[.)](?:\s|(?![ก-๛.])))")
_ANSWER = re.compile(r"^\s*(?:ตอบ|เฉลย|คำตอบ|answer|ans)\s*[:：.]?\s*(.+?)\s*$", re.IGNORECASE)
_KEY_HEAD = re.compile(r"^\s*(?:เฉลย(?:ข้อสอบ|คำตอบ)?|คำตอบ|answer\s*key|key)\s*[:：]?\s*(.*)$", re.IGNORECASE)
_PAIR = rf"(\d{{1,3}})\s*[.)\-:=]?\s*\(?({_CH})\)?(?![^\s,;|)])"
_PAIRS_ONLY = re.compile(rf"^\s*(?:{_PAIR}[\s,;|]*)+$")
_SECTION = re.compile(r"^\s*(?:ตอนที่|ส่วนที่|คำชี้แจง|คำสั่ง|part)(?![ก-๛a-z])", re.IGNORECASE)
_PAGE_NO = re.compile(r"^[\s\-–—]*(?:หน้า|page)?\s*\d{1,3}\s*(?:/\s*\d{1,3})?[\s\-–—]*$", re.IGNORECASE)


def _plain(s: str) -> str:
    return s.replace(EM_ON, "").replace(EM_OFF, "")


def _letter_index(t: str) -> Optional[int]:
    t = t.strip()
    if t in LETTERS:
        return LETTERS.index(t)
    if t.lower() in _LAT:
        return _LAT.index(t.lower())
    return None


def _split_mask(s: str) -> Tuple[str, List[bool]]:
    """Marked text -> (the text, which characters were emphasised)."""
    out, mask, on = [], [], False
    for ch in s:
        if ch == EM_ON:
            on = True
        elif ch == EM_OFF:
            on = False
        else:
            out.append(ch)
            mask.append(on)
    return "".join(out), mask


def _mostly_emphasised(text: str, mask: List[bool]) -> bool:
    flags = [m for ch, m in zip(text, mask) if not ch.isspace()]
    return bool(flags) and sum(flags) * 2 >= len(flags)


def _clean_line(s: str) -> str:
    s = s.translate(_THAI_DIGITS).replace("\u0e4d\u0e32", "\u0e33").replace("\u00a0", " ").replace("\u200b", "").replace("\u200c", "").replace("\ufeff", "")
    return s.rstrip()


def _number_answer(t: str) -> Optional[Tuple[str, str]]:
    m = re.match(r"^\s*(-?\s*[\d][\d,]*(?:\.\d+)?(?:\s*[xX×]\s*10\^-?\d{1,3}|(?:\s*/\s*\d+)?(?:\s+\d+\s*/\s*\d+)?))\s*(.*)$", t)
    if m and exams.to_number(m.group(1)) is not None:
        return m.group(1).strip(), m.group(2).strip()
    return None


def _key_pairs(text: str) -> Dict[int, int]:
    out = {}
    for n, l in re.findall(_PAIR, _plain(text)):
        i = _letter_index(l)
        if i is not None:
            out[int(n)] = i
    return out


# ---------------------------------------------------------------- ถูก/ผิด, จับคู่, เติมคำ, cloze

IMG = "\x03"   # a picture in the extracted lines: IMG + name + IMG (already saved with exams.save_image)
MAX_IMAGES = 40
_IMG_TOKEN = re.compile("\x03([0-9a-f]{32}\\.jpg)\x03")
_EXERCISE = re.compile(r"^\s*(?:exercise|แบบฝึกหัด|activity|กิจกรรม(?:ที่)?|worksheet|ใบงาน|part)(?![ก-๛a-z])", re.IGNORECASE)
_FORM_HEAD = re.compile(r"(?:ชื่อ|name)\s*[:：]?\s*[_.…]{2,}.*(?:นามสกุล|ชั้น|เลขที่|class|no\b|number|surname)", re.IGNORECASE)
_BLANK_ANY = re.compile(r"_{3,}|\.{4,}|…{2,}|\[\[")
_TF_TOK = r"[✓✔√☑✗✘×☒✕]|ถูก|ผิด|true|false|T|F|x|X"
_TF_PAIR = re.compile(rf"(\d{{1,3}})\s*[.)\-:=]?\s*[\(\[]?\s*({_TF_TOK})\s*[\)\]]?(?![ก-๛a-zA-Z])", re.IGNORECASE)
_TF_ONLY = re.compile(rf"^\s*(?:{_TF_PAIR.pattern}[\s,;|]*)+$", re.IGNORECASE)
_TF_LEAD = re.compile(rf"^\s*[\(\[]?\s*[_.…]*\s*({_TF_TOK})?\s*[_.…]*\s*[\)\]]?\s*(\d{{1,3}})\s*[.)]\s*(.*)$", re.IGNORECASE)
_TF_TAIL = re.compile(rf"\s+(?:[\(\[]\s*({_TF_TOK})\s*[\)\]]|([✓✔√☑✗✘×☒✕]))\s*$", re.IGNORECASE)
_M_LAT = exams.MATCH_LETTERS["latin"]
_M_THAI = exams.MATCH_LETTERS["thai"]
_M_LET = rf"[a-tA-T{_M_THAI}]"
_M_OPT = re.compile(rf"(?:^|\t|\s{{2,}})\s*\(?\s*({_M_LET})\s*[.)](?=\s|$|{IMG})")
_M_ITEM = re.compile(rf"^\s*(?:[_.…]{{2,}}\s*|\(\s*\)\s*|\[\s*\]\s*)?(?:\(?\s*({_M_LET})\s*\)?\s*(?=[_.…\s]*\d))?[_.…]*\s*(\d{{1,3}})\s*[.)]\s*(.*)$")
_M_TAIL = re.compile(rf"(?:[_.…]{{2,}}\s*({_M_LET})\s*[_.…]*|\(\s*({_M_LET})\s*\))\s*$")
_INSTRUCTION = re.compile(r"read|fill|choose|complete|use the|select|เติม|เลือก|อ่าน|คำชี้แจง|คำสั่ง", re.IGNORECASE)
_BANK_HEAD = re.compile(r"^\s*(?:word\s*bank|words?|คำที่กำหนด(?:ให้)?|กล่องคำ|choose from)\s*[:：]\s*(.*)$", re.IGNORECASE)


def _take_images(s: str) -> Tuple[str, List[str]]:
    names = _IMG_TOKEN.findall(s)
    if not names:
        return s, []
    return re.sub(r"[ \t]{2,}", " ", _IMG_TOKEN.sub(" ", s)).strip(), names


def _tf_value(tok: Optional[str]) -> Optional[bool]:
    if not tok:
        return None
    t = tok.strip().lower()
    if t in ("✓", "✔", "√", "☑", "ถูก", "true", "t"):
        return True
    if t in ("✗", "✘", "×", "☒", "✕", "ผิด", "false", "f", "x"):
        return False
    return None


def _has_blank(s: str) -> bool:
    return bool(_BLANK_ANY.search(s))


def _bank_words(s: str) -> List[str]:
    """A word bank line: most | up | grow | necks (a table row, gaps, or single words with commas)."""
    s = _take_images(s)[0].strip()
    if not s or _Q_START.match(s) or _has_blank(s):
        return []
    cells = [c.strip() for c in re.split(r"\t|\s{2,}|\s*\|\s*", s) if c.strip()]
    if len(cells) >= 3 and all(len(c) <= 25 and len(c.split()) <= 3 and not re.search(r"[.!?:]$", c) for c in cells):
        return cells
    cells = [c.strip() for c in re.split(r"\s*[,，、]\s*", s) if c.strip()]
    if len(cells) >= 4 and all(len(c) <= 20 and len(c.split()) <= 2 and not re.search(r"[.!?:]$", c) for c in cells):
        return cells
    return []


def _mark_blanks(text: str, mask: Optional[List[bool]] = None, use_em: bool = False) -> str:
    """Blanks as the editor keeps them: [[answer]] where the teacher wrote it (in the blank, or emphasised in
    place of it), [[]] where the blank is still empty."""
    s = text
    if use_em and mask and len(mask) == len(text) and not _mostly_emphasised(text, mask):
        out, k = [], 0
        while k < len(s):
            if mask[k]:
                j = k
                while j < len(s) and mask[j]:
                    j += 1
                run = s[k:j]
                word = run.strip().strip("_.…").strip()
                if word and len(word) <= 40 and len(word.split()) <= 4 and "[[" not in run:
                    lead = run[:len(run) - len(run.lstrip())]
                    tail = run[len(run.rstrip()):]
                    out.append(f"{lead}[[{word}]]{tail}")
                else:
                    out.append(run)
                k = j
            else:
                out.append(s[k])
                k += 1
        s = "".join(out)
    blank = r"(?:_{2,}|\.{3,}|…+)"
    s = re.sub(rf"{blank}\s*(\[\[[^\]]*\]\])", r"\1", s)
    s = re.sub(rf"(\[\[[^\]]*\]\])\s*{blank}", r"\1", s)
    s = re.sub(r"(?<![_.…])(?:_{2,}|\.{3,}|…+)([^\s_.…\[\]](?:[^_\[\]…\n]*?[^\s_.…\[\]])?)(?:_{2,}|\.{3,}|…+)(?![_.…])", r"[[\1]]", s)
    s = re.sub(r"_{3,}|\.{4,}|…{2,}", "[[]]", s)
    return re.sub(r"[ \t]{2,}", " ", s)


def _instruction(header: List[str]) -> str:
    t = " ".join(_take_images(_plain(h))[0].strip() for h in header if _plain(h).strip())
    t = re.sub(r"^\s*(?:คำชี้แจง|คำสั่ง)\s*[:：]?\s*", "", t)
    return re.sub(r"\s+", " ", t).strip()


def _kind_of(text: str) -> str:
    t = text.lower()
    if re.search(r"จับคู่|match", t):
        return "match"
    if re.search(r"ถูก.{0,60}ผิด|ผิด.{0,60}ถูก|true.{0,30}false|[✓✔√].{0,80}[✗✘×]|\bt\s*/\s*f\b", t):
        return "truefalse"
    if re.search(r"cloze", t):
        return "cloze"
    if re.search(r"เติมคำ|เติมข้อความ|ช่องว่าง|fill\s*in|complete|word\s*bank|กล่องคำ|คำที่กำหนด", t):
        return "fill"
    if re.search(r"อัตนัย|เขียนตอบ|แสดงวิธี|บรรยาย", t):
        return "photo"
    if re.search(r"ปรนัย|เลือกตอบ", t):
        return "choice"
    return ""


def _shape_kind(body: List[str]) -> str:
    plain = [_plain(x) for x in body]
    numbered = [p for p in plain if _Q_START.match(p)]
    choices = [p for p in plain if _CHOICE.match(p) and not _Q_START.match(p)]
    unnum_blanks = [p for p in plain if not _Q_START.match(p) and _has_blank(p)]
    bank = any(_bank_words(p) for p in plain)
    if not numbered and unnum_blanks and (bank or len(unnum_blanks) >= 2):
        return "cloze"
    marked = sum(1 for p in numbered if (_TF_LEAD.match(p) and _TF_LEAD.match(p).group(1)) or _TF_TAIL.search(p))
    if len(numbered) >= 3 and not choices and marked >= max(2, len(numbered) // 2):
        return "truefalse"
    return ""


def _tf_block(header: List[str], body: List[str], tf_key: Dict[int, bool]) -> Optional[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    for ln in body:
        plain = _take_images(_plain(ln))[0]
        a = _ANSWER.match(plain)
        if a and items:
            v = _tf_value(a.group(1).strip("() "))
            if v is not None:
                items[-1]["answer"] = v
            continue
        m = _TF_LEAD.match(plain)
        if m and m.group(3).strip():
            text, ans = m.group(3).strip(), _tf_value(m.group(1))
            t = _TF_TAIL.search(text)
            if t:
                ans = ans if ans is not None else _tf_value(t.group(1) or t.group(2))
                text = text[:t.start()].strip()
            if ans is None:
                ans = tf_key.get(int(m.group(2)))
            items.append({"text": text, "answer": ans})
        elif items and plain.strip():
            items[-1]["text"] = (items[-1]["text"] + " " + plain.strip()).strip()
    if not items:
        return None
    return {"type": "truefalse", "q": _instruction(header), "items": items}


def _m_index(letter: str, latin: bool) -> Optional[int]:
    if latin:
        return _M_LAT.index(letter.lower()) if letter.lower() in _M_LAT else None
    return _M_THAI.index(letter) if letter in _M_THAI else None


def _match_block(header: List[str], body: List[str], key: Dict[int, int]) -> Optional[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    opts: Dict[int, Dict[str, Any]] = {}
    latin: Optional[bool] = None
    last = None              # ("item", dict) or ("opt", dict): where a continuation line goes
    loose: List[str] = []    # pictures seen before their label

    def parse_options(s: str):
        nonlocal latin, last
        ms = list(_M_OPT.finditer(s))
        for k, m in enumerate(ms):
            letter = m.group(1)
            if latin is None:
                latin = letter.isascii()
            idx = _m_index(letter, latin)
            body_ = s[m.end():ms[k + 1].start() if k + 1 < len(ms) else len(s)]
            text, pics = _take_images(body_)
            if idx is None:
                continue
            o = opts.setdefault(idx, {"text": "", "letter": letter})
            o["text"] = (o["text"] + " " + text.strip()).strip()
            for p in pics:
                o.setdefault("image", p)
            last = ("opt", o)

    for ln in body:
        plain = _plain(ln)
        only_text, pics = _take_images(plain)
        if not only_text.strip():
            for p in pics:
                target = next((o for _, o in sorted(opts.items(), reverse=True) if "image" not in o), None) if opts else None
                if target is not None and last and last[0] == "opt" and "image" not in last[1]:
                    target = last[1]
                if target is not None:
                    target["image"] = p
                else:
                    loose.append(p)
            continue
        m = _M_ITEM.match(plain)
        first_opt = _M_OPT.match(plain)
        if m and not (first_opt and first_opt.start() == 0 and not m.group(1) and not re.match(r"^\s*[_.…(\[]", plain)):
            rest = m.group(3)
            om = _M_OPT.search(rest)
            item_text, opt_part = (rest[:om.start()], rest[om.start():]) if om else (rest, "")
            starts_with_pic = item_text.lstrip().startswith(IMG)
            item_text, ipics = _take_images(item_text)
            if ipics and not starts_with_pic:
                loose.extend(ipics)       # in a PDF the label "a." sits at its picture's foot, a row below
                ipics = []
            ans_letter = m.group(1)
            t = _M_TAIL.search(item_text)
            if t:
                ans_letter = ans_letter or t.group(1) or t.group(2)
                item_text = item_text[:t.start()]
            it = {"text": item_text.strip(), "num": int(m.group(2)), "letter": ans_letter}
            if ipics:
                it["image"] = ipics[0]
            items.append(it)
            last = ("item", it)
            if opt_part:
                parse_options(opt_part)
                if loose and last and last[0] == "opt" and "image" not in last[1]:
                    last[1]["image"] = loose.pop(0)
            continue
        if _M_OPT.match(plain):
            parse_options(plain)
            if loose and last and last[0] == "opt" and "image" not in last[1]:
                last[1]["image"] = loose.pop(0)
            continue
        if last:
            target = last[1]
            target["text"] = (target["text"] + " " + only_text.strip()).strip()
            if pics and "image" not in target:
                target["image"] = pics[0]
    if not items or len(opts) < 2:
        return None
    for idx in sorted(opts):
        if loose and "image" not in opts[idx] and not opts[idx]["text"]:
            opts[idx]["image"] = loose.pop(0)
    latin = bool(latin)
    order = sorted(opts)
    pos = {idx: k for k, idx in enumerate(order)}
    options = []
    for idx in order:
        o = opts[idx]
        d = {"text": o["text"]}
        if o.get("image"):
            d["image"] = o["image"]
        elif not o["text"]:
            d["text"] = f"(รูป {o['letter']})"
            d["missing_picture"] = True
        options.append(d)
    out_items = []
    for it in items:
        idx = _m_index(it["letter"], latin) if it.get("letter") else None
        if idx is None and key.get(it["num"]) in opts:
            idx = key[it["num"]]          # the key's letters count a/ก = 0 like the labels
        d = {"text": it["text"], "answer": pos.get(idx) if idx is not None else None}
        if it.get("image"):
            d["image"] = it["image"]
        out_items.append(d)
    return {"type": "match", "q": _instruction(header), "letters": "latin" if latin else "thai",
            "items": out_items, "options": options}


def _cloze_block(header: List[str], body: List[str]) -> Optional[Dict[str, Any]]:
    instr, bank, passage, pics = list(header), [], [], []
    for ln in body:
        plain, mask = _split_mask(ln)
        if _IMG_TOKEN.search(plain):
            # pictures (a drawing beside the passage) are not part of it; the first one shows with the set
            ptxt, found = _take_images(plain)
            pics += found
            if not ptxt.strip():
                continue
            plain, mask = ptxt, None
        s = plain.strip()
        h = _BANK_HEAD.match(s)
        if h:
            bank += [w for w in re.split(r"\t|\s{2,}|\s*[,，、|]\s*", h.group(1)) if w.strip()]
            continue
        bw = _bank_words(s)
        if bw:
            bank += bw
            continue
        if not passage and not _has_blank(s) and (_INSTRUCTION.search(s) or len(s.split()) <= 6):
            instr.append(s)
            continue
        passage.append(_mark_blanks(plain, mask, use_em=True).strip())
    text = re.sub(r"\s+", " ", " ".join(passage)).strip()
    if "[[" not in text:
        return None
    q: Dict[str, Any] = {"type": "cloze", "q": _instruction(instr), "text": text, "bank": [w.strip() for w in bank]}
    if pics:
        q["image"] = pics[0]
    return q


_WORKING = re.compile(r"^\s*(?:แสดง)?ว\s*[ิ]?\s*[ธช]\s*[ีิ]?\s*ท\s*[ำา]")        # "วิธีทำ": room to work follows
_TAIL_ANS = re.compile(r"(?:^|\s{2,}|\t)\(\s*([^()\t]{1,45}?)\s*\)?\s*$")           # "...เท่าใด        (0.16 kg/m3)"
_CHO_ANS = re.compile(r"\(\s*ข้อ\s*([1-6])\s*\)?\s*$")                               # "(ข้อ 4)"
_CHO_ANS_OCR = re.compile(r"\(\s*[^\d\s()]{1,4}\s*([1-6])\S?\s*\)?\s*$")                 # the same misread: "(va 39", "(ขอ 2"
def _loose_row(text: str, first: int) -> Optional[str]:
    """A row of numbered choices as OCR reads it from fractions and formulas: "1 1.14    2. 12 _1    3. 8.1    4, 8 , 10"
    (a dot lost or read as a comma) -> "1. 1.14   2. 12 _1   3. 8.1   4. 8 , 10". The pieces are far apart and
    numbered first, first + 1, ... ; None when the line is not such a row."""
    parts = re.split(r"\s{3,}", text.strip())
    if len(parts) < 3:
        return None
    out = []
    for i, part in enumerate(parts):
        m = re.match(r"^([1-6])(?:\s*[.,)]\s*|\s+)(\S.*)?$", part)
        if not m or int(m.group(1)) != first + i:
            return None
        out.append(f"{m.group(1)}. {m.group(2) or ''}".rstrip())
    return "   ".join(out)


_Q_CUE = re.compile(r"(ข้อใด|เท่าใด|เท่าไร|เท่าไหร่|อย่างไร|กี่|\?)\s*$")
_NUM_SPLIT = re.compile(r"(?:\s{2,}|\t)(?=[1-6]\s*[.)])|\s+(?=[1-6]\s*[.)]\s)")   # "1. 925   2. 725" / "1.925   2.725"
_SUBQ = re.compile(r"(หรือไม่|อย่างไร|เพราะเหตุใด|เท่าใด|เท่าไร|อะไร)\s*\??\s*$")
_SCI = re.compile(r"(\d+(?:\.\d+)?)\s*[xX×]\s*10\^?(-?\d{1,2})(?![\d.])")


def _sci_text(s: str) -> str:
    """OCR flattens 4.75×10¹⁷ to "4.75x1017": write it 4.75x10^17 (a decimal or a 2-digit power only)."""
    def f(m):
        if "." in m.group(1) or len(m.group(2).lstrip("-")) == 2:
            return f"{m.group(1)}x10^{m.group(2)}"
        return m.group(0)
    return _SCI.sub(f, s)


def parse_lines(lines: List[str], pos: Optional[List[Optional[int]]] = None,
                layout: Optional["Layout"] = None) -> Tuple[List[Dict[str, Any]], List[str]]:
    pos = list(pos) if pos else [None] * len(lines)
    pos += [None] * (len(lines) - len(pos))
    entries = [(_clean_line(x), p) for x, p in zip(lines, pos)]
    entries = [(x, p) for x, p in entries if x.strip() and not _PAGE_NO.match(_plain(x)) and not _FORM_HEAD.search(_plain(x))]
    # page headers / footers: a web address, or the same short line on many pages
    seen: Dict[str, int] = {}
    for x, _ in entries:
        k = re.sub(r"[^0-9a-zก-๛]", "", _plain(x).lower())
        seen[k] = seen.get(k, 0) + 1
    entries = [(x, p) for x, p in entries
               if not (len(re.sub(r"\s+", " ", _plain(x))) <= 120 and not _Q_START.match(_plain(x)) and not _CHOICE.match(_plain(x))
                       and not _NUM_CHOICE.match(_plain(x)) and not _WORKING.match(_plain(x)) and not _ANSWER.match(_plain(x))
                       and (re.search(r"https?://|www\.", _plain(x), re.IGNORECASE)
                            or (seen[re.sub(r"[^0-9a-zก-๛]", "", _plain(x).lower())] >= 3 and len(_plain(x).strip()) >= 8)))]
    lines = [x for x, _ in entries]
    notes: List[str] = []

    # a table like the Excel paste: โจทย์ | ก | ข | ค | ง | คำตอบ
    tab_rows = [x for x in lines if "\t" in x and len([c for c in x.split("\t") if c.strip()]) >= 3]
    if tab_rows and len(tab_rows) >= max(2, len(lines) // 2) and not any(_M_OPT.search(_plain(x)) and _M_ITEM.match(_plain(x)) for x in tab_rows[:3]):
        out = []
        for ln in tab_rows:
            cells = [_take_images(_plain(c))[0].strip() for c in ln.split("\t")]
            cells = [c for c in cells if c]
            m = _Q_START.match(cells[0]) if cells else None
            if m and m.group(2):
                cells[0] = m.group(2)
            elif cells and cells[0].isdigit():
                cells = cells[1:]
            if len(cells) < 3:
                continue
            if re.match(r"^(โจทย์|คำถาม|ข้อ|question)", cells[0], re.IGNORECASE) and _letter_index(cells[-1]) is None:
                continue  # header row
            ans = _letter_index(cells[-1]) if len(cells[-1]) <= 2 else None
            choices = cells[1:-1] if ans is not None or len(cells[-1]) <= 2 else cells[1:]
            if ans is None and len(cells[-1]) <= 2:
                continue  # header row ("โจทย์ | ก | ข | ... | คำตอบ")
            out.append({"type": "choice", "q": cells[0], "choices": choices[:5], "answer": ans if ans is not None and ans < len(choices) else None})
        return _finish(out, notes)

    # 1. the answer key(s): "เฉลย" then "1. ข 2. ค" lines (or a table "1 | ข"); for ถูก/ผิด "1. ✓ 2. ✗" / "1. ถูก"
    key: Dict[int, int] = {}
    tf_key: Dict[int, bool] = {}
    keep: List[Tuple[str, Optional[int]]] = []
    i = 0
    while i < len(lines):
        plain = _plain(lines[i]).replace("\t", " ")
        m = _KEY_HEAD.match(plain)
        rest = m.group(1).strip() if m else ""
        if m and ((rest and _TF_ONLY.match(rest)) or (not rest and i + 1 < len(lines) and _TF_ONLY.match(_plain(lines[i + 1]).replace("\t", " ")))):
            for n, t in _TF_PAIR.findall(rest):
                tf_key[int(n)] = _tf_value(t)
            j = i + 1
            while j < len(lines) and _TF_ONLY.match(_plain(lines[j]).replace("\t", " ")):
                for n, t in _TF_PAIR.findall(_plain(lines[j])):
                    tf_key[int(n)] = _tf_value(t)
                j += 1
            i = j
            continue
        head = bool(m) and (not rest or _PAIRS_ONLY.match(rest))
        if head or (_PAIRS_ONLY.match(plain) and len(_key_pairs(plain)) >= 3):
            if head and rest:
                key.update(_key_pairs(rest))
            elif not head:
                key.update(_key_pairs(plain))
            j = i + 1
            while j < len(lines) and _PAIRS_ONLY.match(_plain(lines[j]).replace("\t", " ")):
                key.update(_key_pairs(lines[j]))
                j += 1
            if head and j == i + 1 and not rest:
                keep.append(entries[i])   # a lone "เฉลย" heading with nothing after it: not a key
            i = j
            continue
        keep.append(entries[i])
        i += 1

    # 2. sections: "ตอนที่ ..." / "คำชี้แจง ..." / "Exercise 3 ..." start one; its words (or its shape) say what it is
    segments: List[List[List[Tuple[str, Optional[int]]]]] = [[[], []]]
    for e in keep:
        p = _plain(e[0])
        if _SECTION.match(p) or _EXERCISE.match(p):
            segments.append([[e], []])
        else:
            segments[-1][1].append(e)

    # 3. questions (every line as its text + which characters were emphasised)
    qs: List[Dict[str, Any]] = []
    cur: Optional[Dict[str, Any]] = None
    section = ""

    def pieces(text: str, mask: List[bool]):
        """split "ก. 3  ข. 4" into its choices, keeping each piece's emphasis"""
        out, prev = [], 0
        for m in _SPLIT.finditer(text):
            out.append((text[prev:m.start()], mask[prev:m.start()]))
            prev = m.end()
        out.append((text[prev:], mask[prev:]))
        return [(t, k) for t, k in out if t.strip()]

    def add_choice(q, text: str, mask: List[bool]):
        for t, k in pieces(text, mask):
            m = _CHOICE.match(t)
            if m:
                body = m.group(3)
                if not q["choices"]:
                    q["latin"] = m.group(2).isascii()        # a. b. c. d. — the picture shows these letters
                star = bool(m.group(1)) or bool(re.search(rf"\s*{_MARK}\s*$", body))
                q["choices"].append(re.sub(rf"\s*{_MARK}\s*$", "", body).strip())
                q["marks"].append((star, _mostly_emphasised(body, k[m.start(3):m.end(3)])))
            elif q["choices"]:
                q["choices"][-1] = (q["choices"][-1] + " " + t.strip()).strip()

    def add_numbered(q, text: str, mask: List[bool]) -> None:
        """choices written 1. 2. 3. 4. (several on a line too)"""
        starts = [0] + [m.end() for m in _NUM_SPLIT.finditer(text)]
        for a, b in zip(starts, starts[1:] + [len(text)]):
            piece, km = text[a:b].strip(), mask[a:b]
            m = re.match(r"^\s*([1-6])\s*[.)]\s*(.*)$", piece)
            if m and int(m.group(1)) == len(q["choices"]) + 1:
                body = m.group(2)
                star = bool(re.search(rf"\s*{_MARK}\s*$", body))
                q["choices"].append(re.sub(rf"\s*{_MARK}\s*$", "", body).strip())
                q["marks"].append((star, _mostly_emphasised(body, km[-len(body):] if body else [])))
            elif q["choices"] and piece:
                q["choices"][-1] = (q["choices"][-1] + " " + piece).strip()
        q["numbered"] = True

    def x_of(p) -> Optional[float]:
        """left edge of a line on the page (pictures and OCR keep every line's box)"""
        if layout is None or p is None or not 0 <= p < len(layout.lines):
            return None
        b = layout.lines[p].get("box")
        return b[0] if b else None

    def next_question(q, n: int, text: str, p) -> bool:
        """ "5. ..." after the choices 1. - 4.: the next question, not a fifth choice, when its number stands at the
        questions' margin (left of the choices), or (no positions) when it reads as a question"""
        if n != q["num"] + 1 or not q["choices"] or not q["numbered"]:
            return False
        x, qx, cx = x_of(p), q.get("_qx"), q.get("_cx")
        if x is not None and qx is not None and cx is not None:
            h = (layout.lines[p].get("h") or 10) if layout is not None else 10
            if cx - qx > max(4.0, 0.5 * h):
                return abs(x - qx) < abs(x - cx)
        return len(q["choices"]) >= 4 and len(text) > 25 and bool(_Q_CUE.search(text))

    def new_question(num: int, text: str, mask: List[bool], p):
        q = {"num": num, "q": "", "choices": [], "marks": [], "answer_text": None, "section": section, "mask": None,
             "numbered": False, "closed": False, "sub_answers": [], "_lines": [p], "_stop": None, "_ans_lines": [],
             "_qx": x_of(p)}
        ps = pieces(text, mask)
        if len(ps) >= 3 and all(_CHOICE.match(t) for t, _ in ps[1:]):   # "1. 2+2 = ?  ก. 3  ข. 4  ค. 5"
            q["q"] = ps[0][0]
            for t, k in ps[1:]:
                add_choice(q, t, k)
        else:
            q["q"] = text
            q["mask"] = mask if len(mask) == len(text) else None
        qs.append(q)
        return q

    def tail_answer(plain: str, mask: List[bool], into_choice: bool = False, p=None, numbered_line: bool = False):
        """An answer printed at the right end of the line: taken off the text, kept as the key."""
        if cur is None:
            return plain, mask
        m = _CHO_ANS.search(plain) or (_CHO_ANS_OCR.search(plain) if numbered_line else None)
        if m:
            cur["answer_text"] = cur["answer_text"] or f"ข้อ {m.group(1)}"
            cur["_ans_lines"].append(p)
            return plain[:m.start()].rstrip(), mask[:m.start()]
        m = _TAIL_ANS.search(plain)
        if m and re.search(r"[\dก-๛a-zA-Z]", m.group(1)):
            if into_choice:
                cur["sub_answers"].append(m.group(1).strip())
            elif not cur["answer_text"]:
                cur["answer_text"] = m.group(1).strip()
            else:
                return plain, mask
            cur["_ans_lines"].append(p)
            return plain[:m.start()].rstrip(), mask[:m.start()]
        return plain, mask

    for header, body in segments:
        cur, pending_num = None, None
        head_txt = [x for x, _ in header]
        body_txt = [x for x, _ in body]
        look = " ".join(_plain(x) for x in head_txt + [b for b in body_txt if not _Q_START.match(_plain(b))][:2])
        kind = _kind_of(look) if header else ""
        numbered = any(_Q_START.match(_plain(b)) for b in body_txt)
        if kind == "cloze" and numbered:
            kind = "fill"                 # numbered sentences with blanks: one เติมคำ question each
        elif kind == "fill" and not numbered:
            kind = "cloze"                # a passage with blanks
        if not kind:
            kind = _shape_kind(body_txt)
        built = None
        if kind == "truefalse":
            # the instruction's second line belongs to it, not to a statement
            while body_txt and not _TF_LEAD.match(_plain(body_txt[0])) and len(head_txt) < 4:
                head_txt.append(body_txt.pop(0))
            built = _tf_block(head_txt, body_txt, tf_key)
        elif kind == "match":
            while body_txt and not _M_ITEM.match(_plain(body_txt[0])) and not _M_OPT.match(_plain(body_txt[0])) and len(head_txt) < 4:
                head_txt.append(body_txt.pop(0))
            built = _match_block(head_txt, body_txt, key)
        elif kind == "cloze":
            built = _cloze_block(head_txt, body_txt)
        if built:
            built["_lines"] = [p for _, p in header + body]
            qs.append({"prebuilt": built, "num": None})
            continue
        section = kind
        for ln, p in body:
            plain, mask = _split_mask(ln)
            if _WORKING.match(plain):
                if cur is not None:
                    tail_answer(plain, mask, p=p)
                    cur["closed"] = True
                    cur["_stop"] = cur["_stop"] if cur["_stop"] is not None else p
                continue
            m = _ANSWER.match(plain)
            if m and cur is not None:
                cur["answer_text"] = m.group(1).strip().strip("()")
                continue
            qm = _Q_START.match(plain)
            if qm and (int(qm.group(1)) == 0 or (cur is not None and _DECIMAL_START.match(plain) and int(qm.group(1)) != cur["num"] + 1)):
                qm = None                 # "0.5 เมตร ..." / "2.5 กิโลกรัม" continue the line above ("8.15x3" after ข้อ 7 is ข้อ 8)
            lm = _LOOSE_CHOICE.match(plain) if (layout is not None and p is not None and layout.lines[p].get("ocr")) else None
            if (lm and cur is not None and not cur["closed"] and not cur["numbered"] and not _CHOICE.match(plain)
                    and len(cur["choices"]) < len(LETTERS) and (cur["choices"] or _SUBQ.search(cur["q"]) or len(cur["q"]) > 10)):
                # OCR reads ก. / ง. before Latin letters or digits as "n." "v." "J.": the next choice
                k = len(cur["choices"])
                plain, mask = LETTERS[k] + ". " + plain[lm.start(2):], [False] * 3 + mask[lm.start(2):]
            ocr = layout is not None and p is not None and 0 <= p < len(layout.lines) and layout.lines[p].get("ocr")
            if ocr and cur is not None and not cur["closed"] and (cur["numbered"] or not cur["choices"]):
                row = _loose_row(plain, len(cur["choices"]) + 1)
                if row and row != plain:
                    plain, mask = row, [False] * len(row)
                cm = re.match(r"^(\s*([1-6])\s*),(?=\s+\S)", plain)
                if (cm and cur["numbered"] and int(cm.group(2)) == len(cur["choices"]) + 1
                        and (int(cm.group(2)) != cur["num"] + 1 or not next_question(cur, int(cm.group(2)), plain, p))):
                    plain = cm.group(1) + "." + plain[cm.end():]    # "4, 89": OCR read the dot of choice 4 as a comma
            nm = _NUM_CHOICE.match(plain)
            if nm and cur is not None and next_question(cur, int(nm.group(1)), plain, p):
                nm = None                         # ข้อ 5 after the choices 1. - 4. of ข้อ 4
            if (nm and cur is not None and not cur["closed"] and cur["choices"] and not cur["numbered"]
                    and int(nm.group(1)) == len(cur["choices"]) + 1 and int(nm.group(1)) != cur["num"] + 1
                    and int(nm.group(1)) <= len(LETTERS)):
                # OCR reads ข. as "2." after ก.: the next letter, not a question
                k = int(nm.group(1))
                lead = re.match(r"^\s*\d\s*[.)]", plain).end()
                plain, mask = LETTERS[k - 1] + "." + plain[lead:], [False] * 2 + mask[lead:]
                qm = None
            if (nm and cur is not None and not cur["closed"] and (cur["numbered"] or not cur["choices"])
                    and int(nm.group(1)) == len(cur["choices"]) + 1 and (cur["numbered"] or int(nm.group(1)) == 1)):
                plain, mask = tail_answer(plain, mask, p=p, numbered_line=True)
                if not cur["choices"]:
                    cur["_cx"] = x_of(p)
                add_numbered(cur, plain, mask)
                cur["_lines"].append(p)
                continue
            if cur is not None and not cur["closed"] and _CHOICE.match(plain) and not qm:
                if cur["numbered"]:
                    # "1) ... 2) ..." was a list inside the question; its choices are ก. ข. ค.
                    cur["q"] = (cur["q"] + "\n" + "\n".join(f"{k + 1}) {c}" for k, c in enumerate(cur["choices"]))).strip()
                    cur["choices"], cur["marks"], cur["numbered"] = [], [], False
                plain, mask = tail_answer(plain, mask, into_choice=True, p=p)
                add_choice(cur, plain, mask)
                cur["_lines"].append(p)
                continue
            m = _Q_KHO.match(plain)
            if m:
                pending_num = int(m.group(1))
                continue
            if qm:
                cur = new_question(int(qm.group(1)), qm.group(2), mask[qm.start(2):], p)
                cur["q"], cur["mask"] = tail_answer(cur["q"], cur["mask"] or [False] * len(cur["q"]), p=p)
                pending_num = None
                continue
            if pending_num is not None:
                cur = new_question(pending_num, plain, mask, p)
                pending_num = None
                continue
            if cur is not None and not cur["closed"]:
                plain, mask = tail_answer(plain, mask, into_choice=bool(cur["choices"]) and not cur["numbered"], p=p,
                                          numbered_line=cur["numbered"])
                cur["mask"] = None
                cur["_lines"].append(p)
                if not plain.strip():
                    continue
                if cur["choices"]:
                    cur["choices"][-1] = (cur["choices"][-1] + " " + plain.strip()).strip()
                else:
                    cur["q"] = (cur["q"] + "\n" + plain.strip()).strip()

    # numbered lines in an explanation box ("1. มีทิศได้ทุกทิศทาง") between ข้อ 5 and ข้อ 6 are not questions
    plain_qs = [q for q in qs if "prebuilt" not in q]
    stray = set()
    for k in range(1, len(plain_qs) - 1):
        a, b, c = plain_qs[k - 1]["num"], plain_qs[k]["num"], plain_qs[k + 1]["num"]
        if b < a and c > a:
            stray.add(id(plain_qs[k]))
    if stray:
        notes.append(f"ข้ามข้อความที่มีเลขข้อแทรกกลาง {len(stray)} แห่ง (น่าจะเป็นคำอธิบาย ไม่ใช่ข้อสอบ) — ตรวจกับต้นฉบับ")

    out = []
    for q in qs:
        if "prebuilt" in q:
            out.append(q["prebuilt"])
            continue
        if id(q) in stray:
            continue
        base = {"num": q["num"], "_lines": q["_lines"], "_stop": q["_stop"], "_ans_lines": q["_ans_lines"]}
        text = _sci_text(q["q"].strip()) if layout is not None else q["q"].strip()
        ans_t = q["answer_text"]
        if q["choices"]:
            letters = "1234" if q["numbered"] else LETTERS
            subq = q["sub_answers"] or sum(1 for c in q["choices"] if _SUBQ.search(_take_images(c)[0])) >= 2
            if subq and not q["numbered"]:
                # ก. ... ข. ... ค. ... are parts of one question (each with its own answer), not choices
                parts = "\n".join(f"{LETTERS[k] if k < len(LETTERS) else '-'}. {_take_images(c)[0]}" for k, c in enumerate(q["choices"]))
                guide = " • ".join(f"{LETTERS[k]}. {a}" for k, a in enumerate(q["sub_answers"]) if k < len(LETTERS))
                out.append({**base, "type": "photo", "q": f"{text}\n{parts}", "guide": guide})
                continue
            answer = None
            if ans_t:
                m = re.match(r"^\s*(?:ข้อ\s*)?([1-6])\b", _plain(ans_t)) if q["numbered"] else None
                answer = int(m.group(1)) - 1 if m else (None if q["numbered"] else _letter_index(_plain(ans_t)[:1]))
            if answer is None and q["num"] in key and not q["numbered"]:
                answer = key[q["num"]]
            if answer is None:
                stars = [k for k, (s, _) in enumerate(q["marks"]) if s]
                ems = [k for k, (_, e) in enumerate(q["marks"]) if e]
                if len(stars) == 1:
                    answer = stars[0]
                elif len(ems) == 1 and len(q["choices"]) > 1:
                    answer = ems[0]
            ch = [_take_images(c)[0] for c in q["choices"]]
            if layout is not None:
                ch = [_sci_text(c) for c in ch]
            labels = {"labels": "number"} if q["numbered"] else ({"labels": "latin"} if q.get("latin") else {})
            out.append({**base, "type": "choice", "q": text, "choices": ch, "answer": answer, **labels})
            continue
        if q["section"] == "photo":
            out.append({**base, "type": "photo", "q": text, "guide": _plain(ans_t or "").strip()})
            continue
        fill = q["section"] == "fill"
        mask = q["mask"] if q["mask"] is not None and len(q["mask"]) == len(q["q"]) else None
        inline = None if ans_t else re.search(r"\s+(?:ตอบ|คำตอบ|answer|ans)\s*[:：.]?\s*(\S.*)$", q["q"], re.IGNORECASE)
        if inline:
            ans_t = inline.group(1).strip().strip("()")
            q["q"], mask = q["q"][:inline.start()], (mask[:inline.start()] if mask else None)
            text = q["q"].strip()
        marked = _mark_blanks(q["q"], mask, use_em=fill).strip() if (_has_blank(text) or fill) else text
        blanks = re.findall(r"\[\[([^\]]*)\]\]", marked)
        if len(blanks) >= 2 and (fill or any(b.strip() for b in blanks)):
            out.append({**base, "type": "cloze", "q": "", "text": marked, "bank": []})
            continue
        filled = blanks[0].strip() if len(blanks) == 1 else ""
        ans = _plain(ans_t or "").strip() or filled
        if layout is not None:
            ans = _sci_text(ans)
        shown = re.sub(r"\[\[[^\]]*\]\]", "________", marked).strip() if len(blanks) == 1 else text
        short = bool(ans) and len(ans) <= 40 and len(ans.split()) <= 4 and not re.search(r"[.!?]\s*\S", ans)
        if ans and _number_answer(ans):
            num, unit = _number_answer(ans)
            out.append({**base, "type": "number", "q": shown if filled else text, "answer": num, "unit": unit})
        elif short and not q["closed"] or (fill and blanks):
            # dotted lines with no answer outside a เติมคำ part are room to write, not a word blank
            out.append({**base, "type": "text", "q": shown, "answer": ans})
        else:
            # "วิธีทำ" under it / a long answer: written on paper and photographed, the printed answer is the guide
            out.append({**base, "type": "photo", "q": text, "guide": ans})
    nums = [q["num"] for q in out if q.get("num") is not None]
    if nums:
        missing = [n for n in range(min(nums), max(nums) + 1) if n not in set(nums)]
        if missing and len(missing) <= 20 and not any(q["type"] in exams.SET_TYPES for q in out):
            notes.append("ไม่พบข้อ " + ", ".join(map(str, missing)) + " (รูปแบบไม่ตรงหรือเป็นรูปภาพ) — ตรวจกับต้นฉบับ")
    if layout is not None:
        _attach_figures(out, layout, notes)
    return _finish(out, notes)


def _finish(out: List[Dict[str, Any]], notes: List[str]) -> Tuple[List[Dict[str, Any]], List[str]]:
    clean = []
    for q in out:
        figures = q.get("_figures") or []
        scan = q.get("_scan")
        q = {k: v for k, v in q.items() if k != "num" and not k.startswith("_")}
        if scan:
            q["scan_image"] = scan          # the question as printed; the editor offers it in place of the figure
        q["points"] = 1
        pics: List[str] = []
        for field in ("q", "text"):
            if isinstance(q.get(field), str):
                q[field], found = _take_images(q[field])
                pics += found
        if q.get("image"):
            pics.insert(0, q.pop("image"))
        pics += figures
        pics = list(dict.fromkeys(pics))
        if pics:
            q["image"] = pics[0] if len(pics) == 1 else _compose(pics)
        if q["type"] == "choice":
            ch = [c.strip() for c in q["choices"] if c and c.strip()]
            if len(q["choices"]) > len(LETTERS):
                notes.append(f"ข้อ \"{q['q'][:30]}\" มีตัวเลือกเกิน {len(LETTERS)} ตัว เก็บไว้ {len(LETTERS)} ตัวแรก")
            ans = q.get("answer")
            if ans is not None and (ans >= len(q["choices"]) or not q["choices"][ans].strip()):
                ans = None
            if ans is not None:
                ans = ch.index(q["choices"][ans].strip())
            q["choices"], q["answer"] = ch[:len(LETTERS)], ans if ans is not None and ans < len(LETTERS) else None
            if len(q["choices"]) < 2:
                q = {"type": "photo", "q": "\n".join([q["q"], *q["choices"]]).strip(), "guide": "", "points": 1,
                     **{k: q[k] for k in ("image", "scan_image") if q.get(k)}}
        if q["type"] == "match" and any(o.pop("missing_picture", False) for o in q["options"]):
            notes.append(f"ชุดจับคู่ \"{q['q'][:30]}\": ตัวเลือกที่เป็นรูปบางตัวดึงจากไฟล์ไม่ได้ — กดปุ่มรูปที่ตัวเลือกเพื่อใส่รูปเอง")
        if not q.get("q") and q["type"] not in exams.SET_TYPES:
            if q.get("image"):
                q["q"] = "(ดูรูป)"
            else:
                continue
        clean.append(q)
    return clean, notes


# ---------------------------------------------------------------- entry point

def missing_key(q: Dict[str, Any]) -> bool:
    t = q["type"]
    if t == "choice":
        return q.get("answer") is None
    if t in ("number", "text"):
        return not str(q.get("answer") or "").strip()
    if t in ("truefalse", "match"):
        return any(it.get("answer") is None for it in q.get("items") or [])
    if t == "cloze":
        return any(not a for a in exams.cloze_blanks(q.get("text") or "")) or (
            bool(q.get("bank")) and any(not any(exams.text_matches(w, a) for w in q["bank"]) for a in exams.cloze_blanks(q.get("text") or "") if a))
    return False


def _pictures_in(qs: List[Dict[str, Any]]) -> int:
    n = 0
    for q in qs:
        n += bool(q.get("image"))
        for part in (q.get("items") or []) + (q.get("options") or []):
            n += isinstance(part, dict) and bool(part.get("image"))
    return n


def questions_from_file(filename: str, data: bytes, progress: Optional[Callable[[str], None]] = None) -> Dict[str, Any]:
    _job.progress, _job.layout = progress, Layout()
    try:
        return _questions_from_file(filename, data)
    finally:
        _job.progress, _job.layout = None, None


def _questions_from_file(filename: str, data: bytes) -> Dict[str, Any]:
    if not data:
        raise ValueError("ไฟล์ว่าง")
    if len(data) > MAX_BYTES:
        raise ValueError("ไฟล์ใหญ่เกิน 25 MB")
    ext = Path(filename or "").suffix.lower()
    if ext == ".doc" or data[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1":
        data, ext = _doc_to_docx(data), ".docx"
    if ext == ".pdf" or data[:4] == b"%PDF":
        lines, info = pdf_lines(data)
    elif ext == ".docx" or data[:2] == b"PK":
        try:
            _progress("กำลังเปิดไฟล์ Word...")
            lines, info = docx_lines(data)
        except ValueError:
            raise
        except Exception:
            raise ValueError("เปิดไฟล์ Word ไม่ได้ (ไฟล์เสียหรือมีรหัสผ่าน)")
        if _has_math(data) and (shutil.which("soffice") or Path(r"C:\Program Files\LibreOffice\program\soffice.exe").exists()):
            # formulas (Word equations) do not survive as text: read the PDF of the paper, so each question can
            # be shown as its picture
            _progress("ไฟล์มีสูตร — กำลังแปลงเป็นหน้ากระดาษ...")
            lines, info = pdf_lines(_office_to_pdf(data, ".docx"))
            info["math"] = True
        elif _looks_scanned(lines, info) and find_tesseract():
            _progress("ไฟล์นี้แปลงมาจากภาพสแกน — กำลังแปลงเป็นหน้ากระดาษ...")
            images = info.get("images", 0)
            lines, info = pdf_lines(_office_to_pdf(data, ".docx"), force_ocr=True)
            info["converted_scan"], info["images"] = True, 0
            _job.converted = images
    elif ext in IMAGE_EXT or data[:3] == b"\xff\xd8\xff" or data[:8] == b"\x89PNG\r\n\x1a\n":
        lines, info = image_lines(data)
    elif ext in (".txt", ""):
        lines, info = data.decode("utf-8", errors="replace").splitlines(), {"images": 0}
    else:
        raise ValueError("รองรับไฟล์ Word (.docx, .doc), PDF และรูปภาพ (.jpg .png)")
    _progress("กำลังจัดข้อสอบ...")
    layout = _job.layout if _job.layout is not None and _job.layout.lines else None
    qs, notes = parse_lines(lines, info.get("pos"), layout)
    if info.get("converted_scan"):
        notes.insert(0, "ไฟล์ Word นี้แปลงมาจากภาพสแกน (ตัวอักษรในไฟล์อ่านไม่ได้) — ระบบอ่านจากภาพทุกหน้าแทน")
    if not qs:
        raise ValueError("ไม่พบข้อสอบในไฟล์ — ข้อสอบต้องขึ้นต้นด้วยเลขข้อ (1. 2. ...) และตัวเลือก ก. ข. ค. ง.")
    no_key = [i + 1 for i, q in enumerate(qs) if missing_key(q)]
    if no_key:
        notes.insert(0, f"ยังไม่มีเฉลย {len(no_key)} ข้อ (ข้อ {', '.join(map(str, no_key[:15]))}{' ...' if len(no_key) > 15 else ''}) — ใส่เฉลยในข้อที่มีกรอบสีส้ม")
    if info.get("ocr_pages"):
        notes.insert(0, f"อ่านจากภาพด้วย OCR {info['ocr_pages']} หน้า — ตรวจตัวสะกด ตัวเลข และเฉลยทุกข้อ"
                        " (ในภาพ ระบบดูตัวหนา/สี/ไฮไลต์ไม่ออก ใช้ได้เฉพาะ 'ตอบ ข' หรือตารางเฉลย)")
    if info.get("ocr_skipped"):
        notes.append(f"อ่านด้วย OCR ได้สูงสุด {OCR_MAX_PAGES} หน้าต่อไฟล์ — แบ่งไฟล์แล้วอัปโหลดเพิ่ม")
    used = _pictures_in(qs)
    if used:
        notes.append(f"ใส่รูปจากไฟล์ให้แล้ว {used} รูป — ตรวจว่ารูปตรงกับข้อ/ตัวเลือก")
    if info.get("images") and info["images"] > used:
        notes.append(f"ในไฟล์มีรูปภาพที่ไม่ได้นำเข้า {info['images'] - used} รูป — ข้อที่ต้องดูรูป กดปุ่มรูปในข้อนั้นเพื่อใส่เอง")
    counts = {t: sum(1 for q in qs if q["type"] == t) for t in exams.QUESTION_TYPES}
    # show each question as its picture: a scan, a paper with formulas, or one full of drawings (maths / science)
    # (formulas and labels of drawings come out of a PDF as lines of lone letters / digits: "2 2", "s u", "A")
    loose = [ln for ln in (_plain(x).strip() for x in lines) if ln and all(len(t) <= 2 for t in ln.split())]
    suggest = bool(info.get("ocr_pages") or info.get("math") or (len(loose) >= 5 and len(loose) >= 0.08 * len(lines)))
    return {"questions": qs, "notes": notes, "counts": counts, "suggest_image": suggest and any(q.get("scan_image") for q in qs)}
