local addon = "nightslayer-rating/source/Addon/NightslayerRating/"
dofile(addon .. "RatingColors.lua")
local colors = NightslayerRatingColors
time = function() return 1789067767 end
date = os.date
local data = {
    meta = { region = "US", season = 3, previousSeason = 2 },
    cutoffs = {
        [2] = {
            [2] = { updated = 1788220271, thresholds = {2803, 2481, 1944, 1629, 1458} },
            [3] = { updated = 1788220271, thresholds = {2493, 2269, 1913, 1662, 1482} },
            [5] = { updated = 1788220271, thresholds = {2340, 2166, 1854, 1640, 1466} },
        },
        [3] = {
            [2] = { updated = time(), thresholds = {2199, 2058, 1863, 1676, 1498} },
            [3] = { updated = time(), thresholds = {2177, 2006, 1844, 1690, 1500} },
            [5] = { updated = time(), thresholds = {2255, 2078, 1837, 1644, 1493} },
        },
    },
}
local hexes = {"ff8000", "a335ee", "0070dd", "1eff00", "ffffff", "aaaaaa"}
for season = 2, 3 do
    for _, bracket in ipairs({2, 3, 5}) do
        for index, minimum in ipairs(data.cutoffs[season][bracket].thresholds) do
            assert(colors.Band(data, minimum, bracket, season).hex == hexes[index])
            assert(colors.Band(data, minimum + 1, bracket, season).hex == hexes[index])
            assert(colors.Band(data, minimum - 1, bracket, season).hex == hexes[index + 1])
        end
    end
end
assert(colors.Band(data, 0, 2, 3).label == "Inactive")
assert(colors.Band(data, nil, 2, 3).label == "Inactive")
assert(colors.Band(data, 2400, 2, 2).hex == "0070dd")
assert(colors.Band(data, 2400, 3, 2).hex == "a335ee")
assert(colors.Band(data, 2400, 5, 2).hex == "ff8000")
assert(colors.Band(data, 2400, 2, 3).hex == "ff8000")
assert(colors.Band(data, 2900).hex == "ffffff") -- all-time provenance unknown
assert(colors.Band(data, 2400, 2, 4).hex == "ffffff") -- never reuse S3 for S4
data.cutoffs[3][2].thresholds[1] = 2450
assert(colors.Band(data, 2400, 2, 3).hex == "a335ee") -- daily cutoff movement
assert(colors.Band(data, 2400, 2, 2).hex == "0070dd") -- archive unaffected
assert(not colors.Status(data):find("stale", 1, true))
data.cutoffs[3][2].updated = time() - 49 * 3600
assert(colors.Status(data):find("stale", 1, true))
data.cutoffs[3][2] = nil
assert(colors.Band(data, 2400, 2, 3).hex == "ffffff")
assert(colors.Status(data):find("2v2 unavailable", 1, true))
data.cutoffs[3][2] = { updated = time(), thresholds = {100, 200, 300, 400, 500} }
assert(colors.Band(data, 2400, 2, 3).hex == "ffffff")
data.meta.region = "EU"
assert(colors.Band(data, 2900, 5, 2).hex == "ffffff")
data.meta.region = "US"
data.cutoffs[3][2] = { updated = time(), thresholds = {2199, 2058, 1863, 1676, 1498} }

