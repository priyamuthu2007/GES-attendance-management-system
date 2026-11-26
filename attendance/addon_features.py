import csv
import io
import json
import math
import re
import time
from datetime import date, datetime, timezone
from functools import wraps

import bcrypt
from flask import (
    Blueprint,
    Response,
    current_app,
    g,
    jsonify,
    redirect,
    render_template,
    request,
    session,
)

from . import db, limiter
from .geofence import (
    ATTENDANCE_RADIUS_METERS,
    MAX_GPS_ACCURACY_METERS,
    nearest_office,
    valid_coordinate,
)
from .time_utils import local_now, local_time_string, time_string


bp = Blueprint("addon_features", __name__)
ROLES = ("admin", "manager", "hr", "auditor", "employee")
WEEKDAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}
EMPLOYEE_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
TIME_PATTERN = re.compile(r"^(?:[01]\d|2[0-3]):[0-5]\d$")
started_at = time.monotonic()


def audit_action(connection, actor_id, actor_role, action, entity_type, entity_id=None, details=None):
    with connection.cursor() as cursor:
        cursor.execute(
            """INSERT INTO audit_logs
               (actor_employee_id, actor_role, action, entity_type, entity_id, details)
               VALUES (%s, %s, %s, %s, %s, %s)""",
            (
                actor_id,
                actor_role,
                action,
                entity_type,
                str(entity_id) if entity_id is not None else None,
                json.dumps(details, ensure_ascii=False, default=str) if details else None,
            ),
        )


def current_role():
    employee_id = session.get("employee_id")
    if not employee_id:
        return None

    with db.get_connection().cursor() as cursor:
        cursor.execute(
            """SELECT e.active, COALESCE(r.role, 'employee') AS role
               FROM employees AS e
               LEFT JOIN employee_roles AS r ON r.employee_id = e.employee_id
               WHERE e.employee_id = %s""",
            (employee_id,),
        )
        employee = cursor.fetchone()

    if not employee or not employee["active"]:
        session.clear()
        return None
    g.employee_id = employee_id
    g.employee_role = employee["role"]
    return employee["role"]


def roles_required(*allowed_roles):
    def decorate(view):
        @wraps(view)
        def wrapped(*args, **kwargs):
            role = current_role()
            if role is None:
                return jsonify(error="Please sign in to continue."), 401
            if role not in allowed_roles:
                return jsonify(error="You are not allowed to perform this action."), 403
            return view(*args, **kwargs)

        return wrapped

    return decorate


def _payload():
    payload = request.get_json(silent=True)
    return payload if isinstance(payload, dict) else None


def _valid_time(value):
    return isinstance(value, str) and TIME_PATTERN.fullmatch(value) is not None


def _csv_safe(value):
    if value is None:
        return ""
    text = str(value)
    if text.startswith(("=", "+", "-", "@", "\t", "\r")):
        return "'" + text
    return text


@bp.get("/api/auth/session")
@roles_required(*ROLES)
def auth_session():
    return jsonify(employeeId=g.employee_id, role=g.employee_role)


@bp.get("/attendance-report")
def attendance_report_page():
    if current_role() not in ("admin", "hr", "auditor"):
        return redirect("/")
    return render_template("attendance_report.html")


