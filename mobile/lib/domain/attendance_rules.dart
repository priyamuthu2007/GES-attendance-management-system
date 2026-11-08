class Shift {
  const Shift({
    this.name = 'Custom',
    required this.startHour,
    required this.startMinute,
    this.endHour = 17,
    this.endMinute = 0,
    required this.gracePeriodMinutes,
    this.checkInWindowMinutes = 120,
  });

  final String name;
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  final int gracePeriodMinutes;
  final int checkInWindowMinutes;

  void validate() {
    final start = startHour * 60 + startMinute;
    final end = endHour * 60 + endMinute;
    final duration = (end - start + 24 * 60) % (24 * 60);
    if (name.trim().isEmpty ||
        startHour < 0 ||
        startHour > 23 ||
        startMinute < 0 ||
        startMinute > 59 ||
        endHour < 0 ||
        endHour > 23 ||
        endMinute < 0 ||
        endMinute > 59 ||
        duration == 0 ||
        duration > 16 * 60 ||
        gracePeriodMinutes < 0 ||
        gracePeriodMinutes > 240 ||
        checkInWindowMinutes < 1 ||
        checkInWindowMinutes > 360) {
      throw ArgumentError('Shift configuration is invalid.');
    }
  }
}

class Lateness {
  const Lateness({
    required this.isLate,
    required this.totalDelayMinutes,
    required this.delayAfterGraceMinutes,
  });

  final bool isLate;
  final int totalDelayMinutes;
  final int delayAfterGraceMinutes;
}

const _microsecondsPerMinute = Duration.microsecondsPerSecond * 60;

Lateness calculateLateness({
  required DateTime checkInLocal,
  required Shift shift,
}) {
  shift.validate();
  final arrivalMicros =
      ((checkInLocal.hour * 60 + checkInLocal.minute) * 60 +
              checkInLocal.second) *
          Duration.microsecondsPerSecond +
      checkInLocal.millisecond * Duration.microsecondsPerMillisecond +
      checkInLocal.microsecond;
  final shiftStartMicros =
      ((shift.startHour * 60 + shift.startMinute) * 60) *
      Duration.microsecondsPerSecond;
  final delayMicros = arrivalMicros - shiftStartMicros;
  if (delayMicros < 0) {
    return const Lateness(
      isLate: false,
      totalDelayMinutes: 0,
      delayAfterGraceMinutes: 0,
    );
  }

  final delay = Duration(microseconds: delayMicros);
  final grace = Duration(minutes: shift.gracePeriodMinutes);
  final afterGrace = delay - grace;
  final isLate = afterGrace.inMicroseconds > 0;
  return Lateness(
    isLate: isLate,
    totalDelayMinutes: _roundedUpMinutes(delay),
    delayAfterGraceMinutes: isLate ? _roundedUpMinutes(afterGrace) : 0,
  );
}

Lateness calculateLatenessFromShiftStart({
  required DateTime checkInLocal,
  required DateTime shiftStartLocal,
  required int gracePeriodMinutes,
}) {
  if (gracePeriodMinutes < 0 || gracePeriodMinutes > 240) {
    throw ArgumentError('Shift grace period is invalid.');
  }
  final delay = checkInLocal.difference(shiftStartLocal);
  if (delay.isNegative) {
    return const Lateness(
      isLate: false,
      totalDelayMinutes: 0,
      delayAfterGraceMinutes: 0,
    );
  }
  final grace = Duration(minutes: gracePeriodMinutes);
  final afterGrace = delay - grace;
  final isLate = afterGrace.inMicroseconds > 0;
  return Lateness(
    isLate: isLate,
    totalDelayMinutes: _roundedUpMinutes(delay),
    delayAfterGraceMinutes: isLate ? _roundedUpMinutes(afterGrace) : 0,
  );
}

int _roundedUpMinutes(Duration duration) =>
    (duration.inMicroseconds + _microsecondsPerMinute - 1) ~/
    _microsecondsPerMinute;
