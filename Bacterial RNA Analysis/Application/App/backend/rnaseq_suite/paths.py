from __future__ import annotations

import os
import re
from pathlib import Path


_WINDOWS_DRIVE = re.compile(r"^([A-Za-z]):[\\/](.*)$")
_WSL_UNC = re.compile(
    r"^\\\\wsl(?:(?:\.localhost)|\$)?\\[^\\]+\\(.*)$", re.IGNORECASE
)


def runtime_path(value: str | os.PathLike[str]) -> Path:
    """Convert a Windows path stored by the GUI into a WSL/native runtime path."""

    raw = os.fspath(value).strip().strip('"')
    match = _WINDOWS_DRIVE.match(raw)
    if match:
        drive, remainder = match.groups()
        remainder = remainder.replace("\\", "/")
        return Path(f"/mnt/{drive.lower()}/{remainder}")

    unc_match = _WSL_UNC.match(raw)
    if unc_match:
        return Path("/" + unc_match.group(1).replace("\\", "/"))

    return Path(raw).expanduser()


def safe_name(value: str, fallback: str = "item") -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", value.strip())
    cleaned = cleaned.strip("._-")
    return cleaned or fallback


def is_probably_fastq(path: Path) -> bool:
    name = path.name.lower()
    return name.endswith((".fastq", ".fq", ".fastq.gz", ".fq.gz"))


def is_probably_bam(path: Path) -> bool:
    return path.name.lower().endswith(".bam")
