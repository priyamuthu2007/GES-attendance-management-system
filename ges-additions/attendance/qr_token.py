"""Rotating, stateless office QR tokens: HMAC-SHA256 over (office, 30-second window).

No database needed. The kiosk screen shows a fresh token every window; the server accepts the
current window and one neighbour, so a token is usable for about 30-60 seconds.
"""
import base64
import hashlib
import hmac
import time

WINDOW_SECONDS = 30


def _window(now=None):
    return int((time.time() if now is None else now) // WINDOW_SECONDS)


def _sig(secret: bytes, office: str, window: int) -> str:
    mac = hmac.new(secret, f"{office}|{window}".encode(), hashlib.sha256).digest()[:16]
    return base64.urlsafe_b64encode(mac).decode().rstrip("=")


def issue_token(secret: bytes, office: str, now=None) -> str:
    w = _window(now)
    return f"{office}.{w}.{_sig(secret, office, w)}"


def office_of(token: str):
    parts = token.rsplit(".", 2)
    return parts[0] if len(parts) == 3 and parts[0] else None


def verify_token(secret: bytes, token: str, office: str, now=None, skew_windows: int = 1) -> bool:
    parts = token.rsplit(".", 2)
    if len(parts) != 3:
        return False
    tok_office, w, sig = parts
    if tok_office != office or not (w.isascii() and w.isdigit()):
        return False
    w = int(w)
    if abs(_window(now) - w) > skew_windows:
        return False
    return hmac.compare_digest(sig, _sig(secret, office, w))
