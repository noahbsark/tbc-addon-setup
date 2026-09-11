local UI = NightslayerRatingUI

local function bracketValue(map, bracket)
    return type(map) == "table" and (map[bracket] or map[tostring(bracket)]) or nil
end

function UI.CurrentInfo(data, record, bracket)
    local stamp
    if record and type(record.current) == "table" then
        stamp = bracketValue(record.currentUpdated, bracket)
    else
        stamp = bracketValue(data.meta and data.meta.leaderboardUpdates, bracket)
    end
    stamp = tonumber(stamp) or 0
    local known = stamp <= 0 or time() - stamp > 48 * 3600 or
        bracketValue(record and record.currentLastKnown, bracket) == 1
    return known, UI.Age(stamp)
end

function UI.HistoryLine(record, bracket)
    local samples = bracketValue(record and record.history, bracket)
    if type(samples) ~= "table" or #samples < 2 then return "History: collecting local snapshots" end
    local latest = samples[#samples]
    if not latest.at or not latest.rating or time() - latest.at > 48 * 3600 then
        return "History: latest observation is stale"
    end
    local baseline
    -- Choose the oldest real observation inside seven days of the newest one.
    -- Show the actual duration, rather than extrapolating to a week.
    for _, sample in ipairs(samples) do
        if sample.at >= latest.at - 7 * 86400 and sample.at < latest.at then
            baseline = sample
            break
        end
    end
    if not baseline then return "History: no recent comparison yet" end
    local hours = (latest.at - baseline.at) / 3600
    local duration = hours >= 48 and string.format("%.1f days", hours / 24) or string.format("%.0f hours", hours)
    if hours < 1 then return "History: collecting local snapshots" end
    return string.format("Observed change: %+d over %s (snapshots)", latest.rating - baseline.rating, duration)
end

function UI.ProfileStatus(record, automatic)
    local cached = {}
    for index, bracket in ipairs({2, 3, 5}) do
        local rating = record and (bracketValue(record.current, bracket) or record[index])
        if (tonumber(rating) or 0) > 0 then cached[#cached + 1] = bracket .. "v" .. bracket end
    end
    local prefix = #cached > 0 and ("Current-season ratings cached: " .. table.concat(cached, ", ") .. ".\n") or
        "Current-season ratings: no cached data.\n"
    if record and (tonumber(record.notFoundUntil) or 0) > time() then
        return prefix .. "Profile unavailable; retry after " .. date("%Y-%m-%d", record.notFoundUntil) .. "."
    end
    if record and (tonumber(record.profileAttemptAt) or 0) > (tonumber(record.exactFetchedAt) or 0) then
        return prefix .. "Profile lookup will retry; cached ratings remain available."
    end
    if record and record.exact then
        local source = record.exactSource == "shared" and "shared cache" or "local lookup"
        return prefix .. "Peak profile cached from " .. source .. "; checked " .. UI.Age(record.exactFetchedAt) .. "."
    end
    if not automatic then return prefix .. "Exact profiles require the Windows companion." end
    return prefix .. (#cached > 0 and "Exact peak lookup pending; current ratings are already cached." or
        "Current rating and exact peak lookup pending.")
end
