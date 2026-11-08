from flask import current_app, jsonify, request

from . import db
from .geofence import validate_location
from .time_utils import local_now, local_time_string, time_string, utc_for_database


def get_shift(cursor, employee_id, day_of_week):
    cursor.execute(
        """SELECT day_of_week, shift_start, shift_end
           FROM employee_shifts
           WHERE employee_id = %s AND day_of_week = %s""",
        (employee_id, day_of_week),
    )
    shift = cursor.fetchone()
    if not shift:
        return None
    return {
        "dayOfWeek": shift["day_of_week"],
        "start": time_string(shift["shift_start"]),
        "end": time_string(shift["shift_end"]),
    }


def attendance_to_json(record, time_zone):
    if not record:
        return None
    return {
        "attendanceDate": record["attendance_date"].isoformat(),
        "checkInAt": local_time_string(record["check_in_at"], time_zone),
        "checkInOffice": record["check_in_office_name"],
        "checkInDistanceMeters": float(record["check_in_distance_meters"]),
        "checkOutAt": local_time_string(record["check_out_at"], time_zone),
        "checkOutOffice": record["check_out_office_name"],
        "checkOutDistanceMeters": (
            float(record["check_out_distance_meters"])
            if record["check_out_distance_meters"] is not None
            else None
        ),
        "shift": {
            "start": time_string(record["shift_start"]),
            "end": time_string(record["shift_end"]),
        },
    }


def get_today_state(time_zone, offices):
    employee_id = request_employee_id()
    today = local_now(time_zone).date()
    connection = db.get_connection()
    with connection.cursor() as cursor:
        shift = get_shift(cursor, employee_id, today.weekday())
        cursor.execute(
            """SELECT * FROM attendance
               WHERE employee_id = %s AND attendance_date = %s""",
            (employee_id, today),
        )
        record = cursor.fetchone()
        if not record:
            cursor.execute(
                """SELECT * FROM attendance
                   WHERE employee_id = %s AND check_out_at IS NULL
                   ORDER BY attendance_date DESC LIMIT 1""",
                (employee_id,),
            )
            record = cursor.fetchone()
    return {
        "employeeId": employee_id,
        "shift": shift,
        "attendance": attendance_to_json(record, time_zone),
        "timeZone": time_zone,
        "offices": [
            {"id": office["id"], "name": office["name"],
             "latitude": office["latitude"], "longitude": office["longitude"]}
            for office in offices
        ],
        "attendanceRadiusMeters": 50,
        "maxGpsAccuracyMeters": 25,
    }


def request_employee_id():
    from flask import session

    return session["employee_id"]


def create_check_in(config, employee_id):
    payload = request.get_json(silent=True) or {}
    if not isinstance(payload, dict):
        payload = {}
    office, error = validate_location(payload, config["OFFICES"])
    if error:
        return jsonify(error[0]), error[1]

    now = local_now(config["OFFICE_TIMEZONE"])
    connection = db.get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT employee_id FROM employees WHERE employee_id = %s AND active = 1 FOR UPDATE",
                (employee_id,),
            )
            if not cursor.fetchone():
                connection.rollback()
                return jsonify(error="Employee account is inactive."), 403

            cursor.execute(
                """SELECT attendance_id FROM attendance
                   WHERE employee_id = %s AND check_out_at IS NULL
                   ORDER BY attendance_date DESC LIMIT 1 FOR UPDATE""",
                (employee_id,),
            )
            if cursor.fetchone():
                connection.rollback()
                return jsonify(error="Check out from your previous attendance before checking in again."), 409

            cursor.execute(
                """SELECT attendance_id FROM attendance
                   WHERE employee_id = %s AND attendance_date = %s LIMIT 1""",
                (employee_id, now.date()),
            )
            if cursor.fetchone():
                connection.rollback()
                return jsonify(error="Attendance is already complete for today."), 409

            shift = get_shift(cursor, employee_id, now.weekday())
            if not shift:
                connection.rollback()
                return jsonify(error="No shift is assigned for today. Contact your administrator."), 409

            cursor.execute(
                """INSERT INTO attendance
                   (employee_id, attendance_date, shift_start, shift_end, check_in_at,
                    check_in_latitude, check_in_longitude, check_in_accuracy_meters,
                    check_in_distance_meters, check_in_office_id, check_in_office_name)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (
                    employee_id,
                    now.date(),
                    shift["start"],
                    shift["end"],
                    utc_for_database(now),
                    payload["latitude"],
                    payload["longitude"],
                    office["accuracyMeters"],
                    office["distanceMeters"],
                    office["id"],
                    office["name"],
                ),
            )
            attendance_id = cursor.lastrowid
            connection.commit()
            cursor.execute("SELECT * FROM attendance WHERE attendance_id = %s", (attendance_id,))
            record = cursor.fetchone()
        return jsonify(
            attendance=attendance_to_json(record, config["OFFICE_TIMEZONE"]),
            message="Check-in recorded.",
        ), 201
    except Exception:
        connection.rollback()
        current_app.logger.exception("Could not save employee check-in.")
        return jsonify(error="Check-in could not be saved. Please try again."), 500


def create_check_out(config, employee_id):
    payload = request.get_json(silent=True) or {}
    if not isinstance(payload, dict):
        payload = {}
    office, error = validate_location(payload, config["OFFICES"])
    if error:
        return jsonify(error[0]), error[1]

    connection = db.get_connection()
    now = local_now(config["OFFICE_TIMEZONE"])
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT employee_id FROM employees WHERE employee_id = %s AND active = 1 FOR UPDATE",
                (employee_id,),
            )
            if not cursor.fetchone():
                connection.rollback()
                return jsonify(error="Employee account is inactive."), 403

            cursor.execute(
                """SELECT * FROM attendance
                   WHERE employee_id = %s AND check_out_at IS NULL
                   ORDER BY attendance_date DESC LIMIT 1 FOR UPDATE""",
                (employee_id,),
            )
            record = cursor.fetchone()
            if not record:
                connection.rollback()
                return jsonify(error="No open check-in was found to check out from."), 409

            cursor.execute(
                """UPDATE attendance
                   SET check_out_at = %s, check_out_latitude = %s, check_out_longitude = %s,
                       check_out_accuracy_meters = %s, check_out_distance_meters = %s,
                       check_out_office_id = %s, check_out_office_name = %s
                   WHERE attendance_id = %s AND check_out_at IS NULL""",
                (
                    utc_for_database(now),
                    payload["latitude"],
                    payload["longitude"],
                    office["accuracyMeters"],
                    office["distanceMeters"],
                    office["id"],
                    office["name"],
                    record["attendance_id"],
                ),
            )
            if cursor.rowcount != 1:
                connection.rollback()
                return jsonify(error="Attendance has already been checked out."), 409
            connection.commit()
            cursor.execute(
                "SELECT * FROM attendance WHERE attendance_id = %s",
                (record["attendance_id"],),
            )
            updated = cursor.fetchone()
        return jsonify(
            attendance=attendance_to_json(updated, config["OFFICE_TIMEZONE"]),
            message="Check-out recorded.",
        )
    except Exception:
        connection.rollback()
        current_app.logger.exception("Could not save employee check-out.")
        return jsonify(error="Check-out could not be saved. Please try again."), 500
