# GES Smart Attendance

The app uses the requested stack: semantic HTML, CSS, vanilla JavaScript, the browser Geolocation API, Python Flask, and PostgreSQL. It supports multiple registered sites, office-local attendance dates, employee-to-site assignments, and separate geofenced check-in/check-out events.

The separate [`mobile/`](./mobile/) Flutter project implements offline-first attendance polling on the phone. Morning, evening, and night shift sessions are generated and reconciled locally; geofencing and attendance records require no internet. Attendance is unlocked only after a fresh GPS fix places the employee inside the default 10-metre fence, and each check-in/out is confirmed with a locally verified employee PIN. Administrator tools use a separate PIN and support encrypted backup/import for manual offline consolidation. Encrypted JSON is stored on the phone; PIN confirmation is self-attestation, not proof of identity. The poller runs while the app is open and catches up missed sessions on the next launch/resume; mobile operating systems do not guarantee exact-time processing while the app is closed.

## Attendance workflow

1. Employee signs in with an administrator-provisioned employee ID and password.
2. The app loads the employee's assigned sites and attendance status.
3. The browser requests fresh GPS permission and shows the nearest office and distance.
4. The browser collects fresh GPS readings for up to 30 seconds, preferring a fix with 5 m accuracy. Check-in is accepted only if GPS accuracy is 5 m or better and the server-calculated nearest-office distance plus GPS-reported accuracy is no more than 10 m.
5. The same fresh-location and server-side checks apply to check-out.
6. PostgreSQL stores the employee, office-local attendance date, UTC check-in/check-out timestamps, coordinates, GPS accuracy, distance, and office used. Database uniqueness prevents multiple daily records; a transaction locks the employee row to prevent concurrent open check-ins.

Employees can check in on any day and at any time, but only within one of their assigned site geofences. Shift hours are not an attendance restriction. An open check-in must be checked out before another check-in can be created.

## Local development

Requirements: Python 3.11+ and PostgreSQL. Flask serves the employee attendance interface from [`templates/index.html`](./templates/index.html), with its backend integration in [`static/app.js`](./static/app.js). The separate [`FRONTEND.html`](../FRONTEND.html) dashboard is not used by the Flask app.

1. Start the PostgreSQL service and copy `.env.example` to `.env`. Set and verify the GPS coordinates for every registered site before deployment. The roster import expects the office IDs `anna-nagar`, `kpl`, `kpl-stp`, `nlc-m1a`, and `zirconium`. Never commit `.env`.
2. Create a virtual environment and install dependencies:

   ```powershell
   py -3 -m venv .venv
   .\.venv\Scripts\python.exe -m pip install -r requirements.txt
   ```

3. Configure the local database, app account, migration account, and schema:

   ```powershell
   .\.venv\Scripts\python.exe .\scripts\setup-local-database.py
   ```

   The database defaults to `ges` (override with `PG_DATABASE` in `.env`). Enter the PostgreSQL administrator username and password when prompted. The password is read locally without being displayed or saved. The helper creates the new database and least-privilege accounts, generates fresh application credentials in the ignored `.env`, initializes the schema, and verifies the app connection. This does not migrate any MySQL records; create new employee accounts after setup. If the administrator password is unknown, ask the PostgreSQL administrator to run the setup; do not bypass database authentication. This local setup sets `SESSION_COOKIE_SECURE=false`; use HTTPS and set it to `true` for deployment.

4. Provision an employee and assign at least one registered site:

   ```powershell
   .\.venv\Scripts\python.exe manage.py create-employee EMPLOYEE-001 --sites anna-nagar --days mon,tue,wed,thu,fri --shift-start 09:00 --shift-end 17:00
   ```

   The password is requested twice without being displayed. Use `--flexible-shift` for a seven-day flexible schedule, or `--no-shift` when no shift should be recorded. Attendance is accepted any day at an assigned site regardless of the shift schedule.

   To import employee IDs and site assignments from an `.xlsx` roster, first validate it with:

   ```powershell
   .\.venv\Scripts\python.exe manage.py import-roster "C:\path\to\employee-roster.xlsx" --preview
   ```

   Run the same command without `--preview` to import. The importer reads only the `ID` and `SITE` columns, ignores the workbook's password column, prompts securely for each new employee password, and updates site assignments for existing accounts without changing their passwords. KPL/KPL-STP employees receive flexible shift records for all seven days; other new employees have no fixed weekday shift recorded while their weekly off days are unknown. Existing non-KPL shifts are preserved. Check-in is allowed any day at an assigned site.

