import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/attendance_event.dart';
import '../domain/attendance_session.dart';
import '../domain/attendance_rules.dart';
import '../domain/geofence.dart';
import '../domain/pin_credentials.dart';

abstract interface class AttendanceStore {
  Future<List<AttendanceEvent>> eventsForDate(
    String employeeId,
    String attendanceDate,
  );

  Future<List<AttendanceSession>> pollAttendance(
    LocalProfile profile,
    DateTime nowUtc,
  );

  Future<List<AttendanceSession>> sessionsForRange(
    String employeeId,
    String startDate,
    String endDate,
  );

  Future<void> recordEvent(AttendanceEvent event, {required String pin});
}

class AttendanceRepository implements AttendanceStore {
  AttendanceRepository({
    required Directory directory,
    required List<int> encryptionKey,
    DateTime Function()? clock,
  }) : _file = File(
         '${directory.path}${Platform.pathSeparator}attendance.json',
       ),
       _key = SecretKey(encryptionKey),
       _clock = clock ?? DateTime.now {
    if (encryptionKey.length != 32) {
      throw ArgumentError('Attendance JSON encryption key must be 32 bytes.');
    }
  }

  static const _fileVersion = 1;
  static const _backupIterations = 600000;
  static final _algorithm = AesGcm.with256bits();
  final File _file;
  final SecretKey _key;
  final DateTime Function() _clock;
  Future<void> _operationTail = Future<void>.value();

  Future<LocalProfile?> loadProfile() => _locked(() async {
    final row = (await _readData())['profile'] as Map<String, Object?>?;
    if (row == null || row['pin_salt'] == null || row['pin_hash'] == null) {
      return null;
    }
    final shiftParts = (row['shift_start']! as String).split(':');
    final days = (row['shift_days']! as String)
        .split(',')
        .where((day) => day.isNotEmpty)
        .map(int.parse)
        .toSet();
    return LocalProfile(
      plant: PlantConfiguration(
        name: row['plant_name']! as String,
        latitude: (row['plant_latitude']! as num).toDouble(),
        longitude: (row['plant_longitude']! as num).toDouble(),
        radiusMeters: (row['radius_meters']! as num).toDouble(),
        maxAccuracyMeters: (row['max_accuracy_meters']! as num).toDouble(),
        timezoneId: row['timezone_id']! as String,
      ),
      employee: EmployeeProfile(
        employeeId: row['employee_id']! as String,
        name: row['employee_name']! as String,
        shift: Shift(
          name: row['shift_name'] as String? ?? 'Custom',
          startHour: int.parse(shiftParts[0]),
          startMinute: int.parse(shiftParts[1]),
          endHour: row['shift_end_hour'] as int? ?? 17,
          endMinute: row['shift_end_minute'] as int? ?? 0,
          gracePeriodMinutes: row['grace_period_minutes']! as int,
          checkInWindowMinutes: row['check_in_window_minutes'] as int? ?? 120,
        ),
        shiftDays: days,
      ),
    );
  });

