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
    if not automatic then return "Exact profiles require the Windows companion." end
    if record and (tonumber(record.notFoundUntil) or 0) > time() then
        return "Profile unavailable; retry after " .. date("%Y-%m-%d", record.notFoundUntil) .. "."
    end
    if record and (tonumber(record.profileAttemptAt) or 0) > (tonumber(record.exactFetchedAt) or 0) then
        return "Profile lookup will retry; cached ratings remain available."
    end
    if record and record.exact then return "Profile cached; active players are checked about daily." end
    return "Exact profile lookup queued."
end
