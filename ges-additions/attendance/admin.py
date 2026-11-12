"""Admin dashboard: employees and shifts, attendance report + CSV, corrections, holidays/leave, audit log.

Self-contained: own login (admin_users table, bcrypt), own CSRF token, own login rate limit.
If your app uses a global Flask-WTF CSRFProtect, exempt this blueprint: csrf.exempt(admin.bp).
"""
import csv
import hmac
import io
import json
import os
import re
import secrets
import time as _time
from collections import Counter, defaultdict
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

import bcrypt
import pymysql
from flask import Blueprint, Response, abort, flash, redirect, render_template, request, session, url_for

from . import rules
from .schema_map import (ATT, DAY_NAMES, EMP, OFFICES, SHIFT, TZ_NAME, day_index, day_name, db,
                         normalise_day, parse_days, weekday_value)

TEMPLATES = os.path.join(os.path.dirname(__file__), "..", "templates")
bp = Blueprint("admin", __name__, url_prefix="/admin", template_folder=TEMPLATES)
TZ = ZoneInfo(TZ_NAME)
POLICY = rules.Policy.from_env()
MAX_RANGE_DAYS = 62
CODE_RE = re.compile(r"^[A-Za-z0-9_-]{3,32}$")


# ---------- security plumbing ----------
def _csrf():
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(24)
    return session["csrf"]


_FAILS = {}  # ip -> [timestamps]; in-memory is fine for a single waitress process


def _locked_out(ip):
    now = _time.time()
    recent = [t for t in _FAILS.get(ip, []) if now - t < 300]
    _FAILS[ip] = recent
    return len(recent) >= 5


@bp.context_processor
def _inject():
    return {"admin_csrf": _csrf, "status_label": rules.LABELS, "status_tone": rules.TONE,
            "flag_label": rules.FLAG_LABELS, "fmt": rules.format_minutes,
            "day_names": DAY_NAMES, "offices": OFFICES}


@bp.before_request
def _guard():
    if request.method == "POST" and not hmac.compare_digest(request.form.get("csrf", ""), session.get("csrf", "\0")):
        abort(400, "Form expired. Reload the page and try again.")
    if request.endpoint != "admin.login" and "admin_id" not in session:
        return redirect(url_for("admin.login", next=request.full_path.rstrip("?")))


def _audit(cur, action, target, details=None):
    cur.execute("INSERT INTO audit_log (admin_id, action, target, details) VALUES (%s,%s,%s,%s)",
                (session.get("admin_id"), action, target, json.dumps(details, default=str) if details else None))


def _fail(msg, to="admin.employees", **kw):
    flash(msg, "error")
    return redirect(url_for(to, **kw))


# ---------- parsing helpers ----------
def _date(s, default=None):
    try:
        return date.fromisoformat(s)
    except (TypeError, ValueError):
        return default


def _hhmm(s):
    try:
        h, m = (s or "").split(":")[:2]
        return time(int(h), int(m))
    except ValueError:
        return None


def _local_to_utc_naive(s):
    """'2026-11-10T09:05' typed in office time -> naive UTC datetime for MySQL."""
    local = datetime.strptime(s, "%Y-%m-%dT%H:%M").replace(tzinfo=TZ)
    return local.astimezone(timezone.utc).replace(tzinfo=None)


def _to_local(dt):
    u = rules.as_utc(dt)
    return u.astimezone(TZ) if u else None


def _clock(dt, day):
    l = _to_local(dt)
    return "" if not l else l.strftime("%H:%M") + (" +1" if l.date() > day else "")


# ---------- auth ----------
@bp.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        ip = request.remote_addr or "?"
        if _locked_out(ip):
            flash("Too many failed sign-ins. Wait five minutes and try again.", "error")
            return render_template("admin/login.html"), 429
        with db() as c, c.cursor() as cur:
            cur.execute("SELECT id, password_hash FROM admin_users WHERE username=%s AND active=1",
                        (request.form.get("username", "").strip(),))
            row = cur.fetchone()
        pw = request.form.get("password", "").encode()
        if row and bcrypt.checkpw(pw, row["password_hash"].encode()):
            session.clear()
            session["admin_id"] = row["id"]
            nxt = request.args.get("next", "")
            return redirect(nxt if nxt.startswith("/admin/") else url_for("admin.attendance"))
        _FAILS.setdefault(ip, []).append(_time.time())
        flash("Username or password is incorrect.", "error")
    return render_template("admin/login.html")


