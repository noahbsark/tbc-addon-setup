import gzip
import importlib.util
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "central-rating-data" / "build_shared_cache.py"
SPEC = importlib.util.spec_from_file_location("build_shared_cache", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class FakeClient:
    def get_json(self, path, *, allow_missing=False):
        if path == "anniversary/leaderboards/2/US/2/":
            return None
        if path.startswith("anniversary/leaderboards/1/US/"):
            bracket = int(path.rstrip("/").split("/")[-1])
            return {
                "updated": 1_788_490_157_000,
                "data": [
                    {
                        "server": "Nightslayer",
                        "name": "Twinname",
                        "rating": 1500 + bracket,
                    },
                    {
                        "server": "Dreamscythe",
                        "name": "Twinname",
                        "rating": 1700 + bracket,
                    },
                    {"server": "OtherRealm", "name": "Ignored", "rating": 2500},
                ],
            }
        if path.startswith("anniversary/cutoffs/1/US/"):
            return {
                "cutoff": [
                    [2000, "Vengeful Gladiator"],
                    [1900, "Gladiator"],
                    [1800, "Duelist"],
                    [1700, "Rival"],
                    [1500, "Challenger"],
                ]
            }
        if path == "anniversary/player/Dreamscythe/Exactname":
            return {
                "info": {"name": "Exactname"},
                "bracket_best": {"2": 2300},
                "season1": {"2": {"rating": 2200}},
            }
        raise AssertionError(f"unexpected URL: {path}")


class SharedCacheTests(unittest.TestCase):
    def test_two_realms_are_distinct_and_names_are_not_published(self):
        snapshot = MODULE.build_snapshot(FakeClient())
        players = snapshot["players"]
        nightslayer_key = MODULE.lookup_hash("Nightslayer", "Twinname")
        dreamscythe_key = MODULE.lookup_hash("Dreamscythe", "Twinname")
        self.assertNotEqual(nightslayer_key, dreamscythe_key)
        self.assertIn(nightslayer_key, players)
        self.assertIn(dreamscythe_key, players)
        self.assertEqual(
            players[dreamscythe_key]["current"]["2"], 1702
        )
        self.assertEqual(
            players[nightslayer_key]["current"]["2"], 1502
        )
        serialized = json.dumps(snapshot, ensure_ascii=False)
        self.assertNotIn("Twinname", serialized)
        self.assertNotIn("Ignored", serialized)
        self.assertEqual(snapshot["version"], 4)
        self.assertEqual(snapshot["keyAlgorithm"], "nsr-h4-v1")

    def test_hash_vector_and_deterministic_gzip(self):
        self.assertEqual(
            MODULE.lookup_hash("Nightslayer", "Reefey"), "ec31af45054a44db"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "snapshot.json.gz"
            meta = root / "snapshot.meta.json"
            lua_output = root / "snapshot.lua.gz"
            snapshot = {
                "version": 4,
                "keyAlgorithm": "nsr-h4-v1",
                "players": {},
                "season": 1,
                "generated": 123,
                "leaderboardUpdated": 120,
                "cutoffSeason": 1,
                "cutoffs": {"2": {}, "3": {}, "5": {}},
                "counts": {},
            }
            MODULE.write_outputs(snapshot, output, meta, lua_output)
            decoded = json.loads(gzip.decompress(output.read_bytes()))
            self.assertEqual(decoded, snapshot)
            self.assertNotIn("players", json.loads(meta.read_text(encoding="utf-8")))
            lua = gzip.decompress(lua_output.read_bytes()).decode("utf-8")
            self.assertIn("NightslayerRatingData", lua)
            self.assertIn('realms = { "Nightslayer", "Dreamscythe" }', lua)
            self.assertIn("sharedPlayers", lua)

    def test_hash_collision_fails_closed(self):
        with mock.patch.object(MODULE, "lookup_hash", return_value="0000000000000000"):
            with self.assertRaisesRegex(RuntimeError, "hash collision"):
                MODULE.build_snapshot(FakeClient())


if __name__ == "__main__":
    unittest.main()