  Future<void> saveProfile({
    required PlantConfiguration plant,
    required EmployeeProfile employee,
    PinCredential? pinCredential,
    PinCredential? administratorCredential,
    String? administratorPin,
  }) => _locked(() async {
    if (plant.name.trim().isEmpty ||
        plant.name.trim().length > 160 ||
        employee.employeeId.trim().length > 64 ||
        !RegExp(
          r'^[A-Za-z0-9._-]{1,64}$',
        ).hasMatch(employee.employeeId.trim()) ||
        employee.employeeId.trim().isEmpty ||
        employee.name.trim().isEmpty ||
        employee.name.trim().length > 160 ||
        employee.shiftDays.isEmpty ||
        employee.shiftDays.any((day) => day < 1 || day > 7)) {
      throw ArgumentError(
        'Plant, employee, shift, and working days are required.',
      );
    }

    tz.getLocation(plant.timezoneId);
    PlantFence(
      latitude: plant.latitude,
      longitude: plant.longitude,
      radiusMeters: plant.radiusMeters,
      maxAccuracyMeters: plant.maxAccuracyMeters,
    ).validate();
    employee.shift.validate();
    final data = await _readData();
    final oldProfile = data['profile'] as Map<String, Object?>?;
    if (oldProfile != null) {
      if (administratorPin == null) {
        throw StateError('Administrator PIN is required to edit device setup.');
      }
      await _verifyAdministratorPin(data, oldProfile, administratorPin);
    }
    if (oldProfile == null &&
        (pinCredential == null || administratorCredential == null)) {
      throw StateError(
        'Initial setup requires employee and administrator PINs.',
      );
    }
    if (pinCredential == null &&
        (oldProfile == null ||
            oldProfile['pin_salt'] == null ||
            oldProfile['pin_hash'] == null)) {
      throw StateError('Employee PIN is not configured on this device.');
    }
    final shiftStart =
        '${employee.shift.startHour.toString().padLeft(2, '0')}:'
        '${employee.shift.startMinute.toString().padLeft(2, '0')}';
    data['profile'] = <String, Object?>{
      ...?oldProfile,
      'plant_name': plant.name.trim(),
      'plant_latitude': plant.latitude,
      'plant_longitude': plant.longitude,
      'radius_meters': plant.radiusMeters,
      'max_accuracy_meters': plant.maxAccuracyMeters,
      'timezone_id': plant.timezoneId,
      'employee_id': employee.employeeId.trim(),
      'employee_name': employee.name.trim(),
      if (pinCredential != null) ...{
        'pin_salt': pinCredential.salt,
        'pin_hash': pinCredential.hash,
        'pin_failed_attempts': 0,
        'pin_locked_until_utc': null,
      },
      if (administratorCredential != null) ...{
        'admin_pin_salt': administratorCredential.salt,
        'admin_pin_hash': administratorCredential.hash,
        'admin_pin_failed_attempts': 0,
        'admin_pin_locked_until_utc': null,
      },
      'shift_start': shiftStart,
      'shift_name': employee.shift.name.trim(),
      'shift_end_hour': employee.shift.endHour,
      'shift_end_minute': employee.shift.endMinute,
      'check_in_window_minutes': employee.shift.checkInWindowMinutes,
      'grace_period_minutes': employee.shift.gracePeriodMinutes,
      'shift_days': (employee.shiftDays.toList()..sort()).join(','),
      'configured_at_utc': _clock().toUtc().toIso8601String(),
    };
    await _writeData(data);
  });

  Future<bool> hasAdministratorPin() => _locked(() async {
    final profile = (await _readData())['profile'] as Map<String, Object?>?;
    if (profile == null) return false;
    final hasSalt = profile['admin_pin_salt'] != null;
    final hasHash = profile['admin_pin_hash'] != null;
    if (hasSalt != hasHash) {
      throw StateError('Administrator PIN data is incomplete.');
    }
    return hasSalt;
  });

  Future<void> setAdministratorPin(
    PinCredential credential, {
    bool onlyIfMissing = false,
    String? currentPin,
  }) => _locked(() async {
    final data = await _readData();
    final profile = data['profile'] as Map<String, Object?>?;
    if (profile == null) {
      throw StateError(
        'Set up the employee device before setting an admin PIN.',
      );
    }
    if (onlyIfMissing) {
      if (profile['admin_pin_hash'] != null ||
          profile['admin_pin_salt'] != null) {
        throw StateError('An administrator PIN is already configured.');
      }
    } else {
      if (currentPin == null) {
        throw StateError('Current administrator PIN is required.');
      }
      await _verifyAdministratorPin(data, profile, currentPin);
    }
    profile['admin_pin_salt'] = credential.salt;
    profile['admin_pin_hash'] = credential.hash;
    profile['admin_pin_failed_attempts'] = 0;
    profile['admin_pin_locked_until_utc'] = null;
    await _writeData(data);
  });

  Future<void> verifyAdministratorPin(String pin) => _locked(() async {
    final data = await _readData();
    final profile = data['profile'] as Map<String, Object?>?;
    if (profile == null) {
      throw StateError('Administrator PIN is not configured.');
    }
    await _verifyAdministratorPin(data, profile, pin);
    await _writeData(data);
  });

