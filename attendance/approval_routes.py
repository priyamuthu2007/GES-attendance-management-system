from flask import current_app, jsonify, request

from . import db
from .attendance_routes import get_shift
from .time_utils import local_now, local_time_string, time_string, utc_for_database


def create_exception_request(config, employee_id):
    payload = request.get_json(silent=True) or {}
    reason = payload.get("reason") if isinstance(payload, dict) else None
    if not isinstance(reason, str) or not 10 <= len(reason.strip()) <= 500:
        return jsonify(error="Enter a reason between 10 and 500 characters."), 400
    reason = reason.strip()

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
                """SELECT * FROM attendance
                   WHERE employee_id = %s AND check_out_at IS NULL
                   ORDER BY attendance_date DESC LIMIT 1 FOR UPDATE""",
                (employee_id,),
            )
            open_record = cursor.fetchone()
            if open_record:
                action = "check-out"
                attendance_date = open_record["attendance_date"]
                shift_start = open_record["shift_start"]
                shift_end = open_record["shift_end"]
            else:
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
                    return jsonify(error="No shift is assigned for today."), 409
                action = "check-in"
                attendance_date = now.date()
                shift_start = shift["start"]
                shift_end = shift["end"]

            cursor.execute(
                """SELECT request_id FROM attendance_exception_requests
                   WHERE employee_id = %s AND attendance_date = %s
                     AND action = %s AND status = 'pending'
                   LIMIT 1""",
                (employee_id, attendance_date, action),
            )
            if cursor.fetchone():
                connection.rollback()
                return jsonify(error="A request for this attendance action is already pending."), 409

            cursor.execute(
                """INSERT INTO attendance_exception_requests
                   (employee_id, attendance_date, action, requested_at, shift_start,
                    shift_end, reason)
                   VALUES (%s, %s, %s, %s, %s, %s, %s)""",
                (
                    employee_id,
                    attendance_date,
                    action,
                    utc_for_database(now),
                    shift_start,
                    shift_end,
                    reason,
                ),
            )
            request_id = cursor.lastrowid
            connection.commit()
        return jsonify(
            request={
                "requestId": request_id,
                "action": action,
                "status": "pending",
                "reason": reason,
            },
            message="Your request was sent to a manager for review.",
        ), 201
    except Exception:
        connection.rollback()
        current_app.logger.exception("Could not save an attendance exception request.")
        return jsonify(error="Your request could not be saved. Please try again."), 500


def list_manager_requests(time_zone):
    connection = db.get_connection()
    with connection.cursor() as cursor:
        cursor.execute(
            """SELECT r.request_id, r.employee_id, r.attendance_date, r.action,
                      r.requested_at, r.shift_start, r.shift_end, r.reason,
                      r.status, r.manager_id, r.decided_at, r.decision_note,
                      e.active
               FROM attendance_exception_requests AS r
               JOIN employees AS e ON e.employee_id = r.employee_id
               ORDER BY (r.status = 'pending') DESC, r.created_at DESC
               LIMIT 100"""
        )
        rows = cursor.fetchall()
    return jsonify(
        requests=[
            {
                "requestId": row["request_id"],
                "employeeId": row["employee_id"],
                "employeeActive": bool(row["active"]),
                "attendanceDate": row["attendance_date"].isoformat(),
                "action": row["action"],
                "requestedAt": local_time_string(row["requested_at"], time_zone),
                "shift": {
                    "start": time_string(row["shift_start"]),
                    "end": time_string(row["shift_end"]),
                },
                "reason": row["reason"],
                "status": row["status"],
                "managerId": row["manager_id"],
                "decidedAt": (
                    local_time_string(row["decided_at"], time_zone)
                    if row["decided_at"]
                    else None
                ),
                "decisionNote": row["decision_note"],
            }
            for row in rows
        ]
    )


