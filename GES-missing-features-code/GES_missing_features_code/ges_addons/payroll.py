import csv, io
from datetime import date
from flask import Blueprint, request, Response, jsonify
from .db import get_db
from .roles import roles_required
from .audit import log_action

bp=Blueprint("addon_payroll",__name__)

@bp.get("/api/reports/attendance.csv")
@roles_required("admin","hr","auditor")
def export_csv():
    start,end=request.args.get("start_date"),request.args.get("end_date")
    try:
        date.fromisoformat(start or ""); date.fromisoformat(end or "")
    except ValueError:
        return jsonify(error="Provide start_date and end_date as YYYY-MM-DD"),400
    db=get_db()
    try:
        rows=db.execute("""SELECT employee_id,date,check_in,check_out,status
          FROM attendance WHERE date BETWEEN ? AND ? ORDER BY date,employee_id""",(start,end)).fetchall()
    except Exception:
        db.close()
        return jsonify(error="Adjust SQL to match your existing attendance table/column names"),500
    db.close()
    out=io.StringIO(); w=csv.writer(out)
    w.writerow(["employee_id","date","check_in","check_out","status"])
    for r in rows: w.writerow([r[k] for k in r.keys()])
    log_action("attendance_csv_export","attendance",None,{"from":start,"to":end,"rows":len(rows)})
    return Response(out.getvalue(),mimetype="text/csv",
      headers={"Content-Disposition":"attachment; filename=attendance_report.csv"})
