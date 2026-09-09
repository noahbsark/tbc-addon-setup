-- Run from the repository root with Lua 5.1+ (WoW APIs are mocked).
local addon = "nightslayer-rating/source/Addon/NightslayerRating/"
local ns = {}
assert(loadfile(addon .. "RatingColors.lua"))("NightslayerRating", ns)
local cutoffs = {
    [2] = {2803, 2481, 1944, 1629, 1458},
    [3] = {2493, 2269, 1913, 1662, 1482},
    [5] = {2340, 2166, 1854, 1640, 1466},
}
local colors = {"ff8000", "a335ee", "0070dd", "1eff00", "ffffff", "aaaaaa"}
for bracket, thresholds in pairs(cutoffs) do
    for index, minimum in ipairs(thresholds) do
        assert(ns.GetRatingBand(minimum, bracket, 2, "US").hex == colors[index])
        assert(ns.GetRatingBand(minimum + 1, bracket, 2, "US").hex == colors[index])
        assert(ns.GetRatingBand(minimum - 1, bracket, 2, "US").hex == colors[index + 1])
    end
    assert(ns.GetRatingBand(nil, bracket, 2, "US").hex == "aaaaaa")
    assert(ns.GetRatingBand(0, bracket, 2, "US").hex == "aaaaaa")
end
for _, season in ipairs({1, 3, 4}) do
    assert(ns.GetRatingBand(2100, 2, season, "US").hex == "a335ee")
end
assert(ns.GetRatingBand(2100, 2, 2, "US").hex == "0070dd")
assert(ns.GetRatingBand(2100, 2, 2, "EU").hex == "a335ee")

function wipe(t) for k in pairs(t) do t[k] = nil end end
function time() return 1788900000.0 end
date = os.date
SlashCmdList = {}
local hooks, events, chats = {}, {}, {}
function hooksecurefunc(name, callback) hooks[name] = callback end
LFGListUtil_SetSearchEntryTooltip = function() end
LFGBrowseSearchEntryTooltip_UpdateAndShow = function() end
local leader = "Reefey"
C_LFGList = { GetSearchResultInfo = function() return {leaderName = leader} end }
C_Timer = { After = function(_, callback) callback() end }
function CreateFrame()
    return { RegisterEvent = function() end, SetScript = function(_, name, callback) events[name] = callback end }
