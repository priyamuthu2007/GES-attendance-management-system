import tempfile
import unittest
import zipfile
from pathlib import Path

from attendance.roster import read_employee_roster


class RosterReaderTests(unittest.TestCase):
    def test_reads_only_employee_ids_and_sites_from_xlsx(self):
        workbook_xml = """\
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
 <sheets><sheet name="Employees" sheetId="1" r:id="rId1"/></sheets>
</workbook>"""
        relationships_xml = """\
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>"""
        shared_strings_xml = """\
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
 <si><t>NAME</t></si><si><t>SITE</t></si><si><t>ID</t></si>
 <si><t>Password</t></si><si><t>Employee Name</t></si>
 <si><t>HO,KPL</t></si><si><t>EMPLOYEE-003</t></si>
 <si><t>private-test-value</t></si>
</sst>"""
        sheet_xml = """\
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
 <sheetData>
  <row r="1">
   <c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c>
   <c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c>
  </row>
  <row r="2">
   <c r="A2" t="s"><v>4</v></c><c r="B2" t="s"><v>5</v></c>
   <c r="C2" t="s"><v>6</v></c><c r="D2" t="s"><v>7</v></c>
  </row>
 </sheetData>
</worksheet>"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "roster.xlsx"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("xl/workbook.xml", workbook_xml)
                archive.writestr("xl/_rels/workbook.xml.rels", relationships_xml)
                archive.writestr("xl/sharedStrings.xml", shared_strings_xml)
                archive.writestr("xl/worksheets/sheet1.xml", sheet_xml)

            roster = read_employee_roster(path)

        self.assertEqual(
            roster,
            [{"employee_id": "EMPLOYEE-003", "site": "HO,KPL"}],
        )
        self.assertNotIn("password", roster[0])


if __name__ == "__main__":
    unittest.main()
