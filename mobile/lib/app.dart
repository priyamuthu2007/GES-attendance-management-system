import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timezone/timezone.dart' as tz;

import 'data/attendance_repository.dart';
import 'domain/attendance_event.dart';
import 'domain/attendance_rules.dart';
import 'domain/attendance_session.dart';
import 'domain/geofence.dart';
import 'domain/location_provider.dart';
import 'domain/pin_credentials.dart';
import 'services/attendance_workflow.dart';

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({
    required this.repository,
    required this.locationProvider,
    required this.workflow,
    super.key,
  });

  final AttendanceRepository repository;
  final LocationProvider locationProvider;
  final AttendanceWorkflow workflow;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GES Offline Attendance',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176c62)),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: FutureBuilder<LocalProfile?>(
        future: repository.loadProfile(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _StartupError(message: snapshot.error.toString());
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final profile = snapshot.data;
          if (profile == null) {
            return SetupPage(
              repository: repository,
              locationProvider: locationProvider,
              workflow: workflow,
            );
          }
          return FutureBuilder<bool>(
            future: repository.hasAdministratorPin(),
            builder: (context, adminSnapshot) {
              if (adminSnapshot.hasError) {
                return _StartupError(message: adminSnapshot.error.toString());
              }
              if (adminSnapshot.connectionState != ConnectionState.done) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              if (adminSnapshot.data != true) {
                return AdministratorEnrollmentPage(
                  profile: profile,
                  repository: repository,
                  locationProvider: locationProvider,
                  workflow: workflow,
                );
              }
              return AttendancePage(
                profile: profile,
                repository: repository,
                locationProvider: locationProvider,
                workflow: workflow,
              );
            },
          );
        },
      ),
    );
  }
}

class SetupPage extends StatefulWidget {
  const SetupPage({
    required this.repository,
    required this.locationProvider,
    required this.workflow,
    this.existingProfile,
    this.administratorPin,
    super.key,
  });

