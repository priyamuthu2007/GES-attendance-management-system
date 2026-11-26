from math import radians, sin, cos, sqrt, atan2
from flask import Blueprint, request, current_app, jsonify
from .audit import log_action

bp = Blueprint("addon_gps", __name__)

def distance_m(lat1, lon1, lat2, lon2):
    r=6371000
    p1,p2=radians(lat1),radians(lat2)
    dp,dl=radians(lat2-lat1),radians(lon2-lon1)
    a=sin(dp/2)**2+cos(p1)*cos(p2)*sin(dl/2)**2
    return 2*r*atan2(sqrt(a),sqrt(1-a))

@bp.post("/api/validate-office-location")
def validate_location():
    d=request.get_json(silent=True) or {}
    try:
        lat,lon=float(d["latitude"]),float(d["longitude"])
        accuracy=float(d.get("accuracy",999999))
        if not (-90<=lat<=90 and -180<=lon<=180): raise ValueError()
    except (KeyError,TypeError,ValueError):
        return jsonify(error="Valid latitude and longitude required"),400
    office_lat=current_app.config.get("OFFICE_LAT")
    office_lon=current_app.config.get("OFFICE_LON")
    if office_lat is None or office_lon is None:
        return jsonify(error="Configure OFFICE_LAT and OFFICE_LON first"),503
    radius=float(current_app.config.get("OFFICE_RADIUS_METERS",50))
    distance=distance_m(lat,lon,float(office_lat),float(office_lon))
    allowed=distance<=radius and accuracy<=float(current_app.config.get("MAX_GPS_ACCURACY_METERS",100))
    log_action("gps_check","location",None,{"distance_m":round(distance,2),"accuracy_m":accuracy,"allowed":allowed})
    return jsonify(allowed=allowed,distance_m=round(distance,2),accuracy_m=accuracy,radius_m=radius)

@bp.post("/api/location-risk-check")
def risk_check():
    d=request.get_json(silent=True) or {}
    signals=[]
    try:
        lat,lon=float(d["latitude"]),float(d["longitude"])
        accuracy=float(d.get("accuracy",999999))
        if not (-90<=lat<=90 and -180<=lon<=180): signals.append("invalid_coordinates")
        if accuracy<=0 or accuracy>500: signals.append("poor_accuracy")
        if d.get("mock_location") is True: signals.append("client_reports_mock_location")
        if not d.get("timestamp"): signals.append("missing_timestamp")
    except (KeyError,TypeError,ValueError):
        signals.append("malformed_location")
    db=__import__("ges_addons.db",fromlist=["get_db"]).get_db()
    db.execute("INSERT INTO addon_security_events(username,event_type,details) VALUES(?,?,?)",
      (str(d.get("username","unknown")),"gps_risk_check",",".join(signals)))
    db.commit(); db.close()
    return jsonify(review_required=bool(signals),signals=signals,
      limitation="Browser GPS and client flags cannot prove a device is not spoofed.")
