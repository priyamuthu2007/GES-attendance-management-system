import 'package:timezone/timezone.dart' as tz;

import '../data/attendance_repository.dart';
import '../domain/attendance_event.dart';
import '../domain/attendance_rules.dart';
import '../domain/attendance_session.dart';
import '../domain/geofence.dart';
import '../domain/location_provider.dart';

class AttendanceWorkflow {
  AttendanceWorkflow({
    required this.repository,
    required this.locationProvider,
    required this.deviceId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AttendanceStore repository;
  final LocationProvider locationProvider;
  final String deviceId;
  final DateTime Function() _clock;

  Future<AttendanceEvent> record({
    required LocalProfile profile,
    required AttendanceEventType type,
    required String pin,
  }) async {
    final plantTimeZone = tz.getLocation(profile.plant.timezoneId);
    final start = tz.TZDateTime.from(_clock().toUtc(), plantTimeZone);
    final polledSessions = await repository.pollAttendance(
      profile,
      start.toUtc(),
    );
    final shiftSession = _sessionForAction(
      profile: profile,
      type: type,
      now: start,
      sessions: polledSessions,
    );
    final dayKey = shiftSession.shiftDate;
    final existingEvents = await repository.eventsForDate(
      profile.employee.employeeId,
      dayKey,
    );
    final hasCheckIn = existingEvents.any(
      (event) => event.type == AttendanceEventType.checkIn,
    );
    final hasCheckOut = existingEvents.any(
      (event) => event.type == AttendanceEventType.checkOut,
    );

    if (type == AttendanceEventType.checkIn) {
      if (start.toUtc().isBefore(shiftSession.start.toUtc()) ||
          start.toUtc().isAfter(shiftSession.checkInDeadline.toUtc())) {
        throw StateError('Check-in is outside the permitted shift window.');
      }
    }

    if (type == AttendanceEventType.checkIn) {
      if (hasCheckIn || hasCheckOut) {
        throw StateError('Attendance was already recorded for today.');
      }
    } else if (!hasCheckIn || hasCheckOut) {
      throw StateError('There is no open check-in to close.');
    }

    final fix = await locationProvider.getFreshFix();
    final geofence = PlantFence(
      latitude: profile.plant.latitude,
      longitude: profile.plant.longitude,
      radiusMeters: profile.plant.radiusMeters,
      maxAccuracyMeters: profile.plant.maxAccuracyMeters,
    );
    final geofenceResult = verifyLocation(
      fence: geofence,
      fix: fix,
      now: _clock().toUtc(),
    );
    if (!geofenceResult.accepted) {
      throw StateError(
        geofenceResult.reason ?? 'Location could not be verified.',
      );
    }

    final recordedAt = tz.TZDateTime.from(_clock().toUtc(), plantTimeZone);
    if (type == AttendanceEventType.checkIn &&
        (recordedAt.toUtc().isBefore(shiftSession.start.toUtc()) ||
            recordedAt.toUtc().isAfter(shiftSession.checkInDeadline.toUtc()))) {
      throw StateError(
        'The check-in window closed during location verification.',
      );
    }
    if (type == AttendanceEventType.checkOut &&
        recordedAt.toUtc().isAfter(
          shiftSession.end.toUtc().add(const Duration(hours: 6)),
        )) {
      throw StateError('The shift check-out window has expired.');
    }
    final finalLocationCheck = verifyLocation(
      fence: geofence,
      fix: fix,
      now: recordedAt,
    );
    if (!finalLocationCheck.accepted) {
      throw StateError(
        finalLocationCheck.reason ?? 'Location could not be verified.',
      );
    }

    final shiftStartLocal = tz.TZDateTime.from(
      shiftSession.start.toUtc(),
      plantTimeZone,
    );
    final lateness = type == AttendanceEventType.checkIn
        ? calculateLatenessFromShiftStart(
            checkInLocal: recordedAt,
            shiftStartLocal: shiftStartLocal,
            gracePeriodMinutes: profile.employee.shift.gracePeriodMinutes,
          )
        : const Lateness(
            isLate: false,
            totalDelayMinutes: 0,
            delayAfterGraceMinutes: 0,
          );
    final shiftStart = profile.employee.shift;
    final event = AttendanceEvent(
      eventId: AttendanceRepository.createEventId(),
      deviceId: deviceId,
      employeeId: profile.employee.employeeId,
      type: type,
      attendanceDate: dayKey,
      timestampUtc: recordedAt.toUtc(),
      locationCapturedAtUtc: fix.capturedAt.toUtc(),
      timezoneOffsetMinutes: recordedAt.timeZoneOffset.inMinutes,
      shiftName: profile.employee.shift.name,
      shiftStart:
          '${shiftStartLocal.hour.toString().padLeft(2, '0')}:'
          '${shiftStartLocal.minute.toString().padLeft(2, '0')}',
      gracePeriodMinutes: shiftStart.gracePeriodMinutes,
      latitude: fix.latitude,
      longitude: fix.longitude,
      accuracyMeters: fix.accuracyMeters,
      distanceMeters: finalLocationCheck.distanceMeters!,
      timezoneId: profile.plant.timezoneId,
      isLate: lateness.isLate,
      totalDelayMinutes: lateness.totalDelayMinutes,
      delayAfterGraceMinutes: lateness.delayAfterGraceMinutes,
      verificationMethod: AttendanceVerificationMethod.employeePin,
      verificationStatus: AttendanceVerificationStatus.pinConfirmed,
    );
    await repository.recordEvent(event, pin: pin);
    return event;
  }

  ShiftOccurrence _sessionForAction({
    required LocalProfile profile,
    required AttendanceEventType type,
    required tz.TZDateTime now,
    required List<AttendanceSession> sessions,
  }) {
    final shift = profile.employee.shift;
    final candidateDates = [now, now.subtract(const Duration(days: 1))];
    final occurrences = candidateDates
        .where((date) => profile.employee.shiftDays.contains(date.weekday))
        .map(
          (date) => shiftOccurrence(
            shift: shift,
            localDate: date,
            timezoneId: profile.plant.timezoneId,
          ),
        )
        .toList();
    if (type == AttendanceEventType.checkIn) {
      final occurrence = occurrences.where((candidate) {
        final start = candidate.start;
        final deadline = candidate.checkInDeadline;
        return !now.isBefore(start) && !now.isAfter(deadline);
      }).firstOrNull;
      if (occurrence == null) {
        throw StateError(
          'Check-in is not open for the assigned shift. '
          'It opens at shift start and closes after '
          '${shift.checkInWindowMinutes} minutes.',
        );
      }
      final expectedSessionId = shiftSessionId(
        employeeId: profile.employee.employeeId,
        shiftDate: occurrence.shiftDate,
        shiftName: shift.name,
      );
      if (!sessions.any((session) => session.sessionId == expectedSessionId)) {
        throw StateError(
          'The offline attendance poll has not created a shift session.',
        );
      }
      return occurrence;
    }

    final occurrence = occurrences.where((candidate) {
      final id = shiftSessionId(
        employeeId: profile.employee.employeeId,
        shiftDate: candidate.shiftDate,
        shiftName: shift.name,
      );
      final session = sessions
          .where((item) => item.sessionId == id)
          .firstOrNull;
      return session != null &&
          (session.status == AttendanceSessionStatus.present) &&
          !now.isBefore(candidate.start) &&
          !now.isAfter(candidate.end.add(const Duration(hours: 6)));
    }).firstOrNull;
    if (occurrence == null) {
      throw StateError('There is no open assigned shift to check out from.');
    }
    return occurrence;
  }
}
