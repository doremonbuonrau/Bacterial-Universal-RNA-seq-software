from __future__ import annotations

import gzip
import hashlib
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, TextIO

from .config import ConfigError
from .paths import safe_name


@dataclass(frozen=True)
class Feature:
    seqid: str
    source: str
    feature_type: str
    start: int
    end: int
    score: str
    strand: str
    phase: str
    attributes: dict[str, str]


def _open_text(path: Path) -> TextIO:
    if path.name.lower().endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return path.open("r", encoding="utf-8", errors="replace")


def fasta_lengths(path: Path) -> dict[str, int]:
    lengths: dict[str, int] = {}
    current: str | None = None
    with _open_text(path) as handle:
        for line_number, raw in enumerate(handle, start=1):
            line = raw.strip()
            if not line:
                continue
            if line.startswith(">"):
                current = line[1:].split()[0]
                if not current:
                    raise ConfigError(f"Blank FASTA identifier at line {line_number}.")
                if current in lengths:
                    raise ConfigError(f"Duplicate FASTA identifier: {current}")
                lengths[current] = 0
            else:
                if current is None:
                    raise ConfigError("FASTA sequence occurs before the first header.")
                lengths[current] += len(re.sub(r"\s+", "", line))
    if not lengths:
        raise ConfigError(f"No sequences were found in FASTA: {path}")
    empty = [name for name, length in lengths.items() if length == 0]
    if empty:
        raise ConfigError(f"FASTA contains empty sequences: {', '.join(empty[:5])}")
    return lengths


def parse_attributes(raw: str) -> dict[str, str]:
    raw = raw.strip()
    attributes: dict[str, str] = {}
    if not raw or raw == ".":
        return attributes

    if "=" in raw:
        for item in raw.split(";"):
            item = item.strip()
            if not item:
                continue
            if "=" in item:
                key, value = item.split("=", 1)
                attributes[key.strip()] = value.strip().strip('"')
            else:
                attributes[item] = ""
        return attributes

    for match in re.finditer(r"([^;\s]+)\s+\"([^\"]*)\"\s*;?", raw):
        attributes[match.group(1)] = match.group(2)
    if attributes:
        return attributes

    for item in raw.split(";"):
        parts = item.strip().split(None, 1)
        if len(parts) == 2:
            attributes[parts[0]] = parts[1].strip().strip('"')
    return attributes


def read_features(path: Path) -> list[Feature]:
    features: list[Feature] = []
    with _open_text(path) as handle:
        for line_number, raw in enumerate(handle, start=1):
            if not raw.strip() or raw.startswith("#"):
                continue
            fields = raw.rstrip("\r\n").split("\t")
            if len(fields) != 9:
                raise ConfigError(
                    f"Annotation line {line_number} has {len(fields)} columns; GFF/GTF requires 9."
                )
            try:
                start = int(fields[3])
                end = int(fields[4])
            except ValueError as exc:
                raise ConfigError(
                    f"Annotation line {line_number} has non-integer coordinates."
                ) from exc
            if start < 1 or end < start:
                raise ConfigError(
                    f"Annotation line {line_number} has invalid coordinates {start}-{end}."
                )
            strand = fields[6]
            if strand not in {"+", "-", ".", "?"}:
                raise ConfigError(
                    f"Annotation line {line_number} has invalid strand '{strand}'."
                )
            features.append(
                Feature(
                    seqid=fields[0],
                    source=fields[1],
                    feature_type=fields[2],
                    start=start,
                    end=end,
                    score=fields[5],
                    strand=strand,
                    phase=fields[7],
                    attributes=parse_attributes(fields[8]),
                )
            )
    if not features:
        raise ConfigError(f"No feature rows were found in annotation: {path}")
    return features


def _choose_feature_type(features: Iterable[Feature], requested: str) -> str:
    counts = Counter(feature.feature_type for feature in features)
    if requested and requested.lower() != "auto":
        exact = next((name for name in counts if name.lower() == requested.lower()), None)
        if exact is None:
            available = ", ".join(f"{name} ({count})" for name, count in counts.most_common(12))
            raise ConfigError(
                f"Requested annotation feature type '{requested}' was not found. Available: {available}"
            )
        return exact
    for candidate in ("gene", "CDS", "exon"):
        if candidate in counts:
            return candidate
    return counts.most_common(1)[0][0]