  Future<List<int>> exportAttendanceBackup({
    required String administratorPin,
    required String passphrase,
    required String deviceId,
  }) => _locked(() async {
    _validateBackupPassphrase(passphrase);
    final data = await _readData();
    final profile = data['profile'] as Map<String, Object?>?;
    if (profile == null) {
      throw StateError('Set up this device before exporting attendance.');
    }
    await _verifyAdministratorPin(data, profile, administratorPin);
    await _writeData(data);
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _deriveBackupKey(passphrase, salt);
    final payload = <String, Object?>{
      'format': 'ges-attendance-backup',
      'version': 1,
      'created_at_utc': _clock().toUtc().toIso8601String(),
      'source_device_id': deviceId,
      'plant_fingerprint': _plantFingerprint(profile),
      'events': data['events'],
      'sessions': data['sessions'],
    };
    final box = await _algorithm.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    return utf8.encode(
      jsonEncode({
        'format': 'ges-attendance-encrypted',
        'version': 1,
        'kdf': 'pbkdf2-hmac-sha256',
        'iterations': _backupIterations,
        'salt': base64UrlEncode(salt),
        'nonce': base64UrlEncode(box.nonce),
        'ciphertext': base64UrlEncode(box.cipherText),
        'mac': base64UrlEncode(box.mac.bytes),
      }),
    );
  });

  Future<AttendanceBackupImportResult> importAttendanceBackup({
    required List<int> bytes,
    required String administratorPin,
    required String passphrase,
  }) => _locked(() async {
    _validateBackupPassphrase(passphrase);
    final data = await _readData();
    final profile = data['profile'] as Map<String, Object?>?;
    if (profile == null) {
      throw StateError('Set up this device before importing attendance.');
    }
    await _verifyAdministratorPin(data, profile, administratorPin);
    final envelope = jsonDecode(utf8.decode(bytes));
    if (envelope is! Map<String, dynamic> ||
        envelope['format'] != 'ges-attendance-encrypted' ||
        envelope['version'] != 1 ||
        envelope['kdf'] != 'pbkdf2-hmac-sha256' ||
        envelope['iterations'] != _backupIterations) {
      throw const FormatException('Unsupported attendance backup format.');
    }
    final salt = base64Url.decode(envelope['salt'] as String);
    final nonce = base64Url.decode(envelope['nonce'] as String);
    final ciphertext = base64Url.decode(envelope['ciphertext'] as String);
    final mac = base64Url.decode(envelope['mac'] as String);
    if (salt.length != 16 || nonce.length != 12 || mac.length != 16) {
      throw const FormatException('Attendance backup is malformed.');
    }
    final key = await _deriveBackupKey(passphrase, salt);
    final cleartext = await _algorithm.decrypt(
      SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(key),
    );
    final payload = jsonDecode(utf8.decode(cleartext));
    if (payload is! Map<String, dynamic> ||
        payload['format'] != 'ges-attendance-backup' ||
        payload['version'] != 1 ||
        payload['plant_fingerprint'] != _plantFingerprint(profile) ||
        payload['events'] is! List ||
        payload['sessions'] is! List) {
      throw const FormatException(
        'Backup is invalid or belongs to a different office.',
      );
    }

    final incomingEvents = _events(payload['events']);
    final incomingSessions = _sessions(payload['sessions']);
    final events = _events(data['events']);
    final sessions = _sessions(data['sessions']);
    final eventIds = {for (final event in events) event.eventId: event};
    final dailyEvents = {
      for (final event in events)
        '${event.employeeId}:${event.attendanceDate}:${event.type.name}': event,
    };
    final incomingIds = <String>{};
    final incomingDaily = <String, AttendanceEvent>{};
    var addedEvents = 0;
    var duplicateEvents = 0;
    for (final event in incomingEvents) {
      final dailyKey =
          '${event.employeeId}:${event.attendanceDate}:${event.type.name}';
      if (!incomingIds.add(event.eventId)) {
        throw const FormatException('Backup contains duplicate event IDs.');
      }
      final duplicateId = eventIds[event.eventId];
      final duplicateDay = dailyEvents[dailyKey];
      final duplicateWithinImport = incomingDaily[dailyKey];
      if (duplicateId != null) {
        if (!_sameJson(duplicateId.toMap(), event.toMap())) {
          throw StateError('Backup conflicts with an existing event ID.');
        }
        duplicateEvents++;
        continue;
      }
      if (duplicateDay != null || duplicateWithinImport != null) {
        throw StateError(
          'Backup conflicts for ${event.employeeId} on ${event.attendanceDate} '
          '(${event.type.name}). No records were imported.',
        );
      }
      incomingDaily[dailyKey] = event;
      eventIds[event.eventId] = event;
      dailyEvents[dailyKey] = event;
      events.add(event);
      addedEvents++;
    }

    final sessionIds = {
      for (final session in sessions) session.sessionId: session,
    };
    final incomingSessionIds = <String>{};
    var addedSessions = 0;
    var duplicateSessions = 0;
    for (final session in incomingSessions) {
      if (!incomingSessionIds.add(session.sessionId)) {
        throw const FormatException('Backup contains duplicate session IDs.');
      }
      final duplicate = sessionIds[session.sessionId];
      if (duplicate != null) {
        if (!_sameJson(duplicate.toMap(), session.toMap())) {
          throw StateError(
            'Backup conflicts with existing session ${session.sessionId}. '
            'No records were imported.',
          );
        }
        duplicateSessions++;
        continue;
      }
      sessionIds[session.sessionId] = session;
      sessions.add(session);
      addedSessions++;
    }

    data['events'] = events.map((event) => event.toMap()).toList();
    data['sessions'] = sessions.map((session) => session.toMap()).toList();
    await _writeData(data);
    return AttendanceBackupImportResult(
      addedEvents: addedEvents,
      duplicateEvents: duplicateEvents,
      addedSessions: addedSessions,
      duplicateSessions: duplicateSessions,
    );
  });

