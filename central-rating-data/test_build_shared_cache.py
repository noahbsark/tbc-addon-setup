import gzip
import importlib.util
import json
import tempfile
import unittest
import time
import urllib.error
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
    def test_shared_peaks_resume_without_refetching_or_exposing_names(self):
        client = FakeClient()
        client.get_profile = mock.Mock(return_value={"bracket_best": {"2": 2700, "3": 2200, "10": 0}})
        first = MODULE.build_snapshot(client, profile_limit=1)
        self.assertEqual(first["profiles"]["fetched"], 1)
        self.assertEqual(first["profiles"]["state"], "budget")
        completed = next(key for key, row in first["players"].items() if row["exactFetchedAt"])
        original_stamp = first["players"][completed]["exactFetchedAt"]
        second = MODULE.build_snapshot(client, first, profile_limit=1)
        self.assertEqual(client.get_profile.call_count, 2)
        self.assertNotEqual(client.get_profile.call_args_list[0], client.get_profile.call_args_list[1])
        self.assertEqual(second["profiles"]["cached"], 2)
        self.assertEqual(second["players"][completed]["exactFetchedAt"], original_stamp)
        third = MODULE.build_snapshot(client, second, profile_limit=100)
        self.assertEqual(client.get_profile.call_count, 2)
        self.assertEqual(third["profiles"]["attempted"], 0)
        self.assertNotIn("Twinname", json.dumps(third))
        self.assertNotIn("10", third["players"][completed]["exactBest"])
        self.assertIn("exactBest = { [2] = 2700, [3] = 2200 }", MODULE.render_lua(third))

    def test_old_shared_peaks_survive_failures_and_older_values(self):
        client = FakeClient()
        client.get_profile = mock.Mock(return_value={"bracket_best": {"2": 2700}})
        previous = MODULE.build_snapshot(client, profile_limit=100)
        for row in previous["players"].values():
            row["exactFetchedAt"] = int(time.time()) - 8 * 86400
        client.get_profile.side_effect = urllib.error.HTTPError("profile", 429, "slow down", {}, None)
        result = MODULE.build_snapshot(client, previous, profile_limit=100)
        self.assertEqual(result["profiles"]["attempted"], 1)
        self.assertEqual(result["profiles"]["state"], "throttled")
        self.assertTrue(all(row["exactBest"]["2"] == 2700 for row in result["players"].values()))
        client.get_profile.side_effect = None
        client.get_profile.return_value = {"bracket_best": {"2": 2500}}
        result = MODULE.build_snapshot(client, previous, profile_limit=100)
        self.assertTrue(all(row["exactBest"]["2"] == 2700 for row in result["players"].values()))

    def test_missing_invalid_and_time_budget_do_not_repeat_requests(self):
        client = FakeClient()
        client.get_profile = mock.Mock(side_effect=urllib.error.HTTPError("profile", 404, "missing", {}, None))
        first = MODULE.build_snapshot(client, profile_limit=100)
        self.assertEqual(first["profiles"]["unavailable"], 2)
        second = MODULE.build_snapshot(client, first, profile_limit=100)
        self.assertEqual(second["profiles"]["attempted"], 0)
        self.assertEqual(client.get_profile.call_count, 2)
        client.get_profile.side_effect = None
        client.get_profile.return_value = {"bracket_best": {"2": "bad"}}
        invalid = MODULE.build_snapshot(client, profile_limit=100)
        self.assertEqual(invalid["profiles"]["failed"], 2)
        self.assertEqual(invalid["profiles"]["cached"], 0)
        result = MODULE.build_snapshot(client, profile_limit=100, profile_seconds=0)
        self.assertEqual(result["profiles"]["attempted"], 0)
        self.assertEqual(result["profiles"]["state"], "budget")

    def test_five_errors_stop_collector_and_untried_players_go_next(self):
        now = int(time.time())
        rows = {str(i): {"current": {"2": 1500}} for i in range(12)}
        snapshot = {"players": rows, "season": 3}
        identities = {key: ("Nightslayer", "Example") for key in rows}
        client = FakeClient()
        client.get_profile = mock.Mock(side_effect=TimeoutError())
        MODULE.enrich_profiles(client, snapshot, identities, None, 100, 480)
        self.assertEqual(snapshot["profiles"]["attempted"], 5)
        self.assertEqual(snapshot["profiles"]["state"], "paused")
        previous = {**snapshot, "version": 6, "keyAlgorithm": MODULE.HASH_ALGORITHM,
                    "region": "US", "generated": now}
        next_snapshot = {"players": {key: {"current": {"2": 1500}} for key in rows}, "season": 3}
        client.get_profile.side_effect = None
        client.get_profile.return_value = {"bracket_best": {"2": 1800}}
        MODULE.enrich_profiles(client, next_snapshot, identities, previous, 100, 480)
        self.assertEqual(next_snapshot["profiles"]["fetched"], 7)

    def test_departed_player_retains_peak_without_fresh_current_rating(self):
        client = FakeClient()
        client.get_profile = mock.Mock(return_value={"bracket_best": {"2": 2700}})
        previous = MODULE.build_snapshot(client, profile_limit=100)
        key = MODULE.lookup_hash("Nightslayer", "Departed")
        previous["players"][key] = {"realm": "Nightslayer", "exactBest": {"2": 3000},
                                     "exactFetchedAt": int(time.time()), "current": {"2": 2000}}
        result = MODULE.build_snapshot(client, previous, profile_limit=100)
        self.assertEqual(result["players"][key]["exactBest"], {"2": 3000})
        self.assertEqual(result["players"][key]["current"], {})
        self.assertEqual(sum(result["counts"].values()), len(result["players"]))
        previous["players"][key]["exactFetchedAt"] = int(time.time()) + 7200
        with self.assertRaises(ValueError):
            MODULE.build_snapshot(client, previous, profile_limit=100)

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
