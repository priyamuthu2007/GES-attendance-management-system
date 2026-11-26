from flask import Blueprint, request, session, jsonify
from werkzeug.security import generate_password_hash, check_password_hash
from .db import get_db
from .roles import roles_required
from .audit import log_action

bp = Blueprint("addon_accounts", __name__)

@bp.post("/api/accounts")
@roles_required("admin", "hr")
def create_account():
    d = request.get_json(silent=True) or {}
    username, password, name = str(d.get("username","")).strip(), str(d.get("password","")), str(d.get("full_name","")).strip()
    role = str(d.get("role","employee")).lower()
    if not username or not name or len(password) < 10:
        return jsonify(error="Username, full name and password (10+ characters) required"), 400
    if role not in {"admin","manager","hr","auditor","employee"}:
        return jsonify(error="Invalid role"), 400
    db = get_db()
    try:
        cur = db.execute("INSERT INTO addon_users(username,password_hash,full_name,role) VALUES(?,?,?,?)",
                         (username, generate_password_hash(password), name, role))
        db.commit()
        uid = cur.lastrowid
    except Exception:
        db.close()
        return jsonify(error="Account could not be created; username may already exist"), 409
    db.close()
    log_action("account_created", "user", uid, {"username": username, "role": role})
    return jsonify(id=uid, username=username, role=role), 201

@bp.post("/api/addon-login")
def login():
    d = request.get_json(silent=True) or {}
    db = get_db()
    user = db.execute("SELECT * FROM addon_users WHERE username=? AND active=1",
                      (str(d.get("username","")).strip(),)).fetchone()
    db.close()
    if not user or not check_password_hash(user["password_hash"], str(d.get("password",""))):
        return jsonify(error="Invalid username or password"), 401
    session.clear()
    session.update(user_id=user["id"], username=user["username"], role=user["role"])
    log_action("login", "user", user["id"])
    return jsonify(message="Logged in", role=user["role"])

@bp.post("/api/addon-logout")
def logout():
    session.clear()
    return jsonify(message="Logged out")
