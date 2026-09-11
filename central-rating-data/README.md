# Nightslayer Rating shared data

This directory contains the low-rate publisher for the addon's read-only arena-rating snapshot.

- GitHub Actions refreshes Nightslayer and Dreamscythe leaderboard data hourly.
- The stable `ratings-data` release contains `shared-cache.json.gz`, `shared-data.lua.gz`, and small metadata.
- Shared rating rows are keyed by a deterministic four-part lookup hash. Raw character names are not written to the public snapshot or workflow logs.
- Snapshot schema v6 appends the previous season's archived 2v2/3v3/5v5 ratings to the original six-number Lua row (current, then all-time best seen). The first six positions remain compatible with older addons.
- `previousSeason` identifies those three compatibility values. The 1.3.1 UI does not display them; it shows Current and lifetime Peak, using frozen S2 cutoffs to color the latter. The snapshot includes US cutoff tables keyed by season and bracket, with the source's update timestamp and a separate fetch timestamp.
- The publisher uses the same `/api/anniversary/cutoffs/{season}/US/{bracket}/` endpoint as IronForge's cutoff cards. The canonical frozen S2 values live in `../nightslayer-rating/source/Updater/Season2Cutoffs.json`; current cutoffs and future previous-season archives come from the API. Invalid or missing cutoff tiers fail publication, leaving the prior stable release intact.
- Optional `leaderboardUpdates` metadata preserves the current source timestamp for each bracket; v1.4 displays the oldest complete timestamp and individual bracket ages. Legacy snapshots remain compatible and show the latest known source date without inventing per-bracket freshness.
- Installed Windows companions can only download the snapshot. They receive no repository credential and cannot overwrite shared data.
- The shared collector loads its previous published snapshot and gradually adds exact peaks from public leaderboard profiles (up to 100 attempts/run, at least one second between requests, eight-minute profile budget). It reuses cached profiles for seven days and retains recently checked departed players for up to 90 days. A 429 stops profile collection; five consecutive errors pause it. 404s wait seven days and transient errors six hours before another attempt. Raw profile names are transient and are not published.
- Optional per-player `exactBest` and `exactFetchedAt` fields extend v6 without changing the nine existing Lua positions. Older clients ignore these fields. Coverage metadata is separate from the leaderboard source dates.
- User-requested exact lifetime-high requests remain local: the companion reads this addon's own SavedVariables queue and contacts IronForge directly. In v1.4, priority players viewed within three days and local characters refresh daily; other profiles refresh weekly. Normal runs are capped at 50 profiles; the explicit Process Queue mode handles all due requests. Fresh shared peaks avoid duplicate local lookups where current ratings are available. No user queue or local result is uploaded.

If the shared asset is unavailable, the companion falls back to the same low-rate IronForge requests it used before shared snapshots were introduced.

The companion validates cutoff ordering, timestamps, and rating ranges, preserves the last valid values, and checks the direct cutoff source at most daily after a successful fetch when shared data is unavailable or stale. The addon identifies cutoff data older than 48 hours. Production snapshot publication is restricted to `main`; feature-branch tests cannot overwrite the shared release.

To package a release, first build the snapshot with `build_shared_cache.py`, then run `python tools/package_rating_addon.py --snapshot PATH/TO/shared-cache.json.gz` from the repository root. This bundles the matching Lua code, snapshot, updater, and frozen cutoffs in both downloads and refreshes their checksums. It also writes `nightslayer-rating/latest.json`, containing the Windows ZIP filename, version, and SHA256. Commit the ZIP and manifest together so the Windows upgrade helper sees a matching release.

Windows bundles also include `Updater/BundledSnapshot.json.gz`, built from the same JSON as the packaged Data.lua. The companion can initialize from this file without network access. It accepts legacy v4/v5 shared snapshots, preserves cutoff data when those formats omit it, and refuses to roll back newer cached ratings. Bracket refreshes retain valid data on HTTP errors or empty/malformed responses.
