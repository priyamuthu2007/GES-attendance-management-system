"""Attendance rules: late, early leave, overtime, half day, leave, holidays, week-offs.

Pure functions, no Flask or database imports, so they are easy to unit test.
Timestamps are stored in UTC; shifts are interpreted in the office timezone.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from typing import Optional
from zoneinfo import ZoneInfo

UTC = timezone.utc

LABELS = {
    "present": "Present", "half_day": "Half day", "absent": "Absent", "leave": "On leave",
    "half_leave": "Half-day leave", "holiday": "Holiday", "week_off": "Week off",
    "worked_off_day": "Worked on a day off", "in_progress": "Checked in",
    "missing_checkout": "Missing check-out", "pending": "Not checked in yet", "upcoming": "Upcoming",
}
TONE = {
    "present": "ok", "half_leave": "ok", "worked_off_day": "ok",
    "half_day": "warn", "in_progress": "warn", "pending": "warn",
    "absent": "bad", "missing_checkout": "bad",
    "leave": "neutral", "holiday": "neutral", "week_off": "neutral", "upcoming": "neutral",
}
FLAG_LABELS = {"late": "Late", "early_leave": "Left early", "overtime": "Overtime"}


@dataclass(frozen=True)
class Policy:
    late_grace_min: int = 10            # late only if check-in is more than this after shift start
    early_leave_grace_min: int = 5      # early leave only if check-out is more than this before shift end
    overtime_after_min: int = 30        # overtime counts only if check-out is at least this after shift end
    half_day_ratio: float = 0.5         # worked less than this share of the shift => half day
    missing_checkout_after_min: int = 120  # open check-in this long after shift end => missing check-out

    @classmethod
    def from_env(cls, env=os.environ) -> "Policy":
        d = cls()
        return cls(
            int(env.get("LATE_GRACE_MIN", d.late_grace_min)),
            int(env.get("EARLY_LEAVE_GRACE_MIN", d.early_leave_grace_min)),
            int(env.get("OVERTIME_AFTER_MIN", d.overtime_after_min)),
            float(env.get("HALF_DAY_RATIO", d.half_day_ratio)),
            int(env.get("MISSING_CHECKOUT_AFTER_MIN", d.missing_checkout_after_min)),
        )


@dataclass(frozen=True)
class Shift:
    start: time
    end: time  # if end <= start the shift ends the next day (night shift)


@dataclass(frozen=True)
class DayResult:
    day: date
    status: str
    flags: tuple = ()
    scheduled_min: int = 0
    worked_min: int = 0
    late_min: int = 0
    early_leave_min: int = 0
    overtime_min: int = 0


def as_time(v) -> time:
    """MySQL TIME columns come back from PyMySQL as timedelta; normalise to datetime.time."""
    if isinstance(v, time):
        return v
    if isinstance(v, timedelta):
        s = int(v.total_seconds()) % 86400
        return time(s // 3600, (s % 3600) // 60, s % 60)
    if isinstance(v, str):
        return time(*[int(p) for p in v.split(":")])
    raise TypeError(f"cannot convert {v!r} to time")


def as_utc(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is None:
        return None
    return dt.replace(tzinfo=UTC) if dt.tzinfo is None else dt.astimezone(UTC)


def shift_window(day: date, shift: Shift, tz: ZoneInfo):
    start = datetime.combine(day, shift.start, tzinfo=tz)
    end = datetime.combine(day, shift.end, tzinfo=tz)
    if end <= start:
        end += timedelta(days=1)
    return start.astimezone(UTC), end.astimezone(UTC)


def _min(a: datetime, b: datetime) -> int:
    return int((a - b).total_seconds() // 60)


def format_minutes(m) -> str:
    return "" if not m else f"{m // 60}h {m % 60:02d}m"


def classify_day(day: date, *, shift: Optional[Shift], check_in, check_out, tz: ZoneInfo,
                 policy: Policy = Policy(), holiday: bool = False, leave: Optional[str] = None,
                 now: Optional[datetime] = None) -> DayResult:
    """Resolve one employee-day. `leave` is None, 'full' or 'half'."""
    now = as_utc(now) or datetime.now(UTC)
    ci, co = as_utc(check_in), as_utc(check_out)
    worked = max(0, _min(co, ci)) if ci and co else 0

    # Days off: holiday, or no shift that weekday. Work done on them counts fully as overtime.
    if holiday or shift is None:
        if ci and co:
            return DayResult(day, "worked_off_day", ("overtime",), 0, worked, overtime_min=worked)
        if ci:
            return DayResult(day, "worked_off_day")
        return DayResult(day, "holiday" if holiday else "week_off")

    if leave == "full":
        return DayResult(day, "leave")

    start, end = shift_window(day, shift, tz)
    scheduled = _min(end, start)

    if leave == "half" and ci:
        return DayResult(day, "half_leave", (), scheduled // 2, worked)

    if not ci:
        if day > now.astimezone(tz).date():
            return DayResult(day, "upcoming", scheduled_min=scheduled)
        if now <= end:
            return DayResult(day, "pending", scheduled_min=scheduled)
        return DayResult(day, "absent", scheduled_min=scheduled)

    late = max(0, _min(ci, start))
    late = late if late > policy.late_grace_min else 0

    if not co:
        overdue = now > end + timedelta(minutes=policy.missing_checkout_after_min)
        return DayResult(day, "missing_checkout" if overdue else "in_progress",
                         ("late",) if late else (), scheduled, 0, late)

    early = max(0, _min(end, co))
    early = early if early > policy.early_leave_grace_min else 0
    ot = max(0, _min(co, end))
    ot = ot if ot >= policy.overtime_after_min else 0
    status = "half_day" if worked < policy.half_day_ratio * scheduled else "present"
    flags = tuple(n for n, v in (("late", late), ("early_leave", early), ("overtime", ot)) if v)
    return DayResult(day, status, flags, scheduled, worked, late, early, ot)
