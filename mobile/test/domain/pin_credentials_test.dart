import 'package:ges_offline_attendance/domain/pin_credentials.dart';
import 'package:test/test.dart';

void main() {
  test('creates a salted PIN credential and verifies the PIN', () async {
    final credential = await PinCredential.create('123456');

    expect(credential.salt, isNot(credential.hash));
    expect(
      await PinCredential.verify(
        pin: '123456',
        salt: credential.salt,
        hash: credential.hash,
      ),
      isTrue,
    );
    expect(
      await PinCredential.verify(
        pin: '654321',
        salt: credential.salt,
        hash: credential.hash,
      ),
      isFalse,
    );
  });

  test('rejects PINs that are not exactly six digits', () async {
    await expectLater(
      PinCredential.create('12345'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      await PinCredential.verify(pin: '12x456', salt: '', hash: ''),
      isFalse,
    );
  });
}
