const ATTENDANCE_RADIUS_METERS = 10;
const MAX_GPS_ACCURACY_METERS = 5;
const TARGET_GPS_ACCURACY_METERS = 5;
const LOCATION_SAMPLE_WINDOW_MS = 30000;

const state = {
  csrfToken: "",
  employeeId: "",
  employeeRole: "",
  timeZone: "Asia/Kolkata",
  offices: [],
  attendance: null,
  employeeEmail: "",
  timeZone: "Asia/Kolkata",
  offices: [],
  attendance: null,
  exceptionRequest: null,
  shift: null,
  position: null,
  busy: false,
};

const elements = {
  loginForm: document.querySelector("#login-form"),
  loginButton: document.querySelector("#login-button"),
  attendancePanel: document.querySelector("#attendance-panel"),
  attendanceReportLink: document.querySelector("#attendance-report-link"),
  signOut: document.querySelector("#sign-out"),
  pageTitle: document.querySelector("#page-title"),
  pageIntro: document.querySelector("#page-intro"),
  email: document.querySelector("#employee-email"),
  password: document.querySelector("#password"),
  signedInEmployee: document.querySelector("#signed-in-employee"),
  avatar: document.querySelector("#avatar"),
  shiftInfo: document.querySelector("#shift-info"),
  locationCoordinates: document.querySelector("#location-coordinates"),
  locationPanel: document.querySelector("#location-panel"),
  locationHeading: document.querySelector("#location-heading"),
  locationDetail: document.querySelector("#location-detail"),
  rangeBadge: document.querySelector("#range-badge"),
  officeList: document.querySelector("#office-list"),
  refreshLocation: document.querySelector("#refresh-location"),
  attendanceStatus: document.querySelector("#attendance-status"),
  attendanceAction: document.querySelector("#attendance-action"),
  exceptionReason: document.querySelector("#exception-reason"),
  exceptionSubmit: document.querySelector("#exception-submit"),
  exceptionStatus: document.querySelector("#exception-status"),
  refreshAttendance: document.querySelector("#refresh-attendance"),
  notice: document.querySelector("#notice"),
};

