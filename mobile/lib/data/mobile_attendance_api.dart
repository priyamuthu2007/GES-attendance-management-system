import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecureValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureValueStore implements SecureValueStore {
  const FlutterSecureValueStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class AttendanceApiException implements Exception {
  const AttendanceApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class MobileAttendanceApi {
  MobileAttendanceApi({
    required SecureValueStore storage,
    HttpClient? httpClient,
    bool allowInsecureLoopbackForTesting = false,
  }) : _storage = storage,
       _httpClient = httpClient ?? HttpClient(),
       _allowInsecureLoopbackForTesting = allowInsecureLoopbackForTesting;

  static const _serverUrlKey = 'ges_mobile_server_url_v1';
  static const _sessionCookieKey = 'ges_mobile_session_cookie_v1';
  static const _sessionOriginKey = 'ges_mobile_session_origin_v1';
  static const _requestTimeout = Duration(seconds: 20);

  final SecureValueStore _storage;
  final HttpClient _httpClient;
  final bool _allowInsecureLoopbackForTesting;
  Uri? _serverUri;

  String? get serverUrl => _serverUri?.origin;

  Future<String?> loadServerUrl() async {
    final saved = await _storage.read(_serverUrlKey);
    if (saved == null || saved.isEmpty) return null;
    await setServerUrl(saved);
    return serverUrl;
  }

  Future<void> setServerUrl(String value) async {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null ||
        !parsed.hasAuthority ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.query.isNotEmpty ||
        parsed.fragment.isNotEmpty ||
        (parsed.path.isNotEmpty && parsed.path != '/') ||
        !{'https', 'http'}.contains(parsed.scheme.toLowerCase())) {
      throw const FormatException(
        'Enter a server origin such as https://attendance.example.com.',
      );
    }
    final isLoopback =
        parsed.host == 'localhost' ||
        parsed.host == '127.0.0.1' ||
        parsed.host == '::1';
    if (parsed.scheme.toLowerCase() != 'https' &&
        !(_allowInsecureLoopbackForTesting &&
            parsed.scheme.toLowerCase() == 'http' &&
            isLoopback)) {
      throw const FormatException('Use an HTTPS server address.');
    }

    _serverUri = Uri(
      scheme: parsed.scheme.toLowerCase(),
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
    );
    await _storage.write(_serverUrlKey, _serverUri!.origin);
  }

  Future<bool> hasSavedSession() async {
    final uri = _serverUri;
    if (uri == null) return false;
    final origin = await _storage.read(_sessionOriginKey);
    final cookie = await _storage.read(_sessionCookieKey);
    return origin == uri.origin && cookie != null && cookie.isNotEmpty;
  }

  Future<String> signIn({
    required String employeeId,
    required String password,
  }) async {
    if (_serverUri == null) {
      throw const AttendanceApiException('Set the server URL first.');
    }
    final result = await _request(
      'POST',
      '/api/auth/login',
      body: {'employeeId': employeeId.trim(), 'password': password},
      requiresCsrf: true,
    );
    final signedInId = result['employeeId'];
    if (signedInId is! String || signedInId.isEmpty) {
      throw const AttendanceApiException(
        'The server returned an invalid sign-in response.',
      );
    }
    return signedInId;
  }

  Future<TodayAttendance> loadToday() async {
    final result = await _request('GET', '/api/attendance/today');
    return TodayAttendance.fromJson(result);
  }

  Future<void> checkIn({
    required double latitude,
    required double longitude,
    required double accuracyMeters,
  }) => _record(
    '/api/attendance/check-in',
    latitude: latitude,
    longitude: longitude,
    accuracyMeters: accuracyMeters,
  );

  Future<void> checkOut({
    required double latitude,
    required double longitude,
    required double accuracyMeters,
  }) => _record(
    '/api/attendance/check-out',
    latitude: latitude,
    longitude: longitude,
    accuracyMeters: accuracyMeters,
  );

  Future<void> _record(
    String path, {
    required double latitude,
    required double longitude,
    required double accuracyMeters,
  }) async {
    await _request(
      'POST',
      path,
      requiresCsrf: true,
      body: {
        'latitude': latitude,
        'longitude': longitude,
        'accuracyMeters': accuracyMeters,
      },
    );
  }

  Future<void> signOut() async {
    await _request('POST', '/api/auth/logout', requiresCsrf: true);
    await _clearSession();
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool requiresCsrf = false,
  }) async {
    String? csrfToken;
    if (requiresCsrf) {
      final csrfResponse = await _requestRaw('GET', '/api/csrf-token');
      final value = csrfResponse['csrfToken'];
      if (value is! String || value.isEmpty) {
        throw const AttendanceApiException(
          'The server did not provide a security token.',
        );
      }
      csrfToken = value;
    }
    return _requestRaw(method, path, body: body, csrfToken: csrfToken);
  }

  Future<Map<String, Object?>> _requestRaw(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? csrfToken,
  }) async {
    final baseUri = _serverUri;
    if (baseUri == null) {
      throw const AttendanceApiException('Set the server URL first.');
    }

    try {
      final request = await _httpClient
          .openUrl(method, baseUri.replace(path: path))
          .timeout(_requestTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final origin = await _storage.read(_sessionOriginKey);
      final cookie = await _storage.read(_sessionCookieKey);
      if (origin == baseUri.origin && cookie != null && cookie.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, 'session=$cookie');
      }
      if (csrfToken != null) {
        request.headers.set('X-CSRFToken', csrfToken);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }

      final response = await request.close().timeout(_requestTimeout);
      await _saveSessionCookie(response, baseUri.origin);
      final responseText = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      final decoded = responseText.isEmpty ? <String, Object?>{} : jsonDecode(responseText);
      if (decoded is! Map) {
        throw const AttendanceApiException(
          'The server returned an unexpected response.',
        );
      }
      final result = Map<String, Object?>.from(decoded);
      if (response.statusCode == HttpStatus.unauthorized) {
        await _clearSession();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = result['error'];
        throw AttendanceApiException(
          message is String ? message : 'The server could not complete the request.',
          statusCode: response.statusCode,
        );
      }
      return result;
    } on SocketException {
      throw const AttendanceApiException(
        'Could not reach the server. Check the server URL and your internet or VPN connection.',
      );
    } on TimeoutException {
      throw const AttendanceApiException(
        'The server took too long to respond. Try again.',
      );
    } on FormatException catch (error) {
      throw AttendanceApiException(error.message);
    }
  }

  Future<void> _saveSessionCookie(HttpClientResponse response, String origin) async {
    final headers = response.headers['set-cookie'] ?? const <String>[];
    for (final header in headers) {
      final firstPart = header.split(';').first.trim();
      if (!firstPart.startsWith('session=')) continue;
      final value = firstPart.substring('session='.length);
      if (value.isEmpty) {
        await _clearSession();
      } else {
        await _storage.write(_sessionCookieKey, value);
        await _storage.write(_sessionOriginKey, origin);
      }
    }
  }

  Future<void> _clearSession() async {
    await _storage.delete(_sessionCookieKey);
    await _storage.delete(_sessionOriginKey);
  }

  void close() => _httpClient.close(force: true);
}