  @override
  Future<List<AttendanceEvent>> eventsForDate(
    String employeeId,
    String attendanceDate,
  ) => _locked(() async {
    final events = _events((await _readData())['events']);
    return events
        .where(
          (event) =>
              event.employeeId == employeeId &&
              event.attendanceDate == attendanceDate,
        )
        .toList()
      ..sort(
        (first, second) => first.timestampUtc.compareTo(second.timestampUtc),
      );
  });

  Future<List<AttendanceEvent>> recentEvents(String employeeId) =>
      _locked(() async {
        final events =
            _events(
              (await _readData())['events'],
            ).where((event) => event.employeeId == employeeId).toList()..sort(
              (first, second) =>
                  second.timestampUtc.compareTo(first.timestampUtc),
            );
        return events.take(100).toList();
      });

  Future<List<AttendanceEvent>> allEvents({required String administratorPin}) =>
      _locked(() async {
        final data = await _readData();
        final profile = data['profile'] as Map<String, Object?>?;
        if (profile == null) {
          throw StateError('Administrator PIN is not configured.');
        }
        await _verifyAdministratorPin(data, profile, administratorPin);
        await _writeData(data);
        final events = _events(data['events'])
          ..sort(
            (first, second) =>
                second.timestampUtc.compareTo(first.timestampUtc),
          );
        return events;
      });

  Future<List<AttendanceSession>> allSessions({
    required String administratorPin,
  }) => _locked(() async {
    final data = await _readData();
    final profile = data['profile'] as Map<String, Object?>?;
    if (profile == null) {
      throw StateError('Administrator PIN is not configured.');
    }
    await _verifyAdministratorPin(data, profile, administratorPin);
    await _writeData(data);
    final sessions = _sessions(data['sessions'])
      ..sort((first, second) => second.startUtc.compareTo(first.startUtc));
    return sessions;
  });

