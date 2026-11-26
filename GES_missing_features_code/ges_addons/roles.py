from functools import wraps
from flask import session, jsonify

def roles_required(*roles):
    def deco(fn):
        @wraps(fn)
        def wrapped(*args, **kwargs):
            if not session.get("user_id"):
                return jsonify(error="Login required"), 401
            if session.get("role") not in roles:
                return jsonify(error="Forbidden"), 403
            return fn(*args, **kwargs)
        return wrapped
    return deco
