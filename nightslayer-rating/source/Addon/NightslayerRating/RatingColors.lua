local _, ns = ...

-- US Season 2 reference cutoffs supplied from IronForge's Aug 31 screenshots.
-- Colors describe rating bands; they never assert a title was earned.
local COLORS = { "ff8000", "a335ee", "0070dd", "1eff00", "ffffff" }
local LABELS = { "Elite", "Excellent", "Strong", "Competitive", "Rated" }
local SEASON2_US = {
    [2] = { 2803, 2481, 1944, 1629, 1458 },
    [3] = { 2493, 2269, 1913, 1662, 1482 },
    [5] = { 2340, 2166, 1854, 1640, 1466 },
}
local GENERAL = { 2400, 2100, 1800, 1500, 1 }

function ns.GetRatingBand(value, bracket, season, region)
    local rating = tonumber(value) or 0
    if rating <= 0 then
        return { hex = "aaaaaa", label = "Inactive" }
    end
    local thresholds = GENERAL
    if tonumber(season) == 2 and region == "US" and SEASON2_US[bracket] then
        thresholds = SEASON2_US[bracket]
    end
    for index, minimum in ipairs(thresholds) do
        if rating >= minimum then
            return { hex = COLORS[index], label = LABELS[index] }
        end
    end
    return { hex = "aaaaaa", label = "Rated" }
end
