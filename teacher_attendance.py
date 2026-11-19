"""
ตารางลงเวลาครู (teacher attendance grid), asked for by the owner on 2026-11-18.

It uses the same calendar as the students' daily grid: the semester's 100 day-slots (20 weeks x Mon-Fri,
from database.get_semester_start_date), minus holidays. A day is a holiday for teachers only when every class
level has it as a holiday (daily_attendance_config.holidays_json). Activity days are ordinary school days.

From 06:00 on the server's clock, every teacher counts as มา (/) for the day unless something else is recorded:
  ล   ลากิจ / ลาป่วย   teacher_leaves (the existing leave form), may span several days
  ขส  ขอเข้าสาย          teacher_leaves (the existing leave form), one day
  ร   ไปราชการ           teacher_attendance_marks, no details
  ส   มาสาย              teacher_attendance_marks, no details, only for today or earlier
When a day has more than one record, the first match wins: ล, then ขส, then ร, then ส, then /.
Rejected or cancelled leave records are ignored. Nothing is stored for "/": it is worked out on every read,
so no job has to run at 06:00.

Summary (owner's choice): มา = every school day so far that is not ล, so ส, ขส and ร also count as มา (as a
late student still counts as present); each is also counted on its own.

Who sees what (owner's choice): admin, the personnel head and the director see every teacher (the director
only reads); any other teacher sees only their own row and asks for ขส / ล through the leave form. ส and ร
are entered by the personnel head or an admin. The director has no row.
"""
import json
import sqlite3
from datetime import date, datetime, time
from typing import Any, Dict, List, Optional

import database
import leave_manager

DB = "school_archive.db"
DAY_STARTS = time(6, 0)              # every teacher is "มา" from this time on a school day
MARKS = ("ส", "ร")
LEAVE_SYMBOL = {"ลากิจ": "ล", "ลาป่วย": "ล", "ขอเข้าสาย": "ขส"}
IGNORED_LEAVE_STATUS = ("rejected", "cancelled")

SCHEMA = """
CREATE TABLE IF NOT EXISTS teacher_attendance_marks (
    teacher_code TEXT NOT NULL,
    date TEXT NOT NULL,              -- YYYY-MM-DD
    status TEXT NOT NULL,            -- 'ส' มาสาย, 'ร' ไปราชการ
    updated_by TEXT,
    updated_at TEXT,
    PRIMARY KEY (teacher_code, date)
);
"""


def ensure(conn) -> None:
    """Both tables this page reads (the leave table may not exist yet on a new school). One statement at a
    time, because executescript would commit the caller's open transaction (school_data import)."""
    for stmt in (leave_manager.SCHEMA + SCHEMA).split(";"):
        stmt = " ".join(ln.split("--")[0] for ln in stmt.splitlines()).strip()
        if stmt:
            conn.execute(stmt)


def _connect(db_path: str):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def _now(now: Optional[datetime]) -> datetime:
    return now or datetime.now()


def semester_calendar(term: str, year: str, db_path: str = DB) -> Dict[str, Any]:
    """The 100 day-slots of the semester and which of them are holidays for every class level."""
    t, y = str(term).strip(), str(year).strip()
    start = database.get_semester_start_date(t, y, db_path=db_path)
    dates = database.compute_100_dates(start, t, y)
    with _connect(db_path) as conn:
        rows = conn.execute("SELECT holidays_json FROM daily_attendance_config WHERE term = ? AND year = ?;", (t, y)).fetchall()
    common = None
    for r in rows:
        try:
            got = {int(i) for i in json.loads(r["holidays_json"] or "[]")}
        except Exception:
            got = set()
        common = got if common is None else common & got
    holidays = sorted(i for i in (common or set()) if 0 <= i < len(dates))
    return {"term": t, "year": y, "start_date": start, "dates": dates, "holidays": holidays}


