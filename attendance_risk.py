"""
Early warning for มส. (attendance below 80% of a course's hours makes a student ineligible).

Algorithm: Beta-Binomial forecasting per student x course.
  * Hours already taught (elapsed, holidays excluded, only days the homeroom has recorded)
    give the observed present rate.
  * Prior: the course's class-wide present rate (itself shrunk toward a typical 90%), weighted
    as PRIOR_HOURS of evidence, so a student with 2 observed hours is not judged on 2 hours
    alone (hierarchical empirical Bayes shrinkage).
  * Remaining hours are Beta-Binomial; P(final < 80%) is computed exactly from its pmf.
Chosen over trained classifiers (trees, logistic regression, neural nets) because there are
~65 students and no labelled history of มส. outcomes: the model needs no training data,
is exact, and explains itself ("can still miss N hours").
Also mines each student's absence rate per weekday to show recurring patterns.
"""
import math
from datetime import date
from typing import Any, Dict, List, Optional

import attendance_rules as R

THRESHOLD = 0.80
PRIOR_HOURS = 10.0
TYPICAL_RATE = 0.90        # school-typical present rate, used to stabilise thin early-term data
TYPICAL_WEIGHT = 20.0      # ... weighted as this many hours
MIN_EVIDENCE_HOURS = 4     # below this, a student can be "เฝ้าระวัง" but not "เสี่ยงสูง"
WEEKDAY_TH = ["จันทร์", "อังคาร", "พุธ", "พฤหัสบดี", "ศุกร์"]


def _log_beta(a: float, b: float) -> float:
    return math.lgamma(a) + math.lgamma(b) - math.lgamma(a + b)


def prob_final_below(present: int, remaining: int, total: int, alpha: float, beta: float, threshold: float = THRESHOLD) -> float:
    """P((present + X) / total < threshold) with X ~ BetaBinomial(remaining, alpha, beta)."""
    if total <= 0:
        return 0.0
    need = math.ceil(threshold * total - 1e-9) - present  # future present hours still needed
    if need <= 0:
        return 0.0
    if need > remaining:
        return 1.0
    lb = _log_beta(alpha, beta)
    p = 0.0
    for k in range(0, need):  # X < need
        log_c = math.lgamma(remaining + 1) - math.lgamma(k + 1) - math.lgamma(remaining - k + 1)
        p += math.exp(log_c + _log_beta(k + alpha, remaining - k + beta) - lb)
    return min(1.0, max(0.0, p))


def course_student_risk(
    status_list: List[str],
    hours: List[int],
    activity: Any,
    elapsed_slots: List[int],
    prior_rate: float,
) -> Dict[str, Any]:
    sl = R.clean_status_list(status_list, hours, activity)
    total = sum(hours)
    elapsed = sum(hours[i] for i in elapsed_slots)
    present = sum(hours[i] for i in elapsed_slots if sl[i] in R.PRESENT_MARKS)
    leave = sum(hours[i] for i in elapsed_slots if sl[i] == R.LEAVE_MARK)
    absent = max(0, elapsed - present - leave)
    remaining = max(0, total - elapsed)
    alpha = present + PRIOR_HOURS * prior_rate + 0.5
    beta = (elapsed - present) + PRIOR_HOURS * (1 - prior_rate) + 0.5
    p_hat = alpha / (alpha + beta)
    p_below = prob_final_below(present, remaining, total, alpha, beta)
    max_pct = (present + remaining) / total * 100 if total else 100.0
    can_still_miss = math.floor(present + remaining - THRESHOLD * total + 1e-9) if total else 0
    if total and max_pct < THRESHOLD * 100:
        level = "หมดสิทธิ์ (มส.)"
    elif elapsed < MIN_EVIDENCE_HOURS and absent == 0:
        level = "ปกติ"  # too little observed to warn, and nothing missed yet
    elif p_below >= 0.5 and elapsed >= MIN_EVIDENCE_HOURS:
        level = "เสี่ยงสูง"
    elif p_below >= 0.2 or (total and can_still_miss <= max(2, round(total * 0.05))):
        level = "เฝ้าระวัง"
    else:
        level = "ปกติ"
    return {
        "total_hours": total,
        "elapsed_hours": elapsed,
        "present_hours": present,
        "leave_hours": leave,
        "absent_hours": absent,
        "remaining_hours": remaining,
        "rate_to_date": round(present / elapsed * 100, 1) if elapsed else None,
        "projected_pct": round((present + remaining * p_hat) / total * 100, 1) if total else None,
        "max_possible_pct": round(max_pct, 1),
        "can_still_miss_hours": max(0, can_still_miss),
        "prob_below_80": round(p_below, 3),
        "level": level,
    }


LEVEL_ORDER = {"หมดสิทธิ์ (มส.)": 0, "เสี่ยงสูง": 1, "เฝ้าระวัง": 2, "ปกติ": 3}


