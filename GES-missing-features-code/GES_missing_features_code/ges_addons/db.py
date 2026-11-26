import sqlite3
from flask import current_app

def get_db():
    conn = sqlite3.connect(current_app.config.get("DATABASE", "attendance.db"))
    conn.row_factory = sqlite3.Row
    return conn

def init_addon_tables(app):
    with app.app_context():
        db = get_db()
        db.executescript("""
        CREATE TABLE IF NOT EXISTS addon_users(
          id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL,
          password_hash TEXT NOT NULL, full_name TEXT NOT NULL,
          role TEXT NOT NULL CHECK(role IN ('admin','manager','hr','auditor','employee')),
          active INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE IF NOT EXISTS addon_audit_logs(
          id INTEGER PRIMARY KEY AUTOINCREMENT, actor TEXT, action TEXT NOT NULL,
          entity_type TEXT, entity_id TEXT, details TEXT,
          created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS addon_security_events(
          id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT, event_type TEXT,
          details TEXT, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        """)
        db.commit()
        db.close()
