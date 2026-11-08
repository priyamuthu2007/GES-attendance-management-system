import 'package:test/test.dart';
import 'package:ges_offline_attendance/data/attendance_repository.dart';
import 'package:ges_offline_attendance/domain/attendance_event.dart';
import 'package:ges_offline_attendance/domain/attendance_rules.dart';
import 'package:ges_offline_attendance/domain/attendance_session.dart';
import 'package:ges_offline_attendance/domain/geofence.dart';
import 'package:ges_offline_attendance/domain/location_provider.dart';
import 'package:ges_offline_attendance/services/attendance_workflow.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  timezone_data.initializeTimeZones();
  final time = tz.TZDateTime(
    tz.getLocation('Asia/Kolkata'),
    2026,
    11,
    5,
    9,
    12,
  );
  final profile = LocalProfile(
    plant: const PlantConfiguration(
      name: 'Test Plant',
      latitude: 13,
      longitude: 80,
      radiusMeters: 10,
      timezoneId: 'Asia/Kolkata',
    ),
    employee: const EmployeeProfile(
      employeeId: 'EMP-1',
      name: 'Test Employee',
      shift: Shift(startHour: 9, startMinute: 0, gracePeriodMinutes: 5),
      shiftDays: {1, 2, 3, 4, 5, 6, 7},
    ),
  );

  test(
    'records an in-geofence check-in after PIN and GPS verification',
    () async {
      final store = FakeStore();
      final workflow = AttendanceWorkflow(
        repository: store,
        locationProvider: FakeLocationProvider(
          LocationFix(
            latitude: 13,
            longitude: 80,
            accuracyMeters: 2,
            capturedAt: time,
          ),
        ),
        deviceId: 'device-1',
        clock: () => time,
      );

      final event = await workflow.record(
        profile: profile,
        type: AttendanceEventType.checkIn,
        pin: '123456',
      );

      expect(store.events, hasLength(1));
      expect(event.isLate, isTrue);
      expect(event.totalDelayMinutes, 12);
      expect(event.delayAfterGraceMinutes, 7);
      expect(
        event.verificationMethod,
        AttendanceVerificationMethod.employeePin,
      );
      expect(
        event.verificationStatus,
        AttendanceVerificationStatus.pinConfirmed,
      );
      expect(store.authenticatedPins, ['123456']);
    },
  );

  test(
    'does not request GPS or save attendance when the PIN is rejected',
    () async {
      final store = FakeStore()..rejectPin = true;
      final location = FakeLocationProvider(
        LocationFix(
          latitude: 13,
          longitude: 80,
          accuracyMeters: 2,
          capturedAt: time,
        ),
      );
      final workflow = AttendanceWorkflow(
        repository: store,
        locationProvider: location,
        deviceId: 'device-1',
        clock: () => time,
      );

      await expectLater(
        workflow.record(
          profile: profile,
          type: AttendanceEventType.checkIn,
          pin: '654321',
        ),
        throwsA(isA<StateError>()),
      );
      expect(store.events, isEmpty);
      expect(location.requested, isTrue);
    },
  );

  test('does not save attendance when geofencing rejects the fix', () async {
    final store = FakeStore();
    final workflow = AttendanceWorkflow(
      repository: store,
      locationProvider: FakeLocationProvider(
        LocationFix(
          latitude: 13,
          longitude: 80.001,
          accuracyMeters: 2,
          capturedAt: time,
        ),
      ),
      deviceId: 'device-1',
      clock: () => time,
    );

    await expectLater(
      workflow.record(
        profile: profile,
        type: AttendanceEventType.checkIn,
        pin: '123456',
      ),
      throwsA(isA<StateError>()),
    );
    expect(store.events, isEmpty);
  });

  test('allows checkout after midnight for an open night shift', () async {
    var now = tz.TZDateTime(
      tz.getLocation('Asia/Kolkata'),
      2026,
      11,
      5,
      22,
      12,
    );
    final nightProfile = LocalProfile(
      plant: profile.plant,
      employee: EmployeeProfile(
        employeeId: profile.employee.employeeId,
        name: profile.employee.name,
        shift: const Shift(
          name: 'Night',
          startHour: 22,
          startMinute: 0,
          endHour: 6,
          endMinute: 0,
          gracePeriodMinutes: 5,
          checkInWindowMinutes: 120,
        ),
        shiftDays: {1, 2, 3, 4, 5, 6, 7},
      ),
    );
    final location = FakeLocationProvider(
      LocationFix(
        latitude: 13,
        longitude: 80,
        accuracyMeters: 2,
        capturedAt: now,
      ),
    );
    final store = FakeStore();
    final workflow = AttendanceWorkflow(
      repository: store,
      locationProvider: location,
      deviceId: 'device-1',
      clock: () => now,
    );

    final checkIn = await workflow.record(
      profile: nightProfile,
      type: AttendanceEventType.checkIn,
      pin: '123456',
    );
    expect(checkIn.attendanceDate, '2026-11-05');

    now = tz.TZDateTime(tz.getLocation('Asia/Kolkata'), 2026, 11, 6, 6, 12);
    location.fix = LocationFix(
      latitude: 13,
      longitude: 80,
      accuracyMeters: 2,
      capturedAt: now,
    );
    final checkOut = await workflow.record(
      profile: nightProfile,
      type: AttendanceEventType.checkOut,
      pin: '123456',
    );

    expect(checkOut.attendanceDate, '2026-11-05');
    expect(checkOut.shiftName, 'Night');
    expect(store.events, hasLength(2));
  });
}

