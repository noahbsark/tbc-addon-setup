# TBC Addon Setup

A static GitHub Pages site that turns one WoW Classic TBC settings template into a personalized download. Processing happens in the visitor's browser.

## Run it directly on your computer

Extract the complete project ZIP, then double-click `index.html`. The settings template is embedded in `template-data.js`, so no local web server is required. Keep all extracted website files together.

## Add your settings template

1. Make a ZIP whose internal path begins with:
   `WTF/Account/ACCOUNTNAME/SERVERNAME/CHARACTERNAME/`
2. Put the character-specific files from your own `WTF/Account/...` folder inside that path.
3. Name it `options-template.zip` and place it in `assets/`.
4. Do **not** include your real account, server, character, chat logs, screenshots, or credentials.

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

The bundled template is curated from the supplied full WTF archive. It includes UI-focused account and character settings, while excluding chat caches, histories, economic and quest databases, Battle.net-related data, stale backup files, unrelated character identities, and the Skill Capped addon profile file.

## Publish with GitHub Pages

Push this folder to a GitHub repository. In **Settings → Pages**, choose **GitHub Actions** as the source. The included workflow publishes the site after every push to `main`.

## The 500 MB AddOns folder

Do not commit it to this repository: GitHub blocks individual files over 100 MB and recommends repositories stay well below 1 GB. Host a release archive elsewhere (or use a curated addon-manager list), then add a separate link to it. The settings generator does not need the AddOns folder.
