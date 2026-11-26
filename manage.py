import argparse
import getpass
import re
import sys

import bcrypt
from dotenv import load_dotenv

from attendance import create_app
from attendance.db import connect, get_connection, init_db
from attendance.roster import read_employee_roster


DAY_NAMES = {
    "mon": 0,
    "tue": 1,
    "wed": 2,
    "thu": 3,
    "fri": 4,
    "sat": 5,
    "sun": 6,
}
ROSTER_SITES = {
    "HO": "anna-nagar",
    "KPL": "kpl",
    "KPL-STP": "kpl-stp",
    "NLC M1A": "nlc-m1a",
    "ZIRCONIUM": "zirconium",
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


def parse_offices(value):
    offices = [office.strip() for office in value.split(",")]
    if not offices or any(not office for office in offices) or len(set(offices)) != len(offices):
        raise argparse.ArgumentTypeError("Provide unique comma-separated office IDs.")
    return offices


def build_parser():
    parser = argparse.ArgumentParser(description="GES Smart Attendance administrator tools.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init-db", help="Create the PostgreSQL tables.")
    employee = commands.add_parser("create-employee", help="Create an employee and assign shift days.")
    employee.add_argument("employee_id")
    employee.add_argument("--sites", type=parse_offices, required=True)
    schedule = employee.add_mutually_exclusive_group()
    schedule.add_argument("--no-shift", action="store_true")
    schedule.add_argument("--flexible-shift", action="store_true")
    employee.add_argument("--days", type=parse_days, default=parse_days("mon,tue,wed,thu,fri"))
    employee.add_argument("--shift-start", type=parse_time, default="09:00")
    employee.add_argument("--shift-end", type=parse_time, default="17:00")
    sites = commands.add_parser("set-sites", help="Assign an employee to registered offices.")
    sites.add_argument("employee_id")
    sites.add_argument("--sites", type=parse_offices, required=True)
    roster = commands.add_parser(
        "import-roster",
        help="Create/update employee IDs and site assignments from an .xlsx roster.",
    )
    roster.add_argument("workbook")
    roster.add_argument("--preview", action="store_true")
    shift = commands.add_parser("set-shift", help="Update an employee's assigned shift days.")
    shift.add_argument("employee_id")
    shift.add_argument("--days", type=parse_days, required=True)
    shift.add_argument("--shift-start", type=parse_time, required=True)
    shift.add_argument("--shift-end", type=parse_time, required=True)
    role = commands.add_parser("set-role", help="Set an employee's add-on access role.")
    role.add_argument("employee_id")
    role.add_argument("role", choices=("admin", "manager", "hr", "auditor", "employee"))
    return parser


def create_employee(
    employee_id,
    days,
    shift_start,
    shift_end,
    sites,
    offices,
    no_shift=False,
    flexible_shift=False,
):
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", employee_id):
        raise ValueError("Employee ID may contain letters, numbers, dot, underscore, or hyphen.")
    if not sites or len(set(sites)) != len(sites):
        raise ValueError("Assign at least one unique office site.")
    available_offices = {office["id"] for office in offices}
    unknown_offices = set(sites) - available_offices
    if unknown_offices:
        raise ValueError(f"Unknown office IDs: {', '.join(sorted(unknown_offices))}.")
    if not no_shift and not flexible_shift and shift_start == shift_end:
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
            for office_id in sites:
                cursor.execute(
                    "INSERT INTO employee_offices (employee_id, office_id) VALUES (%s, %s)",
                    (employee_id, office_id),
                )
            if flexible_shift:
                shift_days = range(7)
            elif no_shift:
                shift_days = ()
            else:
                shift_days = days
            for day in shift_days:
                cursor.execute(
                    """INSERT INTO employee_shifts
                       (employee_id, day_of_week, shift_start, shift_end)
                       VALUES (%s, %s, %s, %s)""",
                    (
                        employee_id,
                        day,
                        None if flexible_shift else shift_start,
                        None if flexible_shift else shift_end,
                    ),
                )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    if flexible_shift:
        schedule_label = "with flexible shifts every day"
    elif no_shift:
        schedule_label = "without fixed shift hours"
    else:
        schedule_label = f"with shifts {shift_start}-{shift_end}"
    print(f"Employee {employee_id} created {schedule_label} at {', '.join(sites)}.")


def set_sites(employee_id, sites, offices):
    if not sites or len(set(sites)) != len(sites):
        raise ValueError("Assign at least one unique office site.")
    available_offices = {office["id"] for office in offices}
    unknown_offices = set(sites) - available_offices
    if unknown_offices:
        raise ValueError(f"Unknown office IDs: {', '.join(sorted(unknown_offices))}.")
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT employee_id FROM employees WHERE employee_id = %s AND active = TRUE",
                (employee_id,),
            )
            if not cursor.fetchone():
                raise ValueError(f"Active employee {employee_id} was not found.")
            cursor.execute("DELETE FROM employee_offices WHERE employee_id = %s", (employee_id,))
            for office_id in sites:
                cursor.execute(
                    "INSERT INTO employee_offices (employee_id, office_id) VALUES (%s, %s)",
                    (employee_id, office_id),
                )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    print(f"Sites for {employee_id} set to {', '.join(sites)}.")