@bp.post("/logout")
def logout():
    session.clear()
    return redirect(url_for("admin.login"))


@bp.get("/")
def home():
    return redirect(url_for("admin.attendance"))


# ---------- employees and shifts ----------
def _write_shift(cur, emp_id, days, start, end):
    cur.execute(f"DELETE FROM {SHIFT['table']} WHERE {SHIFT['emp']}=%s", (emp_id,))
    for dv in parse_days(days):
        cur.execute(f"INSERT INTO {SHIFT['table']} ({SHIFT['emp']},{SHIFT['day']},{SHIFT['start']},{SHIFT['end']}) "
                    "VALUES (%s,%s,%s,%s)", (emp_id, dv, start, end))


def _shift_form():
    days = [d for d in request.form.getlist("days") if d in DAY_NAMES]
    start, end = _hhmm(request.form.get("start")), _hhmm(request.form.get("end"))
    if not days or not start or not end or start == end:
        return None
    return days, start, end


@bp.get("/employees")
def employees():
    with db() as c, c.cursor() as cur:
        cur.execute(f"SELECT {EMP['id']} AS id, {EMP['code']} AS code, {EMP['active']} AS active "
                    f"FROM {EMP['table']} ORDER BY {EMP['active']} DESC, {EMP['code']}")
        emps = cur.fetchall()
        cur.execute(f"SELECT {SHIFT['emp']} AS emp, {SHIFT['day']} AS day, {SHIFT['start']} AS s, {SHIFT['end']} AS e "
                    f"FROM {SHIFT['table']}")
        by_emp = defaultdict(list)
        for r in cur.fetchall():
            by_emp[r["emp"]].append(r)
    for e in emps:
        rows = by_emp.get(e["id"], [])
        days = sorted({normalise_day(r["day"]) for r in rows}, key=day_index)
        times = {(rules.as_time(r["s"]), rules.as_time(r["e"])) for r in rows}
        e["days"] = {day_name(d) for d in days}
        e["start"], e["end"] = (f"{min(times)[0]:%H:%M}", f"{min(times)[1]:%H:%M}") if times else ("09:00", "17:00")
        if not rows:
            e["summary"] = "No shift assigned"
        else:
            span = f"{e['start']}–{e['end']}" if len(times) == 1 else "times vary"
            e["summary"] = f"{', '.join(day_name(d).capitalize() for d in days)} at {span}"
    return render_template("admin/employees.html", emps=emps)


@bp.post("/employees/new")
def employee_new():
    code, pw, shift = request.form.get("code", "").strip(), request.form.get("password", ""), _shift_form()
    if not CODE_RE.match(code):
        return _fail("Employee ID must be 3–32 letters, digits, dashes or underscores.")
    if len(pw) < 10:
        return _fail("Password must be at least 10 characters.")
    if not shift:
        return _fail("Pick at least one working day and a start and end time that differ.")
    hashed = bcrypt.hashpw(pw.encode(), bcrypt.gensalt()).decode()
    try:
        with db() as c, c.cursor() as cur:
            cur.execute(f"INSERT INTO {EMP['table']} ({EMP['code']},{EMP['pw']},{EMP['active']}) VALUES (%s,%s,1)",
                        (code, hashed))
            emp_id = cur.lastrowid
            _write_shift(cur, emp_id, *shift)
            _audit(cur, "employee_create", code, {"days": shift[0], "start": str(shift[1]), "end": str(shift[2])})
    except pymysql.err.IntegrityError:
        return _fail(f"Employee ID {code} already exists.")
    flash(f"Added {code}.", "ok")
    return redirect(url_for("admin.employees"))


@bp.post("/employees/<int:emp_id>/shift")
def employee_shift(emp_id):
    shift = _shift_form()
    if not shift:
        return _fail("Pick at least one working day and a start and end time that differ.")
    with db() as c, c.cursor() as cur:
        _write_shift(cur, emp_id, *shift)
        _audit(cur, "shift_change", f"employee {emp_id}", {"days": shift[0], "start": str(shift[1]), "end": str(shift[2])})
    flash("Shift saved.", "ok")
    return redirect(url_for("admin.employees"))


