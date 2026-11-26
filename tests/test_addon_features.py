import csv
import io
import unittest
from datetime import date, datetime
from unittest.mock import patch

from attendance import create_app


class FakeCursor:
    def __init__(self, connection):
        self.connection = connection
        self.result = None
        self.rows = []

    def __enter__(self):
        return self

    def __exit__(self, _exc_type, _exc_value, _traceback):
        return None

    def execute(self, query, params=()):
        self.result = None
        self.rows = []
        if "SELECT e.active" in query:
            self.result = {"active": 1, "role": self.connection.role}
        elif "FROM employees AS e" in query:
            self.rows = self.connection.attendance_rows
        elif "FROM attendance AS a" in query:
            self.rows = self.connection.attendance_rows
        else:
            self.connection.statements.append((query, params))

    def fetchone(self):
        return self.result

    def fetchall(self):
        return self.rows


class FakeConnection:
    def __init__(self, role="employee", attendance_rows=None):
        self.role = role
        self.attendance_rows = attendance_rows or []
        self.statements = []
        self.commits = 0
        self.rollbacks = 0

    def cursor(self):
        return FakeCursor(self)

    def commit(self):
        self.commits += 1

    def rollback(self):
        self.rollbacks += 1


class AddonFeatureTests(unittest.TestCase):
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

    def test_location_notice_is_available_without_login(self):
        response = self.client.get("/location-notice")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"Location Data Notice", response.data)

    def test_valid_csrf_token_reaches_the_logout_route(self):
        self.app.config["WTF_CSRF_ENABLED"] = True
        token = self.client.get("/api/csrf-token").json["csrfToken"]
        response = self.client.post(
            "/api/auth/logout",
            headers={"X-CSRFToken": token},
        )
        self.assertEqual(response.status_code, 401)

    def test_employee_cannot_create_accounts(self):
        connection = FakeConnection(role="employee")
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        with patch("attendance.addon_features.db.get_connection", return_value=connection):
            response = self.client.post(
                "/api/accounts",
                json={
                    "username": "NEW-EMPLOYEE",
                    "full_name": "New Employee",
                    "password": "a-private-password",
                    "days": ["mon"],
                    "shift_start": "09:00",
                    "shift_end": "17:00",
                },
            )
        self.assertEqual(response.status_code, 403)
        self.assertEqual(connection.statements, [])

    def test_admin_created_accounts_receive_site_assignments(self):
        connection = FakeConnection(role="admin")
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "ADMIN-1"
        with patch("attendance.addon_features.db.get_connection", return_value=connection):
            response = self.client.post(
                "/api/accounts",
                json={
                    "username": "NEW-EMPLOYEE",
                    "full_name": "New Employee",
                    "password": "a-private-password",
                    "role": "employee",
                    "days": ["mon"],
                    "shift_start": "09:30",
                    "shift_end": "18:30",
                    "sites": ["test"],
                },
            )
        self.assertEqual(response.status_code, 201)
        assigned_sites = [
            params
            for query, params in connection.statements
            if "INSERT INTO employee_offices" in query
        ]
        self.assertEqual(assigned_sites, [("NEW-EMPLOYEE", "test")])

    def test_csv_export_uses_postgresql_schema_and_escapes_formula_values(self):
        connection = FakeConnection(
            role="hr",
            attendance_rows=[
                {
                    "employee_id": "EMPLOYEE-1",
                    "full_name": "=HYPERLINK(\"bad\")",
                    "attendance_date": date(2026, 11, 16),
                    "check_in_at": datetime(2026, 11, 16, 3, 30),
                    "check_out_at": None,
                }
            ],
        )
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        with patch("attendance.addon_features.db.get_connection", return_value=connection):
            response = self.client.get(
                "/api/reports/attendance.csv?start_date=2026-11-16&end_date=2026-11-16"
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.mimetype, "text/csv")
        rows = list(csv.reader(io.StringIO(response.get_data(as_text=True))))
        self.assertEqual(rows[1][1], "'=HYPERLINK(\"bad\")")
        self.assertEqual(rows[1][-1], "incomplete")
        self.assertEqual(connection.commits, 1)

    def test_attendance_report_shows_active_employees_and_local_times(self):
        connection = FakeConnection(
            role="admin",
            attendance_rows=[
                {
                    "employee_id": "EMPLOYEE-1",
                    "full_name": "Employee One",
                    "shift_day": 0,
                    "shift_start": None,
                    "shift_end": None,
                    "check_in_at": datetime(2026, 11, 16, 3, 31),
                    "check_out_at": datetime(2026, 11, 16, 12, 35),
                },
                {
                    "employee_id": "EMPLOYEE-2",
                    "full_name": None,
                    "shift_day": None,
                    "shift_start": None,
                    "shift_end": None,
                    "check_in_at": None,
                    "check_out_at": None,
                },
            ],
        )
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "ADMIN-1"
        with patch("attendance.addon_features.db.get_connection", return_value=connection):
            response = self.client.get("/api/attendance/report?date=2026-11-16")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["date"], "2026-11-16")
        first, second = response.json["employees"]
        self.assertTrue(first["flexibleShift"])
        self.assertEqual(first["checkInAt"], "2026-11-16T09:01:00+05:30")
        self.assertEqual(first["checkOutAt"], "2026-11-16T18:05:00+05:30")
        self.assertEqual(first["status"], "complete")
        self.assertEqual(second["status"], "not_checked_in")
        self.assertFalse(second["flexibleShift"])
        self.assertEqual(connection.commits, 1)

    def test_employee_cannot_view_attendance_report(self):
        connection = FakeConnection(role="employee")
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        with patch("attendance.addon_features.db.get_connection", return_value=connection):
            response = self.client.get("/api/attendance/report?date=2026-11-16")
        self.assertEqual(response.status_code, 403)
        self.assertEqual(connection.statements, [])

    def test_admin_can_open_attendance_report_page_and_read_session_role(self):
        connection = FakeConnection(role="admin")
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "ADMIN-1"
        with patch("attendance.addon_features.db.get_connection", return_value=connection):
            page = self.client.get("/attendance-report")
            role = self.client.get("/api/auth/session")
        self.assertEqual(page.status_code, 200)
        self.assertIn(b"Check-in", page.data)
        self.assertEqual(role.json, {"employeeId": "ADMIN-1", "role": "admin"})

    def test_risk_check_stores_signals_without_coordinates(self):
        connection = FakeConnection(role="employee")
        with self.client.session_transaction() as browser_session:
            browser_session["employee_id"] = "EMPLOYEE-1"
        with patch("attendance.addon_features.db.get_connection", return_value=connection):
            response = self.client.post(
                "/api/location-risk-check",
                json={
                    "latitude": 13.0,
                    "longitude": 80.0,
                    "accuracy": 5,
                    "timestamp": 1,
                    "mock_location": True,
                },
            )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json["review_required"])
        stored_risk = next(
            params
            for query, params in connection.statements
            if "INSERT INTO location_risk_events" in query
        )
        self.assertEqual(stored_risk[0], "EMPLOYEE-1")
        self.assertNotIn("13.0", stored_risk[1])
        self.assertNotIn("80.0", stored_risk[1])
        self.assertEqual(connection.commits, 1)


if __name__ == "__main__":
    unittest.main()