def roster_offices(site_value, configured_offices):
    site_names = [site.strip().upper() for site in site_value.split(",")]
    if not site_names or any(not site for site in site_names):
        raise ValueError(f"Employee SITE value is invalid: {site_value!r}.")
    unknown_names = set(site_names) - set(ROSTER_SITES)
    if unknown_names:
        raise ValueError(f"Unrecognized roster sites: {', '.join(sorted(unknown_names))}.")
    office_ids = [ROSTER_SITES[site] for site in site_names]
    if len(set(office_ids)) != len(office_ids):
        raise ValueError(f"Employee SITE value contains duplicate sites: {site_value!r}.")
    configured_ids = {office["id"] for office in configured_offices}
    missing = set(office_ids) - configured_ids
    if missing:
        raise ValueError(
            "Add these office IDs to OFFICE_LOCATIONS_JSON before importing: "
            + ", ".join(sorted(missing))
            + "."
        )
    return office_ids


def prompt_password(employee_id):
    password = getpass.getpass(f"New password for {employee_id} (12+ characters): ")
    confirmation = getpass.getpass("Confirm password: ")
    if len(password) < 12:
        raise ValueError("Password must contain at least 12 characters.")
    if len(password.encode("utf-8")) > 72:
        raise ValueError("Password must not exceed 72 UTF-8 bytes.")
    if password != confirmation:
        raise ValueError("Passwords do not match.")
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("ascii")


def import_roster(workbook, offices, preview=False):
    roster = read_employee_roster(workbook)
    prepared = []
    for row in roster:
        employee_id = row["employee_id"]
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", employee_id):
            raise ValueError(f"Invalid employee ID in roster: {employee_id!r}.")
        prepared.append(
            (employee_id, roster_offices(row["site"], offices))
        )

    if preview:
        print(f"Roster is valid: {len(prepared)} employee IDs and all sites are configured.")
        return

    connection = get_connection()
    created = 0
    updated = 0
    for employee_id, site_ids in prepared:
        password_hash = None
        flexible_shift = bool({"kpl", "kpl-stp"} & set(site_ids))
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT active FROM employees WHERE employee_id = %s",
                (employee_id,),
            )
            employee = cursor.fetchone()
        if employee and not employee["active"]:
            raise ValueError(f"Employee {employee_id} is inactive; roster import stopped.")
        if not employee:
            password_hash = prompt_password(employee_id)

        try:
            with connection.cursor() as cursor:
                if not employee:
                    cursor.execute(
                        "INSERT INTO employees (employee_id, password_hash) VALUES (%s, %s)",
                        (employee_id, password_hash),
                    )
                cursor.execute(
                    "DELETE FROM employee_offices WHERE employee_id = %s",
                    (employee_id,),
                )
                if flexible_shift:
                    cursor.execute(
                        "DELETE FROM employee_shifts WHERE employee_id = %s",
                        (employee_id,),
                    )
                for office_id in site_ids:
                    cursor.execute(
                        "INSERT INTO employee_offices (employee_id, office_id) VALUES (%s, %s)",
                        (employee_id, office_id),
                    )
                if flexible_shift:
                    for day in range(7):
                        cursor.execute(
                            """INSERT INTO employee_shifts
                               (employee_id, day_of_week, shift_start, shift_end)
                               VALUES (%s, %s, NULL, NULL)""",
                            (employee_id, day),
                        )
            connection.commit()
        except Exception:
            connection.rollback()
            raise

        if employee:
            updated += 1
            print(f"Updated assigned sites for {employee_id}; password unchanged.")
        else:
            created += 1
            print(f"Created {employee_id} at {', '.join(site_ids)}.")

    print(f"Roster import complete: {created} created, {updated} existing accounts updated.")


