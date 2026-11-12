import unittest
from datetime import datetime, time, timezone
from unittest.mock import patch

from attendance import create_app


class FakeCursor:
    def __init__(self, connection):
        self.connection = connection
        self.result = None
        self.lastrowid = None
        self.rowcount = 0

    def __enter__(self):
        return self

    def __exit__(self, _exc_type, _exc_value, _traceback):
        return None

    def execute(self, query, params):
        if "FROM managers" in query:
            self.result = {"manager_id": "MANAGER-1"}
        elif "SELECT * FROM attendance_exception_requests" in query:
            self.result = self.connection.exception_record
        elif "UPDATE attendance_exception_requests" in query:
            self.connection.exception_record.update(
                {
                    "status": params[0],
                    "manager_id": params[1],
                    "decision_note": params[2],
                    "attendance_id": params[3],
                }
            )
            self.rowcount = 1
        elif "FROM employees" in query:
            self.result = {"employee_id": "EMPLOYEE-1", "active": True}
        elif "INSERT INTO attendance_exception_requests" in query:
            self.connection.exception_request = params
            self.lastrowid = 7
            self.rowcount = 1
        elif "FROM employee_shifts" in query:
            self.result = (
                {
                    "day_of_week": datetime.now().weekday(),
                    "shift_start": time(9, 0),
                    "shift_end": time(17, 0),
                }
                if self.connection.has_shift
                else None
            )
        elif "SELECT attendance_id FROM attendance" in query:
            matching_record = self.connection.record
            if "attendance_date = %s" in query:
                matching_record = (
                    matching_record
                    if matching_record
                    and matching_record["attendance_date"] == params[1]
                    else None
                )
            elif matching_record and matching_record["check_out_at"]:
                matching_record = None
            self.result = (
                {"attendance_id": matching_record["attendance_id"]}
                if matching_record
                else None
            )
        elif "SELECT * FROM attendance" in query and "WHERE employee_id" in query:
            self.result = (
                self.connection.record
                if self.connection.record and not self.connection.record["check_out_at"]
                else None
            )
        elif "INSERT INTO attendance" in query:
            if "check_in_source" in query:
                (
                    employee_id,
                    attendance_date,
                    shift_start,
                    shift_end,
                    check_in_at,
                ) = params
                latitude = longitude = accuracy = distance = None
                office_id = "manual"
                office_name = "Manually approved"
                check_in_source = "manual_approval"
            else:
                (
                    employee_id,
                    attendance_date,
                    shift_start,
                    shift_end,
                    check_in_at,
                    latitude,
                    longitude,
                    accuracy,
                    distance,
                    office_id,
                    office_name,
                ) = params
                check_in_source = "gps"
            self.connection.record = {
                "attendance_id": 1,
                "employee_id": employee_id,
                "attendance_date": attendance_date,
                "shift_start": time.fromisoformat(shift_start) if isinstance(shift_start, str) else shift_start,
                "shift_end": time.fromisoformat(shift_end) if isinstance(shift_end, str) else shift_end,
                "check_in_at": check_in_at,
                "check_in_latitude": latitude,
                "check_in_longitude": longitude,
                "check_in_accuracy_meters": accuracy,
                "check_in_distance_meters": distance,
                "check_in_office_id": office_id,
                "check_in_office_name": office_name,
                "check_in_source": check_in_source,
                "check_out_at": None,
                "check_out_distance_meters": None,
                "check_out_office_name": None,
            }
            self.lastrowid = 1
            self.rowcount = 1
        elif query.startswith("UPDATE attendance"):
            (
                check_out_at,
                latitude,
                longitude,
                accuracy,
                distance,
                office_id,
                office_name,
                _attendance_id,
            ) = params
            self.connection.record.update(
                {
                    "check_out_at": check_out_at,
                    "check_out_latitude": latitude,
                    "check_out_longitude": longitude,
                    "check_out_accuracy_meters": accuracy,
                    "check_out_distance_meters": distance,
                    "check_out_office_id": office_id,
                    "check_out_office_name": office_name,
                }
            )
            self.rowcount = 1
        elif "SELECT * FROM attendance WHERE attendance_id" in query:
            self.result = self.connection.record
        else:
            self.result = None

    def fetchone(self):
        return self.result

    def close(self):
        return None


class FakeConnection:
    def __init__(self, record=None, has_shift=True):
        self.record = record
        self.has_shift = has_shift
        self.exception_request = None
        self.exception_record = None

    def cursor(self):
        return FakeCursor(self)

    def commit(self):
        return None

    def rollback(self):
        return None


