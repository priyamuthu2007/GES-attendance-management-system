# GES attendance add-ons

Four additions for the Flask + MySQL attendance app. Written against the README of the repo, not its source, so
**one file (`attendance/schema_map.py`) holds every guess about your existing tables.** Fix that first.

| Add-on | Files |
|---|---|
| Rotating QR check-in (anti-spoofing) | `attendance/qr_token.py`, `attendance/qr_routes.py`, `templates/kiosk_qr.html` |
| Admin dashboard | `attendance/admin.py`, `templates/admin/*.html`, `scripts/create_admin.py` |
| Late / early / overtime / half-day / leave / holidays | `attendance/rules.py`, `migrations/001_additions.sql` |
| CI + backups | `.github/workflows/ci.yml`, `scripts/backup-mysql.ps1`, `register-backup-task.ps1`, `restore-test.ps1` |
| Tests | `tests/test_rules.py`, `tests/test_qr_token.py` |

## Install

1. Copy the folders into the repo root (they sit beside your existing `attendance/`, `templates/`, `scripts/`, `tests/`).
   Your `attendance/` folder must be the Flask package (it has an `__init__.py`); if it isn't, move the new modules into the package that is.
2. Add `requirements-additions.txt` to `requirements.txt`, then `.\.venv\Scripts\python.exe -m pip install -r requirements.txt`.
3. Open `attendance/schema_map.py`. Run `SHOW CREATE TABLE` for your employee, shift and attendance tables and edit the names.
   Also set `OFFICE_CODES` in `.env` to your real office codes (default `anna-nagar,manapakkam`).
4. Create the new tables with the **migration** account: `mysql -u ges_attendance_migrator -p ges_attendance < migrations\001_additions.sql`
5. Add to `.env`:
   ```
   QR_SECRET=<python -c "import secrets; print(secrets.token_urlsafe(48))">
   KIOSK_KEY=<another random string>
   PUBLIC_BASE_URL=https://<your-host>.<tailnet>.ts.net
   QR_REQUIRED=true
   ```
   Optional policy knobs: `LATE_GRACE_MIN=10`, `EARLY_LEAVE_GRACE_MIN=5`, `OVERTIME_AFTER_MIN=30`, `HALF_DAY_RATIO=0.5`.
6. Register in your app factory (or `wsgi.py`):
   ```python
   from attendance import admin, qr_routes
   app.register_blueprint(admin.bp)
   qr_routes.register(app)          # also checks QR_SECRET / KIOSK_KEY at startup
   # only if you use a global Flask-WTF CSRFProtect:  csrf.exempt(admin.bp)
   ```
7. Create the first admin: `.\.venv\Scripts\python.exe scripts\create_admin.py alice`, then sign in at `/admin/login`.

## Hook the QR proof into check-in and check-out

In your existing check-in **and** check-out handlers, after you work out the nearest office and pass the GPS checks:

```python
from attendance.qr_routes import has_qr_proof, clear_qr_proof

if not has_qr_proof(nearest_office_code):
    return jsonify(error="Scan the QR code shown on the office screen, then try again."), 403
...                       # write the attendance record
clear_qr_proof()          # each scan covers one check-in or check-out
```
On the office PC open `https://<host>/kiosk/anna-nagar?key=<KIOSK_KEY>` full-screen (and `/kiosk/manapakkam?...` at the other office).
Employees scan it with the phone camera, the browser opens `/scan`, and the proof lasts three minutes.
Update your front-end error text so it tells people to scan the code.

## Day rules (`attendance/rules.py`)

| Case | Result |
|---|---|
| Check-in more than 10 min after shift start | Late (minutes shown) |
| Check-out more than 5 min before shift end | Left early |
| Check-out 30+ min after shift end | Overtime, counted from shift end |
| Worked under 50% of the shift | Half day |
| Holiday, or no shift that weekday | Day off; any work done counts fully as overtime |
| Full-day leave / half-day leave with a check-in | On leave / Half-day leave |
| Checked in, no check-out, 2 h after shift end | Missing check-out |
| No check-in once the shift is over | Absent |

Night shifts (end time earlier than start) end the next day. Stored times are UTC and read as office time (`APP_TIMEZONE`, default `Asia/Kolkata`).

## Backups (Windows host)

1. Create the `ges_backup` MySQL user and `.backup.my.cnf` as described at the top of `scripts\backup-mysql.ps1`; add `.backup.my.cnf` to `.gitignore`.
2. Test once by hand: `.\scripts\backup-mysql.ps1 -OffsiteDir "E:\ges-offsite"`.
3. Schedule it (Administrator PowerShell): `.\scripts\register-backup-task.ps1 -OffsiteDir "E:\ges-offsite"`.
4. Once a month: `.\scripts\restore-test.ps1 -AdminDefaultsFile .\.admin.my.cnf`. A backup you have never restored is not a backup.

## What was and wasn't tested

Tested in a sandbox: all unit tests (18 pass), plus an end-to-end run of the admin dashboard and QR flow against MariaDB 10.11 with a stand-in schema
(login, CSRF rejection, create/edit/deactivate employee, report, CSV, holiday, leave, correction update + insert, audit log, QR scan, single-use proof).
**Not tested:** your real schema, MySQL 8 itself, the PowerShell scripts (no Windows here), and the CI workflow on GitHub.

## Known limits

- A QR code can be photographed and sent to someone off-site; it works for under a minute, and GPS must still pass. This raises the bar, it doesn't make presence provable.
- The kiosk URL carries `KIOSK_KEY` in the query string. Keep it on the office PC only and rotate it if it leaks.
- Admin login rate limiting is in memory (resets on restart; fine for one Waitress process).
- Holidays are global; employees aren't tied to one office, so absences can't be filtered by office.
- A correction that creates a brand-new record may need extra NOT NULL columns; list them in `ATT["extra_insert"]`.
