"""
API สาธารณะ (ไม่ต้องล็อกอิน) สำหรับแสดงข้อมูลบนเว็บอื่น เช่น เว็บโรงเรียน / Google Sites (เจ้าของตัดสินใจ 9 พ.ย. 2569):
  * แดชบอร์ดการมาเรียน: ตัวเลขสรุปเท่านั้น (จำนวนนักเรียน, % มาเรียน รวม/รายชั้น/รายเดือน, จำนวนกลุ่มเสี่ยง/เฝ้าระวัง)
    ไม่มีแถวรายคน แม้จะปิดชื่อ — บางชั้นมีไม่กี่คน คนในชุมชนเดาได้
  * ตารางสอนครู: วัน คาบ รหัสวิชา ชื่อวิชา ชั้น ห้อง (ไม่มีหมายเหตุ / id / เวลาแก้ไข)
  * เปิดให้ทุกเว็บ ไม่ต้องใช้กุญแจ; ผู้ดูแลระบบเปิด/ปิดแต่ละชุดได้ (app_settings "public_api"); พักผลไว้ 60 วินาที
    และจำกัดความถี่ต่อเครื่อง เพื่อไม่ให้เครื่องเซิร์ฟเวอร์ของโรงเรียนทำงานหนัก
  * "โค้ดสำหรับวาง" (embed_snippet): HTML + JavaScript ที่ดึงข้อมูลจาก API นี้ ใช้วางในช่อง Embed ของเว็บอื่น
    (ฝังหน้าเว็บของระบบแบบ iframe ผ่าน ngrok ฟรีไม่ได้ เพราะ ngrok ขึ้นหน้าเตือนก่อน — fetch ที่ส่ง header
    ngrok-skip-browser-warning ผ่านได้)
"""
import school_profile
import json
import os
import re
import threading
import time
from collections import defaultdict, deque
from typing import Any, Callable, Dict, Optional, Tuple

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse

import auth
import database

DB = "school_archive.db"
SETTING = "public_api"
DATASETS = ("dashboard", "timetable")
CACHE_SECONDS = 60
RATE_PER_MINUTE = 60          # requests per client per minute (a page load makes 2-3)
DAY_NAMES = {1: "จันทร์", 2: "อังคาร", 3: "พุธ", 4: "พฤหัสบดี", 5: "ศุกร์", 6: "เสาร์", 7: "อาทิตย์"}


# ---------------------------------------------------------------- settings
def settings() -> Dict[str, Any]:
    """{dashboard: bool, timetable: bool, base_url: str} — both open unless the admin closed them."""
    try:
        raw = json.loads(database.get_app_setting(SETTING, "", db_path=DB) or "{}")
    except Exception:
        raw = {}
    out = {k: bool(raw.get(k, True)) for k in DATASETS}
    out["base_url"] = str(raw.get("base_url") or "").strip()
    return out


def save_settings(changes: Dict[str, Any]) -> Dict[str, Any]:
    cur = settings()
    for k in DATASETS:
        if k in changes and changes[k] is not None:
            cur[k] = bool(changes[k])
    if changes.get("base_url") is not None:
        url = str(changes["base_url"]).strip().rstrip("/")
        if url and not re.fullmatch(r"https?://[A-Za-z0-9.\-]+(:\d+)?(/[\w\-./]*)?", url):
            raise HTTPException(status_code=400, detail="ที่อยู่เว็บไม่ถูกต้อง (ตัวอย่าง https://xxx.ngrok-free.dev)")
        cur["base_url"] = url
    database.set_app_setting(SETTING, json.dumps(cur, ensure_ascii=False), db_path=DB)
    _cache.clear()
    return cur