end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) chats[#chats + 1] = text end }
local tooltipHooks, lines = {}, {}
GameTooltip = {
    HookScript = function(_, name, callback) tooltipHooks[name] = callback end,
    IsShown = function() return true end,
    AddLine = function(_, text) lines[#lines + 1] = text end,
    AddDoubleLine = function(_, left, right) lines[#lines + 1] = left .. " " .. right end,
    Show = function() end,
    GetUnit = function() return "Example", "mouseover" end,
}
local unitName, unitRealm = "Example", "Nightslayer"
function UnitIsPlayer() return true end
function UnitFullName() return unitName, unitRealm end
NightslayerRatingData = {
    meta = {region="US", season=3, generated=1788900000, profileLookup=true},
    sharedPlayers = {
        ["ec31af45054a44db"] = {1800, 0, 0, 2600, 1900, 2000, 2026, 1869, 1971},
    },
    players = {
        ["Nightslayer|Example"] = {
            name="Example", realm="Nightslayer", exact=true,
            current={[2]=1800}, best={[2]=2900, [3]=1900}, exactBest={[2]=2900},
            season2={[2]=2026, [3]=1869, [5]=1971}, season2Best={[2]=2175, [3]=2065, [5]=2048},
        },
        ["Dreamscythe|Reefey"] = {name="Reefey", realm="Dreamscythe", current={[2]=1500}, best={[2]=1800}},
    },
}
assert(loadfile(addon .. "Core.lua"))("NightslayerRating", ns)
events.OnEvent(nil, "ADDON_LOADED", "NightslayerRating")
local function reset()
    lines = {}
    tooltipHooks.OnTooltipCleared(GameTooltip)
end
local function contains(text, part) assert(text:find(part, 1, true), "Missing: " .. part .. "\n" .. text) end
local function excludes(text, part) assert(not text:find(part, 1, true), "Unexpected: " .. part) end

hooks.LFGListUtil_SetSearchEntryTooltip(GameTooltip, 1)
local text = table.concat(lines, "\n")
contains(text, "S2 final |cff0070dd2026|r")
contains(text, "S2 final |cff1eff001869|r")
contains(text, "S2 final |cff0070dd1971|r")
contains(text, "Observed |cffffffff2600|r*")
excludes(text, "S2 peak")
excludes(text, "Rank One")
excludes(text, "Gladiator")
local lineCount = #lines
hooks.LFGListUtil_SetSearchEntryTooltip(GameTooltip, 1)
assert(#lines == lineCount, "Repeated hover duplicated rows")

reset()
tooltipHooks.OnTooltipSetUnit(GameTooltip)
text = table.concat(lines, "\n")
contains(text, "Record |cffffffff2900|r")
contains(text, "S2 peak |cff0070dd2175|r")
contains(text, "S2 peak |cff0070dd2065|r")
contains(text, "S2 peak |cff0070dd2048|r")
contains(text, "Observed |cffffffff1900|r*") -- Exactness is per bracket.
events.OnEvent(nil, "CHAT_MSG_WHISPER", "message", "Example")
contains(chats[#chats], "S2 final |cff0070dd2026|r")
contains(chats[#chats], "S2 peak |cff0070dd2175|r")
assert(NightslayerRatingRequests["Nightslayer|Example"])

reset()
unitName, unitRealm = "Reefey", "Dreamscythe"
tooltipHooks.OnTooltipSetUnit(GameTooltip)
text = table.concat(lines, "\n")
contains(text, "Dreamscythe")
contains(text, "1500")
excludes(text, "S2 final")
excludes(text, "2600")

-- An older six-slot snapshot is readable, but has no known season attribution.
NightslayerRatingData.sharedPlayers["ec31af45054a44db"] = {1800, 0, 0, 2600, 0, 0}
reset()
hooks.LFGListUtil_SetSearchEntryTooltip(GameTooltip, 2)
text = table.concat(lines, "\n")
contains(text, "2600")
excludes(text, "S2 final")
NightslayerRatingData.sharedPlayers["ec31af45054a44db"] = {1800, 0, 0, 2600, 0, 0, 2026, 0, 0}

-- Real Vanilla Style hook, including repeat-hover geometry restoration.
local vanilla = {height=100, width=280}
function vanilla:GetHeight() return self.height end
function vanilla:GetWidth() return self.width end
function vanilla:SetHeight(x) self.height=x end
function vanilla:SetWidth(x) self.width=x end
function vanilla:HookScript() end
function vanilla:CreateFontString()
    return {
        SetText=function(self,x) self.text=x end,
        SetTextColor=function() end, SetPoint=function() end, SetJustifyH=function() end, SetWordWrap=function() end,
        ClearAllPoints=function() end, Show=function(self) self.shown=true end,
        Hide=function(self) self.shown=false end,
        GetStringWidth=function(self) return #self.text * 5 end,
    }
end
hooks.LFGBrowseSearchEntryTooltip_UpdateAndShow(vanilla, 1)
local firstHeight = vanilla.height
hooks.LFGBrowseSearchEntryTooltip_UpdateAndShow(vanilla, 1)
assert(vanilla.height == firstHeight, "Vanilla tooltip grew on repeated hover")
local displayed = {}
for _, line in ipairs(vanilla.NightslayerRatingLines) do
    if line.shown then displayed[#displayed+1] = line.text end
end
contains(table.concat(displayed, "\n"), "S2 final |cff0070dd2026|r")
print("Addon tests passed: all S2 boundaries, season/region isolation, LFG, units, whispers, legacy data, per-bracket records, repeated Vanilla hovers.")
