# Nightslayer Rating shared data

This directory contains the low-rate publisher for the addon's read-only arena-rating snapshot.

- GitHub Actions refreshes Nightslayer and Dreamscythe leaderboard data hourly.
- The stable `ratings-data` release contains `shared-cache.json.gz`, `shared-data.lua.gz`, and small metadata.
- Shared rating rows are keyed by a deterministic four-part lookup hash. Raw character names are not written to the public snapshot or workflow logs.
- Snapshot schema v6 appends the previous season's archived 2v2/3v3/5v5 ratings to the original six-number Lua row (current, then all-time best seen). The first six positions remain compatible with older addons.
- `previousSeason` identifies those three new values. It is never inferred from a lifetime high. The snapshot includes US cutoff tables keyed by season and bracket, with the source's update timestamp and a separate fetch timestamp.
- The publisher uses the same `/api/anniversary/cutoffs/{season}/US/{bracket}/` endpoint as IronForge's cutoff cards. The canonical frozen S2 values live in `../nightslayer-rating/source/Updater/Season2Cutoffs.json`; current cutoffs and future previous-season archives come from the API. Invalid or missing cutoff tiers fail publication, leaving the prior stable release intact.
- Installed Windows companions can only download the snapshot. They receive no repository credential and cannot overwrite shared data.
- Exact lifetime-high requests remain local: the companion reads this addon's own SavedVariables queue and contacts IronForge directly for recently encountered characters. Successful exact profiles refresh at most weekly.

If the shared asset is unavailable, the companion falls back to the same low-rate IronForge requests it used before shared snapshots were introduced.

The companion validates cutoff ordering, timestamps, and rating ranges, preserves the last valid values, and checks the direct cutoff source at most daily after a successful fetch when shared data is unavailable or stale. The addon identifies cutoff data older than 48 hours. Production snapshot publication is restricted to `main`; feature-branch tests cannot overwrite the shared release.

To package a release, first build the snapshot with `build_shared_cache.py`, then run `python tools/package_rating_addon.py --data PATH/TO/shared-data.lua.gz` from the repository root. This bundles the matching Lua code, snapshot, updater, and frozen cutoffs in both downloads and refreshes their checksums.