def set_shift(employee_id, days, shift_start, shift_end):
    if shift_start == shift_end:
        raise ValueError("Shift start and end cannot be the same time.")
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT employee_id FROM employees WHERE employee_id = %s AND active = TRUE",
                (employee_id,),
            )
            if not cursor.fetchone():
                raise ValueError(f"Active employee {employee_id} was not found.")
            for day in days:
                cursor.execute(
                    """INSERT INTO employee_shifts
                       (employee_id, day_of_week, shift_start, shift_end)
                       VALUES (%s, %s, %s, %s)
                       ON CONFLICT (employee_id, day_of_week) DO UPDATE SET
                         shift_start = EXCLUDED.shift_start,
                         shift_end = EXCLUDED.shift_end""",
                    (employee_id, day, shift_start, shift_end),
                )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    print(f"Shift assigned to {employee_id}: {shift_start}-{shift_end}.")


def set_role(employee_id, role):
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT employee_id FROM employees WHERE employee_id = %s AND active = TRUE",
                (employee_id,),
            )
            if not cursor.fetchone():
                raise ValueError(f"Active employee {employee_id} was not found.")
            if role == "employee":
                cursor.execute(
                    "DELETE FROM employee_roles WHERE employee_id = %s",
                    (employee_id,),
                )
            else:
                cursor.execute(
                    """INSERT INTO employee_roles (employee_id, role) VALUES (%s, %s)
                       ON CONFLICT (employee_id) DO UPDATE SET role = EXCLUDED.role""",
                    (employee_id, role),
                )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    print(f"Role for {employee_id} set to {role}.")


def main(argv=None):
    load_dotenv()
    args = build_parser().parse_args(argv)
    app = create_app()
    with app.app_context():
        if args.command == "init-db":
            if not app.config["PG_MIGRATION_USER"] or not app.config["PG_MIGRATION_PASSWORD"]:
                raise ValueError("Set PG_MIGRATION_USER and PG_MIGRATION_PASSWORD in .env.")
            connection = connect(app.config, migration=True)
            try:
                init_db(connection)
                print("PostgreSQL schema is up to date.")
            finally:
                connection.close()
        elif args.command == "create-employee":
            create_employee(
                args.employee_id,
                args.days,
                args.shift_start,
                args.shift_end,
                args.sites,
                app.config["OFFICES"],
                args.no_shift,
                args.flexible_shift,
            )
        elif args.command == "set-sites":
            set_sites(args.employee_id, args.sites, app.config["OFFICES"])
        elif args.command == "import-roster":
            import_roster(args.workbook, app.config["OFFICES"], args.preview)
        elif args.command == "set-shift":
            set_shift(args.employee_id, args.days, args.shift_start, args.shift_end)
        elif args.command == "set-role":
            set_role(args.employee_id, args.role)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Command failed: {error}", file=sys.stderr)
        raise SystemExit(1)
