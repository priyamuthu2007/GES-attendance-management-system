# GES Smart Attendance — add-on code for missing features

These modules are a Flask + SQLite integration starter. They add separate addon tables and routes; they do not replace Week 1 files.

## 1. Install
`pip install Flask`

## 2. Add to existing app.py
After creating `app = Flask(__name__)` and configuring `SECRET_KEY`, add:

```python
from ges_addons.config import configure_addons
from ges_addons.db import init_addon_tables
from ges_addons.accounts import bp as accounts_bp
from ges_addons.audit import bp as audit_bp
from ges_addons.gps import bp as gps_bp
from ges_addons.payroll import bp as payroll_bp
from ges_addons.backup import bp as backup_bp
from ges_addons.monitoring import bp as monitoring_bp

configure_addons(app)
init_addon_tables(app)
for addon in (accounts_bp, audit_bp, gps_bp, payroll_bp, backup_bp, monitoring_bp):
    app.register_blueprint(addon)
```

Set a strong `SECRET_KEY`, `DATABASE_PATH`, `OFFICE_LAT`, `OFFICE_LON` and `BACKUP_DIR` environment variables. Never commit real secrets or office coordinates.

## 3. Endpoints
- POST `/api/accounts` (admin/HR)
- POST `/api/addon-login`, POST `/api/addon-logout`
- GET `/api/audit-logs` (admin/auditor)
- POST `/api/validate-office-location`
- POST `/api/location-risk-check`
- GET `/api/reports/attendance.csv?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD`
- POST `/api/admin/backup` and POST `/api/admin/restore/<filename>` (admin)
- GET `/health`

## Important integration limitations
- Account management uses its own `addon_users` table. Integrate with your existing login/user table deliberately; do not run two competing login systems in production.
- CSV export assumes `attendance(employee_id,date,check_in,check_out,status)`. Change the SELECT to match your Week 1 database schema.
- GPS requires real office coordinates in configuration. Radius defaults to 50 metres.
- Browser GPS and client-provided mock-location flags cannot prove that a device is not spoofed. Treat signals as review indicators, not proof.
- Backup/restore code is SQLite-specific. Store encrypted backups off-host and test restoration; use native tooling for other databases.
- HTTPS must be configured at your approved production host/reverse proxy. Flask development server is not production HTTPS.
- Add CSRF protection, rate limiting, secure session settings, access review, privacy/retention approval, and real monitoring/alerting before a real pilot.
- The location notice is a draft requiring HR/management approval. These files do not establish production readiness.
