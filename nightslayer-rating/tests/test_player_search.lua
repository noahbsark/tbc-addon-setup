local addon = "nightslayer-rating/source/Addon/NightslayerRating/"
time = function() return 1789100000 end
date = os.date
wipe = function(t) for key in pairs(t) do t[key] = nil end return t end
GetRealmName = function() return "Dreamscythe" end
SlashCmdList, UISpecialFrames = {}, {}
GameTooltip = { HookScript = function() end }
local frames = {}
local function widget(name)
    local w = { scripts = {} }
    if name then frames[name] = w end
    for _, method in ipairs({"SetSize", "SetPoint", "SetMovable", "EnableMouse", "RegisterForDrag",
        "SetMaxLetters", "SetAutoFocus", "SetWidth", "SetHeight", "SetJustifyH", "SetSpacing",
        "SetScrollChild", "SetVerticalScroll", "RegisterEvent", "StartMoving", "StopMovingOrSizing"}) do
        w[method] = function() end
    end
    w.SetText = function(self, text) self.text = text end
    w.GetText = function(self) return self.text or "" end
    w.SetScript = function(self, event, callback) self.scripts[event] = callback end
    w.CreateFontString = function(self) local child = widget(); self.lastFont = child; return child end
    w.GetStringHeight = function() return 350 end
    w.Show = function(self) self.shown = true end
    w.SetFocus = function(self) self.focus = true end
    w.ClearFocus = function(self) self.focus = false end
    return w
end
CreateFrame = function(_, name, _, template)
    local w = widget(name)
    if template == "BasicFrameTemplateWithInset" then w.TitleText = widget() end
    return w
end
local player = { name = "Example", realm = "Nightslayer", exact = true, tracking = true,
    current = { [2] = 2084 }, currentUpdated = { [2] = time() - 3600 }, currentLastKnown = { [2] = 1 },
    best = { [2] = 2900 }, exactFetchedAt = time() - 86400,
    history = { [2] = { { at = time() - 6 * 86400 - 3600, rating = 2000 }, { at = time() - 3600, rating = 2084 } } } }
NightslayerRatingData = { meta = { season = 3, region = "US", profileLookup = true },
    players = { ["Nightslayer|Example"] = player }, sharedPlayers = {},
    cutoffs = { [2] = { [2] = { updated = time(), thresholds = {2803,2481,1944,1629,1458} } },
        [3] = { [2] = { updated = time(), thresholds = {2200,2100,1900,1700,1500} } } } }
for _, file in ipairs({"RatingColors", "Options", "TitleTracker", "Status", "PlayerDetails", "Search", "Core"}) do
    assert(loadfile(addon .. file .. ".lua"))("NightslayerRating")
end
local UI = NightslayerRatingUI
local result = table.concat(UI.FindPlayer("Example-Nightslayer"), "\n")
assert(result:find("Last known S3 |cff0070dd2084|r (1h ago)", 1, true))
assert(result:find("Peak |cffff80002900|r", 1, true))
assert(result:find("+84 over 6.0 days (snapshots)", 1, true))
assert(NightslayerRatingRequests["Nightslayer|Example"])
result = table.concat(UI.FindPlayer("Example"), "\n")
assert(result:find("Example-Dreamscythe", 1, true))
assert(result:find("No cached rating", 1, true))
assert(not result:find("2900", 1, true))
local count = 0
for _ in pairs(NightslayerRatingRequests) do count = count + 1 end
assert(UI.FindPlayer("|cffff0000Example")[1]:find("Enter a character name", 1, true))
assert(UI.FindPlayer("Example-Unsupported")[1]:find("Enter a character name", 1, true))
local after = 0
for _ in pairs(NightslayerRatingRequests) do after = after + 1 end
assert(after == count)
player.currentLastKnown = {}
assert(not UI.CurrentInfo(NightslayerRatingData, player, 2))
player.currentUpdated[2] = time() - 3 * 86400
assert(UI.CurrentInfo(NightslayerRatingData, player, 2))
player.currentUpdated = {}
local last, age = UI.CurrentInfo(NightslayerRatingData, player, 2)
assert(last and age == "unknown")
player.history[2][2].at = time() - 3 * 86400
assert(UI.HistoryLine(player, 2):find("stale", 1, true))
player.history = {}
assert(UI.HistoryLine(player, 2):find("collecting", 1, true))
player.notFoundUntil = time() + 86400
assert(UI.ProfileStatus(player, true):find("unavailable", 1, true))
player.notFoundUntil = nil
player.profileAttemptAt = time()
assert(UI.ProfileStatus(player, true):find("will retry", 1, true))
assert(UI.ProfileStatus(nil, false):find("Windows companion", 1, true))
-- Shared exact peaks use frozen S2 colors, with observed highs kept honest.
NightslayerRatingData.sharedPlayers["ec31af45054a44db"] = {
    2100, 2300, 0, 2200, 2400, 0, 2000, 1900, 0,
    exactBest = { [2] = 2900, [3] = 2200 }, exactFetchedAt = time() - 600 }
local shared = table.concat(UI.FindPlayer("Reefey-Nightslayer"), "\n")
assert(shared:find("Current-season ratings cached: 2v2, 3v3", 1, true))
assert(shared:find("Peak profile cached from shared cache", 1, true))
assert(shared:find("Peak |cffff80002900|r", 1, true))
assert(shared:find("Observed", 1, true))
NightslayerRatingData.meta.profileLookup = false
assert(not UI.ProfileStatus(NightslayerRatingData.sharedPlayers["ec31af45054a44db"], false):find("require", 1, true))
NightslayerRatingData.meta.profileLookup = true
SlashCmdList.NIGHTSLAYERRATING("search Example-Nightslayer")
assert(frames.NightslayerRatingSearch.shown)
assert(frames.NightslayerRatingSearch.input:GetText() == "Example-Nightslayer")
assert(not frames.NightslayerRatingSearch.input.focus)
SlashCmdList.NIGHTSLAYERRATING("lookup")
assert(frames.NightslayerRatingSearch.input.focus)
frames.NightslayerRatingSearch.input:SetText("Another-Dreamscythe")
frames.NightslayerRatingSearch.input.scripts.OnEnterPressed()
assert(NightslayerRatingRequests["Dreamscythe|Another"])
print("Search window, realm identity, queueing, last-known labels and observed history tests passed")
