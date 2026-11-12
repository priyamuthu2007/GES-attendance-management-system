import unittest

from attendance import qr_token as q

SECRET = b"x" * 40


class QrTokenTests(unittest.TestCase):
    def test_roundtrip(self):
        t = q.issue_token(SECRET, "anna-nagar", now=1_000_000)
        self.assertTrue(q.verify_token(SECRET, t, "anna-nagar", now=1_000_000))
        self.assertEqual(q.office_of(t), "anna-nagar")

    def test_accepts_one_neighbouring_window(self):
        t = q.issue_token(SECRET, "anna-nagar", now=1_000_000)
        self.assertTrue(q.verify_token(SECRET, t, "anna-nagar", now=1_000_000 + 30))

    def test_rejects_expired(self):
        t = q.issue_token(SECRET, "anna-nagar", now=1_000_000)
        self.assertFalse(q.verify_token(SECRET, t, "anna-nagar", now=1_000_000 + 95))

    def test_rejects_other_office(self):
        t = q.issue_token(SECRET, "anna-nagar", now=1_000_000)
        self.assertFalse(q.verify_token(SECRET, t, "manapakkam", now=1_000_000))

    def test_rejects_wrong_secret_and_tampering(self):
        t = q.issue_token(SECRET, "anna-nagar", now=1_000_000)
        self.assertFalse(q.verify_token(b"y" * 40, t, "anna-nagar", now=1_000_000))
        office, w, sig = t.rsplit(".", 2)
        self.assertFalse(q.verify_token(SECRET, f"{office}.{int(w) + 1}.{sig}", "anna-nagar", now=1_000_000))

    def test_rejects_garbage(self):
        for bad in ("", "abc", "a.b.c", "a.²." + "x"):
            self.assertFalse(q.verify_token(SECRET, bad, "a", now=1_000_000))


if __name__ == "__main__":
    unittest.main()