class FakeStore implements AttendanceStore {
  final List<AttendanceEvent> events = [];
  final List<String> authenticatedPins = [];
  bool rejectPin = false;

  @override
  Future<void> recordEvent(AttendanceEvent event, {required String pin}) async {
    authenticatedPins.add(pin);
    if (rejectPin) throw StateError('Incorrect employee PIN.');
    events.add(event);
  }

  @override
  Future<List<AttendanceEvent>> eventsForDate(
    String employeeId,
    String attendanceDate,
  ) async => events
      .where(
        (event) =>
            event.employeeId == employeeId &&
            event.attendanceDate == attendanceDate,
      )
      .toList();

  @override
  Future<List<AttendanceSession>> pollAttendance(
    LocalProfile profile,
    DateTime nowUtc,
  ) async {
    final zone = tz.getLocation(profile.plant.timezoneId);
    final localNow = tz.TZDateTime.from(nowUtc, zone);
    return [-1, 0, 1]
        .map((offset) => localNow.add(Duration(days: offset)))
        .where((date) => profile.employee.shiftDays.contains(date.weekday))
        .map((date) {
          final occurrence = shiftOccurrence(
            shift: profile.employee.shift,
            localDate: date,
            timezoneId: profile.plant.timezoneId,
          );
          final daily = events
              .where(
                (event) =>
                    event.employeeId == profile.employee.employeeId &&
                    event.attendanceDate == occurrence.shiftDate,
              )
              .toList();
          final checkedIn = daily.any(
            (event) => event.type == AttendanceEventType.checkIn,
          );
          final checkedOut = daily.any(
            (event) => event.type == AttendanceEventType.checkOut,
          );
          return AttendanceSession(
            sessionId: shiftSessionId(
              employeeId: profile.employee.employeeId,
              shiftDate: occurrence.shiftDate,
              shiftName: profile.employee.shift.name,
            ),
            employeeId: profile.employee.employeeId,
            shiftName: profile.employee.shift.name,
            shiftDate: occurrence.shiftDate,
            startUtc: occurrence.start.toUtc(),
            endUtc: occurrence.end.toUtc(),
            checkInDeadlineUtc: occurrence.checkInDeadline.toUtc(),
            status: checkedOut
                ? AttendanceSessionStatus.completed
                : checkedIn
                ? AttendanceSessionStatus.present
                : localNow.isAfter(occurrence.checkInDeadline)
                ? AttendanceSessionStatus.absent
                : AttendanceSessionStatus.scheduled,
            updatedAtUtc: nowUtc,
          );
        })
        .toList();
  }

  @override
  Future<List<AttendanceSession>> sessionsForRange(
    String employeeId,
    String startDate,
    String endDate,
  ) async => [];
}

class FakeLocationProvider implements LocationProvider {
  FakeLocationProvider(this.fix);

  LocationFix fix;
  bool requested = false;

  @override
  Future<LocationFix> getFreshFix() async {
    requested = true;
    return fix;
  }
}
