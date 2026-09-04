local ADDON_NAME = ...

local DEFAULT_REALM = "Nightslayer"
local SUPPORTED_REALMS = {
    nightslayer = "Nightslayer",
    dreamscythe = "Dreamscythe",
}
local MAX_REQUESTS = 1500
local PRIORITY_OFFSET = 2000000000
local REQUEST_RETENTION_SECONDS = 30 * 24 * 60 * 60
local BRACKETS = { 2, 3, 5 }
local HASH_MODULI = { 65521, 65519, 65497, 65479 }
local HASH_BASES = { 131, 137, 139, 149 }
local SHARED_CURRENT_INDEX = { [2] = 1, [3] = 2, [5] = 3 }
local SHARED_BEST_INDEX = { [2] = 4, [3] = 5, [5] = 6 }

-- These are neutral visual bands, not official arena titles. Official titles
-- depend on ladder rank at the end of a season and cannot be inferred from a
-- historical rating number alone.
local RATING_BANDS = {
    { minimum = 2400, label = "Elite", hex = "ff8000" },
    { minimum = 2100, label = "Excellent", hex = "a335ee" },
    { minimum = 1800, label = "Strong", hex = "0070dd" },
    { minimum = 1500, label = "Competitive", hex = "1eff00" },
    { minimum = 1, label = "Rated", hex = "ffffff" },
}
local INACTIVE_BAND = { label = "Inactive", hex = "aaaaaa" }

local data = NightslayerRatingData or {
    meta = { realm = DEFAULT_REALM, region = "US", season = 0, generated = 0 },
    sharedPlayers = {},
    players = {},
}

NightslayerRatingRequests = NightslayerRatingRequests or {}
NightslayerRatingSettings = NightslayerRatingSettings or { enabled = true }

local playerIndex = {}
local lowerIndex = {}
local modernTooltipHookInstalled = false
local modernEntryHookInstalled = false
local vanillaTooltipHookInstalled = false
local whisperNotified = {}

local function AsciiLower(value)
    if type(value) ~= "string" then
        return ""
    end

    local output = {}
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte >= 65 and byte <= 90 then
            byte = byte + 32
        end
        output[index] = string.char(byte)
    end
    return table.concat(output)
end

local function NormalizeRealm(realm)
    return AsciiLower(realm):gsub("[%s%-']", "")
end

local function ResolveRealm(realm)
    return SUPPORTED_REALMS[NormalizeRealm(realm or DEFAULT_REALM)]
end

local function PlayerKey(name, realm)
    local canonicalRealm = ResolveRealm(realm)
    if type(name) ~= "string" or name == "" or not canonicalRealm then
        return nil
    end

    return NormalizeRealm(canonicalRealm) .. "|" .. AsciiLower(name)
end

local function SharedLookupKey(name, realm)
    local canonicalRealm = ResolveRealm(realm)
    if type(name) ~= "string" or name == "" or not canonicalRealm then
        return nil
    end

    local input = NormalizeRealm(canonicalRealm) .. "|" .. AsciiLower(name)
    local values = { 0, 0, 0, 0 }
    for index = 1, #input do
        local byte = string.byte(input, index)
        for hashIndex = 1, 4 do
            values[hashIndex] = ((values[hashIndex] * HASH_BASES[hashIndex]) + byte) % HASH_MODULI[hashIndex]
        end
    end
    return string.format("%04x%04x%04x%04x", values[1], values[2], values[3], values[4])
end

local function RebuildIndex()
    wipe(playerIndex)
    wipe(lowerIndex)

    for key, record in pairs(data.players or {}) do
        if type(record) == "table" then
            local keyRealm, keyName = tostring(key):match("^([^|]+)|(.+)$")
            local canonical = record.name or keyName or key
            local realm = ResolveRealm(record.realm or keyRealm or (data.meta and data.meta.realm) or DEFAULT_REALM)
            if realm then
                record.realm = realm
                local exactKey = NormalizeRealm(realm) .. "|" .. canonical
                playerIndex[exactKey] = record
                lowerIndex[AsciiLower(exactKey)] = record
            end
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

local function RequestCount()
    local count = 0
    for _ in pairs(NightslayerRatingRequests) do
        count = count + 1
    end
    return count
end

local function RequestTimestamp(value)
    local stamp = tonumber(value) or 0
    local now = time()
    if stamp > now + (PRIORITY_OFFSET / 2) then
        stamp = stamp - PRIORITY_OFFSET
    end
    return stamp
end

