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
        if path.startswith("anniversary/cutoffs/1/US/"):
            return cutoff_payload()
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
        if path == "anniversary/player/Dreamscythe/Exactname":
            return {
                "info": {"name": "Exactname"},
                "bracket_best": {"2": 2300},
                "season1": {"2": {"rating": 2200}},
            }
        raise AssertionError(f"unexpected URL: {path}")


def cutoff_payload():
    return {
        "updated": "Thu, 10 Sep 2026 14:16:07 GMT",
        "cutoff": [[2199, "Vengeful Gladiator", ""], [2058, "Gladiator", ""],
                   [1863, "Duelist", ""], [1676, "Rival", ""], [1498, "Challenger", ""]],
    }


class SeasonThreeClient:
    def get_json(self, path, *, allow_missing=False):
        if path.startswith("anniversary/cutoffs/3/US/"):
            return cutoff_payload()
        if path.startswith("anniversary/leaderboards/"):
            season = int(path.split("/")[2])
            if season == 4:
                return None
            return {"updated": 1789060881000, "data": [
                {"server": "Nightslayer", "name": "Twinname", "rating": {1: 2900, 2: 2481, 3: 2058}[season]}
            ]}
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
        self.assertEqual(snapshot["version"], 6)
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
            self.assertIn("profileLookup = false", lua)

    def test_lua_players_keep_six_legacy_ratings_and_append_previous(self):
        snapshot = MODULE.build_snapshot(FakeClient())
        key = MODULE.lookup_hash("Nightslayer", "Twinname")
        lua = MODULE.render_lua(snapshot)
        self.assertIn(
            f'["{key}"] = {{ 1502, 1503, 1505, 1502, 1503, 1505, 0, 0, 0 }}',
            lua,
        )
        self.assertNotIn("exact = false", lua)

    def test_season_two_is_not_an_all_time_record(self):
        snapshot = MODULE.build_snapshot(SeasonThreeClient())
        player = snapshot["players"][MODULE.lookup_hash("Nightslayer", "Twinname")]
        self.assertEqual(player["current"]["2"], 2058)
        self.assertEqual(player["previous"]["2"], 2481)
        self.assertEqual(player["bestSeen"]["2"], 2900)
        self.assertEqual(snapshot["previousSeason"], 2)
        self.assertIn("2058, 2058, 2058, 2900, 2900, 2900, 2481, 2481, 2481", MODULE.render_lua(snapshot))

    def test_season_two_cutoffs_match_all_three_screenshots(self):
        snapshot = MODULE.build_snapshot(SeasonThreeClient())
        expected = {"2": [2803, 2481, 1944, 1629, 1458],
                    "3": [2493, 2269, 1913, 1662, 1482],
                    "5": [2340, 2166, 1854, 1640, 1466]}
        for bracket, thresholds in expected.items():
            self.assertEqual(snapshot["cutoffs"]["2"][bracket]["thresholds"], thresholds)
        self.assertEqual(snapshot["cutoffs"]["3"]["2"]["thresholds"], [2199, 2058, 1863, 1676, 1498])

    def test_cutoff_validation_rejects_partial_misordered_and_invalid_data(self):
        for bad in (None, {}, {"cutoff": []}):
            with self.assertRaises(ValueError):
                MODULE.parse_cutoffs(bad, 1800000000)
        for value in ("-", 0, -1, True, 12000, 2400.5):
            payload = cutoff_payload()
            payload["cutoff"][0][0] = value
            with self.assertRaises(ValueError):
                MODULE.parse_cutoffs(payload, 1800000000)
        payload = cutoff_payload()
        payload["cutoff"][1][0] = 2500
        with self.assertRaises(ValueError):
            MODULE.parse_cutoffs(payload, 1800000000)
        payload = cutoff_payload()
        payload["cutoff"][2][1] = "Rival"
        with self.assertRaises(ValueError):
            MODULE.parse_cutoffs(payload, 1800000000)
        with self.assertRaises(ValueError):
            MODULE.parse_cutoffs(cutoff_payload(), 1)

    def test_cutoff_refresh_failure_leaves_published_files_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "snapshot.json.gz"
            output.write_bytes(b"last-good")
            client = SeasonThreeClient()
            original = client.get_json
            client.get_json = lambda path, **kw: {} if "/cutoffs/" in path else original(path, **kw)
            with self.assertRaises(ValueError):
                snapshot = MODULE.build_snapshot(client)
                MODULE.write_outputs(snapshot, output, Path(directory) / "meta.json")
            self.assertEqual(output.read_bytes(), b"last-good")

    def test_hash_collision_fails_closed(self):
        with mock.patch.object(MODULE, "lookup_hash", return_value="0000000000000000"):
            with self.assertRaisesRegex(RuntimeError, "hash collision"):
                MODULE.build_snapshot(FakeClient())


if __name__ == "__main__":
    unittest.main()