@bp.post("/employees/<int:emp_id>/active")
def employee_active(emp_id):
    on = 1 if request.form.get("active") == "1" else 0
    with db() as c, c.cursor() as cur:
        cur.execute(f"UPDATE {EMP['table']} SET {EMP['active']}=%s WHERE {EMP['id']}=%s", (on, emp_id))
        _audit(cur, "employee_activate" if on else "employee_deactivate", f"employee {emp_id}")
    flash("Employee reactivated." if on else "Employee deactivated. They can no longer sign in.", "ok")
    return redirect(url_for("admin.employees"))


# ---------- attendance report ----------
def _report(start, end, office="", emp_id=None):
    with db() as c, c.cursor() as cur:
        q, args = (f"SELECT {EMP['id']} AS id, {EMP['code']} AS code FROM {EMP['table']} WHERE {EMP['active']}=1"), []
        if emp_id:
            q += f" AND {EMP['id']}=%s"
            args.append(emp_id)
        cur.execute(q + f" ORDER BY {EMP['code']}", args)
        emps = cur.fetchall()
        cur.execute(f"SELECT {SHIFT['emp']} AS emp, {SHIFT['day']} AS day, {SHIFT['start']} AS s, {SHIFT['end']} AS e "
                    f"FROM {SHIFT['table']}")
        shifts = defaultdict(dict)
        for r in cur.fetchall():
            shifts[r["emp"]][normalise_day(r["day"])] = rules.Shift(rules.as_time(r["s"]), rules.as_time(r["e"]))
        cur.execute(f"SELECT {ATT['emp']} AS emp, {ATT['date']} AS d, {ATT['cin']} AS cin, {ATT['cout']} AS cout, "
                    f"{ATT['office']} AS office FROM {ATT['table']} WHERE {ATT['date']} BETWEEN %s AND %s", (start, end))
        recs = {(r["emp"], r["d"]): r for r in cur.fetchall()}
        cur.execute("SELECT holiday_date FROM holidays WHERE holiday_date BETWEEN %s AND %s", (start, end))
        holidays = {r["holiday_date"] for r in cur.fetchall()}
        cur.execute("SELECT employee_id, leave_date, leave_type FROM leave_records WHERE leave_date BETWEEN %s AND %s",
                    (start, end))
        leaves = {(r["employee_id"], r["leave_date"]): r["leave_type"] for r in cur.fetchall()}

    rows, d = [], end
    while d >= start:
        for e in emps:
            rec = recs.get((e["id"], d))
            if office and (not rec or rec["office"] != office):
                continue  # employees have no home office, so absences can't be tied to one
            shift = shifts[e["id"]].get(weekday_value(d))
            res = rules.classify_day(d, shift=shift, check_in=rec["cin"] if rec else None,
                                     check_out=rec["cout"] if rec else None, tz=TZ, policy=POLICY,
                                     holiday=d in holidays, leave=leaves.get((e["id"], d)))
            rows.append({"day": d, "emp_id": e["id"], "code": e["code"], "office": rec["office"] if rec else "",
                         "shift": f"{shift.start:%H:%M}–{shift.end:%H:%M}" if shift else "",
                         "cin": _clock(rec["cin"], d) if rec else "", "cout": _clock(rec["cout"], d) if rec else "",
                         "res": res})
        d -= timedelta(days=1)
    return rows


def _range_args():
    today = datetime.now(TZ).date()
    end = _date(request.args.get("to"), today)
    start = _date(request.args.get("from"), end - timedelta(days=6))
    if start > end:
        start, end = end, start
    clipped = (end - start).days >= MAX_RANGE_DAYS
    if clipped:
        start = end - timedelta(days=MAX_RANGE_DAYS - 1)
    office = request.args.get("office", "")
    return start, end, office if office in OFFICES else "", request.args.get("emp", type=int), clipped


@bp.get("/attendance")
def attendance():
    start, end, office, emp_id, clipped = _range_args()
    if clipped:
        flash(f"Showing the latest {MAX_RANGE_DAYS} days. Narrow the range to see older dates.", "error")
    rows = _report(start, end, office, emp_id)
    n = Counter(r["res"].status for r in rows)
    summary = {"present": n["present"] + n["worked_off_day"], "late": sum("late" in r["res"].flags for r in rows),
               "absent": n["absent"], "missing": n["missing_checkout"], "half": n["half_day"]}
    with db() as c, c.cursor() as cur:
        cur.execute(f"SELECT {EMP['id']} AS id, {EMP['code']} AS code FROM {EMP['table']} ORDER BY {EMP['code']}")
        people = cur.fetchall()
    return render_template("admin/attendance.html", rows=rows, start=start, end=end, office=office,
                           emp_id=emp_id, people=people, summary=summary, qs=request.query_string.decode())


