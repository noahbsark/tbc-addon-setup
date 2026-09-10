#!/usr/bin/env python3
"""Build both installable addon ZIPs from source and a generated Lua snapshot."""
import argparse
import gzip
import hashlib
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "nightslayer-rating/source"
ADDON = SOURCE / "Addon/NightslayerRating"


def build(data_path: Path) -> list[Path]:
    data = data_path.read_bytes()
    if data_path.suffix == ".gz":
        data = gzip.decompress(data)
    if b"NightslayerRatingData = {" not in data or b"previousSeason = " not in data:
        raise ValueError("Expected a generated season-aware Lua snapshot")
    toc = (ADDON / "NightslayerRating.toc").read_text()
    version = re.search(r"^## Version: (.+)$", toc, re.MULTILINE).group(1)
    output = ROOT / "nightslayer-rating/downloads"
    output.mkdir(exist_ok=True)
    artifacts = []
    for flavor in ("AddonOnly", "Windows"):
        artifact = output / f"NightslayerRating-{version}-{flavor}.zip"
        root = ADDON if flavor == "AddonOnly" else SOURCE
        prefix = "NightslayerRating" if flavor == "AddonOnly" else f"NightslayerRating-{version}"
        files = {f"{prefix}/{p.relative_to(root).as_posix()}": p.read_bytes()
                 for p in sorted(root.rglob("*")) if p.is_file()}
        data_name = f"{prefix}/Data.lua" if flavor == "AddonOnly" else f"{prefix}/Addon/NightslayerRating/Data.lua"
        files[data_name] = data
        if flavor == "Windows":
            files[f"{prefix}/LICENSE.txt"] = (ADDON / "LICENSE.txt").read_bytes()
        with ZipFile(artifact, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
            for name, payload in sorted(files.items()):
                info = ZipInfo(name, date_time=(2026, 9, 10, 0, 0, 0))
                info.compress_type = ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, payload)
        artifacts.append(artifact)
    checksums = "\n".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  downloads/{p.name}" for p in artifacts)
    (ROOT / "nightslayer-rating/checksums.txt").write_text(checksums + "\n")
    return artifacts


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, required=True)
    args = parser.parse_args()
    for artifact in build(args.data):
        print(f"{artifact.name}: {artifact.stat().st_size:,} bytes")
