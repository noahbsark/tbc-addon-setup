local ADDON_NAME = ...

local DEFAULT_REALM = "Nightslayer"
local MAX_REQUESTS = 1500
local PRIORITY_OFFSET = 2000000000
local BRACKETS = { 2, 3, 5 }

local data = NightslayerRatingData or {
    meta = { realm = DEFAULT_REALM, region = "US", season = 0, generated = 0 },
    players = {},
}

NightslayerRatingRequests = NightslayerRatingRequests or {}
NightslayerRatingSettings = NightslayerRatingSettings or { enabled = true }

local playerIndex = {}
local lowerIndex = {}
local hooksInstalled = false

local function NormalizeRealm(realm)
    if type(realm) ~= "string" then
        return ""
    end

    return string.lower((realm:gsub("[%s%-']", "")))
end

local function RebuildIndex()
    wipe(playerIndex)
    wipe(lowerIndex)

    for key, record in pairs(data.players or {}) do
        if type(record) == "table" then
            local canonical = record.name or key
            playerIndex[canonical] = record
            lowerIndex[string.lower(canonical)] = record
        end
    end
end

local function SplitPlayerName(fullName)
    if type(fullName) ~= "string" or fullName == "" then
        return nil, nil
    end

    local name, realm = fullName:match("^([^%-]+)%-(.+)$")
    if not name then
        name = fullName
        realm = DEFAULT_REALM
    end

    return name, realm
end

local function IsSupportedRealm(realm)
    return NormalizeRealm(realm) == NormalizeRealm(DEFAULT_REALM)
end

local function RequestCount()
    local count = 0
    for _ in pairs(NightslayerRatingRequests) do
        count = count + 1
    end
    return count
end

local function RemoveOldestRequest()
    local oldestKey
    local oldestValue

    for key, value in pairs(NightslayerRatingRequests) do
        value = tonumber(value) or 0
        if not oldestValue or value < oldestValue then
            oldestKey = key
            oldestValue = value
        end
    end

    if oldestKey then
        NightslayerRatingRequests[oldestKey] = nil
    end
end

local function QueuePlayer(fullName, highPriority)
    local name, realm = SplitPlayerName(fullName)
    if not name or not IsSupportedRealm(realm) then
        return
    end

    local key = DEFAULT_REALM .. "|" .. name
    if not NightslayerRatingRequests[key] and RequestCount() >= MAX_REQUESTS then
        RemoveOldestRequest()
    end

    local stamp = time()
    if highPriority then
        stamp = stamp + PRIORITY_OFFSET
    end
    NightslayerRatingRequests[key] = stamp
end

local function UsableLeaderName(value)
    if type(value) ~= "string" then
        return nil
    end

    local ok, encoded = pcall(string.find, value, "|K", 1, true)
    if not ok or encoded then
        return nil
    end

    return value
end

local function GetLeaderName(resultID)
    if not resultID or not C_LFGList then
        return nil
    end

    if C_LFGList.GetSearchResultInfo then
        local ok, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
        if ok and type(info) == "table" then
            local name = UsableLeaderName(info.leaderName)
            if name then
                return name
            end
        end
    end

    if C_LFGList.GetSearchResultLeaderInfo then
        local ok, info = pcall(C_LFGList.GetSearchResultLeaderInfo, resultID)
        if ok and type(info) == "table" then
            local name = UsableLeaderName(info.leaderName) or UsableLeaderName(info.name)
            if name then
                return name
            end
        end
    end

    return nil
end

local function GetResultIDFromFrame(frame)
    local current = frame

    for _ = 1, 6 do
        if not current then
            break
        end

        if current.resultID then
            return current.resultID
        end
        if current.searchResultID then
            return current.searchResultID
        end

        if current.GetElementData then
            local ok, elementData = pcall(current.GetElementData, current)
            if ok then
                if type(elementData) == "number" then
                    return elementData
                elseif type(elementData) == "table" then
                    if elementData.resultID then
                        return elementData.resultID
                    elseif elementData.searchResultID then
                        return elementData.searchResultID
                    end
                end
            end
        end

        current = current.GetParent and current:GetParent() or nil
    end

    return nil
