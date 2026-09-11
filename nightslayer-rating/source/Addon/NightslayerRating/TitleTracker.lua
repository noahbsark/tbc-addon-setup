-- Record only titles exposed by the game. Website placements and rating colors
-- are never evidence that a character owns a title.
NightslayerRatingTitles = {}
local Titles = NightslayerRatingTitles
local ranks = { Challenger = 1, Rival = 2, Duelist = 3, Gladiator = 4,
    ["Infernal Gladiator"] = 5, ["Merciless Gladiator"] = 5,
    ["Vengeful Gladiator"] = 5, ["Brutal Gladiator"] = 5 }
local colors = { "ffffff", "1eff00", "0070dd", "a335ee", "ff8000" }
local realms = { nightslayer = "Nightslayer", dreamscythe = "Dreamscythe" }
local function Key(name, realm)
    if type(name) ~= "string" or type(realm) ~= "string" then return nil end
    realm = realms[string.lower(realm):gsub("[%s%-]", "")]
    if not realm then return nil end
    return string.lower(realm .. "|" .. name)
end

local function Records()
    if type(NightslayerRatingKnownTitles) ~= "table" then NightslayerRatingKnownTitles = {} end
    return NightslayerRatingKnownTitles
end

function Titles.Get(name, realm)
    local key = Key(name, realm)
    local record = key and Records()[key]
    if type(record) == "table" and ranks[record.title] and type(record.guid) == "string" and
        type(record.seen) == "number" and record.seen > 0 and record.seen <= time() + 3600 then
        return record
    end
end

local function Remember(name, realm, guid, title)
    local key, rank = Key(name, realm), ranks[title]
    if not key or not rank or type(guid) ~= "string" or not guid:match("^Player%-") then return end
    local old = Titles.Get(name, realm)
    if old and old.guid == guid and ranks[old.title] > rank then return end
    Records()[key] = { title = title, guid = guid, seen = time() }
end

function Titles.Observe(unit)
    if not NightslayerRatingUI.Enabled() or not NightslayerRatingUI.Settings().titles or
        type(UnitGUID) ~= "function" or not UnitIsPlayer(unit) then return end
    local name, realm = UnitName(unit)
    realm = realm and realm ~= "" and realm or (type(GetRealmName) == "function" and GetRealmName())
    local key, guid = Key(name, realm), UnitGUID(unit)
    if not key or not guid then return end
    local old = Titles.Get(name, realm)
    if old and old.guid ~= guid then Records()[key] = nil end -- name reused by another character
    if type(UnitPVPName) == "function" then
        local ok, full = pcall(UnitPVPName, unit)
        if ok and type(full) == "string" then
            for title in pairs(ranks) do
                if full == title .. " " .. name or full == title .. " " .. name .. "-" .. realm then
                    Remember(name, realm, guid, title)
                end
            end
        end
    end
    if unit == "player" and type(GetNumTitles) == "function" and type(IsTitleKnown) == "function" and
        type(GetTitleName) == "function" then
        for id = 1, math.min(tonumber(GetNumTitles()) or 0, 5000) do
            local known = IsTitleKnown(id)
            if known == true or known == 1 then
                local title = GetTitleName(id)
                if type(title) == "string" then
                    title = title:gsub("%%s", ""):match("^%s*(.-)%s*$")
                    Remember(name, realm, guid, title)
                end
            end
        end
    end
end

function Titles.Line(name, realm, details)
    if not NightslayerRatingUI.Settings().titles then return nil end
    local record = Titles.Get(name, realm)
    if not record then return nil end
    local line = "Highest known title: |cff" .. colors[ranks[record.title]] .. record.title .. "|r"
    if details then line = line .. " (seen " .. date("%Y-%m-%d", record.seen) .. ")" end
    return line
end

function Titles.Prune()
    local valid = {}
    for key, record in pairs(Records()) do
        if type(key) ~= "string" or type(record) ~= "table" or not ranks[record.title] or
            type(record.seen) ~= "number" or record.seen <= 0 or record.seen > time() + 3600 then
            Records()[key] = nil
        else valid[#valid + 1] = { key = key, seen = record.seen } end
    end
    table.sort(valid, function(a, b) return a.seen > b.seen end)
    for i = 2001, #valid do Records()[valid[i].key] = nil end
end
