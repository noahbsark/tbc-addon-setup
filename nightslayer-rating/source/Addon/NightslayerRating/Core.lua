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
local PEAK_COMPARISON_SEASON = 2
local Colors = NightslayerRatingColors
local UI = NightslayerRatingUI
local Titles = NightslayerRatingTitles

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
    if localRecord and (localRecord.exact == true or localRecord.tracking == true) then
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

local function ExactRating(record, bracket)
    if type(record) ~= "table" or record.exact ~= true then return false end
    if bracket and type(record.exactBrackets) == "table" then
        return record.exactBrackets[bracket] == true or record.exactBrackets[tostring(bracket)] == true
    end
    return true
end

local function AllVisiblePeaksExact(record)
    for _, bracket in ipairs(BRACKETS) do
        if UI.Bracket(bracket) and (tonumber(BestRating(record, bracket)) or 0) > 0 and
            not ExactRating(record, bracket) then return false end
    end
    return ExactRating(record)
end

local function CurrentSeason()
    return tonumber(data.meta and data.meta.season) or 0
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

local function ColoredRating(value, bracket, season)
    return Colors.Text(Colors.Band(data, value, bracket, season), RatingText(value))
end

local function RatingBandLabel(current, bracket)
    if (tonumber(current) or 0) <= 0 then return "|cffaaaaaaNo current data|r" end
    local band = Colors.Band(data, current, bracket, CurrentSeason())
    return Colors.Text(band, band.label)
end

local function HasBracketRating(record, bracket)
    return UI.Bracket(bracket) and ((tonumber(CurrentRating(record, bracket)) or 0) > 0 or
        (tonumber(BestRating(record, bracket)) or 0) > 0)
end

