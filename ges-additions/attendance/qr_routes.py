"""Office QR check-in proof.

Flow: the kiosk screen at each office shows a QR that rotates every 30 s. The employee scans it with
the phone camera -> /scan verifies the token and puts a short-lived proof in their session -> the
existing check-in/out endpoint calls has_qr_proof(office) and clear_qr_proof() (see README).
Nobody who is not at the office screen can get a valid token, so spoofed GPS alone is not enough.

Env: QR_SECRET (32+ random chars), KIOSK_KEY (random string), PUBLIC_BASE_URL (the Tailscale HTTPS URL),
     QR_REQUIRED (default "true"), OFFICE_CODES.
"""
import hmac
import io
import os
import time

import segno
from flask import Blueprint, Response, abort, redirect, render_template, render_template_string, request, session

from . import qr_token
from .schema_map import OFFICES

TEMPLATES = os.path.join(os.path.dirname(__file__), "..", "templates")
bp = Blueprint("qr", __name__, template_folder=TEMPLATES)
PROOF_TTL_SECONDS = 180


def register(app):
    """Call once from your app factory. Fails fast if the secrets are missing."""
    if len(os.environ.get("QR_SECRET", "")) < 32:
        raise RuntimeError("Set QR_SECRET to a random string of at least 32 characters in .env")
    if not os.environ.get("KIOSK_KEY") or not os.environ.get("PUBLIC_BASE_URL"):
        raise RuntimeError("Set KIOSK_KEY and PUBLIC_BASE_URL in .env")
    app.register_blueprint(bp)


def _secret() -> bytes:
    return os.environ["QR_SECRET"].encode()


def _kiosk_authorised() -> bool:
    return hmac.compare_digest(request.args.get("key", ""), os.environ.get("KIOSK_KEY", "\0"))


def qr_required() -> bool:
    return os.getenv("QR_REQUIRED", "true").lower() == "true"


def has_qr_proof(office_code: str) -> bool:
    """True if this browser scanned a valid QR for `office_code` in the last few minutes."""
    if not qr_required():
        return True
    p = session.get("qr_proof") or {}
    return p.get("office") == office_code and p.get("exp", 0) >= time.time()


def clear_qr_proof() -> None:
    session.pop("qr_proof", None)


@bp.get("/kiosk/<office>")
def kiosk(office):
    if office not in OFFICES:
        abort(404)
    if not _kiosk_authorised():
        abort(403)
    return render_template("kiosk_qr.html", office=office, key=request.args["key"])


@bp.get("/kiosk/<office>/qr.svg")
def kiosk_qr(office):
    if office not in OFFICES:
        abort(404)
    if not _kiosk_authorised():
        abort(403)
    token = qr_token.issue_token(_secret(), office)
    url = os.environ["PUBLIC_BASE_URL"].rstrip("/") + "/scan?t=" + token
    buf = io.BytesIO()
    segno.make(url, error="m").save(buf, kind="svg", scale=10, border=3)
    return Response(buf.getvalue(), mimetype="image/svg+xml", headers={"Cache-Control": "no-store"})


@bp.get("/scan")
def scan():
    token = request.args.get("t", "")
    office = qr_token.office_of(token)
    if office in OFFICES and qr_token.verify_token(_secret(), token, office):
        session["qr_proof"] = {"office": office, "exp": int(time.time()) + PROOF_TTL_SECONDS}
        return redirect(os.getenv("QR_SUCCESS_REDIRECT", "/"))
    return render_template_string(
        "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
        "<title>Code expired</title><body style='font-family:system-ui;max-width:28rem;margin:3rem auto;padding:0 1rem'>"
        "<h1>That code has expired</h1>"
        "<p>Scan the code on the office screen again. It changes every 30 seconds.</p></body>"), 400
