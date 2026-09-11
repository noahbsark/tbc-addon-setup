#!/usr/bin/env python3
"""Build both ZIPs and an offline companion cache from the same JSON snapshot."""
import argparse
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import time
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "nightslayer-rating/source"
ADDON = SOURCE / "Addon/NightslayerRating"


def publisher_module():
    spec = importlib.util.spec_from_file_location("build_shared_cache", ROOT / "central-rating-data/build_shared_cache.py")
    publisher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(publisher)
    return publisher


def validate_snapshot(snapshot):
    if snapshot.get("version") != 6 or snapshot.get("region") != "US" or not snapshot.get("players") or snapshot.get("keyAlgorithm") != "nsr-h4-v1":
        raise ValueError("Expected a complete v6 US JSON snapshot")
    season = snapshot.get("season")
    if type(season) is not int or not 3 <= season <= 20 or snapshot.get("previousSeason") != season - 1:
        raise ValueError("Invalid snapshot season")
    for field in ("generated", "leaderboardUpdated"):
        if type(snapshot.get(field)) is not int or not 0 < snapshot[field] <= time.time() + 3600:
            raise ValueError(f"Invalid {field}")
    players = snapshot["players"]
    if not isinstance(players, dict) or len(players) > 100000:
        raise ValueError("Invalid snapshot player table")
    for key, player in players.items():
        if not re.fullmatch(r"[a-f0-9]{16}", key) or not isinstance(player, dict):
            raise ValueError("Invalid snapshot player")
        for field in ("current", "bestSeen", "previous"):
            ratings = player.get(field, {})
            if not isinstance(ratings, dict) or any(str(b) not in ("2", "3", "5") or type(r) is not int or
                                                   not 0 <= r <= 10000 for b, r in ratings.items()):
                raise ValueError("Invalid rating map")
    counts = snapshot.get("counts", {})
    if set(counts) != {"Nightslayer", "Dreamscythe"} or any(type(v) is not int or v < 0 for v in counts.values()) or sum(counts.values()) != len(players):
        raise ValueError("Snapshot realm counts do not match its players")
    for season_key, brackets in snapshot.get("cutoffs", {}).items():
        if not str(season_key).isdigit() or not 1 <= int(season_key) <= 20 or not isinstance(brackets, dict):
            raise ValueError("Invalid cutoff season")
        for bracket, entry in brackets.items():
            thresholds = entry.get("thresholds", []) if isinstance(entry, dict) else []
            if str(bracket) not in ("2", "3", "5") or len(thresholds) != 5 or any(type(v) is not int or not 1 <= v <= 10000 for v in thresholds) or thresholds != sorted(thresholds, reverse=True):
                raise ValueError("Invalid cutoff thresholds")
            stamp = entry.get("updated")
            if type(stamp) is not int or not 0 < stamp <= time.time() + 3600:
                raise ValueError("Invalid cutoff source date")
    frozen = json.loads((SOURCE / "Updater/Season2Cutoffs.json").read_text())
    for bracket in ("2", "3", "5"):
        if snapshot.get("cutoffs", {}).get("2", {}).get(bracket, {}).get("thresholds") != frozen["2"][bracket]["thresholds"]:
            raise ValueError("Snapshot changed the frozen S2 cutoffs")


def source_version():
    version = re.search(r"^## Version: (.+)$", (ADDON / "NightslayerRating.toc").read_text(), re.MULTILINE).group(1)
    if not re.fullmatch(r"\d{1,3}\.\d{1,3}\.\d{1,3}", version):
        raise ValueError("Invalid addon version")
    if f'UI.version = "{version}"' not in (ADDON / "Options.lua").read_text() or \
       f"$UpdaterVersion = '{version}'" not in (SOURCE / "Updater/NightslayerRatingUpdater.ps1").read_text():
        raise ValueError("Addon and updater source versions must match the TOC")
    return version


