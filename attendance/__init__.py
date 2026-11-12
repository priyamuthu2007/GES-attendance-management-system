import json
import os
from datetime import timedelta
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import bcrypt
from dotenv import load_dotenv
from flask import Flask, jsonify, render_template, request, session
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from flask_wtf.csrf import CSRFError, CSRFProtect, generate_csrf

from . import db
from .geofence import ATTENDANCE_RADIUS_METERS, MAX_GPS_ACCURACY_METERS

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

csrf = CSRFProtect()
limiter = Limiter(
    key_func=lambda: request.headers.get("Tailscale-User-Login") or get_remote_address(),
    default_limits=[],
    storage_uri="memory://",
)


def load_offices():
    raw = os.getenv("OFFICE_LOCATIONS_JSON", "").strip()
    if not raw:
        raise RuntimeError("Set OFFICE_LOCATIONS_JSON in .env with registered office pins.")
    try:
        offices = json.loads(raw)
    except json.JSONDecodeError as error:
        raise RuntimeError("OFFICE_LOCATIONS_JSON must be a JSON array.") from error
    if not isinstance(offices, list) or not offices:
        raise RuntimeError("OFFICE_LOCATIONS_JSON must contain at least one office.")

    ids = set()
    normalized = []
    for office in offices:
        if not isinstance(office, dict):
            raise RuntimeError("Each registered office must be an object.")
        office_id = office.get("id")
        name = office.get("name")
        latitude = office.get("latitude")
        longitude = office.get("longitude")
        if (
            not isinstance(office_id, str)
            or not office_id.strip()
            or office_id in ids
            or not isinstance(name, str)
            or not name.strip()
            or isinstance(latitude, bool)
            or not isinstance(latitude, (int, float))
            or isinstance(longitude, bool)
            or not isinstance(longitude, (int, float))
            or not -90 <= latitude <= 90
            or not -180 <= longitude <= 180
        ):
            raise RuntimeError("Each office needs a unique ID, name, and valid GPS coordinates.")
        ids.add(office_id)
        normalized.append(
            {
                "id": office_id,
                "name": name.strip(),
                "latitude": float(latitude),
                "longitude": float(longitude),
            }
        )
    return normalized


