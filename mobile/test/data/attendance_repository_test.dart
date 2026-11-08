import 'dart:convert';
import 'dart:io';

import 'package:ges_offline_attendance/data/attendance_repository.dart';
import 'package:ges_offline_attendance/domain/attendance_event.dart';
import 'package:ges_offline_attendance/domain/attendance_rules.dart';
import 'package:ges_offline_attendance/domain/attendance_session.dart';
import 'package:ges_offline_attendance/domain/pin_credentials.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as timezone_data;

void main() {
  late Directory directory;
  late AttendanceRepository repository;
  late DateTime now;

  setUpAll(timezone_data.initializeTimeZones);

  setUp(() async {
    now = DateTime.utc(2026, 11, 5, 3, 30);
    directory = await Directory.systemTemp.createTemp('ges-attendance-test-');
    repository = AttendanceRepository(
      directory: directory,
      encryptionKey: List<int>.generate(32, (index) => index),
      clock: () => now,
    );
  });

  tearDown(() => directory.delete(recursive: true));

  Future<void> saveProfile() async {
    await repository.saveProfile(
      plant: const PlantConfiguration(
        name: 'Treatment plant',
        latitude: 13,
        longitude: 80,
      ),
      employee: const EmployeeProfile(
        employeeId: 'EMP-1',
        name: 'Employee One',
        shift: Shift(
          name: 'Morning',
          startHour: 9,
          startMinute: 0,
          gracePeriodMinutes: 5,
        ),
        shiftDays: {1, 2, 3, 4, 5},
      ),
      pinCredential: await PinCredential.create('123456'),
      administratorCredential: await PinCredential.create('111111'),
    );
    final profile = await repository.loadProfile();
    await repository.pollAttendance(profile!, now);
  }

  Future<bool> tryRecord(AttendanceEvent event) async {
    try {
      await repository.recordEvent(event, pin: '123456');
      return true;
    } on StateError {
      return false;
    }
  }

  test('saves and reloads plant, employee, and shift setup', () async {
    await saveProfile();

    final loaded = await repository.loadProfile();

    expect(loaded?.plant.radiusMeters, 50);
    expect(loaded?.employee.employeeId, 'EMP-1');
    expect(loaded?.employee.shiftDays, {1, 2, 3, 4, 5});
    expect(loaded?.employee.shift.gracePeriodMinutes, 5);
    expect(
      File(path.join(directory.path, 'attendance.json')).existsSync(),
      isTrue,
    );
  });

  test('administrator PIN is separate and enforces a lockout', () async {
    await saveProfile();

    expect(await repository.hasAdministratorPin(), isTrue);
    await expectLater(
      repository.verifyAdministratorPin('123456'),
      throwsA(
        predicate(
          (error) =>
              error is StateError &&
              error.message.toString().contains('Incorrect administrator PIN'),
        ),
      ),
    );
    await repository.verifyAdministratorPin('111111');

    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await repository.verifyAdministratorPin('654321');
      } on StateError {
        // The attempts are expected to fail and accumulate toward lockout.
      }
    }
    await expectLater(
      repository.verifyAdministratorPin('111111'),
      throwsA(
        predicate(
          (error) =>
              error is StateError &&
              error.message.toString().contains('Too many incorrect PIN'),
        ),
      ),
    );
  });

  test('requires administrator PIN to change device setup', () async {
    await saveProfile();
    final profile = (await repository.loadProfile())!;

    await expectLater(
      repository.saveProfile(plant: profile.plant, employee: profile.employee),
      throwsA(
        predicate(
          (error) =>
              error is StateError &&
              error.message.toString().contains('Administrator PIN'),
        ),
      ),
    );
    await repository.verifyAdministratorPin('111111');
  });

  test(
    'stores employee and attendance JSON in an encrypted envelope',
    () async {
      await saveProfile();

      final contents = await File(
        path.join(directory.path, 'attendance.json'),
      ).readAsString();

      expect(contents, contains('"version":1'));
      expect(contents, contains('"ciphertext"'));
      expect(contents, isNot(contains('EMP-1')));
      expect(contents, isNot(contains('123456')));
    },
  );

  test('authenticates PIN and records check-in and check-out', () async {
    await saveProfile();

    await repository.recordEvent(
      _event(AttendanceEventType.checkIn),
      pin: '123456',
    );
    await expectLater(
      repository.recordEvent(
        _event(AttendanceEventType.checkOut),
        pin: '654321',
      ),
      throwsA(isA<StateError>()),
    );
    await repository.recordEvent(
      _event(AttendanceEventType.checkOut),
      pin: '123456',
    );

    final events = await repository.eventsForDate('EMP-1', '2026-11-05');
    expect(events, hasLength(2));
    expect(events.map((event) => event.type), [
      AttendanceEventType.checkIn,
      AttendanceEventType.checkOut,
    ]);
    expect(
      events.every(
        (event) =>
            event.verificationMethod ==
                AttendanceVerificationMethod.employeePin &&
            event.verificationStatus ==
                AttendanceVerificationStatus.pinConfirmed,
      ),
      isTrue,
    );
  });

  test(
    'locks PIN authentication after five failures and later recovers',
    () async {
      await saveProfile();

      for (var attempt = 0; attempt < 5; attempt++) {
        await expectLater(
          repository.recordEvent(
            _event(AttendanceEventType.checkIn, id: 'attempt-$attempt'),
            pin: '654321',
          ),
          throwsA(isA<StateError>()),
        );
      }
      await expectLater(
        repository.recordEvent(
          _event(AttendanceEventType.checkIn, id: 'blocked'),
          pin: '123456',
        ),
        throwsA(
          predicate(
            (error) =>
                error is StateError &&
                error.message.toString().contains('Too many incorrect PIN'),
          ),
        ),
      );

      now = now.add(const Duration(minutes: 16));
      await repository.recordEvent(
        _event(AttendanceEventType.checkIn, id: 'after-lockout'),
        pin: '123456',
      );
    },
  );

  test('requires an open check-in before check-out', () async {
    await saveProfile();

    await expectLater(
      repository.recordEvent(
        _event(AttendanceEventType.checkOut),
        pin: '123456',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('prevents duplicate events even when actions race', () async {
    await saveProfile();

    final List<bool> results = await Future.wait<bool>([
      tryRecord(_event(AttendanceEventType.checkIn, id: 'first')),
      tryRecord(_event(AttendanceEventType.checkIn, id: 'second')),
    ]);

    expect(results.where((recorded) => recorded), hasLength(1));
    expect(await repository.eventsForDate('EMP-1', '2026-11-05'), hasLength(1));
  });

  test('rejects events for a different employee profile', () async {
    await saveProfile();

    await expectLater(
      repository.recordEvent(
        _event(AttendanceEventType.checkIn, employeeId: 'EMP-2'),
        pin: '123456',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'polling creates local shift sessions and marks missed check-ins absent',
    () async {
      now = DateTime.utc(2026, 11, 5, 2, 31);
      await repository.saveProfile(
        plant: const PlantConfiguration(
          name: 'Treatment plant',
          latitude: 13,
          longitude: 80,
        ),
        employee: const EmployeeProfile(
          employeeId: 'EMP-1',
          name: 'Employee One',
          shift: Shift(
            name: 'Morning',
            startHour: 6,
            startMinute: 0,
            endHour: 14,
            endMinute: 0,
            gracePeriodMinutes: 5,
            checkInWindowMinutes: 120,
          ),
          shiftDays: {1, 2, 3, 4, 5, 6, 7},
        ),
        pinCredential: await PinCredential.create('123456'),
        administratorCredential: await PinCredential.create('111111'),
      );
      final profile = (await repository.loadProfile())!;
      await repository.verifyAdministratorPin('111111');

      final sessions = await repository.pollAttendance(profile, now);
      final today = sessions.firstWhere(
        (session) => session.shiftDate == '2026-11-05',
      );

      expect(today.status, AttendanceSessionStatus.absent);
      expect(today.shiftName, 'Morning');
      expect(
        sessions.any((session) => session.shiftDate == '2026-11-04'),
        isFalse,
      );
      expect(
        await repository.sessionsForRange('EMP-1', '2026-11-05', '2026-11-05'),
        hasLength(1),
      );
    },
  );

  test('keeps an overnight shift session on its starting date', () async {
    now = DateTime.utc(2026, 11, 5, 16, 45);
    await repository.saveProfile(
      plant: const PlantConfiguration(
        name: 'Treatment plant',
        latitude: 13,
        longitude: 80,
      ),
      employee: const EmployeeProfile(
        employeeId: 'EMP-1',
        name: 'Employee One',
        shift: Shift(
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
      pinCredential: await PinCredential.create('123456'),
      administratorCredential: await PinCredential.create('111111'),
    );
    final profile = (await repository.loadProfile())!;

    final sessions = await repository.pollAttendance(profile, now);
    final night = sessions.firstWhere(
      (session) => session.shiftDate == '2026-11-05',
    );

    expect(night.startUtc, DateTime.utc(2026, 11, 5, 16, 30));
    expect(night.endUtc, DateTime.utc(2026, 11, 6, 0, 30));
    expect(night.status, AttendanceSessionStatus.scheduled);
  });

  test('refreshes session times when the assigned shift changes', () async {
    await saveProfile();
    await repository.saveProfile(
      plant: const PlantConfiguration(
        name: 'Treatment plant',
        latitude: 13,
        longitude: 80,
      ),
      employee: const EmployeeProfile(
        employeeId: 'EMP-1',
        name: 'Employee One',
        shift: Shift(
          name: 'Morning',
          startHour: 10,
          startMinute: 0,
          endHour: 18,
          endMinute: 0,
          gracePeriodMinutes: 5,
        ),
        shiftDays: {1, 2, 3, 4, 5},
      ),
      pinCredential: await PinCredential.create('123456'),
      administratorPin: '111111',
    );
    final profile = (await repository.loadProfile())!;
    await repository.verifyAdministratorPin('111111');

    final sessions = await repository.pollAttendance(profile, now);
    final today = sessions.firstWhere(
      (session) => session.shiftDate == '2026-11-05',
    );

    expect(today.startUtc, DateTime.utc(2026, 11, 5, 4, 30));
    expect(today.endUtc, DateTime.utc(2026, 11, 5, 12, 30));
  });

  test(
    'marks a checked-in shift incomplete after its checkout window',
    () async {
      await saveProfile();
      await repository.recordEvent(
        _event(AttendanceEventType.checkIn),
        pin: '123456',
      );

      now = DateTime.utc(2026, 11, 5, 17, 31);
      final profile = (await repository.loadProfile())!;
      final sessions = await repository.pollAttendance(profile, now);
      final session = sessions.firstWhere(
        (item) => item.shiftDate == '2026-11-05',
      );

      expect(session.status, AttendanceSessionStatus.incomplete);
    },
  );

  test(
    'encrypted backups consolidate employees without exporting PINs',
    () async {
      await saveProfile();
      final sourceDirectory = await Directory.systemTemp.createTemp(
        'ges-attendance-source-',
      );
      try {
        final source = AttendanceRepository(
          directory: sourceDirectory,
          encryptionKey: List<int>.generate(32, (index) => index),
          clock: () => now,
        );
        await source.saveProfile(
          plant: const PlantConfiguration(
            name: 'Treatment plant',
            latitude: 13,
            longitude: 80,
          ),
          employee: const EmployeeProfile(
            employeeId: 'EMP-2',
            name: 'Employee Two',
            shift: Shift(
              name: 'Morning',
              startHour: 9,
              startMinute: 0,
              gracePeriodMinutes: 5,
            ),
            shiftDays: {1, 2, 3, 4, 5},
          ),
          pinCredential: await PinCredential.create('222222'),
          administratorCredential: await PinCredential.create('333333'),
        );
        final sourceProfile = (await source.loadProfile())!;
        await source.pollAttendance(sourceProfile, now);
        await source.recordEvent(
          _event(AttendanceEventType.checkIn, employeeId: 'EMP-2'),
          pin: '222222',
        );
        final backup = await source.exportAttendanceBackup(
          administratorPin: '333333',
          passphrase: 'office-backup-passphrase',
          deviceId: 'source-device',
        );

        expect(utf8.decode(backup), isNot(contains('EMP-2')));
        await expectLater(
          repository.importAttendanceBackup(
            bytes: backup,
            administratorPin: '111111',
            passphrase: 'wrong-backup-passphrase',
          ),
          throwsA(anything),
        );
        expect(await repository.allEvents(administratorPin: '111111'), isEmpty);

        final result = await repository.importAttendanceBackup(
          bytes: backup,
          administratorPin: '111111',
          passphrase: 'office-backup-passphrase',
        );
        expect(result.addedEvents, 1);
        expect(result.duplicateEvents, 0);
        expect(
          (await repository.allEvents(
            administratorPin: '111111',
          )).single.employeeId,
          'EMP-2',
        );

        final duplicateResult = await repository.importAttendanceBackup(
          bytes: backup,
          administratorPin: '111111',
          passphrase: 'office-backup-passphrase',
        );
        expect(duplicateResult.addedEvents, 0);
        expect(duplicateResult.duplicateEvents, 1);

        final conflictingDirectory = await Directory.systemTemp.createTemp(
          'ges-attendance-conflict-',
        );
        try {
          final conflictingSource = AttendanceRepository(
            directory: conflictingDirectory,
            encryptionKey: List<int>.generate(32, (index) => index),
            clock: () => now,
          );
          await conflictingSource.saveProfile(
            plant: const PlantConfiguration(
              name: 'Treatment plant',
              latitude: 13,
              longitude: 80,
            ),
            employee: const EmployeeProfile(
              employeeId: 'EMP-2',
              name: 'Employee Two',
              shift: Shift(
                name: 'Morning',
                startHour: 9,
                startMinute: 0,
                gracePeriodMinutes: 5,
              ),
              shiftDays: {1, 2, 3, 4, 5},
            ),
            pinCredential: await PinCredential.create('222222'),
            administratorCredential: await PinCredential.create('333333'),
          );
          final conflictingProfile = (await conflictingSource.loadProfile())!;
          await conflictingSource.pollAttendance(conflictingProfile, now);
          await conflictingSource.recordEvent(
            _event(
              AttendanceEventType.checkIn,
              id: 'different-check-in',
              employeeId: 'EMP-2',
            ),
            pin: '222222',
          );
          final conflictBackup = await conflictingSource.exportAttendanceBackup(
            administratorPin: '333333',
            passphrase: 'office-backup-passphrase',
            deviceId: 'conflicting-device',
          );

          await expectLater(
            repository.importAttendanceBackup(
              bytes: conflictBackup,
              administratorPin: '111111',
              passphrase: 'office-backup-passphrase',
            ),
            throwsA(isA<StateError>()),
          );
          expect(
            (await repository.allEvents(
              administratorPin: '111111',
            )).single.eventId,
            'checkIn',
          );
        } finally {
          await conflictingDirectory.delete(recursive: true);
        }
      } finally {
        await sourceDirectory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'imports legacy SQL records only when JSON storage is not present',
    () async {
      await repository.importLegacyData(
        profile: null,
        events: [_event(AttendanceEventType.checkIn).toMap()],
      );

      final imported = await repository.eventsForDate('EMP-1', '2026-11-05');
      expect(imported, hasLength(1));

      await repository.importLegacyData(profile: null, events: []);
      expect(
        await repository.eventsForDate('EMP-1', '2026-11-05'),
        hasLength(1),
      );
    },
  );
}

AttendanceEvent _event(
  AttendanceEventType type, {
  String? id,
  String employeeId = 'EMP-1',
}) => AttendanceEvent(
  eventId: id ?? type.name,
  deviceId: 'device-1',
  employeeId: employeeId,
  type: type,
  attendanceDate: '2026-11-05',
  timestampUtc: DateTime.utc(2026, 11, 5, type.index == 0 ? 3 : 12, 30),
  locationCapturedAtUtc: DateTime.utc(
    2026,
    11,
    5,
    type.index == 0 ? 3 : 12,
    30,
  ),
  timezoneOffsetMinutes: 330,
  shiftName: 'Morning',
  shiftStart: '09:00',
  gracePeriodMinutes: 5,
  latitude: 13,
  longitude: 80,
  accuracyMeters: 2,
  distanceMeters: 0,
  timezoneId: 'Asia/Kolkata',
  isLate: false,
  totalDelayMinutes: 0,
  delayAfterGraceMinutes: 0,
  verificationMethod: AttendanceVerificationMethod.employeePin,
  verificationStatus: AttendanceVerificationStatus.pinConfirmed,
);
