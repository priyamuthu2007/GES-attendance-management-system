import 'dart:math' as math;

const earthRadiusMeters = 6371000.0;

class PlantFence {
  const PlantFence({
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
    required this.maxAccuracyMeters,
  });

  final double latitude;
  final double longitude;
  final double radiusMeters;
  final double maxAccuracyMeters;

  void validate() {
    if (!_validCoordinates(latitude, longitude) ||
        !radiusMeters.isFinite ||
        radiusMeters <= 0 ||
        !maxAccuracyMeters.isFinite ||
        maxAccuracyMeters <= 0) {
      throw ArgumentError('Plant fence configuration is invalid.');
    }
  }
}

class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.capturedAt,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime capturedAt;
}

class GeofenceResult {
  const GeofenceResult({
    required this.accepted,
    required this.distanceMeters,
    required this.reason,
  });

  final bool accepted;
  final double? distanceMeters;
  final String? reason;
}

GeofenceResult verifyLocation({
  required PlantFence fence,
  required LocationFix fix,
  required DateTime now,
  Duration maxFixAge = const Duration(seconds: 30),
  Duration allowedClockSkew = const Duration(seconds: 5),
}) {
  fence.validate();

  if (!_validCoordinates(fix.latitude, fix.longitude)) {
    return const GeofenceResult(
      accepted: false,
      distanceMeters: null,
      reason: 'GPS returned invalid coordinates.',
    );
  }
  if (!fix.accuracyMeters.isFinite ||
      fix.accuracyMeters < 0 ||
      fix.accuracyMeters > fence.maxAccuracyMeters) {
    return const GeofenceResult(
      accepted: false,
      distanceMeters: null,
      reason: 'GPS accuracy is too low.',
    );
  }

  final age = now.difference(fix.capturedAt);
  if (age > maxFixAge || age < -allowedClockSkew) {
    return const GeofenceResult(
      accepted: false,
      distanceMeters: null,
      reason: 'GPS fix is stale or has an invalid timestamp.',
    );
  }

  final distance = distanceInMeters(
    fix.latitude,
    fix.longitude,
    fence.latitude,
    fence.longitude,
  );
  if (distance + fix.accuracyMeters > fence.radiusMeters) {
    return GeofenceResult(
      accepted: false,
      distanceMeters: distance,
      reason: 'GPS does not confirm the phone is within the plant geofence.',
    );
  }

  return GeofenceResult(accepted: true, distanceMeters: distance, reason: null);
}

double distanceInMeters(
  double latitude1,
  double longitude1,
  double latitude2,
  double longitude2,
) {
  if (!_validCoordinates(latitude1, longitude1) ||
      !_validCoordinates(latitude2, longitude2)) {
    throw ArgumentError('Latitude or longitude is out of range.');
  }

  final latitudeDelta = _radians(latitude2 - latitude1);
  final longitudeDelta = _radians(longitude2 - longitude1);
  final haversine =
      math.pow(math.sin(latitudeDelta / 2), 2) +
      math.cos(_radians(latitude1)) *
          math.cos(_radians(latitude2)) *
          math.pow(math.sin(longitudeDelta / 2), 2);
  final bounded = haversine.clamp(0.0, 1.0);
  return (2 *
          earthRadiusMeters *
          math.atan2(math.sqrt(bounded), math.sqrt(1 - bounded)))
      .toDouble();
}

bool _validCoordinates(double latitude, double longitude) =>
    latitude.isFinite &&
    longitude.isFinite &&
    latitude >= -90 &&
    latitude <= 90 &&
    longitude >= -180 &&
    longitude <= 180;

double _radians(double degrees) => degrees * math.pi / 180;