local function BracketSummary(record, bracket)
    local lastKnown, age = UI.CurrentInfo(data, record, bracket)
    local current = CurrentRating(record, bracket)
    local parts = {
        (lastKnown and (tonumber(current) or 0) > 0 and "Last known S" or "Current S") .. CurrentSeason() .. " " ..
            ColoredRating(current, bracket, CurrentSeason()) ..
            (lastKnown and (tonumber(current) or 0) > 0 and (" (" .. age .. ")") or ""),
    }
    parts[#parts + 1] = (ExactRating(record, bracket) and "Peak " or "Observed ") ..
        ColoredRating(BestRating(record, bracket), bracket, PEAK_COMPARISON_SEASON) ..
        (ExactRating(record, bracket) and "" or "*")
    return table.concat(parts, "   ")
end

function UI.FindPlayer(query)
    query = type(query) == "string" and query:match("^%s*(.-)%s*$") or ""
    local name, realm = SplitPlayerName(query)
    if not query:find("-", 1, true) and type(GetRealmName) == "function" then
        realm = ResolveRealm(GetRealmName()) or DEFAULT_REALM
    end
    realm = ResolveRealm(realm)
    if not name or name == "" or #name > 48 or name:find("[%s%p%d%c]") or not realm then
        return { "Enter a character name, optionally followed by -Nightslayer or -Dreamscythe." }
    end
    QueuePlayer(name .. "-" .. realm, true)
    local record = LookupRecord(name, realm)
    local lines = { "|cffffd200" .. name .. "-" .. realm .. "|r", UI.ProfileStatus(record, AutomaticExactLookupAvailable()) }
    local title = Titles.Line(name, realm, true)
    if title then
        lines[#lines + 1] = title
        lines[#lines + 1] = "Highest confirmed observation on this client; other titles may be unknown."
    end
    if not record then
        lines[#lines + 1] = "No cached rating. Missing data does not mean a zero rating."
    else
        for _, bracket in ipairs(BRACKETS) do
            if UI.Bracket(bracket) then
                local _, age = UI.CurrentInfo(data, record, bracket)
                lines[#lines + 1] = " "
                lines[#lines + 1] = bracket .. "v" .. bracket .. "   " .. BracketSummary(record, bracket)
                lines[#lines + 1] = "Rating source: " .. age
                lines[#lines + 1] = UI.HistoryLine(record, bracket)
                local cutoff = UI.Settings().nextCutoff and Colors.NextCutoff(data, CurrentRating(record, bracket), bracket)
                if cutoff then lines[#lines + 1] = cutoff end
            end
        end
        lines[#lines + 1] = " "
        lines[#lines + 1] = "Peak colors use frozen S2 cutoffs. Observed* means a confirmed lifetime peak is unavailable."
    end
    for _, line in ipairs(UI.StatusLines(data, false, record)) do lines[#lines + 1] = line end
    return lines
end

local function ShowWhisperRating(fullName)
    if not UI.Enabled("whispers") then
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
    local title = Titles.Line(name, canonicalRealm)
    if not record then
        if AutomaticExactLookupAvailable() then
            DEFAULT_CHAT_FRAME:AddMessage(prefix .. "rating not cached yet; exact lookup queued")
        else
            DEFAULT_CHAT_FRAME:AddMessage(prefix .. "not in the packaged leaderboard cache")
        end
        if title then DEFAULT_CHAT_FRAME:AddMessage(prefix .. title) end
        return
    end

    local parts = {}
    local exact = AllVisiblePeaksExact(record)
    for _, bracket in ipairs(BRACKETS) do
        local current = CurrentRating(record, bracket)
        if HasBracketRating(record, bracket) then
            parts[#parts + 1] = string.format(
                "%dv%d %s: %s",
                bracket,
                bracket,
                RatingBandLabel(current, bracket),
                BracketSummary(record, bracket)
            )
        end
    end
    if title then parts[#parts + 1] = title end

    if #parts == 0 then
        DEFAULT_CHAT_FRAME:AddMessage(prefix .. "no tracked arena rating")
    else
        DEFAULT_CHAT_FRAME:AddMessage(prefix .. table.concat(parts, " | "))
    end
end

local function AddRatingLines(tooltip, fullName, resultID)
    local surface = type(resultID) == "string" and resultID:match("^unit:") and "units" or "groupFinder"
    if not UI.Enabled(surface) or not tooltip or not tooltip:IsShown() then
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
    local details = UI.Details()
    local title = Titles.Line(name, canonicalRealm, details)
    if title then tooltip:AddLine(title, 0.80, 0.80, 0.80) end

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

    local exact = AllVisiblePeaksExact(record)
    local foundRating = false

    for _, bracket in ipairs(BRACKETS) do
        local current = CurrentRating(record, bracket)
        if HasBracketRating(record, bracket) then
            foundRating = true
            local left = string.format(
                "%dv%d  %s",
                bracket,
                bracket,
                RatingBandLabel(current, bracket)
            )
            local right = BracketSummary(record, bracket)
            tooltip:AddDoubleLine(left, right, 0.35, 0.75, 1.00, 0.80, 0.80, 0.80)
            if details then
                local _, age = UI.CurrentInfo(data, record, bracket)
                tooltip:AddLine("Rating source: " .. age .. "; " .. UI.HistoryLine(record, bracket), 0.65, 0.65, 0.65)
            end
            if details and UI.Settings().nextCutoff then
                local nextCutoff = Colors.NextCutoff(data, current, bracket)
                if nextCutoff then tooltip:AddLine(nextCutoff, 0.65, 0.65, 0.65) end
            end
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

    for _, line in ipairs(UI.StatusLines(data, details, record)) do tooltip:AddLine(line, 0.55, 0.55, 0.55) end
    if not details then tooltip:AddLine("Shift-hover for details", 0.45, 0.45, 0.45) end
    if title and details then tooltip:AddLine("Known from this client's observations; other titles may be unknown.", 0.55, 0.55, 0.55) end

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
    if not UI.Enabled("groupFinder") then
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
    local details = UI.Details()
    local title = Titles.Line(name, canonicalRealm, details)
    if title then displayLines[#displayLines + 1] = { title, 0.80, 0.80, 0.80 } end

    if not record then
        displayLines[#displayLines + 1] = { "Current rating not cached yet", 0.75, 0.75, 0.75 }
        if AutomaticExactLookupAvailable() then
            displayLines[#displayLines + 1] = { "Exact lookup queued automatically", 0.35, 0.75, 1.00 }
        else
            displayLines[#displayLines + 1] = { "Not in the packaged leaderboard cache", 0.55, 0.55, 0.55 }
        end
    else
        local exact = AllVisiblePeaksExact(record)
        local foundRating = false

        for _, bracket in ipairs(BRACKETS) do
            local current = CurrentRating(record, bracket)
            if HasBracketRating(record, bracket) then
                foundRating = true
                displayLines[#displayLines + 1] = {
                    string.format(
                        "|cff59bfff%dv%d|r  %s   %s",
                        bracket,
                        bracket,
                        RatingBandLabel(current, bracket),
                        BracketSummary(record, bracket)
                    ),
                    1.00,
                    1.00,
                    1.00,
                }
                if details then
                    local _, age = UI.CurrentInfo(data, record, bracket)
                    displayLines[#displayLines + 1] = { "Rating source: " .. age .. "; " .. UI.HistoryLine(record, bracket), 0.65, 0.65, 0.65 }
                end
                if details and UI.Settings().nextCutoff then
                    local nextCutoff = Colors.NextCutoff(data, current, bracket)
                    if nextCutoff then displayLines[#displayLines + 1] = { nextCutoff, 0.65, 0.65, 0.65 } end
                end
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

    for _, line in ipairs(UI.StatusLines(data, details, record)) do
        displayLines[#displayLines + 1] = { line, 0.55, 0.55, 0.55 }
    end
    if not details then displayLines[#displayLines + 1] = { "Shift-hover for details", 0.45, 0.45, 0.45 } end
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
            Titles.Observe(unitToken)
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
eventFrame:RegisterEvent("KNOWN_TITLES_UPDATE")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME or arg1 == "Blizzard_GroupFinder" or arg1 == "Blizzard_GroupFinder_VanillaStyle" then
            InstallHooks()
        end
    elseif event == "PLAYER_LOGIN" then
        InstallHooks()
        Titles.Prune()
        Titles.Observe("player")
        local sync = NightslayerRatingSyncStatus or {}
        if UI.Enabled() and UI.NewerVersion(sync.availableVersion, UI.version) then
            print("|cffffd200Nightslayer Rating:|r version " .. sync.availableVersion .. " available. Close WoW and run Upgrade.cmd in Windows.")
        end
    elseif event == "KNOWN_TITLES_UPDATE" then
        Titles.Observe("player")
    elseif event == "PLAYER_TARGET_CHANGED" then
        Titles.Observe("target")
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

    if command == "options" or command == "settings" then
        UI.OpenOptions()
    elseif command == "on" then
        NightslayerRatingSettings.enabled = true
        print("|cffffd200Nightslayer Rating:|r enabled")
    elseif command == "off" then
        NightslayerRatingSettings.enabled = false
        print("|cffffd200Nightslayer Rating:|r disabled")
    elseif command == "cutoffs" then
        print(Colors.Status(data))
        for _, season in ipairs({ CurrentSeason(), PEAK_COMPARISON_SEASON }) do
            if season > 0 then
                for _, bracket in ipairs(BRACKETS) do
                    print(Colors.Details(data, season, bracket))
                end
            end
        end
        print("Current uses current-season cutoffs. Lifetime Peak/Observed uses frozen S2 cutoffs as a color guide, not an earned-title claim.")
    elseif command == "lookup" or command == "search" then
        UI.OpenSearch(rest)
    elseif command == "upgrade" then
        print("|cffffd200Nightslayer Rating:|r close WoW and run Upgrade.cmd from the Windows bundle or the Nightslayer Rating folder in your Start menu.")
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
        print("Installed version: " .. UI.version)
        for _, line in ipairs(UI.StatusLines(data, true)) do print(line) end
        print("Commands: /nsr search [NAME-REALM], /nsr options, /nsr status, /nsr on, /nsr off, /nsr cutoffs, /nsr lookup [NAME-REALM], /nsr upgrade")
    end
end
