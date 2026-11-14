"""
Single source of truth for ปพ.5 course attendance arithmetic.

Mirrors the ปพ.5 template (template_ปพ5_blank.xlsx):
  - Sheets (2)/(3) have one column per school day (20 weeks x Mon-Fri = 100 slots).
  - Row 8 "ชั่วโมงที่" holds how many hours that day's check is worth
    (the template note at BB9: "เรียนจำนวน 1 ชั่วโมง/การเช็ค").
  - Sheet (3) summary:  AW มาเรียน = sum of hours marked "/" or "ส"
                        AY ลา      = sum of hours marked "ล"
                        AX ขาด     = hours taught up to today - มาเรียน - ลา
                        AZ ร้อยละ  = มาเรียน / hours taught up to today * 100
    N3 / AW8 stay the full-semester total (sum of row 8). Days after today are not
    counted yet; "today" is the computer's local date, so a new day starts at midnight.

Holidays contribute 0 hours. Activity days (locked_counted) count as present
for every period the course is actually taught that day.
"""
import json
import re
from datetime import date
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

WEEKS = 20
DAYS = 5
SLOTS = WEEKS * DAYS

PRESENT_MARK = "/"
LATE_MARK = "ส"
LEAVE_MARK = "ล"
PRESENT_MARKS = frozenset({PRESENT_MARK, LATE_MARK})

DAILY_STATUS_TO_MARK = {"present": PRESENT_MARK, "late": LATE_MARK, "leave": LEAVE_MARK}

# Fallback when a course has no timetable at all (legacy behaviour: Mon + Tue, 1 period each)
DEFAULT_PERIODS = (1, 1, 0, 0, 0)

_DAY_KEYS = {
    "mon": 0, "monday": 0, "จันทร์": 0, "จ": 0,
    "tue": 1, "tuesday": 1, "อังคาร": 1, "อ": 1,
    "wed": 2, "wednesday": 2, "พุธ": 2, "พ": 2,
    "thu": 3, "thursday": 3, "พฤหัสบดี": 3, "พฤ": 3,
    "fri": 4, "friday": 4, "ศุกร์": 4, "ศ": 4,
}

_ARRIVED_PERIOD_RE = re.compile(r"มาคาบ\s*(\d+)")


def today_iso() -> str:
    """The computer's local date (YYYY-MM-DD); a new school day starts right after midnight."""
    return date.today().isoformat()


def elapsed_slot_count(dates: Sequence[str], today: Optional[str] = None) -> int:
    """How many of the 100 semester day-slots are on or before today (dates are in order)."""
    today = today or today_iso()
    return sum(1 for d in dates[:SLOTS] if d <= today)


def _load(schedule: Any) -> Any:
    if isinstance(schedule, str):
        try:
            return json.loads(schedule) if schedule.strip() else None
        except Exception:
            return None
    return schedule


def schedule_slots(schedule: Any) -> List[Dict[str, Any]]:
    """Return the list-of-slots form ({day:1..5, period, span}) of a schedule, or [] if unknown."""
    schedule = _load(schedule)
    if isinstance(schedule, list):
        return [s for s in schedule if isinstance(s, dict)]
    if isinstance(schedule, dict) and isinstance(schedule.get("slots"), list) and schedule["slots"]:
        return [s for s in schedule["slots"] if isinstance(s, dict)]
    return []


def periods_by_weekday(schedule: Any) -> List[int]:
    """Teaching periods per weekday, index 0=Mon .. 4=Fri. Accepts list-of-slots, dict or JSON string."""
    periods = [0] * DAYS
    slots = schedule_slots(schedule)
    if slots:
        for s in slots:
            try:
                d = int(s.get("day"))
                span = int(s.get("span") or 1)
            except (TypeError, ValueError):
                continue
            if 1 <= d <= DAYS:
                periods[d - 1] += span
        return periods

    schedule = _load(schedule)
    if isinstance(schedule, dict):
        for k, v in schedule.items():
            idx = _DAY_KEYS.get(str(k).lower().strip())
            if idx is None:
                continue
            try:
                periods[idx] += max(0, int(v or 0))
            except (TypeError, ValueError):
                pass
    return periods


