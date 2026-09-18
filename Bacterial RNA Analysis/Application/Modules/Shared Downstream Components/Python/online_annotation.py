#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import http.client
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zlib
from collections import defaultdict
from pathlib import Path
from typing import Iterable

from progress_status import update_progress

USER_AGENT = "BacterialRNAAnalysis/1.9.77"
ENGINE_VERSION = "1.9.77"
UNIPROT_BASE = "https://rest.uniprot.org"
SWISSPROT_FASTA_URL = "https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/complete/uniprot_sprot.fasta.gz"
MAX_LINEAGE_UNIPROT_PROTEINS = 1_200_000
DATABASE_LIBRARY_ROOT = Path(os.environ.get("BRA_DATABASE_LIBRARY", "")).expanduser() if os.environ.get("BRA_DATABASE_LIBRARY") else Path.home() / ".local" / "share" / "prok-rnaseq" / "Database Library"
CACHE_ROOT = DATABASE_LIBRARY_ROOT / "UniProt"
LEGACY_CACHE_ROOT = Path.home() / ".cache" / "bacterial-rna-analysis" / "functional-annotation"
_LIBRARY_ANNOUNCED = False


def _write_database_library_readme() -> None:
    DATABASE_LIBRARY_ROOT.mkdir(parents=True, exist_ok=True)
    for name in ("UniProt", "STRING", "KEGG", "Rfam", "Pathway mappings"):
        (DATABASE_LIBRARY_ROOT / name).mkdir(parents=True, exist_ok=True)
    readme = DATABASE_LIBRARY_ROOT / "README.txt"
    text = (
        "Bacterial RNA Analysis - Shared Database Library\n"
        "=================================================\n\n"
        "This folder is shared by GO/Enrichment, Co-expression/Networks, STRING, "
        "Pathway Database Analysis, Transcript Discovery, and future database-backed modules.\n\n"
        "Downloaded databases are kept here and reused across projects and software updates. "
        "Choosing Update/Refresh performs a small online release check first. A valid local database is kept when UniProt has not changed; "
        "only a newer release causes the affected cache to be replaced. Integrity failures or manual deletion also trigger a download.\n\n"
        "UniProt/ stores exact-organism and conservative taxonomic-lineage UniProtKB reviewed + TrEMBL data, "
        "the reviewed Swiss-Prot fallback, DIAMOND search indexes, and annotation tables.\n"
        "When an exact bacterial strain has no UniProt proteome, sequence rescue may use a bounded genus-lineage "
        "library; this is homology-based only and never assigns function by gene name alone.\n"
        "STRING/ stores reusable STRING REST responses keyed by organism and request.\n"
        "KEGG/ stores organism-specific pathway mappings retrieved after user confirmation.\n"
        "Rfam/ stores user-supplied Rfam.cm and Rfam.clanin files for reuse by Transcript Discovery.\n"
        "Pathway mappings/ stores imported BioCyc, MetaCyc, and custom TERM2GENE mappings for provenance/reuse.\n"
    )
    if not readme.is_file() or readme.read_text(encoding="utf-8", errors="replace") != text:
        readme.write_text(text, encoding="utf-8")


def _migrate_legacy_uniprot_cache() -> None:
    """Move the old per-feature cache into the shared library without redownloading."""
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    if not LEGACY_CACHE_ROOT.is_dir():
        return
    moved = 0
    for source in LEGACY_CACHE_ROOT.iterdir():
        if not source.is_file():
            continue
        target = CACHE_ROOT / source.name
        if target.exists():
            continue
        try:
            shutil.move(str(source), str(target))
            moved += 1
        except OSError:
            try:
                shutil.copy2(source, target)
                moved += 1
            except OSError:
                pass
    if moved:
        print(f"Shared Database Library: migrated {moved} existing UniProt cache file(s) from the older cache location; no re-download is required for valid completed files.", flush=True)


def _ensure_database_library(*, announce: bool = True) -> Path:
    global _LIBRARY_ANNOUNCED
    _write_database_library_readme()
    _migrate_legacy_uniprot_cache()
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    if announce and not _LIBRARY_ANNOUNCED:
        print(f"Shared Database Library: {DATABASE_LIBRARY_ROOT}", flush=True)
        print(
            "Downloaded database files are kept in this shared library and reused by future analyses. "
            "Update/Refresh first checks the current UniProt release and downloads only when the cached release is older. Integrity validation failures or removed files still trigger a download.",
            flush=True,
        )
        _LIBRARY_ANNOUNCED = True
    return DATABASE_LIBRARY_ROOT


def _record_library_entry(name: str, path: Path, metadata: dict[str, object] | None = None) -> None:
    """Maintain a small human/machine-readable index without scanning large databases."""
    _ensure_database_library(announce=False)
    manifest_path = DATABASE_LIBRARY_ROOT / "library_manifest.json"
    try:
        manifest = read_json(manifest_path) if manifest_path.is_file() else {}
    except Exception:
        manifest = {}
    entries = manifest.get("entries")
    if not isinstance(entries, dict):
        entries = {}
    payload: dict[str, object] = {
        "path": str(path),
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if path.is_file():
        payload["size_bytes"] = path.stat().st_size
    if metadata:
        payload.update(metadata)
    entries[name] = payload
    manifest = {
        "library_root": str(DATABASE_LIBRARY_ROOT),
        "software_version": ENGINE_VERSION,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "entries": entries,
    }
    write_json_atomic(manifest_path, manifest)
UNIPROT_FIELDS = [
    "accession",
    "id",
    "protein_name",
    "gene_names",
    "gene_primary",
    "gene_oln",
    "gene_orf",
    "organism_name",
    "organism_id",
    "go_p",
    "go_f",
    "go_c",
]


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr, flush=True)


def _set_progress(
    *, overall: float | int | None = None, phase: str | None = None,
    phase_percent: float | int | None = None, current: int | None = None,
    total: int | None = None, unit: str | None = None, detail: str | None = None,
    status: str = "running",
) -> None:
    try:
        update_progress(
            mode=os.environ.get("BRA_PROGRESS_MODE", ""), status=status,
            overall_percent=overall, phase=phase, phase_percent=phase_percent,
            current=current, total=total, unit=unit, detail=detail,
        )
    except Exception:
        # Progress reporting must never make a scientific analysis fail.
        pass


def _uniprot_query_state(query: str) -> dict[str, object]:
    """Read the current UniProt release/count for a query without downloading records.

    This is the basis of the shared-library *real update* behaviour.  The update
    checkbox first performs this tiny one-record request.  A valid local cache is
    retained when it already belongs to the current UniProt release; only a newer
    remote release causes the affected cache to be replaced.
    """
    try:
        params = urllib.parse.urlencode({
            "query": query, "format": "tsv", "fields": "accession", "size": "1",
        })
        request = urllib.request.Request(
            f"{UNIPROT_BASE}/uniprotkb/search?{params}",
            headers={"User-Agent": USER_AGENT, "Accept": "text/tab-separated-values"},
        )
        with urllib.request.urlopen(request, timeout=45) as response:
            raw_total = str(response.headers.get("x-total-results", "0") or "0").strip()
            return {
                "release": str(response.headers.get("x-uniprot-release", "") or "").strip(),
                "release_date": str(response.headers.get("x-uniprot-release-date", "") or "").strip(),
                "total_results": int(raw_total) if raw_total.isdigit() else 0,
            }
    except Exception as exc:
        print(f"WARNING: UniProt update check was unavailable ({type(exc).__name__}: {exc}).", flush=True)
        return {}


def _uniprot_total_results(query: str) -> int:
    """Return UniProt result count for a query without downloading the records."""
    return int(_uniprot_query_state(query).get("total_results", 0) or 0)


def _parse_cache_time(value: object) -> float | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        # Metadata written by this suite uses UTC ISO-8601 with a trailing Z.
        from datetime import datetime
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _remote_release_is_newer(
    metadata: dict[str, object],
    local_path: Path,
    remote: dict[str, object],
    *,
    label: str,
) -> bool | None:
    """Return True=new remote release, False=current cache, None=inconclusive.

    Newer suite caches store the exact UniProt release.  For an older cache without
    release metadata, the download timestamp is compared with UniProt's current
    release date so a file downloaded after that release is not pointlessly fetched
    again.  An inconclusive online check never deletes a valid local cache.
    """
    remote_release = str(remote.get("release", "") or "").strip()
    local_release = str(metadata.get("uniprot_release", metadata.get("release", "")) or "").strip()
    if remote_release and local_release:
        if remote_release == local_release:
            print(f"UniProt update check for {label}: local release {local_release} is current; download skipped.", flush=True)
            return False
        print(f"UniProt update check for {label}: local release {local_release} -> online release {remote_release}; update required.", flush=True)
        return True

    # Compatibility with caches created before exact UniProt release metadata was
    # persisted.  If the cache was obtained after the current release date, it is
    # necessarily a copy of that current_release object.
    remote_date = _parse_cache_time(remote.get("release_date", ""))
    local_time = _parse_cache_time(metadata.get("downloaded_at", ""))
    if local_time is None and local_path.is_file():
        try:
            local_time = local_path.stat().st_mtime
        except OSError:
            local_time = None
    if remote_date is not None and local_time is not None:
        if local_time + 60 >= remote_date:
            print(f"UniProt update check for {label}: cached copy was obtained after the current UniProt release date; download skipped.", flush=True)
            return False
        print(f"UniProt update check for {label}: cached copy predates the current UniProt release; update required.", flush=True)
        return True

    remote_total = int(remote.get("total_results", 0) or 0)
    try:
        local_total = int(str(metadata.get("protein_records", metadata.get("records", "0")) or "0"))
    except ValueError:
        local_total = 0
    if remote_total > 0 and local_total > 0 and remote_total != local_total:
        print(f"UniProt update check for {label}: protein count changed from {local_total:,} to {remote_total:,}; update required.", flush=True)
        return True
    return None


def _should_replace_cache_on_update(
    refresh: bool,
    local_path: Path,
    metadata: dict[str, object],
    query: str,
    *,
    label: str,
) -> tuple[bool, dict[str, object]]:
    """Implement non-destructive 'update if changed' semantics."""
    if not refresh or not local_path.is_file() or local_path.stat().st_size <= 0:
        return False, {}
    print(f"Checking UniProt online for changes to {label} before downloading anything...", flush=True)
    remote = _uniprot_query_state(query)
    if not remote:
        print(f"UniProt update check for {label} could not be completed. The valid local cache is being kept; no download will start.", flush=True)
        return False, {}
    decision = _remote_release_is_newer(metadata, local_path, remote, label=label)
    if decision is True:
        return True, remote
    if decision is False:
        return False, remote
    print(
        f"UniProt update check for {label} was inconclusive because the older cache lacks enough release metadata. "
        "The valid local copy is being kept to avoid an unnecessary large download. Future downloads record exact release metadata.",
        flush=True,
    )
    return False, remote