class TodayAttendance {
  const TodayAttendance({
    required this.employeeId,
    required this.timeZone,
    required this.shift,
    required this.attendance,
    required this.offices,
  });

  final String employeeId;
  final String timeZone;
  final ShiftSummary? shift;
  final AttendanceSummary? attendance;
  final List<AssignedOffice> offices;

  factory TodayAttendance.fromJson(Map<String, Object?> json) {
    final employeeId = json['employeeId'];
    final timeZone = json['timeZone'];
    if (employeeId is! String || timeZone is! String) {
      throw const FormatException('The attendance response is incomplete.');
    }
    final officesValue = json['offices'];
    if (officesValue is! List) {
      throw const FormatException('The assigned office list is invalid.');
    }
    final shiftValue = json['shift'];
    final attendanceValue = json['attendance'];
    return TodayAttendance(
      employeeId: employeeId,
      timeZone: timeZone,
      shift: shiftValue == null
          ? null
          : ShiftSummary.fromJson(_objectMap(shiftValue)),
      attendance: attendanceValue == null
          ? null
          : AttendanceSummary.fromJson(_objectMap(attendanceValue)),
      offices: officesValue.map(
        (office) => AssignedOffice.fromJson(_objectMap(office)),
      ).toList(growable: false),
    );
  }
}

class ShiftSummary {
  const ShiftSummary({required this.start, required this.end});

  final String? start;
  final String? end;

  factory ShiftSummary.fromJson(Map<String, Object?> json) => ShiftSummary(
    start: _optionalString(json['start'], 'shift.start'),
    end: _optionalString(json['end'], 'shift.end'),
  );
}

class AttendanceSummary {
  const AttendanceSummary({
    required this.attendanceDate,
    required this.checkInAt,
    required this.checkInOffice,
    required this.checkOutAt,
    required this.checkOutOffice,
  });

  final String attendanceDate;
  final String? checkInAt;
  final String? checkInOffice;
  final String? checkOutAt;
  final String? checkOutOffice;

  factory AttendanceSummary.fromJson(Map<String, Object?> json) {
    final attendanceDate = json['attendanceDate'];
    if (attendanceDate is! String) {
      throw const FormatException('The attendance date is invalid.');
    }
    return AttendanceSummary(
      attendanceDate: attendanceDate,
      checkInAt: _optionalString(json['checkInAt'], 'checkInAt'),
      checkInOffice: _optionalString(json['checkInOffice'], 'checkInOffice'),
      checkOutAt: _optionalString(json['checkOutAt'], 'checkOutAt'),
      checkOutOffice: _optionalString(json['checkOutOffice'], 'checkOutOffice'),
    );
  }
}

class AssignedOffice {
  const AssignedOffice({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;

  factory AssignedOffice.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    if (id is! String ||
        name is! String ||
        latitude is! num ||
        longitude is! num) {
      throw const FormatException('An assigned office has invalid data.');
    }
    return AssignedOffice(
      id: id,
      name: name,
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
    );
  }
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) {
    throw const FormatException('The server returned invalid attendance data.');
  }
  return Map<String, Object?>.from(value);
}

String? _optionalString(Object? value, String field) {
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('The server returned an invalid $field value.');
}
