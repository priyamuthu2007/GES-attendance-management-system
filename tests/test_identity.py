import unittest

from attendance.identity import normalize_email


class EmailNormalizationTests(unittest.TestCase):
    def test_trims_and_lowercases_address(self):
        self.assertEqual(
            normalize_email("  Employee.Name@Example.COM "),
            "employee.name@example.com",
        )

    def test_rejects_malformed_address(self):
        for value in ("", "user@", "user@localhost", "a..b@example.com", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                normalize_email(value)


if __name__ == "__main__":
    unittest.main()
