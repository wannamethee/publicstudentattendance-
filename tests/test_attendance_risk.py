import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import attendance_rules as R
from attendance_risk import course_student_risk, prob_final_below


class RiskTests(unittest.TestCase):
    def test_probability_bounds(self):
        # already has enough present hours
        self.assertEqual(prob_final_below(present=32, remaining=8, total=40, alpha=1, beta=1), 0.0)
        # cannot reach 80% any more
        self.assertEqual(prob_final_below(present=0, remaining=30, total=40, alpha=1, beta=1), 1.0)

    def test_probability_matches_binomial_intuition(self):
        # needs 32 of the remaining 40 with a strong 95% prior: low risk
        low = prob_final_below(0, 40, 40, alpha=95, beta=5)
        # same need with a 70% prior: high risk
        high = prob_final_below(0, 40, 40, alpha=70, beta=30)
        self.assertLess(low, 0.1)
        self.assertGreater(high, 0.8)

    def test_hopeless_student_is_flagged_mor_sor(self):
        hours = R.slot_hours([1, 1, 0, 0, 0])  # 40 hours
        sl = [""] * 100
        elapsed = [i for i in range(45) if hours[i]]  # 18 hours taught, all missed
        r = course_student_risk(sl, hours, set(), elapsed, prior_rate=0.9)
        self.assertEqual(r["level"], "หมดสิทธิ์ (มส.)")
        self.assertLess(r["max_possible_pct"], 80)
        self.assertEqual(r["can_still_miss_hours"], 0)

    def test_regular_student_is_normal(self):
        hours = R.slot_hours([1, 1, 0, 0, 0])
        sl = ["/"] * 100
        elapsed = [i for i in range(20) if hours[i]]
        r = course_student_risk(sl, hours, set(), elapsed, prior_rate=0.9)
        self.assertEqual(r["level"], "ปกติ")
        self.assertEqual(r["can_still_miss_hours"], 8)
        self.assertEqual(r["rate_to_date"], 100.0)


if __name__ == "__main__":
    unittest.main()
