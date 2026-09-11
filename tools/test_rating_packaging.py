import base64
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import time
import unittest
from unittest.mock import patch
from zipfile import ZIP_DEFLATED, ZipFile

import package_rating_addon as package
import prepare_rating_release as release


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.version = package.source_version()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(package.SOURCE, self.root / "nightslayer-rating/source")
        shutil.copytree(package.ROOT / "central-rating-data", self.root / "central-rating-data")
        shutil.copy(package.ROOT / "nightslayer-rating/index.html", self.root / "nightslayer-rating/index.html")
        for obj, field, value in ((package, "ROOT", self.root), (release, "ROOT", self.root),
                                  (package, "SOURCE", self.root / "nightslayer-rating/source"),
                                  (package, "ADDON", self.root / "nightslayer-rating/source/Addon/NightslayerRating")):
            mock = patch.object(obj, field, value)
            mock.start()
            self.addCleanup(mock.stop)
        frozen = json.loads((package.SOURCE / "Updater/Season2Cutoffs.json").read_text())
        self.snapshot = {"version": 6, "region": "US", "season": 3, "previousSeason": 2,
                         "generated": int(time.time()), "leaderboardUpdated": int(time.time()),
                         "keyAlgorithm": "nsr-h4-v1", "counts": {"Nightslayer": 1, "Dreamscythe": 0},
                         "cutoffs": frozen, "players": {"0123456789abcdef": {
                             "current": {"2": 2100}, "bestSeen": {"2": 2900}, "previous": {"2": 2400}}}}
        self.input = self.root / "snapshot.json.gz"
        self.input.write_bytes(gzip.compress(json.dumps(self.snapshot).encode()))

    def build(self):
        return package.build(self.input)

    def resign(self, paths):
        manifest_path = self.root / "nightslayer-rating/latest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["sha256"] = hashlib.sha256(paths[1].read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        (self.root / "nightslayer-rating/checksums.txt").write_text("".join(
            f"{hashlib.sha256(p.read_bytes()).hexdigest()}  downloads/{p.name}\n" for p in paths))

    def test_reproducible_and_complete(self):
        paths = self.build()
        original = [p.read_bytes() for p in paths]
        self.build()
        self.assertEqual(original, [p.read_bytes() for p in paths])
        self.assertEqual(package.verify(), self.version)
        with ZipFile(paths[0]) as archive:
            self.assertIn("NightslayerRating/Search.lua", archive.namelist())

    def test_changed_source_cannot_ship_with_old_zip(self):
        self.build()
        with (package.ADDON / "Core.lua").open("a") as stream:
            stream.write("\n-- updated source\n")
        with self.assertRaisesRegex(ValueError, "Stale packaged source"):
            package.verify()

    def test_mismatched_bootstrap_is_rejected_even_with_updated_checksums(self):
        paths = self.build()
        with ZipFile(paths[1]) as archive:
            contents = {n: archive.read(n) for n in archive.namelist()}
        self.snapshot["players"]["0123456789abcdef"]["current"]["2"] = 1000
        name = next(n for n in contents if n.endswith("BundledSnapshot.json.gz"))
        contents[name] = gzip.compress(json.dumps(self.snapshot).encode())
        with ZipFile(paths[1], "w", ZIP_DEFLATED) as archive:
            for name, payload in contents.items():
                archive.writestr(name, payload)
        self.resign(paths)
        with self.assertRaisesRegex(ValueError, "bootstrap snapshot differ"):
            package.verify()

    def test_invalid_source_version_and_frozen_thresholds_fail_before_packaging(self):
        self.snapshot["cutoffs"]["2"]["2"]["thresholds"][0] = 9999
        with self.assertRaisesRegex(ValueError, "frozen S2"):
            package.validate_snapshot(self.snapshot)
        toc = package.ADDON / "NightslayerRating.toc"
        toc.write_text(toc.read_text().replace(self.version, "0.0.0"))
        with self.assertRaisesRegex(ValueError, "versions must match"):
            package.source_version()

    def test_release_does_not_overwrite_an_existing_version(self):
        self.build()
        calls = []

        def fake_api(path, payload=None):
            calls.append((path, payload))
            if path.endswith("git/ref/heads/main"):
                return {"object": {"sha": "main"}}
            if "contents/nightslayer-rating/latest.json" in path:
                return {"content": base64.b64encode(json.dumps({"version": self.version}).encode()).decode()}
            self.fail("Unexpected API mutation")

        with patch.dict("os.environ", {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "noahbsark/tbc-addon-setup"}), \
             patch.object(release, "api", fake_api), \
             patch.object(release.subprocess, "check_output", return_value="source"), \
             patch.object(release.subprocess, "run"):
            with self.assertRaisesRegex(RuntimeError, "Bump the TOC"):
                release.main()
        self.assertTrue(all(payload is None for _, payload in calls))


if __name__ == "__main__":
    unittest.main()