def _csv_safe(v):
    v = str(v)
    return "'" + v if v[:1] in ("=", "+", "-", "@") else v


@bp.get("/attendance.csv")
def attendance_csv():
    start, end, office, emp_id, _ = _range_args()
    out = io.StringIO()
    w = csv.writer(out)
    w.writerow(["Date", "Employee", "Office", "Shift", "Check-in", "Check-out", "Worked (min)", "Status",
                "Flags", "Late (min)", "Early leave (min)", "Overtime (min)"])
    for r in _report(start, end, office, emp_id):
        x = r["res"]
        w.writerow([r["day"].isoformat(), _csv_safe(r["code"]), r["office"], r["shift"], r["cin"], r["cout"],
                    x.worked_min, rules.LABELS[x.status], " ".join(x.flags), x.late_min, x.early_leave_min,
                    x.overtime_min])
    return Response("\ufeff" + out.getvalue(), mimetype="text/csv; charset=utf-8",
                    headers={"Content-Disposition": f'attachment; filename="attendance_{start}_{end}.csv"'})


# ---------- corrections ----------
def _load_record(cur, emp_id, day, lock=False):
    cur.execute(f"SELECT {ATT['id']} AS id, {ATT['cin']} AS cin, {ATT['cout']} AS cout, {ATT['office']} AS office "
                f"FROM {ATT['table']} WHERE {ATT['emp']}=%s AND {ATT['date']}=%s" + (" FOR UPDATE" if lock else ""),
                (emp_id, day))
    return cur.fetchone()


@bp.route("/attendance/correct", methods=["GET", "POST"])
def correct():
    emp_id = request.values.get("emp", type=int)
    day = _date(request.values.get("day"))
    if not emp_id or not day:
        abort(400)
    back = url_for("admin.attendance", **{"from": day.isoformat(), "to": day.isoformat()})
    if request.method == "POST":
        reason, office = request.form.get("reason", "").strip(), request.form.get("office", "")
        try:
            cin = _local_to_utc_naive(request.form["check_in"])
            cout = _local_to_utc_naive(request.form["check_out"]) if request.form.get("check_out") else None
        except (KeyError, ValueError):
            return _fail("Enter the check-in time (and check-out, if any) as a valid date and time.",
                         "admin.correct", emp=emp_id, day=day.isoformat())
        if cout and cout <= cin:
            return _fail("Check-out must be after check-in.", "admin.correct", emp=emp_id, day=day.isoformat())
        if len(reason) < 5:
            return _fail("Write a reason of at least five characters. It is saved in the audit log.",
                         "admin.correct", emp=emp_id, day=day.isoformat())
        if office not in OFFICES:
            return _fail("Choose the office.", "admin.correct", emp=emp_id, day=day.isoformat())
        with db() as c, c.cursor() as cur:
            old = _load_record(cur, emp_id, day, lock=True)
            if old:
                cur.execute(f"UPDATE {ATT['table']} SET {ATT['cin']}=%s, {ATT['cout']}=%s, {ATT['office']}=%s "
                            f"WHERE {ATT['id']}=%s", (cin, cout, office, old["id"]))
            else:
                cols = {ATT["emp"]: emp_id, ATT["date"]: day, ATT["cin"]: cin, ATT["cout"]: cout,
                        ATT["office"]: office, **ATT["extra_insert"]}
                cur.execute(f"INSERT INTO {ATT['table']} ({','.join(cols)}) VALUES ({','.join(['%s'] * len(cols))})",
                            list(cols.values()))
            _audit(cur, "attendance_correct", f"employee {emp_id} on {day}",
                   {"reason": reason, "old": old, "new": {"cin": cin, "cout": cout, "office": office}})
        flash("Attendance saved and recorded in the audit log.", "ok")
        return redirect(back)

    with db() as c, c.cursor() as cur:
        cur.execute(f"SELECT {EMP['code']} AS code FROM {EMP['table']} WHERE {EMP['id']}=%s", (emp_id,))
        emp = cur.fetchone() or abort(404)
        rec = _load_record(cur, emp_id, day)
    fmt = "%Y-%m-%dT%H:%M"
    cin, cout = (_to_local(rec["cin"]), _to_local(rec["cout"])) if rec else (None, None)
    return render_template("admin/correct.html", emp=emp, emp_id=emp_id, day=day, rec=rec, back=back,
                           cin=cin.strftime(fmt) if cin else f"{day}T09:00", cout=cout.strftime(fmt) if cout else "")


