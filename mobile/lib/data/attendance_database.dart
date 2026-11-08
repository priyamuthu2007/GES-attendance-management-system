import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'attendance_schema.dart';

class AttendanceDatabase {
  AttendanceDatabase._(this.database, this._databasePath);

  final Database database;
  final String _databasePath;

  static const _databaseName = 'ges_offline_attendance.db';
  static const _keyName = 'attendance_database_key_v1';

  static Future<AttendanceDatabase> open(
    FlutterSecureStorage secureStorage,
  ) async {
    final key = await _databaseKey(secureStorage);
    final databasePath = path.join(await getDatabasesPath(), _databaseName);
    final database = await _open(databasePath, key);
    return AttendanceDatabase._(database, databasePath);
  }

  static Future<AttendanceDatabase?> openIfExists(
    FlutterSecureStorage secureStorage,
  ) async {
    final databasePath = path.join(await getDatabasesPath(), _databaseName);
    if (!await File(databasePath).exists()) return null;
    return open(secureStorage);
  }

  static Future<Database> _open(String databasePath, String key) async {
    return openDatabase(
      databasePath,
      password: key,
      version: 2,
      onCreate: (db, _) async {
        await createAttendanceSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await migrateAttendanceSchemaFromV1(db);
      },
    );
  }

  static Future<String> _databaseKey(FlutterSecureStorage secureStorage) async {
    final existing = await secureStorage.read(key: _keyName);
    if (existing != null && existing.length >= 40) return existing;

    final random = Random.secure();
    final key = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await secureStorage.write(key: _keyName, value: key);
    return key;
  }

  Future<void> deleteAfterImport() async {
    await database.close();
    await deleteDatabase(_databasePath);
  }
}
