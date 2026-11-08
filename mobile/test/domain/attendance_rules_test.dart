import 'package:test/test.dart';
import 'package:ges_offline_attendance/domain/attendance_rules.dart';

void main() {
  const shift = Shift(startHour: 9, startMinute: 0, gracePeriodMinutes: 5);

  test('calculates total and post-grace delay', () {
    final result = calculateLateness(
      checkInLocal: DateTime(2026, 11, 5, 9, 12),
      shift: shift,
    );

    expect(result.isLate, isTrue);
    expect(result.totalDelayMinutes, 12);
    expect(result.delayAfterGraceMinutes, 7);
  });

  test('arrival exactly at the grace limit is on time', () {
    final result = calculateLateness(
      checkInLocal: DateTime(2026, 11, 5, 9, 5),
      shift: shift,
    );

    expect(result.isLate, isFalse);
    expect(result.delayAfterGraceMinutes, 0);
  });

  test('rounds partial minutes up after the grace limit', () {
    final result = calculateLateness(
      checkInLocal: DateTime(2026, 11, 5, 9, 5, 1),
      shift: shift,
    );

    expect(result.isLate, isTrue);
    expect(result.delayAfterGraceMinutes, 1);
  });

  test('early arrival has no delay', () {
    final result = calculateLateness(
      checkInLocal: DateTime(2026, 11, 5, 8, 58),
      shift: shift,
    );

    expect(result.isLate, isFalse);
    expect(result.totalDelayMinutes, 0);
  });

  test('calculates lateness correctly for an overnight shift', () {
    final result = calculateLatenessFromShiftStart(
      checkInLocal: DateTime.utc(2026, 11, 6, 0, 7),
      shiftStartLocal: DateTime.utc(2026, 11, 5, 22),
      gracePeriodMinutes: 5,
    );

    expect(result.isLate, isTrue);
    expect(result.totalDelayMinutes, 127);
    expect(result.delayAfterGraceMinutes, 122);
  });
}
