# Nightslayer Rating shared data

This directory contains the low-rate publisher for the addon's read-only arena-rating snapshot.

- GitHub Actions refreshes Nightslayer and Dreamscythe leaderboard data every 30 minutes.
- The stable `ratings-data` release contains `shared-cache.json.gz`, `shared-data.lua.gz`, and small metadata.
- Shared rating rows are keyed by a deterministic four-part lookup hash. Raw character names are not written to the public snapshot or workflow logs.
- Installed Windows companions can only download the snapshot. They receive no repository credential and cannot overwrite shared data.
- Exact lifetime-high requests remain local: the companion reads this addon's own SavedVariables queue and contacts IronForge directly for characters that user encountered.

If the shared asset is unavailable, the companion falls back to the same low-rate IronForge requests it used before shared snapshots were introduced.
