import 'package:test/test.dart';
import 'package:ges_offline_attendance/domain/geofence.dart';

void main() {
  const fence = PlantFence(
    latitude: 13,
    longitude: 80,
    radiusMeters: 10,
    maxAccuracyMeters: 25,
  );
  final now = DateTime.utc(2026, 11, 5, 6);

  test('accepts a fresh accurate fix at the plant center', () {
    final result = verifyLocation(
      fence: fence,
      fix: LocationFix(
        latitude: 13,
        longitude: 80,
        accuracyMeters: 3,
        capturedAt: now,
      ),
      now: now,
    );

    expect(result.accepted, isTrue);
    expect(result.distanceMeters, 0);
  });

  test('rejects points whose GPS uncertainty crosses the fence', () {
    final result = verifyLocation(
      fence: fence,
      fix: LocationFix(
        latitude: 13,
        longitude: 80.00008,
        accuracyMeters: 3,
        capturedAt: now,
      ),
      now: now,
    );

    expect(result.accepted, isFalse);
    expect(result.reason, contains('does not confirm'));
  });

  test('rejects poor-accuracy and stale fixes', () {
    final poorFix = verifyLocation(
      fence: fence,
      fix: LocationFix(
        latitude: 13,
        longitude: 80,
        accuracyMeters: 26,
        capturedAt: now,
      ),
      now: now,
    );
    final staleFix = verifyLocation(
      fence: fence,
      fix: LocationFix(
        latitude: 13,
        longitude: 80,
        accuracyMeters: 3,
        capturedAt: now.subtract(const Duration(seconds: 31)),
      ),
      now: now,
    );

    expect(poorFix.accepted, isFalse);
    expect(staleFix.accepted, isFalse);
    expect(staleFix.reason, contains('stale'));
  });

  test('rejects invalid coordinates', () {
    final result = verifyLocation(
      fence: fence,
      fix: LocationFix(
        latitude: double.nan,
        longitude: 80,
        accuracyMeters: 3,
        capturedAt: now,
      ),
      now: now,
    );

    expect(result.accepted, isFalse);
    expect(result.distanceMeters, isNull);
  });
}