async function api(path, options = {}, retryCsrf = true) {
  const headers = { ...options.headers };
  if (options.body) headers["Content-Type"] = "application/json";
  if (options.method && options.method !== "GET") {
    headers["X-CSRFToken"] = state.csrfToken;
  }
  const response = await fetch(path, {
    ...options,
    headers,
    credentials: "same-origin",
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (
      retryCsrf &&
      response.status === 400 &&
      body.error === "Security token expired. Refresh the page and try again."
    ) {
      await renewCsrfToken();
      return api(path, options, false);
    }
    if (response.status === 401 && path !== "/api/auth/login") {
      showLogin();
    }
    throw new Error(body.error || "The request could not be completed.");
  }
  return body;
}

async function renewCsrfToken() {
  const result = await api("/api/csrf-token");
  state.csrfToken = result.csrfToken;
}

function showNotice(message, kind = "info") {
  elements.notice.textContent = message;
  elements.notice.className = `notice ${kind}`;
}

function clearNotice() {
  elements.notice.textContent = "";
  elements.notice.className = "notice hidden";
}

function showLogin() {
  state.employeeId = "";
<<<<<<< HEAD
  state.employeeRole = "";
  state.attendance = null;
=======
  state.employeeEmail = "";
  state.attendance = null;
  state.exceptionRequest = null;
  state.shift = null;
>>>>>>> 834d82c7b6f03dad2b2020a1e4e4b56ad3503891
  state.position = null;
  elements.loginForm.classList.remove("hidden");
  elements.attendancePanel.classList.add("hidden");
  elements.signOut.classList.add("hidden");
  elements.attendanceReportLink.classList.add("hidden");
  elements.pageTitle.textContent = "Welcome back.";
  elements.pageIntro.textContent = "Sign in with your employee account to continue.";
}

function showAttendancePage(email) {
  state.employeeEmail = email;
  elements.loginForm.classList.add("hidden");
  elements.attendancePanel.classList.remove("hidden");
  elements.signOut.classList.remove("hidden");
  elements.attendanceReportLink.classList.toggle(
    "hidden",
    !["admin", "hr", "auditor"].includes(state.employeeRole),
  );
  elements.pageTitle.textContent = "Good to see you.";
<<<<<<< HEAD
  elements.pageIntro.textContent = "Check in at your assigned office any day.";
  elements.signedInEmployee.textContent = employeeId;
  elements.avatar.textContent = employeeId.charAt(0).toUpperCase();
=======
  elements.pageIntro.textContent = "Confirm your shift and location to record attendance.";
  elements.signedInEmployee.textContent = email;
  elements.avatar.textContent = email.charAt(0).toUpperCase();
>>>>>>> 834d82c7b6f03dad2b2020a1e4e4b56ad3503891
}

function nearestOffice(position) {
  if (!position || state.offices.length === 0) return null;
  return state.offices
    .map((office) => ({
      ...office,
      distanceMeters: haversineMeters(
        position.latitude,
        position.longitude,
        office.latitude,
        office.longitude,
      ),
    }))
    .sort((first, second) => first.distanceMeters - second.distanceMeters)[0];
}

function withinRange(position) {
  const nearest = nearestOffice(position);
  return Boolean(
    nearest &&
      position.accuracy <= MAX_GPS_ACCURACY_METERS &&
      nearest.distanceMeters + position.accuracy <= ATTENDANCE_RADIUS_METERS,
  );
}

function updateLocationPanel() {
  const nearest = nearestOffice(state.position);
  const inRange = withinRange(state.position);
  elements.locationPanel.classList.toggle("in-range", inRange);
  elements.locationPanel.classList.toggle("out-range", Boolean(state.position) && !inRange);

  if (!state.position) {
    elements.locationHeading.textContent = "Checking your location";
    elements.locationDetail.textContent = "Allow location access to continue.";
    elements.locationCoordinates.textContent = "Location permission is needed.";
    elements.rangeBadge.className = "range-badge hidden";
    return;
  }

  elements.locationCoordinates.textContent =
    `GPS fix ±${Math.round(state.position.accuracy)} m accuracy`;
  elements.locationDetail.textContent =
    `${Math.round(nearest.distanceMeters)} m from ${nearest.name} · GPS accuracy ±${Math.round(state.position.accuracy)} m`;

  if (state.position.accuracy > MAX_GPS_ACCURACY_METERS) {
    elements.locationHeading.textContent = "GPS accuracy is too low";
    elements.rangeBadge.textContent = "LOW ACCURACY";
    elements.rangeBadge.className = "range-badge bad";
  } else if (inRange) {
    elements.locationHeading.textContent = `Within range of ${nearest.name}`;
    elements.rangeBadge.textContent = "IN RANGE";
    elements.rangeBadge.className = "range-badge good";
  } else {
    elements.locationHeading.textContent = "Outside the check-in zone";
    elements.rangeBadge.textContent = "OUT OF RANGE";
    elements.rangeBadge.className = "range-badge bad";
  }
}

function renderAttendance() {
  const attendance = state.attendance;
  const hasOpenCheckIn = Boolean(attendance && !attendance.checkOutAt);
  const checkedOut = Boolean(attendance?.checkOutAt);
  elements.attendanceStatus.classList.toggle("hidden", !attendance);
  if (attendance) {
    const checkInTime = formatTime(attendance.checkInAt);
    const checkInSource =
      attendance.checkInSource === "manual_approval" ? " · manually approved" : "";
    const checkoutLine = attendance.checkOutAt
      ? `<br>Check-out: ${escapeHtml(formatTime(attendance.checkOutAt))} · ${escapeHtml(attendance.checkOutOffice)}${attendance.checkOutSource === "manual_approval" ? " · manually approved" : ""}`
      : "<br>Check-out has not been recorded.";
    elements.attendanceStatus.innerHTML =
      `<strong>Check-in: ${escapeHtml(checkInTime)} · ${escapeHtml(attendance.checkInOffice)}${checkInSource}</strong>${checkoutLine}`;
    if (checkedOut) {
      elements.attendanceAction.textContent = "Attendance completed for today";
    } else {
      elements.attendanceAction.textContent = "Mark check-out";
    }
  } else {
    elements.attendanceAction.textContent = "Mark check-in";
  }

  elements.attendanceAction.dataset.action = hasOpenCheckIn ? "check-out" : "check-in";
  const canCheckIn = Boolean(state.shift);
  elements.attendanceAction.disabled =
    state.busy ||
    checkedOut ||
    (!hasOpenCheckIn && !canCheckIn) ||
    !state.position ||
    !withinRange(state.position);
  elements.attendanceAction.setAttribute(
    "aria-label",
    hasOpenCheckIn ? "Mark check-out" : "Mark check-in",
  );
  elements.refreshLocation.disabled = state.busy;
  renderExceptionRequest();
}

function renderExceptionRequest() {
  const attendance = state.attendance;
  const hasOpenCheckIn = Boolean(attendance && !attendance.checkOutAt);
  const completed = Boolean(attendance?.checkOutAt);
  const canRequest = Boolean(state.shift || hasOpenCheckIn);
  const pending = Boolean(state.exceptionRequest);
  elements.exceptionSubmit.disabled = state.busy || pending || completed || !canRequest;
  elements.exceptionReason.disabled = state.busy || pending || completed || !canRequest;
  elements.exceptionStatus.classList.toggle("hidden", !pending);
  if (pending) {
    elements.exceptionStatus.textContent =
      `Pending manager review for ${state.exceptionRequest.action}. Your request has not yet changed attendance.`;
  } else {
    elements.exceptionStatus.textContent = "";
  }
  elements.refreshAttendance.disabled = state.busy;
}

async function getCurrentLocation() {
  if (!navigator.geolocation) {
    throw new Error("This browser does not support GPS location.");
  }
  return new Promise((resolve, reject) => {
<<<<<<< HEAD
    let bestPosition = null;
    let lastError = null;
    let watchId = null;
    let settled = false;
    const timeoutId = window.setTimeout(() => {
      if (bestPosition) {
        finish(resolve, bestPosition);
      } else {
        finish(
          reject,
          new Error(
            lastError
              ? locationErrorMessage(lastError)
              : "GPS location timed out. Move near a window and try again.",
          ),
        );
      }
    }, LOCATION_SAMPLE_WINDOW_MS);

    function finish(callback, value) {
      if (settled) return;
      settled = true;
      window.clearTimeout(timeoutId);
      if (watchId !== null) navigator.geolocation.clearWatch(watchId);
      callback(value);
    }

    try {
      watchId = navigator.geolocation.watchPosition(
        ({ coords }) => {
          const position = {
            latitude: coords.latitude,
            longitude: coords.longitude,
            accuracy: coords.accuracy,
          };
          if (
            !Number.isFinite(position.latitude) ||
            !Number.isFinite(position.longitude) ||
            !Number.isFinite(position.accuracy) ||
            position.accuracy < 0
          ) {
            return;
          }
          if (!bestPosition || position.accuracy < bestPosition.accuracy) {
            bestPosition = position;
          }
          if (bestPosition.accuracy <= TARGET_GPS_ACCURACY_METERS) {
            finish(resolve, bestPosition);
          }
        },
        (error) => {
          if (error.code === 1) {
            finish(
              reject,
              new Error(
                "Location permission was denied. Allow access in browser settings and try again.",
              ),
            );
          } else {
            lastError = error;
          }
        },
        {
          enableHighAccuracy: true,
          timeout: LOCATION_SAMPLE_WINDOW_MS + 1000,
          maximumAge: 0,
        },
      );
    } catch (error) {
      finish(
        reject,
        new Error(
          error.message || "Could not determine your location. Check device location services and try again.",
        ),
      );
    }
=======
    navigator.geolocation.getCurrentPosition(
      ({ coords }) =>
        resolve({
          latitude: coords.latitude,
          longitude: coords.longitude,
          accuracy: coords.accuracy,
        }),
      (error) => {
        const message =
          error.code === 1
            ? "Location permission was denied. Allow access in browser settings and try again."
            : error.code === 3
              ? "GPS location timed out. Move near a window and try again."
              : "Could not determine your location. Check device location services and try again.";
        reject(new Error(message));
      },
      { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 },
    );
>>>>>>> 834d82c7b6f03dad2b2020a1e4e4b56ad3503891
  });
}

function locationErrorMessage(error) {
  if (error.code === 1) {
    return "Location permission was denied. Allow access in browser settings and try again.";
  }
  if (error.code === 3) {
    return "GPS location timed out. Move near a window and try again.";
  }
  return "Could not determine your location. Check device location services and try again.";
}

async function refreshLocation() {
  state.position = null;
  updateLocationPanel();
  renderAttendance();
  showNotice("Collecting fresh GPS readings for up to 30 seconds. Move near a window for best accuracy.");
  try {
    state.position = await getCurrentLocation();
    updateLocationPanel();
    renderAttendance();
    clearNotice();
  } catch (error) {
    state.position = null;
    updateLocationPanel();
    renderAttendance();
    showNotice(error.message, "error");
  }
}

async function loadAttendance() {
  const employee = await api("/api/auth/session");
  state.employeeRole = employee.role;
  const result = await api("/api/attendance/today");
  state.employeeId = result.employeeId;
  state.employeeEmail = result.employeeEmail;
  state.timeZone = result.timeZone;
  state.attendance = result.attendance;
  state.exceptionRequest = result.exceptionRequest;
  state.offices = result.offices;
<<<<<<< HEAD
  elements.shiftInfo.textContent = "Check in any day at your assigned office, regardless of shift hours.";
  elements.officeList.textContent = state.offices.length
    ? state.offices.map((office) => office.name).join(" or ")
    : "No office assigned. Contact your administrator.";
  showAttendancePage(result.employeeId);
=======
  elements.shiftInfo.textContent = state.shift
    ? `${state.shift.start} – ${state.shift.end}`
    : "No shift assigned today. Contact your administrator.";
  elements.officeList.textContent = state.offices.map((office) => office.name).join(" or ");
  showAttendancePage(result.employeeEmail);
>>>>>>> 834d82c7b6f03dad2b2020a1e4e4b56ad3503891
  renderAttendance();
}

async function submitExceptionRequest() {
  if (state.busy) return;
  state.busy = true;
  renderAttendance();
  clearNotice();
  try {
    const result = await api("/api/attendance/exception-requests", {
      method: "POST",
      body: JSON.stringify({ reason: elements.exceptionReason.value }),
    });
    state.exceptionRequest = result.request;
    elements.exceptionReason.value = "";
    renderAttendance();
    showNotice(result.message, "success");
  } catch (error) {
    showNotice(error.message, "error");
  } finally {
    state.busy = false;
    renderAttendance();
  }
}

async function refreshAttendance() {
  try {
    await loadAttendance();
    showNotice("Attendance status refreshed.", "success");
  } catch (error) {
    showNotice(error.message, "error");
  }
}

async function signIn(event) {
  event.preventDefault();
  clearNotice();
  elements.loginButton.disabled = true;
  elements.loginButton.textContent = "Signing in…";
  try {
    await api("/api/auth/login", {
      method: "POST",
      body: JSON.stringify({
        email: elements.email.value.trim(),
        password: elements.password.value,
      }),
    });
    elements.password.value = "";
    await renewCsrfToken();
    await loadAttendance();
    void refreshLocation();
  } catch (error) {
    showNotice(error.message, "error");
  } finally {
    elements.loginButton.disabled = false;
    elements.loginButton.textContent = "Sign in";
  }
}

async function submitAttendance() {
  if (state.busy) return;
  state.busy = true;
  renderAttendance();
  clearNotice();
  showNotice("Collecting fresh GPS readings for up to 30 seconds…");
  try {
    const position = await getCurrentLocation();
    state.position = position;
    updateLocationPanel();
    if (position.accuracy > MAX_GPS_ACCURACY_METERS) {
      throw new Error("GPS accuracy is too low to verify attendance. Refresh your location and try again.");
    }
    if (!withinRange(position)) {
      throw new Error(`Your location is outside the confirmed ${ATTENDANCE_RADIUS_METERS} metre attendance area.`);
    }
    const action = elements.attendanceAction.dataset.action;
    const result = await api(`/api/attendance/${action}`, {
      method: "POST",
      body: JSON.stringify({
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
      }),
    });
    state.attendance = result.attendance;
    clearNotice();
    showNotice(result.message, "success");
  } catch (error) {
    showNotice(error.message, "error");
  } finally {
    state.busy = false;
    renderAttendance();
  }
}

async function signOut() {
  try {
    await api("/api/auth/logout", { method: "POST" });
    await renewCsrfToken();
    clearNotice();
    showLogin();
  } catch (error) {
    showNotice(error.message, "error");
  }
}

function haversineMeters(lat1, lon1, lat2, lon2) {
  const radians = (degrees) => (degrees * Math.PI) / 180;
  const latDelta = radians(lat2 - lat1);
  const lonDelta = radians(lon2 - lon1);
  const a =
    Math.sin(latDelta / 2) ** 2 +
    Math.cos(radians(lat1)) * Math.cos(radians(lat2)) * Math.sin(lonDelta / 2) ** 2;
  return 12_742_000 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function formatTime(value) {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: state.timeZone,
  })
    .format(new Date(value));
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[character]);
}

elements.loginForm.addEventListener("submit", signIn);
elements.signOut.addEventListener("click", signOut);
elements.refreshLocation.addEventListener("click", refreshLocation);
elements.attendanceAction.addEventListener("click", submitAttendance);
elements.exceptionSubmit.addEventListener("click", submitExceptionRequest);
elements.refreshAttendance.addEventListener("click", refreshAttendance);

async function initialize() {
  try {
    await renewCsrfToken();
    await loadAttendance();
    if (!state.attendance?.checkOutAt) void refreshLocation();
  } catch (error) {
    if (!error.message.includes("Please sign in")) {
      showNotice(error.message, "error");
    }
  }
}

initialize();