@bp.get("/api/attendance/report")
@roles_required("admin", "hr", "auditor")
def attendance_report():
    date_value = request.args.get("date", "")
    if date_value:
        try:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_value):
                raise ValueError
            selected_date = date.fromisoformat(date_value)
        except ValueError:
            return jsonify(error="Provide date as YYYY-MM-DD."), 400
    else:
        selected_date = local_now(current_app.config["OFFICE_TIMEZONE"]).date()

    connection = db.get_connection()
    with connection.cursor() as cursor:
        cursor.execute(
            """SELECT e.employee_id, p.full_name, s.day_of_week AS shift_day,
                      s.shift_start, s.shift_end, a.check_in_at, a.check_out_at
               FROM employees AS e
               LEFT JOIN employee_profiles AS p ON p.employee_id = e.employee_id
               LEFT JOIN employee_shifts AS s
                 ON s.employee_id = e.employee_id AND s.day_of_week = %s
               LEFT JOIN attendance AS a
                 ON a.employee_id = e.employee_id AND a.attendance_date = %s
               WHERE e.active = TRUE
               ORDER BY e.employee_id""",
            (selected_date.weekday(), selected_date),
        )
        rows = cursor.fetchall()

    time_zone = current_app.config["OFFICE_TIMEZONE"]
    employees = []
    for row in rows:
        check_in = local_time_string(row["check_in_at"], time_zone)
        check_out = local_time_string(row["check_out_at"], time_zone)
        employees.append(
            {
                "employeeId": row["employee_id"],
                "fullName": row["full_name"],
                "shiftStart": time_string(row["shift_start"]) if row["shift_start"] else None,
                "shiftEnd": time_string(row["shift_end"]) if row["shift_end"] else None,
                "flexibleShift": (
                    row["shift_day"] is not None
                    and row["shift_start"] is None
                    and row["shift_end"] is None
                ),
                "checkInAt": check_in,
                "checkOutAt": check_out,
                "status": (
                    "not_checked_in"
                    if check_in is None
                    else "checked_in"
                    if check_out is None
                    else "complete"
                ),
            }
        )

    audit_action(
        connection,
        g.employee_id,
        g.employee_role,
        "attendance_report_view",
        "attendance",
        None,
        {"date": selected_date.isoformat(), "employees": len(employees)},
    )
    connection.commit()
    return jsonify(
        date=selected_date.isoformat(),
        timeZone=time_zone,
        employees=employees,
    )


@bp.post("/api/accounts")
@limiter.limit("5 per hour")
@roles_required("admin", "hr")
def create_account():
    payload = _payload()
    if payload is None:
        return jsonify(error="A JSON object is required."), 400

    employee_id = payload.get("username")
    full_name = payload.get("full_name")
    password = payload.get("password")
    role = payload.get("role", "employee")
    days = payload.get("days")
    shift_start = payload.get("shift_start")
    shift_end = payload.get("shift_end")
    sites = payload.get("sites")

    if (
        not isinstance(employee_id, str)
        or not EMPLOYEE_ID_PATTERN.fullmatch(employee_id.strip())
        or not isinstance(full_name, str)
        or not full_name.strip()
        or len(full_name.strip()) > 160
        or not isinstance(password, str)
        or len(password) < 12
        or len(password.encode("utf-8")) > 72
    ):
        return jsonify(error="Provide a valid username, full name, and a 12–72 byte password."), 400
    if role not in ROLES:
        return jsonify(error="Invalid account role."), 400
    if g.employee_role != "admin" and role != "employee":
        return jsonify(error="Only an admin can assign a non-employee role."), 403
    available_sites = {office["id"] for office in current_app.config["OFFICES"]}
    if (
        not isinstance(sites, list)
        or not sites
        or any(not isinstance(site, str) or site not in available_sites for site in sites)
        or len(set(sites)) != len(sites)
    ):
        return jsonify(error="Assign the employee to one or more registered office sites."), 400
    if (
        not isinstance(days, list)
        or not days
        or any(not isinstance(day, str) or day.lower() not in WEEKDAYS for day in days)
        or len({day.lower() for day in days}) != len(days)
        or not _valid_time(shift_start)
        or not _valid_time(shift_end)
        or shift_start == shift_end
    ):
        return jsonify(error="Provide unique working days and valid, different shift times."), 400

    employee_id = employee_id.strip()
    full_name = full_name.strip()
    password_hash = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("ascii")
    connection = db.get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "INSERT INTO employees (employee_id, password_hash) VALUES (%s, %s)",
                (employee_id, password_hash),
            )
            cursor.execute(
                "INSERT INTO employee_profiles (employee_id, full_name) VALUES (%s, %s)",
                (employee_id, full_name),
            )
            cursor.execute(
                "INSERT INTO employee_roles (employee_id, role) VALUES (%s, %s)",
                (employee_id, role),
            )
            for office_id in sites:
                cursor.execute(
                    "INSERT INTO employee_offices (employee_id, office_id) VALUES (%s, %s)",
                    (employee_id, office_id),
                )
            for day in days:
                cursor.execute(
                    """INSERT INTO employee_shifts
                       (employee_id, day_of_week, shift_start, shift_end)
                       VALUES (%s, %s, %s, %s)""",
                    (employee_id, WEEKDAYS[day.lower()], shift_start, shift_end),
                )
        audit_action(
            connection,
            g.employee_id,
            g.employee_role,
            "account_created",
            "employee",
            employee_id,
            {"role": role, "days": [day.lower() for day in days]},
        )
        connection.commit()
    except Exception:
        connection.rollback()
        raise

    return jsonify(username=employee_id, full_name=full_name, role=role), 201


