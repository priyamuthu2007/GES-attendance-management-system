import 'package:sqflite_common/sqlite_api.dart';

Future<void> createAttendanceSchema(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE app_profile (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      plant_name TEXT NOT NULL,
      plant_latitude REAL NOT NULL,
      plant_longitude REAL NOT NULL,
      radius_meters REAL NOT NULL,
      max_accuracy_meters REAL NOT NULL,
      timezone_id TEXT NOT NULL,
      employee_id TEXT NOT NULL,
      employee_name TEXT NOT NULL,
      pin_salt TEXT,
      pin_hash TEXT,
      pin_failed_attempts INTEGER NOT NULL DEFAULT 0,
      pin_locked_until_utc TEXT,
      shift_start TEXT NOT NULL,
      grace_period_minutes INTEGER NOT NULL,
      shift_days TEXT NOT NULL,
      configured_at_utc TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE attendance_events (
      event_id TEXT PRIMARY KEY NOT NULL,
      device_id TEXT NOT NULL,
      employee_id TEXT NOT NULL,
      event_type TEXT NOT NULL CHECK (event_type IN ('checkIn', 'checkOut')),
      attendance_date TEXT NOT NULL,
      timestamp_utc TEXT NOT NULL,
      location_captured_at_utc TEXT NOT NULL,
      timezone_offset_minutes INTEGER NOT NULL,
      shift_start TEXT NOT NULL,
      grace_period_minutes INTEGER NOT NULL,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL,
      accuracy_meters REAL NOT NULL,
      distance_meters REAL NOT NULL,
      timezone_id TEXT NOT NULL,
      is_late INTEGER NOT NULL CHECK (is_late IN (0, 1)),
      total_delay_minutes INTEGER NOT NULL,
      delay_after_grace_minutes INTEGER NOT NULL,
      face_model_version TEXT,
      liveness_model_version TEXT,
      verification_method TEXT NOT NULL
        CHECK (verification_method IN ('employeePin', 'faceBiometric')),
      verification_status TEXT NOT NULL
        CHECK (verification_status IN ('pinConfirmed', 'biometricVerified'))
    )
  ''');
  await db.execute('''
    CREATE UNIQUE INDEX attendance_event_once_per_day
    ON attendance_events(employee_id, attendance_date, event_type)
  ''');
  await db.execute('''
    CREATE INDEX attendance_events_employee_time
    ON attendance_events(employee_id, timestamp_utc DESC)
  ''');
}

Future<void> migrateAttendanceSchemaFromV1(DatabaseExecutor db) async {
  await db.execute('ALTER TABLE app_profile ADD COLUMN pin_salt TEXT');
  await db.execute('ALTER TABLE app_profile ADD COLUMN pin_hash TEXT');
  await db.execute(
    'ALTER TABLE app_profile ADD COLUMN pin_failed_attempts INTEGER NOT NULL DEFAULT 0',
  );
  await db.execute(
    'ALTER TABLE app_profile ADD COLUMN pin_locked_until_utc TEXT',
  );
  await db.execute(
    'ALTER TABLE attendance_events RENAME TO attendance_events_v1',
  );
  await db.execute('''
    CREATE TABLE attendance_events (
      event_id TEXT PRIMARY KEY NOT NULL,
      device_id TEXT NOT NULL,
      employee_id TEXT NOT NULL,
      event_type TEXT NOT NULL CHECK (event_type IN ('checkIn', 'checkOut')),
      attendance_date TEXT NOT NULL,
      timestamp_utc TEXT NOT NULL,
      location_captured_at_utc TEXT NOT NULL,
      timezone_offset_minutes INTEGER NOT NULL,
      shift_start TEXT NOT NULL,
      grace_period_minutes INTEGER NOT NULL,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL,
      accuracy_meters REAL NOT NULL,
      distance_meters REAL NOT NULL,
      timezone_id TEXT NOT NULL,
      is_late INTEGER NOT NULL CHECK (is_late IN (0, 1)),
      total_delay_minutes INTEGER NOT NULL,
      delay_after_grace_minutes INTEGER NOT NULL,
      face_model_version TEXT,
      liveness_model_version TEXT,
      verification_method TEXT NOT NULL
        CHECK (verification_method IN ('employeePin', 'faceBiometric')),
      verification_status TEXT NOT NULL
        CHECK (verification_status IN ('pinConfirmed', 'biometricVerified'))
    )
  ''');
  await db.execute('''
    INSERT INTO attendance_events (
      event_id, device_id, employee_id, event_type, attendance_date,
      timestamp_utc, location_captured_at_utc, timezone_offset_minutes,
      shift_start, grace_period_minutes, latitude, longitude, accuracy_meters,
      distance_meters, timezone_id, is_late, total_delay_minutes,
      delay_after_grace_minutes, face_model_version, liveness_model_version,
      verification_method, verification_status
    )
    SELECT
      event_id, device_id, employee_id, event_type, attendance_date,
      timestamp_utc, location_captured_at_utc, timezone_offset_minutes,
      shift_start, grace_period_minutes, latitude, longitude, accuracy_meters,
      distance_meters, timezone_id, is_late, total_delay_minutes,
      delay_after_grace_minutes, face_model_version, liveness_model_version,
      'faceBiometric', 'biometricVerified'
    FROM attendance_events_v1
  ''');
  await db.execute('DROP TABLE attendance_events_v1');
  await _createAttendanceIndexes(db);
}

Future<void> _createAttendanceIndexes(DatabaseExecutor db) async {
  await db.execute('''
    CREATE UNIQUE INDEX attendance_event_once_per_day
    ON attendance_events(employee_id, attendance_date, event_type)
  ''');
  await db.execute('''
    CREATE INDEX attendance_events_employee_time
    ON attendance_events(employee_id, timestamp_utc DESC)
  ''');
}
