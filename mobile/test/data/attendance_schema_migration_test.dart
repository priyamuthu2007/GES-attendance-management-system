import 'package:ges_offline_attendance/data/attendance_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

void main() {
  late Database database;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: _createVersionOneSchema,
      ),
    );
    await database.insert('attendance_events', {
      'event_id': 'legacy-event',
      'device_id': 'device-1',
      'employee_id': 'EMP-1',
      'event_type': 'checkIn',
      'attendance_date': '2026-11-05',
      'timestamp_utc': '2026-11-05T03:30:00.000Z',
      'location_captured_at_utc': '2026-11-05T03:30:00.000Z',
      'timezone_offset_minutes': 330,
      'shift_start': '09:00',
      'grace_period_minutes': 5,
      'latitude': 13.0,
      'longitude': 80.0,
      'accuracy_meters': 2.0,
      'distance_meters': 0.0,
      'timezone_id': 'Asia/Kolkata',
      'is_late': 0,
      'total_delay_minutes': 0,
      'delay_after_grace_minutes': 0,
      'face_model_version': 'face-v1',
      'liveness_model_version': 'live-v1',
      'verification_status': 'verified',
    });
  });

  tearDown(() => database.close());

  test(
    'migrates old attendance and preserves its verification metadata',
    () async {
      await migrateAttendanceSchemaFromV1(database);

      final events = await database.query('attendance_events');
      expect(events, hasLength(1));
      expect(events.single['event_id'], 'legacy-event');
      expect(events.single['verification_method'], 'faceBiometric');
      expect(events.single['verification_status'], 'biometricVerified');
      expect(events.single['face_model_version'], 'face-v1');

      final profile = await database.rawQuery(
        'SELECT pin_salt, pin_hash, pin_failed_attempts '
        'FROM app_profile WHERE id = 1',
      );
      expect(profile.single['pin_salt'], isNull);
      expect(profile.single['pin_hash'], isNull);
      expect(profile.single['pin_failed_attempts'], 0);
    },
  );
}

Future<void> _createVersionOneSchema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE app_profile (
      id INTEGER PRIMARY KEY,
      plant_name TEXT NOT NULL,
      plant_latitude REAL NOT NULL,
      plant_longitude REAL NOT NULL,
      radius_meters REAL NOT NULL,
      max_accuracy_meters REAL NOT NULL,
      timezone_id TEXT NOT NULL,
      employee_id TEXT NOT NULL,
      employee_name TEXT NOT NULL,
      shift_start TEXT NOT NULL,
      grace_period_minutes INTEGER NOT NULL,
      shift_days TEXT NOT NULL,
      configured_at_utc TEXT NOT NULL
    )
  ''');
  await db.insert('app_profile', {
    'id': 1,
    'plant_name': 'Plant',
    'plant_latitude': 13.0,
    'plant_longitude': 80.0,
    'radius_meters': 10.0,
    'max_accuracy_meters': 25.0,
    'timezone_id': 'Asia/Kolkata',
    'employee_id': 'EMP-1',
    'employee_name': 'Employee',
    'shift_start': '09:00',
    'grace_period_minutes': 5,
    'shift_days': '1,2,3,4,5',
    'configured_at_utc': '2026-11-05T00:00:00.000Z',
  });
  await db.execute('''
    CREATE TABLE attendance_events (
      event_id TEXT PRIMARY KEY NOT NULL,
      device_id TEXT NOT NULL,
      employee_id TEXT NOT NULL,
      event_type TEXT NOT NULL,
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
      is_late INTEGER NOT NULL,
      total_delay_minutes INTEGER NOT NULL,
      delay_after_grace_minutes INTEGER NOT NULL,
      face_model_version TEXT NOT NULL,
      liveness_model_version TEXT NOT NULL,
      verification_status TEXT NOT NULL
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