@bp.get("/api/audit-logs")
@roles_required("admin", "auditor")
def audit_logs():
    with db.get_connection().cursor() as cursor:
        cursor.execute(
            """SELECT audit_id, actor_employee_id, actor_role, action, entity_type,
                      entity_id, details, created_at
               FROM audit_logs ORDER BY audit_id DESC LIMIT 500"""
        )
        rows = cursor.fetchall()
    return jsonify(
        [
            {
                "id": row["audit_id"],
                "actor": row["actor_employee_id"],
                "role": row["actor_role"],
                "action": row["action"],
                "entityType": row["entity_type"],
                "entityId": row["entity_id"],
                "details": row["details"],
                "createdAt": row["created_at"].isoformat(sep=" "),
            }
            for row in rows
        ]
    )


@bp.post("/api/validate-office-location")
@limiter.limit("30 per minute")
@roles_required(*ROLES)
def validate_office_location():
    payload = _payload()
    if payload is None:
        return jsonify(error="A JSON object is required."), 400

    latitude = payload.get("latitude")
    longitude = payload.get("longitude")
    accuracy = payload.get("accuracyMeters", payload.get("accuracy"))
    if not valid_coordinate(latitude, longitude):
        return jsonify(error="Valid latitude and longitude are required."), 400
    if (
        isinstance(accuracy, bool)
        or not isinstance(accuracy, (int, float))
        or not math.isfinite(accuracy)
        or accuracy < 0
    ):
        return jsonify(error="A valid GPS accuracy value is required."), 400
    offices = current_app.config["OFFICES"]
    if not offices:
        return jsonify(error="No office locations are configured."), 503

    nearest = nearest_office(latitude, longitude, offices)
    allowed = (
        accuracy <= MAX_GPS_ACCURACY_METERS
        and nearest["distanceMeters"] + accuracy <= ATTENDANCE_RADIUS_METERS
    )
    connection = db.get_connection()
    audit_action(
        connection,
        g.employee_id,
        g.employee_role,
        "location_validation",
        "office",
        nearest["id"],
        {
            "allowed": allowed,
            "distance_m": round(nearest["distanceMeters"], 2),
            "accuracy_m": accuracy,
        },
    )
    connection.commit()
    return jsonify(
        allowed=allowed,
        distance_m=round(nearest["distanceMeters"], 2),
        accuracy_m=accuracy,
        radius_m=ATTENDANCE_RADIUS_METERS,
        office=nearest["name"],
    )


