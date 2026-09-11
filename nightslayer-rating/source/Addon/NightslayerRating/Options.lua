NightslayerRatingUI = {}
local UI = NightslayerRatingUI
UI.version = "1.5.0"
local defaults = {
    enabled = true, groupFinder = true, units = true, whispers = true,
    compact = true, nextCutoff = true, titles = true,
    bracket2 = true, bracket3 = true, bracket5 = true,
}

function UI.Settings()
    if type(NightslayerRatingSettings) ~= "table" then NightslayerRatingSettings = {} end
    for key, value in pairs(defaults) do
        if type(NightslayerRatingSettings[key]) ~= "boolean" then NightslayerRatingSettings[key] = value end
    end
    return NightslayerRatingSettings
end

function UI.Enabled(surface)
    local settings = UI.Settings()
    return settings.enabled and (not surface or settings[surface])
end

function UI.Bracket(bracket)
    return UI.Settings()["bracket" .. bracket]
end

function UI.Details()
    return not UI.Settings().compact or (type(IsShiftKeyDown) == "function" and IsShiftKeyDown())
end

function UI.Age(stamp)
    stamp = tonumber(stamp)
    if not stamp or stamp <= 0 then return "unknown" end
    local seconds = math.max(0, time() - stamp)
    if seconds < 60 then return "just now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local panel
function UI.OpenOptions()
    if not panel then
        panel = CreateFrame("Frame", "NightslayerRatingOptions", UIParent, "BasicFrameTemplateWithInset")
        panel:SetSize(390, 435)
        panel:SetPoint("CENTER")
        panel:SetMovable(true)
        panel:EnableMouse(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetScript("OnDragStart", panel.StartMoving)
        panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
        panel.TitleText:SetText("Nightslayer Rating " .. UI.version)
        if UISpecialFrames then table.insert(UISpecialFrames, "NightslayerRatingOptions") end
        local choices = {
            {"enabled", "Enable Nightslayer Rating"},
            {"groupFinder", "Group Finder tooltips"}, {"units", "Player tooltips"},
            {"whispers", "Private whisper summaries"}, {"compact", "Compact tooltips (Shift-hover for details)"},
            {"nextCutoff", "Distance to next current-season cutoff"}, {"titles", "Highest known arena title"},
            {"bracket2", "Show 2v2"}, {"bracket3", "Show 3v3"}, {"bracket5", "Show 5v5"},
        }
        panel.checks = {}
        for index, choice in ipairs(choices) do
            local key = choice[1]
            local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            check:SetPoint("TOPLEFT", 14, -32 - (index - 1) * 31)
            local label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            label:SetPoint("LEFT", check, "RIGHT", 2, 0)
            label:SetText(choice[2])
            check:SetScript("OnClick", function(self) UI.Settings()[key] = self:GetChecked() and true or false end)
            panel.checks[key] = check
        end
        local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        note:SetPoint("BOTTOMLEFT", 18, 25)
        note:SetWidth(350)
        note:SetJustifyH("LEFT")
        note:SetText("/nsr search opens player search. Peak colors use S2 cutoffs.\n/nsr status shows data age and download results.")
    end
    for key, check in pairs(panel.checks) do check:SetChecked(UI.Settings()[key]) end
    panel:Show()
end

UI.Settings()
