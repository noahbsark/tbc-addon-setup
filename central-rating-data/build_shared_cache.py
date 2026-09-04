#!/usr/bin/env python3
"""Build the public, pseudonymous Nightslayer Rating snapshot.

The published file contains rating maps keyed by a deterministic two-part hash.
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
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable


DEFAULT_API_BASE = "https://ironforge.pro/api"
REALMS = {"nightslayer": "Nightslayer", "dreamscythe": "Dreamscythe"}
BRACKETS = (2, 3, 5)
MAX_SEASON = 20
HASH_ALGORITHM = "nsr-h4-v1"
HASH_MODULI = (65_521, 65_519, 65_497, 65_479)
HASH_BASES = (131, 137, 139, 149)
USER_AGENT = (
    "NightslayerRating/1.1.0 shared-cache publisher "
    "(+https://github.com/noahbsark/tbc-addon-setup)"
)


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


def parse_cutoffs(rows: Iterable[Any]) -> dict[str, int]:
    result: dict[str, int] = {}
    for row in rows or ():
        if not isinstance(row, list) or len(row) < 2:
            continue
        try:
            rating = int(row[0])
        except (TypeError, ValueError):
            continue
        title = str(row[1])
        if title == "Gladiator":
            tier = "gladiator"
        elif title == "Duelist":
            tier = "duelist"
        elif title == "Rival":
            tier = "rival"
        elif title == "Challenger":
            tier = "challenger"
        elif title.endswith("Gladiator") or title == "Rank One":
            tier = "rank"
        else:
            continue
        if rating > 0:
            result[tier] = rating
    return result


def new_player() -> dict[str, dict[str, int]]:
    return {"current": {}, "bestSeen": {}}


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


def build_snapshot(client: ApiClient) -> dict[str, Any]:
    generated = int(time.time())
    payloads: dict[tuple[int, int], Any] = {}
    seasons = discover_seasons(client, payloads)
    current_season = seasons[-1]
    players: dict[str, dict[str, dict[str, int]]] = {}
    seen_by_realm: dict[str, set[str]] = {realm: set() for realm in REALMS.values()}
    leaderboard_updated = 0

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
                seen_by_realm[realm].add(key)
                player = players.setdefault(key, new_player())
                bracket_key = str(bracket)
                if season == current_season:
                    player["current"][bracket_key] = rating
                player["bestSeen"][bracket_key] = max(
                    int(player["bestSeen"].get(bracket_key, 0)), rating
                )

    cutoffs: dict[str, dict[str, int]] = {}
    for bracket in BRACKETS:
        payload = client.get_json(f"anniversary/cutoffs/{current_season}/US/{bracket}/")
        rows = payload.get("cutoff", []) if isinstance(payload, dict) else []
        cutoff_map = parse_cutoffs(rows)
        if len(cutoff_map) < 5:
            raise RuntimeError(f"incomplete {bracket}v{bracket} cutoff data")
        cutoffs[str(bracket)] = cutoff_map

    ordered_players = {key: players[key] for key in sorted(players)}
    counts = {realm: len(keys) for realm, keys in seen_by_realm.items()}
    return {
        "version": 4,
        "keyAlgorithm": HASH_ALGORITHM,
        "generated": generated,
        "source": "ironforge.pro",
        "region": "US",
        "season": current_season,
        "cutoffSeason": current_season,
        "cutoffs": cutoffs,
        "realms": list(REALMS.values()),
        "leaderboardUpdated": leaderboard_updated,
        "counts": counts,
        "players": ordered_players,
    }


def lua_rating_map(values: dict[str, int]) -> str:
    parts = [
        f"[{bracket}] = {int(values[str(bracket)])}"
        for bracket in BRACKETS
        if int(values.get(str(bracket), 0)) > 0
    ]
    return "{ " + ", ".join(parts) + " }"


def lua_cutoff_map(values: dict[str, int]) -> str:
    tiers = ("rank", "gladiator", "duelist", "rival", "challenger")
    parts = [
        f"{tier} = {int(values[tier])}"
        for tier in tiers
        if int(values.get(tier, 0)) > 0
    ]
    return "{ " + ", ".join(parts) + " }"


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
        f"        generated = {int(snapshot['generated'])},",
        f"        leaderboardUpdated = {int(snapshot['leaderboardUpdated'])},",
        f"        sharedGenerated = {int(snapshot['generated'])},",
        "        counts = {",
        f"            Nightslayer = {int(counts.get('Nightslayer', 0))},",
        f"            Dreamscythe = {int(counts.get('Dreamscythe', 0))},",
        "        },",
        '        source = "ironforge.pro via pseudonymous shared snapshot",',
        "    },",
        f"    cutoffSeason = {int(snapshot['cutoffSeason'])},",
        "    cutoffs = {",
    ]
    cutoffs = snapshot.get("cutoffs", {})
    for bracket in BRACKETS:
        lines.append(
            f"        [{bracket}] = {lua_cutoff_map(cutoffs.get(str(bracket), {}))},"
        )
    lines.extend(("    },", "    sharedPlayers = {"))
    for key, player in snapshot.get("players", {}).items():
        lines.extend(
            (
                f'        ["{key}"] = {{',
                f"            current = {lua_rating_map(player.get('current', {}))},",
                f"            best = {lua_rating_map(player.get('bestSeen', {}))},",
                "            exact = false,",
                "        },",
            )
        )
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
    args = parser.parse_args()

    snapshot = build_snapshot(ApiClient(args.api_base))
    write_outputs(snapshot, args.output, args.meta_output, args.lua_output)
    print(
        f"Built season {snapshot['season']} pseudonymous snapshot with "
        f"{len(snapshot['players'])} rows: {snapshot['counts']}"
    )


if __name__ == "__main__":
    main()