  @override
  Future<List<AttendanceSession>> pollAttendance(
    LocalProfile profile,
    DateTime nowUtc,
  ) => _locked(() async {
    final data = await _readData();
    final sessions = _sessions(data['sessions']);
    final localNow = tz.TZDateTime.from(
      nowUtc.toUtc(),
      tz.getLocation(profile.plant.timezoneId),
    );
    final allEvents = _events(data['events']);
    final storedProfile = data['profile'] as Map<String, Object?>?;
    final configuredAtText = storedProfile?['configured_at_utc'] as String?;
    final configuredDate = configuredAtText == null
        ? null
        : tz.TZDateTime.from(
            DateTime.parse(configuredAtText).toUtc(),
            tz.getLocation(profile.plant.timezoneId),
          );
    var changed = false;
    for (var offset = -120; offset <= 1; offset++) {
      final localDate = localNow.add(Duration(days: offset));
      if (configuredDate != null &&
          shiftDateKey(localDate).compareTo(shiftDateKey(configuredDate)) < 0) {
        continue;
      }
      if (!profile.employee.shiftDays.contains(localDate.weekday)) continue;
      final occurrence = shiftOccurrence(
        shift: profile.employee.shift,
        localDate: localDate,
        timezoneId: profile.plant.timezoneId,
      );
      final sessionId = shiftSessionId(
        employeeId: profile.employee.employeeId,
        shiftDate: occurrence.shiftDate,
        shiftName: profile.employee.shift.name,
      );
      final sessionIndex = sessions.indexWhere(
        (session) => session.sessionId == sessionId,
      );
      final dailyEvents = allEvents
          .where(
            (event) =>
                event.employeeId == profile.employee.employeeId &&
                event.attendanceDate == occurrence.shiftDate,
          )
          .toList();
      final hasCheckIn = dailyEvents.any(
        (event) => event.type == AttendanceEventType.checkIn,
      );
      final hasCheckOut = dailyEvents.any(
        (event) => event.type == AttendanceEventType.checkOut,
      );
      final status = hasCheckOut
          ? AttendanceSessionStatus.completed
          : hasCheckIn
          ? localNow.isAfter(occurrence.end.add(const Duration(hours: 6)))
                ? AttendanceSessionStatus.incomplete
                : AttendanceSessionStatus.present
          : localNow.isAfter(occurrence.checkInDeadline)
          ? AttendanceSessionStatus.absent
          : AttendanceSessionStatus.scheduled;
      final session = AttendanceSession(
        sessionId: sessionId,
        employeeId: profile.employee.employeeId,
        shiftName: profile.employee.shift.name,
        shiftDate: occurrence.shiftDate,
        startUtc: occurrence.start.toUtc(),
        endUtc: occurrence.end.toUtc(),
        checkInDeadlineUtc: occurrence.checkInDeadline.toUtc(),
        status: status,
        updatedAtUtc: nowUtc.toUtc(),
      );
      if (sessionIndex < 0) {
        sessions.add(session);
        changed = true;
      } else if (sessions[sessionIndex].status != status ||
          sessions[sessionIndex].startUtc != session.startUtc ||
          sessions[sessionIndex].endUtc != session.endUtc ||
          sessions[sessionIndex].checkInDeadlineUtc !=
              session.checkInDeadlineUtc) {
        sessions[sessionIndex] = session;
        changed = true;
      }
    }

    final cutoff = localNow.subtract(const Duration(days: 120));
    final oldSessionCount = sessions.length;
    sessions.removeWhere(
      (session) => session.shiftDate.compareTo(shiftDateKey(cutoff)) < 0,
    );
    if (sessions.length != oldSessionCount) changed = true;
    if (changed) {
      data['sessions'] = sessions.map((session) => session.toMap()).toList();
      await _writeData(data);
    }
    return sessions
        .where(
          (session) =>
              session.employeeId == profile.employee.employeeId &&
              session.shiftDate.compareTo(shiftDateKey(cutoff)) >= 0,
        )
        .toList()
      ..sort((first, second) => second.startUtc.compareTo(first.startUtc));
  });

  @override
  Future<List<AttendanceSession>> sessionsForRange(
    String employeeId,
    String startDate,
    String endDate,
  ) => _locked(() async {
    final sessions =
        _sessions((await _readData())['sessions'])
            .where(
              (session) =>
                  session.employeeId == employeeId &&
                  session.shiftDate.compareTo(startDate) >= 0 &&
                  session.shiftDate.compareTo(endDate) <= 0,
            )
            .toList()
          ..sort(
            (first, second) => second.shiftDate.compareTo(first.shiftDate),
          );
    return sessions;
  });

