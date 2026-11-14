"""
Unit tests for attendance_rules (the ปพ.5 attendance arithmetic).
Run: python -m unittest discover -s tests
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import attendance_rules as R

# Week 1 of 2/2569: Mon 26 Oct .. Fri 30 Oct 2026
DATES = [f"2026-10-{26 + i}" for i in range(5)] + [f"d{i}" for i in range(5, 100)]


def schedule(*slots):
    return [{"day": d, "period": p, "span": s} for d, p, s in slots]


class PeriodsTests(unittest.TestCase):
    def test_list_schedule_sums_spans_per_weekday(self):
        sch = schedule((2, 3, 1), (2, 4, 1), (5, 1, 1))
        self.assertEqual(R.periods_by_weekday(sch), [0, 2, 0, 0, 1])
        self.assertEqual(R.period_numbers_by_weekday(sch), [[], [3, 4], [], [], [1]])

    def test_dict_schedule_prefers_slots_over_counts(self):
        sch = {"mon": 1, "tue": 1, "slots": schedule((3, 2, 1))}
        self.assertEqual(R.periods_by_weekday(sch), [0, 0, 1, 0, 0])

    def test_legacy_dict_counts(self):
        self.assertEqual(R.periods_by_weekday('{"mon": 1, "fri": 2}'), [1, 0, 0, 0, 2])


class SummaryTests(unittest.TestCase):
    def test_hours_are_weighted_by_row_8(self):
        # Tue taught 2 periods: one "/" on Tuesday is worth 2 hours, as in the template row 8
        hours = R.slot_hours([0, 2, 0, 0, 0])
        sl = [""] * 100
        sl[1] = "/"
        s = R.summarize(sl, hours)
        self.assertEqual((s["present_count"], s["absent_count"], s["total_periods"]), (2, 38, 40))
        self.assertEqual(s["percentage"], 5.0)

    def test_holidays_leave_total_and_clear_marks(self):
        hours = R.slot_hours([1, 1, 1, 0, 0], holidays={0, 1})
        sl = ["/"] * 100
        s = R.summarize(sl, hours)
        self.assertEqual(s["total_periods"], 58)
        self.assertEqual(s["status_list"][0], "")
        self.assertEqual(s["status_list"][3], "")  # not taught on Thursday

    def test_late_counts_present_leave_counts_separately(self):
        hours = R.slot_hours([1, 1, 0, 0, 0])
        sl = [""] * 100
        sl[0], sl[1] = "ส", "ล"
        s = R.summarize(sl, hours)
        self.assertEqual((s["present_count"], s["late_count"], s["leave_count"], s["absent_count"]), (1, 1, 1, 38))

    def test_activity_day_counts_present(self):
        hours = R.slot_hours([1, 0, 0, 0, 0])
        s = R.summarize([""] * 100, hours, activity_days={0})
        self.assertEqual(s["status_list"][0], "/")
        self.assertEqual(s["present_count"], 1)


class UpToTodayTests(unittest.TestCase):
    def test_absent_and_percent_count_only_days_up_to_today(self):
        hours = R.slot_hours([1, 1, 1, 1, 1], holidays={0, 1, 2, 3})  # 26-29 Oct holidays
        sl = [""] * 100
        sl[4] = "/"  # Fri 30 Oct present
        s = R.summarize(sl, hours, elapsed_slots=5)  # today = Fri 30 Oct
        self.assertEqual((s["present_count"], s["absent_count"], s["elapsed_periods"]), (1, 0, 1))
        self.assertEqual(s["percentage"], 100.0)
        self.assertEqual(s["total_periods"], 96)  # N3 stays the full semester

    def test_marks_after_today_are_ignored(self):
        hours = R.slot_hours([1, 1, 1, 1, 1])
        s = R.summarize(["/"] * 100, hours, elapsed_slots=2)
        self.assertEqual(s["status_list"][:3], ["/", "/", ""])
        self.assertEqual((s["present_count"], s["percentage"]), (2, 100.0))

    def test_nothing_taught_yet(self):
        s = R.summarize([""] * 100, R.slot_hours([1, 0, 0, 0, 0]), elapsed_slots=0)
        self.assertEqual((s["absent_count"], s["percentage"]), (0, 100.0))

    def test_elapsed_slot_count(self):
        self.assertEqual(R.elapsed_slot_count(DATES[:5], today="2026-10-28"), 3)


class DailyDerivationTests(unittest.TestCase):
    def test_unrecorded_days_stay_blank(self):
        hours = R.slot_hours([1, 1, 1, 1, 1])
        auto = R.auto_status_list({"2026-10-26": "present"}, DATES, hours)
        self.assertEqual(auto[:5], ["/", "", "", "", ""])

    def test_late_arrival_after_the_course_periods_is_absent(self):
        sch = schedule((1, 1, 1), (1, 2, 1))  # Monday periods 1-2
        hours = R.slot_hours(R.periods_by_weekday(sch))
        nums = R.period_numbers_by_weekday(sch)
        auto = R.auto_status_list({"2026-10-26": ("late", "มาคาบ 3 (ค21102)")}, DATES, hours, (), nums)
        self.assertEqual(auto[0], "")
        auto = R.auto_status_list({"2026-10-26": ("late", "มาคาบ 2")}, DATES, hours, (), nums)
        self.assertEqual(auto[0], "ส")

    def test_teacher_overrides_survive_resync(self):
        hours = R.slot_hours([1, 1, 0, 0, 0])
        auto = R.auto_status_list({"2026-10-26": "present", "2026-10-27": "present"}, DATES, hours)
        submitted = list(auto)
        submitted[1] = "ล"  # teacher records leave on Tuesday
        manual = R.manual_slots_from(submitted, auto, hours)
        self.assertEqual(manual, [1])
        stored = {"status_list": submitted, "manual_slots": manual}
        # homeroom later changes Monday to absent: Monday follows, Tuesday keeps the teacher's mark
        new_auto = R.auto_status_list({"2026-10-27": "present"}, DATES, hours)
        sl, kept = R.resolve_status_list(stored, new_auto, has_daily=True)
        self.assertEqual(sl[:2], ["", "ล"])
        self.assertEqual(kept, [1])
        sl, kept = R.resolve_status_list(stored, new_auto, has_daily=True, from_daily=True)
        self.assertEqual((sl[1], kept), ("/", []))

    def test_no_exam_right_only_once_80_percent_is_out_of_reach(self):
        # 40 hours in the semester: up to 8 hours missed (absent or leave) can still reach 80%
        self.assertFalse(R.no_exam_right(present=2, elapsed=10, total=40))   # 8 missed: 32/40 = 80%
        self.assertTrue(R.no_exam_right(present=1, elapsed=10, total=40))    # 9 missed: 31/40 < 80%
        self.assertFalse(R.no_exam_right(present=0, elapsed=0, total=0))
        hours = R.slot_hours([2, 0, 0, 0, 0])   # 2 hours every Monday, 40 in the semester
        sl = [""] * 100
        self.assertTrue(R.summarize(sl, hours, (), 25)["no_exam_right"])     # 5 Mondays absent = 10 hours
        sl[0] = sl[5] = "/"
        self.assertFalse(R.summarize(sl, hours, (), 25)["no_exam_right"])    # teacher fixes 2 Mondays: 6 missed

    def test_teacher_remark_wins_over_attendance_ms(self):
        self.assertEqual(R.effective_remark("", {"no_exam_right": True}), "มส")
        self.assertEqual(R.effective_remark("ร", {"no_exam_right": True}), "ร")
        self.assertEqual(R.effective_remark("", {"no_exam_right": False}), "")
        self.assertEqual(R.effective_remark(None, {}), "")

    def test_legacy_semesters_keep_stored_marks(self):
        stored = {"status_list": ["/"] * 40}
        sl, manual = R.resolve_status_list(stored, [""] * 100, has_daily=False)
        self.assertEqual(sl[:5], ["/", "/", "", "", ""])
        self.assertEqual(manual, [])


if __name__ == "__main__":
    unittest.main()
