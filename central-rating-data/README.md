# Nightslayer Rating shared data

This directory contains the low-rate publisher for the addon's read-only arena-rating snapshot.

- GitHub Actions refreshes Nightslayer and Dreamscythe leaderboard data hourly.
- The stable `ratings-data` release contains `shared-cache.json.gz`, `shared-data.lua.gz`, and small metadata.
- Shared rating rows are keyed by a deterministic four-part lookup hash. Raw character names are not written to the public snapshot or workflow logs.
- Generated Lua uses one compact six-number row per character (current 2v2/3v3/5v5, then best-seen 2v2/3v3/5v5) to reduce in-game load time and memory.
- Installed Windows companions can only download the snapshot. They receive no repository credential and cannot overwrite shared data.
- Exact lifetime-high requests remain local: the companion reads this addon's own SavedVariables queue and contacts IronForge directly for recently encountered characters. Successful exact profiles refresh at most weekly.

If the shared asset is unavailable, the companion falls back to the same low-rate IronForge requests it used before shared snapshots were introduced.
