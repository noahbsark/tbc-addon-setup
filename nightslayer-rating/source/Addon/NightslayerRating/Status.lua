local UI = NightslayerRatingUI
local modes = { shared = "Shared download succeeded", direct = "Direct download succeeded",
    partial = "Partial download; some cached ratings retained", cached = "Download failed; using cached ratings",
    failed = "Update failed; previous data retained", bundled = "Included snapshot",
    retained = "Published snapshot is older; newer cached ratings retained" }

function UI.StatusLines(data, details, record)
    local sync = NightslayerRatingSyncStatus or {}
    local meta = data.meta or {}
    local stamp = tonumber(meta.leaderboardUpdated) or 0
    local complete, oldest = true, nil
    for _, bracket in ipairs({2, 3, 5}) do
        local value = meta.leaderboardUpdates and tonumber(meta.leaderboardUpdates[bracket])
        if not value or value <= 0 then complete = false else oldest = math.min(oldest or value, value) end
    end
    if complete then stamp = oldest end
    local lines = { (complete and "Ratings: " or "Latest rating source: ") .. UI.Age(stamp) ..
        ((stamp > 0 and time() - stamp > 48 * 3600) and " (stale)" or "") }
    local cutoffStatus = NightslayerRatingColors.Status(data)
    if details or cutoffStatus:find("stale", 1, true) or cutoffStatus:find("unavailable", 1, true) then
        lines[#lines + 1] = cutoffStatus
    end
    if sync.mode ~= "shared" and sync.mode ~= "direct" and sync.mode ~= nil then
        lines[#lines + 1] = modes[sync.mode] or "Update status unavailable"
    end
    if details then
        if meta.leaderboardUpdates then
            for _, bracket in ipairs({2, 3, 5}) do
                lines[#lines + 1] = bracket .. "v" .. bracket .. " ratings: " .. UI.Age(meta.leaderboardUpdates[bracket])
            end
        end
        lines[#lines + 1] = "Last attempt: " .. UI.Age(sync.lastAttempt)
        lines[#lines + 1] = "Last complete rating download: " .. UI.Age(sync.lastSuccess)
        if record and record.exact then lines[#lines + 1] = "Peak checked: " .. UI.Age(record.exactFetchedAt) end
        if sync.pendingProfiles then lines[#lines + 1] = "Peak lookups pending: " .. sync.pendingProfiles end
        if sync.failedProfiles and sync.failedProfiles > 0 then
            lines[#lines + 1] = "Peak lookups retrying: " .. sync.failedProfiles
        end
        if sync.unavailableProfiles and sync.unavailableProfiles > 0 then
            lines[#lines + 1] = "Profiles unavailable: " .. sync.unavailableProfiles
        end
        local queueStates = { running = "in progress at last save", complete = "pass finished",
            cancelled = "stopped by user", paused = "paused after source errors", interrupted = "interrupted" }
        if queueStates[sync.queueState] then
            lines[#lines + 1] = string.format("Last queue pass: %d/%d attempted (%s)",
                tonumber(sync.queueAttempted) or 0, tonumber(sync.queueTotal) or 0, queueStates[sync.queueState])
            lines[#lines + 1] = string.format("Queue results: %d fetched, %d unavailable, %d need retry",
                tonumber(sync.queueFetched) or 0, tonumber(sync.queueMissing) or 0, tonumber(sync.queueFailed) or 0)
        end
        if (tonumber(sync.pendingProfiles) or 0) > 50 then
            lines[#lines + 1] = "Large queue: /nsr queue explains the Windows Process Queue shortcut."
        end
        lines[#lines + 1] = "Status reflects the last login or /reload."
    end
    if type(sync.availableVersion) == "string" and UI.NewerVersion(sync.availableVersion, UI.version) then
        lines[#lines + 1] = "Version " .. sync.availableVersion .. " available; run Upgrade.cmd in Windows."
    end
    return lines
end

function UI.NewerVersion(candidate, installed)
    local function parts(value)
        local a, b, c = tostring(value):match("^(%d+)%.(%d+)%.(%d+)$")
        if a then return { tonumber(a), tonumber(b), tonumber(c) } end
    end
    local a, b = parts(candidate), parts(installed)
    if not a or not b then return false end
    for i = 1, 3 do if a[i] ~= b[i] then return a[i] > b[i] end end
    return false
end