def create_app(test_config=None):
    app = Flask(__name__, template_folder="../templates", static_folder="../static")
    app.config.update(
        SECRET_KEY=os.getenv("FLASK_SECRET_KEY"),
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=os.getenv("SESSION_COOKIE_SECURE", "true").lower()
        in {"true", "1", "yes"},
        PERMANENT_SESSION_LIFETIME=timedelta(hours=8),
        MAX_CONTENT_LENGTH=10 * 1024,
        WTF_CSRF_TIME_LIMIT=timedelta(hours=8),
        OFFICE_TIMEZONE=os.getenv("OFFICE_TIMEZONE", ""),
        MYSQL_HOST=os.getenv("MYSQL_HOST", "127.0.0.1"),
        MYSQL_PORT=int(os.getenv("MYSQL_PORT", "3306")),
        MYSQL_DATABASE=os.getenv("MYSQL_DATABASE", "ges_attendance"),
        MYSQL_USER=os.getenv("MYSQL_USER", ""),
        MYSQL_PASSWORD=os.getenv("MYSQL_PASSWORD", ""),
        MYSQL_MIGRATION_USER=os.getenv("MYSQL_MIGRATION_USER", ""),
        MYSQL_MIGRATION_PASSWORD=os.getenv("MYSQL_MIGRATION_PASSWORD", ""),
        OFFICES=load_offices() if os.getenv("OFFICE_LOCATIONS_JSON") else [],
        TESTING=False,
    )
    if test_config:
        app.config.update(test_config)
    if not app.config["SECRET_KEY"] and not app.config["TESTING"]:
        raise RuntimeError(
            "FLASK_SECRET_KEY is missing. Copy .env.example to .env and set "
            "FLASK_SECRET_KEY to a random value of at least 32 characters."
        )
    if (
        not app.config["TESTING"]
        and len(app.config["SECRET_KEY"]) < 32
    ):
        raise RuntimeError("FLASK_SECRET_KEY must contain at least 32 characters.")
    if not app.config["TESTING"]:
        if not app.config["MYSQL_USER"] or not app.config["MYSQL_PASSWORD"]:
            raise RuntimeError("Set MYSQL_USER and MYSQL_PASSWORD in .env.")
        try:
            ZoneInfo(app.config["OFFICE_TIMEZONE"])
        except ZoneInfoNotFoundError as error:
            raise RuntimeError("Set OFFICE_TIMEZONE to a valid IANA timezone.") from error

    csrf.init_app(app)
    limiter.init_app(app)
    app.teardown_appcontext(db.close_db)

    @app.after_request
    def set_security_headers(response):
        if request.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "same-origin"
        response.headers["Permissions-Policy"] = "geolocation=(self)"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            "img-src 'self' data:; connect-src 'self'; object-src 'none'; "
            "base-uri 'self'; frame-ancestors 'none'; form-action 'self'"
        )
        return response

    @app.errorhandler(CSRFError)
    def handle_csrf_error(error):
        return jsonify(error="Security token expired. Refresh the page and try again."), 400

    @app.errorhandler(413)
    def handle_large_request(_error):
        return jsonify(error="Request is too large."), 413

    @app.errorhandler(Exception)
    def handle_unexpected_error(error):
        from werkzeug.exceptions import HTTPException

        if isinstance(error, HTTPException):
            return jsonify(error=error.description), error.code
        app.logger.exception("Unhandled attendance request error.")
        return jsonify(error="The request could not be completed. Please try again."), 500

    @app.get("/")
    def index():
        return render_template("index.html")

    @app.get("/manager")
    def manager_page():
        return render_template("manager.html")

    @app.get("/api/health/live")
    def health_live():
        return jsonify(status="ok")

    @app.get("/api/health/ready")
    def health_ready():
        try:
            db.get_connection().ping(reconnect=False)
            load_offices()
            ZoneInfo(app.config["OFFICE_TIMEZONE"])
        except Exception:
            app.logger.exception("Readiness check failed.")
            return jsonify(status="not_ready"), 503
        return jsonify(status="ready")

    @app.get("/api/csrf-token")
    def csrf_token():
        return jsonify(csrfToken=generate_csrf())

    def current_employee():
        employee_id = session.get("employee_id")
        if not employee_id:
            return None
        cursor = db.get_connection().cursor()
        try:
            cursor.execute(
                "SELECT employee_id FROM employees WHERE employee_id = %s AND active = 1",
                (employee_id,),
            )
            return cursor.fetchone()
        finally:
            cursor.close()

    def login_required(view):
        from functools import wraps

        @wraps(view)
        def wrapped(*args, **kwargs):
            if not session.get("employee_id"):
                return jsonify(error="Please sign in to continue."), 401
            if not current_employee():
                session.clear()
                return jsonify(error="Please sign in to continue."), 401
            return view(*args, **kwargs)

        return wrapped

    def manager_required(view):
        from functools import wraps

        @wraps(view)
        def wrapped(*args, **kwargs):
            manager_id = session.get("manager_id")
            if not manager_id:
                return jsonify(error="Please sign in with a manager account."), 401
            cursor = db.get_connection().cursor()
            try:
                cursor.execute(
                    "SELECT manager_id FROM managers WHERE manager_id = %s AND active = 1",
                    (manager_id,),
                )
                if not cursor.fetchone():
                    session.clear()
                    return jsonify(error="Manager account is inactive."), 403
            finally:
                cursor.close()
            return view(*args, **kwargs)

        return wrapped

    @app.post("/api/manager/auth/login")
    @limiter.limit("10 per 15 minutes")
    def manager_login():
        body = request.get_json(silent=True) or {}
        if not isinstance(body, dict):
            body = {}
        manager_id = body.get("managerId")
        password = body.get("password")
        if (
            not isinstance(manager_id, str)
            or not isinstance(password, str)
            or not manager_id.strip()
            or not password
        ):
            return jsonify(error="Enter your manager ID and password."), 400

        session.clear()
        cursor = db.get_connection().cursor()
        try:
            cursor.execute(
                "SELECT manager_id, password_hash, active FROM managers WHERE manager_id = %s",
                (manager_id.strip(),),
            )
            manager = cursor.fetchone()
        finally:
            cursor.close()

        valid_password = manager and manager["active"] and bcrypt.checkpw(
            password.encode("utf-8"), manager["password_hash"].encode("utf-8")
        )
        if not valid_password:
            return jsonify(error="Manager ID or password is incorrect."), 401

        session.clear()
        session.permanent = True
        session["manager_id"] = manager["manager_id"]
        return jsonify(managerId=manager["manager_id"])

    @app.post("/api/manager/auth/logout")
    @manager_required
    def manager_logout():
        session.clear()
        return jsonify(status="signed_out")

    @app.get("/api/manager/requests")
    @manager_required
    def manager_requests():
        from .approval_routes import list_manager_requests

        return list_manager_requests(app.config["OFFICE_TIMEZONE"])

    @app.post("/api/manager/requests/<int:request_id>/decision")
    @manager_required
    def manager_decide_request(request_id):
        from .approval_routes import decide_exception_request

        return decide_exception_request(app.config, session["manager_id"], request_id)

    @app.post("/api/auth/login")
    @limiter.limit("10 per 15 minutes")
    def login():
        body = request.get_json(silent=True) or {}
        if not isinstance(body, dict):
            body = {}
        employee_id = body.get("employeeId")
        password = body.get("password")
        if (
            not isinstance(employee_id, str)
            or not isinstance(password, str)
            or not employee_id.strip()
            or not password
        ):
            return jsonify(error="Enter your employee ID and password."), 400

        session.clear()
        cursor = db.get_connection().cursor()
        try:
            cursor.execute(
                "SELECT employee_id, password_hash, active FROM employees WHERE employee_id = %s",
                (employee_id.strip(),),
            )
            employee = cursor.fetchone()
        finally:
            cursor.close()

        valid_password = employee and employee["active"] and bcrypt.checkpw(
            password.encode("utf-8"), employee["password_hash"].encode("utf-8")
        )
        if not valid_password:
            return jsonify(error="Employee ID or password is incorrect."), 401

        session.permanent = True
        session["employee_id"] = employee["employee_id"]
        return jsonify(employeeId=employee["employee_id"])

    @app.post("/api/auth/logout")
    @login_required
    def logout():
        session.clear()
        return jsonify(status="signed_out")

    @app.get("/api/attendance/today")
    @login_required
    def attendance_today():
        from .attendance_routes import get_today_state

        return jsonify(get_today_state(app.config["OFFICE_TIMEZONE"], app.config["OFFICES"]))

    @app.post("/api/attendance/check-in")
    @login_required
    def check_in():
        from .attendance_routes import create_check_in

        return create_check_in(app.config, session["employee_id"])

    @app.post("/api/attendance/check-out")
    @login_required
    def check_out():
        from .attendance_routes import create_check_out

        return create_check_out(app.config, session["employee_id"])

    @app.post("/api/attendance/exception-requests")
    @login_required
    @limiter.limit("5 per hour")
    def create_attendance_exception_request():
        from .approval_routes import create_exception_request

        return create_exception_request(app.config, session["employee_id"])

    return app
