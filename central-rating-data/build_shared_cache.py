#!/usr/bin/env python3
"""Build the public, pseudonymous Nightslayer Rating snapshot.

The published file contains rating maps keyed by a deterministic four-part hash.
Raw character names are used transiently while reading IronForge responses but
are never written to the snapshot or logs.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import tempfile
import time
import unicodedata
from email.utils import parsedate_to_datetime
import urllib.error
import urllib.request
from urllib.parse import quote
from pathlib import Path
from typing import Any


DEFAULT_API_BASE = "https://ironforge.pro/api"
REALMS = {"nightslayer": "Nightslayer", "dreamscythe": "Dreamscythe"}
BRACKETS = (2, 3, 5)
MAX_SEASON = 20
HASH_ALGORITHM = "nsr-h4-v1"
HASH_MODULI = (65_521, 65_519, 65_497, 65_479)
HASH_BASES = (131, 137, 139, 149)
USER_AGENT = (
    "NightslayerRating/1.5.0 shared-cache publisher "
    "(+https://github.com/noahbsark/tbc-addon-setup)"
)
FROZEN_CUTOFFS_PATH = (
    Path(__file__).resolve().parents[1]
    / "nightslayer-rating/source/Updater/Season2Cutoffs.json"
)


def parse_cutoffs(payload: Any, checked: int) -> dict[str, Any]:
    """Read the same ordered five cutoff cards used by the IronForge UI."""
    rows = payload.get("cutoff") if isinstance(payload, dict) else None
    if not isinstance(rows, list) or len(rows) != 5:
        raise ValueError("expected all five cutoff tiers")
    thresholds = []
    for index, row in enumerate(rows):
        if not isinstance(row, list) or len(row) < 2:
            raise ValueError("invalid cutoff row")
        label = str(row[1])
        expected = ("Gladiator", "Gladiator", "Duelist", "Rival", "Challenger")[index]
        if (index == 0 and not label.endswith(" Gladiator")) or (index > 0 and label != expected):
            raise ValueError("unexpected cutoff tier order")
        value = row[0]
        if isinstance(value, bool) or not str(value).isdigit() or not 1 <= int(value) <= 10000:
            raise ValueError("invalid cutoff rating")
        thresholds.append(int(value))
    if thresholds != sorted(thresholds, reverse=True):
        raise ValueError("cutoffs must be descending")
    updated = int(parsedate_to_datetime(payload["updated"]).timestamp())
    if not 0 < updated <= checked + 3600:
        raise ValueError("invalid cutoff timestamp")
    return {"updated": updated, "checked": checked, "thresholds": thresholds}


def build_cutoffs(client: ApiClient, season: int, checked: int) -> dict[str, Any]:
    # Season 2 is frozen to the user's final US archive values. Never replace
    # it with current-season data, even after a future season rollover.
    cutoffs = json.loads(FROZEN_CUTOFFS_PATH.read_text(encoding="utf-8"))
    for target in sorted({season, season - 1} - {0, 2}):
        cutoffs[str(target)] = {}
        for bracket in BRACKETS:
            payload = client.get_json(f"anniversary/cutoffs/{target}/US/{bracket}/")
            # A malformed response fails this publication; the stable release
            # keeps its last good snapshot instead of publishing guessed colors.
            cutoffs[str(target)][str(bracket)] = parse_cutoffs(payload, checked)
    return cutoffs


def ascii_lower(value: str) -> str:
    return "".join(chr(ord(char) + 32) if "A" <= char <= "Z" else char for char in value)


def normalize_realm(value: str) -> str:
    return re.sub(r"[\s\-']", "", ascii_lower(value or ""))


def resolve_realm(value: str) -> str | None:
    return REALMS.get(normalize_realm(value))


def valid_player_name(value: str) -> bool:
    if not 2 <= len(value) <= 24:
        return False
    return all(unicodedata.category(char).startswith("L") for char in value)


def lookup_hash(realm: str, name: str) -> str:
    payload = f"{normalize_realm(realm)}|{ascii_lower(name)}".encode("utf-8")
    values = [0, 0, 0, 0]
    for byte in payload:
        for index, (base, modulus) in enumerate(zip(HASH_BASES, HASH_MODULI)):
            values[index] = (values[index] * base + byte) % modulus
    return "".join(f"{value:04x}" for value in values)


class ApiClient:
    def __init__(self, base_url: str, pause_seconds: float = 0.4) -> None:
        self.base_url = base_url.rstrip("/")
        self.pause_seconds = pause_seconds

    def get_json(self, path: str, *, allow_missing: bool = False) -> Any | None:
        url = f"{self.base_url}/{path.lstrip('/')}"
        request = urllib.request.Request(
            url,
            headers={"Accept": "application/json", "User-Agent": USER_AGENT},
        )
        delays = (1, 3, 8)
        for attempt, delay in enumerate(delays):
            try:
                with urllib.request.urlopen(request, timeout=45) as response:
                    payload = json.load(response)
                time.sleep(self.pause_seconds)
                return payload
            except urllib.error.HTTPError as exc:
                if allow_missing and exc.code in (404, 500):
                    return None
                if attempt == len(delays) - 1:
                    raise
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
                if attempt == len(delays) - 1:
                    raise
            time.sleep(delay)
        return None

    def get_profile(self, realm: str, name: str) -> Any:
        # One attempt per candidate. In particular, never retry a 429 here.
        path = f"anniversary/player/{quote(realm, safe='')}/{quote(name, safe='')}"
        request = urllib.request.Request(f"{self.base_url}/{path}", headers={
            "Accept": "application/json", "User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.load(response)
        finally:
            time.sleep(max(1.0, self.pause_seconds))


def peak_map(value: Any) -> dict[str, int]:
    if not isinstance(value, dict) or any(
        str(key) not in ("2", "3", "5") or type(rating) is not int or not 0 <= rating <= 10000
        for key, rating in value.items()
    ):
        raise ValueError("invalid exact peak map")
    return {str(key): rating for key, rating in value.items() if rating > 0}


def profile_state(row: Any, now: int) -> dict[str, Any]:
    """Only copy validated profile fields; never carry old current ratings forward."""
    if not isinstance(row, dict):
        raise ValueError("invalid profile cache row")
    result = {"exactBest": peak_map(row.get("exactBest", {}))}
    for field in ("exactFetchedAt", "profileAttemptAt", "profileRetryAfter"):
        stamp = row.get(field, 0)
        allowance = 7 * 86400 if field == "profileRetryAfter" else 3600
        if type(stamp) is not int or not 0 <= stamp <= now + allowance:
            raise ValueError("invalid profile cache timestamp")
        result[field] = stamp
    if result["exactBest"] and not result["exactFetchedAt"]:
        raise ValueError("undated exact peaks")
    return result


def enrich_profiles(client: ApiClient, snapshot: dict[str, Any], identities: dict,
                    previous: dict[str, Any] | None, limit: int, seconds: float) -> None:
    now = int(time.time())
    old_players = {}
    if previous is not None:
        if (previous.get("version") != 6 or previous.get("keyAlgorithm") != HASH_ALGORITHM
                or previous.get("region") != "US" or not isinstance(previous.get("players"), dict)
                or not 0 < previous.get("generated", 0) <= now + 3600
                or previous.get("season", 0) > snapshot["season"]):
            raise ValueError("invalid previous snapshot; refusing to reset shared peaks")
        old_players = previous["players"]
    players = snapshot["players"]
    for key, row in players.items():
        row.update(profile_state(old_players.get(key, {}), now))
    candidates = [key for key, row in players.items() if key in identities
                  and row["profileRetryAfter"] <= now
                  and (not row["exactFetchedAt"] or now - row["exactFetchedAt"] >= 7 * 86400)]
    # Untried before retries, with current ladder players first within each group.
    # Failed candidates receive a retry date and cannot monopolize later runs.
    candidates.sort(key=lambda key: (bool(players[key]["exactFetchedAt"]),
                                     players[key]["profileAttemptAt"],
                                     not bool(players[key]["current"]), key))
    stats = {"attempted": 0, "fetched": 0, "unavailable": 0, "failed": 0, "state": "complete"}
    deadline = time.monotonic() + max(0, seconds)
    consecutive_errors = 0
    for key in candidates[:max(0, limit)]:
        if time.monotonic() >= deadline:
            stats["state"] = "budget"
            break
        row = players[key]
        row["profileAttemptAt"] = int(time.time())
        stats["attempted"] += 1
        realm, name = identities[key]
        try:
            payload = client.get_profile(realm, name)
            raw_peaks = payload.get("bracket_best") if isinstance(payload, dict) else None
            if not isinstance(raw_peaks, dict):
                raise ValueError("missing profile peaks")
            # IronForge also returns a '10' slot. Only arena 2/3/5 belongs in
            # this addon's peak maps; validate those values without importing it.
            peaks = peak_map({str(key): value for key, value in raw_peaks.items()
                              if str(key) in ("2", "3", "5")})
        except urllib.error.HTTPError as error:
            if error.code == 404:
                row["profileRetryAfter"] = int(time.time()) + 7 * 86400
                stats["unavailable"] += 1
                consecutive_errors = 0
                continue
            row["profileRetryAfter"] = int(time.time()) + 6 * 3600
            stats["failed"] += 1
            consecutive_errors += 1
            if error.code == 429:
                stats["state"] = "throttled"
                break
        except (urllib.error.URLError, TimeoutError, ValueError, OSError):
            row["profileRetryAfter"] = int(time.time()) + 6 * 3600
            stats["failed"] += 1
            consecutive_errors += 1
        else:
            # Lifetime highs cannot be lowered by an incomplete/newer response.
            for bracket, rating in peaks.items():
                row["exactBest"][bracket] = max(row["exactBest"].get(bracket, 0), rating)
            row["exactFetchedAt"] = int(time.time())
            row["profileRetryAfter"] = 0
            stats["fetched"] += 1
            consecutive_errors = 0
        if consecutive_errors >= 5:
            stats["state"] = "paused"
            break
    if stats["state"] == "complete" and stats["attempted"] < len(candidates):
        stats["state"] = "budget"
    stats["cached"] = sum(bool(row["exactFetchedAt"]) for row in players.values())
    stats["total"] = len(players)
    snapshot["profiles"] = stats


def new_player() -> dict[str, dict[str, int]]:
    return {"current": {}, "bestSeen": {}, "previous": {}}


def discover_seasons(client: ApiClient, payloads: dict[tuple[int, int], Any]) -> list[int]:
    seasons: list[int] = []
    for season in range(1, MAX_SEASON + 1):
        payload = client.get_json(
            f"anniversary/leaderboards/{season}/US/2/", allow_missing=True
        )
        rows = payload.get("data", []) if isinstance(payload, dict) else []
        if not rows:
            break
        payloads[(season, 2)] = payload
        seasons.append(season)
    if not seasons:
        raise RuntimeError("IronForge returned no Anniversary arena seasons")
    return seasons


def build_snapshot(client: ApiClient, previous: dict[str, Any] | None = None,
                   profile_limit: int = 0, profile_seconds: float = 480) -> dict[str, Any]:
    generated = int(time.time())
    payloads: dict[tuple[int, int], Any] = {}
    seasons = discover_seasons(client, payloads)
    current_season = seasons[-1]
    players: dict[str, dict[str, dict[str, int]]] = {}
    hash_owners: dict[str, str] = {}
    identities: dict[str, tuple[str, str]] = {}
    seen_by_realm: dict[str, set[str]] = {realm: set() for realm in REALMS.values()}
    leaderboard_updated = 0
    leaderboard_updates = {}

    for season in seasons:
        for bracket in BRACKETS:
            payload = payloads.get((season, bracket))
            if payload is None:
                payload = client.get_json(
                    f"anniversary/leaderboards/{season}/US/{bracket}/"
                )
            rows = payload.get("data", []) if isinstance(payload, dict) else []
            if not rows:
                raise RuntimeError(f"missing season {season} {bracket}v{bracket} leaderboard")
            if season == current_season:
                try:
                    leaderboard_updated = max(
                        leaderboard_updated, int(float(payload.get("updated", 0)) / 1000)
                    )
                    leaderboard_updates[str(bracket)] = int(float(payload.get("updated", 0)) / 1000)
                except (TypeError, ValueError):
                    pass
            for row in rows:
                if not isinstance(row, dict):
                    continue
                realm = resolve_realm(str(row.get("server", "")))
                name = str(row.get("name", ""))
                try:
                    rating = int(row.get("rating", 0))
                except (TypeError, ValueError):
                    rating = 0
                if not realm or not valid_player_name(name) or rating <= 0:
                    continue

                key = lookup_hash(realm, name)
                identity = f"{normalize_realm(realm)}|{ascii_lower(name)}"
                previous_owner = hash_owners.setdefault(key, identity)
                if previous_owner != identity:
                    raise RuntimeError(
                        "lookup hash collision detected; update the hash algorithm"
                    )
                seen_by_realm[realm].add(key)
                identities[key] = (realm, name)
                player = players.setdefault(key, new_player())
                player["realm"] = realm
                bracket_key = str(bracket)
                if season == current_season:
                    player["current"][bracket_key] = max(
                        int(player["current"].get(bracket_key, 0)), rating
                    )
                if season == current_season - 1:
                    player["previous"][bracket_key] = max(
                        int(player["previous"].get(bracket_key, 0)), rating
                    )
                player["bestSeen"][bracket_key] = max(
                    int(player["bestSeen"].get(bracket_key, 0)), rating
                )

    # Keep completed peaks for recently checked players who disappear from all
    # published ladders. No old current rating is presented as a fresh one.
    if previous is not None and isinstance(previous.get("players"), dict):
        for key, old in previous["players"].items():
            if key in players or not re.fullmatch(r"[0-9a-f]{16}", key) or not isinstance(old, dict):
                continue
            realm = resolve_realm(str(old.get("realm", "")))
            state = profile_state(old, generated)
            if realm and state["exactFetchedAt"] > generated - 90 * 86400:
                players[key] = {**new_player(), "realm": realm}
                seen_by_realm[realm].add(key)
    ordered_players = {key: players[key] for key in sorted(players)}
    counts = {realm: len(keys) for realm, keys in seen_by_realm.items()}
    snapshot = {
        "version": 6,
        "keyAlgorithm": HASH_ALGORITHM,
        "generated": generated,
        "source": "ironforge.pro",
        "region": "US",
        "season": current_season,
        "previousSeason": max(0, current_season - 1),
        "cutoffs": build_cutoffs(client, current_season, generated),
        "realms": list(REALMS.values()),
        "leaderboardUpdated": leaderboard_updated,
        "leaderboardUpdates": leaderboard_updates,
        "counts": counts,
        "players": ordered_players,
    }
    enrich_profiles(client, snapshot, identities, previous, profile_limit, profile_seconds)
    return snapshot


def lua_rating_map(values: dict[str, int]) -> str:
    parts = [
        f"[{bracket}] = {int(values[str(bracket)])}"
        for bracket in BRACKETS
        if int(values.get(str(bracket), 0)) > 0
    ]
    return "{ " + ", ".join(parts) + " }"


def lua_compact_player(player: dict[str, dict[str, int]]) -> str:
    """Keep the legacy six ratings, then append previous-season 2/3/5."""
    current = player.get("current", {})
    best = player.get("bestSeen", {})
    ratings = [int(current.get(str(bracket), 0)) for bracket in BRACKETS]
    ratings.extend(int(best.get(str(bracket), 0)) for bracket in BRACKETS)
    ratings.extend(int(player.get("previous", {}).get(str(bracket), 0)) for bracket in BRACKETS)
    fields = [str(max(0, rating)) for rating in ratings]
    if player.get("exactFetchedAt", 0) > 0:
        fields += ["exactBest = " + lua_rating_map(player.get("exactBest", {})),
                   "exactFetchedAt = " + str(int(player["exactFetchedAt"]))]
    return "{ " + ", ".join(fields) + " }"


def lua_cutoffs(cutoffs: dict[str, Any]) -> list[str]:
    lines = ["    cutoffs = {"]
    for season, brackets in sorted(cutoffs.items(), key=lambda item: int(item[0])):
        lines.append(f"        [{int(season)}] = {{")
        for bracket, entry in sorted(brackets.items()):
            thresholds = ", ".join(str(int(value)) for value in entry["thresholds"])
            lines.append(
                f"            [{int(bracket)}] = {{ updated = {int(entry['updated'])}, "
                f"thresholds = {{ {thresholds} }} }},"
            )
        lines.append("        },")
    return lines + ["    },"]


def render_lua(snapshot: dict[str, Any]) -> str:
    counts = snapshot.get("counts", {})
    lines = [
        "-- Generated by the public Nightslayer Rating snapshot workflow.",
        "NightslayerRatingData = {",
        "    meta = {",
        '        realm = "Nightslayer",',
        '        realms = { "Nightslayer", "Dreamscythe" },',
        '        region = "US",',
        f"        season = {int(snapshot['season'])},",
        f"        previousSeason = {int(snapshot.get('previousSeason', 0))},",
        f"        generated = {int(snapshot['generated'])},",
        f"        leaderboardUpdated = {int(snapshot['leaderboardUpdated'])},",
        f"        leaderboardUpdates = {lua_rating_map(snapshot.get('leaderboardUpdates', {}))},",
        f"        sharedGenerated = {int(snapshot['generated'])},",
        "        profileLookup = false,",
        f"        sharedProfiles = {int(snapshot.get('profiles', {}).get('cached', 0))},",
        "        counts = {",
        f"            Nightslayer = {int(counts.get('Nightslayer', 0))},",
        f"            Dreamscythe = {int(counts.get('Dreamscythe', 0))},",
        "        },",
        '        source = "ironforge.pro via pseudonymous shared snapshot",',
        "    },",
    ]
    lines.extend(lua_cutoffs(snapshot.get("cutoffs", {})))
    lines.append("    sharedPlayers = {")
    for key, player in snapshot.get("players", {}).items():
        lines.append(f'        ["{key}"] = {lua_compact_player(player)},')
    lines.extend(("    },", "    players = {},", "}", ""))
    return "\n".join(lines)


def write_outputs(
    snapshot: dict[str, Any],
    output: Path,
    meta_output: Path,
    lua_output: Path | None = None,
) -> None:
    encoded = json.dumps(
        snapshot, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    compressed = gzip.compress(encoded, compresslevel=9, mtime=0)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as handle:
        handle.write(compressed)
        temporary = Path(handle.name)
    os.replace(temporary, output)

    meta = {key: value for key, value in snapshot.items() if key != "players"}
    meta["compressedBytes"] = len(compressed)
    meta["jsonBytes"] = len(encoded)
    meta_output.write_text(
        json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    if lua_output is not None:
        lua_encoded = render_lua(snapshot).encode("utf-8")
        lua_output.write_bytes(gzip.compress(lua_encoded, compresslevel=9, mtime=0))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--meta-output", type=Path, required=True)
    parser.add_argument("--lua-output", type=Path)
    parser.add_argument("--api-base", default=DEFAULT_API_BASE)
    parser.add_argument("--previous-snapshot", type=Path)
    parser.add_argument("--profile-limit", type=int, default=100)
    parser.add_argument("--profile-seconds", type=float, default=480)
    args = parser.parse_args()

    previous = None
    if args.previous_snapshot:
        previous = json.loads(gzip.decompress(args.previous_snapshot.read_bytes()))
    snapshot = build_snapshot(ApiClient(args.api_base), previous, args.profile_limit, args.profile_seconds)
    write_outputs(snapshot, args.output, args.meta_output, args.lua_output)
    print(
        f"Built season {snapshot['season']} pseudonymous snapshot with "
        f"{len(snapshot['players'])} rows: {snapshot['counts']}"
    )


if __name__ == "__main__":
    main()
