# GES Attendance for Android and iOS

The Flutter app connects employee phones to the shared Flask/PostgreSQL
attendance service. The server remains the source of truth for employee
accounts, assigned offices, attendance timestamps, and geofence validation.
The app does not connect to PostgreSQL directly and does not store employee
passwords.

## Features

- Employee sign-in with the same employee ID and password used by the web app.
- Securely stored Flask session cookie using Android Keystore / Apple Keychain.
- CSRF token retrieval for state-changing API requests.
- Today's assigned sites, shift information, and check-in/check-out times.
- Fresh foreground GPS location collected only when the employee requests
  check-in or check-out.
- Check-in and check-out requests validated by the Flask server against the
  employee's assigned sites. Attendance timestamps are assigned by the server.
- Session and password are cleared from app memory when signing out. The
  server session cookie is cleared from secure storage on successful sign-out
  or when the server rejects the session.

The previous on-device/offline implementation remains in the source tree for
reference but is no longer launched by `main.dart`. Its locally stored
attendance records are not automatically imported into the central database.

## Requirements and launch

Install Flutter, Android SDK, and (for iOS builds) macOS with Xcode. From this
directory:

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

On the sign-in screen, enter the HTTPS address of the deployed attendance
server, then enter the employee credentials. The app requires an HTTPS URL
reachable from the phone; `127.0.0.1` on a phone refers to the phone itself.
For local development, use a secured HTTPS address reachable over the
organization's private VPN rather than exposing the Flask development server
or PostgreSQL to the public internet.

## Backend API

The app uses the existing endpoints:

- `POST /api/auth/login`
- `GET /api/attendance/today`
- `POST /api/attendance/check-in`
- `POST /api/attendance/check-out`
- `POST /api/auth/logout`
- `GET /api/csrf-token`

The Flutter client preserves the Flask session cookie and uses the server's
CSRF token on each state-changing request. Use a valid TLS certificate; the app
does not disable certificate checks or accept plain HTTP.

## Location and operational notes

Location permission is needed only for check-in/check-out. GPS can be
unavailable or inaccurate indoors; the server rejects fixes outside its
configured accuracy and assigned-office fence. The app needs network/VPN
access when recording attendance; it does not queue attendance for later
offline synchronization.

Test with an employee account and a real supported phone at each assigned
office before rollout. Android and iOS builds are separate platform targets;
iOS compilation requires macOS and Xcode. The existing browser attendance
report remains available to authorized administrators through the web app.