class AppTests(unittest.TestCase):
    def setUp(self):
        self.app = create_app(
            {
                "TESTING": True,
                "SECRET_KEY": "test-only-secret",
                "WTF_CSRF_ENABLED": False,
                "OFFICE_TIMEZONE": "Asia/Kolkata",
                "OFFICES": [
                    {"id": "test", "name": "Test Office", "latitude": 0.0, "longitude": 0.0}
                ],
            }
        )
        self.client = self.app.test_client()

    def test_home_serves_plain_html_app(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"/static/styles.css", response.data)
        self.assertIn(b"/static/app.js", response.data)
        self.assertIn(b"Assigned shift", response.data)
        self.assertIn(b'id="attendance-action"', response.data)
        response.close()

    def test_home_assets_are_served_by_flask(self):
        for path in ("/static/styles.css", "/static/app.js"):
            with self.subTest(path=path):
                response = self.client.get(path)
                self.assertEqual(response.status_code, 200)
                response.close()

    def test_manager_page_uses_separate_review_portal(self):
        response = self.client.get("/manager")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"MANAGER REVIEW", response.data)
        self.assertIn(b"/static/manager.js", response.data)

    def test_health_liveness_is_available(self):
        response = self.client.get("/api/health/live")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["status"], "ok")

    def test_attendance_api_requires_employee_login(self):
        response = self.client.get("/api/attendance/today")
        self.assertEqual(response.status_code, 401)

    def test_manager_request_queue_requires_a_manager_login(self):
        response = self.client.get("/api/manager/requests")
        self.assertEqual(response.status_code, 401)

    def test_employee_exception_request_requires_employee_login(self):
        response = self.client.post(
            "/api/attendance/exception-requests",
            json={"reason": "GPS signal is weak indoors"},
        )
        self.assertEqual(response.status_code, 401)

    def test_state_changing_routes_require_csrf(self):
        self.app.config["WTF_CSRF_ENABLED"] = True
        response = self.client.post("/api/auth/login", json={"employeeId": "A", "password": "B"})
        self.assertEqual(response.status_code, 400)
        self.assertIn("Security token", response.json["error"])

    def test_check_in_rejects_inaccurate_gps_before_database_access(self):
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        with patch("attendance.db.get_connection", return_value=FakeConnection()):
            response = self.client.post(
                "/api/attendance/check-in",
                json={"latitude": 0, "longitude": 0, "accuracyMeters": 26},
            )
        self.assertEqual(response.status_code, 422)

    def test_check_in_saves_employee_shift_and_office(self):
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        connection = FakeConnection()
        with patch("attendance.db.get_connection", return_value=connection):
            response = self.client.post(
                "/api/attendance/check-in",
                json={"latitude": 0, "longitude": 0, "accuracyMeters": 5},
            )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.json["attendance"]["checkInOffice"], "Test Office")
        self.assertEqual(response.json["attendance"]["shift"], {"start": "09:00", "end": "17:00"})
        self.assertIsNone(connection.record["check_out_at"])

    def test_check_out_closes_the_open_attendance_record(self):
        self.record = {
            "attendance_id": 4,
            "employee_id": "EMPLOYEE-1",
            "attendance_date": datetime.now().date(),
            "shift_start": time(9, 0),
            "shift_end": time(17, 0),
            "check_in_at": datetime.now(timezone.utc).replace(tzinfo=None),
            "check_in_office_name": "Test Office",
            "check_in_distance_meters": 0.0,
            "check_out_at": None,
            "check_out_distance_meters": None,
            "check_out_office_name": None,
        }
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        connection = FakeConnection(record=self.record)
        with patch("attendance.db.get_connection", return_value=connection):
            response = self.client.post(
                "/api/attendance/check-out",
                json={"latitude": 0, "longitude": 0, "accuracyMeters": 5},
            )
        self.assertEqual(response.status_code, 200)
        self.assertIsNotNone(response.json["attendance"]["checkOutAt"])
        self.assertEqual(response.json["attendance"]["checkOutOffice"], "Test Office")

    def test_cannot_check_in_again_after_attendance_is_completed_today(self):
        self.record = {
            "attendance_id": 4,
            "attendance_date": datetime.now().date(),
            "check_out_at": datetime.now(timezone.utc).replace(tzinfo=None),
        }
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        connection = FakeConnection(record=self.record)
        with patch("attendance.db.get_connection", return_value=connection):
            response = self.client.post(
                "/api/attendance/check-in",
                json={"latitude": 0, "longitude": 0, "accuracyMeters": 5},
            )
        self.assertEqual(response.status_code, 409)

    def test_check_in_requires_a_shift_for_today(self):
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        connection = FakeConnection(has_shift=False)
        with patch("attendance.db.get_connection", return_value=connection):
            response = self.client.post(
                "/api/attendance/check-in",
                json={"latitude": 0, "longitude": 0, "accuracyMeters": 5},
            )
        self.assertEqual(response.status_code, 409)
        self.assertIsNone(connection.record)

    def test_employee_can_request_manual_review_with_a_reason(self):
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        connection = FakeConnection()
        with patch("attendance.db.get_connection", return_value=connection):
            response = self.client.post(
                "/api/attendance/exception-requests",
                json={"reason": "GPS signal is weak indoors"},
            )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.json["request"]["action"], "check-in")
        self.assertEqual(response.json["request"]["status"], "pending")
        self.assertEqual(connection.exception_request[-1], "GPS signal is weak indoors")

    def test_employee_exception_request_requires_a_meaningful_reason(self):
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        with patch("attendance.db.get_connection", return_value=FakeConnection()):
            response = self.client.post(
                "/api/attendance/exception-requests",
                json={"reason": "GPS"},
            )
        self.assertEqual(response.status_code, 400)

    def test_manager_approval_creates_a_manual_attendance_record(self):
        connection = FakeConnection()
        connection.exception_record = {
            "request_id": 7,
            "employee_id": "EMPLOYEE-1",
            "attendance_date": datetime.now().date(),
            "action": "check-in",
            "requested_at": datetime.now(timezone.utc).replace(tzinfo=None),
            "shift_start": time(9, 0),
            "shift_end": time(17, 0),
            "status": "pending",
        }
        with self.client.session_transaction() as browser_session:
            browser_session["manager_id"] = "MANAGER-1"
        with patch("attendance.db.get_connection", return_value=connection):
            response = self.client.post(
                "/api/manager/requests/7/decision",
                json={"decision": "approved", "note": "Confirmed with supervisor"},
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(connection.record["check_in_source"], "manual_approval")
        self.assertIsNone(connection.record["check_in_latitude"])
        self.assertEqual(connection.exception_record["status"], "approved")
        self.assertEqual(connection.exception_record["manager_id"], "MANAGER-1")


if __name__ == "__main__":
    unittest.main()