local function CleanupRequests()
    local cutoff = time() - REQUEST_RETENTION_SECONDS
    for key, value in pairs(NightslayerRatingRequests) do
        local stamp = RequestTimestamp(value)
        if type(key) ~= "string" or stamp <= 0 or stamp < cutoff then
            NightslayerRatingRequests[key] = nil
        end
    end
end

local function RemoveOldestRequest()
    local oldestKey
    local oldestValue

    for key, value in pairs(NightslayerRatingRequests) do
        value = RequestTimestamp(value)
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
    local canonicalRealm = ResolveRealm(realm)
    if not name or not canonicalRealm then
        return false
    end

    local key = canonicalRealm .. "|" .. name
    if not NightslayerRatingRequests[key] and RequestCount() >= MAX_REQUESTS then
        RemoveOldestRequest()
    end

    local stamp = time()
    if highPriority then
        stamp = stamp + PRIORITY_OFFSET
    end
    NightslayerRatingRequests[key] = stamp
    return true
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

local function PlayerNameFromUnitTooltip(tooltip)
    if not tooltip or not tooltip.GetUnit then
        return nil, nil
    end

    local _, unitToken = tooltip:GetUnit()
    if not unitToken or type(UnitIsPlayer) ~= "function" or not UnitIsPlayer(unitToken) then
        return nil, nil
    end

    local name
    local realm
    if type(UnitFullName) == "function" then
        name, realm = UnitFullName(unitToken)
    elseif type(UnitName) == "function" then
        name = UnitName(unitToken)
    end

    name = UsableLeaderName(name)
    if not name then
        return nil, nil
    end

    if not realm or realm == "" then
        realm = DEFAULT_REALM
    end

    return name .. "-" .. realm, unitToken
end

local function LookupRecord(name, realm)
    local key = PlayerKey(name, realm)
    if not key then
        return nil
    end

    local localRecord = playerIndex[key] or lowerIndex[key]
    if localRecord and localRecord.exact == true then
        return localRecord
    end

    local sharedKey = SharedLookupKey(name, realm)
    local sharedRecord = sharedKey and data.sharedPlayers and data.sharedPlayers[sharedKey]
    return sharedRecord or localRecord
end

local function CurrentRating(record, bracket)
    if type(record) ~= "table" then
        return nil
    end
    if type(record.current) == "table" then
        return record.current[bracket] or record.current[tostring(bracket)]
    end
    local index = SHARED_CURRENT_INDEX[bracket]
    return index and record[index] or nil
end

local function BestRating(record, bracket)
    if type(record) ~= "table" then
        return nil
    end
    if type(record.best) == "table" then
        return record.best[bracket] or record.best[tostring(bracket)]
    end
    local index = SHARED_BEST_INDEX[bracket]
    return index and record[index] or nil
end

local function ExactRating(record)
    return type(record) == "table" and record.exact == true
end

local function AutomaticExactLookupAvailable()
    return data.meta and data.meta.profileLookup == true
end

local function RatingText(value)
    value = tonumber(value)
    if not value or value <= 0 then
        return "--"
    end
    return tostring(math.floor(value + 0.5))
end

local function GetRatingBand(value)
    local rating = tonumber(value) or 0
    if rating <= 0 then
        return INACTIVE_BAND
    end

    for _, band in ipairs(RATING_BANDS) do
        if rating >= band.minimum then
            return band
        end
    end

    return INACTIVE_BAND
end

local function ColorText(band, text)
    return "|cff" .. band.hex .. tostring(text) .. "|r"
end

local function ColoredRating(value)
    return ColorText(GetRatingBand(value), RatingText(value))
end

local function RatingBandLabel(current)
    local band = GetRatingBand(current)
    return ColorText(band, band.label)
end