def build(snapshot_path: Path) -> list[Path]:
    encoded = snapshot_path.read_bytes()
    if snapshot_path.suffix == ".gz":
        encoded = gzip.decompress(encoded)
    snapshot = json.loads(encoded)
    validate_snapshot(snapshot)
    data = publisher_module().render_lua(snapshot).encode("utf-8")
    bundled_snapshot = gzip.compress(encoded, compresslevel=9, mtime=0)
    version = source_version()
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
            files[f"{prefix}/Updater/BundledSnapshot.json.gz"] = bundled_snapshot
        with ZipFile(artifact, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
            for name, payload in sorted(files.items()):
                info = ZipInfo(name, date_time=(2026, 9, 11, 0, 0, 0))
                info.compress_type = ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, payload)
        artifacts.append(artifact)
    checksums = "\n".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  downloads/{p.name}" for p in artifacts)
    (ROOT / "nightslayer-rating/checksums.txt").write_text(checksums + "\n")
    windows = next(path for path in artifacts if path.name.endswith("-Windows.zip"))
    manifest = {"version": version, "archive": windows.name,
                "sha256": hashlib.sha256(windows.read_bytes()).hexdigest()}
    (ROOT / "nightslayer-rating/latest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    page_path = ROOT / "nightslayer-rating/index.html"
    page = page_path.read_text()
    page = re.sub(r"NightslayerRating-\d+\.\d+\.\d+", f"NightslayerRating-{version}", page)
    page = re.sub(r"\bVersion \d+\.\d+\.\d+", f"Version {version}", page)
    page = re.sub(r"\bv\d+\.\d+\.\d+", f"v{version}", page)
    page = re.sub(r"<strong>[\d,]+</strong><span>Players in this release’s shared snapshot</span>",
                  f"<strong>{len(snapshot['players']):,}</strong><span>Players in this release’s shared snapshot</span>", page)
    page = re.sub(r"(?<=<strong>Windows bundle SHA-256</strong><br><code>)[a-f0-9]{64}", manifest["sha256"], page)
    page_path.write_text(page)
    verify()
    return artifacts


def verify():
    """Check the release as shipped, including every TOC dependency and source file."""
    version = source_version()
    release = ROOT / "nightslayer-rating"
    manifest = json.loads((release / "latest.json").read_text())
    if manifest.get("version") != version or manifest.get("archive") != f"NightslayerRating-{version}-Windows.zip":
        raise ValueError("Release manifest does not match the source version")
    checksums = []
    data_copies = []
    snapshot = None
    for flavor in ("AddonOnly", "Windows"):
        archive_path = release / "downloads" / f"NightslayerRating-{version}-{flavor}.zip"
        sha = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        checksums.append(f"{sha}  downloads/{archive_path.name}")
        if flavor == "Windows" and sha != manifest.get("sha256"):
            raise ValueError("Windows ZIP does not match the upgrade checksum")
        with ZipFile(archive_path) as archive:
            if archive.testzip() is not None or len(archive.namelist()) != len(set(archive.namelist())):
                raise ValueError("Invalid or duplicate ZIP entries")
            root = ADDON if flavor == "AddonOnly" else SOURCE
            prefix = "NightslayerRating" if flavor == "AddonOnly" else f"NightslayerRating-{version}"
            expected = {f"{prefix}/{p.relative_to(root).as_posix()}": p.read_bytes()
                        for p in root.rglob("*") if p.is_file()}
            data_name = f"{prefix}/Data.lua" if flavor == "AddonOnly" else f"{prefix}/Addon/NightslayerRating/Data.lua"
            data_copies.append(archive.read(data_name))
            expected[data_name] = data_copies[-1]
            if flavor == "Windows":
                bundled_name = f"{prefix}/Updater/BundledSnapshot.json.gz"
                expected[bundled_name] = archive.read(bundled_name)
                expected[f"{prefix}/LICENSE.txt"] = (ADDON / "LICENSE.txt").read_bytes()
                snapshot = json.loads(gzip.decompress(expected[bundled_name]))
                validate_snapshot(snapshot)
            if set(expected) != set(archive.namelist()):
                raise ValueError("ZIP file list does not match the release source")
            for name, payload in expected.items():
                if archive.read(name) != payload:
                    raise ValueError(f"Stale packaged source: {name}")
            toc_prefix = prefix if flavor == "AddonOnly" else f"{prefix}/Addon/NightslayerRating"
            for line in (ADDON / "NightslayerRating.toc").read_text().splitlines():
                if line.strip() and not line.startswith("#") and f"{toc_prefix}/{line.strip()}" not in expected:
                    raise ValueError(f"Missing TOC dependency: {line}")
    expected_data = publisher_module().render_lua(snapshot).encode("utf-8")
    if any(data != expected_data for data in data_copies):
        raise ValueError("Addon data and companion bootstrap snapshot differ")
    if (release / "checksums.txt").read_text() != "\n".join(checksums) + "\n":
        raise ValueError("Release checksum list does not match the ZIPs")
    page = (release / "index.html").read_text()
    if f'<strong>Windows bundle SHA-256</strong><br><code>{manifest["sha256"]}</code>' not in page:
        raise ValueError("Download page checksum differs from the release")
    for flavor in ("AddonOnly", "Windows"):
        if f'downloads/NightslayerRating-{version}-{flavor}.zip' not in page:
            raise ValueError("Download page points to another version")
    return version


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.snapshot:
        for artifact in build(args.snapshot):
            print(f"{artifact.name}: {artifact.stat().st_size:,} bytes")
    elif args.verify:
        print(f"Verified Nightslayer Rating {verify()}: source, ZIPs, bootstrap and manifest agree")
    else:
        parser.error("Provide --snapshot to build, or --verify to check the committed release")
