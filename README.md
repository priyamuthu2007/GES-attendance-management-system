# GES Smart Attendance

The app uses the requested stack: semantic HTML, CSS, vanilla JavaScript, the browser Geolocation API, Python Flask, and MySQL Community Server. It supports both registered Chennai offices, office-local attendance dates, assigned employee shifts, and separate geofenced check-in/check-out events.

The separate [`mobile/`](./mobile/) Flutter project implements offline-first attendance polling on the phone. Morning, evening, and night shift sessions are generated and reconciled locally; geofencing and attendance records require no internet. Attendance is unlocked only after a fresh GPS fix places the employee inside the default 10-metre fence, and each check-in/out is confirmed with a locally verified employee PIN. Administrator tools use a separate PIN and support encrypted backup/import for manual offline consolidation. Encrypted JSON is stored on the phone; PIN confirmation is self-attestation, not proof of identity. The poller runs while the app is open and catches up missed sessions on the next launch/resume; mobile operating systems do not guarantee exact-time processing while the app is closed.

## Attendance workflow

1. Employee signs in with an administrator-provisioned employee ID and password.
2. The app fetches the employee's assigned shift for the office-local day.
3. The browser requests fresh GPS permission and shows the nearest office and distance.
4. The employee checks in only if the server-calculated nearest-office distance plus GPS-reported accuracy is no more than 50 m. GPS accuracy must also be 25 m or better.
5. The same fresh-location and server-side checks apply to check-out.
6. MySQL stores the employee, office-local attendance date, UTC check-in/check-out timestamps, coordinates, GPS accuracy, distance, and office used. Database uniqueness prevents multiple daily records; a transaction locks the employee row to prevent concurrent open check-ins.

The app does not force check-in during shift hours; it fetches and displays the assigned shift as in the supplied workflow. An employee must have a shift assigned for that weekday to check in. An open check-in must be checked out before another check-in can be created.

## Local development

Requirements: Python 3.11+ and MySQL Community Server 8+.

1. Create a MySQL database and separate application and schema-migration users. The app account cannot alter tables; use the migration account only for `manage.py init-db`. Connect as a MySQL administrator and run:

   ```sql
   CREATE DATABASE ges_attendance CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
   CREATE USER 'ges_attendance_app'@'localhost' IDENTIFIED BY 'REPLACE_WITH_A_UNIQUE_PASSWORD';
   CREATE USER 'ges_attendance_migrator'@'localhost' IDENTIFIED BY 'REPLACE_WITH_A_DIFFERENT_PASSWORD';
   GRANT SELECT, INSERT, UPDATE, DELETE
     ON ges_attendance.* TO 'ges_attendance_app'@'localhost';
   GRANT CREATE, ALTER, INDEX, REFERENCES
     ON ges_attendance.* TO 'ges_attendance_migrator'@'localhost';
   FLUSH PRIVILEGES;
   ```

2. Copy `.env.example` to `.env`. Set a random `FLASK_SECRET_KEY` (generate with `python -c "import secrets; print(secrets.token_urlsafe(48))"`), and set both the app (`MYSQL_USER`, `MYSQL_PASSWORD`) and migration (`MYSQL_MIGRATION_USER`, `MYSQL_MIGRATION_PASSWORD`) credentials. The office coordinates and `Asia/Kolkata` timezone are prefilled from the pins you supplied; verify that each pin is on the employee entrance. Never commit `.env`.
3. Create a virtual environment and install dependencies:

   ```powershell
   py -3 -m venv .venv
   .\.venv\Scripts\python.exe -m pip install -r requirements.txt
   ```

4. Create tables:

   ```powershell
   .\.venv\Scripts\python.exe manage.py init-db
   ```

5. Provision an employee and weekday shift (default weekdays 9 AM–5 PM):

   ```powershell
   .\.venv\Scripts\python.exe manage.py create-employee EMPLOYEE-001 --days mon,tue,wed,thu,fri --shift-start 09:00 --shift-end 17:00
   ```

   The password is requested twice without being displayed. Change a shift with:

   ```powershell
   .\.venv\Scripts\python.exe manage.py set-shift EMPLOYEE-001 --days mon,tue,wed,thu,fri --shift-start 09:00 --shift-end 17:00
   ```

6. Run a local development server:

   ```powershell
   $env:SESSION_COOKIE_SECURE = "false"
   .\.venv\Scripts\flask.exe --app wsgi:app run --host 127.0.0.1 --port 5000
   ```

   Open `http://127.0.0.1:5000`. Browser geolocation works on localhost for development. For normal use, the HTTPS URL provided by the private VPN is required.

## Self-host at the Anna Nagar office

The Anna Nagar PC is the single app/MySQL host. The Manapakkam PC and employee phones use a private VPN to reach the same app and database. Do not start a separate app or database at the second office.

1. Install Python 3.11+, MySQL 8+, and Tailscale on the Anna Nagar host. Keep MySQL local-only; do not open port 3306 to the internet or office Wi-Fi. Set MySQL to start automatically with Windows.
2. Create the database/user above. Copy the project onto the host and configure its ignored `.env`. For the host-to-MySQL local connection, use `MYSQL_HOST=127.0.0.1`.
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

The host must be powered on with MySQL, internet, and the private VPN available for the full check-in/check-out period. The project includes `scripts\uninstall-windows-host.ps1` to remove its startup task without deleting data. Back up the MySQL database regularly to storage separate from the host and test restoring those backups.

Private VPN plan terms may limit business use or device counts; confirm your organization's eligibility. The office PC, internet, backups, power protection, and security maintenance are still operational responsibilities even if cloud hosting has no bill.

## Security and operational limitations

- Passwords use bcrypt; session cookies are HTTP-only, SameSite, and HTTPS-secure for the tailnet deployment. State-changing API calls use CSRF protection and login attempts are rate limited. The app's MySQL account has only data access; schema changes require the separate migration account.
- The server repeats all coordinate/radius checks; the browser is not trusted to authorize attendance.
- Browser GPS coordinates and accuracy can be spoofed, and indoor GPS may be poor. This is not proof of physical presence. If attendance has payroll/legal significance, add an onsite control (such as managed-device verification, a rotating office QR code, NFC, or supervised exception workflow).
- The system stores employee coordinates and attendance times. Define notice, access controls, retention, backup, and deletion policies for employee data.
- This MySQL schema is for a new database and does not automatically migrate existing PostgreSQL records.

Run the test suite with:

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```