def period_numbers_by_weekday(schedule: Any) -> List[List[int]]:
    """Period numbers taught per weekday (e.g. [[2], [], [2], [], [3]]); empty when only counts are known."""
    out: List[List[int]] = [[] for _ in range(DAYS)]
    for s in schedule_slots(schedule):
        try:
            d = int(s.get("day"))
            p = int(s.get("period"))
            span = int(s.get("span") or 1)
        except (TypeError, ValueError):
            continue
        if 1 <= d <= DAYS:
            out[d - 1].extend(range(p, p + span))
    return [sorted(x) for x in out]


def parse_slot_set(raw: Any) -> Set[int]:
    if isinstance(raw, str):
        try:
            raw = json.loads(raw) if raw.strip() else []
        except Exception:
            return set()
    out: Set[int] = set()
    for x in raw or []:
        try:
            i = int(x)
        except (TypeError, ValueError):
            continue
        if 0 <= i < SLOTS:
            out.add(i)
    return out


def slot_hours(periods: Sequence[int], holidays: Iterable[int] = (), activity_days: Iterable[int] = ()) -> List[int]:
    """Row 8 of the ปพ.5: hours each of the 100 day-slots is worth for this course."""
    hol = set(holidays)
    return [0 if i in hol else int(periods[i % DAYS]) for i in range(SLOTS)]


def normalize_status_list(status_list: Optional[Sequence[Any]]) -> List[str]:
    """Pad/truncate to 100 slots. A legacy 40-slot list (2 days/week) is expanded onto Mon/Tue."""
    sl = ["" if v is None else str(v) for v in (status_list or [])]
    if len(sl) == 40:
        expanded: List[str] = []
        for w in range(WEEKS):
            expanded.extend([sl[w * 2], sl[w * 2 + 1], "", "", ""])
        return expanded
    return (sl + [""] * SLOTS)[:SLOTS]


def arrived_period_from_note(note: Optional[str]) -> Optional[int]:
    m = _ARRIVED_PERIOD_RE.search(note or "")
    return int(m.group(1)) if m else None


def mark_from_daily(status: Optional[str], arrived_period: Optional[int], periods_that_day: Sequence[int]) -> str:
    """
    Course mark for one day from the homeroom (daily) record.
    Unrecorded days stay blank. A late student who arrived after every period
    this course teaches that day missed the class, so it is blank (absent).
    """
    if status == "late" and arrived_period and periods_that_day:
        if all(p < arrived_period for p in periods_that_day):
            return ""
    return DAILY_STATUS_TO_MARK.get(status or "", "")


def auto_status_list(
    daily_by_date: Dict[str, Any],
    dates: Sequence[str],
    hours: Sequence[int],
    activity_days: Iterable[int] = (),
    period_numbers: Optional[Sequence[Sequence[int]]] = None,
    elapsed_slots: int = SLOTS,
) -> List[str]:
    """
    Status list derived purely from the daily attendance table, up to today (elapsed_slots).
    daily_by_date maps ISO date -> status string or (status, note) tuple.
    """
    act = set(activity_days)
    out = [""] * SLOTS
    for i in range(min(SLOTS, elapsed_slots)):
        if not hours[i]:
            continue
        if i in act:
            out[i] = PRESENT_MARK
            continue
        rec = daily_by_date.get(dates[i]) if i < len(dates) else None
        if isinstance(rec, (tuple, list)):
            status, note = (rec[0], rec[1] if len(rec) > 1 else None)
        else:
            status, note = rec, None
        nums = period_numbers[i % DAYS] if period_numbers else []
        out[i] = mark_from_daily(status, arrived_period_from_note(note), nums)
    return out


