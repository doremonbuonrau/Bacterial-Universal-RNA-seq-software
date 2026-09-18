#!/usr/bin/env python3
"""Convert a CSV or TSV table into a readable single-sheet XLSX workbook.

Uses only Python's standard library so existing OpDetect installations do not
need an additional Excel-writing package. The workbook includes a styled header,
filters, frozen header row, sensible column widths, and numeric cells.
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
    return (value or "Results")[:31]


def parse_cell(value: str) -> tuple[str, object]:
    text = value.strip()
    if text == "":
        return "blank", ""
    if re.fullmatch(r"[-+]?\d+", text):
        try:
            return "integer", int(text)
        except ValueError:
            pass
    if re.fullmatch(r"[-+]?(?:\d+\.\d*|\d*\.\d+|\d+)(?:[eE][-+]?\d+)?", text):
        try:
            number = float(text)
            if math.isfinite(number):
                return "number", number
        except ValueError:
            pass
    return "text", value


def cell_xml(reference: str, value: str, style: int = 0, force_text: bool = False) -> str:
    kind, parsed = ("text", value) if force_text and value != "" else parse_cell(value)
    style_attr = f' s="{style}"' if style else ""
    if kind == "blank":
        return f'<c r="{reference}"{style_attr}/>'
    if kind in {"integer", "number"}:
        return f'<c r="{reference}"{style_attr}><v>{parsed}</v></c>'
    preserve = ' xml:space="preserve"' if value != value.strip() else ""
    return (
        f'<c r="{reference}" t="inlineStr"{style_attr}>'
        f'<is><t{preserve}>{escape(value)}</t></is></c>'
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--delimiter", choices=["comma", "tab"], required=True)
    parser.add_argument("--sheet-name", default="Results")
    parser.add_argument(
        "--drop-columns",
        default="",
        help="Comma-separated input column names to omit from the workbook",
    )
    args = parser.parse_args()

    delimiter = "," if args.delimiter == "comma" else "\t"
    with args.input.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.reader(handle, delimiter=delimiter))
    if not rows:
        raise SystemExit(f"Input table is empty: {args.input}")

    input_width = max(len(row) for row in rows)
    rows = [row + [""] * (input_width - len(row)) for row in rows]
    original_headers = [str(value).strip() for value in rows[0]]
    drop_columns = {
        value.strip().lower()
        for value in args.drop_columns.split(",")
        if value.strip()
    }
    keep_indexes = [
        index
        for index, header in enumerate(original_headers)
        if header.lower() not in drop_columns
    ]
    if not keep_indexes:
        raise SystemExit("All input columns were removed; at least one column must remain")
    rows = [[row[index] for index in keep_indexes] for row in rows]
    original_headers = [original_headers[index] for index in keep_indexes]
    rows[0] = [re.sub(r"_+", " ", header).strip() for header in original_headers]

    width_count = len(keep_indexes)
    widths: list[int] = []
    for col in range(width_count):
        maximum = max(len(str(row[col])) for row in rows[: min(len(rows), 5000)])
        widths.append(max(9, min(42, maximum + 2)))

    last_cell = f"{column_name(width_count)}{len(rows)}"
    sheet_name = safe_sheet_name(args.sheet_name)
    text_headers = {
        "name_1", "name_2", "operon_id", "chromosome", "strand", "topology",
        "wraps_origin", "genes", "replicate", "sample", "contig",
    }

    worksheet_parts = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
        f'<dimension ref="A1:{last_cell}"/>',
        '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>',
        '<sheetFormatPr defaultRowHeight="15"/>',
        '<cols>',
    ]
    for index, width in enumerate(widths, start=1):
        worksheet_parts.append(f'<col min="{index}" max="{index}" width="{width}" customWidth="1"/>')
    worksheet_parts.extend(['</cols>', '<sheetData>'])

    for row_index, row in enumerate(rows, start=1):
        height = ' ht="24" customHeight="1"' if row_index == 1 else ""
        worksheet_parts.append(f'<row r="{row_index}"{height}>')
        for col_index, value in enumerate(row, start=1):
            ref = f"{column_name(col_index)}{row_index}"
            header = original_headers[col_index - 1].strip().lower() if original_headers else ""
            worksheet_parts.append(
                cell_xml(
                    ref,
                    value,
                    style=1 if row_index == 1 else 2,
                    force_text=(row_index > 1 and header in text_headers),
                )
            )
        worksheet_parts.append('</row>')
    worksheet_parts.extend([
        '</sheetData>',
        f'<autoFilter ref="A1:{last_cell}"/>',
        '<pageMargins left="0.3" right="0.3" top="0.5" bottom="0.5" header="0.2" footer="0.2"/>',
        '</worksheet>',
    ])
    worksheet_xml = "".join(worksheet_parts)

    styles_xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="2">
    <font><sz val="10"/><name val="Calibri"/><family val="2"/></font>
    <font><b/><color rgb="FFFFFFFF"/><sz val="10"/><name val="Calibri"/><family val="2"/></font>
  </fonts>
  <fills count="3">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF4472C4"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="2">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    <border><left style="thin"><color rgb="FFDCE5DF"/></left><right style="thin"><color rgb="FFDCE5DF"/></right><top style="thin"><color rgb="FFDCE5DF"/></top><bottom style="thin"><color rgb="FFDCE5DF"/></bottom><diagonal/></border>
  </borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="3">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
  </cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>'''

    workbook_xml = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets><sheet name={quoteattr(sheet_name)} sheetId="1" r:id="rId1"/></sheets>
</workbook>'''
    workbook_rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>'''
    root_rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>'''
    content_types = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>'''
    timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    core_xml = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title>{escape(args.output.stem)}</dc:title><dc:creator>OpDetect Windows GUI</dc:creator>
  <dcterms:created xsi:type="dcterms:W3CDTF">{timestamp}</dcterms:created>
  <dcterms:modified xsi:type="dcterms:W3CDTF">{timestamp}</dcterms:modified>
</cp:coreProperties>'''
    app_xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>OpDetect</Application></Properties>'''

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", content_types)
        archive.writestr("_rels/.rels", root_rels)
        archive.writestr("docProps/core.xml", core_xml)
        archive.writestr("docProps/app.xml", app_xml)
        archive.writestr("xl/workbook.xml", workbook_xml)
        archive.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        archive.writestr("xl/styles.xml", styles_xml)
        archive.writestr("xl/worksheets/sheet1.xml", worksheet_xml)

    print(f"Wrote {len(rows) - 1} data row(s) to {args.output}")


if __name__ == "__main__":
    main()