  final AttendanceRepository repository;
  final LocationProvider locationProvider;
  final AttendanceWorkflow workflow;
  final LocalProfile? existingProfile;
  final String? administratorPin;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _plantName = TextEditingController(text: 'Wastewater Treatment Plant');
  final _latitude = TextEditingController();
  final _longitude = TextEditingController();
  final _radius = TextEditingController(text: '50');
  final _maxAccuracy = TextEditingController(text: '25');
  final _timezone = TextEditingController(text: 'Asia/Kolkata');
  final _employeeId = TextEditingController();
  final _employeeName = TextEditingController();
  final _employeePin = TextEditingController();
  final _employeePinConfirmation = TextEditingController();
  final _administratorPin = TextEditingController();
  final _administratorPinConfirmation = TextEditingController();
  String _shiftName = 'Morning';
  final _shiftStart = TextEditingController(text: '06:00');
  final _shiftEnd = TextEditingController(text: '14:00');
  final _grace = TextEditingController(text: '5');
  final _checkInWindow = TextEditingController(text: '120');
  final Set<int> _shiftDays = {1, 2, 3, 4, 5};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final profile = widget.existingProfile;
    if (profile == null) return;
    _plantName.text = profile.plant.name;
    _latitude.text = profile.plant.latitude.toString();
    _longitude.text = profile.plant.longitude.toString();
    _radius.text = profile.plant.radiusMeters.toString();
    _maxAccuracy.text = profile.plant.maxAccuracyMeters.toString();
    _timezone.text = profile.plant.timezoneId;
    _employeeId.text = profile.employee.employeeId;
    _employeeName.text = profile.employee.name;
    _shiftName = profile.employee.shift.name;
    _shiftStart.text =
        '${profile.employee.shift.startHour.toString().padLeft(2, '0')}:'
        '${profile.employee.shift.startMinute.toString().padLeft(2, '0')}';
    _shiftEnd.text =
        '${profile.employee.shift.endHour.toString().padLeft(2, '0')}:'
        '${profile.employee.shift.endMinute.toString().padLeft(2, '0')}';
    _grace.text = profile.employee.shift.gracePeriodMinutes.toString();
    _checkInWindow.text = profile.employee.shift.checkInWindowMinutes
        .toString();
    _shiftDays
      ..clear()
      ..addAll(profile.employee.shiftDays);
  }

  @override
  void dispose() {
    _plantName.dispose();
    _latitude.dispose();
    _longitude.dispose();
    _radius.dispose();
    _maxAccuracy.dispose();
    _timezone.dispose();
    _employeeId.dispose();
    _employeeName.dispose();
    _employeePin.dispose();
    _employeePinConfirmation.dispose();
    _administratorPin.dispose();
    _administratorPinConfirmation.dispose();
    _shiftStart.dispose();
    _shiftEnd.dispose();
    _grace.dispose();
    _checkInWindow.dispose();
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;

  String? _coordinate(String? value, double minimum, double maximum) {
    if (_required(value) != null) return 'Required';
    final number = double.tryParse(value!.trim());
    if (number == null ||
        !number.isFinite ||
        number < minimum ||
        number > maximum) {
      return 'Enter a value between $minimum and $maximum';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_shiftDays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one shift day.')),
      );
      return;
    }
    final timeParts = _shiftStart.text.split(':');
    final hour = int.tryParse(timeParts[0]);
    final minute = timeParts.length == 2 ? int.tryParse(timeParts[1]) : null;
    if (hour == null || minute == null || hour > 23 || minute > 59) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter shift start as HH:MM, for example 09:00.'),
        ),
      );
      return;
    }
    final endParts = _shiftEnd.text.split(':');
    final endHour = int.tryParse(endParts[0]);
    final endMinute = endParts.length == 2 ? int.tryParse(endParts[1]) : null;
    if (endHour == null ||
        endMinute == null ||
        endHour > 23 ||
        endMinute > 59) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter shift end as HH:MM, for example 17:00.'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final profile = LocalProfile(
        plant: PlantConfiguration(
          name: _plantName.text.trim(),
          latitude: double.parse(_latitude.text),
          longitude: double.parse(_longitude.text),
          radiusMeters: double.parse(_radius.text),
          maxAccuracyMeters: double.parse(_maxAccuracy.text),
          timezoneId: _timezone.text.trim(),
        ),
        employee: EmployeeProfile(
          employeeId: _employeeId.text.trim(),
          name: _employeeName.text.trim(),
          shift: Shift(
            name: _shiftName,
            startHour: hour,
            startMinute: minute,
            endHour: endHour,
            endMinute: endMinute,
            gracePeriodMinutes: int.parse(_grace.text),
            checkInWindowMinutes: int.parse(_checkInWindow.text),
          ),
          shiftDays: _shiftDays,
        ),
      );
      final pinCredential = _employeePin.text.isEmpty
          ? null
          : await PinCredential.create(_employeePin.text);
      final administratorCredential = widget.existingProfile == null
          ? await PinCredential.create(_administratorPin.text)
          : null;
      await widget.repository.saveProfile(
        plant: profile.plant,
        employee: profile.employee,
        pinCredential: pinCredential,
        administratorCredential: administratorCredential,
        administratorPin: widget.administratorPin,
      );
      if (mounted) {
        if (widget.existingProfile != null) {
          Navigator.of(context).pop(profile);
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => AttendancePage(
                profile: profile,
                repository: widget.repository,
                locationProvider: widget.locationProvider,
                workflow: widget.workflow,
              ),
            ),
          );
        }
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Setup could not be saved: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existingProfile == null
              ? 'Set up this phone'
              : 'Edit device settings',
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Device setup',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              widget.existingProfile == null
                  ? 'Configure the plant pin, employee, and separate administrator PIN. '
                        'Records stay encrypted on this device.'
                  : 'Update the plant pin, employee, or shift. Leave the employee PIN blank to keep it unchanged.',
            ),
            const SizedBox(height: 20),
            _sectionTitle('Plant geofence'),
            _field(
              _plantName,
              'Plant name',
              validator: _required,
              maxLength: 160,
            ),
            Row(
              children: [
                Expanded(
                  child: _field(
                    _latitude,
                    'Latitude',
                    keyboard: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    validator: (value) => _coordinate(value, -90, 90),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _field(
                    _longitude,
                    'Longitude',
                    keyboard: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    validator: (value) => _coordinate(value, -180, 180),
                  ),
                ),
              ],
            ),
            _field(
              _radius,
              'Radius in metres',
              keyboard: const TextInputType.numberWithOptions(decimal: true),
              validator: (value) => _coordinate(value, 1, 1000),
            ),
            _field(
              _maxAccuracy,
              'Maximum GPS accuracy (metres)',
              keyboard: const TextInputType.numberWithOptions(decimal: true),
              validator: (value) => _coordinate(value, 1, 100),
            ),
            _field(
              _timezone,
              'Plant timezone (IANA, e.g. Asia/Kolkata)',
              validator: (value) {
                if (_required(value) != null) return 'Required';
                try {
                  tz.getLocation(value!.trim());
                  return null;
                } on ArgumentError {
                  return 'Enter a valid IANA timezone';
                }
              },
            ),
            const Text(
              'The default is 50 m. Attendance requires GPS uncertainty to fit '
              'inside the configured radius.',
            ),
            const SizedBox(height: 20),
            _sectionTitle('Employee and assigned shift'),
            DropdownButtonFormField<String>(
              initialValue: _shiftName,
              decoration: const InputDecoration(labelText: 'Assigned shift'),
              items: [
                for (final name in {'Morning', 'Evening', 'Night', _shiftName})
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _shiftName = value;
                  switch (value) {
                    case 'Morning':
                      _shiftStart.text = '06:00';
                      _shiftEnd.text = '14:00';
                      break;
                    case 'Evening':
                      _shiftStart.text = '14:00';
                      _shiftEnd.text = '22:00';
                      break;
                    case 'Night':
                      _shiftStart.text = '22:00';
                      _shiftEnd.text = '06:00';
                      break;
                  }
                });
              },
            ),
            _field(
              _employeeId,
              'Employee ID',
              validator: (value) {
                if (value == null ||
                    !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(value.trim())) {
                  return 'Use 1–64 letters, numbers, dot, underscore or hyphen';
                }
                return null;
              },
              maxLength: 64,
            ),
            _field(
              _employeeName,
              'Employee name',
              validator: _required,
              maxLength: 160,
            ),
            _field(
              _employeePin,
              'Employee PIN (6 digits)',
              keyboard: TextInputType.number,
              validator: (value) {
                if (widget.existingProfile != null &&
                    (value == null || value.isEmpty)) {
                  return null;
                }
                return value == null || !RegExp(r'^\d{6}$').hasMatch(value)
                    ? 'Enter exactly 6 digits'
                    : null;
              },
              maxLength: 6,
              obscureText: true,
            ),
            _field(
              _employeePinConfirmation,
              'Confirm employee PIN',
              keyboard: TextInputType.number,
              validator: (value) {
                if (widget.existingProfile != null &&
                    _employeePin.text.isEmpty &&
                    (value == null || value.isEmpty)) {
                  return null;
                }
                return value != _employeePin.text ? 'PINs do not match' : null;
              },
              maxLength: 6,
              obscureText: true,
            ),
            if (widget.existingProfile == null) ...[
              const SizedBox(height: 8),
              _sectionTitle('Administrator PIN'),
              const Text(
                'This is separate from the employee PIN. Keep it with the office supervisor.',
              ),
              _field(
                _administratorPin,
                'Administrator PIN (6 digits)',
                keyboard: TextInputType.number,
                validator: (value) =>
                    value == null || !RegExp(r'^\d{6}$').hasMatch(value)
                    ? 'Enter exactly 6 digits'
                    : null,
                maxLength: 6,
                obscureText: true,
              ),
              _field(
                _administratorPinConfirmation,
                'Confirm administrator PIN',
                keyboard: TextInputType.number,
                validator: (value) => value != _administratorPin.text
                    ? 'PINs do not match'
                    : null,
                maxLength: 6,
                obscureText: true,
              ),
            ],
            Row(
              children: [
                Expanded(
                  child: _field(
                    _shiftStart,
                    'Shift start (HH:MM)',
                    validator: (value) {
                      if (value == null ||
                          !RegExp(
                            r'^(?:[01]\d|2[0-3]):[0-5]\d$',
                          ).hasMatch(value)) {
                        return 'Use 24-hour HH:MM';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _field(
                    _shiftEnd,
                    'Shift end (HH:MM)',
                    validator: (value) {
                      if (value == null ||
                          !RegExp(
                            r'^(?:[01]\d|2[0-3]):[0-5]\d$',
                          ).hasMatch(value)) {
                        return 'Use 24-hour HH:MM';
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: _field(
                    _grace,
                    'Grace period (minutes)',
                    keyboard: TextInputType.number,
                    validator: (value) {
                      final minutes = int.tryParse(value ?? '');
                      return minutes == null || minutes < 0 || minutes > 240
                          ? 'Enter 0–240'
                          : null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _field(
                    _checkInWindow,
                    'Check-in window (min)',
                    keyboard: TextInputType.number,
                    validator: (value) {
                      final minutes = int.tryParse(value ?? '');
                      return minutes == null || minutes < 1 || minutes > 360
                          ? 'Enter 1–360'
                          : null;
                    },
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 4,
              children: [
                for (var day = 1; day <= 7; day++)
                  FilterChip(
                    label: Text(_weekdayName(day)),
                    selected: _shiftDays.contains(day),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _shiftDays.add(day);
                        } else {
                          _shiftDays.remove(day);
                        }
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(
                _saving
                    ? 'Saving…'
                    : widget.existingProfile == null
                    ? 'Save device setup'
                    : 'Save changes',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboard,
    String? Function(String?)? validator,
    int? maxLength,
    bool obscureText = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      keyboardType: keyboard,
      validator: validator,
      maxLength: maxLength,
      obscureText: obscureText,
      decoration: InputDecoration(labelText: label),
    ),
  );
}

class AdministratorEnrollmentPage extends StatefulWidget {
  const AdministratorEnrollmentPage({
    required this.profile,
    required this.repository,
    required this.locationProvider,
    required this.workflow,
    super.key,
  });

  final LocalProfile profile;
  final AttendanceRepository repository;
  final LocationProvider locationProvider;
  final AttendanceWorkflow workflow;

  @override
  State<AdministratorEnrollmentPage> createState() =>
      _AdministratorEnrollmentPageState();
}

class _AdministratorEnrollmentPageState
    extends State<AdministratorEnrollmentPage> {
  final _formKey = GlobalKey<FormState>();
  final _pin = TextEditingController();
  final _confirmation = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _pin.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.repository.setAdministratorPin(
        await PinCredential.create(_pin.text),
        onlyIfMissing: true,
      );
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => AttendancePage(
              profile: widget.profile,
              repository: widget.repository,
              locationProvider: widget.locationProvider,
              workflow: widget.workflow,
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Administrator setup failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Secure this attendance device')),
    body: Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Supervisor setup required',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'This installation has no administrator PIN. An office supervisor must set one before attendance can be used.',
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: 'Administrator PIN (6 digits)',
            ),
            validator: (value) =>
                value == null || !RegExp(r'^\d{6}$').hasMatch(value)
                ? 'Enter exactly 6 digits'
                : null,
          ),
          TextFormField(
            controller: _confirmation,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: 'Confirm administrator PIN',
            ),
            validator: (value) =>
                value != _pin.text ? 'PINs do not match' : null,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Set administrator PIN'),
          ),
        ],
      ),
    ),
  );
}

class AttendancePage extends StatefulWidget {
  const AttendancePage({
    required this.profile,
    required this.repository,
    required this.locationProvider,
    required this.workflow,
    super.key,
  });

  final LocalProfile profile;
  final AttendanceRepository repository;
  final LocationProvider locationProvider;
  final AttendanceWorkflow workflow;

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage>
    with WidgetsBindingObserver {
  LocationFix? _fix;
  GeofenceResult? _locationResult;
  List<AttendanceEvent> _todayEvents = [];
  List<AttendanceEvent> _history = [];
  List<AttendanceSession> _sessions = [];
  bool _busy = true;
  bool _insideZone = false;
  bool _polling = false;
  String? _message;
  Timer? _accessTimeout;
  Timer? _pollTimer;

  tz.TZDateTime get _plantNow => tz.TZDateTime.from(
    DateTime.now().toUtc(),
    tz.getLocation(widget.profile.plant.timezoneId),
  );
  String get _todayKey => _dateKey(_plantNow);
  AttendanceEvent? get _checkIn => _eventOf(AttendanceEventType.checkIn);
  AttendanceEvent? get _checkOut => _eventOf(AttendanceEventType.checkOut);
  bool get _hasOpenCheckIn => _checkIn != null && _checkOut == null;
  bool get _complete => _checkOut != null;
  AttendanceSession? get _currentSession {
    for (final session in _sessions) {
      if (session.status == AttendanceSessionStatus.present) return session;
    }
    for (final session in _sessions) {
      if (session.shiftDate == _todayKey) return session;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pollTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_pollAndLoad()),
    );
    unawaited(_pollAndLoad());
    unawaited(_refreshLocation());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accessTimeout?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_pollAndLoad());
      unawaited(_refreshLocation());
    } else {
      _accessTimeout?.cancel();
      if (_insideZone && mounted) {
        setState(() {
          _insideZone = false;
          _fix = null;
          _locationResult = null;
          _message = 'Check your location again to unlock attendance.';
        });
      }
    }
  }

  AttendanceEvent? _eventOf(AttendanceEventType type) {
    for (final event in _todayEvents) {
      if (event.type == type) return event;
    }
    return null;
  }

  Future<void> _loadAttendance() async {
    final sessions = await widget.repository.pollAttendance(
      widget.profile,
      DateTime.now().toUtc(),
    );
    final employeeId = widget.profile.employee.employeeId;
    final currentSession =
        sessions
            .where(
              (session) => session.status == AttendanceSessionStatus.present,
            )
            .firstOrNull ??
        sessions.where((session) => session.shiftDate == _todayKey).firstOrNull;
    final today = await widget.repository.eventsForDate(
      employeeId,
      currentSession?.shiftDate ?? _todayKey,
    );
    final history = await widget.repository.recentEvents(employeeId);
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _todayEvents = today;
        _history = history;
      });
    }
  }

  Future<void> _pollAndLoad() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      await _loadAttendance();
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _message =
              'Offline shift polling failed: '
              '${error.toString().replaceFirst('Bad state: ', '')}',
        );
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _refreshLocation() async {
    _accessTimeout?.cancel();
    setState(() {
      _busy = true;
      _insideZone = false;
      _message = null;
      _fix = null;
      _locationResult = null;
    });
    try {
      final fix = await widget.locationProvider.getFreshFix();
      final plant = widget.profile.plant;
      final result = verifyLocation(
        fence: PlantFence(
          latitude: plant.latitude,
          longitude: plant.longitude,
          radiusMeters: plant.radiusMeters,
          maxAccuracyMeters: plant.maxAccuracyMeters,
        ),
        fix: fix,
        now: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _fix = fix;
        _locationResult = result;
        _insideZone = result.accepted;
        _message = result.accepted
            ? 'Attendance unlocked for 30 seconds.'
            : result.reason;
      });
      if (result.accepted) {
        _accessTimeout = Timer(const Duration(seconds: 30), () {
          if (!mounted) return;
          setState(() {
            _insideZone = false;
            _fix = null;
            _locationResult = null;
            _message = 'Location access expired. Check your location again.';
          });
        });
        await _loadAttendance();
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _insideZone = false;
          _message = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _requestPin() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirm employee PIN'),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            onSubmitted: (pin) => Navigator.of(context).pop(pin),
            decoration: const InputDecoration(labelText: '6-digit PIN'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _record(AttendanceEventType type) async {
    final pin = await _requestPin();
    if (pin == null || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final event = await widget.workflow.record(
        profile: widget.profile,
        type: type,
        pin: pin,
      );
      await _loadAttendance();
      if (!mounted) return;
      setState(() {
        _fix = LocationFix(
          latitude: event.latitude,
          longitude: event.longitude,
          accuracyMeters: event.accuracyMeters,
          capturedAt: event.locationCapturedAtUtc,
        );
        _locationResult = GeofenceResult(
          accepted: true,
          distanceMeters: event.distanceMeters,
          reason: null,
        );
        _message = type == AttendanceEventType.checkIn
            ? (event.isLate
                  ? 'Check-in recorded. ${event.delayAfterGraceMinutes} min late after grace.'
                  : 'Check-in recorded. On time.')
            : 'Check-out recorded.';
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          final message = error.toString().replaceFirst('Bad state: ', '');
          final normalized = message.toLowerCase();
          if (normalized.contains('gps') ||
              normalized.contains('geofence') ||
              normalized.contains('location') ||
              normalized.contains('local attendance date')) {
            _insideZone = false;
            _accessTimeout?.cancel();
          }
          _message = message;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAdministratorTools() async {
    try {
      final administratorPin = await _requestAdministratorPin();
      if (administratorPin == null || !mounted) return;
      await widget.repository.verifyAdministratorPin(administratorPin);
      if (!mounted) return;
      final updatedProfile = await Navigator.of(context).push<LocalProfile>(
        MaterialPageRoute<LocalProfile>(
          builder: (_) => AdminToolsPage(
            profile: widget.profile,
            repository: widget.repository,
            locationProvider: widget.locationProvider,
            workflow: widget.workflow,
            administratorPin: administratorPin,
          ),
        ),
      );
      if (updatedProfile != null && mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => AttendancePage(
              profile: updatedProfile,
              repository: widget.repository,
              locationProvider: widget.locationProvider,
              workflow: widget.workflow,
            ),
          ),
        );
      } else if (mounted) {
        await _pollAndLoad();
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Administrator access failed: '
              '${error.toString().replaceFirst('Bad state: ', '')}',
            ),
          ),
        );
      }
    }
  }

  Future<String?> _requestAdministratorPin() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Administrator access'),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            onSubmitted: (pin) => Navigator.of(context).pop(pin),
            decoration: const InputDecoration(labelText: '6-digit admin PIN'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Unlock'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final employee = widget.profile.employee;
    final shift = employee.shift;
    final shiftText =
        '${shift.startHour.toString().padLeft(2, '0')}:'
        '${shift.startMinute.toString().padLeft(2, '0')}';
    final actionType = _hasOpenCheckIn
        ? AttendanceEventType.checkOut
        : AttendanceEventType.checkIn;
    final currentSession = _currentSession;
    final shiftAssignedToday =
        currentSession != null &&
        currentSession.status != AttendanceSessionStatus.absent;
    final checkInWindowOpen =
        currentSession != null &&
        currentSession.status == AttendanceSessionStatus.scheduled &&
        !DateTime.now().toUtc().isBefore(currentSession.startUtc) &&
        !DateTime.now().toUtc().isAfter(currentSession.checkInDeadlineUtc);
    final currentMonthSessions = _sessions.where((session) {
      final date = session.shiftDate;
      return date.startsWith(
        '${_plantNow.year.toString().padLeft(4, '0')}-'
        '${_plantNow.month.toString().padLeft(2, '0')}',
      );
    });
    final absentCount = currentMonthSessions
        .where((session) => session.status == AttendanceSessionStatus.absent)
        .length;
    final attendedCount = currentMonthSessions
        .where(
          (session) =>
              session.status == AttendanceSessionStatus.present ||
              session.status == AttendanceSessionStatus.completed ||
              session.status == AttendanceSessionStatus.incomplete,
        )
        .length;
    final checkoutWindowOpen =
        actionType == AttendanceEventType.checkOut &&
        currentSession?.status == AttendanceSessionStatus.present &&
        !DateTime.now().toUtc().isAfter(
          currentSession!.endUtc.add(const Duration(hours: 6)),
        );
    return Scaffold(
      appBar: AppBar(
        title: const Text('GES Offline Attendance'),
        actions: [
          IconButton(
            tooltip: 'Administrator tools',
            onPressed: _openAdministratorTools,
            icon: const Icon(Icons.admin_panel_settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshLocation,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (!_insideZone) ...[
              const SizedBox(height: 80),
              Icon(
                _busy ? Icons.location_searching : Icons.location_off,
                size: 72,
              ),
              const SizedBox(height: 16),
              Text(
                _busy ? 'Checking your location…' : 'Attendance is locked',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                _message ??
                    'Allow location access. The app unlocks only when a fresh, '
                        'accurate GPS fix confirms you are inside '
                        '${widget.profile.plant.radiusMeters.toStringAsFixed(0)} m '
                        'of ${widget.profile.plant.name}.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy ? null : _refreshLocation,
                icon: const Icon(Icons.my_location),
                label: Text(_busy ? 'Checking location…' : 'Check location'),
              ),
            ] else ...[
              Text(
                'Hello, ${employee.name}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text('Employee ID: ${employee.employeeId}'),
              const SizedBox(height: 18),
              _infoCard(
                context,
                title: 'Assigned shift',
                body:
                    '${shift.name} · $shiftText–'
                    '${shift.endHour.toString().padLeft(2, '0')}:'
                    '${shift.endMinute.toString().padLeft(2, '0')} · '
                    '${shift.gracePeriodMinutes} min grace',
                icon: Icons.schedule,
              ),
              _infoCard(
                context,
                title: 'Offline shift polling',
                body:
                    '${_sessions.length} scheduled sessions tracked · '
                    '$attendedCount attended · $absentCount absent this month',
                icon: Icons.sync,
              ),
              if (currentSession != null)
                _infoCard(
                  context,
                  title: 'Current shift session',
                  body:
                      '${currentSession.shiftName} · ${currentSession.shiftDate} · '
                      '${_sessionStatusLabel(currentSession.status)}',
                  icon: Icons.event_available,
                ),
              _infoCard(
                context,
                title: widget.profile.plant.name,
                body:
                    '${widget.profile.plant.latitude}, ${widget.profile.plant.longitude} · '
                    '${widget.profile.plant.radiusMeters.toStringAsFixed(0)} m radius',
                icon: Icons.location_on_outlined,
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Location check',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _fix == null
                            ? 'A fresh GPS fix is requested when this page opens, resumes, or you try to record attendance.'
                            : '${_fix!.latitude.toStringAsFixed(6)}, ${_fix!.longitude.toStringAsFixed(6)} · '
                                  'distance ${_locationResult?.distanceMeters?.toStringAsFixed(1) ?? '—'} m · '
                                  'accuracy ±${_fix!.accuracyMeters.toStringAsFixed(1)} m',
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _refreshLocation,
                        icon: const Icon(Icons.my_location),
                        label: const Text('Get fresh GPS fix'),
                      ),
                    ],
                  ),
                ),
              ),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Your PIN confirms access to this employee profile, not your '
                    'physical identity. GPS and device time can be spoofed.',
                  ),
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _message!,
                    style: TextStyle(
                      color: _locationResult?.accepted == false
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
                ),
              FilledButton.icon(
                onPressed:
                    _busy ||
                        _complete ||
                        (actionType == AttendanceEventType.checkOut &&
                            !checkoutWindowOpen) ||
                        (actionType == AttendanceEventType.checkIn &&
                            (!shiftAssignedToday || !checkInWindowOpen))
                    ? null
                    : () => _record(actionType),
                icon: Icon(
                  actionType == AttendanceEventType.checkIn
                      ? Icons.login
                      : Icons.logout,
                ),
                label: Text(
                  _complete
                      ? 'Attendance complete'
                      : actionType == AttendanceEventType.checkOut &&
                            !checkoutWindowOpen
                      ? 'Check-out window expired'
                      : actionType == AttendanceEventType.checkIn &&
                            !shiftAssignedToday
                      ? currentSession?.status == AttendanceSessionStatus.absent
                            ? 'Check-in window closed'
                            : 'Waiting for shift window'
                      : actionType == AttendanceEventType.checkIn &&
                            !checkInWindowOpen
                      ? 'Check-in opens at $shiftText'
                      : actionType == AttendanceEventType.checkIn
                      ? 'Check in'
                      : 'Check out',
                ),
              ),
              const SizedBox(height: 20),
              Text('Today', style: Theme.of(context).textTheme.titleLarge),
              if (_todayEvents.isEmpty)
                const ListTile(title: Text('No attendance recorded today.'))
              else
                for (final event in _todayEvents) _eventTile(context, event),
              const SizedBox(height: 12),
              Text(
                'Recent attendance',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (_history.isEmpty)
                const ListTile(title: Text('No local attendance history yet.'))
              else
                for (final event in _history) _eventTile(context, event),
              const SizedBox(height: 12),
              Text(
                'Daily and monthly report',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final session in _sessions.take(10))
                ListTile(
                  dense: true,
                  title: Text('${session.shiftDate} · ${session.shiftName}'),
                  trailing: Text(_sessionStatusLabel(session.status)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoCard(
    BuildContext context, {
    required String title,
    required String body,
    required IconData icon,
  }) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(body),
    ),
  );

  Widget _eventTile(BuildContext context, AttendanceEvent event) {
    final time = tz.TZDateTime.from(
      event.timestampUtc,
      tz.getLocation(event.timezoneId),
    ).toString();
    final eventName = event.type == AttendanceEventType.checkIn
        ? 'Check-in'
        : 'Check-out';
    final attendanceDetails = event.isLate
        ? 'Late: ${event.totalDelayMinutes} min total, '
              '${event.delayAfterGraceMinutes} min after grace'
        : 'On time';
    final verificationDetails =
        event.verificationMethod == AttendanceVerificationMethod.employeePin
        ? 'PIN self-attested'
        : 'Biometric verification';
    final details =
        '${event.shiftName} · $attendanceDetails · $verificationDetails · GPS ±'
        '${event.accuracyMeters.toStringAsFixed(1)} m';
    return ListTile(
      title: Text('$eventName · ${time.substring(0, 16)}'),
      subtitle: Text(details),
      leading: Icon(
        event.isLate
            ? Icons.warning_amber
            : event.verificationMethod ==
                  AttendanceVerificationMethod.employeePin
            ? Icons.person_outline
            : Icons.verified_outlined,
        color: event.isLate ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}

class AdminToolsPage extends StatelessWidget {
  const AdminToolsPage({
    required this.profile,
    required this.repository,
    required this.locationProvider,
    required this.workflow,
    required this.administratorPin,
    super.key,
  });

  final LocalProfile profile;
  final AttendanceRepository repository;
  final LocationProvider locationProvider;
  final AttendanceWorkflow workflow;
  final String administratorPin;

  Future<String?> _requestPassphrase(
    BuildContext context, {
    required bool confirm,
  }) async {
    final controller = TextEditingController();
    final confirmation = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) {
          var error = '';
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(
                confirm ? 'Encrypt attendance backup' : 'Unlock backup',
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Use a unique passphrase of at least 12 characters when restoring this file. Longer is better; the app does not store it.',
                  ),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Backup passphrase',
                    ),
                  ),
                  if (confirm)
                    TextField(
                      controller: confirmation,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm passphrase',
                      ),
                    ),
                  if (error.isNotEmpty)
                    Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (controller.text.trim().length < 12) {
                      setDialogState(
                        () => error = 'Use at least 12 non-space characters.',
                      );
                    } else if (confirm &&
                        controller.text != confirmation.text) {
                      setDialogState(() => error = 'Passphrases do not match.');
                    } else {
                      Navigator.of(context).pop(controller.text);
                    }
                  },
                  child: Text(confirm ? 'Create backup' : 'Import backup'),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      controller.dispose();
      confirmation.dispose();
    }
  }

  Future<void> _exportBackup(BuildContext context) async {
    final passphrase = await _requestPassphrase(context, confirm: true);
    if (passphrase == null || !context.mounted) return;
    File? file;
    try {
      final bytes = await repository.exportAttendanceBackup(
        administratorPin: administratorPin,
        passphrase: passphrase,
        deviceId: workflow.deviceId,
      );
      final directory = await getTemporaryDirectory();
      final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
      file = File(
        '${directory.path}${Platform.pathSeparator}ges-attendance-$timestamp.gesbackup',
      );
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Encrypted GES attendance backup',
          text:
              'Encrypted attendance records. Share the passphrase separately.',
        ),
      );
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Backup export failed: $error')));
      }
    } finally {
      final exportedFile = file;
      if (exportedFile != null) {
        try {
          if (await exportedFile.exists()) await exportedFile.delete();
        } on Object catch (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Temporary backup cleanup failed: $error'),
              ),
            );
          }
        }
      }
    }
  }

  Future<void> _importBackup(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['gesbackup'],
        withData: true,
      );
      if (result == null || !context.mounted) return;
      final bytes = result.files.single.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('The selected backup file could not be read.');
      }
      final passphrase = await _requestPassphrase(context, confirm: false);
      if (passphrase == null || !context.mounted) return;
      final summary = await repository.importAttendanceBackup(
        bytes: bytes,
        administratorPin: administratorPin,
        passphrase: passphrase,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${summary.addedEvents} events and '
            '${summary.addedSessions} sessions; skipped '
            '${summary.duplicateEvents + summary.duplicateSessions} exact duplicates.',
          ),
        ),
      );
      Navigator.of(context).pop(profile);
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Backup was not imported; existing records were not overwritten. '
              'Check the passphrase, file, and office: $error',
            ),
          ),
        );
      }
    }
  }

  Future<void> _changeAdministratorPin(BuildContext context) async {
    final oldPin = TextEditingController();
    final newPin = TextEditingController();
    final confirmation = TextEditingController();
    try {
      final values = await showDialog<List<String>>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Change administrator PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (controller, label) in [
                (oldPin, 'Current admin PIN'),
                (newPin, 'New 6-digit admin PIN'),
                (confirmation, 'Confirm new admin PIN'),
              ])
                TextField(
                  controller: controller,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: InputDecoration(labelText: label),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                context,
              ).pop([oldPin.text, newPin.text, confirmation.text]),
              child: const Text('Change PIN'),
            ),
          ],
        ),
      );
      if (values == null || !context.mounted) return;
      if (!RegExp(r'^\d{6}$').hasMatch(values[1]) || values[1] != values[2]) {
        throw StateError('New administrator PINs must match and be 6 digits.');
      }
      await repository.verifyAdministratorPin(values[0]);
      await repository.setAdministratorPin(
        await PinCredential.create(values[1]),
        currentPin: values[0],
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Administrator PIN changed.')),
        );
      }
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Administrator PIN was not changed: $error')),
        );
      }
    } finally {
      oldPin.dispose();
      newPin.dispose();
      confirmation.dispose();
    }
  }

  Future<void> _editSetup(BuildContext context) async {
    final updatedProfile = await Navigator.of(context).push<LocalProfile>(
      MaterialPageRoute<LocalProfile>(
        builder: (_) => SetupPage(
          repository: repository,
          locationProvider: locationProvider,
          workflow: workflow,
          existingProfile: profile,
          administratorPin: administratorPin,
        ),
      ),
    );
    if (updatedProfile != null && context.mounted) {
      Navigator.of(context).pop(updatedProfile);
    }
  }

  Future<void> _showConsolidatedRecords(BuildContext context) async {
    final events = await repository.allEvents(
      administratorPin: administratorPin,
    );
    final sessions = await repository.allSessions(
      administratorPin: administratorPin,
    );
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            ConsolidatedRecordsPage(events: events, sessions: sessions),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Administrator tools')),
    body: ListView(
      children: [
        const ListTile(
          title: Text('Offline data handling'),
          subtitle: Text(
            'Backups contain attendance events and shift sessions, not employee or administrator PINs.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.settings),
          title: const Text('Edit device setup'),
          onTap: () => _editSetup(context),
        ),
        ListTile(
          leading: const Icon(Icons.backup_outlined),
          title: const Text('Export encrypted backup'),
          subtitle: const Text('Share the file and passphrase separately.'),
          onTap: () => _exportBackup(context),
        ),
        ListTile(
          leading: const Icon(Icons.file_open_outlined),
          title: const Text('Import backup'),
          subtitle: const Text(
            'Merge records for the same office; conflicts stop the import.',
          ),
          onTap: () => _importBackup(context),
        ),
        ListTile(
          leading: const Icon(Icons.table_view_outlined),
          title: const Text('View consolidated records'),
          onTap: () => _showConsolidatedRecords(context),
        ),
        ListTile(
          leading: const Icon(Icons.password),
          title: const Text('Change administrator PIN'),
          onTap: () => _changeAdministratorPin(context),
        ),
      ],
    ),
  );
}