  @override
  Future<void> recordEvent(
    AttendanceEvent event, {
    required String pin,
  }) => _locked(() async {
    final data = await _readData();
    final profile = data['profile'] as Map<String, Object?>?;
    if (profile == null ||
        profile['pin_salt'] == null ||
        profile['pin_hash'] == null) {
      throw StateError('Employee PIN is not configured on this device.');
    }
    if (profile['employee_id'] != event.employeeId) {
      throw StateError(
        "Attendance employee does not match this phone's configured employee.",
      );
    }
    if ((profile['shift_name'] as String? ?? 'Custom') != event.shiftName) {
      throw StateError('Attendance shift does not match the assigned shift.');
    }
    if (event.verificationMethod != AttendanceVerificationMethod.employeePin ||
        event.verificationStatus != AttendanceVerificationStatus.pinConfirmed) {
      throw StateError('Attendance must be recorded using employee PIN.');
    }

    final fence = PlantFence(
      latitude: (profile['plant_latitude']! as num).toDouble(),
      longitude: (profile['plant_longitude']! as num).toDouble(),
      radiusMeters: (profile['radius_meters']! as num).toDouble(),
      maxAccuracyMeters: (profile['max_accuracy_meters']! as num).toDouble(),
    );
    final verifiedLocation = verifyLocation(
      fence: fence,
      fix: LocationFix(
        latitude: event.latitude,
        longitude: event.longitude,
        accuracyMeters: event.accuracyMeters,
        capturedAt: event.locationCapturedAtUtc,
      ),
      now: event.timestampUtc,
    );
    if (!event.distanceMeters.isFinite ||
        event.distanceMeters < 0 ||
        !verifiedLocation.accepted ||
        (verifiedLocation.distanceMeters! - event.distanceMeters).abs() > 1) {
      throw StateError(
        verifiedLocation.reason ?? 'Stored GPS distance is inconsistent.',
      );
    }

    final now = _clock().toUtc();
    final lockoutText = profile['pin_locked_until_utc'] as String?;
    final lockout = lockoutText == null ? null : DateTime.parse(lockoutText);
    if (lockout != null && lockout.isAfter(now)) {
      throw StateError(_lockoutMessage(lockout, now));
    }
    final validPin = await PinCredential.verify(
      pin: pin,
      salt: profile['pin_salt']! as String,
      hash: profile['pin_hash']! as String,
    );
    if (!validPin) {
      final failures = (profile['pin_failed_attempts']! as int) + 1;
      profile['pin_failed_attempts'] = failures;
      profile['pin_locked_until_utc'] = failures >= 5
          ? now.add(const Duration(minutes: 15)).toIso8601String()
          : null;
      await _writeData(data);
      throw StateError('Incorrect employee PIN.');
    }

    profile['pin_failed_attempts'] = 0;
    profile['pin_locked_until_utc'] = null;
    final events = _events(data['events']);
    final daily = events
        .where(
          (existing) =>
              existing.employeeId == event.employeeId &&
              existing.attendanceDate == event.attendanceDate,
        )
        .toList();
    final hasCheckIn = daily.any(
      (existing) => existing.type == AttendanceEventType.checkIn,
    );
    final hasCheckOut = daily.any(
      (existing) => existing.type == AttendanceEventType.checkOut,
    );
    if (event.type == AttendanceEventType.checkIn &&
        (hasCheckIn || hasCheckOut)) {
      throw StateError('Attendance was already recorded for this day.');
    }
    if (event.type == AttendanceEventType.checkOut &&
        (!hasCheckIn || hasCheckOut)) {
      throw StateError('A current open check-in is required before check-out.');
    }
    events.add(event);
    data['events'] = events.map((item) => item.toMap()).toList();
    final sessions = _sessions(data['sessions']);
    final sessionId = shiftSessionId(
      employeeId: event.employeeId,
      shiftDate: event.attendanceDate,
      shiftName: event.shiftName,
    );
    final sessionIndex = sessions.indexWhere(
      (session) => session.sessionId == sessionId,
    );
    if (sessionIndex < 0) {
      throw StateError('The scheduled attendance session is missing.');
    }
    final session = sessions[sessionIndex];
    if (event.type == AttendanceEventType.checkIn &&
        (session.status != AttendanceSessionStatus.scheduled ||
            event.timestampUtc.isBefore(session.startUtc) ||
            event.timestampUtc.isAfter(session.checkInDeadlineUtc))) {
      throw StateError('Check-in is outside the permitted shift window.');
    }
    if (event.type == AttendanceEventType.checkOut &&
        (session.status != AttendanceSessionStatus.present ||
            event.timestampUtc.isBefore(session.startUtc) ||
            event.timestampUtc.isAfter(
              session.endUtc.add(const Duration(hours: 6)),
            ))) {
      throw StateError('There is no open shift session to check out from.');
    }
    sessions[sessionIndex] = AttendanceSession(
      sessionId: session.sessionId,
      employeeId: session.employeeId,
      shiftName: session.shiftName,
      shiftDate: session.shiftDate,
      startUtc: session.startUtc,
      endUtc: session.endUtc,
      checkInDeadlineUtc: session.checkInDeadlineUtc,
      status: event.type == AttendanceEventType.checkIn
          ? AttendanceSessionStatus.present
          : AttendanceSessionStatus.completed,
      updatedAtUtc: _clock().toUtc(),
    );
    data['sessions'] = sessions.map((session) => session.toMap()).toList();
    await _writeData(data);
  });