def _choose_id_attribute(features: list[Feature], feature_type: str, requested: str) -> str:
    selected = [feature for feature in features if feature.feature_type == feature_type]
    if requested and requested.lower() != "auto":
        present = sum(bool(feature.attributes.get(requested)) for feature in selected)
        if present == 0:
            raise ConfigError(
                f"Requested annotation ID attribute '{requested}' is absent from {feature_type} rows."
            )
        return requested

    if feature_type.lower() == "gene":
        candidates = ("locus_tag", "gene_id", "ID", "gene", "Name")
    else:
        candidates = ("locus_tag", "gene", "gene_id", "Parent", "ID", "Name")
    coverage = {
        key: sum(bool(feature.attributes.get(key)) for feature in selected)
        for key in candidates
    }
    return max(candidates, key=lambda key: (coverage[key], -candidates.index(key)))


def _clean_gene_id(value: str, fallback_index: int) -> str:
    value = value.split(",", 1)[0].strip()
    value = re.sub(r"^(gene|cds|rna)-", "", value, flags=re.IGNORECASE)
    return safe_name(value, f"feature_{fallback_index:06d}")


def _interval_union_length(intervals: list[tuple[int, int]]) -> int:
    total = 0
    current_start: int | None = None
    current_end: int | None = None
    for start, end in sorted(intervals):
        if current_start is None:
            current_start, current_end = start, end
        elif start <= int(current_end) + 1:
            current_end = max(int(current_end), end)
        else:
            total += int(current_end) - current_start + 1
            current_start, current_end = start, end
    if current_start is not None:
        total += int(current_end) - current_start + 1
    return total