class ConsolidatedRecordsPage extends StatelessWidget {
  const ConsolidatedRecordsPage({
    required this.events,
    required this.sessions,
    super.key,
  });

  final List<AttendanceEvent> events;
  final List<AttendanceSession> sessions;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Consolidated attendance')),
    body: ListView(
      children: [
        ListTile(
          title: Text('${events.length} attendance events'),
          subtitle: Text('${sessions.length} shift sessions'),
        ),
        for (final event in events)
          ListTile(
            title: Text(
              '${event.employeeId} · ${event.type == AttendanceEventType.checkIn ? 'Check-in' : 'Check-out'}',
            ),
            subtitle: Text(
              '${event.attendanceDate} · ${event.timestampUtc.toIso8601String()} · ${event.shiftName}',
            ),
          ),
        for (final session in sessions)
          ListTile(
            title: Text('${session.employeeId} · ${session.shiftDate}'),
            subtitle: Text(
              '${session.shiftName} · ${_sessionStatusLabel(session.status)}',
            ),
          ),
      ],
    ),
  );
}

String _sessionStatusLabel(AttendanceSessionStatus status) => switch (status) {
  AttendanceSessionStatus.scheduled => 'Scheduled',
  AttendanceSessionStatus.present => 'Present',
  AttendanceSessionStatus.completed => 'Completed',
  AttendanceSessionStatus.absent => 'Absent',
  AttendanceSessionStatus.incomplete => 'Check-out missing',
};

class _StartupError extends StatelessWidget {
  const _StartupError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Text('Could not open encrypted attendance storage: $message'),
    ),
  );
}

String _weekdayName(int weekday) =>
    const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][weekday - 1];

String _dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
