const form = document.querySelector("#report-form");
const dateInput = document.querySelector("#report-date");
const reportRows = document.querySelector("#report-rows");
const reportMessage = document.querySelector("#report-message");
const csvExport = document.querySelector("#csv-export");

function showMessage(message, kind = "info") {
  reportMessage.textContent = message;
  reportMessage.className = `notice ${kind}`;
}

function clearMessage() {
  reportMessage.textContent = "";
  reportMessage.className = "notice hidden";
}

function displayTime(value, timeZone) {
  if (!value) return "—";
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone,
  }).format(new Date(value));
}

function addCell(row, value) {
  const cell = document.createElement("td");
  cell.textContent = value || "—";
  row.append(cell);
}

function renderRows(employees, timeZone) {
  reportRows.replaceChildren();
  if (employees.length === 0) {
    const row = reportRows.insertRow();
    const cell = row.insertCell();
    cell.colSpan = 6;
    cell.textContent = "No active employees found.";
    return;
  }

  for (const employee of employees) {
    const row = reportRows.insertRow();
    addCell(row, employee.employeeId);
    addCell(row, employee.fullName);
    addCell(
      row,
      employee.flexibleShift
        ? "Flexible (all days)"
        : employee.shiftStart && employee.shiftEnd
          ? `${employee.shiftStart}–${employee.shiftEnd}`
          : "Not configured",
    );
    addCell(row, displayTime(employee.checkInAt, timeZone));
    addCell(row, displayTime(employee.checkOutAt, timeZone));
    addCell(
      row,
      {
        not_checked_in: "Not checked in",
        checked_in: "Checked in",
        complete: "Complete",
      }[employee.status] || "Unknown",
    );
  }
}

async function loadReport(dateValue = "") {
  clearMessage();
  reportRows.replaceChildren();
  const loadingRow = reportRows.insertRow();
  const loadingCell = loadingRow.insertCell();
  loadingCell.colSpan = 6;
  loadingCell.textContent = "Loading attendance…";

  const query = dateValue ? `?date=${encodeURIComponent(dateValue)}` : "";
  try {
    const response = await fetch(`/api/attendance/report${query}`, {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
    const result = await response.json();
    if (!response.ok) {
      throw new Error(result.error || "Could not load attendance.");
    }

    dateInput.value = result.date;
    csvExport.href = `/api/reports/attendance.csv?start_date=${result.date}&end_date=${result.date}`;
    renderRows(result.employees, result.timeZone);
  } catch (error) {
    reportRows.replaceChildren();
    showMessage(error.message, "error");
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  loadReport(dateInput.value);
});

loadReport();