local function ShowWhisperRating(fullName)
    if not NightslayerRatingSettings.enabled then
        return
    end

    local name, realm = SplitPlayerName(fullName)
    name = UsableLeaderName(name)
    local canonicalRealm = ResolveRealm(realm)
    if not name or not canonicalRealm then
        return
    end

    local notificationKey = PlayerKey(name, canonicalRealm)
    if whisperNotified[notificationKey] then
        return
    end
    whisperNotified[notificationKey] = true

    QueuePlayer(name .. "-" .. canonicalRealm, true)

    local displayName = name
    if canonicalRealm ~= DEFAULT_REALM then
        displayName = displayName .. "-" .. canonicalRealm
    end
    local prefix = "|cffffd200[NSR]|r " .. displayName .. ": "
    local record = LookupRecord(name, canonicalRealm)
    if not record then
        if AutomaticExactLookupAvailable() then
            DEFAULT_CHAT_FRAME:AddMessage(prefix .. "rating not cached yet; exact lookup queued")
        else
            DEFAULT_CHAT_FRAME:AddMessage(prefix .. "not in the packaged leaderboard cache")
        end
        return
    end

    local parts = {}
    local exact = ExactRating(record)
    for _, bracket in ipairs(BRACKETS) do
        local current = CurrentRating(record, bracket)
        local best = BestRating(record, bracket)
        if (tonumber(current) or 0) > 0 or (tonumber(best) or 0) > 0 then
            parts[#parts + 1] = string.format(
                "%dv%d %s: %s current / %s %s%s",
                bracket,
                bracket,
                RatingBandLabel(current),
                ColoredRating(current),
                ColoredRating(best),
                exact and "record high" or "observed",
                exact and "" or "*"
            )
        end
    end

    if #parts == 0 then
        DEFAULT_CHAT_FRAME:AddMessage(prefix .. "no tracked arena rating")
    else
        DEFAULT_CHAT_FRAME:AddMessage(prefix .. table.concat(parts, " | "))
    end
end

local function AddRatingLines(tooltip, fullName, resultID)
    if not NightslayerRatingSettings.enabled or not tooltip or not tooltip:IsShown() then
        return
    end

    local name, realm = SplitPlayerName(fullName)
    local canonicalRealm = ResolveRealm(realm)
    if not name or not canonicalRealm then
        return
    end

    local token = tostring(resultID or "tooltip") .. ":" .. canonicalRealm .. ":" .. name
    if tooltip.NightslayerRatingToken == token then
        return
    end
    tooltip.NightslayerRatingToken = token

    QueuePlayer(name .. "-" .. canonicalRealm, true)

    local record = LookupRecord(name, canonicalRealm)
    tooltip:AddLine(" ")
    tooltip:AddLine("IronForge Rating |cff9d9d9d- " .. canonicalRealm .. "|r", 1.00, 0.82, 0.00)

    if not record then
        tooltip:AddLine("Current rating not cached yet", 0.75, 0.75, 0.75)
        if AutomaticExactLookupAvailable() then
            tooltip:AddLine("Exact lookup queued automatically", 0.35, 0.75, 1.00)
        else
            tooltip:AddLine("Not in the packaged leaderboard cache", 0.55, 0.55, 0.55)
        end
        tooltip:Show()
        return
    end

    local exact = ExactRating(record)
    local foundRating = false

    for _, bracket in ipairs(BRACKETS) do
        local current = CurrentRating(record, bracket)
        local best = BestRating(record, bracket)

        if (tonumber(current) or 0) > 0 or (tonumber(best) or 0) > 0 then
            foundRating = true
            local bestLabel = exact and "Record " or "Observed "
            local suffix = exact and "" or "*"
            local left = string.format(
                "%dv%d  %s",
                bracket,
                bracket,
                RatingBandLabel(current)
            )
            local right = string.format(
                "Current %s   %s%s%s",
                ColoredRating(current),
                bestLabel,
                ColoredRating(best),
                suffix
            )
            tooltip:AddDoubleLine(left, right, 0.35, 0.75, 1.00, 0.80, 0.80, 0.80)
        end
    end

    if not foundRating then
        tooltip:AddLine("No tracked arena rating", 0.75, 0.75, 0.75)
    elseif not exact then
        if AutomaticExactLookupAvailable() then
            tooltip:AddLine("* Exact lifetime high is queued", 0.55, 0.55, 0.55)
        else
            tooltip:AddLine("* Observed leaderboard value; not a lifetime peak", 0.55, 0.55, 0.55)
        end
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

local function HideVanillaRatingLines(tooltip)
    if not tooltip or not tooltip.NightslayerRatingLines then
        return
    end

    for _, line in ipairs(tooltip.NightslayerRatingLines) do
        line:Hide()
        line:ClearAllPoints()
    end

    if tooltip.NightslayerRatingFinalHeight and
        math.abs(tooltip:GetHeight() - tooltip.NightslayerRatingFinalHeight) < 1 then
        tooltip:SetHeight(tooltip.NightslayerRatingBaseHeight)
    end
    if tooltip.NightslayerRatingFinalWidth and
        math.abs(tooltip:GetWidth() - tooltip.NightslayerRatingFinalWidth) < 1 then
        tooltip:SetWidth(tooltip.NightslayerRatingBaseWidth)
    end
    tooltip.NightslayerRatingBaseHeight = nil
    tooltip.NightslayerRatingBaseWidth = nil
    tooltip.NightslayerRatingFinalHeight = nil
    tooltip.NightslayerRatingFinalWidth = nil
