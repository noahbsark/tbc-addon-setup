# Nightslayer Rating

Free World of Warcraft TBC Anniversary addon for Nightslayer and Dreamscythe US. It adds current-season, observed, and lifetime-peak 2v2, 3v3, and 5v5 ratings to Group Finder tooltips, normal player tooltips, and a private local summary when someone whispers you.

[Download and install](https://noahbsark.github.io/tbc-addon-setup/nightslayer-rating/) · [Report a bug](https://github.com/noahbsark/tbc-addon-setup/issues) · [Shared data status](https://github.com/noahbsark/tbc-addon-setup/releases/tag/ratings-data)

## What the numbers mean

- **Current** is the newest current-season rating published by the source.
- **Peak** is the exact lifetime bracket high returned by the character profile after the Windows companion processes a character. Its color is compared with the frozen Season 2 US cutoffs for that bracket, regardless of which season the high occurred in.
- **Observed\*** is the highest rating found in the tracked leaderboard snapshots while the exact lifetime peak lookup is pending. It uses the same S2 color comparison, with an explicit observed-data label.
- Rated, Competitive, Strong, Excellent, and Elite remain neutral visual labels. Current colors follow the current US season and bracket's Challenger, Rival, Duelist, Gladiator, and Rank One cutoff estimates. Peak/Observed colors use the fixed S2 cutoffs for that bracket. Positive values below Challenger are gray; missing cutoffs use neutral white. Zero/missing ratings remain gray and inactive.

## Current and peak colors (v1.3.1)

The tooltip and chat summary show two values per bracket: Current and Peak (or Observed* until its exact lookup completes). There is no S2 rating column. Peak is compared against these frozen final IronForge US Season 2 cutoffs:

| Bracket | Orange: Merciless Gladiator | Purple: Gladiator | Blue: Duelist | Green: Rival | White: Challenger |
| --- | ---: | ---: | ---: | ---: | ---: |
| [2v2](https://ironforge.pro/anniversary/leaderboards/archive/season-2/US/2/) | 2803 | 2481 | 1944 | 1629 | 1458 |
| [3v3](https://ironforge.pro/anniversary/leaderboards/archive/season-2/US/3/) | 2493 | 2269 | 1913 | 1662 | 1482 |
| [5v5](https://ironforge.pro/anniversary/leaderboards/archive/season-2/US/5/) | 2340 | 2166 | 1854 | 1640 | 1466 |

Thresholds are inclusive. Current S3 ratings use the live [2v2](https://ironforge.pro/anniversary/leaderboards/US/2/), [3v3](https://ironforge.pro/anniversary/leaderboards/US/3/), and [5v5](https://ironforge.pro/anniversary/leaderboards/US/5/) cutoff values fetched by the hourly shared publisher. Each bracket keeps its own source timestamp. Cutoffs older than 48 hours are marked stale; `/nsr cutoffs` shows the current-season cutoffs and the fixed S2 comparison cutoffs. A failed or invalid refresh retains the last valid cutoff data. No guessed fixed bands or cross-bracket substitutions are used.

On a future season rollover, Current follows the snapshot season. Peak/Observed keeps the same fixed S2 color comparison. Colors describe a rating range and do not claim an earned title.

To upgrade from 1.2.x, close WoW, extract the **1.3.1 Windows bundle**, and run `Install.cmd` again. This installs the new coloring code and companion while preserving the existing exact-profile cache. Subsequent data and cutoff changes use the existing updater; log in or `/reload` to see them. The addon-only ZIP is a point-in-time snapshot and does not refresh itself.

Version 1.3.1 accepts the existing v4/v5 shared snapshots as well as v6. The Windows bundle includes the same snapshot in a format the companion can load locally, so a fresh install works during a source outage. Failed or empty leaderboard requests preserve their cached bracket values, and a failed future-season probe cannot advance the season. An update with no usable data leaves the existing Data.lua untouched.

The addon-only ZIP contains a point-in-time shared snapshot. The Windows bundle adds an hourly updater and focused exact-profile lookups. It discovers your own Nightslayer and Dreamscythe character folders automatically; encountered players are queued after WoW saves its variables. WoW itself cannot contact websites, and externally updated data becomes visible after the next login or `/reload`.

## Data and privacy

The shared GitHub snapshot contains ratings keyed by deterministic realm-aware lookup hashes, not raw names. These keys are pseudonymous, not encryption. Exact names encountered in game remain in the addon's SavedVariables queue and in the local companion cache; recent requests expire after 30 days and unused exact cache rows after 90 days.

Installed companions are read-only GitHub clients and receive no repository credential. They do not upload user-submitted data, chat text, account details, machine identifiers, or credentials. See [`source/README.txt`](source/README.txt) for the full design and uninstall details.

Ratings currently come from [IronForge](https://ironforge.pro/). [Xunamate Anniversary](https://anniversary.xunamate.gg/) is linked as a useful independent live-rank cross-check, but the addon does not scrape or depend on its private API.

## Development

- Addon and Windows companion: `source/`
- Shared snapshot publisher: `../central-rating-data/`
- License: [MIT](LICENSE)

This community project is not affiliated with Blizzard Entertainment, IronForge, or Xunamate.