def normalize_annotation(
    fasta_path: Path,
    annotation_path: Path,
    output_dir: Path,
    *,
    feature_type: str = "auto",
    id_attribute: str = "auto",
) -> dict[str, object]:
    output_dir.mkdir(parents=True, exist_ok=True)
    contigs = fasta_lengths(fasta_path)
    all_features = read_features(annotation_path)
    selected_type = _choose_feature_type(all_features, feature_type)
    selected_id = _choose_id_attribute(all_features, selected_type, id_attribute)

    selected: list[tuple[str, Feature]] = []
    skipped_contig = 0
    skipped_bounds = 0
    sanitized_collisions = 0
    raw_to_clean: dict[str, str] = {}
    clean_owner: dict[str, str] = {}
    for index, feature in enumerate(all_features, start=1):
        if feature.feature_type != selected_type:
            continue
        if feature.seqid not in contigs:
            skipped_contig += 1
            continue
        if feature.end > contigs[feature.seqid]:
            skipped_bounds += 1
            continue
        raw_id = feature.attributes.get(selected_id, "")
        identity = raw_id.strip() or f"__missing_id_{index}"
        gene_id = raw_to_clean.get(identity)
        if gene_id is None:
            gene_id = _clean_gene_id(raw_id, index)
            if gene_id in clean_owner and clean_owner[gene_id] != identity:
                sanitized_collisions += 1
                digest = hashlib.sha1(identity.encode("utf-8")).hexdigest()[:8]
                gene_id = f"{gene_id}_{digest}"
            raw_to_clean[identity] = gene_id
            clean_owner[gene_id] = identity
        selected.append((gene_id, feature))

    if not selected:
        raise ConfigError(
            f"No usable {selected_type} rows remain after matching annotation contigs to the FASTA."
        )

    saf_path = output_dir / "features.saf"
    gff_path = output_dir / "annotation.normalized.gff3"
    metadata_path = output_dir / "gene_metadata.tsv"
    coordinates_path = output_dir / "gene_coordinates.tsv"
    lengths_path = output_dir / "gene_lengths.tsv"
    contigs_path = output_dir / "contig_sizes.tsv"

    intervals: dict[str, list[tuple[int, int]]] = defaultdict(list)
    metadata: dict[str, dict[str, str]] = {}

    # Some otherwise valid bacterial annotations leave the parent gene strand as
    # '.' while CDS/RNA child features carry the actual + / - orientation.  Recover
    # the parent direction only when all matched directional child features agree.
    # This keeps gene_coordinates.tsv, gene_metadata.tsv and features.saf useful for
    # DE Circos/genome views without guessing when the annotation is ambiguous.
    pre_alias_to_gene: dict[str, str] = {}
    for gene_id, feature in selected:
        pre_alias_to_gene[gene_id] = gene_id
        for key in (selected_id, "ID", "locus_tag", "gene_id", "gene", "Name"):
            for alias in feature.attributes.get(key, "").split(","):
                alias = alias.strip()
                if alias:
                    pre_alias_to_gene[alias] = gene_id
    child_strands: dict[str, set[str]] = defaultdict(set)
    for feature in all_features:
        if feature.strand not in {"+", "-"}:
            continue
        candidates: list[str] = []
        for key in ("Parent", "locus_tag", "gene_id", "gene"):
            candidates.extend(item.strip() for item in feature.attributes.get(key, "").split(",") if item.strip())
        gene_id = next((pre_alias_to_gene[item] for item in candidates if item in pre_alias_to_gene), None)
        if gene_id:
            child_strands[gene_id].add(feature.strand)
    recovered_gene_strand = {
        gene_id: next(iter(values))
        for gene_id, values in child_strands.items()
        if len(values) == 1
    }

    with saf_path.open("w", encoding="utf-8", newline="\n") as saf, gff_path.open(
        "w", encoding="utf-8", newline="\n"
    ) as gff:
        saf.write("GeneID\tChr\tStart\tEnd\tStrand\n")
        gff.write("##gff-version 3\n")
        for gene_id, feature in selected:
            strand = feature.strand if feature.strand in {"+", "-"} else recovered_gene_strand.get(gene_id, ".")
            saf.write(
                f"{gene_id}\t{feature.seqid}\t{feature.start}\t{feature.end}\t{strand}\n"
            )
            attributes = dict(feature.attributes)
            attributes["ID"] = gene_id
            attributes["original_id_attribute"] = selected_id
            attribute_text = ";".join(
                f"{key}={str(value).replace(';', ',').replace(chr(9), ' ')}"
                for key, value in sorted(attributes.items())
                if value != ""
            )
            gff.write(
                "\t".join(
                    [
                        feature.seqid,
                        "ProkRNASeqSuite",
                        "gene",
                        str(feature.start),
                        str(feature.end),
                        feature.score,
                        strand,
                        ".",
                        attribute_text,
                    ]
                )
                + "\n"
            )
            intervals[gene_id].append((feature.start, feature.end))
            if gene_id not in metadata:
                metadata[gene_id] = {
                    "gene_id": gene_id,
                    "contig": feature.seqid,
                    "strand": strand,
                    "feature_type": selected_type,
                    "original_id": feature.attributes.get(selected_id, ""),
                    "locus_tag": feature.attributes.get("locus_tag", ""),
                    "old_locus_tag": feature.attributes.get("old_locus_tag", ""),
                    "protein_id": feature.attributes.get("protein_id", ""),
                    "gene": feature.attributes.get("gene", ""),
                    "name": feature.attributes.get("Name", ""),
                    "product": feature.attributes.get("product", ""),
                }

    # NCBI bacterial GFF3 commonly stores locus_tag on gene rows but product on
    # child CDS/RNA rows. Enrich the portable gene table without changing the
    # explicit intervals used for counting.
    alias_to_gene: dict[str, str] = {}
    for gene_id, feature in selected:
        alias_to_gene[gene_id] = gene_id
        for key in (selected_id, "ID", "locus_tag", "gene_id", "gene", "Name"):
            for alias in feature.attributes.get(key, "").split(","):
                alias = alias.strip()
                if alias:
                    alias_to_gene[alias] = gene_id

    for feature in all_features:
        candidates: list[str] = []
        for key in ("Parent", "locus_tag", "gene_id", "gene"):
            candidates.extend(item.strip() for item in feature.attributes.get(key, "").split(","))
        gene_id = next((alias_to_gene[item] for item in candidates if item in alias_to_gene), None)
        if gene_id is None or gene_id not in metadata:
            continue
        for destination, source_key in (
            ("locus_tag", "locus_tag"),
            ("old_locus_tag", "old_locus_tag"),
            ("protein_id", "protein_id"),
            ("gene", "gene"),
            ("name", "Name"),
            ("product", "product"),
        ):
            if not metadata[gene_id][destination] and feature.attributes.get(source_key):
                metadata[gene_id][destination] = feature.attributes[source_key]

    with metadata_path.open("w", encoding="utf-8", newline="\n") as handle:
        fields = [
            "gene_id",
            "contig",
            "seqid",
            "start",
            "end",
            "chromStart",
            "chromEnd",
            "strand",
            "feature_type",
            "original_id",
            "locus_tag",
            "old_locus_tag",
            "protein_id",
            "gene",
            "name",
            "product",
        ]
        handle.write("\t".join(fields) + "\n")
        for gene_id in sorted(metadata):
            row = dict(metadata[gene_id])
            gene_intervals = intervals.get(gene_id, [])
            row["seqid"] = str(row.get("contig", ""))
            if gene_intervals:
                start_1based = min(start for start, _ in gene_intervals)
                end_1based = max(end for _, end in gene_intervals)
                row["start"] = str(start_1based)
                row["end"] = str(end_1based)
                # GFF/GTF coordinates are 1-based inclusive. BED/IGV chromStart is 0-based; chromEnd is exclusive.
                row["chromStart"] = str(start_1based - 1)
                row["chromEnd"] = str(end_1based)
            else:
                row["start"] = ""
                row["end"] = ""
                row["chromStart"] = ""
                row["chromEnd"] = ""
            handle.write(
                "\t".join(str(row.get(field, "")).replace("\t", " ") for field in fields)
                + "\n"
            )


    with coordinates_path.open("w", encoding="utf-8", newline="\n") as handle:
        fields = [
            "gene_id", "seqid", "start", "end", "strand",
            "chromStart", "chromEnd", "length_bp",
            "feature_type", "locus_tag", "old_locus_tag", "protein_id", "gene", "name", "product",
        ]
        handle.write("\t".join(fields) + "\n")
        coordinate_rows = []
        for gene_id, record in metadata.items():
            gene_intervals = intervals.get(gene_id, [])
            if not gene_intervals:
                continue
            start_1based = min(start for start, _ in gene_intervals)
            end_1based = max(end for _, end in gene_intervals)
            coordinate_rows.append((str(record.get("contig", "")), start_1based, end_1based, gene_id, record))
        for seqid, start_1based, end_1based, gene_id, record in sorted(coordinate_rows):
            row = {
                "gene_id": gene_id,
                "seqid": seqid,
                "start": start_1based,
                "end": end_1based,
                "strand": record.get("strand", "."),
                "chromStart": start_1based - 1,
                "chromEnd": end_1based,
                "length_bp": end_1based - start_1based + 1,
                "feature_type": record.get("feature_type", selected_type),
                "locus_tag": record.get("locus_tag", ""),
                "old_locus_tag": record.get("old_locus_tag", ""),
                "protein_id": record.get("protein_id", ""),
                "gene": record.get("gene", ""),
                "name": record.get("name", ""),
                "product": record.get("product", ""),
            }
            handle.write("\t".join(str(row.get(field, "")).replace("\t", " ") for field in fields) + "\n")

    with lengths_path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("gene_id\tlength_bp\n")
        for gene_id in sorted(intervals):
            handle.write(f"{gene_id}\t{_interval_union_length(intervals[gene_id])}\n")

    with contigs_path.open("w", encoding="utf-8", newline="\n") as handle:
        for contig, length in contigs.items():
            handle.write(f"{contig}\t{length}\n")

    return {
        "feature_type": selected_type,
        "id_attribute": selected_id,
        "feature_rows": len(selected),
        "unique_gene_ids": len(intervals),
        "contigs": len(contigs),
        "skipped_missing_contig": skipped_contig,
        "skipped_out_of_bounds": skipped_bounds,
        "sanitized_id_collisions": sanitized_collisions,
        "outputs": [
            str(saf_path),
            str(gff_path),
            str(metadata_path),
            str(coordinates_path),
            str(lengths_path),
            str(contigs_path),
        ],
    }
