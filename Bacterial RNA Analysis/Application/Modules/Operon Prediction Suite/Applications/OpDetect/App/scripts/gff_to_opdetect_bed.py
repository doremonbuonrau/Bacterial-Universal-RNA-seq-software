#!/usr/bin/env python3
"""Convert bacterial GFF3 annotations to the 9-column file expected by OpDetect.

The output uses zero-based, half-open coordinates because OpDetect slices a Python
coverage array with annotation start:end. The ninth column contains one unique gene ID.
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import unquote


def parse_attributes(text: str) -> dict[str, str]:
    attrs: dict[str, str] = {}
    for item in text.strip().split(";"):
        if not item:
            continue
        if "=" in item:
            key, value = item.split("=", 1)
        elif " " in item:
            key, value = item.split(" ", 1)
            value = value.strip('"')
        else:
            continue
        attrs[key.strip()] = unquote(value.strip())
    return attrs


def choose_gene_id(attrs: dict[str, str], fallback: str) -> str:
    # locus_tag is usually unique and stable in bacterial annotations.
    for key in ("locus_tag", "Name", "gene", "protein_id", "ID", "Parent"):
        value = attrs.get(key)
        if value:
            value = value.split(",")[0].strip()
            for prefix in ("gene-", "cds-"):
                if value.startswith(prefix):
                    value = value[len(prefix) :]
            return value
    return fallback


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gff", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--feature", default="CDS", help="GFF feature type, default CDS")
    args = parser.parse_args()

    rows: list[tuple[str, int, int, str, str]] = []
    with args.gff.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 9:
                raise ValueError(f"GFF line {line_number} does not contain 9 tab-separated fields")
            seqid, _source, feature, start, end, _score, strand, _phase, attributes = fields
            if feature != args.feature:
                continue
            if strand not in {"+", "-"}:
                continue
            start_1 = int(start)
            end_1 = int(end)
            if start_1 < 1 or end_1 < start_1:
                raise ValueError(f"Invalid coordinates at GFF line {line_number}: {start}-{end}")
            attrs = parse_attributes(attributes)
            gene_id = choose_gene_id(attrs, f"gene_{line_number}")
            # Convert 1-based inclusive GFF3 coordinates to 0-based half-open coordinates.
            rows.append((seqid, start_1 - 1, end_1, strand, gene_id))

    if not rows:
        raise SystemExit(f"No {args.feature!r} records were found in {args.gff}")

    duplicate_ids = [name for name, count in Counter(row[4] for row in rows).items() if count > 1]
    if duplicate_ids:
        preview = ", ".join(duplicate_ids[:10])
        raise SystemExit(
            "Gene identifiers must be unique. Duplicate identifiers include: " + preview
        )

    rows.sort(key=lambda row: (row[0], row[1], row[2], row[4]))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as out:
        for seqid, start0, end, strand, gene_id in rows:
            # OpDetect names these columns Chromosome, ena, gene, start, end, ., strand, ., name.
            out.write(f"{seqid}\t.\tgene\t{start0}\t{end}\t.\t{strand}\t.\t{gene_id}\n")

    seqids = sorted({row[0] for row in rows})
    print(f"Wrote {len(rows)} genes across {len(seqids)} sequence(s) to {args.output}")
    if len(seqids) > 1:
        print(
            "Multi-contig annotation detected. The Windows pipeline will integrate each contig separately.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
