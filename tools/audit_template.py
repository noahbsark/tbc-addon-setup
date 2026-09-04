#!/usr/bin/env python3
"""Fail the Pages build if the embedded WTF template exposes user data."""

from __future__ import annotations

import base64
import io
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
CHUNKS = sorted(ROOT.glob("template-chunk-*.js"))
MAX_ARCHIVE_BYTES = 10 * 1024 * 1024
MAX_EXPANDED_BYTES = 25 * 1024 * 1024

BANNED_FILES = {
    "Prat-3.0.lua",
    "Syndicator.lua",
    "WeakAurasArchive.lua",
    "WeakAurasOptions.lua",
    "DruidDEScore.lua",
    "TomTom.lua",
}

PRIVATE_PATTERNS = {
    "Discord invitation": re.compile(rb"(?:discord\.gg|discord(?:app)?\.com/invite)/", re.I),
    "email address": re.compile(rb"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.I),
    "WoW player GUID": re.compile(rb"Player-[0-9]+-[0-9A-F]+", re.I),
    "Windows user path": re.compile(rb"[A-Z]:\\Users\\[^\\\r\n]+", re.I),
    "BattleTag": re.compile(rb"\b[A-Z][A-Z0-9]{2,11}#[0-9]{4,10}\b", re.I),
}


def fail(message: str) -> None:
    raise SystemExit(f"Template privacy audit failed: {message}")


def embedded_zip() -> bytes:
    if len(CHUNKS) != 5:
        fail(f"expected 5 template chunks, found {len(CHUNKS)}")

    encoded: list[str] = []
    for path in CHUNKS:
        match = re.search(r'"([A-Za-z0-9+/=]+)"', path.read_text(encoding="utf-8"))
        if not match:
            fail(f"could not parse {path.name}")
        encoded.append(match.group(1))

    try:
        payload = base64.b64decode("".join(encoded), validate=True)
    except ValueError as exc:
        fail(f"invalid base64: {exc}")
    if not payload or len(payload) > MAX_ARCHIVE_BYTES:
        fail(f"archive size is invalid ({len(payload)} bytes)")
    return payload


def main() -> None:
    payload = embedded_zip()
    total = 0
    files = 0
    try:
        archive = zipfile.ZipFile(io.BytesIO(payload))
    except zipfile.BadZipFile as exc:
        fail(f"invalid ZIP: {exc}")

    for info in archive.infolist():
        path = PurePosixPath(info.filename)
        if path.is_absolute() or ".." in path.parts or "\\" in info.filename:
            fail(f"unsafe archive path: {info.filename!r}")
        if info.is_dir():
            continue
        if path.name in BANNED_FILES:
            fail(f"private or derived file is present: {path.name}")
        if "WTF" not in path.parts or "ACCOUNTNAME" not in path.parts:
            fail(f"unexpected non-template path: {info.filename!r}")

        total += info.file_size
        files += 1
        if total > MAX_EXPANDED_BYTES:
            fail("expanded archive is too large")

        content = archive.read(info)
        for label, pattern in PRIVATE_PATTERNS.items():
            if pattern.search(content):
                fail(f"{label} found in {info.filename!r}")

    if not files:
        fail("archive contains no files")
    if archive.testzip() is not None:
        fail("archive CRC validation failed")

    print(f"Template privacy audit passed: {files} files, {total} bytes")


if __name__ == "__main__":
    main()
