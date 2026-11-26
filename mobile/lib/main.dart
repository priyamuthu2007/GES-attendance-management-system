import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'data/mobile_attendance_api.dart';
import 'online_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const secureStorage = FlutterSecureStorage();
  final api = MobileAttendanceApi(
    storage: FlutterSecureValueStore(secureStorage),
  );
  runApp(OnlineAttendanceApp(api: api));
}
