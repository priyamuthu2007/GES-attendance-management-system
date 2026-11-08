import 'geofence.dart';

abstract interface class LocationProvider {
  Future<LocationFix> getFreshFix();
}
