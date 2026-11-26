# GES Smart Attendance add-on reference files

The add-on has been adapted into the main Flask/PostgreSQL project. Its active routes
and PostgreSQL schema are in [`attendance/addon_features.py`](../../attendance/addon_features.py)
and [`attendance/schema.sql`](../../attendance/schema.sql); the app factory
registers these routes and uses the existing employee login.

The files in `ges_addons/` are the original SQLite starter implementation and
are kept here as reference only. Do not import them into the running app: they
create a second login/account system and their backup/restore functions operate
on SQLite, not the project's PostgreSQL database.

## Integrated features

- Account creation with roles, employee details, and assigned shifts:
  `POST /api/accounts` (admin or HR; only admins can assign elevated roles).
- Audit history: `GET /api/audit-logs` (admin or auditor).
- Office-location validation and risk-review signals:
  `POST /api/validate-office-location` and `POST /api/location-risk-check`.
  Risk checks store review signals, not raw coordinates, and cannot prove that
  GPS data is genuine.
- Attendance CSV export:
  `GET /api/reports/attendance.csv?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD`.
- Employee location notice: `GET /location-notice`.
- PostgreSQL health check: `GET /health`.

All state-changing routes use the app's existing CSRF protection. Admin access
is assigned locally after database setup:

```powershell
.\.venv\Scripts\python.exe manage.py set-role EMPLOYEE-001 admin
```

The old PowerShell backup utilities in `ges-additions/` target MySQL and are
not compatible with the active PostgreSQL app. Use PostgreSQL `pg_dump` and
`pg_restore` for operator-managed backup and recovery. The SQLite restore
endpoint is intentionally not exposed.
