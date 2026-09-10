-- Cutoff ranges describe a rating, never an earned title or season reward.
NightslayerRatingColors = {}
local Colors = NightslayerRatingColors
local BANDS = {
    { label = "Elite", hex = "ff8000", cutoff = "Rank One" },
    { label = "Excellent", hex = "a335ee", cutoff = "Gladiator" },
    { label = "Strong", hex = "0070dd", cutoff = "Duelist" },
    { label = "Competitive", hex = "1eff00", cutoff = "Rival" },
    { label = "Rated", hex = "ffffff", cutoff = "Challenger" },
}
local INACTIVE = { label = "Inactive", hex = "aaaaaa" }
local UNCLASSIFIED = { label = "Rated", hex = "ffffff" }
local BELOW = { label = "Below cutoff", hex = "aaaaaa" }

function Colors.GetCutoffs(data, season, bracket)
    if not data or not data.meta or data.meta.region ~= "US" then return nil end
    local seasons = data.cutoffs or {}
    local brackets = seasons[season] or seasons[tostring(season)]
    local entry = brackets and (brackets[bracket] or brackets[tostring(bracket)])
    if type(entry) ~= "table" or type(entry.thresholds) ~= "table" or
        #entry.thresholds ~= 5 or (tonumber(entry.updated) or 0) <= 0 then return nil end
    local previous = 10000
    for _, minimum in ipairs(entry.thresholds) do
        if type(minimum) ~= "number" or minimum ~= math.floor(minimum) or
            minimum < 1 or minimum > previous then return nil end
        previous = minimum
    end
    return entry
end

function Colors.Band(data, value, bracket, season)
    local rating = tonumber(value) or 0
    if rating <= 0 then return INACTIVE end
    -- All-time records have no season provenance. Missing cutoffs also get a
    -- neutral color; never substitute another bracket or season's thresholds.
    if not season or not bracket then return UNCLASSIFIED end
    local entry = Colors.GetCutoffs(data, season, bracket)
    if not entry then return UNCLASSIFIED end
    for index, minimum in ipairs(entry.thresholds) do
        if rating >= minimum then return BANDS[index] end
    end
    return BELOW
end

function Colors.Text(band, text)
    return "|cff" .. band.hex .. tostring(text) .. "|r"
end

function Colors.Status(data)
    local season = data.meta and data.meta.season or 0
    local oldest, missing = nil, {}
    for _, bracket in ipairs({ 2, 3, 5 }) do
        local entry = Colors.GetCutoffs(data, season, bracket)
        if entry then
            oldest = math.min(oldest or entry.updated, entry.updated)
        else
            missing[#missing + 1] = bracket .. "v" .. bracket
        end
    end
    local prefix = "US S" .. season .. " cutoffs: "
    if #missing > 0 then return prefix .. table.concat(missing, ", ") .. " unavailable" end
    local stale = time() - oldest > 48 * 60 * 60
    return prefix .. date("%Y-%m-%d", oldest) .. (stale and " (stale)" or "")
end

function Colors.Details(data, season, bracket)
    local entry = Colors.GetCutoffs(data, season, bracket)
    local prefix = "US S" .. season .. " " .. bracket .. "v" .. bracket .. ": "
    if not entry then return prefix .. "cutoffs unavailable" end
    local parts = {}
    for index, value in ipairs(entry.thresholds) do
        parts[#parts + 1] = Colors.Text(BANDS[index], BANDS[index].cutoff .. " " .. value)
    end
    return prefix .. table.concat(parts, " / ") .. " (" .. date("%Y-%m-%d", entry.updated) .. ")"
end
