#!/usr/bin/env python3
"""Write Pearson and Spearman replicate-correlation TSV matrices to one XLSX.

The implementation uses only the Python standard library so it works in the
existing OpDetect environment without adding another dependency.
"""
from __future__ import annotations

import argparse
import csv
import math
import re
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr


def column_name(index: int) -> str:
    result = ""
    value = index
    while value:
        value, remainder = divmod(value - 1, 26)
        result = chr(65 + remainder) + result
    return result


def safe_sheet_name(value: str) -> str:
    value = re.sub(r"[\\/*?:\[\]]", " ", value).strip()
    return (value or "Correlation")[:31]


def parse_cell(value: str) -> tuple[str, object]:
    text = value.strip()
    if not text:
        return "blank", ""
    try:
        number = float(text)
    except ValueError:
        return "text", value
    if math.isfinite(number):
        return "number", number
    return "text", value


def cell_xml(reference: str, value: str, style: int = 0, force_text: bool = False) -> str:
    kind, parsed = ("text", value) if force_text and value != "" else parse_cell(value)
    style_attr = f' s="{style}"' if style else ""
    if kind == "blank":
        return f'<c r="{reference}"{style_attr}/>'
    if kind == "number":
        return f'<c r="{reference}"{style_attr}><v>{parsed}</v></c>'
    preserve = ' xml:space="preserve"' if value != value.strip() else ""
    return f'<c r="{reference}" t="inlineStr"{style_attr}><is><t{preserve}>{escape(value)}</t></is></c>'


def read_matrix(path: Path) -> list[list[str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.reader(handle, delimiter="\t"))
    if len(rows) < 2 or len(rows[0]) < 2:
        raise ValueError(f"Correlation matrix is empty or malformed: {path}")
    width = max(len(row) for row in rows)
    return [row + [""] * (width - len(row)) for row in rows]


def worksheet_xml(rows: list[list[str]]) -> str:
    width_count = max(len(row) for row in rows)
    widths: list[int] = []
    for col in range(width_count):
        maximum = max(len(str(row[col])) for row in rows)
        widths.append(max(12, min(30, maximum + 3)))
    last_cell = f"{column_name(width_count)}{len(rows)}"
    parts = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
        f'<dimension ref="A1:{last_cell}"/>',
        '<sheetViews><sheetView workbookViewId="0"><pane xSplit="1" ySplit="1" topLeftCell="B2" activePane="bottomRight" state="frozen"/></sheetView></sheetViews>',
        '<sheetFormatPr defaultRowHeight="18"/>',
        '<cols>',
    ]
    for index, width in enumerate(widths, start=1):
        parts.append(f'<col min="{index}" max="{index}" width="{width}" customWidth="1"/>')
    parts.extend(['</cols>', '<sheetData>'])
    for row_index, row in enumerate(rows, start=1):
        parts.append(f'<row r="{row_index}" ht="22" customHeight="1">')
        for col_index, value in enumerate(row, start=1):
            ref = f"{column_name(col_index)}{row_index}"
            style = 1 if row_index == 1 or col_index == 1 else 2
            parts.append(cell_xml(ref, value, style=style, force_text=(row_index == 1 or col_index == 1)))
        parts.append('</row>')
    parts.extend([
        '</sheetData>',
        '<pageMargins left="0.3" right="0.3" top="0.5" bottom="0.5" header="0.2" footer="0.2"/>',
        '</worksheet>',
    ])
    return ''.join(parts)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--pearson', required=True, type=Path)
    parser.add_argument('--spearman', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()

    sheets = [
        ('Pearson correlation', read_matrix(args.pearson)),
        ('Spearman correlation', read_matrix(args.spearman)),
    ]

    styles_xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="2">
    <font><sz val="10"/><name val="Calibri"/><family val="2"/></font>
    <font><b/><color rgb="FFFFFFFF"/><sz val="10"/><name val="Calibri"/><family val="2"/></font>
  </fonts>
  <fills count="4">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF4472C4"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFEAF2F8"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="2">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    <border><left style="thin"><color rgb="FFDCE5DF"/></left><right style="thin"><color rgb="FFDCE5DF"/></right><top style="thin"><color rgb="FFDCE5DF"/></top><bottom style="thin"><color rgb="FFDCE5DF"/></bottom><diagonal/></border>
  </borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="3">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="2" fontId="0" fillId="3" borderId="1" xfId="0" applyNumberFormat="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
  </cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>'''

    sheet_entries = []
    workbook_rel_entries = []
    content_overrides = []
    for index, (name, _) in enumerate(sheets, start=1):
        sheet_entries.append(f'<sheet name={quoteattr(safe_sheet_name(name))} sheetId="{index}" r:id="rId{index}"/>')
        workbook_rel_entries.append(f'<Relationship Id="rId{index}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{index}.xml"/>')
        content_overrides.append(f'<Override PartName="/xl/worksheets/sheet{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>')
    styles_rel_id = len(sheets) + 1
    workbook_rel_entries.append(f'<Relationship Id="rId{styles_rel_id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>')

    workbook_xml = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>{''.join(sheet_entries)}</sheets>
</workbook>'''
    workbook_rels = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{''.join(workbook_rel_entries)}</Relationships>'''
    root_rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>'''
    content_types = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  {''.join(content_overrides)}
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>'''
    timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
    core_xml = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title>Replicate correlations</dc:title><dc:creator>OpDetect Windows GUI</dc:creator>
  <dcterms:created xsi:type="dcterms:W3CDTF">{timestamp}</dcterms:created>
  <dcterms:modified xsi:type="dcterms:W3CDTF">{timestamp}</dcterms:modified>
</cp:coreProperties>'''
    app_xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>OpDetect</Application></Properties>'''

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', content_types)
        archive.writestr('_rels/.rels', root_rels)
        archive.writestr('docProps/core.xml', core_xml)
        archive.writestr('docProps/app.xml', app_xml)
        archive.writestr('xl/workbook.xml', workbook_xml)
        archive.writestr('xl/_rels/workbook.xml.rels', workbook_rels)
        archive.writestr('xl/styles.xml', styles_xml)
        for index, (_, rows) in enumerate(sheets, start=1):
            archive.writestr(f'xl/worksheets/sheet{index}.xml', worksheet_xml(rows))

    print(f'Wrote Pearson and Spearman correlation sheets to {args.output}')


if __name__ == '__main__':
    main()
