import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

class PinCredential {
  const PinCredential._({required this.salt, required this.hash});

  final String salt;
  final String hash;

  static const _iterations = 120000;
  static const _bits = 256;
  static const _saltLength = 16;
  static Future<PinCredential> create(String pin) async {
    _validatePin(pin);
    final random = Random.secure();
    final salt = List<int>.generate(_saltLength, (_) => random.nextInt(256));
    final hash = await _derive(pin, salt);
    return PinCredential._(
      salt: base64UrlEncode(salt),
      hash: base64UrlEncode(hash),
    );
  }

  static Future<bool> verify({
    required String pin,
    required String salt,
    required String hash,
  }) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) return false;
    final saltBytes = base64Url.decode(salt);
    final expected = base64Url.decode(hash);
    final actual = await _derive(pin, saltBytes);
    if (actual.length != expected.length) return false;
    var difference = 0;
    for (var index = 0; index < actual.length; index++) {
      difference |= actual[index] ^ expected[index];
    }
    return difference == 0;
  }

  static Future<List<int>> _derive(String pin, List<int> salt) async {
    return Isolate.run(() async {
      final algorithm = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: _iterations,
        bits: _bits,
      );
      final key = await algorithm.deriveKey(
        secretKey: SecretKey(utf8.encode(pin)),
        nonce: salt,
      );
      return key.extractBytes();
    });
  }

  static void _validatePin(String pin) {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw ArgumentError('Employee PIN must contain exactly six digits.');
    }
  }
}