def teacher_rows(db_path: str = DB) -> List[Dict[str, str]]:
    """Teachers on the grid: every teacher with a code, except the director."""
    with _connect(db_path) as conn:
        rows = conn.execute("SELECT code, name FROM school_teachers WHERE code IS NOT NULL AND TRIM(code) != '' ORDER BY id;").fetchall()
    out = []
    for r in rows:
        code, name = str(r["code"]).strip(), str(r["name"] or "").strip()
        if database.is_school_director(code, name, db_path):
            continue
        out.append({"code": code, "name": name})
    return out


def _counts_today(d: str, now: datetime) -> bool:
    """A day is counted once it has started: earlier days, or today from 06:00."""
    today = now.date().isoformat()
    return d < today or (d == today and now.time() >= DAY_STARTS)


def build_grid(term: str, year: str, only_code: Optional[str] = None, now: Optional[datetime] = None,
               db_path: str = DB) -> Dict[str, Any]:
    """Status of every teacher on every day-slot, plus each teacher's summary up to now.
    only_code: a teacher who may see only their own row."""
    now = _now(now)
    cal = semester_calendar(term, year, db_path)
    dates, holidays = cal["dates"], set(cal["holidays"])
    first, last = dates[0], dates[-1]
    teachers = teacher_rows(db_path)
    if only_code is not None:
        teachers = [t for t in teachers if t["code"] == str(only_code).strip()]
    codes = {t["code"] for t in teachers}

    with _connect(db_path) as conn:
        ensure(conn)
        leaves = conn.execute(
            "SELECT * FROM teacher_leaves WHERE COALESCE(status, 'pending') NOT IN (?, ?) "
            "AND start_date <= ? AND COALESCE(NULLIF(end_date, ''), start_date) >= ? ORDER BY start_date, id;",
            (*IGNORED_LEAVE_STATUS, last, first)).fetchall()
        marks = conn.execute("SELECT teacher_code, date, status FROM teacher_attendance_marks WHERE date BETWEEN ? AND ?;",
                             (first, last)).fetchall()

    slot_of = {d: i for i, d in enumerate(dates)}
    # leave records per teacher per slot: ล beats ขส when both cover the same day
    leave_at: Dict[str, Dict[int, Dict[str, Any]]] = {}
    for r in leaves:
        code = str(r["teacher_code"]).strip()
        sym = LEAVE_SYMBOL.get(str(r["leave_type"]).strip())
        if code not in codes or not sym:
            continue
        start = str(r["start_date"]).strip()[:10]
        end = (str(r["end_date"] or "").strip()[:10] or start) if sym == "ล" else start
        for d in dates:
            if start <= d <= end:
                i = slot_of[d]
                have = leave_at.setdefault(code, {}).get(i)
                if have and have["symbol"] == "ล":
                    continue
                leave_at[code][i] = {"symbol": sym, "leave_id": r["id"], "leave_type": r["leave_type"],
                                     "approval": r["status"] or "pending", "time": r["expected_arrival_time"] or "",
                                     "start_date": start, "end_date": end}
    mark_at: Dict[str, Dict[int, str]] = {}
    for r in marks:
        code, d = str(r["teacher_code"]).strip(), str(r["date"])
        if code in codes and d in slot_of and r["status"] in MARKS:
            mark_at.setdefault(code, {})[slot_of[d]] = r["status"]

    counted = [i not in holidays and _counts_today(d, now) for i, d in enumerate(dates)]
    elapsed = sum(counted)
    weeks, months = _periods(dates, holidays, counted)
    out_rows = []
    for t in teachers:
        code = t["code"]
        status, info = [], []
        for i, d in enumerate(dates):
            if i in holidays:
                status.append("")
                info.append(None)
                continue
            lv = leave_at.get(code, {}).get(i)
            mk = mark_at.get(code, {}).get(i)
            if lv:
                s = lv["symbol"]
            elif mk == "ร":
                s = "ร"
            elif mk == "ส" and counted[i]:
                s = "ส"
            else:
                s = "/" if counted[i] else ""
            status.append(s)
            info.append({k: v for k, v in lv.items() if k != "symbol"} if lv else None)
        out_rows.append({
            "teacher_code": code, "teacher_name": t["name"], "status_list": status, "info": info,
            "summary": _summary(status, info, counted, 0, len(dates) - 1),
            "weekly": [_summary(status, info, counted, w["first_slot"], w["last_slot"]) for w in weeks],
            "monthly": [_summary(status, info, counted, m["first_slot"], m["last_slot"]) for m in months],
        })
    today = now.date().isoformat()
    return {**cal, "today": today, "today_slot": slot_of.get(today), "day_started": now.time() >= DAY_STARTS,
            "day_starts": DAY_STARTS.strftime("%H:%M"), "school_days": elapsed, "teachers": out_rows,
            "weeks": weeks, "months": months}


