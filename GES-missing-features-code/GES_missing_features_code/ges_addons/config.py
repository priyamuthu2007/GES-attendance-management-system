import os

def configure_addons(app):
    app.config.setdefault("DATABASE",os.getenv("DATABASE_PATH","attendance.db"))
    app.config.setdefault("BACKUP_DIR",os.getenv("BACKUP_DIR","backups"))
    app.config.setdefault("OFFICE_LAT",float(os.environ["OFFICE_LAT"]) if os.getenv("OFFICE_LAT") else None)
    app.config.setdefault("OFFICE_LON",float(os.environ["OFFICE_LON"]) if os.getenv("OFFICE_LON") else None)
    app.config.setdefault("OFFICE_RADIUS_METERS",50)
    app.config.setdefault("MAX_GPS_ACCURACY_METERS",100)
    app.config.setdefault("SESSION_COOKIE_HTTPONLY",True)
    app.config.setdefault("SESSION_COOKIE_SAMESITE","Lax")
