import 'dart:math';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as timezone_data;

import 'app.dart';
import 'data/attendance_database.dart';
import 'data/attendance_repository.dart';
import 'services/attendance_workflow.dart';
import 'services/geolocator_location_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  const secureStorage = FlutterSecureStorage();
  final deviceId = await _deviceId(secureStorage);
  final repository = AttendanceRepository(
    directory: await getApplicationSupportDirectory(),
    encryptionKey: await _attendanceJsonKey(secureStorage),
  );
  final legacyDatabase = await AttendanceDatabase.openIfExists(secureStorage);
  if (legacyDatabase != null) {
    var imported = false;
    try {
      final legacyProfiles = await legacyDatabase.database.query(
        'app_profile',
        where: 'id = 1',
      );
      final legacyEvents = await legacyDatabase.database.query(
        'attendance_events',
      );
      await repository.importLegacyData(
        profile: legacyProfiles.isEmpty
            ? null
            : Map<String, Object?>.from(legacyProfiles.first),
        events: legacyEvents.map(Map<String, Object?>.from).toList(),
      );
      imported = true;
    } finally {
      if (imported) {
        await legacyDatabase.deleteAfterImport();
      } else {
        await legacyDatabase.database.close();
      }
    }
  }
  final locationProvider = GeolocatorLocationProvider();
  final workflow = AttendanceWorkflow(
    repository: repository,
    locationProvider: locationProvider,
    deviceId: deviceId,
  );
  runApp(
    AttendanceApp(
      repository: repository,
      locationProvider: locationProvider,
      workflow: workflow,
    ),
  );
}

Future<List<int>> _attendanceJsonKey(FlutterSecureStorage secureStorage) async {
  const keyName = 'attendance_json_encryption_key_v1';
  final existing = await secureStorage.read(key: keyName);
  if (existing != null) {
    final key = base64Url.decode(existing);
    if (key.length == 32) return key;
    throw StateError('Stored attendance JSON encryption key is invalid.');
  }
  final random = Random.secure();
  final key = List<int>.generate(32, (_) => random.nextInt(256));
  await secureStorage.write(key: keyName, value: base64UrlEncode(key));
  return key;
}

Future<String> _deviceId(FlutterSecureStorage secureStorage) async {
  const keyName = 'attendance_device_id_v1';
  final existing = await secureStorage.read(key: keyName);
  if (existing != null && existing.isNotEmpty) return existing;
  final random = Random.secure();
  final generated = List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  await secureStorage.write(key: keyName, value: generated);
  return generated;
}
