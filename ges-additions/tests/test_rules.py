import unittest
from datetime import date, datetime, time
from zoneinfo import ZoneInfo

from attendance import rules

IST = ZoneInfo("Asia/Kolkata")
DAY = date(2026, 11, 10)
DAY_SHIFT = rules.Shift(time(9, 0), time(17, 0))
NIGHT_SHIFT = rules.Shift(time(22, 0), time(6, 0))
AFTER = datetime(2026, 11, 20, 12, 0, tzinfo=IST)  # "now" safely after DAY


def at(d, h, m=0):
    return datetime(2026, 11, d, h, m, tzinfo=IST)


def run(shift=DAY_SHIFT, cin=None, cout=None, **kw):
    kw.setdefault("now", AFTER)
    return rules.classify_day(DAY, shift=shift, check_in=cin, check_out=cout, tz=IST, **kw)


class RulesTests(unittest.TestCase):
    def test_on_time_full_day(self):
        r = run(cin=at(10, 9, 0), cout=at(10, 17, 0))
        self.assertEqual((r.status, r.flags, r.worked_min), ("present", (), 480))

    def test_late_respects_grace(self):
        self.assertEqual(run(cin=at(10, 9, 10), cout=at(10, 17)).flags, ())
        r = run(cin=at(10, 9, 25), cout=at(10, 17))
        self.assertEqual((r.flags, r.late_min), (("late",), 25))

    def test_early_leave(self):
        r = run(cin=at(10, 9), cout=at(10, 16, 30))
        self.assertEqual((r.flags, r.early_leave_min), (("early_leave",), 30))

    def test_overtime_threshold(self):
        self.assertEqual(run(cin=at(10, 9), cout=at(10, 17, 20)).overtime_min, 0)
        r = run(cin=at(10, 9), cout=at(10, 18, 15))
        self.assertEqual((r.flags, r.overtime_min), (("overtime",), 75))

    def test_half_day(self):
        r = run(cin=at(10, 9), cout=at(10, 12, 30))
        self.assertEqual(r.status, "half_day")

    def test_night_shift_crosses_midnight(self):
        r = run(shift=NIGHT_SHIFT, cin=at(10, 21, 58), cout=at(11, 6, 10))
        self.assertEqual((r.status, r.flags, r.scheduled_min, r.worked_min), ("present", (), 480, 492))

    def test_absent_pending_upcoming(self):
        self.assertEqual(run().status, "absent")
        self.assertEqual(run(now=at(10, 11)).status, "pending")
        self.assertEqual(run(now=at(9, 11)).status, "upcoming")

    def test_open_checkin_then_missing_checkout(self):
        self.assertEqual(run(cin=at(10, 9), now=at(10, 15)).status, "in_progress")
        self.assertEqual(run(cin=at(10, 9), now=at(10, 20)).status, "missing_checkout")

    def test_days_off(self):
        self.assertEqual(run(shift=None).status, "week_off")
        self.assertEqual(run(holiday=True).status, "holiday")
        r = run(holiday=True, cin=at(10, 10), cout=at(10, 14))
        self.assertEqual((r.status, r.overtime_min), ("worked_off_day", 240))

    def test_leave(self):
        self.assertEqual(run(leave="full").status, "leave")
        self.assertEqual(run(leave="half", cin=at(10, 9), cout=at(10, 13)).status, "half_leave")
        self.assertEqual(run(leave="half").status, "absent")

    def test_naive_db_timestamps_are_utc(self):
        # 03:30 UTC == 09:00 IST, 11:30 UTC == 17:00 IST
        r = run(cin=datetime(2026, 11, 10, 3, 30), cout=datetime(2026, 11, 10, 11, 30))
        self.assertEqual((r.status, r.flags), ("present", ()))

    def test_mysql_time_as_timedelta(self):
        from datetime import timedelta
        self.assertEqual(rules.as_time(timedelta(hours=9, minutes=30)), time(9, 30))


if __name__ == "__main__":
    unittest.main()
