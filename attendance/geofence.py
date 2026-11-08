import math

ATTENDANCE_RADIUS_METERS = 50
MAX_GPS_ACCURACY_METERS = 25
EARTH_RADIUS_METERS = 6_371_000


def valid_coordinate(latitude, longitude):
    return (
        isinstance(latitude, (int, float))
        and not isinstance(latitude, bool)
        and isinstance(longitude, (int, float))
        and not isinstance(longitude, bool)
        and math.isfinite(latitude)
        and math.isfinite(longitude)
        and -90 <= latitude <= 90
        and -180 <= longitude <= 180
    )


def distance_in_meters(latitude1, longitude1, latitude2, longitude2):
    radians = math.radians
    latitude_delta = radians(latitude2 - latitude1)
    longitude_delta = radians(longitude2 - longitude1)
    haversine = (
        math.sin(latitude_delta / 2) ** 2
        + math.cos(radians(latitude1))
        * math.cos(radians(latitude2))
        * math.sin(longitude_delta / 2) ** 2
    )
    haversine = min(1.0, max(0.0, haversine))
    return 2 * EARTH_RADIUS_METERS * math.atan2(
        math.sqrt(haversine), math.sqrt(1 - haversine)
    )


def nearest_office(latitude, longitude, offices):
    return min(
        (
            {
                **office,
                "distanceMeters": distance_in_meters(
                    latitude, longitude, office["latitude"], office["longitude"]
                ),
            }
            for office in offices
        ),
        key=lambda office: office["distanceMeters"],
    )


def validate_location(payload, offices):
    latitude = payload.get("latitude")
    longitude = payload.get("longitude")
    accuracy = payload.get("accuracyMeters")
    if not valid_coordinate(latitude, longitude):
        return None, ({"error": "Valid GPS latitude and longitude are required."}, 400)
    if (
        isinstance(accuracy, bool)
        or not isinstance(accuracy, (int, float))
        or not math.isfinite(accuracy)
        or accuracy < 0
    ):
        return None, ({"error": "A valid GPS accuracy value is required."}, 400)
    if accuracy > MAX_GPS_ACCURACY_METERS:
        return None, (
            {
                "error": "GPS accuracy is too low. Refresh your location and try again.",
                "maxGpsAccuracyMeters": MAX_GPS_ACCURACY_METERS,
            },
            422,
        )
    office = nearest_office(latitude, longitude, offices)
    office["accuracyMeters"] = float(accuracy)
    if office["distanceMeters"] + accuracy > ATTENDANCE_RADIUS_METERS:
        return None, (
            {
                "error": "Your GPS location and accuracy do not confirm that you are within 50 metres of an office.",
                "distanceMeters": round(office["distanceMeters"], 1),
                "nearestOfficeName": office["name"],
            },
            403,
        )
    return office, None
