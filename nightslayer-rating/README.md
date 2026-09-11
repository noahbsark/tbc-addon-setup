# Nightslayer Rating

Free World of Warcraft TBC Anniversary addon for Nightslayer and Dreamscythe US. It adds Current and lifetime Peak 2v2, 3v3, and 5v5 ratings to Group Finder tooltips, player tooltips, and private whisper summaries, with an optional highest known arena title.

[Download and install](https://noahbsark.github.io/tbc-addon-setup/nightslayer-rating/) · [Report a bug](https://github.com/noahbsark/tbc-addon-setup/issues) · [Shared data status](https://github.com/noahbsark/tbc-addon-setup/releases/tag/ratings-data)

## New in 1.4.0

- `/nsr options` opens display preferences: Group Finder, player tooltips, private whisper summaries, 2v2/3v3/5v5 filters, known titles, and compact mode. Shift-hover reveals details, including distance to the next **current-season** cutoff. Unknown cutoffs have no invented distance; stale cutoffs are labeled.
- `/nsr status` separates the source rating/cutoff age from the latest download attempt. It reports complete, partial, failed, or retained-cache results and pending/unavailable peak lookups. Per-bracket source timestamps prevent a fresh 3v3 update from making stale 2v2 data appear fresh. Status is loaded at login or `/reload`.
- Exact peaks refresh daily for your local characters and priority players viewed within the last three days. Less active profiles remain on a weekly cache. The existing 50-requests-per-run budget remains; persistent failures rotate behind untried requests.
- The companion checks for new addon versions daily and displays a notification in game. To apply one, close WoW and run **Upgrade.cmd**, also available under **Nightslayer Rating → Upgrade** in the Windows Start menu. The helper checks the release manifest, ZIP checksum, paths, and version before installing. The installer preserves rating caches, backs up the previous installation, and attempts automatic rollback if file replacement fails. Hourly background tasks continue to refresh data; code upgrades run only when you launch the helper.

### Highest known arena title

This is **the highest arena title this client has confirmed**, rather than a complete title history for every player. For your own character, the addon reads the game's owned-title list. For another visible character, it records an arena title actually displayed in the unit's PvP name. It retains the highest observed tier and distinguishes same-name characters by realm and, when visible, GUID. An unknown title is omitted. Title observations are stored only in your local SavedVariables; they are never uploaded or added to the public shared cache.

The recognized English-client arena titles are Challenger, Rival, Duelist, Gladiator, and the named TBC Rank One titles. Rank One variants are the same tier; the most recently observed variant is displayed. The addon cannot see every unequipped title another character owns. A Group Finder player can show a known title after this client has observed that character in game.

IronForge exposes `reward_list` and per-season `title` fields, but its profile UI calls that history **previous placements**, and its current-season title field includes still-unearned cutoff ranges. Those fields and rating colors are not used as proof of title ownership. Game API references: [title functions](https://github.com/Gethe/wow-ui-source/blob/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/TitleDocumentation.lua), [unit PvP name](https://github.com/Gethe/wow-ui-source/blob/classic_anniversary/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua).

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

To upgrade from 1.3.1 or earlier, close WoW, extract the **1.4.0 Windows bundle**, and run `Install.cmd`. This installs the new code and upgrade helper while preserving your exact-profile cache and game settings. Subsequent code releases can use `Upgrade.cmd`. Data and cutoff changes use the existing updater; log in or `/reload` to see them. The addon-only ZIP is a point-in-time snapshot and does not refresh itself.

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
