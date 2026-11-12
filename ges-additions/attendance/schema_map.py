"""Everything this add-on assumes about your EXISTING GES database lives in this file.

Run `SHOW CREATE TABLE ...` on your real tables and edit the names below until they match.
New tables (admin_users, audit_log, holidays, leave_records) come from migrations/001_additions.sql.
The dict values are trusted constants used to build SQL; never fill them from user input.
"""
import os
from contextlib import contextmanager

import pymysql
from pymysql.cursors import DictCursor

TZ_NAME = os.getenv("APP_TIMEZONE", "Asia/Kolkata")
OFFICES = [o.strip() for o in os.getenv("OFFICE_CODES", "anna-nagar,manapakkam").split(",") if o.strip()]

EMP = {"table": "employees", "id": "id", "code": "employee_code",
       "pw": "password_hash", "active": "is_active"}

SHIFT = {"table": "employee_shifts", "emp": "employee_id", "day": "weekday",
         "start": "shift_start", "end": "shift_end"}

ATT = {"table": "attendance_records", "id": "id", "emp": "employee_id",
       "date": "attendance_date", "cin": "check_in_at", "cout": "check_out_at",
       "office": "office_code",
       # Extra NOT NULL columns your table needs when a correction INSERTs a brand-new record,
       # e.g. {"latitude": 0, "longitude": 0, "gps_accuracy_m": 0, "distance_m": 0}
       "extra_insert": {}}

# How weekdays are stored in SHIFT["day"]: "name" -> 'mon'..'sun', "int" -> 0..6 (Monday = 0)
WEEKDAYS_AS = "name"
DAY_NAMES = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


def normalise_day(v):
    return str(v).strip().lower()[:3] if WEEKDAYS_AS == "name" else int(v)


def weekday_value(d):
    return DAY_NAMES[d.weekday()] if WEEKDAYS_AS == "name" else d.weekday()


def parse_days(names):
    return [n if WEEKDAYS_AS == "name" else DAY_NAMES.index(n) for n in names]


def day_name(v):
    return DAY_NAMES[v] if isinstance(v, int) else v


def day_index(v):
    return v if isinstance(v, int) else DAY_NAMES.index(v)


@contextmanager
def db():
    """Short-lived connection: commits on success, rolls back on error."""
    conn = pymysql.connect(
        host=os.getenv("MYSQL_HOST", "127.0.0.1"),
        port=int(os.getenv("MYSQL_PORT", "3306")),
        user=os.environ["MYSQL_USER"],
        password=os.environ["MYSQL_PASSWORD"],
        database=os.getenv("MYSQL_DATABASE", "ges_attendance"),
        charset="utf8mb4", cursorclass=DictCursor, autocommit=False,
    )
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
