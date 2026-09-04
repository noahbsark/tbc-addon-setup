# Nightslayer Rating

Free World of Warcraft TBC Anniversary addon for Nightslayer and Dreamscythe US. It adds current and highest-recorded 2v2, 3v3, and 5v5 ratings to Group Finder tooltips, normal player tooltips, and a private local summary when someone whispers you.

[Download and install](https://noahbsark.github.io/tbc-addon-setup/nightslayer-rating/) · [Report a bug](https://github.com/noahbsark/tbc-addon-setup/issues) · [Shared data status](https://github.com/noahbsark/tbc-addon-setup/releases/tag/ratings-data)

## What the numbers mean

- **Current** is the newest current-season rating published by the source.
- **High** is the exact lifetime bracket high returned by the character profile after the Windows companion processes a recently encountered name.
- **Best cached\*** is the highest rating seen in the tracked leaderboards when an exact profile has not completed.
- Rated, Competitive, Strong, Excellent, and Elite are neutral visual bands. They are not official arena titles or achievement claims.

The addon-only ZIP contains a point-in-time shared snapshot. The Windows bundle adds an hourly updater and focused exact-profile lookups. WoW itself cannot contact websites, and externally updated data becomes visible after the next login or `/reload`.

## Data and privacy

The shared GitHub snapshot contains ratings keyed by deterministic realm-aware lookup hashes, not raw names. These keys are pseudonymous, not encryption. Exact names encountered in game remain in the addon's SavedVariables queue and in the local companion cache; recent requests expire after 30 days and unused exact cache rows after 90 days.

Installed companions are read-only GitHub clients and receive no repository credential. They do not upload user-submitted data, chat text, account details, machine identifiers, or credentials. See [`source/README.txt`](source/README.txt) for the full design and uninstall details.

Ratings currently come from [IronForge](https://ironforge.pro/). [Xunamate Anniversary](https://anniversary.xunamate.gg/) is linked as a useful independent live-rank cross-check, but the addon does not scrape or depend on its private API.

## Development

- Addon and Windows companion: `source/`
- Shared snapshot publisher: `../central-rating-data/`
- License: [MIT](LICENSE)

This community project is not affiliated with Blizzard Entertainment, IronForge, or Xunamate.
