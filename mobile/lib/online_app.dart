import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'data/mobile_attendance_api.dart';

class OnlineAttendanceApp extends StatefulWidget {
  const OnlineAttendanceApp({required this.api, super.key});

  final MobileAttendanceApi api;

  @override
  State<OnlineAttendanceApp> createState() => _OnlineAttendanceAppState();
}

class _OnlineAttendanceAppState extends State<OnlineAttendanceApp> {
  TodayAttendance? _today;
  String? _savedServerUrl;
  String? _startupError;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    widget.api.close();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    try {
      _savedServerUrl = await widget.api.loadServerUrl();
      if (_savedServerUrl != null && await widget.api.hasSavedSession()) {
        _today = await widget.api.loadToday();
      }
    } on Object catch (error) {
      _startupError = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signIn(
    String serverUrl,
    String employeeId,
    String password,
  ) async {
    await widget.api.setServerUrl(serverUrl);
    await widget.api.signIn(employeeId: employeeId, password: password);
    final today = await widget.api.loadToday();
    if (!mounted) return;
    setState(() {
      _savedServerUrl = widget.api.serverUrl;
      _today = today;
      _startupError = null;
    });
  }

  Future<void> _refresh() async {
    final today = await widget.api.loadToday();
    if (mounted) setState(() => _today = today);
  }

  Future<void> _recordAttendance({required bool checkOut}) async {
    final fix = await _getFreshPosition();
    if (checkOut) {
      await widget.api.checkOut(
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracyMeters: fix.accuracy,
      );
    } else {
      await widget.api.checkIn(
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracyMeters: fix.accuracy,
      );
    }
    await _refresh();
  }

  Future<void> _signOut() async {
    await widget.api.signOut();
    if (mounted) setState(() => _today = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GES Attendance',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176c62)),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _today == null
          ? SignInPage(
              initialServerUrl: _savedServerUrl ?? '',
              initialError: _startupError,
              onSignIn: _signIn,
            )
          : EmployeeAttendancePage(
              today: _today!,
              onRefresh: _refresh,
              onRecordAttendance: _recordAttendance,
              onSignOut: _signOut,
            ),
    );
  }
}

class SignInPage extends StatefulWidget {
  const SignInPage({
    required this.initialServerUrl,
    required this.initialError,
    required this.onSignIn,
    super.key,
  });

  final String initialServerUrl;
  final String? initialError;
  final Future<void> Function(String serverUrl, String employeeId, String password)
  onSignIn;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  late final TextEditingController _serverUrl;
  final _employeeId = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _serverUrl = TextEditingController(text: widget.initialServerUrl);
    _error = widget.initialError;
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    _employeeId.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_employeeId.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter your employee ID and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSignIn(
        _serverUrl.text,
        _employeeId.text,
        _password.text,
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.location_on, size: 52),
                  const SizedBox(height: 12),
                  Text(
                    'GES Attendance',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Sign in with the employee ID and password provided by your administrator.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _serverUrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Attendance server URL',
                      hintText: 'https://attendance.example.com',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _employeeId,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Employee ID'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: !_showPassword,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _busy ? null : _submit(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                        icon: Icon(
                          _showPassword ? Icons.visibility_off : Icons.visibility,
                        ),
                        tooltip: _showPassword ? 'Hide password' : 'Show password',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Sign in'),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Use your organization’s HTTPS server address. The server must be reachable from this phone.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class EmployeeAttendancePage extends StatefulWidget {
  const EmployeeAttendancePage({
    required this.today,
    required this.onRefresh,
    required this.onRecordAttendance,
    required this.onSignOut,
    super.key,
  });

  final TodayAttendance today;
  final Future<void> Function() onRefresh;
  final Future<void> Function({required bool checkOut}) onRecordAttendance;
  final Future<void> Function() onSignOut;

  @override
  State<EmployeeAttendancePage> createState() => _EmployeeAttendancePageState();
}

class _EmployeeAttendancePageState extends State<EmployeeAttendancePage> {
  bool _busy = false;

  bool get _hasOpenCheckIn =>
      widget.today.attendance?.checkInAt != null &&
      widget.today.attendance?.checkOutAt == null;

  bool get _isComplete => widget.today.attendance?.checkOutAt != null;

  Future<void> _performAttendance() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRecordAttendance(checkOut: _hasOpenCheckIn);
      if (mounted) {
        _showMessage(_hasOpenCheckIn ? 'Check-out recorded.' : 'Check-in recorded.');
      }
    } on Object catch (error) {
      if (mounted) _showMessage(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshWithMessage() async {
    try {
      await widget.onRefresh();
    } on Object catch (error) {
      if (mounted) _showMessage(error.toString(), isError: true);
    }
  }

  Future<void> _signOut() async {
    try {
      await widget.onSignOut();
    } on Object catch (error) {
      if (mounted) _showMessage(error.toString(), isError: true);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final attendance = widget.today.attendance;
    final title = _isComplete
        ? 'Attendance complete'
        : _hasOpenCheckIn
        ? 'Checked in'
        : 'Not checked in';
    final shift = widget.today.shift;
    final shiftLabel = shift == null
        ? 'No fixed shift'
        : shift.start == null || shift.end == null
        ? 'Flexible schedule'
        : '${shift.start} – ${shift.end}';
    final canCheckIn = widget.today.offices.isNotEmpty && !_isComplete;

    return Scaffold(
      appBar: AppBar(
        title: const Text('GES Attendance'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refreshWithMessage,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh attendance',
          ),
          IconButton(
            onPressed: _busy ? null : _signOut,
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshWithMessage,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Hello, ${widget.today.employeeId}',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text('Times shown in ${widget.today.timeZone}.'),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 12),
                    Text('Shift: $shiftLabel'),
                    if (attendance?.checkInAt != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Check-in: ${attendance!.checkInAt}'
                        '${attendance.checkInOffice == null ? '' : ' at ${attendance.checkInOffice}'}',
                      ),
                    ],
                    if (attendance?.checkOutAt != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Check-out: ${attendance!.checkOutAt}'
                        '${attendance.checkOutOffice == null ? '' : ' at ${attendance.checkOutOffice}'}',
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy || !canCheckIn
                            ? null
                            : _performAttendance,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                _hasOpenCheckIn
                                    ? Icons.logout
                                    : Icons.login,
                              ),
                        label: Text(
                          _busy
                              ? 'Checking location…'
                              : _isComplete
                              ? 'Done for today'
                              : _hasOpenCheckIn
                              ? 'Check out'
                              : 'Check in',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Your location is requested only when you check in or out. The server verifies that you are at an assigned site.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('Your assigned sites', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (widget.today.offices.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('No site is assigned to this account.'),
                  subtitle: Text('Contact your administrator.'),
                ),
              )
            else
              for (final office in widget.today.offices)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.business_outlined),
                    title: Text(office.name),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

Future<Position> _getFreshPosition() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw StateError('Turn on device location services and try again.');
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw StateError('Location permission is required for attendance.');
  }
  return Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.best,
      timeLimit: Duration(seconds: 20),
    ),
  );
}