def clean_status_list(status_list: Sequence[str], hours: Sequence[int], activity_days: Iterable[int] = (), elapsed_slots: int = SLOTS) -> List[str]:
    """Blank slots worth 0 hours (holidays / non-teaching days) and days after today; activity days count present."""
    act = set(activity_days)
    sl = normalize_status_list(status_list)
    return [
        "" if not hours[i] or i >= elapsed_slots else (PRESENT_MARK if i in act else sl[i])
        for i in range(SLOTS)
    ]


def merge_manual(auto: Sequence[str], stored: Sequence[str], manual_slots: Iterable[int]) -> List[str]:
    """Teacher overrides win on their slots; everything else follows the daily table."""
    manual = set(manual_slots)
    return [stored[i] if i in manual else auto[i] for i in range(SLOTS)]


def manual_slots_from(submitted: Sequence[str], auto: Sequence[str], hours: Sequence[int]) -> List[int]:
    return [i for i in range(SLOTS) if hours[i] and submitted[i] != auto[i]]


NO_EXAM_RIGHT = "มส"


def no_exam_right(present: int, elapsed: int, total: int) -> bool:
    """มส.: even attending every remaining hour cannot reach 80% of the semester hours
    (absent + leave > 20% of N3). Same rule as the risk panel's "หมดสิทธิ์ (มส.)"."""
    remaining = max(0, total - elapsed)
    return total > 0 and (present + remaining) * 5 < total * 4


def effective_remark(manual_remark: Optional[str], attendance: Optional[Dict[str, Any]]) -> str:
    """Sheet (4) column S: the teacher's own remark (ร, มผ, ...) wins; otherwise มส. follows the
    attendance, so it appears and disappears as the teacher corrects the course's attendance."""
    manual = str(manual_remark or "").strip()
    if manual:
        return manual
    return NO_EXAM_RIGHT if (attendance or {}).get("no_exam_right") else ""


def summarize(
    status_list: Sequence[str],
    hours: Sequence[int],
    activity_days: Iterable[int] = (),
    elapsed_slots: int = SLOTS,
) -> Dict[str, Any]:
    """
    AW-AZ summary of the ปพ.5 sheet (3), counted up to today:
    only the first `elapsed_slots` day-slots (dates <= today) are taught yet, so ขาด and
    ร้อยละ use the hours taught so far; total_periods stays the full-semester N3/AW8.
    """
    n = max(0, min(SLOTS, elapsed_slots))
    sl = clean_status_list(status_list, hours, activity_days, n)
    total = sum(hours)
    elapsed = sum(hours[:n])
    present = sum(hours[i] for i in range(n) if sl[i] in PRESENT_MARKS)
    late = sum(hours[i] for i in range(n) if sl[i] == LATE_MARK)
    leave = sum(hours[i] for i in range(n) if sl[i] == LEAVE_MARK)
    absent = max(0, elapsed - present - leave)
    pct = round(present / elapsed * 100, 1) if elapsed > 0 else 100.0
    return {
        "no_exam_right": no_exam_right(present, elapsed, total),
        "status_list": sl,
        "present_count": present,
        "absent_count": absent,
        "leave_count": leave,
        "late_count": late,
        "total_periods": total,
        "elapsed_periods": elapsed,
        "elapsed_slots": n,
        "total_slots": SLOTS,
        "percentage": pct,
    }


def resolve_status_list(
    stored_att: Dict[str, Any],
    auto: Sequence[str],
    has_daily: bool,
    from_daily: bool = False,
) -> Tuple[List[str], List[int]]:
    """
    Decide what a student's course status list is, and which slots are teacher overrides.
    - from_daily: discard overrides and take the daily table as-is.
    - semester has daily data for the student: daily table + teacher overrides.
    - otherwise (legacy / imported terms): keep the stored list untouched.
    """
    stored = normalize_status_list(stored_att.get("status_list"))
    if from_daily:
        return list(auto), []
    if has_daily:
        manual = sorted(parse_slot_set(stored_att.get("manual_slots")))
        return merge_manual(auto, stored, manual), manual
    return stored, []
