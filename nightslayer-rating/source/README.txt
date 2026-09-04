NIGHTSLAYER RATING 1.2.0
TBC Anniversary (Interface 20506) - Nightslayer and Dreamscythe US

WHAT CHANGED IN 1.2.0
---------------------
- Replaced inferred Rank One/Gladiator/etc. labels with neutral visual bands:
  Rated, Competitive, Strong, Excellent, and Elite. Official arena titles are
  based on end-of-season ladder rank and cannot be inferred from a peak rating.
- An inactive bracket now says Inactive even when an older peak exists. Current
  and peak numbers remain independently color coded for quick scanning.
- Cut packaged rating data to a compact format, reducing addon load work and
  memory use without changing the lookup result.
- Hardened shared-cache downloads with strict compressed, decompressed, record,
  and rating limits.
- Reduced exact-profile traffic: only recently encountered characters are kept,
  and successful exact profiles refresh no more than weekly.
- Fixed repeated Vanilla Style tooltip growth and stale automatic-updater entries.
- The addon-only build now clearly distinguishes its packaged leaderboard cache
  from exact lifetime highs that require the Windows companion.

If an earlier version is installed, close WoW, extract this release, and run
Install.cmd again. Your existing exact-profile cache is migrated and preserved.

WHAT IT DOES
------------
Hover a player in Blizzard's Looking For Group / Group Finder panel, in the
world, on a unit frame, or in a battleground. The tooltip gains color-coded
IronForge 2v2, 3v3, and 5v5 rows showing current rating and the highest recorded
rating.

When a character whispers you, or you whisper them, a private [NSR] line in
your chat shows the same summary once per character per login. The other player
does not receive a message.

Unsuffixed names default to Nightslayer. Cross-realm unit tooltips and names such
as Player-Dreamscythe are detected automatically.

INSTALLATION (WINDOWS)
----------------------
1. Close World of Warcraft if it is open.
2. Extract this ZIP, then double-click Install.cmd.
3. Start TBC Anniversary. That is the only setup required.

The installer normally finds the _anniversary_ game folder itself. If WoW is in
an unusual location, it asks you to select that folder once. It installs a quiet
current-user updater that refreshes every hour and at Windows sign-in.

HOW AUTOMATIC DATA WORKS
------------------------
WoW addons cannot contact websites. The Windows companion performs network work
outside the game and writes Data.lua, which WoW reads at login or /reload.

1. A scheduled GitHub job builds a pseudonymous snapshot of current and
   historical leaderboard ratings for Nightslayer and Dreamscythe from IronForge.
2. Each installed companion downloads that read-only compressed snapshot. No
   GitHub password or token is installed on users' computers.
3. Names encountered in Group Finder, unit tooltips, battlegrounds, or whispers
   are saved in this addon's own SavedVariables queue.
4. After WoW next saves that queue during logout, exit, or /reload, the companion
   asks IronForge for exact lifetime highs for up to 10 recent profiles per run.
5. New data appears at the next login or /reload. A running WoW client cannot
   hot-load an externally changed addon file.

If GitHub's shared snapshot is temporarily unavailable, the companion falls back
to IronForge's bulk endpoints and continues working. A tooltip says "Best cached*"
until an exact profile lookup has completed; it never labels an approximation as
an exact lifetime high.

Colors are a fixed visual guide: gray inactive, white rated, green competitive
(1500+), blue strong (1800+), purple excellent (2100+), and orange elite (2400+).
These labels are intentionally not official arena titles or achievement claims.

OPTIONAL COMMANDS
-----------------
/nsr                              Show cache status
/nsr on                           Enable tooltip and chat additions
/nsr off                          Disable tooltip and chat additions
/nsr lookup Reefey                Queue a Nightslayer character
/nsr lookup Player-Dreamscythe    Queue a Dreamscythe character

"Update Now.cmd" is included for troubleshooting; normal use does not require it.

WHY CLIENTS DO NOT WRITE TO GITHUB
----------------------------------
Installed companions are read-only GitHub clients. Giving them a shared write
credential would let anyone extract it, falsify ratings, or damage the database.
The central job independently verifies bulk data, while exact character requests
remain private and automatic on each user's computer.

PRIVACY AND SAFETY
------------------
The public snapshot contains arena-rating maps indexed by realm-aware lookup
hashes; it does not publish raw character names. The companion sends no Battle.net
credentials, chat text, account names, machine identifiers, or game-memory data.
It reads only this addon's SavedVariables queue.

Local cache and logs live in:

  %LOCALAPPDATA%\NightslayerRating

The installer creates one current-user scheduled task named
"NightslayerRating Updater". If Windows blocks task creation, it falls back to an
update at Windows sign-in.

UNINSTALLATION
--------------
Double-click Uninstall.cmd. It removes the addon, scheduled updater, and local
cache. Character names may remain in WoW's account SavedVariables until WoW
rewrites or you manually remove that old file; they are inert without the updater.

This community addon is not affiliated with Blizzard Entertainment or IronForge.
Data source: https://ironforge.pro/