end

local function GetVanillaRatingLine(tooltip, index)
    tooltip.NightslayerRatingLines = tooltip.NightslayerRatingLines or {}
    local line = tooltip.NightslayerRatingLines[index]

    if not line then
        line = tooltip:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        line:SetJustifyH("LEFT")
        line:SetWordWrap(false)
        tooltip.NightslayerRatingLines[index] = line
    end

    return line
end

local function AddVanillaRatingBlock(tooltip, fullName, resultID)
    if not tooltip then
        return
    end

    HideVanillaRatingLines(tooltip)
    if not NightslayerRatingSettings.enabled then
        return
    end

    local name, realm = SplitPlayerName(fullName)
    local canonicalRealm = ResolveRealm(realm)
    if not name or not canonicalRealm then
        return
    end

    QueuePlayer(name .. "-" .. canonicalRealm, true)

    local displayLines = {
        { "IronForge Rating - " .. canonicalRealm, 1.00, 0.82, 0.00 },
    }
    local record = LookupRecord(name, canonicalRealm)

    if not record then
        displayLines[#displayLines + 1] = { "Current rating not cached yet", 0.75, 0.75, 0.75 }
        if AutomaticExactLookupAvailable() then
            displayLines[#displayLines + 1] = { "Exact lookup queued automatically", 0.35, 0.75, 1.00 }
        else
            displayLines[#displayLines + 1] = { "Not in the packaged leaderboard cache", 0.55, 0.55, 0.55 }
        end
    else
        local exact = ExactRating(record)
        local foundRating = false

        for _, bracket in ipairs(BRACKETS) do
            local current = CurrentRating(record, bracket)
            local best = BestRating(record, bracket)

            if (tonumber(current) or 0) > 0 or (tonumber(best) or 0) > 0 then
                foundRating = true
                local bestLabel = exact and "Record" or "Observed"
                local suffix = exact and "" or "*"
                displayLines[#displayLines + 1] = {
                    string.format(
                        "|cff59bfff%dv%d|r  %s   Current %s   %s %s%s",
                        bracket,
                        bracket,
                        RatingBandLabel(current),
                        ColoredRating(current),
                        bestLabel,
                        ColoredRating(best),
                        suffix
                    ),
                    1.00,
                    1.00,
                    1.00,
                }
            end
        end

        if not foundRating then
            displayLines[#displayLines + 1] = { "No tracked arena rating", 0.75, 0.75, 0.75 }
        elseif not exact then
            displayLines[#displayLines + 1] = {
                AutomaticExactLookupAvailable()
                    and "* Exact lifetime high is queued"
                    or "* Observed leaderboard value; not a lifetime peak",
                0.55,
                0.55,
                0.55,
            }
        end
    end

    local baseHeight = tooltip:GetHeight()
    local baseWidth = tooltip:GetWidth()
    local lineHeight = 14
    local firstLineY = -(baseHeight - 11)
    local maxLineWidth = 0

    for index, lineInfo in ipairs(displayLines) do
        local line = GetVanillaRatingLine(tooltip, index)
        line:SetText(lineInfo[1])
        line:SetTextColor(lineInfo[2], lineInfo[3], lineInfo[4])
        line:SetPoint("TOPLEFT", tooltip, "TOPLEFT", 11, firstLineY - ((index - 1) * lineHeight))
        line:Show()
        maxLineWidth = math.max(maxLineWidth, line:GetStringWidth())
    end

    local finalWidth = math.max(baseWidth, maxLineWidth + 22)
    local finalHeight = baseHeight + (#displayLines * lineHeight) + 5
    tooltip.NightslayerRatingBaseHeight = baseHeight
    tooltip.NightslayerRatingBaseWidth = baseWidth
    tooltip.NightslayerRatingFinalHeight = finalHeight
    tooltip.NightslayerRatingFinalWidth = finalWidth
    tooltip:SetWidth(finalWidth)
    tooltip:SetHeight(finalHeight)
    tooltip.NightslayerRatingResultID = resultID
end

local function AddVanillaByResultID(tooltip, resultID)
    HideVanillaRatingLines(tooltip)
    local leaderName = GetLeaderName(resultID)
    if leaderName then
        AddVanillaRatingBlock(tooltip, leaderName, resultID)
    end
end

local function InstallHooks()
    if not modernTooltipHookInstalled and type(LFGListUtil_SetSearchEntryTooltip) == "function" then
        hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", function(tooltip, resultID)
            if not AddByResultID(tooltip, resultID) then
                local name = NameFromTooltip(tooltip)
                if name then
                    AddRatingLines(tooltip, name, resultID)
                end
            end
        end)
        modernTooltipHookInstalled = true
    end

    if not modernEntryHookInstalled and type(LFGListSearchEntry_OnEnter) == "function" then
        hooksecurefunc("LFGListSearchEntry_OnEnter", function(entry)
            local resultID = GetResultIDFromFrame(entry)
            if resultID then
                if not AddByResultID(GameTooltip, resultID) then
                    local name = NameFromTooltip(GameTooltip)
                    if name then
                        AddRatingLines(GameTooltip, name, resultID)
                    end
                end
            end
        end)
        modernEntryHookInstalled = true
    end

    if not vanillaTooltipHookInstalled and type(LFGBrowseSearchEntryTooltip_UpdateAndShow) == "function" then
        hooksecurefunc("LFGBrowseSearchEntryTooltip_UpdateAndShow", function(tooltip, resultID)
            AddVanillaByResultID(tooltip, resultID)
        end)
        vanillaTooltipHookInstalled = true
    end
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

CleanupRequests()
RebuildIndex()

GameTooltip:HookScript("OnTooltipCleared", function(tooltip)
    tooltip.NightslayerRatingToken = nil
end)

GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
    C_Timer.After(0, function()
        if not tooltip:IsShown() then
            return
        end

        local fullName, unitToken = PlayerNameFromUnitTooltip(tooltip)
        if fullName then
            AddRatingLines(tooltip, fullName, "unit:" .. unitToken)
        end
    end)
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
            AddRatingLines(tooltip, name)
        end
    end)
end)

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
eventFrame:RegisterEvent("LFG_LIST_SEARCH_RESULT_UPDATED")
eventFrame:RegisterEvent("CHAT_MSG_WHISPER")
eventFrame:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME or arg1 == "Blizzard_GroupFinder" or arg1 == "Blizzard_GroupFinder_VanillaStyle" then
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
    elseif event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_WHISPER_INFORM" then
        ShowWhisperRating(arg2)
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
        if QueuePlayer(rest, true) then
            if AutomaticExactLookupAvailable() then
                print("|cffffd200Nightslayer Rating:|r queued " .. rest .. " for automatic exact lookup")
            else
                print("|cffffd200Nightslayer Rating:|r saved " .. rest .. "; the Windows companion is required for exact lookup")
            end
        else
            print("|cffffd200Nightslayer Rating:|r use NAME or NAME-Nightslayer/Dreamscythe")
        end
    else
        local exact = 0
        local realmCounts = { Nightslayer = 0, Dreamscythe = 0 }
        local packagedCounts = data.meta and data.meta.counts
        local hasPackagedCounts = type(packagedCounts) == "table" and
            ((tonumber(packagedCounts.Nightslayer) or 0) +
            (tonumber(packagedCounts.Dreamscythe) or 0)) > 0
        if hasPackagedCounts then
            realmCounts.Nightslayer = tonumber(packagedCounts.Nightslayer) or 0
            realmCounts.Dreamscythe = tonumber(packagedCounts.Dreamscythe) or 0
        end

        for _, record in pairs(data.players or {}) do
            local recordRealm = ResolveRealm(record.realm or (data.meta and data.meta.realm) or DEFAULT_REALM)
            if recordRealm and not hasPackagedCounts then
                realmCounts[recordRealm] = (realmCounts[recordRealm] or 0) + 1
            end
            if record.exact then
                exact = exact + 1
            end
        end
        local players = realmCounts.Nightslayer + realmCounts.Dreamscythe

        print(string.format(
            "|cffffd200Nightslayer Rating:|r %d cached players (%d Nightslayer, %d Dreamscythe), %d exact lifetime highs, season %s, exact lookup %s",
            players,
            realmCounts.Nightslayer,
            realmCounts.Dreamscythe,
            exact,
            tostring((data.meta and data.meta.season) or "?"),
            AutomaticExactLookupAvailable() and "automatic" or "requires Windows companion"
        ))
        print("Commands: /nsr on, /nsr off, /nsr lookup NAME[-REALM]")
    end
end
