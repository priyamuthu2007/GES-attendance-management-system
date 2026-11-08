import 'package:geolocator/geolocator.dart';

import '../domain/location_provider.dart';
import '../domain/geofence.dart';

class GeolocatorLocationProvider implements LocationProvider {
  @override
  Future<LocationFix> getFreshFix() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Turn on device location services and try again.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Location permission is required for attendance.');
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        timeLimit: Duration(seconds: 20),
      ),
    );
    return LocationFix(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeters: position.accuracy,
      capturedAt: position.timestamp,
    );
  }
}
