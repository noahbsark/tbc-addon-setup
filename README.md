# TBC Addon Setup

A static GitHub Pages site that turns one WoW Classic TBC settings template into a personalized download. Processing happens in the visitor's browser. The repository also hosts the free [Nightslayer Rating addon](nightslayer-rating/) and its Windows companion.

## Run it directly on your computer

Extract the complete project ZIP, then double-click `index.html`. The settings template is embedded across `template-chunk-1.js` through `template-chunk-5.js`, and the ZIP library is self-hosted in `vendor/`, so no local web server or third-party script is required. Keep all extracted website files together.

## Add your settings template

1. Make a ZIP whose internal path begins with:
   `WTF/Account/ACCOUNTNAME/SERVERNAME/CHARACTERNAME/`
2. Put the character-specific files from your own `WTF/Account/...` folder inside that path.
3. Sanitize it before embedding it. Do **not** include your real account, server, character, chat logs, screenshots, inventory/economic databases, cached waypoints, archived imports, or credentials.
4. Split the base64-encoded ZIP across the five `template-chunk-*.js` files.
5. Run `python tools/audit_template.py` before publishing. The Pages workflow runs the same fail-closed privacy check.

Example ZIP structure:

```text
ACCOUNTNAME/
└── SERVERNAME/
    └── CHARACTERNAME/
        ├── AddOns.txt
        ├── config-cache.wtf
        └── SavedVariables/
```

The site renames all three placeholders when generating the download. If your addon settings also rely on account-level SavedVariables, include them beneath `ACCOUNTNAME/` as appropriate.

The bundled template is curated from the supplied full WTF archive. It includes UI-focused account and character settings. Chat/Prat history, inventory and score caches, saved waypoints, WeakAuras archives/editor caches, Battle.net-related data, stale backups, and source character identities are excluded. The automated audit also rejects email addresses, BattleTags, Discord invites, Windows user paths, player GUIDs, unsafe ZIP paths, and known non-placeholder identities.

## Nightslayer Rating

The addon download page is at `nightslayer-rating/`. Its source is in `nightslayer-rating/source/`, while `central-rating-data/` builds the read-only pseudonymous rating snapshot used by the addon. See the addon README for exact installation, privacy, and data-source behavior.

## Publish with GitHub Pages

Push this folder to a GitHub repository. In **Settings → Pages**, choose **GitHub Actions** as the source. The included workflow publishes the site after every push to `main`.

## The 500 MB AddOns folder

Do not commit it to this repository: GitHub blocks individual files over 100 MB and recommends repositories stay well below 1 GB. Host a release archive elsewhere (or use a curated addon-manager list), then add a separate link to it. The settings generator does not need the AddOns folder.