  Future<void> importLegacyData({
    required Map<String, Object?>? profile,
    required List<Map<String, Object?>> events,
  }) => _locked(() async {
    if (await _file.exists()) return;
    if (profile == null && events.isEmpty) return;
    final normalizedProfile = profile == null
        ? null
        : <String, Object?>{
            ...profile,
            'shift_name': profile['shift_name'] as String? ?? 'Custom',
            'shift_end_hour': profile['shift_end_hour'] as int? ?? 17,
            'shift_end_minute': profile['shift_end_minute'] as int? ?? 0,
            'check_in_window_minutes':
                profile['check_in_window_minutes'] as int? ?? 120,
            'pin_failed_attempts': profile['pin_failed_attempts'] as int? ?? 0,
          };
    final shiftName = normalizedProfile?['shift_name'] as String? ?? 'Custom';
    final normalizedEvents = events.map((event) {
      final hasFaceModel =
          event['face_model_version'] is String ||
          event['liveness_model_version'] is String;
      final method =
          event['verification_method'] as String? ??
          (hasFaceModel ? 'faceBiometric' : 'employeePin');
      final status =
          event['verification_status'] as String? ??
          (method == 'faceBiometric' ? 'biometricVerified' : 'pinConfirmed');
      return <String, Object?>{
        ...event,
        'shift_name': event['shift_name'] as String? ?? shiftName,
        'verification_method': method == 'faceBiometric'
            ? 'faceBiometric'
            : 'employeePin',
        'verification_status': status == 'biometricVerified'
            ? 'biometricVerified'
            : 'pinConfirmed',
      };
    }).toList();
    await _writeData({
      'profile': normalizedProfile,
      'events': normalizedEvents,
      'sessions': <Object>[],
    });
  });

