import argparse
import getpass
import re
import sys

import bcrypt
from dotenv import load_dotenv

from attendance import create_app
from attendance.db import connect, get_connection, init_db


DAY_NAMES = {
    "mon": 0,
    "tue": 1,
    "wed": 2,
    "thu": 3,
    "fri": 4,
    "sat": 5,
    "sun": 6,
}


def parse_days(value):
    try:
        days = sorted({DAY_NAMES[day.strip().lower()] for day in value.split(",")})
    except KeyError as error:
        raise argparse.ArgumentTypeError(
            "Use comma-separated weekday names: mon,tue,wed,thu,fri,sat,sun."
        ) from error
    if not days:
        raise argparse.ArgumentTypeError("At least one shift day is required.")
    return days


def parse_time(value):
    if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", value):
        raise argparse.ArgumentTypeError("Use 24-hour HH:MM time, such as 09:00.")
    return value


def build_parser():
    parser = argparse.ArgumentParser(description="GES Smart Attendance administrator tools.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init-db", help="Create the MySQL tables.")
    manager = commands.add_parser("create-manager", help="Create a manager account.")
    manager.add_argument("manager_id")
    employee = commands.add_parser("create-employee", help="Create an employee and assign shift days.")
    employee.add_argument("employee_id")
    employee.add_argument("--days", type=parse_days, default=parse_days("mon,tue,wed,thu,fri"))
    employee.add_argument("--shift-start", type=parse_time, default="09:00")
    employee.add_argument("--shift-end", type=parse_time, default="17:00")
    shift = commands.add_parser("set-shift", help="Update an employee's assigned shift days.")
    shift.add_argument("employee_id")
    shift.add_argument("--days", type=parse_days, required=True)
    shift.add_argument("--shift-start", type=parse_time, required=True)
    shift.add_argument("--shift-end", type=parse_time, required=True)
    return parser


def create_employee(employee_id, days, shift_start, shift_end):
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", employee_id):
        raise ValueError("Employee ID may contain letters, numbers, dot, underscore, or hyphen.")
    if shift_start == shift_end:
        raise ValueError("Shift start and end cannot be the same time.")
    password = getpass.getpass("New employee password (12+ characters): ")
    confirmation = getpass.getpass("Confirm password: ")
    if len(password) < 12:
        raise ValueError("Password must contain at least 12 characters.")
    if len(password.encode("utf-8")) > 72:
        raise ValueError("Password must not exceed 72 UTF-8 bytes.")
    if password != confirmation:
        raise ValueError("Passwords do not match.")

    password_hash = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("ascii")
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "INSERT INTO employees (employee_id, password_hash) VALUES (%s, %s)",
                (employee_id, password_hash),
            )
            for day in days:
                cursor.execute(
                    """INSERT INTO employee_shifts
                       (employee_id, day_of_week, shift_start, shift_end)
                       VALUES (%s, %s, %s, %s)""",
                    (employee_id, day, shift_start, shift_end),
                )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    print(f"Employee {employee_id} created with shifts {shift_start}-{shift_end}.")


def create_manager(manager_id):
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", manager_id):
        raise ValueError("Manager ID may contain letters, numbers, dot, underscore, or hyphen.")
    password = getpass.getpass("New manager password (12+ characters): ")
    confirmation = getpass.getpass("Confirm password: ")
    if len(password) < 12:
        raise ValueError("Password must contain at least 12 characters.")
    if len(password.encode("utf-8")) > 72:
        raise ValueError("Password must not exceed 72 UTF-8 bytes.")
    if password != confirmation:
        raise ValueError("Passwords do not match.")

    password_hash = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("ascii")
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "INSERT INTO managers (manager_id, password_hash) VALUES (%s, %s)",
                (manager_id, password_hash),
            )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    print(f"Manager {manager_id} created.")


def set_shift(employee_id, days, shift_start, shift_end):
    if shift_start == shift_end:
        raise ValueError("Shift start and end cannot be the same time.")
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT employee_id FROM employees WHERE employee_id = %s AND active = 1",
                (employee_id,),
            )
            if not cursor.fetchone():
                raise ValueError(f"Active employee {employee_id} was not found.")
            for day in days:
                cursor.execute(
                    """INSERT INTO employee_shifts
                       (employee_id, day_of_week, shift_start, shift_end)
                       VALUES (%s, %s, %s, %s)
                       ON DUPLICATE KEY UPDATE
                         shift_start = VALUES(shift_start), shift_end = VALUES(shift_end)""",
                    (employee_id, day, shift_start, shift_end),
                )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    print(f"Shift assigned to {employee_id}: {shift_start}-{shift_end}.")


def main(argv=None):
    load_dotenv()
    args = build_parser().parse_args(argv)
    app = create_app()
    with app.app_context():
        if args.command == "init-db":
            if not app.config["MYSQL_MIGRATION_USER"] or not app.config["MYSQL_MIGRATION_PASSWORD"]:
                raise ValueError("Set MYSQL_MIGRATION_USER and MYSQL_MIGRATION_PASSWORD in .env.")
            connection = connect(app.config, migration=True)
            try:
                init_db(connection)
                print("MySQL schema is up to date.")
            finally:
                connection.close()
        elif args.command == "create-employee":
            create_employee(args.employee_id, args.days, args.shift_start, args.shift_end)
        elif args.command == "create-manager":
            create_manager(args.manager_id)
        elif args.command == "set-shift":
            set_shift(args.employee_id, args.days, args.shift_start, args.shift_end)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Command failed: {error}", file=sys.stderr)
        raise SystemExit(1)