def default_base_url() -> str:
    """The address other websites reach this system at (the ngrok domain of start_ngrok.js / standby_sync.py)."""
    url = os.environ.get("STANDBY_PUBLIC_URL")
    if url:
        return url.rstrip("/")
    domain = os.environ.get("NGROK_DOMAIN")
    if not domain:
        try:
            import standby_sync
            domain = standby_sync.DEFAULT_DOMAIN
        except Exception:
            domain = ""
    return f"https://{domain}" if domain else ""


def base_url() -> str:
    return settings()["base_url"] or default_base_url()


# ---------------------------------------------------------------- cache + rate limit
_cache: Dict[tuple, Tuple[float, Any]] = {}
_hits: Dict[str, deque] = defaultdict(deque)
_lock = threading.Lock()


def _cached(key: tuple, build: Callable[[], Any]) -> Any:
    now = time.time()
    with _lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < CACHE_SECONDS:
            return hit[1]
    value = build()
    with _lock:
        if len(_cache) > 200:
            _cache.clear()
        _cache[key] = (now, value)
    return value


def _limit(request: Request) -> None:
    ip = auth.client_ip(request)
    now = time.time()
    with _lock:
        q = _hits[ip]
        while q and now - q[0] > 60:
            q.popleft()
        if len(q) >= RATE_PER_MINUTE:
            raise HTTPException(status_code=429, detail="เรียกข้อมูลถี่เกินไป กรุณารอสักครู่")
        q.append(now)
        if len(_hits) > 5000:
            for k in [k for k, v in _hits.items() if not v or now - v[-1] > 60]:
                del _hits[k]


def _open(dataset: str) -> None:
    if not settings()[dataset]:
        raise HTTPException(status_code=403, detail="ผู้ดูแลระบบปิดการแสดงข้อมูลนี้บนเว็บอื่นไว้")


def _semester(term: Optional[str], year: Optional[str], current: Callable[[], Tuple[str, str]]) -> Tuple[str, str]:
    t, y = (term or "").strip(), (year or "").strip()
    if not t or not y:
        t, y = current()
    if not re.fullmatch(r"[1-3]", t) or not re.fullmatch(r"\d{4}", y):
        raise HTTPException(status_code=400, detail="ภาคเรียน/ปีการศึกษาไม่ถูกต้อง (term=1-3, year=2569)")
    return t, y


# ---------------------------------------------------------------- data
def school_info() -> Dict[str, Any]:
    name = database.get_app_setting("school_name", "", db_path=DB)
    if not name:
        try:
            name = database.get_school_signatories(db_path=DB).get("school_name") or ""
        except Exception:
            name = ""
    raw = re.sub(r"^โรงเรียน\s*", "", name or "").strip() or school_profile.short_name(DB)
    theme = {k: database.get_app_setting(f"theme_{k}", d, db_path=DB)
             for k, d in (("primary_color", "#351C75"), ("secondary_color", "#D4AF37"), ("font_family", "Sarabun"))}
    return {"name": f"โรงเรียน{raw}", "theme": theme}


def dashboard_summary(term: str, year: str, month: Optional[str]) -> Dict[str, Any]:
    """The attendance dashboard as numbers only: no student rows (not even masked ones)."""
    d = database.get_attendance_dashboard(term=term, year=year, mode="daily", month=month, db_path=DB)
    s = d.get("summary") or {}
    levels = []
    for lv in d.get("levels") or []:
        levels.append({
            "class_level": lv.get("class_level"),
            "student_count": int(lv.get("student_count") or 0),
            "average_pct": lv.get("average_pct"),
        })
    return {
        "term": term, "year": year,
        "month": d.get("selected_month") or "all",
        "month_name": d.get("month_name") or "",
        "months": [{"key": m.get("key"), "name": m.get("name")} for m in d.get("available_months") or []],
        "summary": {
            "total_students": int(s.get("total_students") or 0),
            "average_attendance_pct": s.get("average_attendance_pct"),
            "at_risk_count": int(s.get("at_risk_count") or 0),       # มาเรียนต่ำกว่า 60%
            "warning_count": int(s.get("warning_count") or 0),       # ต่ำกว่า 80% หรือเคยขาดเรียน
        },
        "levels": levels,
        "criterion_pct": 80,
        "updated_at": time.strftime("%Y-%m-%d %H:%M"),
    }


