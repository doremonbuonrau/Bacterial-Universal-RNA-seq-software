#!/usr/bin/env python3
"""Create a per-contig circular/linear topology table from GUI settings."""
from __future__ import annotations
import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fasta", required=True, type=Path)
    parser.add_argument("--mode", choices=["auto", "circular", "linear"], default="auto")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    records: list[tuple[str, str, str]] = []
    with args.fasta.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.startswith(">"):
                continue
            header = line[1:].strip()
            contig = header.split()[0] if header else ""
            if not contig:
                raise SystemExit("FASTA contains an empty sequence identifier")
            if args.mode == "auto":
                topology = "linear" if "linear" in header.lower() else "circular"
                reason = "header contains 'linear'" if topology == "linear" else "default bacterial replicon assumption"
            else:
                topology = args.mode
                reason = f"GUI setting: all {args.mode}"
            records.append((contig, topology, reason))

    if not records:
        raise SystemExit("Reference FASTA contains no sequence records")
    if len({record[0] for record in records}) != len(records):
        raise SystemExit("Reference FASTA contains duplicate sequence identifiers")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="") as handle:
        handle.write("contig\ttopology\treason\n")
        for contig, topology, reason in records:
            handle.write(f"{contig}\t{topology}\t{reason}\n")
    print(f"Wrote topology for {len(records)} sequence record(s) to {args.output}")
    for contig, topology, reason in records:
        print(f"  {contig}: {topology} ({reason})")


if __name__ == "__main__":
    main()
