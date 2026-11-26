import os, sqlite3, shutil
from datetime import datetime
from flask import Blueprint, current_app, jsonify
from .roles import roles_required
from .audit import log_action

bp=Blueprint("addon_backup",__name__)

@bp.post("/api/admin/backup")
@roles_required("admin")
def create_backup():
    dbpath=current_app.config.get("DATABASE","attendance.db")
    folder=current_app.config.get("BACKUP_DIR","backups")
    os.makedirs(folder,exist_ok=True)
    name="attendance-"+datetime.utcnow().strftime("%Y%m%d-%H%M%S")+".sqlite"
    target_path=os.path.join(folder,name)
    src=sqlite3.connect(dbpath); dst=sqlite3.connect(target_path)
    try: src.backup(dst)
    finally: dst.close(); src.close()
    log_action("backup_created","backup",name)
    return jsonify(filename=name),201

@bp.post("/api/admin/restore/<filename>")
@roles_required("admin")
def restore(filename):
    if os.path.basename(filename)!=filename or not filename.endswith(".sqlite"):
        return jsonify(error="Invalid filename"),400
    folder=current_app.config.get("BACKUP_DIR","backups")
    src=os.path.join(folder,filename); dst=current_app.config.get("DATABASE","attendance.db")
    if not os.path.isfile(src): return jsonify(error="Backup not found"),404
    check=sqlite3.connect(src)
    try:
        if check.execute("PRAGMA integrity_check").fetchone()[0]!="ok":
            return jsonify(error="Backup integrity check failed"),400
    finally: check.close()
    shutil.copy2(src,dst)
    log_action("backup_restored","backup",filename)
    return jsonify(message="Restored; verify the application before use")
