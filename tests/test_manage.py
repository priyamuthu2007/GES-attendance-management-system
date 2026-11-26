import contextlib
import io
import unittest
from unittest.mock import patch

import manage


class FakeCursor:
    def __init__(self, connection):
        self.connection = connection

    def __enter__(self):
        return self

    def __exit__(self, _exc_type, _exc_value, _traceback):
        return None

    def execute(self, query, params):
        self.connection.statements.append((query, params))


class FakeConnection:
    def __init__(self):
        self.statements = []
        self.commits = 0
        self.rollbacks = 0

    def cursor(self):
        return FakeCursor(self)

    def commit(self):
        self.commits += 1

    def rollback(self):
        self.rollbacks += 1


class ManageTests(unittest.TestCase):
    def test_create_employee_assigns_flexible_shifts_all_seven_days(self):
        connection = FakeConnection()
        with (
            patch("manage.getpass.getpass", side_effect=["secure-password-123", "secure-password-123"]),
            patch("manage.get_connection", return_value=connection),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            manage.create_employee(
                "EMPLOYEE-100",
                list(range(5)),
                "09:00",
                "17:00",
                ["kpl"],
                [{"id": "kpl"}],
                flexible_shift=True,
            )

        shifts = [
            params
            for query, params in connection.statements
            if "INSERT INTO employee_shifts" in query
        ]
        sites = [
            params
            for query, params in connection.statements
            if "INSERT INTO employee_offices" in query
        ]
        self.assertEqual([row[1] for row in shifts], list(range(7)))
        self.assertTrue(all(row[2:] == (None, None) for row in shifts))
        self.assertEqual(sites, [("EMPLOYEE-100", "kpl")])
        self.assertEqual(connection.commits, 1)


if __name__ == "__main__":
    unittest.main()
