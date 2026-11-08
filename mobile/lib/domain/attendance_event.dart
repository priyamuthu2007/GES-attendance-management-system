import 'attendance_rules.dart';

enum AttendanceEventType { checkIn, checkOut }

enum AttendanceVerificationMethod { employeePin, faceBiometric }

enum AttendanceVerificationStatus { pinConfirmed, biometricVerified }

class AttendanceEvent {
  const AttendanceEvent({
    required this.eventId,
    required this.deviceId,
    required this.employeeId,
    required this.type,
    required this.attendanceDate,
    required this.timestampUtc,
    required this.locationCapturedAtUtc,
    required this.timezoneOffsetMinutes,
    required this.shiftName,
    required this.shiftStart,
    required this.gracePeriodMinutes,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.distanceMeters,
    required this.timezoneId,
    required this.isLate,
    required this.totalDelayMinutes,
    required this.delayAfterGraceMinutes,
    required this.verificationMethod,
    required this.verificationStatus,
  });

  final String eventId;
  final String deviceId;
  final String employeeId;
  final AttendanceEventType type;
  final String attendanceDate;
  final DateTime timestampUtc;
  final DateTime locationCapturedAtUtc;
  final int timezoneOffsetMinutes;
  final String shiftName;
  final String shiftStart;
  final int gracePeriodMinutes;
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final double distanceMeters;
  final String timezoneId;
  final bool isLate;
  final int totalDelayMinutes;
  final int delayAfterGraceMinutes;
  final AttendanceVerificationMethod verificationMethod;
  final AttendanceVerificationStatus verificationStatus;

  factory AttendanceEvent.fromMap(Map<String, Object?> row) {
    return AttendanceEvent(
      eventId: row['event_id']! as String,
      deviceId: row['device_id']! as String,
      employeeId: row['employee_id']! as String,
      type: AttendanceEventType.values.byName(row['event_type']! as String),
      attendanceDate: row['attendance_date']! as String,
      timestampUtc: DateTime.parse(row['timestamp_utc']! as String),
      locationCapturedAtUtc: DateTime.parse(
        row['location_captured_at_utc']! as String,
      ),
      timezoneOffsetMinutes: row['timezone_offset_minutes']! as int,
      shiftName: row['shift_name']! as String,
      shiftStart: row['shift_start']! as String,
      gracePeriodMinutes: row['grace_period_minutes']! as int,
      latitude: (row['latitude']! as num).toDouble(),
      longitude: (row['longitude']! as num).toDouble(),
      accuracyMeters: (row['accuracy_meters']! as num).toDouble(),
      distanceMeters: (row['distance_meters']! as num).toDouble(),
      timezoneId: row['timezone_id']! as String,
      isLate: (row['is_late']! as int) == 1,
      totalDelayMinutes: row['total_delay_minutes']! as int,
      delayAfterGraceMinutes: row['delay_after_grace_minutes']! as int,
      verificationMethod: AttendanceVerificationMethod.values.byName(
        row['verification_method']! as String,
      ),
      verificationStatus: AttendanceVerificationStatus.values.byName(
        row['verification_status']! as String,
      ),
    );
  }

  Map<String, Object?> toMap() => {
    'event_id': eventId,
    'device_id': deviceId,
    'employee_id': employeeId,
    'event_type': type.name,
    'attendance_date': attendanceDate,
    'timestamp_utc': timestampUtc.toIso8601String(),
    'location_captured_at_utc': locationCapturedAtUtc.toIso8601String(),
    'timezone_offset_minutes': timezoneOffsetMinutes,
    'shift_name': shiftName,
    'shift_start': shiftStart,
    'grace_period_minutes': gracePeriodMinutes,
    'latitude': latitude,
    'longitude': longitude,
    'accuracy_meters': accuracyMeters,
    'distance_meters': distanceMeters,
    'timezone_id': timezoneId,
    'is_late': isLate ? 1 : 0,
    'total_delay_minutes': totalDelayMinutes,
    'delay_after_grace_minutes': delayAfterGraceMinutes,
    'verification_method': verificationMethod.name,
    'verification_status': verificationStatus.name,
  };
}

class PlantConfiguration {
  const PlantConfiguration({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.radiusMeters = 50,
    this.maxAccuracyMeters = 25,
    this.timezoneId = 'Asia/Kolkata',
  });

  final String name;
  final double latitude;
  final double longitude;
  final double radiusMeters;
  final double maxAccuracyMeters;
  final String timezoneId;
}

class EmployeeProfile {
  const EmployeeProfile({
    required this.employeeId,
    required this.name,
    required this.shift,
    required this.shiftDays,
  });

  final String employeeId;
  final String name;
  final Shift shift;
  final Set<int> shiftDays;
}
