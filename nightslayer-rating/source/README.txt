NIGHTSLAYER RATING 1.3.1
TBC Anniversary (Interface 20506) - Nightslayer and Dreamscythe US

WHAT CHANGED IN 1.3.1
---------------------
- Removed the S2 rating column. The display now shows Current and lifetime Peak
  (Observed* until an exact lifetime high has been fetched).
- Current uses the live current-season US bracket cutoffs. Peak/Observed uses
  the fixed S2 cutoffs for its bracket as a color comparison.
- The updater accepts the existing v4/v5 shared snapshot format as well as v6.
- The Windows bundle includes a local snapshot for first-run source outages.
- Failed future-season probes cannot advance the current season. HTTP 500 and
  empty responses preserve the affected bracket's cached data while the rest
  of the update continues. An empty failed refresh cannot overwrite Data.lua.

WHAT CHANGED IN 1.3.0
---------------------
- Current ratings use the current season's US cutoff estimates for their own
  2v2, 3v3, or 5v5 bracket. The shared hourly refresh includes cutoff updates.
- A separate S2 column shows the previous season's archived rating. Its colors
  use the frozen final S2 US cutoffs shown below. Record/Observed remains the
  all-time value and is neutral white because its season is unknown.
- Tooltips and /nsr show the cutoff date and mark it stale after 48 hours.
  /nsr cutoffs lists the current and previous-season thresholds for all brackets.
- Invalid cutoff refreshes retain the last valid data. The updater migrates
  older caches without discarding exact lifetime records.

WHAT CHANGED IN 1.2.7
---------------------
- Each manual pass now processes up to 50 due profiles instead of 25.
- Successful and missing-profile requests use a 0.5-second pacing delay.
- Transient failures use a 3-second backoff before the batch continues.

WHAT CHANGED IN 1.2.6
---------------------
- A 5xx error or other transient failure for one IronForge profile no longer
  aborts the batch. The updater skips it, continues, and saves other results.
- Each pass reports fetched, missing, and transient-error profile counts.

WHAT CHANGED IN 1.2.5
---------------------
- Update Now.cmd now offers another updater pass after every run. Press any key
  to process the next batch, or close the window when finished.

WHAT CHANGED IN 1.2.4
---------------------
- Increased focused exact-profile lookups from 10 to 25 per updater run while
  retaining request pacing and the one-week successful-profile cache.

WHAT CHANGED IN 1.2.3
---------------------
- Older SavedVariables request entries without a Priority field are migrated
  safely instead of interrupting exact-profile queue parsing.
- Updater output now separates profiles due for fetching from fresh cached rows.

WHAT CHANGED IN 1.2.2
---------------------
- SavedVariables can now be read while WoW holds the file open.
- Local character-folder discovery no longer depends on SavedVariables existing.
- Queue diagnostics report the request count and the actual file-read error.

WHAT CHANGED IN 1.2.1
---------------------
- Exact IronForge record ratings are now labeled "Record"; leaderboard-only
  values are labeled "Observed*" and never presented as lifetime peaks.
- The Windows updater discovers your own supported-realm character folders, so
  it can fetch their exact records without waiting for a SavedVariables flush.
- Fixed the Windows integration test's success detection.

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
IronForge 2v2, 3v3, and 5v5 rows showing current rating and, after an exact
profile lookup, the lifetime peak rating.

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
3. Your own Nightslayer and Dreamscythe characters are discovered automatically
   from their local WTF folders. Names encountered in Group Finder, unit
   tooltips, battlegrounds, or whispers are saved in this addon's queue.
4. After WoW saves encountered names during logout, exit, or /reload, the
   companion asks IronForge for exact record ratings for up to 50 profiles/run.
5. New data appears at the next login or /reload. A running WoW client cannot
   hot-load an externally changed addon file.

If GitHub's shared snapshot is temporarily unavailable, the companion falls back
to IronForge's bulk endpoints and continues working. A tooltip says "Observed*"
until an exact profile lookup has completed and explains that this is only a
leaderboard snapshot, never an exact lifetime high.

Colors use US cutoff estimates separately for each season and bracket: orange
Rank One range (Elite), purple Gladiator range (Excellent), blue Duelist range
(Strong), green Rival range (Competitive), and white Challenger range (Rated).
Positive ratings below Challenger are gray. Missing cutoffs use neutral white;
zero or missing ratings are gray and display --. These ranges do not assert
that a player earned an arena title or met the season's reward eligibility.

Frozen S2 thresholds (inclusive; IronForge archive, August 31, 2026):
Bracket    Orange    Purple    Blue    Green    White
2v2        2803      2481      1944    1629     1458
3v3        2493      2269      1913    1662     1482
5v5        2340      2166      1854    1640     1466

Only Current and Peak are displayed; there is no S2 rating column. Peak is the
lifetime bracket high, colored against the fixed S2 thresholds above. Observed*
uses that same comparison while the exact lifetime lookup is pending. Current
S3 cutoffs follow source updates through the shared publisher and Windows
companion. New files become visible after login or /reload. A future season
rollover changes Current while the Peak comparison remains fixed to S2.

OPTIONAL COMMANDS
-----------------
/nsr                              Show cache status
/nsr on                           Enable tooltip and chat additions
/nsr off                          Disable tooltip and chat additions
/nsr cutoffs                      Show current/S2 comparison cutoff details
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
