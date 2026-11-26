import unittest
from unittest.mock import patch

import pymysql

from attendance import create_app, db


class FakeConnection:
    def __init__(self):
        self.fail_ping = False
        self.ping_count = 0
        self.rollback_count = 0
        self.closed = False

    def ping(self, reconnect=False):
        self.ping_count += 1
        if self.fail_ping:
            raise pymysql.err.OperationalError(2006, "connection is gone")

    def rollback(self):
        self.rollback_count += 1

    def close(self):
        self.closed = True


class DatabasePoolTests(unittest.TestCase):
    def setUp(self):
        self.app = create_app(
            {
                "TESTING": True,
                "SECRET_KEY": "test-only-secret",
                "MYSQL_HOST": "127.0.0.1",
                "MYSQL_PORT": 3306,
                "MYSQL_DATABASE": "test",
                "MYSQL_USER": "test",
                "MYSQL_PASSWORD": "test",
            }
        )

    def test_reuses_a_healthy_connection_between_requests(self):
        connection = FakeConnection()
        with self.app.app_context(), patch(
            "attendance.db.connect", return_value=connection
        ) as connect:
            first = db.get_connection()
            db.close_db()
            second = db.get_connection()
            self.assertIs(first, second)
            self.assertEqual(connect.call_count, 1)
            self.assertEqual(connection.rollback_count, 1)
            db.close_db()

    def test_replaces_a_stale_connection(self):
        stale = FakeConnection()
        fresh = FakeConnection()
        with self.app.app_context(), patch(
            "attendance.db.connect", side_effect=[stale, fresh]
        ) as connect:
            db.get_connection()
            db.close_db()
            stale.fail_ping = True
            replacement = db.get_connection()
            self.assertIs(replacement, fresh)
            self.assertTrue(stale.closed)
            self.assertEqual(connect.call_count, 2)
            db.close_db()


if __name__ == "__main__":
    unittest.main()