end

local function FrameLooksLikeGroupFinder(frame)
    local current = frame

    for _ = 1, 8 do
        if not current then
            break
        end

        local frameName = current.GetName and current:GetName()
        if type(frameName) == "string" and
            (frameName:find("LFGList") or frameName:find("GroupFinder")) then
            return true
        end

        current = current.GetParent and current:GetParent() or nil
    end

    return false
end

local function NameFromTooltip(tooltip)
    if not tooltip or not FrameLooksLikeGroupFinder(tooltip:GetOwner()) then
        return nil
    end

    local firstLine = _G[tooltip:GetName() .. "TextLeft1"]
    local text = firstLine and firstLine:GetText()
    if type(text) ~= "string" then
        return nil
    end

    local ok, name = pcall(function()
        local cleaned = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        return cleaned:match("^([^%s]+)%s+[Ll][Vv][Ll]?%s*%d+")
    end)
    return ok and name or nil
end

local function LookupRecord(name)
    if not name then
        return nil
    end

    return playerIndex[name] or lowerIndex[string.lower(name)]
end

local function RatingText(value)
    value = tonumber(value)
    if not value or value <= 0 then
        return "--"
    end
    return tostring(math.floor(value + 0.5))
end

local function AddRatingLines(tooltip, fullName, resultID)
    if not NightslayerRatingSettings.enabled or not tooltip or not tooltip:IsShown() then
        return
    end

    local name, realm = SplitPlayerName(fullName)
    if not name or not IsSupportedRealm(realm) then
        return
    end

    local token = tostring(resultID or "tooltip") .. ":" .. name
    if tooltip.NightslayerRatingToken == token then
        return
    end
    tooltip.NightslayerRatingToken = token

    QueuePlayer(name .. "-" .. DEFAULT_REALM, true)

    local record = LookupRecord(name)
    tooltip:AddLine(" ")
    tooltip:AddLine("IronForge Rating |cff9d9d9d- Nightslayer|r", 1.00, 0.82, 0.00)

    if not record then
        tooltip:AddLine("Current rating not cached yet", 0.75, 0.75, 0.75)
        tooltip:AddLine("Lookup queued automatically", 0.35, 0.75, 1.00)
        tooltip:Show()
        return
    end

    local exact = record.exact == true
    local foundRating = false

    for _, bracket in ipairs(BRACKETS) do
        local current = record.current and record.current[bracket]
        local best = record.best and record.best[bracket]

        if (tonumber(current) or 0) > 0 or (tonumber(best) or 0) > 0 then
            foundRating = true
            local bestLabel = exact and "High " or "Best cached "
            local suffix = exact and "" or "*"
            local right = string.format(
                "Current |cffffffff%s|r   %s|cff00ff98%s%s|r",
                RatingText(current),
                bestLabel,
                RatingText(best),
                suffix
            )
            tooltip:AddDoubleLine(bracket .. "v" .. bracket, right, 0.35, 0.75, 1.00, 0.80, 0.80, 0.80)
        end
    end

    if not foundRating then
        tooltip:AddLine("No tracked arena rating", 0.75, 0.75, 0.75)
    elseif not exact then
        tooltip:AddLine("* Exact lifetime high is queued", 0.55, 0.55, 0.55)
    end

    local generated = data.meta and tonumber(data.meta.generated)
    if generated and generated > 0 then
        tooltip:AddLine("Synced " .. date("%Y-%m-%d %H:%M", generated), 0.45, 0.45, 0.45)
    end

    tooltip:Show()
end

local function AddByResultID(tooltip, resultID)
    local leaderName = GetLeaderName(resultID)
    if leaderName then
        AddRatingLines(tooltip, leaderName, resultID)
        return true
    end
    return false
end

