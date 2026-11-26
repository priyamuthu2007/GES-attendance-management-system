import time
from flask import Blueprint, jsonify
from .db import get_db
bp=Blueprint("addon_monitor",__name__)
started=time.time()

@bp.get("/health")
def health():
    try:
        db=get_db(); db.execute("SELECT 1"); db.close()
        return jsonify(status="ok",database="ok",uptime_seconds=round(time.time()-started,1))
    except Exception:
        return jsonify(status="degraded",database="unavailable"),503
