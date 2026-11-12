let csrfToken = "";

const elements = {
  form: document.querySelector("#manager-login-form"),
  managerId: document.querySelector("#manager-id"),
  password: document.querySelector("#manager-password"),
  loginButton: document.querySelector("#manager-login-button"),
  dashboard: document.querySelector("#manager-dashboard"),
  heading: document.querySelector("#manager-heading"),
  requests: document.querySelector("#manager-requests"),
  refresh: document.querySelector("#manager-refresh"),
  signOut: document.querySelector("#manager-sign-out"),
  notice: document.querySelector("#manager-notice"),
};

async function api(path, options = {}, retryCsrf = true) {
  const headers = { ...options.headers };
  if (options.body) headers["Content-Type"] = "application/json";
  if (options.method && options.method !== "GET") headers["X-CSRFToken"] = csrfToken;
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
    const error = new Error(body.error || "The request could not be completed.");
    error.status = response.status;
    throw error;
  }
  return body;
}

async function renewCsrfToken() {
  const response = await api("/api/csrf-token");
  csrfToken = response.csrfToken;
}

function showNotice(message, kind = "info") {
  elements.notice.textContent = message;
  elements.notice.className = `notice ${kind}`;
}

function showLogin() {
  elements.form.classList.remove("hidden");
  elements.dashboard.classList.add("hidden");
  elements.signOut.classList.add("hidden");
  elements.heading.textContent = "";
}

function showDashboard(managerId) {
  elements.form.classList.add("hidden");
  elements.dashboard.classList.remove("hidden");
  elements.signOut.classList.remove("hidden");
  elements.heading.textContent = `Signed in as ${managerId}`;
}

function addText(parent, tag, text, className) {
  const element = document.createElement(tag);
  element.textContent = text;
  if (className) element.className = className;
  parent.append(element);
  return element;
}

function renderRequests(requests) {
  elements.requests.replaceChildren();
  if (requests.length === 0) {
    addText(elements.requests, "p", "No exception requests have been submitted.", "empty-state");
    return;
  }
  for (const item of requests) {
    const card = document.createElement("article");
    card.className = "card request-card";
    const title = `${item.employeeId} · ${item.action} · ${item.attendanceDate}`;
    addText(card, "h3", title);
    addText(
      card,
      "p",
      `Requested ${new Date(item.requestedAt).toLocaleString()} · shift ${item.shift.start}–${item.shift.end}`,
      "request-meta",
    );
    addText(card, "p", item.reason, "request-reason");
    if (!item.employeeActive) {
      addText(card, "p", "Employee account is inactive.", "notice error");
    }

    if (item.status === "pending") {
      const noteLabel = document.createElement("label");
      noteLabel.textContent = "Decision note (optional)";
      const note = document.createElement("textarea");
      note.maxLength = 500;
      noteLabel.append(note);
      card.append(noteLabel);
      const actions = document.createElement("div");
      actions.className = "request-actions";
      for (const decision of ["approved", "rejected"]) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = decision === "approved" ? "primary-button" : "secondary-button";
        button.textContent = decision === "approved" ? "Approve attendance" : "Reject request";
        button.disabled = decision === "approved" && !item.employeeActive;
        button.addEventListener("click", () => decideRequest(item.requestId, decision, note.value, button));
        actions.append(button);
      }
      card.append(actions);
    } else {
      addText(
        card,
        "p",
        `${item.status === "approved" ? "Approved" : "Rejected"} by ${item.managerId} at ${new Date(item.decidedAt).toLocaleString()}`,
        "request-meta",
      );
      if (item.decisionNote) addText(card, "p", `Decision note: ${item.decisionNote}`);
    }
    elements.requests.append(card);
  }
}

async function loadRequests() {
  elements.refresh.disabled = true;
  try {
    const result = await api("/api/manager/requests");
    renderRequests(result.requests);
  } finally {
    elements.refresh.disabled = false;
  }
}

async function decideRequest(requestId, decision, note, button) {
  button.disabled = true;
  try {
    const result = await api(`/api/manager/requests/${requestId}/decision`, {
      method: "POST",
      body: JSON.stringify({ decision, note }),
    });
    showNotice(result.message, "success");
    await loadRequests();
  } catch (error) {
    showNotice(error.message, "error");
  } finally {
    button.disabled = false;
  }
}

async function signIn(event) {
  event.preventDefault();
  elements.loginButton.disabled = true;
  try {
    const result = await api("/api/manager/auth/login", {
      method: "POST",
      body: JSON.stringify({
        managerId: elements.managerId.value.trim(),
        password: elements.password.value,
      }),
    });
    elements.password.value = "";
    await renewCsrfToken();
    showDashboard(result.managerId);
    await loadRequests();
    showNotice("Manager sign-in successful.", "success");
  } catch (error) {
    showNotice(error.message, "error");
  } finally {
    elements.loginButton.disabled = false;
  }
}

async function signOut() {
  try {
    await api("/api/manager/auth/logout", { method: "POST" });
    await renewCsrfToken();
    showLogin();
    showNotice("Signed out.", "info");
  } catch (error) {
    showNotice(error.message, "error");
  }
}

elements.form.addEventListener("submit", signIn);
elements.refresh.addEventListener("click", () => loadRequests().catch((error) => showNotice(error.message, "error")));
elements.signOut.addEventListener("click", signOut);

async function initialize() {
  try {
    await renewCsrfToken();
    const result = await api("/api/manager/requests");
    showDashboard("Manager");
    renderRequests(result.requests);
  } catch (error) {
    showLogin();
    if (error.status !== 401) showNotice(error.message, "error");
  }
}

initialize();