def _summary(status: List[str], info: List[Any], counted: List[bool], first: int, last: int) -> Dict[str, int]:
    """Counts for the day-slots first..last (inclusive), only days that have started.
    มา = school days so far that are not ล (ส, ขส and ร count as มา too)."""
    n = {"/": 0, "ส": 0, "ขส": 0, "ล": 0, "ร": 0}
    days = kij = puay = 0
    for i in range(first, last + 1):
        if not counted[i]:
            continue
        days += 1
        s = status[i]
        if s in n:
            n[s] += 1
        if s == "ล" and isinstance(info[i], dict):
            kij += info[i].get("leave_type") == "ลากิจ"
            puay += info[i].get("leave_type") == "ลาป่วย"
    return {"school_days": days, "present": days - n["ล"], "on_time": n["/"], "late": n["ส"],
            "late_request": n["ขส"], "leave": n["ล"], "leave_kij": kij, "leave_puay": puay, "official": n["ร"]}


def _periods(dates: List[str], holidays, counted: List[bool]):
    """Weeks (5 slots each) and calendar months of the semester, as slot ranges, with how many school days each
    has and how many have started. A month not reached yet has elapsed 0 (shown as ยังไม่ถึง, never 100%)."""
    def info(first: int, last: int) -> Dict[str, Any]:
        rng = range(first, last + 1)
        return {"first_slot": first, "last_slot": last, "start": dates[first], "end": dates[last],
                "school_days": sum(1 for i in rng if i not in holidays), "elapsed": sum(1 for i in rng if counted[i])}

    weeks = [{"index": w, **info(w * 5, min(w * 5 + 4, len(dates) - 1))} for w in range((len(dates) + 4) // 5)]
    months: List[Dict[str, Any]] = []
    for i, d in enumerate(dates):
        key = d[:7]
        if months and months[-1]["key"] == key:
            months[-1]["last"] = i
        else:
            months.append({"key": key, "first": i, "last": i})
    months = [{"key": m["key"], "year": int(m["key"][:4]), "month": int(m["key"][5:7]), **info(m["first"], m["last"])}
              for m in months]
    return weeks, months


def set_mark(term: str, year: str, teacher_code: str, day: str, status: str, by: str,
             now: Optional[datetime] = None, db_path: str = DB) -> Dict[str, Any]:
    """Set ส (late) or ร (official duty) on one school day; status "" or "/" puts the day back to มา.
    Raises ValueError with a Thai message the page can show."""
    now = _now(now)
    code = str(teacher_code or "").strip()
    st = str(status or "").strip()
    st = "" if st == "/" else st
    if st and st not in MARKS:
        raise ValueError("สถานะต้องเป็น ส (มาสาย) หรือ ร (ไปราชการ)")
    try:
        d = date.fromisoformat(str(day).strip()[:10]).isoformat()
    except ValueError:
        raise ValueError("วันที่ไม่ถูกต้อง")
    if date.fromisoformat(d).weekday() >= 5:
        raise ValueError("วันเสาร์-อาทิตย์ไม่ใช่วันเรียน")
    cal = semester_calendar(term, year, db_path)
    if d not in cal["dates"]:
        raise ValueError("วันนี้ไม่อยู่ในภาคเรียนที่เลือก")
    if cal["dates"].index(d) in set(cal["holidays"]):
        raise ValueError("วันนี้เป็นวันหยุด")
    if not any(t["code"] == code for t in teacher_rows(db_path)):
        raise ValueError("ไม่พบครูรหัสนี้ในตารางลงเวลา")
    if st == "ส" and d > now.date().isoformat():
        raise ValueError("ยังไม่ถึงวันนี้ ลง ส (มาสาย) ล่วงหน้าไม่ได้")
    with _connect(db_path) as conn:
        ensure(conn)
        if st:
            lv = conn.execute(
                "SELECT leave_type FROM teacher_leaves WHERE teacher_code = ? AND COALESCE(status, 'pending') NOT IN (?, ?) "
                "AND start_date <= ? AND (CASE WHEN leave_type = 'ขอเข้าสาย' THEN start_date "
                "ELSE COALESCE(NULLIF(end_date, ''), start_date) END) >= ? LIMIT 1;",
                (code, *IGNORED_LEAVE_STATUS, d, d)).fetchone()
            if lv:
                raise ValueError(f"วันนี้มีรายการ{lv['leave_type']}อยู่แล้ว แก้ไขหรือลบรายการนั้นก่อน")
            conn.execute(
                "INSERT INTO teacher_attendance_marks (teacher_code, date, status, updated_by, updated_at) VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT(teacher_code, date) DO UPDATE SET status = excluded.status, updated_by = excluded.updated_by, "
                "updated_at = excluded.updated_at;",
                (code, d, st, by, now.strftime("%Y-%m-%d %H:%M:%S")))
        else:
            conn.execute("DELETE FROM teacher_attendance_marks WHERE teacher_code = ? AND date = ?;", (code, d))
        conn.commit()
    return {"teacher_code": code, "date": d, "status": st or "/"}


def marks_between(teacher_code: str, start: str, end: Optional[str], db_path: str = DB) -> List[Dict[str, str]]:
    """ส / ร already entered for this teacher between two dates (inclusive)."""
    s = str(start or "").strip()[:10]
    e = str(end or "").strip()[:10] or s
    with _connect(db_path) as conn:
        ensure(conn)
        rows = conn.execute("SELECT date, status FROM teacher_attendance_marks WHERE teacher_code = ? AND date BETWEEN ? AND ? "
                            "ORDER BY date;", (str(teacher_code).strip(), s, e)).fetchall()
    return [{"date": r["date"], "status": r["status"]} for r in rows]


def clear_marks(teacher_code: str, start: str, end: Optional[str], db_path: str = DB) -> int:
    """A leave entered by the personnel head / an admin replaces any ส / ร on its days."""
    s = str(start or "").strip()[:10]
    e = str(end or "").strip()[:10] or s
    with _connect(db_path) as conn:
        ensure(conn)
        cur = conn.execute("DELETE FROM teacher_attendance_marks WHERE teacher_code = ? AND date BETWEEN ? AND ?;",
                           (str(teacher_code).strip(), s, e))
        conn.commit()
        return cur.rowcount


# ---------------------------------------------------------------------------------------------------------------
# พิมพ์สรุปตามช่วง (สัปดาห์ / เดือน / ทั้งภาคเรียน) — the owner asked for weekly and monthly summaries on 2026-11-18

THAI_MONTHS = ["", "มกราคม", "กุมภาพันธ์", "มีนาคม", "เมษายน", "พฤษภาคม", "มิถุนายน", "กรกฎาคม", "สิงหาคม",
               "กันยายน", "ตุลาคม", "พฤศจิกายน", "ธันวาคม"]
THAI_MONTHS_SHORT = ["", "ม.ค.", "ก.พ.", "มี.ค.", "เม.ย.", "พ.ค.", "มิ.ย.", "ก.ค.", "ส.ค.", "ก.ย.", "ต.ค.", "พ.ย.", "ธ.ค."]
DAY_SHORT = ["จ", "อ", "พ", "พฤ", "ศ", "ส", "อา"]
PERIODS = ("week", "month", "term")


def _thai_date(iso: str, short: bool = False) -> str:
    d = date.fromisoformat(iso)
    if short:
        return f"{d.day} {THAI_MONTHS_SHORT[d.month]} {(d.year + 543) % 100:02d}"
    return f"{d.day} {THAI_MONTHS[d.month]} พ.ศ. {d.year + 543}"


def period_slice(grid: Dict[str, Any], period: str, index: Optional[int]) -> Dict[str, Any]:
    """The period being shown: title, slot range, and which per-teacher summary belongs to it
    (summary / weekly[index] / monthly[index]). index None = the period that holds today, else the first."""
    if period not in PERIODS:
        raise ValueError("ช่วงต้องเป็น week, month หรือ term")
    dates = grid["dates"]
    if period == "term":
        return {"period": "term", "index": 0, "first_slot": 0, "last_slot": len(dates) - 1, "key": "summary",
                "elapsed": grid["school_days"], "title": "ทั้งภาคเรียน",
                "range": f"{_thai_date(dates[0], True)} – {_thai_date(dates[-1], True)}"}
    items = grid["weeks"] if period == "week" else grid["months"]
    if index is None:
        today = grid.get("today_slot")
        index = next((k for k, p in enumerate(items)
                      if today is not None and p["first_slot"] <= today <= p["last_slot"]), 0)
    if not 0 <= index < len(items):
        raise ValueError("ไม่มีช่วงนี้ในภาคเรียน")
    p = items[index]
    title = f"สัปดาห์ที่ {index + 1}" if period == "week" else f"เดือน{THAI_MONTHS[p['month']]} {p['year'] + 543}"
    return {"period": period, "index": index, "first_slot": p["first_slot"], "last_slot": p["last_slot"],
            "key": "weekly" if period == "week" else "monthly", "elapsed": p["elapsed"], "title": title,
            "range": f"{_thai_date(p['start'], True)} – {_thai_date(p['end'], True)}"}


def period_report_html(grid: Dict[str, Any], period: str, index: Optional[int], school_name: str,
                       director_name: str, head_name: str, now: Optional[datetime] = None) -> str:
    """A4 landscape page: one row per teacher, the days (week / month) or the months (term), then the totals."""
    from html import escape as esc
    now = _now(now)
    sl = period_slice(grid, period, index)
    first, last = sl["first_slot"], sl["last_slot"]
    dates, holidays = grid["dates"], set(grid["holidays"])
    rows = grid["teachers"]

    def summ(r: Dict[str, Any]) -> Dict[str, int]:
        return r["summary"] if sl["key"] == "summary" else r[sl["key"]][sl["index"]]

    months = grid["months"] if period == "term" else []
    if period == "term":
        head_cols = "".join(f"<th>{THAI_MONTHS_SHORT[m['month']]} {(m['year'] + 543) % 100:02d}</th>" for m in months)
    else:
        head_cols = ""
        for i in range(first, last + 1):
            d = date.fromisoformat(dates[i])
            cls = ' class="off"' if i in holidays else ""
            head_cols += f"<th{cls}>{DAY_SHORT[d.weekday()]}<br>{d.day}</th>"

    def n(v: int) -> str:
        return str(v) if v else "–"

    body = ""
    tot = {"school_days": 0, "present": 0, "late": 0, "late_request": 0, "leave": 0, "official": 0}
    who = {k: 0 for k in ("late", "late_request", "leave", "official")}
    for no, r in enumerate(rows, 1):
        s = summ(r)
        for k in tot:
            tot[k] += s[k]
        for k in who:
            who[k] += 1 if s[k] > 0 else 0
        cells = ""
        if period == "term":
            for k, m in enumerate(months):
                ms = r["monthly"][k]
                if m["elapsed"] == 0:
                    cells += '<td class="muted">ยังไม่ถึง</td>'
                    continue
                parts = [f"{sym}{ms[key]}" for sym, key in
                         (("ส", "late"), ("ขส", "late_request"), ("ล", "leave"), ("ร", "official")) if ms[key]]
                cells += f"<td>{' '.join(parts) if parts else '✓'}</td>"
        else:
            for i in range(first, last + 1):
                st = r["status_list"][i]
                if i in holidays:
                    cells += '<td class="off"></td>'
                else:
                    cells += f'<td class="{"sx" if st not in ("", "/") else "s"}">{esc(st)}</td>'
        present = f"{s['present']}/{s['school_days']}" if s["school_days"] else "–"
        leave = n(s["leave"]) + (f" <small>(กิจ {s['leave_kij']} ป่วย {s['leave_puay']})</small>" if s["leave"] else "")
        body += (f'<tr><td>{no}</td><td class="name">{esc(r["teacher_name"])}</td>{cells}'
                 f'<td class="t">{present}</td><td class="t">{n(s["late"])}</td><td class="t">{n(s["late_request"])}</td>'
                 f'<td class="t">{leave}</td><td class="t">{n(s["official"])}</td></tr>')
    if not rows:
        body = '<tr><td colspan="40" class="muted">ไม่มีรายชื่อครู</td></tr>'

    if tot["school_days"]:
        rate = f"{tot['present'] * 100 / tot['school_days']:.1f}%"
        overview = (f"มาปฏิบัติงาน <b>{rate}</b> ({tot['present']} จาก {tot['school_days']} วัน-คน) • "
                    f"มาสาย {tot['late']} ครั้ง ({who['late']} คน) • "
                    f"ขอเข้าสาย {tot['late_request']} ครั้ง ({who['late_request']} คน) • "
                    f"ลา {tot['leave']} วัน ({who['leave']} คน) • ไปราชการ {tot['official']} วัน ({who['official']} คน)")
    else:
        overview = "ช่วงนี้ยังไม่ถึง จึงยังไม่มีข้อมูลการมาปฏิบัติงาน"
    counted = [i for i in range(first, last + 1) if i not in holidays and _counts_today(dates[i], now)]
    school = [i for i in range(first, last + 1) if i not in holidays]
    upto = f" (นับถึง {_thai_date(dates[counted[-1]], True)})" if counted and len(counted) < len(school) else ""
    narrow = period == "month"
    # equal day / month columns: fixed layout, the first two and the totals get a set width
    mid = (len(months) if period == "term" else (last - first + 1))
    colgroup = ('<colgroup><col style="width: 30px"><col style="width: 200px">' + '<col>' * mid
                + '<col style="width: 58px"><col style="width: 58px"><col style="width: 70px"><col style="width: 96px">'
                  '<col style="width: 66px"></colgroup>')
    if school_name and not school_name.startswith("โรงเรียน"):
        school_name = "โรงเรียน" + school_name
    pad, fsize = ("3px 2px", "9pt") if narrow else ("5px 6px", "10pt")
    tick_note = " • ✓ = มาตรงเวลาทุกวันในเดือนนั้น" if period == "term" else ""
    head_line = esc(head_name) if head_name else "." * 40
    return f"""<!DOCTYPE html>
<html lang="th"><head><meta charset="utf-8">
<title>สรุปการมาปฏิบัติงานของครู {esc(sl['title'])} - {esc(school_name)}</title>
<style>
  @page {{ size: A4 landscape; margin: 10mm 12mm; }}
  body {{ font-family: 'Sarabun', 'TH Sarabun New', Tahoma, sans-serif; font-size: 11pt; color: #1e293b; margin: 0; padding: 16px; }}
  .header {{ text-align: center; border-bottom: 2px solid #0f172a; padding-bottom: 8px; margin-bottom: 10px; }}
  .school {{ font-size: 15pt; font-weight: bold; }}
  .sub {{ font-size: 12.5pt; font-weight: bold; color: #334155; }}
  .meta {{ font-size: 10pt; color: #64748b; }}
  .overview {{ font-size: 10.5pt; margin: 6px 0 10px; }}
  table {{ width: 100%; border-collapse: collapse; table-layout: fixed; }}
  th, td {{ border: 1px solid #94a3b8; padding: {pad}; font-size: {fsize}; text-align: center; }}
  th {{ background: #f1f5f9; }}
  td.name {{ text-align: left; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
  td.t {{ font-weight: bold; background: #f8fafc; }}
  td.sx {{ font-weight: bold; background: #fff7ed; }}
  .off {{ background: #e2e8f0; }}
  .muted {{ color: #94a3b8; }}
  small {{ font-weight: normal; color: #475569; }}
  .legend {{ font-size: 9.5pt; color: #475569; margin-top: 6px; }}
  .signatures {{ margin-top: 26px; display: flex; justify-content: space-between; page-break-inside: avoid; }}
  .sig {{ text-align: center; width: 42%; }}
  .line {{ margin: 38px auto 0; border-bottom: 1px dotted #475569; width: 85%; }}
  .no-print {{ text-align: right; margin-bottom: 10px; }}
  .btn {{ font-family: inherit; font-size: 11pt; padding: 8px 20px; background: #1b0b38; color: #ffd95a; border: 1px solid #eab308; border-radius: 6px; cursor: pointer; font-weight: bold; }}
  @media print {{ .no-print {{ display: none !important; }} body {{ padding: 0; }} }}
</style></head><body>
<div class="no-print"><button class="btn" onclick="window.print()">สั่งพิมพ์ / บันทึกเป็น PDF</button></div>
<div class="header">
  <div class="school">{esc(school_name)}</div>
  <div class="sub">สรุปการมาปฏิบัติงานของครู {esc(sl['title'])} ภาคเรียนที่ {esc(str(grid['term']))}/{esc(str(grid['year']))}</div>
  <div class="meta">{esc(sl['range'])}{esc(upto)} • ข้อมูล ณ วันที่ {_thai_date(now.date().isoformat())}</div>
</div>
<div class="overview">{overview}</div>
<table>{colgroup}
  <thead><tr><th>ที่</th><th>ชื่อ - นามสกุล</th>{head_cols}<th>มา</th><th>มาสาย<br>(ส)</th><th>ขอเข้าสาย<br>(ขส)</th><th>ลา<br>(ล)</th><th>ไปราชการ<br>(ร)</th></tr></thead>
  <tbody>{body}</tbody>
</table>
<div class="legend">/ มา • ส มาสาย • ขส ขอเข้าสาย • ล ลา • ร ไปราชการ • ช่องสีเทา = วันหยุด • นับเฉพาะวันเรียนที่ผ่านมาแล้ว • "มา" รวม ส ขส ร{tick_note}</div>
<div class="signatures">
  <div class="sig"><div>ขอรับรองว่าข้อมูลถูกต้องตามความเป็นจริง</div><div class="line"></div>
    <div style="margin-top: 6px;">( {head_line} )</div><div class="meta">ตำแหน่ง หัวหน้างานบุคคล</div></div>
  <div class="sig"><div>ทราบ</div><div class="line"></div>
    <div style="margin-top: 6px;">( {esc(director_name)} )</div><div class="meta">ตำแหน่ง ผู้อำนวยการ{esc(school_name)}</div></div>
</div>
</body></html>"""


# ---------------------------------------------------------------------------------------------------------------
# ใครไม่อยู่ในวันนั้น + คาบสอนที่ได้รับผลกระทบ (dashboard, 2026-11-19): joins the grid with the teachers' timetable
# (teacher_timetables) so the school sees which classes have no teacher and can arrange a substitute.

AWAY_ORDER = {"ล": 0, "ร": 1, "ขส": 2, "ส": 3}
NO_STUDENT_PERIODS = ("PLC ครู",)      # teachers-only periods: nobody has to cover them


def _hhmm(text: Any) -> Optional[str]:
    """'9:30' / '09.30' / '09:30:00' -> '09:30'; anything else -> None."""
    import re
    m = re.fullmatch(r"\s*(\d{1,2})[:.](\d{2})(?::\d{2})?\s*(?:น\.?)?\s*", str(text or ""))
    if not m or int(m.group(1)) > 23 or int(m.group(2)) > 59:
        return None
    return f"{int(m.group(1)):02d}:{m.group(2)}"


def day_overview(term: str, year: str, day: str, now: Optional[datetime] = None, db_path: str = DB,
                 grid: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Who is away on `day` (ล ลา, ร ไปราชการ, ขส ขอเข้าสาย, ส มาสาย) and their timetable that day.
    A period is "affected" (needs a substitute) when the teacher is away for it: every period for ล and ร, the
    periods that start before the arrival time for ขส (no time given: none, the page says so), none for ส.
    Periods without students (PLC ครู) are listed but never affected."""
    import timetable_manager
    grid = grid or build_grid(term, year, now=now, db_path=db_path)
    dates = grid["dates"]
    if day not in dates:
        raise ValueError("วันที่นี้ไม่ใช่วันเรียนของภาคเรียนนี้ (วันเสาร์-อาทิตย์หรือนอกภาคเรียน)")
    slot = dates.index(day)
    dow = date.fromisoformat(day).weekday() + 1          # 1 = Monday ... 5 = Friday
    out: Dict[str, Any] = {"date": day, "slot": slot, "weekday": dow, "is_holiday": slot in grid["holidays"],
                           "today": grid["today"], "is_future": day > grid["today"], "teachers_total": len(grid["teachers"]),
                           "counts": {"ล": 0, "ร": 0, "ขส": 0, "ส": 0}, "affected_periods": 0, "entries": []}
    if out["is_holiday"]:
        return out

    times = {c["period"]: (c["time_start"], c["time_end"]) for c in timetable_manager.PERIOD_CONFIGS if c["period"] > 0}
    with _connect(db_path) as conn:
        trows = conn.execute(
            "SELECT teacher_name, period_num, period_span, course_code, course_name, class_level, room FROM teacher_timetables "
            "WHERE term = ? AND year = ? AND day_of_week = ? ORDER BY period_num;", (str(term).strip(), str(year).strip(), dow)).fetchall()
    by_teacher: Dict[str, List[sqlite3.Row]] = {}
    for r in trows:
        by_teacher.setdefault(database.normalize_teacher_base_name(r["teacher_name"]), []).append(r)

    entries = []
    for order, t in enumerate(grid["teachers"]):
        st = t["status_list"][slot]
        if st not in AWAY_ORDER:
            continue
        info = t["info"][slot] or {}
        arrival = _hhmm(info.get("time")) if st == "ขส" else None
        periods, affected = [], 0
        for r in by_teacher.get(database.normalize_teacher_base_name(t["teacher_name"]), []):
            p0, span = int(r["period_num"]), max(1, int(r["period_span"] or 1))
            start = times.get(p0, ("", ""))[0]
            end = times.get(p0 + span - 1, ("", ""))[1]
            if st in ("ล", "ร"):
                hit = True
            elif st == "ขส" and arrival and start:
                hit = start < arrival
            else:
                hit = False
            no_students = str(r["course_code"]).strip() in NO_STUDENT_PERIODS
            hit = hit and not no_students
            affected += span if hit else 0
            periods.append({"period": p0, "span": span, "time_start": start, "time_end": end, "no_students": no_students,
                            "course_code": r["course_code"], "course_name": r["course_name"] or "",
                            "class_level": r["class_level"] or "", "room": r["room"] or "", "affected": hit})
        entries.append({"teacher_code": t["teacher_code"], "teacher_name": t["teacher_name"], "status": st,
                        "leave_type": info.get("leave_type") or TEACHER_STATUS_NAME[st], "arrival_time": arrival,
                        "late_without_time": st == "ขส" and not arrival, "approval": info.get("approval") or "",
                        "periods": periods, "affected_periods": affected, "_order": order})
        out["counts"][st] += 1
        out["affected_periods"] += affected
    entries.sort(key=lambda e: (AWAY_ORDER[e["status"]], e["_order"]))
    for e in entries:
        del e["_order"]
    out["entries"] = entries
    return out


TEACHER_STATUS_NAME = {"ล": "ลา", "ร": "ไปราชการ", "ขส": "ขอเข้าสาย", "ส": "มาสาย"}
