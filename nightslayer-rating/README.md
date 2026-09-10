# Nightslayer Rating

Free World of Warcraft TBC Anniversary addon for Nightslayer and Dreamscythe US. It adds current-season, previous-season, observed, and exact-record 2v2, 3v3, and 5v5 ratings to Group Finder tooltips, normal player tooltips, and a private local summary when someone whispers you.

[Download and install](https://noahbsark.github.io/tbc-addon-setup/nightslayer-rating/) · [Report a bug](https://github.com/noahbsark/tbc-addon-setup/issues) · [Shared data status](https://github.com/noahbsark/tbc-addon-setup/releases/tag/ratings-data)

## What the numbers mean

- **Current** is the newest current-season rating published by the source.
- **S2** (while the current season is S3) is the previous season's archived leaderboard rating. It is separate from the all-time record, and is not a season peak or proof of an earned title. An unavailable rating displays `--`.
- **Record** is the exact lifetime bracket high returned by the character profile after the Windows companion processes a character.
- **Observed\*** is only a rating found in a tracked leaderboard snapshot. It is never presented as a lifetime peak.
- Rated, Competitive, Strong, Excellent, and Elite remain neutral visual labels. Their colors now follow the matching US season and bracket's Challenger, Rival, Duelist, Gladiator, and Rank One cutoff estimates. A positive rating below Challenger is gray; missing cutoffs and all-time Record/Observed ratings are neutral white. Zero/missing ratings remain gray and inactive.

## Season and bracket colors (v1.3.0)

Season 2 is frozen to the final IronForge US archive cutoffs supplied for this update:

| Bracket | Orange: Merciless Gladiator | Purple: Gladiator | Blue: Duelist | Green: Rival | White: Challenger |
| --- | ---: | ---: | ---: | ---: | ---: |
| [2v2](https://ironforge.pro/anniversary/leaderboards/archive/season-2/US/2/) | 2803 | 2481 | 1944 | 1629 | 1458 |
| [3v3](https://ironforge.pro/anniversary/leaderboards/archive/season-2/US/3/) | 2493 | 2269 | 1913 | 1662 | 1482 |
| [5v5](https://ironforge.pro/anniversary/leaderboards/archive/season-2/US/5/) | 2340 | 2166 | 1854 | 1640 | 1466 |

Thresholds are inclusive. Current S3 ratings use the live [2v2](https://ironforge.pro/anniversary/leaderboards/US/2/), [3v3](https://ironforge.pro/anniversary/leaderboards/US/3/), and [5v5](https://ironforge.pro/anniversary/leaderboards/US/5/) cutoff values fetched by the hourly shared publisher. Each bracket keeps its own source timestamp. Cutoffs older than 48 hours are marked stale; `/nsr cutoffs` shows every current and previous-season threshold. A failed or invalid refresh retains the last valid cutoff data. No guessed fixed bands or cross-bracket substitutions are used.

On a future season rollover, the current and previous season labels follow the snapshot metadata. The S2 archive remains frozen. Record/Observed stays all-time and neutral because those numbers have no season provenance.

To upgrade from 1.2.x, close WoW, extract the **1.3.0 Windows bundle**, and run `Install.cmd` again. This installs the new coloring code and companion while preserving the existing exact-profile cache. Subsequent data and cutoff changes use the existing updater; log in or `/reload` to see them. The addon-only ZIP is a point-in-time snapshot and does not refresh itself.

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