local function InstallHooks()
    if hooksInstalled then
        return
    end

    local installed = false

    if type(LFGListUtil_SetSearchEntryTooltip) == "function" then
        hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", function(tooltip, resultID)
            if not AddByResultID(tooltip, resultID) then
                local name = NameFromTooltip(tooltip)
                if name then
                    AddRatingLines(tooltip, name .. "-" .. DEFAULT_REALM, resultID)
                end
            end
        end)
        installed = true
    end

    if type(LFGListSearchEntry_OnEnter) == "function" then
        hooksecurefunc("LFGListSearchEntry_OnEnter", function(entry)
            local resultID = GetResultIDFromFrame(entry)
            if resultID then
                if not AddByResultID(GameTooltip, resultID) then
                    local name = NameFromTooltip(GameTooltip)
                    if name then
                        AddRatingLines(GameTooltip, name .. "-" .. DEFAULT_REALM, resultID)
                    end
                end
            end
        end)
        installed = true
    end

    hooksInstalled = installed
end

local function TrackSearchResults()
    if not C_LFGList or not C_LFGList.GetSearchResults then
        return
    end

    local ok, results = pcall(C_LFGList.GetSearchResults)
    if not ok or type(results) ~= "table" then
        return
    end

    for _, resultID in ipairs(results) do
        local leaderName = GetLeaderName(resultID)
        if leaderName then
            QueuePlayer(leaderName, false)
        end
    end
end

RebuildIndex()

GameTooltip:HookScript("OnTooltipCleared", function(tooltip)
    tooltip.NightslayerRatingToken = nil
end)

GameTooltip:HookScript("OnShow", function(tooltip)
    C_Timer.After(0, function()
        if not tooltip:IsShown() or tooltip.NightslayerRatingToken then
            return
        end

        local resultID = GetResultIDFromFrame(tooltip:GetOwner())
        if resultID and AddByResultID(tooltip, resultID) then
            return
        end

        local name = NameFromTooltip(tooltip)
        if name then
            AddRatingLines(tooltip, name .. "-" .. DEFAULT_REALM)
        end
    end)
end)

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
eventFrame:RegisterEvent("LFG_LIST_SEARCH_RESULT_UPDATED")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME or arg1 == "Blizzard_GroupFinder" then
            InstallHooks()
        end
    elseif event == "PLAYER_LOGIN" then
        InstallHooks()
    elseif event == "LFG_LIST_SEARCH_RESULTS_RECEIVED" then
        C_Timer.After(0.2, TrackSearchResults)
    elseif event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
        local leaderName = GetLeaderName(arg1)
        if leaderName then
            QueuePlayer(leaderName, false)
        end
    end
end)

SLASH_NIGHTSLAYERRATING1 = "/nsr"
SlashCmdList.NIGHTSLAYERRATING = function(message)
    message = (message or ""):match("^%s*(.-)%s*$")
    local command, rest = message:match("^(%S+)%s*(.-)$")
    command = command and string.lower(command) or "status"

    if command == "on" then
        NightslayerRatingSettings.enabled = true
        print("|cffffd200Nightslayer Rating:|r enabled")
    elseif command == "off" then
        NightslayerRatingSettings.enabled = false
        print("|cffffd200Nightslayer Rating:|r disabled")
    elseif command == "lookup" and rest ~= "" then
        QueuePlayer(rest .. "-" .. DEFAULT_REALM, true)
        print("|cffffd200Nightslayer Rating:|r queued " .. rest .. " for automatic lookup")
    else
        local players = 0
        local exact = 0
        for _, record in pairs(data.players or {}) do
            players = players + 1
            if record.exact then
                exact = exact + 1
            end
        end

        print(string.format(
            "|cffffd200Nightslayer Rating:|r %d cached players, %d exact lifetime highs, season %s",
            players,
            exact,
            tostring((data.meta and data.meta.season) or "?")
        ))
        print("Commands: /nsr on, /nsr off, /nsr lookup NAME")
    end
end