def teacher_timetables(term: str, year: str) -> Dict[str, Any]:
    from timetable_manager import get_timetables, get_teachers_with_timetables, PERIOD_CONFIGS
    slots = []
    for r in get_timetables(term=term, year=year, db_path=DB):
        slots.append({
            "teacher": (r.get("teacher_name") or "").strip(),
            "day": r.get("day_of_week"),
            "period": r.get("period_num"),
            "span": r.get("period_span") or 1,
            "course_code": r.get("course_code") or "",
            "course_name": r.get("course_name") or "",
            "class_level": r.get("class_level") or "",
            "room": r.get("room") or "",
        })
    return {
        "term": term, "year": year,
        "teachers": get_teachers_with_timetables(term=term, year=year, db_path=DB),
        "days": [{"day": d, "name": DAY_NAMES[d]} for d in range(1, 6)],
        "periods": [{"period": p["period"], "name": p["name"], "time": p["label"], "break": bool(p.get("is_break"))}
                    for p in PERIOD_CONFIGS],
        "slots": slots,
        "updated_at": time.strftime("%Y-%m-%d %H:%M"),
    }


# ---------------------------------------------------------------- routes
def make_router(current_semester: Callable[[], Tuple[str, str]]) -> APIRouter:
    r = APIRouter()

    @r.get("/api/public/v1")
    def public_index(request: Request):
        """What this API offers (for whoever builds the other website)."""
        _limit(request)
        st = settings()
        return {
            "status": "success",
            "note": "ข้อมูลสาธารณะ อ่านอย่างเดียว ไม่ต้องล็อกอิน • ผ่านลิงก์ ngrok ต้องส่ง header 'ngrok-skip-browser-warning: 1' "
                    "• พักผลไว้ 60 วินาที • จำกัด 60 ครั้ง/นาที/เครื่อง",
            "endpoints": {
                "/api/public/v1/info": "ชื่อโรงเรียน สีประจำโรงเรียน ภาคเรียนปัจจุบัน ชุดข้อมูลที่เปิดอยู่",
                "/api/public/v1/dashboard?term=2&year=2569&month=2026-11": "สรุปการมาเรียน (ไม่ใส่ term/year = ภาคเรียนปัจจุบัน, month ไม่ใส่ = ทั้งภาคเรียน)",
                "/api/public/v1/timetables?term=2&year=2569&teacher=ชื่อครู": "ตารางสอนครู (ไม่ใส่ teacher = ทุกคน)",
            },
            "enabled": {k: st[k] for k in DATASETS},
        }

    @r.get("/api/public/v1/info")
    def public_info(request: Request):
        _limit(request)
        t, y = current_semester()
        st = settings()
        return {"status": "success", "school": _cached(("school",), school_info),
                "term": t, "year": y, "title": f"ภาคเรียนที่ {t}/{y}", "enabled": {k: st[k] for k in DATASETS}}

    @r.get("/api/public/v1/dashboard")
    def public_dashboard(request: Request, term: Optional[str] = Query(None), year: Optional[str] = Query(None),
                         month: Optional[str] = Query(None)):
        _limit(request)
        _open("dashboard")
        t, y = _semester(term, year, current_semester)
        m = (month or "").strip() or None
        if m and m != "all" and not re.fullmatch(r"\d{4}-\d{2}", m):
            raise HTTPException(status_code=400, detail="month ต้องเป็น YYYY-MM (ปี ค.ศ.)")
        data = _cached(("dashboard", t, y, m), lambda: dashboard_summary(t, y, None if m == "all" else m))
        return {"status": "success", "data": data}

    @r.get("/api/public/v1/timetables")
    def public_timetables(request: Request, term: Optional[str] = Query(None), year: Optional[str] = Query(None),
                          teacher: Optional[str] = Query(None)):
        _limit(request)
        _open("timetable")
        t, y = _semester(term, year, current_semester)
        data = dict(_cached(("timetable", t, y), lambda: teacher_timetables(t, y)))
        who = (teacher or "").strip()
        if who:
            key = auth._base_name(who)
            data["slots"] = [s for s in data["slots"] if auth._base_name(s["teacher"]) == key]
        return {"status": "success", "data": data}

    @r.get("/api/public/v1/preview", response_class=HTMLResponse)
    def public_preview(request: Request, view: str = Query("dashboard")):
        """The paste-in code on a page of its own (to see what the other website will show)."""
        _limit(request)
        if view not in ("dashboard", "timetable"):
            view = "dashboard"
        title = "ตัวอย่าง: แดชบอร์ดการมาเรียน" if view == "dashboard" else "ตัวอย่าง: ตารางสอนครู"
        page = ("<!doctype html><html lang='th'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
                f"<title>{title}</title></head><body style='margin:0;padding:16px;background:#f3f4f6'>"
                f"{embed_snippet(view, '')}</body></html>")
        return HTMLResponse(page, headers={"Cache-Control": "no-cache"})

    return r