# ---------- holidays and leave ----------
@bp.get("/calendar")
def calendar():
    since = datetime.now(TZ).date() - timedelta(days=30)
    with db() as c, c.cursor() as cur:
        cur.execute("SELECT holiday_date, name FROM holidays WHERE holiday_date >= %s ORDER BY holiday_date", (since,))
        holidays = cur.fetchall()
        cur.execute(f"SELECT l.id, l.leave_date, l.leave_type, l.reason, e.{EMP['code']} AS code FROM leave_records l "
                    f"JOIN {EMP['table']} e ON e.{EMP['id']}=l.employee_id WHERE l.leave_date >= %s "
                    "ORDER BY l.leave_date DESC, code", (since,))
        leaves = cur.fetchall()
        cur.execute(f"SELECT {EMP['id']} AS id, {EMP['code']} AS code FROM {EMP['table']} "
                    f"WHERE {EMP['active']}=1 ORDER BY {EMP['code']}")
        people = cur.fetchall()
    return render_template("admin/calendar.html", holidays=holidays, leaves=leaves, people=people)


@bp.post("/calendar/holiday")
def holiday_add():
    d, name = _date(request.form.get("date")), request.form.get("name", "").strip()[:120]
    if not d or not name:
        return _fail("Enter a date and a holiday name.", "admin.calendar")
    with db() as c, c.cursor() as cur:
        cur.execute("INSERT INTO holidays (holiday_date, name) VALUES (%s,%s) ON DUPLICATE KEY UPDATE name=VALUES(name)",
                    (d, name))
        _audit(cur, "holiday_add", str(d), {"name": name})
    flash("Holiday saved.", "ok")
    return redirect(url_for("admin.calendar"))


@bp.post("/calendar/holiday/delete")
def holiday_delete():
    d = _date(request.form.get("date"))
    if not d:
        abort(400)
    with db() as c, c.cursor() as cur:
        cur.execute("DELETE FROM holidays WHERE holiday_date=%s", (d,))
        _audit(cur, "holiday_delete", str(d))
    flash("Holiday removed.", "ok")
    return redirect(url_for("admin.calendar"))


@bp.post("/calendar/leave")
def leave_add():
    emp_id, d = request.form.get("emp", type=int), _date(request.form.get("date"))
    kind = request.form.get("type") if request.form.get("type") in ("full", "half") else "full"
    if not emp_id or not d:
        return _fail("Choose an employee and a date.", "admin.calendar")
    reason = request.form.get("reason", "").strip()[:200]
    with db() as c, c.cursor() as cur:
        cur.execute("INSERT INTO leave_records (employee_id, leave_date, leave_type, reason, created_by) "
                    "VALUES (%s,%s,%s,%s,%s) ON DUPLICATE KEY UPDATE leave_type=VALUES(leave_type), reason=VALUES(reason)",
                    (emp_id, d, kind, reason, session["admin_id"]))
        _audit(cur, "leave_add", f"employee {emp_id} on {d}", {"type": kind, "reason": reason})
    flash("Leave saved.", "ok")
    return redirect(url_for("admin.calendar"))


@bp.post("/calendar/leave/delete")
def leave_delete():
    lid = request.form.get("id", type=int)
    if not lid:
        abort(400)
    with db() as c, c.cursor() as cur:
        cur.execute("DELETE FROM leave_records WHERE id=%s", (lid,))
        _audit(cur, "leave_delete", f"leave {lid}")
    flash("Leave removed.", "ok")
    return redirect(url_for("admin.calendar"))


# ---------- audit log ----------
@bp.get("/audit")
def audit():
    with db() as c, c.cursor() as cur:
        cur.execute("SELECT a.created_at, u.username, a.action, a.target, a.details FROM audit_log a "
                    "LEFT JOIN admin_users u ON u.id=a.admin_id ORDER BY a.id DESC LIMIT 200")
        rows = cur.fetchall()
    for r in rows:
        r["when"] = _to_local(r["created_at"]).strftime("%d %b %Y, %H:%M")
    return render_template("admin/audit.html", rows=rows)


# ---------- CLI helper (used by scripts/create_admin.py) ----------
def create_admin(username: str, password: str) -> None:
    with db() as c, c.cursor() as cur:
        cur.execute("INSERT INTO admin_users (username, password_hash) VALUES (%s,%s)",
                    (username, bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()))