5. Run a local development server:

   ```powershell
   $env:SESSION_COOKIE_SECURE = "false"
   .\.venv\Scripts\flask.exe --app wsgi:app run --host 127.0.0.1 --port 5001
   ```

   Open `http://127.0.0.1:5001`. Browser geolocation works on localhost for development. For normal use, the HTTPS URL provided by the private VPN is required.

## Integrated missing-feature add-ons

The copied add-on is integrated with the PostgreSQL database and employee session; its separate SQLite account/login and database restore routes are not used. After initializing the schema, create an employee account and grant the first administrator role locally:

```powershell
.\.venv\Scripts\python.exe manage.py create-employee ADMIN-001 --sites anna-nagar --days mon,tue,wed,thu,fri --shift-start 09:00 --shift-end 17:00
.\.venv\Scripts\python.exe manage.py set-role ADMIN-001 admin
```

The first command asks for an employee password without displaying it. The administrator then signs in through the same employee login. The new endpoints are:

- `POST /api/accounts` (admin or HR; HR can create employee accounts only)
- `GET /api/audit-logs` (admin or auditor)
- `GET /attendance-report` and `GET /api/attendance/report?date=YYYY-MM-DD` (admin, HR or auditor; includes each active employee’s recorded check-in/check-out times for the selected office-local date)
- `POST /api/validate-office-location` and `POST /api/location-risk-check` (signed-in employee)
- `GET /api/reports/attendance.csv?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD` (admin, HR or auditor)
- `GET /location-notice` and `GET /health`

The legacy utilities under `ges-additions/` target MySQL and are not compatible with this PostgreSQL app. Back up PostgreSQL with `pg_dump` and periodically verify recovery with `pg_restore`; the add-on's SQLite backup/restore code is also not exposed against the app database. The location notice is a draft and requires management approval before employee use.

## Self-host at the Anna Nagar office

The Anna Nagar PC is the single app/PostgreSQL host. The Manapakkam PC and employee phones use a private VPN to reach the same app and database. Do not start a separate app or database at the second office.

1. Install Python 3.11+, PostgreSQL, and Tailscale on the Anna Nagar host. Keep PostgreSQL local-only; do not open port 5432 to the internet or office Wi-Fi. Set the PostgreSQL service to start automatically with Windows.
2. Create the database and users as described above. Copy the project onto the host and configure its ignored `.env`. For the host-to-PostgreSQL local connection, use `PG_HOST=127.0.0.1`.
3. Open PowerShell as Administrator in the project folder and install the app startup task:

   ```powershell
   .\scripts\install-windows-host.ps1
   ```

   The script creates `.venv`, installs packages, runs tests, creates the schema, and registers the app to start at Windows boot. It uses Waitress and binds Flask to `127.0.0.1:5000`, not to the public/LAN interfaces.
4. Sign the Anna Nagar host into the organization Tailscale network and enable Tailscale HTTPS certificates. Then run:

   ```powershell
   .\scripts\publish-windows-host.ps1
   ```

   This publishes the local app only to authorized devices in the private tailnet. Do not run Tailscale Funnel, router port forwarding, or public database access.
5. Join the Manapakkam computer and employee devices to the same authorized tailnet. Use the HTTPS URL printed by Tailscale Serve. Provision each employee and assigned shift from the host with `.\.venv\Scripts\python.exe manage.py create-employee ...`.
6. Test sign-in, shift display, check-in, checkout, GPS rejection, duplicate prevention, and database recovery at both offices before rollout.

The host must be powered on with PostgreSQL, internet, and the private VPN available for the full check-in/check-out period. The project includes `scripts\uninstall-windows-host.ps1` to remove its startup task without deleting data. Back up the PostgreSQL database regularly to storage separate from the host and test restoring those backups.

Private VPN plan terms may limit business use or device counts; confirm your organization's eligibility. The office PC, internet, backups, power protection, and security maintenance are still operational responsibilities even if cloud hosting has no bill.

## Security and operational limitations

- Passwords use bcrypt; session cookies are HTTP-only, SameSite, and HTTPS-secure for the tailnet deployment. State-changing API calls use CSRF protection and login attempts are rate limited. The app's PostgreSQL account has only data access; schema changes require the separate migration account.
- The server repeats all coordinate/radius checks; the browser is not trusted to authorize attendance.
- Browser GPS coordinates and accuracy can be spoofed, and indoor GPS may be poor. This is not proof of physical presence. If attendance has payroll/legal significance, add an onsite control (such as managed-device verification, a rotating office QR code, NFC, or supervised exception workflow).
- The system stores employee coordinates and attendance times. Define notice, access controls, retention, backup, and deletion policies for employee data.
- This PostgreSQL schema is for a new database. It does not import data from the previous MySQL database.
- The optional code under `ges-additions/` is legacy MySQL-specific code and is not loaded by the active app.

Run the test suite with:

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```
