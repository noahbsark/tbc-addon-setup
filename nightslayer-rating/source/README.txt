NIGHTSLAYER RATING 1.0.0
TBC Anniversary (Interface 20506) - Nightslayer US

WHAT IT DOES
------------
Hover a player in Blizzard's Looking For Group / Group Finder panel. The normal
tooltip gains IronForge 2v2, 3v3, and 5v5 rows showing current rating and the
highest recorded rating.

INSTALLATION (WINDOWS)
----------------------
1. Close World of Warcraft if it is open.
2. Extract this ZIP, then double-click Install.cmd.
3. Start TBC Anniversary. That is the only setup required.

The installer normally finds the _anniversary_ game folder itself. If WoW is in
an unusual location, it asks you to select that folder once. The first data sync
can take a few minutes; later syncs are smaller.

HOW AUTOMATIC DATA WORKS
------------------------
WoW addons are not allowed to contact websites. This package therefore installs
a small PowerShell updater for the current Windows user. It uses IronForge's
public TBC Anniversary endpoints and runs every 30 minutes without opening a
window.

- Current ratings are downloaded in three bulk leaderboard requests and are
  cached for Nightslayer players.
- Group Finder names are quietly queued by the addon. After WoW next saves its
  settings during a normal logout or exit, the updater fetches exact lifetime
  peaks only for those encountered names. This keeps traffic respectful.
- Until an exact player lookup has completed, the tooltip labels the seasonal
  snapshot as "Best cached*". It never presents that approximation as exact.
- WoW reads addon files only while loading. New data appears on the next normal
  game start. /reload also loads it immediately, but is not required.

The included Reefey record is ready as a working example. IronForge can lag the
live game, so the tooltip reflects the newest data that IronForge publishes.

OPTIONAL COMMANDS
-----------------
/nsr                 Show cache status
/nsr on              Enable tooltip additions
/nsr off             Disable tooltip additions
/nsr lookup Reefey   Prioritize a name for an exact lookup

"Update Now.cmd" is included for troubleshooting; normal use does not require
it.

PRIVACY AND SAFETY
------------------
The updater sends no account credentials and does not read game memory, control
WoW, or automate gameplay. It reads only this addon's own SavedVariables file to
learn which public Nightslayer character names were encountered, then requests
their public IronForge pages. Its cache and log live in:

  %LOCALAPPDATA%\NightslayerRating

The installer creates one current-user scheduled task named
"NightslayerRating Updater". If Windows blocks task creation, it falls back to
an update at Windows sign-in.

UNINSTALLATION
--------------
Double-click Uninstall.cmd. It removes the addon, scheduled updater, and local
cache. Character names may remain in WoW's account SavedVariables until WoW
rewrites or you manually remove that old file; they are inert without the
updater.

This community addon is not affiliated with Blizzard Entertainment or
IronForge. Data source: https://ironforge.pro/
