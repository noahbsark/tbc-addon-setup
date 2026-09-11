local addon = "nightslayer-rating/source/Addon/NightslayerRating/"
time = function() return 1789082481 end
date = os.date
dofile(addon .. "RatingColors.lua")
dofile(addon .. "Options.lua")
dofile(addon .. "TitleTracker.lua")
dofile(addon .. "Status.lua")
local UI, Titles, Colors = NightslayerRatingUI, NightslayerRatingTitles, NightslayerRatingColors
local data = { meta = { region = "US", season = 3, generated = time(), leaderboardUpdated = time() - 72 * 3600 },
    cutoffs = { [3] = {} } }
for _, bracket in ipairs({2,3,5}) do
    data.cutoffs[3][bracket] = { updated = time(), thresholds = {2200,2100,1900,1700,1500} }
end
assert(Colors.NextCutoff(data, 1863, 2) == "37 below Duelist cutoff")
assert(Colors.NextCutoff(data, 1900, 2) == "200 below Gladiator cutoff")
assert(Colors.NextCutoff(data, 2200, 2) == "At or above Rank One cutoff")
assert(Colors.NextCutoff(data, 0, 2) == nil)
data.cutoffs[3][2].updated = time() - 49 * 3600
assert(Colors.NextCutoff(data, 1863, 2):find("stale cutoff", 1, true))
data.cutoffs[3][2] = nil
assert(Colors.NextCutoff(data, 1863, 2) == nil)
NightslayerRatingSyncStatus = { mode = "cached", lastAttempt = time(), lastSuccess = time() - 3 * 86400,
    pendingProfiles = 14, failedProfiles = 2, availableVersion = "1.4.1" }
local status = table.concat(UI.StatusLines(data, true, { exact = true, exactFetchedAt = time() - 86400 }), "\n")
assert(status:find("3d ago (stale)", 1, true)) -- never use the freshly generated timestamp
assert(status:find("Download failed", 1, true))
assert(status:find("Peak checked: 1d ago", 1, true))
assert(status:find("pending: 14", 1, true))
assert(status:find("1.4.1 available", 1, true))
assert(UI.NewerVersion("1.10.0", "1.9.0"))
assert(not UI.NewerVersion("1.4.0", "1.4.0"))
assert(not UI.NewerVersion("bad", "1.4.0"))
data.meta.leaderboardUpdates = { [2] = time(), [3] = time() - 4 * 86400, [5] = time() }
assert(UI.StatusLines(data, false)[1]:find("4d ago (stale)", 1, true))

-- Only real unit API observations or the player's owned-title list are accepted.
local character, realm, guid, displayed = "Example", "Nightslayer", "Player-123-456", "Duelist Example"
UnitName = function() return character, realm end
UnitGUID = function() return guid end
UnitIsPlayer = function() return true end
UnitPVPName = function() return displayed end
Titles.Observe("mouseover")
assert(Titles.Get(character, realm).title == "Duelist")
displayed = "Challenger Example"
Titles.Observe("mouseover")
assert(Titles.Get(character, realm).title == "Duelist") -- retain the highest actually seen
displayed = "Merciless Gladiator Example"
Titles.Observe("target")
assert(Titles.Get(character, realm).title == "Merciless Gladiator")
assert(Titles.Line(character, realm):find("Highest known title:", 1, true))
realm = "Dreamscythe"
displayed = "Example"
Titles.Observe("mouseover")
assert(not Titles.Get(character, realm)) -- realm identity matters
displayed = "Someone says Gladiator Example"
Titles.Observe("mouseover")
assert(not Titles.Get(character, realm)) -- no free-text or substring claims
GetNumTitles = function() return 3 end
IsTitleKnown = function(id) return id == 2 end
GetTitleName = function(id) return ({"Merciless Gladiator ", "Gladiator %s", "Duelist "})[id] end
Titles.Observe("player")
assert(Titles.Get(character, realm).title == "Gladiator")
guid = "Player-123-789"
displayed = "Example"
Titles.Observe("mouseover")
assert(not Titles.Get(character, realm)) -- do not transfer evidence to a reused name
NightslayerRatingSettings.titles = false
displayed = "Merciless Gladiator Example"
Titles.Observe("mouseover")
assert(not Titles.Line(character, realm))
print("Status freshness, preferences, cutoff distances and confirmed title observations passed")