def as_bool(value: object, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def read_json(path: Path) -> dict:
    with path.open(encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("Configuration must be a JSON object.")
    return value


def write_json_atomic(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def detect_delimiter(path: Path) -> str:
    if path.suffix.lower() == ".csv":
        return ","
    return "\t"


def read_first_column(path: Path, preferred: str = "") -> list[str]:
    delimiter = detect_delimiter(path)
    with path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter)
        if not reader.fieldnames:
            return []
        field = preferred if preferred and preferred in reader.fieldnames else reader.fieldnames[0]
        values = []
        for row in reader:
            value = str(row.get(field, "")).strip()
            if value:
                values.append(value)
    return list(dict.fromkeys(values))


def parse_fasta(path: Path) -> dict[str, str]:
    opener = gzip.open if path.name.lower().endswith(".gz") else open
    sequences: dict[str, list[str]] = {}
    current = ""
    with opener(path, "rt", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            if line.startswith(">"):
                current = line[1:].strip().split()[0]
                if not current:
                    raise ValueError(f"Blank FASTA identifier in {path}")
                sequences.setdefault(current, [])
            else:
                if not current:
                    raise ValueError(f"Sequence data occurs before the first FASTA header in {path}")
                sequences[current].append(re.sub(r"\s+", "", line).upper())
    return {key: "".join(parts) for key, parts in sequences.items() if parts}


def request_bytes(url: str, *, data: bytes | None = None, timeout: int = 60, headers: dict[str, str] | None = None) -> tuple[bytes, dict[str, str]]:
    merged = {"User-Agent": USER_AGENT, "Accept": "text/tab-separated-values"}
    if headers:
        merged.update(headers)
    last_error: Exception | None = None
    for attempt in range(1, 5):
        req = urllib.request.Request(url, data=data, headers=merged)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                return response.read(), {k.lower(): v for k, v in response.headers.items()}
        except (http.client.IncompleteRead, http.client.HTTPException, urllib.error.URLError,
                socket.timeout, TimeoutError, ConnectionError, OSError) as exc:
            last_error = exc
            if attempt >= 4:
                break
            print(
                f"WARNING: UniProt request was interrupted ({type(exc).__name__}: {exc}); "
                f"retrying automatically ({attempt + 1}/4)...",
                flush=True,
            )
            time.sleep(min(2 ** (attempt - 1), 8))
    assert last_error is not None
    raise last_error


def request_text(url: str, *, timeout: int = 60) -> tuple[str, dict[str, str]]:
    body, headers = request_bytes(url, timeout=timeout)
    return body.decode("utf-8", errors="replace"), headers


def _next_uniprot_page_url(headers: dict[str, str]) -> str:
    """Return the UniProt REST pagination next link, if present."""
    link = str(headers.get("link", "") or "")
    if not link:
        return ""
    for item in link.split(","):
        match = re.search(r"<([^>]+)>\s*;\s*rel=\"?next\"?", item, flags=re.IGNORECASE)
        if match:
            return match.group(1).strip()
    return ""


def _count_fasta_records_text(text: str) -> int:
    return sum(1 for line in text.splitlines() if line.startswith(">"))


def _download_uniprot_query_paginated(
    organism_clause: str,
    destination: Path,
    *,
    label: str,
    expected_records: int,
    overall_start: float = 22.0,
    overall_end: float = 42.0,
    page_size: int = 500,
    timeout: int = 90,
    max_page_attempts: int = 5,
) -> tuple[dict[str, str], int]:
    """Download a scoped UniProt FASTA as resumable REST pages.

    UniProt's large ``/stream`` responses may not support byte-range resume through
    every server/proxy path.  A transient timeout could therefore restart a
    hundreds-of-thousands-record genus download from zero forever.  This downloader
    checkpoints complete REST search pages instead.  A failed page is retried a
    bounded number of times and, if the run stops, the next run resumes from the
    last completed page rather than redownloading earlier pages.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    page_dir = destination.with_name(destination.name + ".pages")
    state_path = destination.with_name(destination.name + ".pages.json")
    page_dir.mkdir(parents=True, exist_ok=True)

    params = urllib.parse.urlencode({
        "query": organism_clause,
        "format": "fasta",
        "size": str(max(1, min(int(page_size), 500))),
    })
    first_url = f"{UNIPROT_BASE}/uniprotkb/search?{params}"

    state: dict[str, object] = {}
    if state_path.is_file():
        try:
            state = read_json(state_path)
        except Exception:
            state = {}
    if state and str(state.get("query", "")) != organism_clause:
        shutil.rmtree(page_dir, ignore_errors=True)
        page_dir.mkdir(parents=True, exist_ok=True)
        state_path.unlink(missing_ok=True)
        state = {}

    next_url = str(state.get("next_url", "") or first_url)
    page_index = int(state.get("page_index", 0) or 0)
    record_count = int(state.get("record_count", 0) or 0)
    metadata: dict[str, str] = {
        "download_strategy": "UniProt REST paginated FASTA",
    }

    if page_index > 0 or record_count > 0:
        ratio = min(1.0, record_count / expected_records) if expected_records > 0 else 0.0
        _set_progress(
            overall=overall_start + ratio * (overall_end - overall_start),
            phase=f"{label} database download",
            phase_percent=ratio * 100.0,
            current=record_count,
            total=expected_records,
            unit="proteins",
            detail=(
                f"{record_count:,}/{expected_records:,} proteins safely cached | resuming page {page_index + 1:,}"
                if expected_records > 0
                else f"{record_count:,} proteins safely cached | resuming page {page_index + 1:,}"
            ),
        )
        print(
            f"Resuming {label} paginated download: {record_count:,} protein records are already safely cached "
            f"across {page_index:,} completed page(s).",
            flush=True,
        )
    else:
        print(
            f"{label} uses resumable page-by-page UniProt retrieval. Completed pages are kept, so a network timeout "
            "will not restart this large database from zero.",
            flush=True,
        )

    last_milestone = int((record_count / expected_records) * 10) if expected_records > 0 else -1

    while next_url:
        text = ""
        headers: dict[str, str] = {}
        last_error: Exception | None = None
        for attempt in range(1, max_page_attempts + 1):
            try:
                text, headers = request_text(next_url, timeout=timeout)
                last_error = None
                break
            except Exception as exc:
                last_error = exc
                if attempt >= max_page_attempts:
                    break
                wait = min(2 ** (attempt - 1), 15)
                _set_progress(
                    overall=(overall_start + (min(1.0, record_count / expected_records) if expected_records > 0 else 0) * (overall_end - overall_start)),
                    phase=f"{label} database download",
                    phase_percent=(min(100.0, record_count / expected_records * 100.0) if expected_records > 0 else 0),
                    current=record_count,
                    total=expected_records,
                    unit="proteins",
                    detail=f"Page {page_index + 1:,} interrupted | retry {attempt + 1}/{max_page_attempts} | earlier pages preserved",
                )
                print(
                    f"WARNING: {label} page {page_index + 1:,} retrieval was interrupted "
                    f"({type(exc).__name__}: {exc}); retrying this page only ({attempt + 1}/{max_page_attempts}).",
                    flush=True,
                )
                time.sleep(wait)
        if last_error is not None:
            state = {
                "query": organism_clause,
                "next_url": next_url,
                "page_index": page_index,
                "record_count": record_count,
                "expected_records": expected_records,
                "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            write_json_atomic(state_path, state)
            raise RuntimeError(
                f"{label} page {page_index + 1:,} could not be retrieved after {max_page_attempts} attempts. "
                f"The first {record_count:,} proteins remain safely cached; rerunning the analysis will resume from this page. "
                f"Last error: {last_error}"
            )

        page_records = _count_fasta_records_text(text)
        if page_records <= 0:
            # A zero-record first page means the query truly has no proteins.  A
            # zero-record later page is treated as normal end-of-pagination only
            # when UniProt also omitted a next link.
            next_candidate = _next_uniprot_page_url(headers)
            if page_index == 0:
                raise RuntimeError(f"{label} UniProtKB download returned no FASTA records for the selected query.")
            if next_candidate:
                raise RuntimeError(f"{label} UniProtKB returned an empty FASTA page while advertising another page.")
            next_url = ""
            break

        page_path = page_dir / f"page_{page_index:06d}.fasta"
        tmp_page = page_path.with_suffix(page_path.suffix + ".tmp")
        tmp_page.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8")
        os.replace(tmp_page, page_path)

        record_count += page_records
        page_index += 1
        next_url = _next_uniprot_page_url(headers)
        metadata["uniprot_release"] = headers.get("x-uniprot-release", metadata.get("uniprot_release", ""))
        metadata["uniprot_release_date"] = headers.get("x-uniprot-release-date", metadata.get("uniprot_release_date", ""))
        state = {
            "query": organism_clause,
            "next_url": next_url,
            "page_index": page_index,
            "record_count": record_count,
            "expected_records": expected_records,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        write_json_atomic(state_path, state)

        ratio = min(1.0, record_count / expected_records) if expected_records > 0 else 0.0
        phase_percent = ratio * 100.0 if expected_records > 0 else 0.0
        _set_progress(
            overall=overall_start + ratio * (overall_end - overall_start),
            phase=f"{label} database download",
            phase_percent=phase_percent,
            current=record_count,
            total=expected_records,
            unit="proteins",
            detail=(
                f"{record_count:,}/{expected_records:,} proteins | {phase_percent:.1f}% | {page_index:,} pages safely cached"
                if expected_records > 0
                else f"{record_count:,} proteins | {page_index:,} pages safely cached"
            ),
        )
        milestone = min(10, int(phase_percent // 10)) if expected_records > 0 else page_index // 100
        if milestone > last_milestone:
            if expected_records > 0:
                print(
                    f"{label} download milestone: {record_count:,}/{expected_records:,} protein records "
                    f"({phase_percent:.0f}%); {page_index:,} complete pages safely cached.",
                    flush=True,
                )
            else:
                print(f"{label} download milestone: {record_count:,} proteins; {page_index:,} pages safely cached.", flush=True)
            last_milestone = milestone

    if record_count <= 0:
        raise RuntimeError(f"{label} UniProtKB download completed but contained no FASTA records.")

    # Build one compact gzip file only after all pages are complete.  Page files
    # remain the crash-safe checkpoint during transfer and are deleted after the
    # final gzip passes validation.
    tmp_gz = destination.with_suffix(destination.suffix + ".tmp")
    with gzip.open(tmp_gz, "wt", encoding="utf-8", newline="\n", compresslevel=6) as out:
        for page_path in sorted(page_dir.glob("page_*.fasta")):
            with page_path.open("rt", encoding="utf-8", errors="replace") as incoming:
                shutil.copyfileobj(incoming, out, length=1024 * 1024)
    validated_count = _count_fasta_records(tmp_gz)
    if validated_count != record_count:
        tmp_gz.unlink(missing_ok=True)
        raise RuntimeError(
            f"{label} paginated cache validation failed: {record_count:,} records were checkpointed but "
            f"{validated_count:,} were found in the final FASTA. The page cache was preserved for recovery."
        )
    os.replace(tmp_gz, destination)
    shutil.rmtree(page_dir, ignore_errors=True)
    state_path.unlink(missing_ok=True)
    _set_progress(
        overall=overall_end,
        phase=f"{label} database download",
        phase_percent=100,
        current=record_count,
        total=(expected_records or record_count),
        unit="proteins",
        detail=f"{record_count:,} proteins downloaded and validated | reusable shared library copy ready",
    )
    print(
        f"{label} paginated download complete: {record_count:,} UniProt protein records. "
        "The completed database is now reusable and the temporary page cache was removed.",
        flush=True,
    )
    return metadata, record_count


def test_connection() -> int:
    query = urllib.parse.urlencode({
        "query": "reviewed:true",
        "format": "tsv",
        "fields": "accession",
        "size": "1",
    })
    try:
        text, headers = request_text(f"{UNIPROT_BASE}/uniprotkb/search?{query}", timeout=20)
    except Exception as exc:
        eprint(f"ERROR: UniProt connection failed: {exc}")
        return 1
    release = headers.get("x-uniprot-release", "unknown")
    if "Entry" not in text and "accession" not in text.lower():
        eprint("ERROR: UniProt returned an unexpected response.")
        return 1
    print(f"READY: UniProt REST API reachable; release {release}")
    return 0


def parse_go_cell(value: str) -> list[tuple[str, str]]:
    results: list[tuple[str, str]] = []
    for item in re.split(r";\s*", value or ""):
        item = item.strip()
        if not item:
            continue
        match = re.search(r"(GO:\d{7})", item)
        if not match:
            continue
        go_id = match.group(1)
        name = re.sub(r"\s*\[?GO:\d{7}\]?\s*", "", item).strip(" ;[]")
        results.append((go_id, name or go_id))
    return results


def parse_uniprot_tsv(text: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    reader = csv.DictReader(text.splitlines(), delimiter="\t")
    for row in reader:
        norm = {str(k or "").strip(): str(v or "").strip() for k, v in row.items()}
        rows.append(norm)
    return rows


def field(row: dict[str, str], *candidates: str) -> str:
    lowered = {k.casefold(): v for k, v in row.items()}
    for candidate in candidates:
        if candidate.casefold() in lowered:
            return lowered[candidate.casefold()]
    return ""


def row_accession(row: dict[str, str]) -> str:
    return field(row, "Entry", "accession")


def identifier_variants(value: str) -> set[str]:
    """Return conservative aliases for bacterial identifiers from tables/FASTA/GFF.

    RNA-processing inputs often contain locus tags, accessions, or GFF-derived IDs with
    harmless prefixes/version suffixes.  UniProt may expose the same identifier in a
    slightly different field.  Generate several exact-ish variants without doing fuzzy
    biological matching, so unrelated short gene symbols are not silently conflated.
    """

    raw = urllib.parse.unquote(str(value or "").strip().strip('"').strip("'"))
    if not raw:
        return set()
    seeds = {raw}
    if "|" in raw:
        seeds.update(part.strip() for part in raw.split("|") if part.strip())

    expanded: set[str] = set()
    prefix = re.compile(r"^(?:gene|cds|rna|mrna|locus[_ -]?tag|gene[_ -]?id|protein[_ -]?id)[:=_-]+", re.IGNORECASE)
    for seed in seeds:
        seed = seed.strip()
        if not seed:
            continue
        expanded.add(seed)
        stripped = prefix.sub("", seed).strip()
        if stripped:
            expanded.add(stripped)
        # Accessions and some annotation exports append a simple numeric version.
        no_version = re.sub(r"\.\d+$", "", seed)
        if no_version:
            expanded.add(no_version)

    variants: set[str] = set()
    for item in expanded:
        folded = item.casefold()
        if not folded:
            continue
        variants.add(folded)
        # A punctuation-insensitive form catches benign GFF sanitisation such as
        # ABC-0001 -> ABC_0001.  Restrict this to longer IDs to avoid gene-symbol
        # collisions (for example, rpoA versus another short alias).
        compact = re.sub(r"[^a-z0-9]+", "", folded)
        if len(compact) >= 6:
            variants.add(compact)
    return variants



ALIAS_COLUMNS = {
    "gene_id", "geneid", "id", "original_id", "originalid", "locus_tag", "locustag",
    "old_locus_tag", "oldlocustag", "gene", "name", "protein_id", "proteinid",
    "parent", "feature_id", "featureid", "transcript_id", "transcriptid", "accession",
    "refseq", "refseq_id", "refseqid", "orf", "ordered_locus", "orderedlocus",
}
COORD_SEQ_COLUMNS = ("seqid", "chr", "chrom", "chromosome", "contig", "sequence")
COORD_START_COLUMNS = ("start", "gene_start", "genestart")
COORD_END_COLUMNS = ("end", "stop", "gene_end", "geneend")
COORD_STRAND_COLUMNS = ("strand", "direction")
REFERENCE_FASTA_NAMES = (
    "reference.fasta", "reference.fa", "genome.fasta", "genome.fa", "reference.fna", "genome.fna",
)
REFERENCE_TABLE_NAMES = (
    "gene_metadata.tsv", "gene metadata.tsv", "gene_coordinates.tsv", "gene coordinates.tsv",
    "features.saf", "annotation.normalized.gff3", "annotation.normalized.gff",
    "annotation.original.gff3", "annotation.original.gff", "annotation.original.gtf",
)


def _column_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value or "").casefold())


def _split_alias_values(value: object) -> list[str]:
    raw = str(value or "").strip()
    if not raw:
        return []
    return [token for token in re.split(r"[\s,;]+", raw) if token]


def _dedupe_paths(paths: Iterable[Path]) -> list[Path]:
    seen: set[str] = set()
    output: list[Path] = []
    for raw in paths:
        try:
            path = raw.expanduser().resolve()
        except Exception:
            path = raw.expanduser()
        key = os.fspath(path)
        if key in seen:
            continue
        seen.add(key)
        output.append(path)
    return output


def _existing_path(value: object) -> Path | None:
    raw = str(value or "").strip().strip('"')
    if not raw:
        return None
    path = Path(raw).expanduser()
    return path if path.exists() else None


def _nearby_config_files(seed: Path) -> list[Path]:
    candidates: list[Path] = []
    start = seed if seed.is_dir() else seed.parent
    current = start
    for _ in range(5):
        for name in (
            "de configuration.json", "differential expression configuration.json",
            "network configuration.json", "enrichment configuration.json", "project_config.json",
        ):
            candidate = current / name
            if candidate.is_file():
                candidates.append(candidate)
        technical = current / "Intermediate files"
        if technical.is_dir():
            candidates.extend(path for path in technical.glob("* configuration.json") if path.is_file())
        if current.parent == current:
            break
        current = current.parent
    return _dedupe_paths(candidates)


def _reference_paths_from_root(root: Path) -> tuple[list[Path], list[Path]]:
    tables: list[Path] = []
    fastas: list[Path] = []
    relative_dirs = (
        Path("."),
        Path("reference"), Path("Reference"), Path("Reference support"),
        Path("Intermediate files/Browser files/Reference"),
        Path("intermediate/Browser files/Reference"),
        Path("Intermediate files/Reference"), Path("intermediate/Reference"),
        Path("analysis_ready/reference"),
        Path("analysis_ready/Intermediate files/Browser files/Reference"),
        Path("Results/Intermediate files/Browser files/Reference"),
    )
    for rel in relative_dirs:
        folder = root / rel
        if not folder.is_dir():
            continue
        for name in REFERENCE_TABLE_NAMES:
            path = folder / name
            if path.is_file():
                tables.append(path)
        for name in REFERENCE_FASTA_NAMES:
            path = folder / name
            if path.is_file():
                fastas.append(path)
    return tables, fastas



def _bounded_recursive_reference_scan(root: Path, max_depth: int = 6) -> tuple[list[Path], list[Path], list[Path]]:
    """Find retained RNA-processing references in sibling analysis folders.

    Downstream modules are often written to sibling folders such as ``edgeR analysis``
    and ``GO analysis`` while RNA Processing keeps its reference under another sibling.
    Earlier discovery only checked fixed paths directly below each ancestor, so it could
    miss a perfectly valid ``<project>/RNA processing/Intermediate files/Reference``.
    This bounded walk searches only nearby project roots and prunes bulky data folders.
    """

    tables: list[Path] = []
    fastas: list[Path] = []
    configs: list[Path] = []
    try:
        root = root.expanduser().resolve()
    except Exception:
        root = root.expanduser()
    if not root.is_dir():
        return tables, fastas, configs

    table_names = {name.casefold() for name in REFERENCE_TABLE_NAMES}
    fasta_names = {name.casefold() for name in REFERENCE_FASTA_NAMES}
    config_names = {
        'project_config.json', 'de configuration.json',
        'differential expression configuration.json', 'enrichment configuration.json',
        'network configuration.json',
    }
    # These folders can contain millions of files but cannot contain the compact
    # reference handoff that GO needs. Keep Reference/Intermediate folders searchable.
    prune = {
        '.git', '__pycache__', 'bam', 'bam bai', 'cleaned fastq', 'cleaned_fastq',
        'coverage tracks', 'coverage', 'basecalls', 'qc', 'figures', 'plots',
        'fastq', 'raw fastq', 'raw_fastq', 'tmp', 'temp',
    }
    root_depth = len(root.parts)
    visited = 0
    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        depth = len(current.parts) - root_depth
        if depth >= max_depth:
            dirnames[:] = []
        else:
            dirnames[:] = [d for d in dirnames if d.casefold() not in prune]
        visited += 1
        if visited > 12000:
            print(f"WARNING: Nearby reference discovery stopped after {visited} folders under {root} to avoid an unbounded filesystem scan.", flush=True)
            break
        for filename in filenames:
            folded = filename.casefold()
            path = current / filename
            if folded in table_names:
                tables.append(path)
            elif folded in fasta_names:
                fastas.append(path)
            elif folded in config_names or folded.endswith(' configuration.json'):
                configs.append(path)
    return _dedupe_paths(tables), _dedupe_paths(fastas), _dedupe_paths(configs)


def _candidate_project_scan_roots(seeds: Iterable[Path]) -> list[Path]:
    """Choose nearby project roots without ever walking an entire drive or filesystem."""

    roots: list[Path] = []
    for seed in seeds:
        current = seed if seed.is_dir() else seed.parent
        chain: list[Path] = []
        for _ in range(5):
            chain.append(current)
            if current.parent == current:
                break
            # Never recurse over /, /mnt, or a whole mounted Windows drive such as /mnt/e.
            if len(current.parts) <= 3 and len(current.parts) >= 2 and current.parts[1] == 'mnt':
                break
            current = current.parent
        # The broadest safe ancestor usually represents the user's project root and is
        # the one that can see sibling RNA-processing / DE / GO folders.
        safe = [p for p in chain if not (len(p.parts) <= 3 and len(p.parts) >= 2 and p.parts[1] == 'mnt')]
        if safe:
            roots.append(safe[-1])
    return _dedupe_paths(roots)

def discover_identifier_context(mode: str, cfg: dict, config_path: Path) -> tuple[list[Path], list[Path], list[Path]]:
    """Discover the RNA-processing annotation/reference behind a downstream result.

    New downstream runs retain their configuration beside the handoff tables.  That
    configuration normally points back to the gene metadata/features exported by RNA
    Processing.  Reusing those files lets GO annotation understand local locus tags and
    GFF/RefSeq aliases instead of assuming the DE gene_id is already a UniProt identifier.
    """

    seeds: list[Path] = [config_path]
    for key in ("result_file", "expression_file", "mapping_file", "annotation_sequence_file"):
        path = _existing_path(cfg.get(key, ""))
        if path is not None:
            seeds.append(path)

    related_configs: list[Path] = []
    for seed in list(seeds):
        related_configs.extend(_nearby_config_files(seed))

    tables: list[Path] = []
    fastas: list[Path] = []
    extra_seeds: list[Path] = []
    for config in _dedupe_paths(related_configs):
        try:
            payload = read_json(config)
        except Exception:
            continue
        for key in (
            "annotation_file", "gene_annotation_file", "gene_metadata_file", "coordinate_file",
            "count_file", "metadata_file", "result_file", "expression_file",
        ):
            path = _existing_path(payload.get(key, ""))
            if path is not None:
                extra_seeds.append(path)
                if key in {"annotation_file", "gene_annotation_file", "gene_metadata_file", "coordinate_file"} and path.is_file():
                    tables.append(path)
        reference = payload.get("reference")
        if isinstance(reference, dict):
            for key in ("annotation", "fasta"):
                path = _existing_path(reference.get(key, ""))
                if path is not None:
                    extra_seeds.append(path)
                    if key == "fasta":
                        fastas.append(path)
                    else:
                        tables.append(path)

    seeds.extend(extra_seeds)
    roots: list[Path] = []
    for seed in seeds:
        current = seed if seed.is_dir() else seed.parent
        for _ in range(6):
            roots.append(current)
            if current.parent == current:
                break
            current = current.parent
    for root in _dedupe_paths(roots):
        found_tables, found_fastas = _reference_paths_from_root(root)
        tables.extend(found_tables)
        fastas.extend(found_fastas)

    # Also inspect sibling analysis folders under a bounded project root. This is the
    # common layout when RNA Processing, Differential Expression, and GO were saved as
    # separate folders under the same user-selected project directory.
    scan_roots = _candidate_project_scan_roots(seeds)
    recursive_configs: list[Path] = []
    for root in scan_roots:
        found_tables, found_fastas, found_configs = _bounded_recursive_reference_scan(root)
        tables.extend(found_tables)
        fastas.extend(found_fastas)
        recursive_configs.extend(found_configs)

    # Project configs discovered in sibling folders can point to the original user GFF
    # and FASTA even when the compact RNA-processing output itself was moved.
    for config in _dedupe_paths(recursive_configs):
        try:
            payload = read_json(config)
        except Exception:
            continue
        reference = payload.get('reference')
        if isinstance(reference, dict):
            annotation_path = _existing_path(reference.get('annotation', ''))
            fasta_path = _existing_path(reference.get('fasta', ''))
            if annotation_path is not None and annotation_path.is_file():
                tables.append(annotation_path)
            if fasta_path is not None and fasta_path.is_file():
                fastas.append(fasta_path)
        for key in ('annotation_file', 'gene_annotation_file', 'gene_metadata_file', 'coordinate_file'):
            path = _existing_path(payload.get(key, ''))
            if path is not None and path.is_file():
                tables.append(path)

    related_configs.extend(recursive_configs)

    # A configured sequence file is also a valid sequence source, but it should not be
    # mistaken for a genome reference when the user explicitly supplied a protein FASTA.
    sequence_path = _existing_path(cfg.get("annotation_sequence_file", ""))
    if sequence_path is not None and sequence_path.is_file():
        fastas.append(sequence_path)

    return _dedupe_paths(tables), _dedupe_paths(fastas), _dedupe_paths(related_configs)


def _requested_alias_index(aliases_by_gene: dict[str, set[str]]) -> dict[str, str | None]:
    index: dict[str, str | None] = {}
    for gene_id, aliases in aliases_by_gene.items():
        for alias in aliases:
            for variant in identifier_variants(alias):
                if variant not in index:
                    index[variant] = gene_id
                elif index[variant] != gene_id:
                    index[variant] = None
    return index


def _match_local_tokens(tokens: Iterable[str], alias_index: dict[str, str | None]) -> set[str]:
    hits: set[str] = set()
    for token in tokens:
        for variant in identifier_variants(token):
            gene = alias_index.get(variant)
            if gene is not None:
                hits.add(gene)
    return hits


def _read_delimited_groups(path: Path) -> list[tuple[set[str], dict[str, object] | None]]:
    groups: list[tuple[set[str], dict[str, object] | None]] = []
    delimiter = "," if path.suffix.lower() == ".csv" else "\t"
    with path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter)
        headers = list(reader.fieldnames or [])
        alias_headers = [h for h in headers if _column_key(h) in {_column_key(x) for x in ALIAS_COLUMNS}]
        if not alias_headers and headers:
            alias_headers = [headers[0]]
        lower_to_header = {_column_key(h): h for h in headers}
        seq_header = next((lower_to_header.get(_column_key(x)) for x in COORD_SEQ_COLUMNS if lower_to_header.get(_column_key(x))), None)
        start_header = next((lower_to_header.get(_column_key(x)) for x in COORD_START_COLUMNS if lower_to_header.get(_column_key(x))), None)
        end_header = next((lower_to_header.get(_column_key(x)) for x in COORD_END_COLUMNS if lower_to_header.get(_column_key(x))), None)
        strand_header = next((lower_to_header.get(_column_key(x)) for x in COORD_STRAND_COLUMNS if lower_to_header.get(_column_key(x))), None)
        for row in reader:
            tokens: set[str] = set()
            for header in alias_headers:
                tokens.update(_split_alias_values(row.get(header, "")))
            if not tokens:
                continue
            coord: dict[str, object] | None = None
            if seq_header and start_header and end_header:
                try:
                    start = int(float(str(row.get(start_header, "")).strip()))
                    end = int(float(str(row.get(end_header, "")).strip()))
                except ValueError:
                    start = end = 0
                seqid = str(row.get(seq_header, "")).strip()
                if seqid and start >= 1 and end >= start:
                    coord = {
                        "seqid": seqid,
                        "start": start,
                        "end": end,
                        "strand": str(row.get(strand_header, ".")).strip() if strand_header else ".",
                        "source": os.fspath(path),
                    }
            groups.append((tokens, coord))
    return groups


def _read_gff_groups(path: Path) -> list[tuple[set[str], dict[str, object] | None]]:
    groups: list[tuple[set[str], dict[str, object] | None]] = []
    opener = gzip.open if path.name.lower().endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            if not raw.strip() or raw.startswith("#"):
                continue
            fields = raw.rstrip("\r\n").split("\t")
            if len(fields) != 9:
                continue
            attrs: dict[str, str] = {}
            attr_text = fields[8]
            if "=" in attr_text:
                for item in attr_text.split(";"):
                    if "=" in item:
                        key, value = item.split("=", 1)
                        attrs[key.strip()] = urllib.parse.unquote(value.strip().strip('"'))
            else:
                for match in re.finditer(r'([^;\s]+)\s+"([^"]*)"\s*;?', attr_text):
                    attrs[match.group(1)] = match.group(2)
            tokens: set[str] = set()
            for key, value in attrs.items():
                if _column_key(key) in {_column_key(x) for x in ALIAS_COLUMNS}:
                    tokens.update(_split_alias_values(value))
            if not tokens:
                continue
            coord: dict[str, object] | None = None
            try:
                start, end = int(fields[3]), int(fields[4])
                if start >= 1 and end >= start:
                    coord = {"seqid": fields[0], "start": start, "end": end, "strand": fields[6], "source": os.fspath(path)}
            except ValueError:
                pass
            groups.append((tokens, coord))
    return groups


def build_identifier_bridge(gene_ids: list[str], tables: Iterable[Path]) -> tuple[dict[str, set[str]], dict[str, dict[str, object]], list[str]]:
    aliases_by_gene: dict[str, set[str]] = {gene: {gene} for gene in gene_ids}
    coordinates: dict[str, dict[str, object]] = {}
    sources: list[str] = []
    groups: list[tuple[set[str], dict[str, object] | None, str]] = []
    for path in tables:
        if not path.is_file():
            continue
        try:
            lower = path.name.lower()
            if lower.endswith((".gff", ".gff3", ".gtf", ".gff.gz", ".gff3.gz", ".gtf.gz")):
                parsed = _read_gff_groups(path)
            else:
                parsed = _read_delimited_groups(path)
        except Exception as exc:
            print(f"WARNING: Could not read identifier bridge source {path}: {exc}", flush=True)
            continue
        if parsed:
            sources.append(os.fspath(path))
            groups.extend((tokens, coord, os.fspath(path)) for tokens, coord in parsed)

    # Propagate local aliases through authoritative rows (gene metadata, SAF, or GFF
    # parent/child records).  Several passes allow a locus_tag learned from a gene row
    # to connect to protein_id on a child CDS row without fuzzy name matching.
    for _ in range(8):
        changed = False
        alias_index = _requested_alias_index(aliases_by_gene)
        for tokens, coord, _source in groups:
            hits = _match_local_tokens(tokens, alias_index)
            if len(hits) != 1:
                continue
            gene = next(iter(hits))
            before = len(aliases_by_gene[gene])
            aliases_by_gene[gene].update(token for token in tokens if token)
            if len(aliases_by_gene[gene]) != before:
                changed = True
            if coord is not None and gene not in coordinates:
                coordinates[gene] = coord
        if not changed:
            break
    return aliases_by_gene, coordinates, list(dict.fromkeys(sources))


def write_identifier_bridge(path: Path, aliases_by_gene: dict[str, set[str]], sources: list[str]) -> None:
    rows = []
    source_text = ";".join(sources)
    for gene_id, aliases in aliases_by_gene.items():
        rows.append({
            "gene_id": gene_id,
            "aliases": ";".join(sorted((alias for alias in aliases if alias != gene_id), key=str.casefold)),
            "bridge_sources": source_text,
        })
    write_tsv(path, rows, ["gene_id", "aliases", "bridge_sources"])

def _go_ids_from_text(value: object) -> list[str]:
    return list(dict.fromkeys(re.findall(r"GO:\d{7}", str(value or ""))))


def extract_retained_annotation(
    gene_ids: list[str], aliases_by_gene: dict[str, set[str]], tables: Iterable[Path]
) -> tuple[list[dict[str, str]], list[dict[str, str]], set[str]]:
    """Recover function names and explicit GO IDs already present in retained annotation.

    This tier is intentionally exact and local. It never transfers a GO term merely
    because two genes have a similar short symbol. Rows are linked through the same
    conservative identifier bridge used for UniProt matching.
    """
    alias_index = _requested_alias_index(aliases_by_gene)
    facts: dict[str, dict[str, object]] = {
        gene: {"products": [], "gene_names": [], "accessions": [], "go": set(), "sources": set()}
        for gene in gene_ids
    }

    def absorb(gene: str, values: dict[str, object], source: Path) -> None:
        fact = facts[gene]
        fact["sources"].add(os.fspath(source))
        for key in ("product", "protein_name", "proteinname", "description", "function", "note"):
            value = str(values.get(key, "") or "").strip()
            if value and value not in {".", "-"}:
                fact["products"].append(value)
        for key in ("gene", "gene_name", "genename", "name", "locus_tag", "locustag", "old_locus_tag", "oldlocustag"):
            value = str(values.get(key, "") or "").strip()
            if value and value not in {".", "-"}:
                fact["gene_names"].append(value)
        for key in ("protein_id", "proteinid", "accession", "refseq", "refseq_id", "refseqid"):
            value = str(values.get(key, "") or "").strip()
            if value and value not in {".", "-"}:
                fact["accessions"].append(value)
        for value in values.values():
            fact["go"].update(_go_ids_from_text(value))

    for path in _dedupe_paths(tables):
        if not path.is_file():
            continue
        lower = path.name.lower()
        try:
            if lower.endswith((".gff", ".gff3", ".gtf", ".gff.gz", ".gff3.gz", ".gtf.gz")):
                opener = gzip.open if lower.endswith(".gz") else open
                with opener(path, "rt", encoding="utf-8", errors="replace") as handle:
                    for raw in handle:
                        if not raw.strip() or raw.startswith("#"):
                            continue
                        fields = raw.rstrip("\r\n").split("\t")
                        if len(fields) != 9:
                            continue
                        attrs: dict[str, str] = {}
                        if "=" in fields[8]:
                            for item in fields[8].split(";"):
                                if "=" in item:
                                    key, value = item.split("=", 1)
                                    attrs[_column_key(key)] = urllib.parse.unquote(value.strip().strip('"'))
                        else:
                            for match in re.finditer(r'([^;\s]+)\s+"([^"]*)"\s*;?', fields[8]):
                                attrs[_column_key(match.group(1))] = match.group(2)
                        tokens: set[str] = set()
                        for key, value in attrs.items():
                            if key in {_column_key(x) for x in ALIAS_COLUMNS}:
                                tokens.update(_split_alias_values(value))
                        hits = _match_local_tokens(tokens, alias_index)
                        if len(hits) != 1:
                            continue
                        normalized = dict(attrs)
                        normalized["note"] = attrs.get("note", "")
                        absorb(next(iter(hits)), normalized, path)
            else:
                delimiter = "," if path.suffix.lower() == ".csv" else "\t"
                with path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle:
                    reader = csv.DictReader(handle, delimiter=delimiter)
                    headers = list(reader.fieldnames or [])
                    alias_headers = [h for h in headers if _column_key(h) in {_column_key(x) for x in ALIAS_COLUMNS}]
                    if not alias_headers and headers:
                        alias_headers = [headers[0]]
                    for row in reader:
                        tokens: set[str] = set()
                        for header in alias_headers:
                            tokens.update(_split_alias_values(row.get(header, "")))
                        hits = _match_local_tokens(tokens, alias_index)
                        if len(hits) != 1:
                            continue
                        values = {_column_key(k): v for k, v in row.items() if k is not None}
                        absorb(next(iter(hits)), values, path)
        except Exception as exc:
            print(f"WARNING: Could not recover retained functional annotation from {path}: {exc}", flush=True)

    annotations: list[dict[str, str]] = []
    go_rows: list[dict[str, str]] = []
    genes_with_local_function: set[str] = set()
    for gene in gene_ids:
        fact = facts[gene]
        products = list(dict.fromkeys(str(x).strip() for x in fact["products"] if str(x).strip()))
        names = list(dict.fromkeys(str(x).strip() for x in fact["gene_names"] if str(x).strip()))
        accessions = list(dict.fromkeys(str(x).strip() for x in fact["accessions"] if str(x).strip()))
        go_ids = sorted(str(x) for x in fact["go"])
        if not (products or names or accessions or go_ids):
            continue
        genes_with_local_function.add(gene)
        annotations.append({
            "gene_id": gene,
            "matched_accession": accessions[0] if accessions else "",
            "entry_name": "",
            "gene_names": ";".join(names),
            "protein_name": products[0] if products else "",
            "organism_name": "",
            "organism_id": "",
            "go_bp": "",
            "go_mf": "",
            "go_cc": "",
            "go_ids": ";".join(go_ids),
            "annotation_method": "retained RNA-processing annotation",
            "database": "Local GFF/GTF/gene metadata",
            "sequence_identity_percent": "",
            "sequence_evalue": "",
        })
        for go_id in go_ids:
            go_rows.append({"gene_id": gene, "term_id": go_id, "term_name": go_id, "source": "GO", "aspect": ""})
    return annotations, go_rows, genes_with_local_function


def row_aliases(row: dict[str, str]) -> set[str]:
    values = [
        row_accession(row),
        field(row, "Entry Name", "id"),
        field(row, "Gene Names", "gene_names"),
        field(row, "Gene Names (primary)", "gene_primary"),
        field(row, "Gene Names (ordered locus)", "gene_oln"),
        field(row, "Gene Names (ORF)", "gene_orf"),
    ]
    aliases: set[str] = set()
    for value in values:
        for token in re.split(r"[\s;,]+", value):
            aliases.update(identifier_variants(token))
    return aliases


def row_to_annotation(gene_id: str, row: dict[str, str], *, method: str, database: str, identity: str = "", evalue: str = "") -> tuple[dict[str, str], list[dict[str, str]]]:
    go_rows: list[dict[str, str]] = []
    go_by_aspect: dict[str, list[str]] = {"BP": [], "MF": [], "CC": []}
    for aspect, labels in (
        ("BP", ("Gene Ontology (biological process)", "go_p")),
        ("MF", ("Gene Ontology (molecular function)", "go_f")),
        ("CC", ("Gene Ontology (cellular component)", "go_c")),
    ):
        value = field(row, *labels)
        for go_id, name in parse_go_cell(value):
            go_by_aspect[aspect].append(go_id)
            go_rows.append({
                "gene_id": gene_id,
                "term_id": go_id,
                "term_name": name,
                "source": "GO",
                "aspect": aspect,
            })
    annotation = {
        "gene_id": gene_id,
        "matched_accession": row_accession(row),
        "entry_name": field(row, "Entry Name", "id"),
        "gene_names": field(row, "Gene Names", "gene_names"),
        "protein_name": field(row, "Protein names", "protein_name"),
        "organism_name": field(row, "Organism", "organism_name"),
        "organism_id": field(row, "Organism (ID)", "organism_id"),
        "go_bp": ";".join(dict.fromkeys(go_by_aspect["BP"])),
        "go_mf": ";".join(dict.fromkeys(go_by_aspect["MF"])),
        "go_cc": ";".join(dict.fromkeys(go_by_aspect["CC"])),
        "go_ids": ";".join(dict.fromkeys(go_by_aspect["BP"] + go_by_aspect["MF"] + go_by_aspect["CC"])),
        "annotation_method": method,
        "database": database,
        "sequence_identity_percent": identity,
        "sequence_evalue": evalue,
    }
    return annotation, go_rows


def uniprot_search(query: str, reviewed_only: bool, *, size: int = 500) -> tuple[list[dict[str, str]], str]:
    if reviewed_only:
        query = f"({query}) AND (reviewed:true)"
    params = urllib.parse.urlencode({
        "query": query,
        "format": "tsv",
        "fields": ",".join(UNIPROT_FIELDS),
        "size": str(size),
    })
    text, headers = request_text(f"{UNIPROT_BASE}/uniprotkb/search?{params}", timeout=90)
    return parse_uniprot_tsv(text), headers.get("x-uniprot-release", "")


def get_taxonomy_context(taxid: str) -> dict[str, object]:
    """Return taxonomy context for conservative sequence-rescue broadening.

    UniProtKB may lag a newly deposited NCBI strain taxon.  We therefore try the
    UniProt taxonomy service first and fall back to NCBI Taxonomy E-utilities.
    The lineage is used only to choose a sequence-homology search scope; it never
    assigns a function merely because two genes share a name.
    """
    if not str(taxid).isdigit():
        return {}
    uniprot_error = ""
    try:
        text, _headers = request_text(f"{UNIPROT_BASE}/taxonomy/{taxid}?format=json", timeout=45)
        payload = json.loads(text)
        if isinstance(payload, dict) and payload:
            return payload
    except Exception as exc:
        uniprot_error = str(exc)

    # NCBI is the authority that minted the taxon ID, so it is the most useful
    # fallback when a new strain has not yet propagated into UniProt Taxonomy.
    try:
        params = urllib.parse.urlencode({"db": "taxonomy", "id": str(taxid), "retmode": "xml"})
        text, _headers = request_text(
            f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?{params}",
            timeout=45,
        )
        root = ET.fromstring(text)
        taxon = root.find(".//Taxon")
        if taxon is None:
            raise RuntimeError("NCBI Taxonomy returned no Taxon record")

        def node_text(node: ET.Element, tag: str) -> str:
            child = node.find(tag)
            return (child.text or "").strip() if child is not None else ""

        lineage: list[dict[str, object]] = []
        lineage_ex = taxon.find("LineageEx")
        if lineage_ex is not None:
            for item in lineage_ex.findall("Taxon"):
                item_taxid = node_text(item, "TaxId")
                lineage.append({
                    "taxonId": int(item_taxid) if item_taxid.isdigit() else item_taxid,
                    "scientificName": node_text(item, "ScientificName"),
                    "rank": node_text(item, "Rank"),
                })
        payload = {
            "taxonId": int(taxid),
            "scientificName": node_text(taxon, "ScientificName"),
            "rank": node_text(taxon, "Rank"),
            "lineage": lineage,
            "taxonomySource": "NCBI Taxonomy E-utilities",
        }
        print(
            f"Taxonomy lineage for taxon {taxid} was resolved through NCBI because the UniProt taxonomy lookup was unavailable or incomplete.",
            flush=True,
        )
        return payload
    except Exception as ncbi_exc:
        details = f"UniProt: {uniprot_error or 'no usable record'}; NCBI: {ncbi_exc}"
        print(f"WARNING: Taxonomy lineage lookup for taxon {taxid} was unavailable ({details}).", flush=True)
        return {}


def _taxonomy_value(item: dict[str, object], *names: str) -> str:
    lowered = {str(k).casefold(): v for k, v in item.items()}
    for name in names:
        value = lowered.get(name.casefold())
        if value is not None:
            return str(value).strip()
    return ""


def sequence_rescue_taxonomy_candidates(organism: str, resolved_taxid: str) -> list[tuple[str, str, str]]:
    """Return exact-taxid then conservative lineage candidates for DIAMOND rescue.

    We broaden at most to genus and only for sequence homology, never for direct
    gene-symbol assignment. This avoids transferring annotations solely by common
    names such as rpoA while still rescuing strain proteins missing from UniProtKB.
    """
    exact_clause, taxid = resolve_taxonomy_clause(organism)
    if resolved_taxid:
        exact_clause, taxid = f"organism_id:{resolved_taxid}", resolved_taxid
    candidates: list[tuple[str, str, str]] = [(exact_clause, taxid, "selected organism")]
    context = get_taxonomy_context(taxid) if taxid else {}
    lineage = context.get("lineage", []) if isinstance(context, dict) else []
    if isinstance(lineage, list):
        genus: tuple[str, str] | None = None
        for item in reversed(lineage):
            if not isinstance(item, dict):
                continue
            rank = _taxonomy_value(item, "rank").casefold()
            item_taxid = _taxonomy_value(item, "taxonId", "taxon_id", "id")
            name = _taxonomy_value(item, "scientificName", "scientific_name", "name")
            if rank == "genus" and item_taxid.isdigit():
                genus = (item_taxid, name)
                break
        if genus and genus[0] != taxid:
            candidates.append((f"taxonomy_id:{genus[0]}", genus[0], f"genus lineage {genus[1] or genus[0]}"))
    return candidates


def resolve_taxonomy_clause(organism: str) -> tuple[str, str]:
    """Resolve a free-text organism name to an NCBI taxon when UniProt can do so.

    Taxon IDs are much less ambiguous than organism-name string matching and also cope
    better with strain suffixes.  If taxonomy lookup is unavailable, retain the older
    organism_name query rather than turning a transient taxonomy failure into a hard stop.
    """

    organism = organism.strip()
    if organism.isdigit():
        return f"organism_id:{organism}", organism
    clean = organism.replace(chr(34), "").strip()
    try:
        params = urllib.parse.urlencode({
            "query": clean,
            "format": "tsv",
            "fields": "id,scientific_name,common_name,rank",
            "size": "10",
        })
        text, _headers = request_text(f"{UNIPROT_BASE}/taxonomy/search?{params}", timeout=45)
        rows = parse_uniprot_tsv(text)
        exact = next(
            (row for row in rows if field(row, "Scientific name", "scientific_name").casefold() == clean.casefold()),
            None,
        )
        chosen = exact or (rows[0] if rows else None)
        if chosen:
            taxid = field(chosen, "Taxon Id", "Taxon ID", "id")
            scientific = field(chosen, "Scientific name", "scientific_name")
            if taxid.isdigit():
                print(f"Resolved organism '{organism}' to UniProt taxonomy ID {taxid} ({scientific or 'scientific name unavailable'}).", flush=True)
                return f"organism_id:{taxid}", taxid
    except Exception as exc:
        print(f"WARNING: UniProt taxonomy-name resolution was unavailable ({exc}); falling back to organism-name matching.", flush=True)
    return f'organism_name:"{clean}"', ""


def _download_organism_rows(organism_clause: str, reviewed_only: bool, refresh: bool = False) -> tuple[list[dict[str, str]], str]:
    _ensure_database_library()
    query = organism_clause.strip() or "*"
    if reviewed_only:
        query = "(reviewed:true)" if query == "*" else f"({query}) AND (reviewed:true)"
    key = hashlib.sha1((query + "|" + ",".join(UNIPROT_FIELDS)).encode("utf-8")).hexdigest()[:20]
    table_dir = CACHE_ROOT / "Annotation tables"
    table_dir.mkdir(parents=True, exist_ok=True)
    table_path = table_dir / f"organism_{key}.tsv"
    metadata_path = table_dir / f"organism_{key}.metadata.json"
    cached_metadata: dict[str, object] = {}
    if metadata_path.is_file():
        try:
            cached_metadata = read_json(metadata_path)
        except Exception:
            cached_metadata = {}
    replace_cache, remote_state = _should_replace_cache_on_update(
        refresh, table_path, cached_metadata, query, label="organism-specific UniProt annotation table"
    )
    if replace_cache:
        table_path.unlink(missing_ok=True)
        metadata_path.unlink(missing_ok=True)
    if table_path.is_file() and table_path.stat().st_size > 0:
        text = table_path.read_text(encoding="utf-8", errors="replace")
        rows = parse_uniprot_tsv(text)
        release = str(cached_metadata.get("release", cached_metadata.get("uniprot_release", "")) or "")
        print(f"Using shared UniProt annotation table from Database Library: {len(rows):,} protein records; download skipped.", flush=True)
        return rows, release
    params = urllib.parse.urlencode({
        "query": query,
        "format": "tsv",
        "fields": ",".join(UNIPROT_FIELDS),
    })
    text, headers = request_text(f"{UNIPROT_BASE}/uniprotkb/stream?{params}", timeout=240)
    rows = parse_uniprot_tsv(text)
    table_path.write_text(text, encoding="utf-8")
    release = headers.get("x-uniprot-release", "") or str(remote_state.get("release", "") or "")
    release_date = headers.get("x-uniprot-release-date", "") or str(remote_state.get("release_date", "") or "")
    write_json_atomic(metadata_path, {
        "query": query, "release": release, "uniprot_release": release,
        "uniprot_release_date": release_date, "records": len(rows), "protein_records": len(rows),
        "downloaded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "UniProtKB REST",
    })
    _record_library_entry(f"UniProt annotation table {key}", table_path, {"records": len(rows), "release": release})
    print(f"Organism-specific UniProt annotation table received: {len(rows):,} protein records.", flush=True)
    print(f"Saved for reuse in shared Database Library: {table_path}", flush=True)
    return rows, release


def _match_identifier_rows(
    gene_ids: list[str],
    rows: list[dict[str, str]],
    aliases_by_gene: dict[str, set[str]] | None = None,
) -> dict[str, dict[str, str]]:
    # Map each alias only when it points to one requested ID. Ambiguous aliases are
    # intentionally ignored instead of silently assigning an annotation to the wrong gene.
    aliases_by_gene = aliases_by_gene or {gene: {gene} for gene in gene_ids}
    requested = _requested_alias_index({gene: set(aliases_by_gene.get(gene, {gene})) | {gene} for gene in gene_ids})

    output: dict[str, dict[str, str]] = {}
    for row in rows:
        candidates = {
            requested[alias]
            for alias in row_aliases(row)
            if alias in requested and requested[alias] is not None
        }
        for original in candidates:
            if original is not None and original not in output:
                output[original] = row
    return output


def _unrestricted_identifier_rows(
    gene_ids: list[str], reviewed_only: bool,
    aliases_by_gene: dict[str, set[str]] | None = None,
) -> tuple[list[dict[str, str]], str]:
    """Search requested identifiers without downloading all of UniProtKB.

    This deliberately remains a lower-confidence mode: common short bacterial
    gene names can occur in many taxa.  Batched exact identifier queries keep the
    search practical while the GUI and result provenance make the uncertainty
    explicit.
    """
    aliases_by_gene = aliases_by_gene or {gene: {gene} for gene in gene_ids}
    rows: list[dict[str, str]] = []
    release = ""
    batch_size = 20
    for start in range(0, len(gene_ids), batch_size):
        batch = gene_ids[start:start + batch_size]
        clauses: list[str] = []
        for gene in batch:
            alternatives = sorted({str(value).strip() for value in aliases_by_gene.get(gene, {gene}) if str(value).strip() and str(value).strip() != str(gene).strip()}, key=lambda value: (len(value), value.casefold()))
            aliases = list(dict.fromkeys([str(gene).strip(), *alternatives]))[:2]
            for alias in aliases:
                escaped = alias.replace("\\", "\\\\").replace('"', '\\"')
                clauses.extend((f'accession:"{escaped}"', f'gene_exact:"{escaped}"', f'gene:"{escaped}"'))
        if not clauses:
            continue
        found, found_release = uniprot_search(" OR ".join(dict.fromkeys(clauses)), reviewed_only, size=500)
        rows.extend(found)
        release = found_release or release
        _set_progress(
            phase="Searching UniProt identifiers without an organism filter",
            phase_percent=100.0 * min(len(gene_ids), start + len(batch)) / max(1, len(gene_ids)),
            current=min(len(gene_ids), start + len(batch)), total=len(gene_ids), unit="query genes",
            detail=f"Unrestricted UniProt search: {min(len(gene_ids), start + len(batch)):,}/{len(gene_ids):,} query genes. Hover for full text.",
        )
    return rows, release


def lookup_gene_ids(
    gene_ids: list[str], organism: str, reviewed_only: bool,
    aliases_by_gene: dict[str, set[str]] | None = None, refresh: bool = False,
) -> tuple[dict[str, dict[str, str]], str, str, str]:
    requested_database = "UniProtKB/Swiss-Prot" if reviewed_only else "UniProtKB (reviewed + TrEMBL)"
    unrestricted = not organism.strip()
    if unrestricted:
        organism_clause, resolved_taxid = "", ""
        print("WARNING: No organism or taxonomy ID was supplied. Searching requested identifiers across taxa; common gene names may be assigned uncertain matches.", flush=True)
        rows, release = _unrestricted_identifier_rows(gene_ids, reviewed_only, aliases_by_gene)
    else:
        organism_clause, resolved_taxid = resolve_taxonomy_clause(organism)
        print(f"Downloading the organism-specific {requested_database} annotation table for identifier matching...", flush=True)
        rows, release = _download_organism_rows(organism_clause, reviewed_only, refresh=refresh)
    output = _match_identifier_rows(gene_ids, rows, aliases_by_gene)
    used_database = requested_database + ("; unrestricted organism search (lower confidence)" if unrestricted else "")

    # Bacterial locus tags are frequently present only on unreviewed TrEMBL records.
    # A reviewed-only lookup can therefore return zero matches even when the organism
    # and IDs are correct.  Automatically broaden only after a zero-match attempt.
    if reviewed_only and not output:
        print(
            "No requested identifiers matched reviewed Swiss-Prot records; retrying the same organism in UniProtKB including TrEMBL...",
            flush=True,
        )
        rows, fallback_release = (_unrestricted_identifier_rows(gene_ids, False, aliases_by_gene) if unrestricted else _download_organism_rows(organism_clause, reviewed_only=False, refresh=refresh))
        output = _match_identifier_rows(gene_ids, rows, aliases_by_gene)
        release = fallback_release or release
        used_database = "UniProtKB (reviewed + TrEMBL; automatic fallback)" + ("; unrestricted organism search (lower confidence)" if unrestricted else "")

    print(
        f"Online identifier annotation: {len(output)}/{len(gene_ids)} genes matched in the {'unrestricted' if unrestricted else 'organism-specific'} UniProt search",
        flush=True,
    )
    return output, release, used_database, resolved_taxid


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _count_fasta_records(path: Path) -> int:
    """Count FASTA records without loading the database into memory.

    Temporary downloads use names such as ``*.fasta.gz.part``.  Detect gzip by
    filename *or* magic bytes so validation does not accidentally interpret a
    compressed partial as plain UTF-8 text.
    """
    is_gzip = path.name.lower().endswith((".gz", ".gz.part"))
    if not is_gzip and path.is_file():
        try:
            with path.open("rb") as probe:
                is_gzip = probe.read(2) == b"\x1f\x8b"
        except OSError:
            pass
    opener = gzip.open if is_gzip else open
    count = 0
    with opener(path, "rt", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith(">"):
                count += 1
    return count


def _feed_fasta_counter(data: bytes, state: dict[str, object]) -> None:
    if not data:
        return
    tail = state.get("tail", b"")
    if not isinstance(tail, (bytes, bytearray)):
        tail = b""
    scan = bytes(tail) + data
    if not bool(state.get("started")):
        if scan.startswith(b">"):
            state["count"] = int(state.get("count", 0)) + 1
        state["started"] = True
    state["count"] = int(state.get("count", 0)) + scan.count(b"\n>")
    state["tail"] = scan[-1:] if scan else b""


def _rebuild_partial_gzip_state(part_path: Path) -> tuple[zlib.decompressobj, dict[str, object]]:
    """Recreate gzip decoder state for an incomplete compressed FASTA.

    A byte-range resume is safe only when the existing partial bytes belong to the
    *same exact compressed object*.  This routine validates the bytes already on
    disk and discards a structurally corrupt partial stream before any network
    request is attempted.
    """
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    state: dict[str, object] = {"count": 0, "tail": b"", "started": False}
    if not part_path.is_file() or part_path.stat().st_size == 0:
        return decoder, state
    try:
        with part_path.open("rb") as handle:
            for raw in iter(lambda: handle.read(1024 * 1024), b""):
                _feed_fasta_counter(decoder.decompress(raw), state)
    except (OSError, zlib.error):
        part_path.unlink(missing_ok=True)
        return zlib.decompressobj(16 + zlib.MAX_WBITS), {"count": 0, "tail": b"", "started": False}
    return decoder, state


def _partial_meta_path(part_path: Path) -> Path:
    return part_path.with_name(part_path.name + ".meta.json")


def _read_partial_meta(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    try:
        value = read_json(path)
        return {str(k): str(v) for k, v in value.items() if v is not None}
    except Exception:
        return {}


def _write_partial_meta(path: Path, value: dict[str, str]) -> None:
    write_json_atomic(path, value)


def _discard_partial_download(part: Path, meta_path: Path, reason: str, label: str) -> None:
    had_data = part.is_file() and part.stat().st_size > 0
    part.unlink(missing_ok=True)
    meta_path.unlink(missing_ok=True)
    if had_data:
        print(f"{label} cached partial download was discarded safely: {reason}", flush=True)


def _download_gzip_fasta_resilient(
    url: str,
    destination: Path,
    *,
    label: str,
    timeout: int = 45,
    max_attempts: int = 10,
    expected_records: int = 0,
    overall_start: float = 20.0,
    overall_end: float = 40.0,
) -> tuple[dict[str, str], int]:
    """Download a UniProt gzip FASTA with responsive, corruption-safe retries.

    Progress is written to the shared GUI state instead of generating thousands of
    console lines.  Partial compressed downloads can be resumed, but only when a
    sidecar proves that they came from the same URL and the server confirms the
    same HTTP object (ETag/Last-Modified via If-Range).  This prevents a partial
    file produced by an older REST endpoint or UniProt release from being appended
    to a different gzip byte stream, which otherwise ends in ``incorrect data
    check`` during decompression.

    Any gzip CRC/stream error encountered during a resumed transfer is treated as a
    cache-integrity problem: the partial file is discarded and the download is
    restarted automatically from byte zero rather than failing the GO/network job.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    part = destination.with_name(destination.name + ".part")
    part_meta_path = _partial_meta_path(part)
    metadata: dict[str, str] = {}
    last_error: Exception | None = None
    read_size = 64 * 1024
    progress_interval = 0.40
    flush_interval_bytes = 1024 * 1024
    corruption_restarts = 0

    # 1.9.57 and older did not record which compressed object a .part file came
    # from.  Such a file is unsafe to range-resume after endpoint/release changes.
    existing_meta = _read_partial_meta(part_meta_path)
    if part.is_file() and part.stat().st_size > 0:
        if not existing_meta:
            _discard_partial_download(
                part, part_meta_path,
                "legacy partial cache has no source identity metadata",
                label,
            )
        elif existing_meta.get("source_url", "") != url:
            _discard_partial_download(
                part, part_meta_path,
                "download source changed since the partial cache was created",
                label,
            )

    for attempt in range(1, max_attempts + 1):
        decoder, state = _rebuild_partial_gzip_state(part)
        offset = part.stat().st_size if part.is_file() else 0
        partial_meta = _read_partial_meta(part_meta_path) if offset else {}
        if offset and partial_meta.get("source_url", "") != url:
            _discard_partial_download(part, part_meta_path, "source identity mismatch", label)
            decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
            state = {"count": 0, "tail": b"", "started": False}
            offset = 0
            partial_meta = {}

        headers = {"User-Agent": USER_AGENT, "Accept": "application/gzip", "Accept-Encoding": "identity"}
        if offset:
            headers["Range"] = f"bytes={offset}-"
            validator = partial_meta.get("etag") or partial_meta.get("last_modified")
            if validator:
                headers["If-Range"] = validator
            cached_count = int(state.get("count", 0))
            cached_ratio = min(1.0, cached_count / expected_records) if expected_records > 0 else 0.0
            _set_progress(
                overall=overall_start + cached_ratio * (overall_end - overall_start),
                phase=f"{label} database download",
                phase_percent=cached_ratio * 100.0,
                current=cached_count,
                total=expected_records,
                unit="proteins",
                detail=(
                    f"{cached_count:,}/{expected_records:,} proteins cached | {_format_bytes(offset)} | reconnecting"
                    if expected_records > 0
                    else f"{cached_count:,} proteins cached | {_format_bytes(offset)} | reconnecting"
                ),
            )
            print(
                f"Resuming {label} download from {_format_bytes(offset)}; "
                f"{cached_count:,} protein records already received.",
                flush=True,
            )
        elif attempt > 1:
            _set_progress(
                overall=overall_start,
                phase=f"{label} database download",
                phase_percent=0,
                current=0,
                total=expected_records,
                unit="proteins",
                detail=f"Retry {attempt}/{max_attempts} | reconnecting to UniProt",
            )
            print(f"Retrying {label} download (attempt {attempt}/{max_attempts})...", flush=True)

        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                status = int(getattr(response, "status", 200) or 200)
                content_range = str(response.headers.get("Content-Range", ""))
                response_etag = str(response.headers.get("ETag", "") or "")
                response_last_modified = str(response.headers.get("Last-Modified", "") or "")
                resumed = bool(offset and status == 206 and content_range.startswith(f"bytes {offset}-"))

                # If-Range causes a changed object to return 200.  A server may also
                # ignore Range.  Either way, appending would corrupt the gzip, so
                # restart safely from byte zero using this response body.
                if offset and not resumed:
                    _discard_partial_download(
                        part, part_meta_path,
                        "server did not confirm an exact byte-range resume",
                        label,
                    )
                    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
                    state = {"count": 0, "tail": b"", "started": False}
                    offset = 0
                    partial_meta = {}
                    _set_progress(
                        overall=overall_start,
                        phase=f"{label} database download",
                        phase_percent=0,
                        current=0,
                        total=expected_records,
                        unit="proteins",
                        detail="Server/release changed or resume unsupported | restarting safely from 0",
                    )
                    print(f"{label} server/release did not support a safe resume; restarting this download from 0.", flush=True)

                # Even with 206, reject a validator mismatch if both sides expose a
                # validator.  This protects against non-compliant proxy/cache layers.
                stored_etag = partial_meta.get("etag", "")
                stored_lm = partial_meta.get("last_modified", "")
                validator_mismatch = bool(
                    resumed and (
                        (stored_etag and response_etag and stored_etag != response_etag)
                        or (stored_lm and response_last_modified and stored_lm != response_last_modified)
                    )
                )
                if validator_mismatch:
                    _discard_partial_download(part, part_meta_path, "UniProt object validator changed", label)
                    raise RuntimeError(f"{label} remote object changed while resuming; retrying from the beginning.")

                metadata["uniprot_release"] = response.headers.get("x-uniprot-release", "")
                metadata["uniprot_release_date"] = response.headers.get("x-uniprot-release-date", "")
                mode = "ab" if resumed else "wb"

                # Persist provenance before receiving data.  A later process/network
                # interruption therefore leaves a resumable partial with identity.
                current_meta = {
                    "source_url": url,
                    "etag": response_etag or partial_meta.get("etag", ""),
                    "last_modified": response_last_modified or partial_meta.get("last_modified", ""),
                    "created_by_engine": ENGINE_VERSION,
                }
                _write_partial_meta(part_meta_path, current_meta)

                last_console_milestone = -1
                last_progress_write = 0.0
                last_flush_position = offset
                attempt_started = time.monotonic()
                attempt_start_count = int(state.get("count", 0))
                attempt_start_bytes = offset
                read_method = getattr(response, "read1", None)

                with part.open(mode) as handle:
                    while True:
                        try:
                            block = read_method(read_size) if callable(read_method) else response.read(read_size)
                        except http.client.IncompleteRead as exc:
                            block = exc.partial or b""
                            if block:
                                handle.write(block)
                                try:
                                    _feed_fasta_counter(decoder.decompress(block), state)
                                except zlib.error as zexc:
                                    raise RuntimeError(f"gzip stream corruption while receiving resumed data: {zexc}") from zexc
                                handle.flush()
                                os.fsync(handle.fileno())
                                current = int(state.get("count", 0))
                                ratio = min(1.0, current / expected_records) if expected_records > 0 else 0.0
                                _set_progress(
                                    overall=overall_start + ratio * (overall_end - overall_start),
                                    phase=f"{label} database download",
                                    phase_percent=ratio * 100.0,
                                    current=current,
                                    total=expected_records,
                                    unit="proteins",
                                    detail=(
                                        f"{current:,}/{expected_records:,} proteins | {_format_bytes(handle.tell())} | connection interrupted; retrying"
                                        if expected_records > 0
                                        else f"{current:,} proteins | {_format_bytes(handle.tell())} | connection interrupted; retrying"
                                    ),
                                )
                            raise
                        if not block:
                            break

                        handle.write(block)
                        try:
                            _feed_fasta_counter(decoder.decompress(block), state)
                        except zlib.error as zexc:
                            raise RuntimeError(f"gzip stream corruption while receiving data: {zexc}") from zexc
                        current = int(state.get("count", 0))
                        now = time.monotonic()
                        position = handle.tell()

                        if position - last_flush_position >= flush_interval_bytes:
                            handle.flush()
                            last_flush_position = position

                        if now - last_progress_write >= progress_interval:

                            if expected_records > 0:
                                ratio = min(1.0, current / expected_records)
                                phase_percent = ratio * 100.0
                                overall = overall_start + ratio * (overall_end - overall_start)
                                milestone = min(10, int(phase_percent // 10))
                                detail = (
                                    f"{current:,}/{expected_records:,} proteins | {phase_percent:.1f}% | "
                                    f"{_format_bytes(position)}"
                                )
                            else:
                                phase_percent = 0.0
                                overall = overall_start
                                milestone = current // 50000
                                detail = f"{current:,} proteins | {_format_bytes(position)}"
                            _set_progress(
                                overall=overall,
                                phase=f"{label} database download",
                                phase_percent=phase_percent,
                                current=current,
                                total=expected_records,
                                unit="proteins",
                                detail=detail,
                            )
                            last_progress_write = now

                            if milestone > last_console_milestone:
                                if expected_records > 0:
                                    print(
                                        f"{label} download milestone: {current:,}/{expected_records:,} protein records "
                                        f"({phase_percent:.0f}%; {_format_bytes(position)} compressed).",
                                        flush=True,
                                    )
                                elif current and (last_console_milestone < 0 or milestone > 0):
                                    print(
                                        f"{label} download milestone: {current:,} protein records "
                                        f"({_format_bytes(position)} compressed).",
                                        flush=True,
                                    )
                                last_console_milestone = milestone

                    _feed_fasta_counter(decoder.flush(), state)
                    handle.flush()
                    os.fsync(handle.fileno())

                if not decoder.eof:
                    raise http.client.IncompleteRead(b"", None)

                # Full gzip validation before promoting the .part file to the cache.
                # This catches CRC/trailer problems even when the network closed
                # cleanly and guarantees DIAMOND never receives a corrupt database.
                try:
                    validated_count = _count_fasta_records(part)
                except (OSError, EOFError, gzip.BadGzipFile, zlib.error) as exc:
                    raise RuntimeError(f"gzip validation failed after download: {exc}") from exc
                record_count = int(validated_count)
                if record_count <= 0:
                    raise RuntimeError(f"{label} download completed but contained no FASTA records.")
                os.replace(part, destination)
                part_meta_path.unlink(missing_ok=True)
                _set_progress(
                    overall=overall_end,
                    phase=f"{label} database download",
                    phase_percent=100,
                    current=record_count,
                    total=(expected_records or record_count),
                    unit="proteins",
                    detail=f"{record_count:,} proteins downloaded | {_format_bytes(destination.stat().st_size)} compressed",
                )
                print(
                    f"{label} download complete: {record_count:,} UniProt protein records downloaded "
                    f"({_format_bytes(destination.stat().st_size)} compressed).",
                    flush=True,
                )
                return metadata, record_count

        except (http.client.IncompleteRead, http.client.HTTPException, urllib.error.URLError,
                socket.timeout, TimeoutError, ConnectionError, OSError, RuntimeError, zlib.error) as exc:
            last_error = exc
            message = str(exc).lower()
            is_corruption = (
                isinstance(exc, zlib.error)
                or "gzip stream corruption" in message
                or "gzip validation failed" in message
                or "incorrect data check" in message
                or "incorrect header check" in message
                or "invalid distance" in message
            )
            if is_corruption:
                corruption_restarts += 1
                _discard_partial_download(
                    part,
                    part_meta_path,
                    f"compressed cache integrity check failed ({exc})",
                    label,
                )
                _set_progress(
                    overall=overall_start,
                    phase=f"{label} database download",
                    phase_percent=0,
                    current=0,
                    total=expected_records,
                    unit="proteins",
                    detail="Corrupt/incompatible partial cache detected | automatic clean restart",
                )
                print(
                    f"WARNING: {label} partial gzip cache was incompatible or corrupt. "
                    "It has been removed and the download will restart automatically from 0.",
                    flush=True,
                )
                if corruption_restarts >= 3:
                    last_error = RuntimeError(
                        f"{label} received corrupt gzip data on {corruption_restarts} clean downloads; "
                        "the server/proxy connection is altering the compressed stream."
                    )
                    break
            else:
                saved = part.stat().st_size if part.is_file() else 0
                _, partial_state = _rebuild_partial_gzip_state(part)
                count = int(partial_state.get("count", 0))
                ratio = min(1.0, count / expected_records) if expected_records > 0 else 0.0
                _set_progress(
                    overall=overall_start + ratio * (overall_end - overall_start),
                    phase=f"{label} database download",
                    phase_percent=ratio * 100.0,
                    current=count,
                    total=expected_records,
                    unit="proteins",
                    detail=(
                        f"{count:,}/{expected_records:,} proteins cached | {_format_bytes(saved)} | reconnecting after {type(exc).__name__}"
                        if expected_records > 0
                        else f"{count:,} proteins cached | {_format_bytes(saved)} | reconnecting after {type(exc).__name__}"
                    ),
                )
                print(
                    f"WARNING: {label} download was interrupted after {count:,} protein records "
                    f"({_format_bytes(saved)} cached). The software will retry automatically. "
                    f"Reason: {type(exc).__name__}: {exc}",
                    flush=True,
                )

            if attempt < max_attempts:
                time.sleep(min(2 ** (attempt - 1), 20))
                continue
            break

    raise RuntimeError(
        f"{label} download could not be completed after {max_attempts} attempts. "
        f"The partial download was preserved only when its source identity and gzip stream were valid. "
        f"Last error: {last_error}"
    )

def _format_bytes(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024.0 or unit == "GiB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024.0
    return f"{size} B"


def _format_duration(seconds: float) -> str:
    if not isinstance(seconds, (int, float)) or seconds < 0 or seconds == float("inf"):
        return "calculating"
    seconds = int(round(seconds))
    if seconds < 60:
        return f"{seconds}s"
    minutes, sec = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {sec:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes:02d}m"


def download_swissprot(refresh: bool = False) -> tuple[Path, Path, dict[str, str]]:
    _ensure_database_library()
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    fasta_gz = CACHE_ROOT / "uniprot_swissprot.fasta.gz"
    db_prefix = CACHE_ROOT / "uniprot_swissprot"
    dmnd = CACHE_ROOT / "uniprot_swissprot.dmnd"
    metadata_path = CACHE_ROOT / "uniprot_swissprot.metadata.json"
    metadata: dict[str, str] = {}
    if metadata_path.is_file():
        try:
            metadata = {str(k): str(v) for k, v in read_json(metadata_path).items()}
        except Exception:
            metadata = {}
    replace_cache, remote_state = _should_replace_cache_on_update(
        refresh, fasta_gz, metadata, "reviewed:true", label="shared Swiss-Prot library"
    )
    if replace_cache:
        fasta_gz.unlink(missing_ok=True)
        dmnd.unlink(missing_ok=True)
        metadata_path.unlink(missing_ok=True)
        partial = fasta_gz.with_name(fasta_gz.name + ".part")
        partial.unlink(missing_ok=True)
        _partial_meta_path(partial).unlink(missing_ok=True)
        shutil.rmtree(fasta_gz.with_name(fasta_gz.name + ".pages"), ignore_errors=True)
        fasta_gz.with_name(fasta_gz.name + ".pages.json").unlink(missing_ok=True)
        metadata = {}
        print("A newer Swiss-Prot release was detected. The affected shared cache will now be refreshed.", flush=True)
    if not fasta_gz.is_file() or fasta_gz.stat().st_size == 0:
        print("Downloading the reviewed UniProtKB/Swiss-Prot protein database. This is a one-time shared-library download and may take several minutes.", flush=True)
        print(f"When complete it will be kept at: {fasta_gz}", flush=True)
        if not remote_state:
            remote_state = _uniprot_query_state("reviewed:true")
        expected_records = int(remote_state.get("total_results", 0) or 0)
        download_meta, record_count = _download_gzip_fasta_resilient(
            SWISSPROT_FASTA_URL,
            fasta_gz,
            label="Swiss-Prot",
            expected_records=expected_records,
            overall_start=22.0,
            overall_end=42.0,
        )
        metadata.update(download_meta)
        metadata.update({
            "downloaded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "source_url": SWISSPROT_FASTA_URL,
            "fasta_sha256": sha256_file(fasta_gz),
            "protein_records": str(record_count),
            "sequence_database": "UniProtKB/Swiss-Prot",
            "uniprot_release": str(remote_state.get("release", metadata.get("uniprot_release", "")) or ""),
            "uniprot_release_date": str(remote_state.get("release_date", metadata.get("uniprot_release_date", "")) or ""),
        })
        write_json_atomic(metadata_path, metadata)
        _record_library_entry("UniProt Swiss-Prot FASTA", fasta_gz, metadata)
        print("Swiss-Prot is now stored in the shared Database Library. Future GO/Network analyses will reuse it. Update/Refresh first checks the online UniProt release and only downloads when the shared copy is older.", flush=True)
    elif metadata_path.is_file():
        try:
            metadata = read_json(metadata_path)
        except Exception:
            metadata = {}
    if fasta_gz.is_file() and not metadata.get("protein_records"):
        try:
            metadata["protein_records"] = str(_count_fasta_records(fasta_gz))
            metadata.setdefault("sequence_database", "UniProtKB/Swiss-Prot")
            write_json_atomic(metadata_path, metadata)
        except Exception as exc:
            print(f"WARNING: Existing Swiss-Prot cache could not be validated ({exc}); it will be downloaded again.", flush=True)
            fasta_gz.unlink(missing_ok=True)
            dmnd.unlink(missing_ok=True)
            return download_swissprot(refresh=False)
    if fasta_gz.is_file():
        try:
            records = int(str(metadata.get("protein_records", "0") or "0"))
        except ValueError:
            records = 0
        print(
            f"Using shared Swiss-Prot library: {records:,} proteins already available; database download skipped." if records else
            "Using shared Swiss-Prot library; database download skipped.",
            flush=True,
        )
    diamond = shutil.which("diamond")
    if not diamond:
        raise RuntimeError("DIAMOND is not installed in the downstream environment. Use Install or update once, then run the sequence annotation again.")
    _record_library_entry("UniProt Swiss-Prot FASTA", fasta_gz, metadata)
    current_fasta_sha = str(metadata.get("fasta_sha256", ""))
    trusted_existing_dmnd = dmnd.is_file() and dmnd.stat().st_size > 0
    if trusted_existing_dmnd and current_fasta_sha and not metadata.get("diamond_fasta_sha256"):
        # Older suite versions did not record the source FASTA hash. If the index
        # is newer than the FASTA, preserve it and adopt it into the new manifest
        # instead of forcing an unnecessary rebuild after upgrade.
        if dmnd.stat().st_mtime >= fasta_gz.stat().st_mtime:
            metadata["diamond_fasta_sha256"] = current_fasta_sha
            write_json_atomic(metadata_path, metadata)
    need_dmnd = (
        not dmnd.is_file() or dmnd.stat().st_size == 0 or
        (current_fasta_sha and metadata.get("diamond_fasta_sha256") not in {"", current_fasta_sha})
    )
    if need_dmnd:
        dmnd.unlink(missing_ok=True)
        print("Building the shared DIAMOND Swiss-Prot search database once...", flush=True)
        subprocess.run([diamond, "makedb", "--in", str(fasta_gz), "--db", str(db_prefix)], check=True)
        if current_fasta_sha:
            metadata["diamond_fasta_sha256"] = current_fasta_sha
            write_json_atomic(metadata_path, metadata)
        _record_library_entry("UniProt Swiss-Prot DIAMOND", dmnd, {"protein_records": metadata.get("protein_records", ""), "fasta_sha256": current_fasta_sha})
    else:
        print(f"Using existing DIAMOND index from shared Database Library: {dmnd}", flush=True)
        _record_library_entry("UniProt Swiss-Prot DIAMOND", dmnd, {"protein_records": metadata.get("protein_records", ""), "fasta_sha256": current_fasta_sha})
    return fasta_gz, dmnd, metadata


def _prepare_uniprot_query_database(
    organism_clause: str,
    cache_key: str,
    display_label: str,
    taxonomy_id: str,
    expected_records: int,
    refresh: bool = False,
) -> tuple[Path, dict[str, str]]:
    """Download/cache one scoped UniProtKB reviewed+TrEMBL FASTA and DIAMOND DB."""
    _ensure_database_library()
    safe_key = re.sub(r"[^A-Za-z0-9_.-]+", "_", cache_key).strip("._") or hashlib.sha1(organism_clause.encode("utf-8")).hexdigest()[:16]
    scoped_dir = CACHE_ROOT / "Taxonomy sequence libraries"
    scoped_dir.mkdir(parents=True, exist_ok=True)
    fasta_gz = scoped_dir / f"uniprot_{safe_key}.fasta.gz"
    db_prefix = scoped_dir / f"uniprot_{safe_key}"
    dmnd = scoped_dir / f"uniprot_{safe_key}.dmnd"
    metadata_path = scoped_dir / f"uniprot_{safe_key}.metadata.json"
    # Adopt the completed exact-organism cache layout used by 1.9.53-1.9.60 so
    # upgrading never forces a valid organism database to be downloaded again.
    if display_label == "selected organism" and taxonomy_id:
        legacy_prefix = CACHE_ROOT / f"uniprot_organism_{taxonomy_id}"
        for old_path, new_path in (
            (legacy_prefix.with_suffix(".fasta.gz"), fasta_gz),
            (legacy_prefix.with_suffix(".dmnd"), dmnd),
            (legacy_prefix.with_suffix(".metadata.json"), metadata_path),
        ):
            if old_path.is_file() and not new_path.exists():
                try:
                    shutil.move(str(old_path), str(new_path))
                except OSError:
                    shutil.copy2(old_path, new_path)
    metadata: dict[str, str] = {}
    if metadata_path.is_file():
        try:
            metadata = {str(k): str(v) for k, v in read_json(metadata_path).items()}
        except Exception:
            metadata = {}
    replace_cache, remote_state = _should_replace_cache_on_update(
        refresh, fasta_gz, metadata, organism_clause, label=f"{display_label} UniProtKB sequence library"
    )
    if replace_cache:
        fasta_gz.unlink(missing_ok=True)
        dmnd.unlink(missing_ok=True)
        metadata_path.unlink(missing_ok=True)
        partial = fasta_gz.with_name(fasta_gz.name + ".part")
        partial.unlink(missing_ok=True)
        _partial_meta_path(partial).unlink(missing_ok=True)
        shutil.rmtree(fasta_gz.with_name(fasta_gz.name + ".pages"), ignore_errors=True)
        fasta_gz.with_name(fasta_gz.name + ".pages.json").unlink(missing_ok=True)
        metadata = {}
        print(f"A newer UniProt release was detected for {display_label}. The affected shared cache will now be refreshed.", flush=True)

    params = urllib.parse.urlencode({"format": "fasta", "query": organism_clause, "size": "500"})
    url = f"{UNIPROT_BASE}/uniprotkb/search?{params}"
    if not fasta_gz.is_file() or fasta_gz.stat().st_size == 0:
        print(f"Downloading {display_label} UniProtKB protein sequences (reviewed + TrEMBL) for sequence rescue...", flush=True)
        print(f"Shared Database Library destination: {fasta_gz}", flush=True)
        download_meta, record_count = _download_uniprot_query_paginated(
            organism_clause,
            fasta_gz,
            label=f"UniProtKB {display_label}",
            expected_records=expected_records,
            overall_start=22.0,
            overall_end=42.0,
        )
        if record_count <= 0:
            fasta_gz.unlink(missing_ok=True)
            raise RuntimeError(f"{display_label} UniProtKB download completed but contained no FASTA records.")
        metadata.update(download_meta)
        metadata.update({
            "downloaded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "source_url": url,
            "query": organism_clause,
            "fasta_sha256": sha256_file(fasta_gz),
            "sequence_database": f"UniProtKB {display_label} reviewed + TrEMBL",
            "taxonomy_id": taxonomy_id,
            "protein_records": str(record_count),
            "uniprot_release": str(remote_state.get("release", metadata.get("uniprot_release", "")) or ""),
            "uniprot_release_date": str(remote_state.get("release_date", metadata.get("uniprot_release_date", "")) or ""),
        })
        write_json_atomic(metadata_path, metadata)
        _record_library_entry(f"UniProt {display_label} {safe_key} FASTA", fasta_gz, metadata)
        print(f"{display_label.capitalize()} UniProtKB proteins are now retained in the shared Database Library and reused automatically.", flush=True)
    elif metadata_path.is_file():
        try:
            metadata = read_json(metadata_path)
        except Exception:
            metadata = {}

    if fasta_gz.is_file() and not metadata.get("protein_records"):
        try:
            metadata["protein_records"] = str(_count_fasta_records(fasta_gz))
            metadata.setdefault("query", organism_clause)
            metadata.setdefault("sequence_database", f"UniProtKB {display_label} reviewed + TrEMBL")
            write_json_atomic(metadata_path, metadata)
        except Exception as exc:
            print(f"WARNING: Existing {display_label} UniProtKB cache could not be validated ({exc}); it will be downloaded again.", flush=True)
            fasta_gz.unlink(missing_ok=True)
            dmnd.unlink(missing_ok=True)
            return _prepare_uniprot_query_database(organism_clause, cache_key, display_label, taxonomy_id, expected_records, refresh=False)

    try:
        records = int(str(metadata.get("protein_records", "0") or "0"))
    except ValueError:
        records = 0
    if records <= 0:
        raise RuntimeError(f"{display_label} UniProtKB cache contained no FASTA records.")
    if fasta_gz.is_file():
        print(f"Using shared {display_label} UniProtKB library: {records:,} proteins already available; download skipped.", flush=True)

    diamond = shutil.which("diamond")
    if not diamond:
        raise RuntimeError("DIAMOND is not installed in the downstream environment. Use Install or update once, then run the sequence annotation again.")
    current_fasta_sha = str(metadata.get("fasta_sha256", ""))
    if dmnd.is_file() and dmnd.stat().st_size > 0 and current_fasta_sha and not metadata.get("diamond_fasta_sha256"):
        if dmnd.stat().st_mtime >= fasta_gz.stat().st_mtime:
            metadata["diamond_fasta_sha256"] = current_fasta_sha
            write_json_atomic(metadata_path, metadata)
    need_dmnd = (
        not dmnd.is_file() or dmnd.stat().st_size == 0 or
        (current_fasta_sha and metadata.get("diamond_fasta_sha256") not in {"", current_fasta_sha})
    )
    if need_dmnd:
        dmnd.unlink(missing_ok=True)
        print(f"Building the shared DIAMOND database for {display_label} once...", flush=True)
        subprocess.run([diamond, "makedb", "--in", str(fasta_gz), "--db", str(db_prefix)], check=True)
        if current_fasta_sha:
            metadata["diamond_fasta_sha256"] = current_fasta_sha
            write_json_atomic(metadata_path, metadata)
    else:
        print(f"Using existing {display_label} DIAMOND index from shared Database Library: {dmnd}", flush=True)
    _record_library_entry(f"UniProt {display_label} {safe_key} DIAMOND", dmnd, {"protein_records": records, "fasta_sha256": current_fasta_sha})
    return dmnd, metadata


def download_organism_uniprot_database(
    organism: str, resolved_taxid: str, refresh: bool = False
) -> tuple[Path, dict[str, str]]:
    """Select the narrowest useful UniProtKB sequence database for bacterial rescue.

    Exact taxon is preferred. If UniProtKB has no proteins for a newly deposited strain,
    the search can broaden conservatively to that taxon's genus. The genus fallback is
    only used for sequence homology and is capped so the GUI never silently starts a
    multi-million-protein TrEMBL download.
    """
    candidates = sequence_rescue_taxonomy_candidates(organism, resolved_taxid)
    rejected: list[str] = []
    for idx, (clause, taxid, label) in enumerate(candidates):
        expected = _uniprot_total_results(clause)
        if expected <= 0:
            rejected.append(f"{label}: no UniProtKB protein records")
            if idx == 0:
                print(f"Exact selected taxon has no UniProtKB protein records; checking a conservative taxonomic-lineage sequence rescue...", flush=True)
            continue
        if label.startswith("genus") and expected > MAX_LINEAGE_UNIPROT_PROTEINS:
            rejected.append(f"{label}: {expected:,} proteins exceeds the automatic {MAX_LINEAGE_UNIPROT_PROTEINS:,}-protein safety cap")
            print(
                f"Genus-lineage UniProtKB contains {expected:,} proteins, above the automatic safety cap of {MAX_LINEAGE_UNIPROT_PROTEINS:,}; "
                "skipping that very large TrEMBL download and retaining global Swiss-Prot as the conservative fallback.",
                flush=True,
            )
            continue
        if label.startswith("genus"):
            print(
                f"Using genus-lineage TrEMBL rescue because the exact strain is absent from UniProtKB: {label}; {expected:,} proteins. "
                "This database is saved once in the shared Database Library.",
                flush=True,
            )
        cache_key = f"tax{taxid}_{hashlib.sha1(clause.encode('utf-8')).hexdigest()[:10]}"
        try:
            return _prepare_uniprot_query_database(clause, cache_key, label, taxid, expected, refresh=refresh)
        except Exception as exc:
            rejected.append(f"{label}: {exc}")
            print(f"WARNING: {label} UniProtKB sequence rescue was unavailable ({exc}).", flush=True)
    raise RuntimeError("No usable scoped UniProtKB sequence database was available. " + "; ".join(rejected))

def run_diamond(
    sequence_file: Path, input_mode: str, output_dir: Path, refresh: bool,
    evalue: float, min_identity: float, *, organism: str = '', resolved_taxid: str = ''
) -> tuple[dict[str, tuple[str, str, str]], dict[str, str]]:
    if organism.strip():
        try:
            dmnd, metadata = download_organism_uniprot_database(organism, resolved_taxid, refresh=refresh)
        except Exception as exc:
            print(f"WARNING: Organism-specific sequence database was unavailable ({exc}); falling back to global reviewed Swiss-Prot.", flush=True)
            _, dmnd, metadata = download_swissprot(refresh=refresh)
    else:
        print(
            "WARNING: No organism or taxonomy ID was supplied for sequence matching. "
            "Using global reviewed Swiss-Prot may produce cross-species homolog assignments; provide an organism for a more accurate scoped database.",
            flush=True,
        )
        _, dmnd, metadata = download_swissprot(refresh=refresh)
    diamond = shutil.which("diamond")
    assert diamond
    raw_hits = output_dir / "sequence_database_hits.tsv"
    command = [
        diamond,
        "blastp" if input_mode == "protein_fasta" else "blastx",
        "--db", str(dmnd),
        "--query", str(sequence_file),
        "--out", str(raw_hits),
        "--outfmt", "6", "qseqid", "sseqid", "pident", "length", "evalue", "bitscore",
        "--evalue", str(evalue),
        "--max-target-seqs", "5",
        "--sensitive",
        "--threads", str(max(1, min(os.cpu_count() or 1, 8))),
    ]
    db_label = metadata.get('sequence_database', 'UniProtKB/Swiss-Prot')
    try:
        query_records = _count_fasta_records(sequence_file)
    except Exception:
        query_records = 0
    try:
        db_records = int(str(metadata.get('protein_records', '0') or '0'))
    except ValueError:
        db_records = 0
    if db_records:
        print(
            f"Protein database ready: {db_records:,} UniProt protein records available. "
            f"DIAMOND will search {query_records:,} query genes/sequences.",
            flush=True,
        )
    else:
        print(f"DIAMOND will search {query_records:,} query genes/sequences against the cached {db_label} database.", flush=True)
    _set_progress(
        overall=44, phase="DIAMOND sequence matching", phase_percent=0, current=0,
        total=0, unit="genes",
        detail=f"Searching {query_records:,} query genes against {db_records:,} database proteins" if db_records else f"Searching {query_records:,} query genes",
    )
    print(f"Scanning sequences against the cached {db_label} database with DIAMOND...", flush=True)
    subprocess.run(command, check=True)
    best: dict[str, tuple[str, str, str]] = {}
    if raw_hits.is_file():
        with raw_hits.open(encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                parts = raw.rstrip("\n").split("\t")
                if len(parts) < 6:
                    continue
                qseqid, sseqid, pident, _length, eval_text, _bitscore = parts[:6]
                try:
                    if float(pident) < min_identity:
                        continue
                except ValueError:
                    continue
                accession = sseqid.split("|")[1] if "|" in sseqid and len(sseqid.split("|")) >= 3 else sseqid
                if qseqid not in best:
                    best[qseqid] = (accession, pident, eval_text)
    _set_progress(
        overall=50, phase="DIAMOND sequence matching", phase_percent=100,
        current=query_records, total=query_records, unit="genes",
        detail=f"{len(best):,}/{query_records:,} query genes have sequence hits",
    )
    print(f"DIAMOND sequence matching complete: {len(best):,}/{query_records:,} query genes/sequences have hits passing the identity threshold.", flush=True)
    return best, metadata



def _write_fasta(path: Path, sequences: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for name, sequence in sequences.items():
            handle.write(f">{name}\n")
            for start in range(0, len(sequence), 80):
                handle.write(sequence[start:start + 80] + "\n")


def _reverse_complement(sequence: str) -> str:
    table = str.maketrans("ACGTRYMKBDHVNacgtrymkbdhvn", "TGCAYRKMVHDBNtgcayrkmvhdbn")
    return sequence.translate(table)[::-1]


def normalize_user_sequence_queries(
    sequence_path: Path,
    gene_ids: list[str],
    aliases_by_gene: dict[str, set[str]],
    destination: Path,
) -> tuple[Path, set[str]]:
    sequences = parse_fasta(sequence_path)
    alias_index = _requested_alias_index(aliases_by_gene)
    mapped: dict[str, str] = {}
    for sequence_id, sequence in sequences.items():
        genes: set[str] = set()
        for variant in identifier_variants(sequence_id):
            gene = alias_index.get(variant)
            if gene is not None:
                genes.add(gene)
        if len(genes) == 1:
            gene = next(iter(genes))
            mapped.setdefault(gene, sequence)
    if not mapped:
        raise ValueError(
            "None of the FASTA identifiers could be connected to analysis gene IDs, even after checking the RNA-processing identifier bridge. "
            "Use a FASTA derived from the same reference annotation, or choose Gene/locus-tag IDs and let the software use the retained RNA-processing reference automatically."
        )
    _write_fasta(destination, mapped)
    return destination, set(mapped)


def extract_reference_gene_queries(
    reference_fasta: Path,
    genes: Iterable[str],
    coordinates: dict[str, dict[str, object]],
    destination: Path,
) -> tuple[Path | None, set[str]]:
    try:
        contigs = parse_fasta(reference_fasta)
    except Exception as exc:
        print(f"WARNING: Could not read automatic reference FASTA {reference_fasta}: {exc}", flush=True)
        return None, set()
    sequences: dict[str, str] = {}
    for gene in genes:
        coord = coordinates.get(gene)
        if not coord:
            continue
        seqid = str(coord.get("seqid", ""))
        reference = contigs.get(seqid)
        if reference is None:
            # FASTA IDs occasionally carry a numeric version while SAF/GFF seqids do not.
            matching = [key for key in contigs if identifier_variants(key) & identifier_variants(seqid)]
            reference = contigs[matching[0]] if len(matching) == 1 else None
        if reference is None:
            continue
        try:
            start = int(coord["start"])
            end = int(coord["end"])
        except (KeyError, TypeError, ValueError):
            continue
        if start < 1 or end < start or end > len(reference):
            continue
        sequence = reference[start - 1:end]
        if str(coord.get("strand", ".")).strip() == "-":
            sequence = _reverse_complement(sequence)
        if sequence:
            sequences[gene] = sequence
    if not sequences:
        return None, set()
    _write_fasta(destination, sequences)
    return destination, set(sequences)


def annotate_by_sequence(
    query_fasta: Path,
    input_mode: str,
    gene_ids: list[str],
    output_dir: Path,
    refresh: bool,
    evalue: float,
    min_identity: float,
    *,
    method_label: str,
    organism: str = '',
    resolved_taxid: str = '',
) -> tuple[list[dict[str, str]], list[dict[str, str]], set[str], str, dict[str, str]]:
    hits, db_metadata = run_diamond(
        query_fasta, input_mode, output_dir, refresh, evalue, min_identity,
        organism=organism, resolved_taxid=resolved_taxid
    )
    requested = set(gene_ids)
    accessions = [hit[0] for gene, hit in hits.items() if gene in requested]
    accession_rows, release = fetch_accessions(accessions, output_dir=output_dir)
    annotations: list[dict[str, str]] = []
    go_rows: list[dict[str, str]] = []
    matched: set[str] = set()
    for gene_id in gene_ids:
        hit = hits.get(gene_id)
        if not hit:
            continue
        accession, identity, eval_text = hit
        row = accession_rows.get(accession)
        if not row:
            continue
        annotation, terms = row_to_annotation(
            gene_id,
            row,
            method=method_label,
            database=db_metadata.get("sequence_database", "UniProtKB/Swiss-Prot"),
            identity=identity,
            evalue=eval_text,
        )
        annotations.append(annotation)
        go_rows.extend(terms)
        matched.add(gene_id)
    return annotations, go_rows, matched, release, db_metadata

def _functional_record_cache_path() -> Path:
    """Return the durable accession-record cache used by resumable DIAMOND annotation."""
    _ensure_database_library(announce=False)
    directory = CACHE_ROOT / "Functional records"
    directory.mkdir(parents=True, exist_ok=True)
    return directory / "uniprot_accession_records.sqlite3"


def _open_functional_record_cache(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path, timeout=30)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=NORMAL")
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS accession_records (
            accession TEXT PRIMARY KEY,
            record_json TEXT NOT NULL,
            uniprot_release TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL
        )
        """
    )
    return connection


def _load_cached_functional_records(
    path: Path, accessions: list[str]
) -> tuple[dict[str, dict[str, str]], str]:
    if not accessions:
        return {}, ""
    output: dict[str, dict[str, str]] = {}
    release = ""
    try:
        with _open_functional_record_cache(path) as connection:
            for start in range(0, len(accessions), 800):
                batch = accessions[start:start + 800]
                placeholders = ",".join("?" for _ in batch)
                query = (
                    "SELECT accession, record_json, uniprot_release "
                    f"FROM accession_records WHERE accession IN ({placeholders})"
                )
                for accession, record_json, current_release in connection.execute(query, batch):
                    try:
                        record = json.loads(record_json)
                    except (TypeError, ValueError, json.JSONDecodeError):
                        continue
                    if isinstance(record, dict):
                        output[str(accession)] = {str(k): str(v) for k, v in record.items()}
                        release = str(current_release or release)
    except (OSError, sqlite3.Error) as exc:
        print(f"WARNING: The reusable UniProt functional-record cache could not be read ({exc}); online retrieval will continue.", flush=True)
    return output, release


def _cache_functional_records(
    path: Path, rows: dict[str, dict[str, str]], release: str
) -> None:
    if not rows:
        return
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    payload = [
        (accession, json.dumps(row, ensure_ascii=False, separators=(",", ":")), release or "", timestamp)
        for accession, row in rows.items()
    ]
    try:
        with _open_functional_record_cache(path) as connection:
            connection.executemany(
                "INSERT OR REPLACE INTO accession_records "
                "(accession, record_json, uniprot_release, updated_at) VALUES (?, ?, ?, ?)",
                payload,
            )
            connection.commit()
    except (OSError, sqlite3.Error) as exc:
        # A cache-write problem must not invalidate records that are already in
        # memory for the current analysis.
        print(f"WARNING: Retrieved UniProt records could not be checkpointed ({exc}); this run will still use them.", flush=True)


def fetch_accessions(
    accessions: Iterable[str], *, output_dir: Path | None = None
) -> tuple[dict[str, dict[str, str]], str]:
    values = list(dict.fromkeys(a for a in accessions if a))
    total = len(values)
    if not total:
        return {}, ""
    cache_path = _functional_record_cache_path()
    output, release = _load_cached_functional_records(cache_path, values)
    cached_at_start = len(output)
    pending = [accession for accession in values if accession not in output]
    if total:
        if cached_at_start:
            print(
                f"Resuming UniProt functional annotation: {cached_at_start:,}/{total:,} DIAMOND-matched protein records "
                f"were recovered from the shared checkpoint; {len(pending):,} remain.",
                flush=True,
            )
        else:
            print(f"Downloading UniProt functional records for {total:,} DIAMOND-matched proteins...", flush=True)

    completed = cached_at_start
    last_milestone = -1
    last_error: Exception | None = None

    def update_retrieval_progress() -> None:
        nonlocal last_milestone
        ratio = (completed / total) if total else 1.0
        _set_progress(
            overall=52 + ratio * 7, phase="Retrieving UniProt functional records",
            phase_percent=ratio * 100, current=completed, total=total, unit="proteins",
            detail=(
                f"{len(output):,}/{total:,} functional records available | "
                f"shared checkpoint; {max(0, total - len(output)):,} still missing"
            ),
        )
        milestone = min(10, int(ratio * 10))
        if milestone > last_milestone:
            print(
                f"UniProt functional-record milestone: {completed:,}/{total:,} proteins resolved or requested "
                f"({ratio * 100:.0f}%); {len(output):,} records safely available.",
                flush=True,
            )
            last_milestone = milestone

    def retrieve_batch(batch: list[str]) -> bool:
        nonlocal release, last_error
        query = " OR ".join(f"accession:{item}" for item in batch)
        try:
            rows, current_release = uniprot_search(
                query, reviewed_only=False, size=max(50, len(batch) * 2)
            )
        except Exception as exc:
            last_error = exc
            return False
        release = current_release or release
        received: dict[str, dict[str, str]] = {}
        for row in rows:
            accession = row_accession(row)
            if accession:
                received[accession] = row
                output[accession] = row
        _cache_functional_records(cache_path, received, current_release or release)
        return True

    update_retrieval_progress()
    interrupted: list[str] = []
    for start in range(0, len(pending), 40):
        batch = pending[start:start + 40]
        if not retrieve_batch(batch):
            interrupted = pending[start:]
            print(
                f"WARNING: UniProt remained unavailable after automatic reconnect attempts. "
                f"The {len(output):,} records already received are safely checkpointed; retrying the unfinished portion with smaller requests.",
                flush=True,
            )
            break
        completed += len(batch)
        update_retrieval_progress()
        if start + 40 < len(pending):
            time.sleep(0.12)

    # One conservative reconnect pass uses smaller requests. If the service is
    # still unavailable, stop making network calls and continue with the safe
    # checkpoint; a later run resumes only the remaining accessions.
    if interrupted:
        for start in range(0, len(interrupted), 10):
            batch = interrupted[start:start + 10]
            if not retrieve_batch(batch):
                interrupted = interrupted[start:]
                break
            completed += len(batch)
            update_retrieval_progress()
            if start + 10 < len(interrupted):
                time.sleep(0.20)
        else:
            interrupted = []

    missing = [accession for accession in values if accession not in output]
    # Do not report 100% when the network stopped mid-retrieval. Downstream
    # phases may still continue with a partial checkpoint, and their own
    # progress updates will take over from this accurate availability count.
    completed = total - len(missing)
    update_retrieval_progress()
    summary = {
        "requested_accessions": total,
        "records_reused_from_cache": cached_at_start,
        "records_available": len(output),
        "records_missing": len(missing),
        "missing_accessions": missing,
        "uniprot_release": release,
        "cache_path": str(cache_path),
        "network_interrupted": bool(interrupted),
        "last_network_error": str(last_error or ""),
    }
    _record_library_entry(
        "UniProt functional records by accession",
        cache_path,
        {"records_available_for_this_run": len(output), "release": release},
    )
    if output_dir is not None:
        write_json_atomic(Path(output_dir) / "uniprot_functional_record_retrieval.json", summary)
        if missing:
            (Path(output_dir) / "uniprot_functional_records_missing.tsv").write_text(
                "accession\n" + "\n".join(missing) + "\n", encoding="utf-8"
            )

    if missing and output:
        print(
            f"WARNING: UniProt functional retrieval is temporarily partial: {len(output):,}/{total:,} records are available and "
            f"{len(missing):,} remain. The combined analysis will continue with the available annotations; rerunning later resumes only the missing records.",
            flush=True,
        )
    elif total:
        print(f"UniProt functional retrieval complete: {len(output):,}/{total:,} records available.", flush=True)
    if total and not output:
        raise RuntimeError(
            "UniProt functional records could not be retrieved and no reusable checkpoint exists. "
            "Check the connection and rerun; DIAMOND results and any future successful batches will be retained."
        ) from last_error
    return output, release


def write_tsv(path: Path, rows: list[dict[str, str]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fields})


def get_analysis_gene_ids(mode: str, cfg: dict) -> list[str]:
    if mode == "enrichment":
        return read_first_column(Path(cfg["result_file"]), str(cfg.get("result_gene_column", "gene_id")))
    if mode == "network":
        return read_first_column(Path(cfg["expression_file"]), str(cfg.get("gene_column", "")))
    if mode == "combined":
        enrichment_genes = read_first_column(
            Path(cfg["result_file"]), str(cfg.get("result_gene_column", "gene_id"))
        )
        network_genes = read_first_column(
            Path(cfg["expression_file"]), str(cfg.get("gene_column", ""))
        )
        return list(dict.fromkeys([*enrichment_genes, *network_genes]))
    raise ValueError(f"Online functional annotation is not supported for mode: {mode}")


def annotate(mode: str, config_path: Path) -> int:
    print(f"Online annotation engine build: {ENGINE_VERSION}", flush=True)
    _set_progress(overall=4, phase="Preparing online annotation", phase_percent=0, detail="Reading analysis configuration")
    cfg = read_json(config_path)
    if not as_bool(cfg.get("online_annotation_enabled"), False):
        return 0
    out_dir = Path(cfg["output_dir"])
    functional_dir = out_dir / ("Gene-to-term mapping (online)" if mode == "enrichment" else "Functional annotation")
    functional_dir.mkdir(parents=True, exist_ok=True)
    input_mode = str(cfg.get("annotation_input_mode", "gene_ids")).strip().lower()
    database = str(cfg.get("annotation_database", "uniprot_reviewed")).strip().lower()
    organism = str(cfg.get("annotation_organism", "")).strip()
    refresh = as_bool(cfg.get("annotation_refresh_database"), False)
    evalue = float(cfg.get("annotation_evalue", 1e-5))
    min_identity = float(cfg.get("annotation_min_identity", 30.0))
    gene_ids = get_analysis_gene_ids(mode, cfg)
    if not gene_ids:
        raise ValueError("No gene identifiers were found in the analysis input table.")
    _set_progress(
        overall=7, phase="Preparing gene identifiers", phase_percent=100,
        current=len(gene_ids), total=len(gene_ids), unit="genes",
        detail=f"{len(gene_ids):,} analysis genes loaded",
    )

    # Reconnect downstream IDs to the original RNA-processing annotation.  This is the
    # important bridge for bacterial projects where DE gene_id values are local locus
    # tags, sanitized GFF IDs, RefSeq protein IDs, or another alias that is not itself a
    # UniProt primary accession.
    bridge_tables, discovered_fastas, related_configs = discover_identifier_context(mode, cfg, config_path)
    aliases_by_gene, coordinates, bridge_sources = build_identifier_bridge(gene_ids, bridge_tables)
    write_identifier_bridge(functional_dir / "identifier_bridge.tsv", aliases_by_gene, bridge_sources)
    extra_aliases = sum(max(0, len(values) - 1) for values in aliases_by_gene.values())
    _set_progress(
        overall=10, phase="Building identifier bridge", phase_percent=100,
        current=len(gene_ids), total=len(gene_ids), unit="genes",
        detail=f"{extra_aliases:,} additional aliases connected to {len(gene_ids):,} genes",
    )
    if bridge_sources:
        print(
            f"Identifier bridge: {len(bridge_sources)} local annotation source(s) connected {extra_aliases} additional aliases to {len(gene_ids)} analysis genes.",
            flush=True,
        )
    else:
        print("Identifier bridge: no retained RNA-processing annotation source was discovered; using analysis gene IDs directly.", flush=True)
    print(
        f"Reference rescue context: coordinates available for {len(coordinates)}/{len(gene_ids)} analysis genes; "
        f"{len(discovered_fastas)} candidate reference FASTA file(s) discovered.",
        flush=True,
    )
    if discovered_fastas:
        for path in discovered_fastas[:6]:
            print(f"Reference rescue FASTA: {path}", flush=True)

    annotations_by_gene: dict[str, dict[str, str]] = {}
    go_rows: list[dict[str, str]] = []
    matched: set[str] = set()
    release = ""
    db_metadata: dict[str, str] = {}
    resolved_taxid = ""
    database_used = database
    automatic_reference_fasta = ""
    automatic_sequence_genes: set[str] = set()
    explicit_sequence_genes: set[str] = set()
    local_annotations, local_go_rows, local_function_genes = extract_retained_annotation(
        gene_ids, aliases_by_gene, bridge_tables
    )

    def add_annotation(annotation: dict[str, str], terms: list[dict[str, str]]) -> None:
        gene_id = annotation["gene_id"]
        existing = annotations_by_gene.get(gene_id)
        # Prefer an annotation carrying GO terms over an earlier identifier hit with no
        # GO terms. Otherwise preserve the direct identifier assignment as the primary row.
        if existing is None or (terms and not existing.get("go_ids", "")):
            annotations_by_gene[gene_id] = annotation
        go_rows.extend(terms)
        matched.add(gene_id)

    if input_mode == "gene_ids":
        reviewed_only = database != "uniprot_all"
        _set_progress(
            overall=12, phase="Organism-specific identifier lookup", phase_percent=0,
            current=0, total=0, unit="genes", detail=f"Querying UniProt identifiers for {len(gene_ids):,} genes",
        )
        row_map, release, db_label, resolved_taxid = lookup_gene_ids(
            gene_ids, organism, reviewed_only, aliases_by_gene, refresh=refresh
        )
        _set_progress(
            overall=18, phase="Organism-specific identifier lookup", phase_percent=100,
            current=len(row_map), total=len(gene_ids), unit="genes",
            detail=f"{len(row_map):,}/{len(gene_ids):,} genes matched directly",
        )
        database_used = db_label
        for gene_id in gene_ids:
            row = row_map.get(gene_id)
            if not row:
                continue
            annotation, terms = row_to_annotation(gene_id, row, method="identifier lookup via local annotation bridge", database=db_label)
            add_annotation(annotation, terms)

        # Preserve explicit function/GO information already present in the user's retained
        # GFF/GTF/gene metadata. This is the most strain-specific evidence available and
        # avoids declaring a gene "unmatched" merely because UniProt lacks that strain.
        local_terms_by_gene: dict[str, list[dict[str, str]]] = defaultdict(list)
        for term in local_go_rows:
            local_terms_by_gene[term["gene_id"]].append(term)
        for annotation in local_annotations:
            add_annotation(annotation, local_terms_by_gene.get(annotation["gene_id"], []))
        if local_function_genes:
            print(
                f"Retained-reference annotation rescue: {len(local_function_genes):,}/{len(gene_ids):,} genes have local functional names/IDs; "
                f"{len({row['gene_id'] for row in local_go_rows}):,} genes carry explicit GO terms in retained annotation.",
                flush=True,
            )

        # If organism-specific identifier matching is incomplete, automatically reuse the
        # retained RNA-processing genome and gene coordinates.  The temporary queries use
        # the analysis gene_id as their FASTA identifier, so DIAMOND results reconnect to
        # the DE table without requiring users to rewrite FASTA headers by hand.
        genes_with_go = {row["gene_id"] for row in go_rows}
        sequence_candidates = [gene for gene in gene_ids if gene not in genes_with_go]
        if sequence_candidates and coordinates and discovered_fastas:
            query_fasta: Path | None = None
            query_genes: set[str] = set()
            for reference_fasta in discovered_fastas:
                candidate, genes_found = extract_reference_gene_queries(
                    reference_fasta,
                    sequence_candidates,
                    coordinates,
                    functional_dir / "automatic_reference_gene_sequences.fasta",
                )
                if candidate is not None and genes_found:
                    query_fasta = candidate
                    query_genes = genes_found
                    automatic_reference_fasta = os.fspath(reference_fasta)
                    break
            if query_fasta is not None and query_genes:
                print(
                    f"Automatic sequence fallback: extracted {len(query_genes)} genes from the retained RNA-processing reference and will search the selected organism UniProtKB proteins with DIAMOND (reviewed + TrEMBL), with global Swiss-Prot only as a fallback.",
                    flush=True,
                )
                seq_annotations, seq_terms, seq_matched, seq_release, sequence_metadata = annotate_by_sequence(
                    query_fasta,
                    "nucleotide_fasta",
                    [gene for gene in gene_ids if gene in query_genes],
                    functional_dir,
                    refresh,
                    evalue,
                    min_identity,
                    method_label="automatic retained-reference sequence similarity (DIAMOND)",
                    organism=organism,
                    resolved_taxid=resolved_taxid,
                )
                db_metadata.update(sequence_metadata)
                release = seq_release or release
                automatic_sequence_genes = set(seq_matched)
                terms_by_gene: dict[str, list[dict[str, str]]] = defaultdict(list)
                for term in seq_terms:
                    terms_by_gene[term["gene_id"]].append(term)
                for annotation in seq_annotations:
                    add_annotation(annotation, terms_by_gene.get(annotation["gene_id"], []))
                if seq_matched:
                    database_used = f"{db_label} + {sequence_metadata.get('sequence_database', 'UniProtKB/Swiss-Prot')} automatic sequence fallback"
            else:
                print(
                    "Automatic sequence fallback was considered, but no requested genes could be reconstructed from the discovered reference FASTA and coordinates.",
                    flush=True,
                )
    elif input_mode in {"protein_fasta", "nucleotide_fasta"}:
        sequence_path = Path(str(cfg.get("annotation_sequence_file", "")))
        if not sequence_path.is_file():
            raise ValueError("A FASTA file is required for sequence-based online annotation.")
        normalized_queries, explicit_sequence_genes = normalize_user_sequence_queries(
            sequence_path,
            gene_ids,
            aliases_by_gene,
            functional_dir / "normalized_annotation_queries.fasta",
        )
        print(
            f"Sequence identifier bridge: {len(explicit_sequence_genes)}/{len(gene_ids)} analysis genes were connected to FASTA records.",
            flush=True,
        )
        seq_annotations, seq_terms, seq_matched, release, db_metadata = annotate_by_sequence(
            normalized_queries,
            input_mode,
            gene_ids,
            functional_dir,
            refresh,
            evalue,
            min_identity,
            method_label="sequence similarity (DIAMOND) via identifier bridge",
            organism=organism,
            resolved_taxid=resolved_taxid,
        )
        terms_by_gene: dict[str, list[dict[str, str]]] = defaultdict(list)
        for term in seq_terms:
            terms_by_gene[term["gene_id"]].append(term)
        for annotation in seq_annotations:
            add_annotation(annotation, terms_by_gene.get(annotation["gene_id"], []))
        local_terms_by_gene: dict[str, list[dict[str, str]]] = defaultdict(list)
        for term in local_go_rows:
            local_terms_by_gene[term["gene_id"]].append(term)
        for annotation in local_annotations:
            add_annotation(annotation, local_terms_by_gene.get(annotation["gene_id"], []))
        database_used = f"{db_metadata.get('sequence_database', 'UniProtKB/Swiss-Prot')} sequence similarity"
        missing_headers = [gene for gene in gene_ids if gene not in explicit_sequence_genes]
        if missing_headers:
            (functional_dir / "FASTA identifiers not connected.tsv").write_text(
                "gene_id\n" + "\n".join(missing_headers) + "\n", encoding="utf-8"
            )
    else:
        raise ValueError(f"Unknown annotation input mode: {input_mode}")

    go_rows = list({(r["gene_id"], r["term_id"], r["term_name"], r["aspect"]): r for r in go_rows}.values())
    annotations = [annotations_by_gene[gene] for gene in gene_ids if gene in annotations_by_gene]
    annotation_fields = [
        "gene_id", "matched_accession", "entry_name", "gene_names", "protein_name", "organism_name", "organism_id",
        "go_ids", "go_bp", "go_mf", "go_cc", "annotation_method", "database", "sequence_identity_percent", "sequence_evalue",
    ]
    write_tsv(functional_dir / "gene_annotations.tsv", annotations, annotation_fields)
    write_tsv(functional_dir / "gene_to_go.tsv", go_rows, ["gene_id", "term_id", "term_name", "source", "aspect"])
    genes_with_go = {row["gene_id"] for row in go_rows}
    unmatched = []
    for gene in gene_ids:
        if gene in matched:
            continue
        unmatched.append({
            "gene_id": gene,
            "reason": "No retained functional annotation or accepted UniProt/DIAMOND annotation at the configured thresholds",
            "next_step": "Keep as unannotated; optionally provide a curated offline mapping or use a broader orthology backend for exploratory annotation",
        })
    without_go = []
    for gene in gene_ids:
        if gene in genes_with_go:
            continue
        without_go.append({
            "gene_id": gene,
            "has_local_function_annotation": "yes" if gene in local_function_genes else "no",
            "has_any_annotation": "yes" if gene in matched else "no",
            "reason": "No explicit GO term recovered from retained annotation or accepted UniProt homolog",
        })
    write_tsv(functional_dir / "unmatched_genes.tsv", unmatched, ["gene_id", "reason", "next_step"])
    write_tsv(functional_dir / "genes_without_go.tsv", without_go, ["gene_id", "has_local_function_annotation", "has_any_annotation", "reason"])

    retrieval_summary_path = functional_dir / "uniprot_functional_record_retrieval.json"
    retrieval_summary: dict[str, object] = {}
    if retrieval_summary_path.is_file():
        try:
            retrieval_summary = {
                key: value
                for key, value in read_json(retrieval_summary_path).items()
                if key != "missing_accessions"
            }
        except Exception:
            retrieval_summary = {}
    report = {
        "annotation_input_mode": input_mode,
        "database": database_used,
        "database_requested": database,
        "database_used": database_used,
        "organism": organism,
        "resolved_taxonomy_id": resolved_taxid,
        "genes_requested": len(gene_ids),
        "genes_annotated": len(matched),
        "genes_with_go": len(genes_with_go),
        "genes_without_go": len(gene_ids) - len(genes_with_go),
        "genes_with_retained_local_annotation": len(local_function_genes),
        "genes_with_retained_local_go": len({row["gene_id"] for row in local_go_rows}),
        "genes_unmatched": len(gene_ids) - len(matched),
        "go_links": len(go_rows),
        "uniprot_release": release or db_metadata.get("uniprot_release", ""),
        "uniprot_functional_record_retrieval": retrieval_summary,
        "database_cache": str(DATABASE_LIBRARY_ROOT) if (input_mode != "gene_ids" or automatic_sequence_genes) else "",
        "sequence_evalue": evalue if (input_mode != "gene_ids" or automatic_sequence_genes) else None,
        "minimum_identity_percent": min_identity if (input_mode != "gene_ids" or automatic_sequence_genes) else None,
        "identifier_bridge_sources": bridge_sources,
        "identifier_bridge_configurations": [os.fspath(path) for path in related_configs],
        "additional_local_aliases": extra_aliases,
        "coordinate_genes_available": len(coordinates),
        "candidate_reference_fastas": [os.fspath(path) for path in discovered_fastas],
        "automatic_reference_fasta": automatic_reference_fasta,
        "automatic_sequence_genes": len(automatic_sequence_genes),
        "explicit_sequence_genes_connected": len(explicit_sequence_genes),
    }
    write_json_atomic(functional_dir / "annotation_report.json", report)

    if mode in {"enrichment", "combined"}:
        mapping_path = functional_dir / "gene_to_go.tsv"
        if not go_rows:
            if not matched:
                raise RuntimeError(
                    "Online gene-to-term mapping could not annotate any analysis genes after organism-specific UniProt lookup, local RNA-processing identifier bridging, and automatic retained-reference sequence fallback when reference files were available. "
                    "Inspect 'Gene-to-term mapping (online)/identifier_bridge.tsv', 'annotation_report.json', and 'unmatched_genes.tsv'. Verify the organism/taxonomy ID only if the identifier bridge contains the expected locus tags."
                )
            raise RuntimeError(
                "Gene identifiers were connected to UniProt, but no GO terms were recovered even after the available automatic sequence fallback. "
                "Review 'Gene-to-term mapping (online)/gene_annotations.tsv' and annotation_report.json, or use an offline gene-to-GO mapping."
            )
        cfg["mapping_file"] = str(mapping_path)
        cfg["annotation_source"] = "GO"
        cfg["mapping_gene_column"] = "gene_id"
        cfg["mapping_term_column"] = "term_id"
        cfg["mapping_name_column"] = "term_name"
        cfg["mapping_source_column"] = "source"
    if mode in {"network", "combined"}:
        cfg["annotation_table_file"] = str(functional_dir / "gene_annotations.tsv")
        cfg["annotation_mapping_file"] = str(functional_dir / "gene_to_go.tsv")
    write_json_atomic(config_path, cfg)
    _set_progress(
        overall=60, phase="Online annotation complete", phase_percent=100,
        current=len(matched), total=len(gene_ids), unit="genes",
        detail=f"{len(matched):,}/{len(gene_ids):,} genes annotated | {len(go_rows):,} GO links",
    )
    print(
        f"Gene annotation complete: {len(matched)}/{len(gene_ids)} genes annotated; {len(go_rows)} GO links recovered.",
        flush=True,
    )
    return 0

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Online bacterial functional annotation for GO and network modules")
    parser.add_argument("mode", nargs="?", choices=["enrichment", "network", "combined"])
    parser.add_argument("config", nargs="?")
    parser.add_argument("--test-connection", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    _ensure_database_library()
    if args.test_connection:
        return test_connection()
    if not args.mode or not args.config:
        raise SystemExit("MODE and CONFIG are required unless --test-connection is used.")
    try:
        return annotate(args.mode, Path(args.config))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:1000] if exc.fp else ""
        _set_progress(status="error", phase="Online annotation failed", detail=f"HTTP {exc.code}: {detail or exc.reason}")
        eprint(f"ERROR: Online database request failed with HTTP {exc.code}: {detail or exc.reason}")
        return 2
    except Exception as exc:
        label = "Online gene-to-term mapping" if args.mode in {"enrichment", "combined"} else "Functional annotation"
        _set_progress(status="error", phase=f"{label} failed", detail=str(exc))
        eprint(f"ERROR: {label} failed: {exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
