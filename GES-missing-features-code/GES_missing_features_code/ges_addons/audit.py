import json
from flask import Blueprint, session, jsonify
from .db import get_db

bp = Blueprint("addon_audit", __name__)

def log_action(action, entity_type=None, entity_id=None, details=None):
    db = get_db()
    db.execute("INSERT INTO addon_audit_logs(actor,action,entity_type,entity_id,details) VALUES(?,?,?,?,?)",
      (session.get("username"), action, entity_type, str(entity_id) if entity_id is not None else None,
       json.dumps(details or {}, default=str)))
    db.commit()
    db.close()

@bp.get("/api/audit-logs")
def logs():
    if session.get("role") not in ("admin", "auditor"):
        return jsonify(error="Forbidden"), 403
    db = get_db()
    rows = db.execute("SELECT * FROM addon_audit_logs ORDER BY id DESC LIMIT 500").fetchall()
    db.close()
    return jsonify([dict(r) for r in rows])
