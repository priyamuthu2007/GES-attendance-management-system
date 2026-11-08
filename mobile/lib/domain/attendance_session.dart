import 'package:timezone/timezone.dart' as tz;

import 'attendance_rules.dart';

enum AttendanceSessionStatus {
  scheduled,
  present,
  completed,
  absent,
  incomplete,
}

class AttendanceSession {
  const AttendanceSession({
    required this.sessionId,
    required this.employeeId,
    required this.shiftName,
    required this.shiftDate,
    required this.startUtc,
    required this.endUtc,
    required this.checkInDeadlineUtc,
    required this.status,
    required this.updatedAtUtc,
  });

  final String sessionId;
  final String employeeId;
  final String shiftName;
  final String shiftDate;
  final DateTime startUtc;
  final DateTime endUtc;
  final DateTime checkInDeadlineUtc;
  final AttendanceSessionStatus status;
  final DateTime updatedAtUtc;

  factory AttendanceSession.fromMap(Map<String, Object?> map) =>
      AttendanceSession(
        sessionId: map['session_id']! as String,
        employeeId: map['employee_id']! as String,
        shiftName: map['shift_name']! as String,
        shiftDate: map['shift_date']! as String,
        startUtc: DateTime.parse(map['start_utc']! as String),
        endUtc: DateTime.parse(map['end_utc']! as String),
        checkInDeadlineUtc: DateTime.parse(
          map['check_in_deadline_utc']! as String,
        ),
        status: AttendanceSessionStatus.values.byName(map['status']! as String),
        updatedAtUtc: DateTime.parse(map['updated_at_utc']! as String),
      );

  Map<String, Object?> toMap() => {
    'session_id': sessionId,
    'employee_id': employeeId,
    'shift_name': shiftName,
    'shift_date': shiftDate,
    'start_utc': startUtc.toIso8601String(),
    'end_utc': endUtc.toIso8601String(),
    'check_in_deadline_utc': checkInDeadlineUtc.toIso8601String(),
    'status': status.name,
    'updated_at_utc': updatedAtUtc.toIso8601String(),
  };
}

class ShiftOccurrence {
  const ShiftOccurrence({
    required this.shiftDate,
    required this.start,
    required this.end,
    required this.checkInDeadline,
  });

  final String shiftDate;
  final tz.TZDateTime start;
  final tz.TZDateTime end;
  final tz.TZDateTime checkInDeadline;
}

ShiftOccurrence shiftOccurrence({
  required Shift shift,
  required DateTime localDate,
  required String timezoneId,
}) {
  shift.validate();
  final timezone = tz.getLocation(timezoneId);
  final start = tz.TZDateTime(
    timezone,
    localDate.year,
    localDate.month,
    localDate.day,
    shift.startHour,
    shift.startMinute,
  );
  var end = tz.TZDateTime(
    timezone,
    localDate.year,
    localDate.month,
    localDate.day,
    shift.endHour,
    shift.endMinute,
  );
  if (!end.isAfter(start)) end = end.add(const Duration(days: 1));
  final deadline = start.add(Duration(minutes: shift.checkInWindowMinutes));
  return ShiftOccurrence(
    shiftDate: _dateKey(start),
    start: start,
    end: end,
    checkInDeadline: deadline,
  );
}

String shiftSessionId({
  required String employeeId,
  required String shiftDate,
  required String shiftName,
}) => '$employeeId:$shiftDate:$shiftName';

String shiftDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String _dateKey(DateTime date) => shiftDateKey(date);