def compute_attendance_risk(term: str, year: str, class_level: Optional[str] = None, today: Optional[str] = None, db_path: str = "school_archive.db") -> Dict[str, Any]:
    import json
    import database

    t, y = str(term), str(year)
    today = today or date.today().isoformat()
    with database.get_connection(db_path) as conn:
        cur = conn.cursor()
        q = """
            SELECT cs.student_id, cs.student_no, cs.full_name, cs.class_level, cs.room
            FROM class_students cs
            WHERE cs.term = ? AND cs.year = ? AND COALESCE(cs.is_locked, 0) = 0 AND COALESCE(cs.is_active, 1) = 1
        """
        args: List[Any] = [t, y]
        if class_level:
            q += " AND cs.class_level = ?"
            args.append(class_level)
        students = {r["student_id"]: dict(r) for r in cur.execute(q, args)}
        recorded = {}
        for r in cur.execute("SELECT DISTINCT class_level, attendance_date FROM daily_attendance WHERE term = ? AND year = ? AND attendance_date <= ?;", (t, y, today)):
            recorded.setdefault(r["class_level"], set()).add(r["attendance_date"])
        rows = cur.execute(
            "SELECT g.student_id, g.course_code, g.attendance_json, c.course_name, c.teacher FROM grades_history g JOIN courses c ON c.course_code = g.course_code AND c.term = g.term AND c.year = g.year WHERE g.term = ? AND g.year = ?;",
            (t, y)
        ).fetchall()
        weekday_stats: Dict[str, List[List[int]]] = {}
        for r in cur.execute("SELECT student_id, attendance_date, status FROM daily_attendance WHERE term = ? AND year = ? AND attendance_date <= ?;", (t, y, today)):
            if r["student_id"] not in students:
                continue
            wd = date.fromisoformat(r["attendance_date"]).weekday()
            if wd > 4:
                continue
            st = weekday_stats.setdefault(r["student_id"], [[0, 0] for _ in range(5)])
            st[wd][1] += 1
            if r["status"] == "absent":
                st[wd][0] += 1

    by_course: Dict[str, List[Any]] = {}
    for r in rows:
        if r["student_id"] in students:
            by_course.setdefault(r["course_code"], []).append(r)

    items = []
    with database.connection_scope(db_path):
        contexts = {code: database.get_course_attendance_context(code, t, y, db_path=db_path) for code in by_course}
    for code, crow in by_course.items():
        ctx = contexts[code]
        lvl_dates = set()
        for s in crow:
            lvl_dates |= recorded.get(students[s["student_id"]]["class_level"], set())
        elapsed_slots = [i for i, d in enumerate(ctx["dates"]) if d <= today and d in lvl_dates and ctx["hours"][i]]
        parsed = []
        for s in crow:
            try:
                att = json.loads(s["attendance_json"] or "{}")
            except Exception:
                att = {}
            parsed.append((s, R.normalize_status_list(att.get("status_list"))))
        # empirical prior: class-wide present rate in this course so far, shrunk toward the typical rate
        e_tot = sum(ctx["hours"][i] for i in elapsed_slots) * len(parsed)
        e_pre = sum(ctx["hours"][i] for _, sl in parsed for i in elapsed_slots if sl[i] in R.PRESENT_MARKS)
        prior = (e_pre + TYPICAL_RATE * TYPICAL_WEIGHT) / (e_tot + TYPICAL_WEIGHT)
        for s, sl in parsed:
            risk = course_student_risk(sl, ctx["hours"], ctx["activity"], elapsed_slots, prior)
            st = students[s["student_id"]]
            items.append({
                "student_id": s["student_id"], "student_no": st["student_no"], "full_name": st["full_name"],
                "class_level": st["class_level"], "room": st["room"],
                "course_code": code, "course_name": s["course_name"], "teacher": s["teacher"],
                **risk,
            })

    items.sort(key=lambda x: (LEVEL_ORDER[x["level"]], -x["prob_below_80"], x["max_possible_pct"]))
    students_out: Dict[str, Dict[str, Any]] = {}
    for it in items:
        so = students_out.setdefault(it["student_id"], {
            "student_id": it["student_id"], "student_no": it["student_no"], "full_name": it["full_name"],
            "class_level": it["class_level"], "room": it["room"], "worst_level": it["level"],
            "courses_at_risk": [], "absence_pattern": None,
        })
        if it["level"] != "ปกติ":
            so["courses_at_risk"].append({k: it[k] for k in ("course_code", "course_name", "level", "prob_below_80", "projected_pct", "max_possible_pct", "can_still_miss_hours")})
    for sid, so in students_out.items():
        ws = weekday_stats.get(sid)
        if ws:
            rates = [(a / n if n else 0.0, n, i) for i, (a, n) in enumerate(ws)]
            r, n, i = max(rates)
            overall = sum(a for a, _ in ws) / max(1, sum(n for _, n in ws))
            if n >= 2 and r >= 0.5 and r >= overall + 0.25:
                so["absence_pattern"] = f"ขาดบ่อยวัน{WEEKDAY_TH[i]} ({round(r * 100)}% ของวัน{WEEKDAY_TH[i]}ที่บันทึก)"
    students_list = sorted(students_out.values(), key=lambda s: (LEVEL_ORDER[s["worst_level"]], -len(s["courses_at_risk"])))
    counts = {lvl: sum(1 for s in students_list if s["worst_level"] == lvl) for lvl in LEVEL_ORDER}
    return {
        "term": t, "year": y, "as_of": today, "threshold_pct": THRESHOLD * 100,
        "method": "Beta-Binomial (empirical Bayes) forecast of final attendance per course",
        "summary": counts,
        "students": students_list,
        "items": items,
    }
