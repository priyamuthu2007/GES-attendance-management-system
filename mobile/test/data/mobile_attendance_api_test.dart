import 'dart:convert';
import 'dart:io';

import 'package:ges_offline_attendance/data/mobile_attendance_api.dart';
import 'package:test/test.dart';

class MemorySecureStore implements SecureValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  late HttpServer server;
  var signedIn = false;
  var loginIncludedCsrfAndCookie = false;
  Map<String, Object?>? checkInPayload;
  var checkInIncludedCsrfAndCookie = false;

  setUp(() async {
    signedIn = false;
    loginIncludedCsrfAndCookie = false;
    checkInPayload = null;
    checkInIncludedCsrfAndCookie = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;

      if (request.uri.path == '/api/csrf-token') {
        response.headers.add(
          'set-cookie',
          'session=${signedIn ? 'authenticated' : 'preauth'}; Path=/; HttpOnly',
        );
        response.write(jsonEncode({'csrfToken': 'test-csrf-token'}));
      } else if (request.uri.path == '/api/auth/login') {
        final payload = jsonDecode(await request.transform(utf8.decoder).join())
            as Map<String, Object?>;
        loginIncludedCsrfAndCookie =
            request.headers.value('X-CSRFToken') == 'test-csrf-token' &&
            request.headers.value('cookie') == 'session=preauth' &&
            payload['employeeId'] == 'EMPLOYEE-002' &&
            payload['password'] == 'test-password';
        signedIn = true;
        response.headers.add(
          'set-cookie',
          'session=authenticated; Path=/; HttpOnly',
        );
        response.write(jsonEncode({'employeeId': 'EMPLOYEE-002'}));
      } else if (request.uri.path == '/api/attendance/today') {
        response.write(
          jsonEncode({
            'employeeId': 'EMPLOYEE-002',
            'timeZone': 'Asia/Kolkata',
            'shift': {'start': null, 'end': null},
            'attendance': null,
            'offices': [
              {
                'id': 'kpl',
                'name': 'KPL',
                'latitude': 13.2515,
                'longitude': 80.3065,
              },
            ],
          }),
        );
      } else if (request.uri.path == '/api/attendance/check-in') {
        checkInPayload =
            jsonDecode(await request.transform(utf8.decoder).join())
                as Map<String, Object?>;
        checkInIncludedCsrfAndCookie =
            request.headers.value('X-CSRFToken') == 'test-csrf-token' &&
            request.headers.value('cookie') == 'session=authenticated';
        response.statusCode = HttpStatus.created;
        response.write(jsonEncode({'message': 'Check-in recorded.'}));
      } else {
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({'error': 'Not found.'}));
      }

      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('signs in with CSRF, loads today, and sends fresh location', () async {
    final storage = MemorySecureStore();
    final api = MobileAttendanceApi(
      storage: storage,
      allowInsecureLoopbackForTesting: true,
    );
    addTearDown(api.close);
    await api.setServerUrl('http://127.0.0.1:${server.port}');

    final employeeId = await api.signIn(
      employeeId: 'EMPLOYEE-002',
      password: 'test-password',
    );
    final today = await api.loadToday();
    await api.checkIn(
      latitude: 13.2515,
      longitude: 80.3065,
      accuracyMeters: 3.2,
    );

    expect(employeeId, 'EMPLOYEE-002');
    expect(loginIncludedCsrfAndCookie, isTrue);
    expect(today.offices.single.name, 'KPL');
    expect(today.shift, isNotNull);
    expect(checkInIncludedCsrfAndCookie, isTrue);
    expect(checkInPayload, {
      'latitude': 13.2515,
      'longitude': 80.3065,
      'accuracyMeters': 3.2,
    });
    expect(await api.hasSavedSession(), isTrue);
  });

  test('rejects non-HTTPS production server URLs', () async {
    final api = MobileAttendanceApi(storage: MemorySecureStore());
    addTearDown(api.close);

    await expectLater(
      api.setServerUrl('http://attendance.example.com'),
      throwsA(isA<FormatException>()),
    );
  });
}