# ---------------------------------------------------------------- the paste-in code
_SNIPPET = r"""<!-- __TITLE__ — จากระบบงาน ปพ.5 (วางในช่อง "ฝังโค้ด / Embed code" ของเว็บโรงเรียน หรือ Google Sites) -->
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Sarabun:wght@400;600;700&display=swap">
<div class="pp5w" data-view="__VIEW__" data-base="__BASE__" data-teacher="" id="__ID__"><div class="pp5w-msg">กำลังโหลด…</div></div>
<script>
(function () {
  var root = document.getElementById("__ID__");
  if (!root) return;
  var BASE = root.getAttribute("data-base") || "", VIEW = root.getAttribute("data-view");
  var H = { "ngrok-skip-browser-warning": "1" };
  function get(path) {
    return fetch(BASE + path, { headers: H }).then(function (r) {
      return r.json().then(function (b) { if (!r.ok) throw new Error(b.detail || ("HTTP " + r.status)); return b; });
    });
  }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function pct(v) { return v == null ? "–" : (Math.round(v * 10) / 10).toFixed(1) + "%"; }
  if (!document.getElementById("pp5w-style")) {
    var st = document.createElement("style"); st.id = "pp5w-style";
    st.textContent = [
      ".pp5w{--pp5-ink:#1f2937;--pp5-muted:#6b7280;--pp5-line:#e5e7eb;--pp5-card:#ffffff;--pp5-soft:#f6f5fb;--pp5-main:#351C75;--pp5-bad:#b42318;",
      "font-family:Sarabun,'Noto Sans Thai',Tahoma,sans-serif;color:var(--pp5-ink);background:var(--pp5-card);border:1px solid var(--pp5-line);",
      "border-radius:14px;padding:16px;box-sizing:border-box;max-width:100%;line-height:1.45}",
      ".pp5w *{box-sizing:border-box}",
      ".pp5w-head{display:flex;flex-wrap:wrap;gap:8px 12px;align-items:center;justify-content:space-between;margin-bottom:12px}",
      ".pp5w-title{font-size:18px;font-weight:700;margin:0}.pp5w-sub{font-size:13px;color:var(--pp5-muted)}",
      ".pp5w select{font:inherit;font-size:14px;padding:6px 10px;border:1px solid var(--pp5-line);border-radius:8px;background:#fff;color:var(--pp5-ink);max-width:100%}",
      ".pp5w-tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:14px}",
      ".pp5w-tile{background:var(--pp5-soft);border-radius:12px;padding:10px 12px}.pp5w-tile b{display:block;font-size:24px;color:var(--pp5-main)}",
      ".pp5w-tile span{font-size:13px;color:var(--pp5-muted)}",
      ".pp5w-bars{display:grid;gap:8px}.pp5w-bar{display:grid;grid-template-columns:84px 1fr 78px;gap:8px;align-items:center;font-size:14px}",
      ".pp5w-track{position:relative;height:14px;background:var(--pp5-soft);border-radius:4px}",
      ".pp5w-fill{position:absolute;left:0;top:0;bottom:0;background:var(--pp5-main);border-radius:0 4px 4px 0}",
      ".pp5w-fill.low{background:var(--pp5-bad)}.pp5w-crit{position:absolute;top:-3px;bottom:-3px;width:0;border-left:2px dashed #9ca3af}",
      ".pp5w-val{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}.pp5w-val.low{color:var(--pp5-bad);font-weight:700}",
      ".pp5w-day{margin:12px 0 6px;font-weight:700;font-size:15px}",
      ".pp5w-item{display:grid;grid-template-columns:74px 1fr;gap:8px;padding:8px 10px;border:1px solid var(--pp5-line);border-radius:10px;margin-bottom:6px;font-size:14px}",
      ".pp5w-item small{display:block;color:var(--pp5-muted);font-size:12px}.pp5w-item b{color:var(--pp5-main)}",
      ".pp5w-foot{margin-top:12px;font-size:12px;color:var(--pp5-muted)}",
      ".pp5w-scroll{overflow-x:auto;-webkit-overflow-scrolling:touch}",
      ".pp5w table{border-collapse:collapse;width:100%;min-width:860px;font-size:13px}",
      ".pp5w th,.pp5w td{border:1px solid var(--pp5-line);padding:6px;text-align:center;vertical-align:middle}",
      ".pp5w th{background:var(--pp5-soft);font-weight:600}.pp5w th small{display:block;font-weight:400;color:var(--pp5-muted)}",
      ".pp5w td.day{font-weight:700;background:var(--pp5-soft);white-space:nowrap}.pp5w td.brk,.pp5w th.brk{background:#fafafa;color:var(--pp5-muted);width:34px;font-size:12px}",
      ".pp5w td.slot{background:#fff}.pp5w td.slot b{display:block;color:var(--pp5-main)}.pp5w td.slot span{display:block;color:var(--pp5-muted);font-size:12px}",
      ".pp5w-msg{color:var(--pp5-muted);font-size:14px;padding:8px 0}"
    ].join("");
    document.head.appendChild(st);
  }
  function theme(info) {
    var t = (info && info.school && info.school.theme) || {};
    if (t.primary_color) root.style.setProperty("--pp5-main", t.primary_color);
  }
  function fail(e) { root.innerHTML = ""; root.appendChild(el("div", "pp5w-msg", "โหลดข้อมูลไม่ได้: " + e.message)); }

  // ---------------- dashboard
  function dashboard(info, first) {
    var month = "", term = first.term, year = first.year;
    function load() {
      var q = "/api/public/v1/dashboard?term=" + term + "&year=" + year + (month ? "&month=" + month : "");
      get(q).then(function (b) { draw(b.data); }).catch(fail);
    }
    function draw(d) {
      root.innerHTML = "";
      var head = el("div", "pp5w-head"), left = el("div");
      left.appendChild(el("h3", "pp5w-title", "สรุปการมาเรียน " + info.school.name));
      left.appendChild(el("div", "pp5w-sub", "ภาคเรียนที่ " + d.term + "/" + d.year + " • " + (d.month_name || "ทั้งภาคเรียน")));
      head.appendChild(left);
      var sel = el("select"); sel.setAttribute("aria-label", "เลือกเดือน");
      var all = el("option", null, "ทั้งภาคเรียน"); all.value = ""; sel.appendChild(all);
      (d.months || []).forEach(function (m) { var o = el("option", null, m.name); o.value = m.key; if (m.key === month) o.selected = true; sel.appendChild(o); });
      sel.onchange = function () { month = sel.value; load(); };
      head.appendChild(sel);
      root.appendChild(head);
      var s = d.summary, tiles = el("div", "pp5w-tiles");
      [["นักเรียนทั้งหมด", s.total_students + " คน"], ["อัตราการมาเรียนเฉลี่ย", pct(s.average_attendance_pct)],
       ["กลุ่มเสี่ยงขาดเรียนสูง", s.at_risk_count + " คน"], ["กลุ่มเฝ้าระวัง", s.warning_count + " คน"]].forEach(function (t) {
        var c = el("div", "pp5w-tile"); c.appendChild(el("b", null, t[1])); c.appendChild(el("span", null, t[0])); tiles.appendChild(c);
      });
      root.appendChild(tiles);
      root.appendChild(el("div", "pp5w-sub", "อัตราการมาเรียนรายชั้น (เส้นประ = เกณฑ์ " + d.criterion_pct + "%)"));
      var bars = el("div", "pp5w-bars"); bars.style.marginTop = "8px";
      (d.levels || []).forEach(function (lv) {
        var low = lv.average_pct != null && lv.average_pct < d.criterion_pct;
        var row = el("div", "pp5w-bar"); row.title = lv.class_level + ": มาเรียน " + pct(lv.average_pct) + " (" + lv.student_count + " คน)";
        row.appendChild(el("div", null, lv.class_level + " (" + lv.student_count + ")"));
        var tr = el("div", "pp5w-track"), f = el("div", "pp5w-fill" + (low ? " low" : ""));
        f.style.width = Math.max(0, Math.min(100, lv.average_pct || 0)) + "%";
        var c = el("div", "pp5w-crit"); c.style.left = d.criterion_pct + "%";
        tr.appendChild(f); tr.appendChild(c); row.appendChild(tr);
        row.appendChild(el("div", "pp5w-val" + (low ? " low" : ""), (low ? "⚠ " : "") + pct(lv.average_pct)));
        bars.appendChild(row);
      });
      root.appendChild(bars);
      root.appendChild(el("div", "pp5w-foot", "ข้อมูล ณ " + d.updated_at + " • เสี่ยงขาดเรียนสูง = มาเรียนต่ำกว่า 60% • เฝ้าระวัง = ต่ำกว่า 80% หรือเคยขาดเรียน"));
    }
    draw(first);
  }

  // ---------------- teacher timetable
  function timetable(info, d) {
    var fixed = (root.getAttribute("data-teacher") || "").trim();
    (function () {
      var who = fixed || (d.teachers[0] || "");
      function draw() {
        root.innerHTML = "";
        var head = el("div", "pp5w-head"), left = el("div");
        left.appendChild(el("h3", "pp5w-title", "ตารางสอน " + (who || "")));
        left.appendChild(el("div", "pp5w-sub", info.school.name + " • ภาคเรียนที่ " + d.term + "/" + d.year));
        head.appendChild(left);
        if (!fixed) {
          var sel = el("select"); sel.setAttribute("aria-label", "เลือกครู");
          d.teachers.forEach(function (t) { var o = el("option", null, t); o.value = t; if (t === who) o.selected = true; sel.appendChild(o); });
          sel.onchange = function () { who = sel.value; draw(); };
          head.appendChild(sel);
        }
        root.appendChild(head);
        var mine = d.slots.filter(function (s) { return s.teacher === who; });
        if (!mine.length) { root.appendChild(el("div", "pp5w-msg", "ยังไม่มีตารางสอน")); return; }
        narrow = root.clientWidth < 640;
        if (narrow) {                       // a phone / a narrow column: a list by day instead of the grid
          var times = {};
          d.periods.forEach(function (p) { times[p.period] = p; });
          d.days.forEach(function (day) {
            var items = mine.filter(function (x) { return x.day === day.day; }).sort(function (a, b) { return a.period - b.period; });
            if (!items.length) return;
            root.appendChild(el("div", "pp5w-day", day.name));
            items.forEach(function (s) {
              var it = el("div", "pp5w-item"), p = times[s.period] || {}, left = el("div"), right = el("div");
              left.appendChild(el("b", null, p.name || ("คาบ " + s.period)));
              left.appendChild(el("small", null, p.time || ""));
              right.appendChild(el("b", null, s.course_code));
              if (s.course_name) right.appendChild(el("small", null, s.course_name));
              var where = [s.class_level, s.room].filter(Boolean).join(" • ");
              if (where) right.appendChild(el("small", null, where));
              it.appendChild(left); it.appendChild(right); root.appendChild(it);
            });
          });
          root.appendChild(el("div", "pp5w-foot", "ข้อมูล ณ " + d.updated_at));
          return;
        }
        var wrap = el("div", "pp5w-scroll"), tb = el("table"), tr = el("tr");
        tr.appendChild(el("th", null, "วัน"));
        d.periods.forEach(function (p) {
          var th = el("th", p.break ? "brk" : null, p.break ? "พัก" : p.name);
          if (!p.break) th.appendChild(el("small", null, p.time));
          tr.appendChild(th);
        });
        tb.appendChild(tr);
        d.days.forEach(function (day) {
          var row = el("tr"); row.appendChild(el("td", "day", day.name));
          var skip = 0;
          d.periods.forEach(function (p, i) {
            if (skip > 0) { skip--; return; }
            if (p.break) { row.appendChild(el("td", "brk", "")); return; }
            var s = mine.filter(function (x) { return x.day === day.day && x.period === p.period; })[0];
            var td = el("td", s ? "slot" : null);
            if (s) {
              td.appendChild(el("b", null, s.course_code));
              if (s.course_name) td.appendChild(el("span", null, s.course_name));
              var where = [s.class_level, s.room].filter(Boolean).join(" • ");
              if (where) td.appendChild(el("span", null, where));
              var span = Math.max(1, s.span || 1), n = 1;
              for (var j = i + 1; j < d.periods.length && n < span; j++) { if (!d.periods[j].break) { n++; skip++; } else break; }
              if (n > 1) td.colSpan = n;
            }
            row.appendChild(td);
          });
          tb.appendChild(row);
        });
        wrap.appendChild(tb); root.appendChild(wrap);
        root.appendChild(el("div", "pp5w-foot", "ข้อมูล ณ " + d.updated_at));
      }
      var narrow = null, timer = null;
      draw();
      window.addEventListener("resize", function () {       // grid <-> list when the box gets wider / narrower
        clearTimeout(timer);
        timer = setTimeout(function () { if (narrow !== null && (root.clientWidth < 640) !== narrow) draw(); }, 200);
      });
    })();
  }

  // both at once (each trip through the tunnel takes a while): the school + the data of the current semester
  Promise.all([get("/api/public/v1/info"), get(VIEW === "timetable" ? "/api/public/v1/timetables" : "/api/public/v1/dashboard")])
    .then(function (r) {
      theme(r[0]);
      if (VIEW === "timetable") timetable(r[0], r[1].data); else dashboard(r[0], r[1].data);
    }).catch(fail);
})();
</script>"""


def embed_snippet(view: str, base: str) -> str:
    view = view if view in ("dashboard", "timetable") else "dashboard"
    title = "แดชบอร์ดการมาเรียน" if view == "dashboard" else "ตารางสอนครู (ใส่ชื่อครูใน data-teacher เพื่อแสดงเฉพาะคนนั้น)"
    uid = f"pp5w-{view}-{int(time.time() * 1000) % 1000000}"
    return (_SNIPPET.replace("__TITLE__", title).replace("__VIEW__", view)
            .replace("__BASE__", base.rstrip("/")).replace("__ID__", uid))
