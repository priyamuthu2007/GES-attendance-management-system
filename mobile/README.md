# GES Offline Attendance Mobile App

This is a separate Flutter app for offline-first attendance. It keeps the
PDF's GPS, shift, lateness, and local-registration workflow, but uses PIN-based
self-check-in instead of its biometric requirement. Each phone stores
employee setup and attendance in an AES-GCM-encrypted `attendance.json` file.
It makes no server or internet request for attendance.

## Current functionality

- First-run setup for the treatment-plant pin, geofence, employee, assigned
  shift, working days, grace period, employee PIN, and separate administrator
  PIN. A supervisor must perform first-time device enrollment.
- Administrator tools are protected by a separate six-digit PIN with a
  five-attempt, 15-minute lockout. They allow device setup changes, PIN changes,
  backup export/import, and review of consolidated local records. Existing
  installations without an administrator PIN require a one-time supervised
  enrollment before operational use.
- A fresh GPS fix is requested when the attendance screen opens or resumes and
  whenever the employee checks location or tries to record an attendance event.
- The attendance screen starts locked and checks GPS before displaying employee
  attendance. It unlocks for 30 seconds only when the full GPS uncertainty
  falls within the configured fence; it locks again on app background/resume
  and requires another location check. Every attendance event independently
  requests and validates a fresh GPS fix.
- The on-device shift poller creates scheduled sessions for assigned workdays,
  runs every minute while the app is open, and reconciles sessions when the app
  starts or resumes. It marks an unrecorded shift absent after its configured
  check-in window and marks a check-in without checkout as incomplete after the
  six-hour checkout window. Session and event records stay on the phone.
- The default fence radius is **50 metres**. First-run device setup allows the
  plant coordinates and radius to be entered; it must be completed by a
  trusted supervisor.
  A location is accepted only when the reported GPS uncertainty is within the
  configured accuracy limit and `distance + accuracy <= radius`.
- Shift dates, lateness, and displayed event times use the configured plant
  IANA timezone (default `Asia/Kolkata`), not the phone's selected timezone.
- Check-in and check-out use separate immutable event records. Duplicate daily
  events, invalid GPS fixes, out-of-window check-ins, and check-out without an
  open check-in are rejected before the encrypted JSON file is updated.
- Each attendance action requires the employee PIN. Only a salted PBKDF2 hash
  is stored in the encrypted file; five incorrect attempts trigger a
  15-minute lockout.
- Attendance events record that the employee PIN was confirmed, rather than
  claiming face-based identity verification.
- Check-in stores UTC time, the device timezone offset, coordinates, GPS
  accuracy, distance, shift start, grace period, and lateness totals.
- Lateness is calculated from the assigned shift start. An arrival exactly at
  the grace limit is on time; partial late minutes are rounded up.
- Morning, evening, and overnight shifts can be assigned during local device
  setup. Overnight sessions retain the date on which the shift started.
- Daily/monthly reports are computed from the device's encrypted local
  attendance sessions and events.
- The JSON encryption key is generated locally and stored using the
  platform secure-storage facility (Android Keystore-backed storage / Apple
  Keychain).
- The JSON document is encrypted on disk; its version, nonce, ciphertext, and
  authentication tag are stored as a JSON envelope. The key is not stored in
  the file. Existing SQLCipher records are imported once during upgrade.
- Admins can export all local events and shift sessions as an AES-GCM encrypted
  `.gesbackup` file. The backup passphrase is separate from the admin PIN, must
  be at least 12 characters, uses 600,000 PBKDF2-HMAC-SHA256 iterations, and is
  never stored by the app. Choose a unique, strong passphrase and keep it
  separate from the exported file.
- Import accepts backups for the same plant coordinates and timezone, merges
  new events and sessions, skips exact duplicates, and aborts without writing
  if it finds conflicting records. Backups exclude device profiles and PINs.
  Use the phone's share/file picker to transfer files; avoid cloud transfer if
  the office requires transfer to remain fully offline.
- Admins can review all imported events in the consolidated-records screen and
  export the combined data again to carry it to another device.

## Identity and operational limits

This version uses employee self-check-in with a PIN instead of face recognition.
The PIN is tied to the employee profile configured on that phone; it does not
prove that the person entering it is that employee. Assign devices to employees,
do not share PINs, and define a supervisor-reviewed exception process before
using records for payroll.

The JSON file is encrypted, and employee and administrator PINs are stored as
salted PBKDF2 hashes. Attendance remains local to each phone: there is no
central server or internet polling. Devices must be manually backed up and
consolidated by an administrator. The administrator must protect the backup
passphrase; a forgotten administrator PIN/passphrase has no server-side reset.
The shift poller runs only while the app is open; after the operating system
closes the app, missed sessions/absences are reconciled on the next launch or
resume.
Android/iOS do not guarantee continuous background execution, so exact-time
absence creation while the app is closed is not promised.
Device clocks and GPS signals remain user-controlled evidence and are not
tamper-proof. An administrator PIN protects app actions but is not a
hardware-enforced role or a defense against a rooted/jailbroken device.
Supervise first setup, retain the backup passphrase safely, define
employee-notice and retention/deletion rules, and physically test before
relying on records for payroll.

## Run and test

Install Flutter 3.47+ and the Android SDK, then from this directory run:

```powershell
flutter pub get
flutter analyze
dart run test
flutter run
```

For Android, enable location permission in the phone settings when prompted.
Test GPS at the real plant entrance with airplane mode enabled. The 50-metre
geofence still depends on the phone's reported GPS uncertainty; if the phone
cannot confirm the entire uncertainty area is inside the fence, it correctly
rejects the event. Survey the entrance and test the actual device before rollout.

iOS builds require macOS and Xcode. To consolidate devices without a server,
export each device's encrypted backup, transfer the files and passphrase
separately, and import each file on the supervisor's phone. Verify the
consolidated records before using them. Device clocks and GPS signals remain
user-controlled evidence and are not tamper-proof.