  static Future<List<int>> _deriveBackupKey(
    String passphrase,
    List<int> salt,
  ) => Isolate.run(() async {
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _backupIterations,
      bits: 256,
    );
    final key = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    return key.extractBytes();
  });

  Future<Map<String, Object?>> _readData() async {
    final backup = File('${_file.path}.bak');
    if (!await _file.exists() && await backup.exists()) {
      await backup.rename(_file.path);
    } else if (await _file.exists() && await backup.exists()) {
      await backup.delete();
    }

    if (!await _file.exists()) {
      return {'profile': null, 'events': <Object>[], 'sessions': <Object>[]};
    }
    final envelope = jsonDecode(await _file.readAsString());
    if (envelope is! Map<String, dynamic> ||
        envelope['version'] != _fileVersion) {
      throw const FormatException('Unsupported attendance JSON file format.');
    }
    final nonce = base64Url.decode(envelope['nonce'] as String);
    final ciphertext = base64Url.decode(envelope['ciphertext'] as String);
    final mac = base64Url.decode(envelope['mac'] as String);
    final cleartext = await _algorithm.decrypt(
      SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
      secretKey: _key,
    );
    final decoded = jsonDecode(utf8.decode(cleartext));
    if (decoded is! Map<String, dynamic> ||
        decoded['events'] is! List ||
        (decoded['sessions'] != null && decoded['sessions'] is! List)) {
      throw const FormatException('Attendance JSON data is invalid.');
    }
    final rawProfile = decoded['profile'];
    if (rawProfile != null && rawProfile is! Map<String, dynamic>) {
      throw const FormatException('Attendance employee profile is invalid.');
    }
    return {
      'profile': rawProfile == null
          ? null
          : Map<String, Object?>.from(rawProfile),
      'events': List<Object?>.from(decoded['events'] as List),
      'sessions': List<Object?>.from(decoded['sessions'] as List? ?? const []),
    };
  }

  Future<void> _writeData(Map<String, Object?> data) async {
    await _file.parent.create(recursive: true);
    final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final box = await _algorithm.encrypt(
      utf8.encode(jsonEncode(data)),
      secretKey: _key,
      nonce: nonce,
    );
    final envelope = jsonEncode({
      'version': _fileVersion,
      'nonce': base64UrlEncode(box.nonce),
      'ciphertext': base64UrlEncode(box.cipherText),
      'mac': base64UrlEncode(box.mac.bytes),
    });
    final temporary = File('${_file.path}.tmp');
    final backup = File('${_file.path}.bak');
    await temporary.writeAsString(envelope, flush: true);
    try {
      if (await backup.exists()) await backup.delete();
      if (await _file.exists()) await _file.rename(backup.path);
      await temporary.rename(_file.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (!await _file.exists() && await backup.exists()) {
        await backup.rename(_file.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  List<AttendanceEvent> _events(Object? value) {
    if (value is! List) {
      throw const FormatException('Attendance event list is invalid.');
    }
    return value.map((item) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Attendance event entry is invalid.');
      }
      final normalized = Map<String, Object?>.from(item);
      normalized.putIfAbsent('shift_name', () => 'Custom');
      return AttendanceEvent.fromMap(normalized);
    }).toList();
  }

  List<AttendanceSession> _sessions(Object? value) {
    if (value == null) return [];
    if (value is! List) {
      throw const FormatException('Attendance session list is invalid.');
    }
    return value.map((item) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Attendance session entry is invalid.');
      }
      return AttendanceSession.fromMap(Map<String, Object?>.from(item));
    }).toList();
  }

  Future<void> _verifyAdministratorPin(
    Map<String, Object?> data,
    Map<String, Object?> profile,
    String pin,
  ) async {
    final salt = profile['admin_pin_salt'] as String?;
    final hash = profile['admin_pin_hash'] as String?;
    if (salt == null || hash == null) {
      throw StateError('Administrator PIN is not configured.');
    }
    final now = _clock().toUtc();
    final lockedUntilText = profile['admin_pin_locked_until_utc'] as String?;
    final lockedUntil = lockedUntilText == null
        ? null
        : DateTime.parse(lockedUntilText);
    if (lockedUntil != null && lockedUntil.isAfter(now)) {
      throw StateError(_lockoutMessage(lockedUntil, now));
    }
    if (!await PinCredential.verify(pin: pin, salt: salt, hash: hash)) {
      final failures = (profile['admin_pin_failed_attempts'] as int? ?? 0) + 1;
      profile['admin_pin_failed_attempts'] = failures;
      profile['admin_pin_locked_until_utc'] = failures >= 5
          ? now.add(const Duration(minutes: 15)).toIso8601String()
          : null;
      await _writeData(data);
      throw StateError('Incorrect administrator PIN.');
    }
    profile['admin_pin_failed_attempts'] = 0;
    profile['admin_pin_locked_until_utc'] = null;
  }

  Future<T> _locked<T>(Future<T> Function() operation) async {
    final previous = _operationTail;
    final release = Completer<void>();
    _operationTail = release.future;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }

  static String _lockoutMessage(DateTime lockedUntil, DateTime now) {
    final remaining = lockedUntil.difference(now).inMinutes + 1;
    return 'Too many incorrect PIN attempts. Try again in $remaining minute(s).';
  }

  static String createEventId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static void _validateBackupPassphrase(String passphrase) {
    if (passphrase.trim().length < 12) {
      throw ArgumentError(
        'Backup passphrase must contain at least 12 non-space characters.',
      );
    }
  }

  static String _plantFingerprint(Map<String, Object?> profile) =>
      '${(profile['plant_latitude']! as num).toDouble().toStringAsFixed(7)}|'
      '${(profile['plant_longitude']! as num).toDouble().toStringAsFixed(7)}|'
      '${profile['timezone_id']! as String}';

  static bool _sameJson(
    Map<String, Object?> first,
    Map<String, Object?> second,
  ) => jsonEncode(first) == jsonEncode(second);
}

class AttendanceBackupImportResult {
  const AttendanceBackupImportResult({
    required this.addedEvents,
    required this.duplicateEvents,
    required this.addedSessions,
    required this.duplicateSessions,
  });

  final int addedEvents;
  final int duplicateEvents;
  final int addedSessions;
  final int duplicateSessions;
}

class LocalProfile {
  const LocalProfile({required this.plant, required this.employee});

  final PlantConfiguration plant;
  final EmployeeProfile employee;
}