@bp.post("/api/location-risk-check")
@limiter.limit("30 per minute")
@roles_required(*ROLES)
def location_risk_check():
    payload = _payload()
    if payload is None:
        return jsonify(error="A JSON object is required."), 400

    signals = []
    if not valid_coordinate(payload.get("latitude"), payload.get("longitude")):
        signals.append("invalid_coordinates")

    accuracy = payload.get("accuracy", payload.get("accuracyMeters"))
    if (
        isinstance(accuracy, bool)
        or not isinstance(accuracy, (int, float))
        or not math.isfinite(accuracy)
        or accuracy <= 0
        or accuracy > 500
    ):
        signals.append("poor_accuracy")
    if payload.get("mock_location") is True:
        signals.append("client_reports_mock_location")

    timestamp = payload.get("timestamp")
    if (
        isinstance(timestamp, bool)
        or not isinstance(timestamp, (int, float))
        or not math.isfinite(timestamp)
        or abs(time.time() * 1000 - timestamp) > 5 * 60 * 1000
    ):
        signals.append("missing_or_stale_timestamp")

    serialized_signals = json.dumps(signals)
    connection = db.get_connection()
    with connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO location_risk_events (employee_id, signals) VALUES (%s, %s)",
            (g.employee_id, serialized_signals),
        )
    audit_action(
        connection,
        g.employee_id,
        g.employee_role,
        "location_risk_check",
        "location",
        None,
        {"signals": signals},
    )
    connection.commit()
    return jsonify(
        review_required=bool(signals),
        signals=signals,
        limitation="Browser GPS and client-reported flags cannot prove a device is not spoofed.",
    )


@bp.get("/api/reports/attendance.csv")
@roles_required("admin", "hr", "auditor")
def attendance_csv():
    start_value = request.args.get("start_date", "")
    end_value = request.args.get("end_date", "")
    try:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", start_value) or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}", end_value
        ):
            raise ValueError
        start = date.fromisoformat(start_value)
        end = date.fromisoformat(end_value)
    except ValueError:
        return jsonify(error="Provide start_date and end_date as YYYY-MM-DD."), 400
    if end < start:
        return jsonify(error="end_date must be on or after start_date."), 400
    if (end - start).days > 366:
        return jsonify(error="The report range must not exceed 366 days."), 400

    connection = db.get_connection()
    with connection.cursor() as cursor:
        cursor.execute(
            """SELECT a.employee_id, p.full_name, a.attendance_date,
                      a.check_in_at, a.check_out_at
               FROM attendance AS a
               LEFT JOIN employee_profiles AS p ON p.employee_id = a.employee_id
               WHERE a.attendance_date BETWEEN %s AND %s
               ORDER BY a.attendance_date, a.employee_id""",
            (start, end),
        )
        rows = cursor.fetchall()

    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(
        ["employee_id", "full_name", "date", "check_in_utc", "check_out_utc", "status"]
    )
    for row in rows:
        writer.writerow(
            [
                _csv_safe(row["employee_id"]),
                _csv_safe(row["full_name"]),
                row["attendance_date"].isoformat(),
                row["check_in_at"].isoformat(sep=" "),
                row["check_out_at"].isoformat(sep=" ") if row["check_out_at"] else "",
                "complete" if row["check_out_at"] else "incomplete",
            ]
        )
    audit_action(
        connection,
        g.employee_id,
        g.employee_role,
        "attendance_csv_export",
        "attendance",
        None,
        {"from": start_value, "to": end_value, "rows": len(rows)},
    )
    connection.commit()
    return Response(
        output.getvalue(),
        mimetype="text/csv",
        headers={"Content-Disposition": "attachment; filename=attendance_report.csv"},
    )


@bp.get("/location-notice")
def location_notice():
    return render_template("location_notice.html")


@bp.get("/health")
def health():
    try:
        with db.get_connection().cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
    except Exception:
        current_app.logger.exception("Add-on health check could not reach PostgreSQL.")
        return jsonify(status="degraded", database="unavailable"), 503
    return jsonify(
        status="ok",
        database="ok",
        uptime_seconds=round(time.monotonic() - started_at, 1),
    )