-- Exercise the real tooltip and whisper entry points with both data formats.
local hooks, events, messages, lines = {}, {}, {}, {}
wipe = function(t) for key in pairs(t) do t[key] = nil end return t end
GameTooltip = {
    HookScript = function(_, event, callback) hooks[event] = callback end,
    IsShown = function() return true end,
    GetUnit = function() return "Twinname", "mouseover" end,
    AddLine = function(_, line) lines[#lines + 1] = line end,
    AddDoubleLine = function(_, left, right) lines[#lines + 1] = left .. " " .. right end,
    Show = function() end,
}
UnitIsPlayer = function() return true end
UnitName = function() return "Twinname", "Nightslayer" end
UnitFullName = UnitName
C_Timer = { After = function(_, callback) callback() end }
CreateFrame = function()
    return { RegisterEvent = function() end,
        SetScript = function(_, event, callback) events[event] = callback end }
end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) messages[#messages + 1] = message end }
SlashCmdList = {}
data.sharedPlayers = {}
data.players = {
    ["Nightslayer|Twinname"] = {
        name = "Twinname", realm = "Nightslayer", exact = true,
        current = { [2] = 2058 }, previous = { [2] = 2481 }, best = { [2] = 2900 },
    },
}
NightslayerRatingData = data
dofile(addon .. "Options.lua")
dofile(addon .. "TitleTracker.lua")
dofile(addon .. "Status.lua")
assert(loadfile(addon .. "Core.lua"))("NightslayerRating")
events.OnEvent(nil, "CHAT_MSG_WHISPER", "ignored", "Twinname-Nightslayer")
assert(#messages == 1)
assert(messages[1]:find("Current S3 |cffa335ee2058|r", 1, true))
assert(not messages[1]:find("S2 ", 1, true))
assert(messages[1]:find("Peak |cffff80002900|r", 1, true))
hooks.OnTooltipSetUnit(GameTooltip)
local tooltip = table.concat(lines, "\n")
assert(tooltip:find("Current S3 |cffa335ee2058|r", 1, true))
assert(not tooltip:find("S2 ", 1, true))
assert(tooltip:find("Peak |cffff80002900|r", 1, true))

-- A legacy six-number row has no previous-season rating; do not relabel its best.
data.players = { ["Nightslayer|Twinname"] = { 0, 0, 0, 2900, 0, 0,
    name = "Twinname", realm = "Nightslayer" } }
data.sharedPlayers = {}
assert(loadfile(addon .. "Core.lua"))("NightslayerRating")
events.OnEvent(nil, "CHAT_MSG_WHISPER", "ignored", "Twinname-Nightslayer")
assert(not messages[2]:find("S2 ", 1, true))
assert(messages[2]:find("Observed |cffff80002900|r*", 1, true))

data.players["Nightslayer|Twinname"][7] = 2481
assert(loadfile(addon .. "Core.lua"))("NightslayerRating")
events.OnEvent(nil, "CHAT_MSG_WHISPER", "ignored", "Twinname-Nightslayer")
assert(not messages[3]:find("S2 ", 1, true))
assert(messages[3]:find("Inactive", 1, true))

-- An identical lifetime peak gets a different S2 color in each bracket;
-- S3 color changes must never recolor that fixed historical comparison.
data.players = { ["Nightslayer|Twinname"] = {
    name = "Twinname", realm = "Nightslayer", exact = true,
    current = { [2] = 2400, [3] = 2400, [5] = 2400 },
    best = { [2] = 2400, [3] = 2400, [5] = 2400 },
} }
assert(loadfile(addon .. "Core.lua"))("NightslayerRating")
events.OnEvent(nil, "CHAT_MSG_WHISPER", "ignored", "Twinname-Nightslayer")
assert(messages[4]:find("Current S3 |cffff80002400|r", 1, true))
assert(messages[4]:find("Peak |cff0070dd2400|r", 1, true))
assert(messages[4]:find("Peak |cffa335ee2400|r", 1, true))
assert(messages[4]:find("Peak |cffff80002400|r", 1, true))
data.cutoffs[3][2].thresholds[1] = 2500
assert(loadfile(addon .. "Core.lua"))("NightslayerRating")
events.OnEvent(nil, "CHAT_MSG_WHISPER", "ignored", "Twinname-Nightslayer")
assert(messages[5]:find("Current S3 |cffa335ee2400|r", 1, true))
assert(messages[5]:find("Peak |cff0070dd2400|r", 1, true))

-- Preferences gate the actual event handlers without suppressing other surfaces.
NightslayerRatingSettings.whispers = false
events.OnEvent(nil, "CHAT_MSG_WHISPER", "ignored", "Othername-Nightslayer")
assert(#messages == 5)
NightslayerRatingSettings.whispers = true
NightslayerRatingSettings.units = false
wipe(lines)
GameTooltip.NightslayerRatingToken = nil
hooks.OnTooltipSetUnit(GameTooltip)
assert(#lines == 0)
NightslayerRatingSettings.units = true
NightslayerRatingSettings.bracket3 = false
NightslayerRatingSettings.bracket5 = false
IsShiftKeyDown = function() return true end
hooks.OnTooltipSetUnit(GameTooltip)
tooltip = table.concat(lines, "\n")
assert(tooltip:find("2v2", 1, true) and not tooltip:find("3v3", 1, true))
assert(tooltip:find("100 below Rank One cutoff", 1, true))
NightslayerRatingSettings.nextCutoff = false
wipe(lines)
GameTooltip.NightslayerRatingToken = nil
hooks.OnTooltipSetUnit(GameTooltip)
assert(not table.concat(lines, "\n"):find("below Rank One", 1, true))
data.players["Nightslayer|Twinname"].exactBrackets = { [3] = true }
wipe(lines)
GameTooltip.NightslayerRatingToken = nil
hooks.OnTooltipSetUnit(GameTooltip)
assert(table.concat(lines, "\n"):find("Observed |cff0070dd2400|r*", 1, true))
assert(not table.concat(lines, "\n"):find("Peak |cff0070dd2400|r", 1, true))
print("Rating color boundaries, season isolation, tooltip and whisper tests passed")