def decide_exception_request(config, manager_id, request_id):
    payload = request.get_json(silent=True) or {}
    if not isinstance(payload, dict):
        payload = {}
    decision = payload.get("decision")
    note = payload.get("note", "")
    if decision not in {"approved", "rejected"}:
        return jsonify(error="Choose approve or reject."), 400
    if not isinstance(note, str) or len(note.strip()) > 500:
        return jsonify(error="The decision note must be 500 characters or fewer."), 400
    note = note.strip() or None

    connection = db.get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """SELECT * FROM attendance_exception_requests
                   WHERE request_id = %s""",
                (request_id,),
            )
            approval_request = cursor.fetchone()
            if not approval_request:
                connection.rollback()
                return jsonify(error="The request was not found."), 404

            cursor.execute(
                "SELECT employee_id, active FROM employees WHERE employee_id = %s FOR UPDATE",
                (approval_request["employee_id"],),
            )
            employee = cursor.fetchone()
            if not employee:
                connection.rollback()
                return jsonify(error="The employee account was not found."), 409
            if not employee["active"] and decision == "approved":
                connection.rollback()
                return jsonify(error="Inactive employee accounts cannot receive attendance approvals."), 409

            cursor.execute(
                """SELECT * FROM attendance_exception_requests
                   WHERE request_id = %s FOR UPDATE""",
                (request_id,),
            )
            approval_request = cursor.fetchone()
            if not approval_request or approval_request["status"] != "pending":
                connection.rollback()
                return jsonify(error="This request has already been reviewed."), 409

            attendance_id = None
            if decision == "approved":
                if approval_request["action"] == "check-in":
                    cursor.execute(
                        """SELECT attendance_id FROM attendance
                           WHERE employee_id = %s AND check_out_at IS NULL
                           ORDER BY attendance_date DESC LIMIT 1 FOR UPDATE""",
                        (approval_request["employee_id"],),
                    )
                    if cursor.fetchone():
                        connection.rollback()
                        return jsonify(error="The employee already has an open check-in."), 409
                    cursor.execute(
                        """SELECT attendance_id FROM attendance
                           WHERE employee_id = %s AND attendance_date = %s LIMIT 1 FOR UPDATE""",
                        (approval_request["employee_id"], approval_request["attendance_date"]),
                    )
                    if cursor.fetchone():
                        connection.rollback()
                        return jsonify(error="Attendance already exists for that date."), 409
                    cursor.execute(
                        """INSERT INTO attendance
                           (employee_id, attendance_date, shift_start, shift_end, check_in_at,
                            check_in_latitude, check_in_longitude, check_in_accuracy_meters,
                            check_in_distance_meters, check_in_office_id, check_in_office_name,
                            check_in_source)
                           VALUES (%s, %s, %s, %s, %s, NULL, NULL, NULL, NULL,
                                   'manual', 'Manually approved', 'manual_approval')""",
                        (
                            approval_request["employee_id"],
                            approval_request["attendance_date"],
                            approval_request["shift_start"],
                            approval_request["shift_end"],
                            approval_request["requested_at"],
                        ),
                    )
                    attendance_id = cursor.lastrowid
                else:
                    cursor.execute(
                        """SELECT * FROM attendance
                           WHERE employee_id = %s AND check_out_at IS NULL
                           ORDER BY attendance_date DESC LIMIT 1 FOR UPDATE""",
                        (approval_request["employee_id"],),
                    )
                    open_record = cursor.fetchone()
                    if not open_record:
                        connection.rollback()
                        return jsonify(error="There is no open check-in to close."), 409
                    if approval_request["requested_at"] <= open_record["check_in_at"]:
                        connection.rollback()
                        return jsonify(error="The requested check-out time is before check-in."), 409
                    attendance_id = open_record["attendance_id"]
                    cursor.execute(
                        """UPDATE attendance
                           SET check_out_at = %s, check_out_latitude = NULL,
                               check_out_longitude = NULL, check_out_accuracy_meters = NULL,
                               check_out_distance_meters = NULL, check_out_office_id = 'manual',
                               check_out_office_name = 'Manually approved',
                               check_out_source = 'manual_approval'
                           WHERE attendance_id = %s AND check_out_at IS NULL""",
                        (approval_request["requested_at"], attendance_id),
                    )
                    if cursor.rowcount != 1:
                        connection.rollback()
                        return jsonify(error="Attendance has already been checked out."), 409

            cursor.execute(
                """UPDATE attendance_exception_requests
                   SET status = %s, manager_id = %s, decided_at = UTC_TIMESTAMP(),
                       decision_note = %s, attendance_id = %s
                   WHERE request_id = %s AND status = 'pending'""",
                (decision, manager_id, note, attendance_id, request_id),
            )
            if cursor.rowcount != 1:
                connection.rollback()
                return jsonify(error="This request has already been reviewed."), 409
            connection.commit()
        return jsonify(message=f"Request {decision}.", status=decision)
    except Exception:
        connection.rollback()
        current_app.logger.exception("Could not record an attendance exception decision.")
        return jsonify(error="The decision could not be saved. Please try again."), 500
