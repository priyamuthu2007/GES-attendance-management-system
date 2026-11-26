import posixpath
import re
import zipfile
import xml.etree.ElementTree as ET


MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS = {"m": MAIN_NS}
ROW_TAG = f"{{{MAIN_NS}}}row"
SHARED_ITEM_TAG = f"{{{MAIN_NS}}}si"


def _column(reference):
    match = re.match(r"[A-Z]+", reference)
    if not match:
        raise ValueError(f"Invalid spreadsheet cell reference: {reference}")
    return match.group(0)


def _shared_strings(archive, required_indices):
    if not required_indices:
        return {}
    if "xl/sharedStrings.xml" not in archive.namelist():
        raise ValueError("The workbook is missing its shared string table.")

    values = {}
    with archive.open("xl/sharedStrings.xml") as source:
        index = 0
        for _, item in ET.iterparse(source, events=("end",)):
            if item.tag != SHARED_ITEM_TAG:
                continue
            if index in required_indices:
                values[index] = "".join(
                    text.text or "" for text in item.findall(".//m:t", NS)
                )
            index += 1
            item.clear()
            if len(values) == len(required_indices):
                break
    if len(values) != len(required_indices):
        raise ValueError("The workbook contains an invalid shared string reference.")
    return values


def _cell_value(cell, shared_strings):
    value = cell.find("m:v", NS)
    raw = value.text if value is not None else ""
    if cell.attrib.get("t") == "s":
        return shared_strings[int(raw)]
    if cell.attrib.get("t") == "inlineStr":
        inline = cell.find("m:is", NS)
        if inline is None:
            return ""
        return "".join(text.text or "" for text in inline.findall(".//m:t", NS))
    return raw


def read_employee_roster(path):
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as error:
        raise ValueError("Provide a readable .xlsx employee roster.") from error

    with archive:
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        relationships = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
        targets = {relation.attrib["Id"]: relation.attrib["Target"] for relation in relationships}
        sheets = workbook.findall("m:sheets/m:sheet", NS)
        if not sheets:
            raise ValueError("The workbook has no worksheets.")

        relationship_id = sheets[0].attrib[f"{{{REL_NS}}}id"]
        target = targets.get(relationship_id)
        if not target:
            raise ValueError("The first worksheet could not be located.")
        sheet_path = (
            target.lstrip("/")
            if target.startswith("/")
            else posixpath.normpath(posixpath.join("xl", target))
        )

        with archive.open(sheet_path) as source:
            first_row = next(
                (element for _, element in ET.iterparse(source, events=("end",)) if element.tag == ROW_TAG),
                None,
            )
        if first_row is None:
            raise ValueError("The first worksheet is empty.")

        raw_headers = {}
        header_string_indices = set()
        for cell in first_row.findall("m:c", NS):
            column = _column(cell.attrib["r"])
            if cell.attrib.get("t") == "s":
                index = int(cell.find("m:v", NS).text)
                raw_headers[column] = ("shared", index)
                header_string_indices.add(index)
            else:
                raw_headers[column] = ("value", _cell_value(cell, {}))
        header_strings = _shared_strings(archive, header_string_indices)
        headers = {}
        for column, (kind, raw) in raw_headers.items():
            value = header_strings[raw] if kind == "shared" else raw
            headers[column] = value.strip().upper()

        required_columns = {
            header: column
            for column, header in headers.items()
            if header in {"ID", "SITE"}
        }
        if set(required_columns) != {"ID", "SITE"}:
            raise ValueError("The workbook must include ID and SITE columns.")
        selected_columns = set(required_columns.values())

        raw_rows = []
        required_string_indices = set()
        with archive.open(sheet_path) as source:
            first = True
            for _, row in ET.iterparse(source, events=("end",)):
                if row.tag != ROW_TAG:
                    continue
                if first:
                    first = False
                    row.clear()
                    continue
                record = {}
                for cell in row.findall("m:c", NS):
                    column = _column(cell.attrib["r"])
                    if column not in selected_columns:
                        continue
                    if cell.attrib.get("t") == "s":
                        index = int(cell.find("m:v", NS).text)
                        record[column] = ("shared", index)
                        required_string_indices.add(index)
                    else:
                        record[column] = ("value", _cell_value(cell, {}))
                if record:
                    raw_rows.append(record)
                row.clear()

        strings = _shared_strings(archive, required_string_indices)
        roster = []
        seen_ids = set()
        for record in raw_rows:
            employee_id = record.get(required_columns["ID"])
            site = record.get(required_columns["SITE"])
            employee_id = (
                strings[employee_id[1]]
                if employee_id and employee_id[0] == "shared"
                else employee_id[1] if employee_id else ""
            ).strip()
            site = (
                strings[site[1]]
                if site and site[0] == "shared"
                else site[1] if site else ""
            ).strip()
            if not employee_id and not site:
                continue
            if not employee_id or not site:
                raise ValueError("Every employee roster row needs both an ID and a SITE.")
            if employee_id in seen_ids:
                raise ValueError(f"Duplicate employee ID in roster: {employee_id}.")
            seen_ids.add(employee_id)
            roster.append({"employee_id": employee_id, "site": site})

    if not roster:
        raise ValueError("The workbook contains no employee records.")
    return roster
