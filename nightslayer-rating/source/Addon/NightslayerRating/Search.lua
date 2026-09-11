local UI = NightslayerRatingUI
local panel

function UI.OpenSearch(query)
    if not panel then
        panel = CreateFrame("Frame", "NightslayerRatingSearch", UIParent, "BasicFrameTemplateWithInset")
        panel:SetSize(610, 570)
        panel:SetPoint("CENTER")
        panel:SetMovable(true)
        panel:EnableMouse(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetScript("OnDragStart", panel.StartMoving)
        panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
        panel.TitleText:SetText("Nightslayer Rating - Player search")
        if UISpecialFrames then table.insert(UISpecialFrames, "NightslayerRatingSearch") end

        local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT", 20, -40)
        hint:SetText("Exact character name: Name-Nightslayer or Name-Dreamscythe")
        local input = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        input:SetPoint("TOPLEFT", 24, -62)
        input:SetSize(424, 28)
        input:SetMaxLetters(80)
        input:SetAutoFocus(false)
        input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        panel.input = input

        local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 20, -109)
        scroll:SetPoint("BOTTOMRIGHT", -39, 83)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(542, 1)
        scroll:SetScrollChild(content)
        local body = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        body:SetPoint("TOPLEFT")
        body:SetWidth(542)
        body:SetJustifyH("LEFT")
        body:SetSpacing(5)
        local function show(text)
            body:SetText(text)
            content:SetHeight(math.max(1, body:GetStringHeight() + 15))
            scroll:SetVerticalScroll(0)
        end
        panel.search = function()
            input:ClearFocus()
            local result = UI.FindPlayer(input:GetText())
            show(table.concat(result, "\n"))
        end
        input:SetScript("OnEnterPressed", panel.search)
        local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        button:SetPoint("LEFT", input, "RIGHT", 15, 0)
        button:SetSize(108, 27)
        button:SetText("Search")
        button:SetScript("OnClick", panel.search)

        local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        note:SetPoint("BOTTOMLEFT", 20, 20)
        note:SetWidth(565)
        note:SetJustifyH("LEFT")
        note:SetText("Results use the loaded cache. To process a new request: /reload to save it, run Update Now in Windows, then /reload to load the result.\nHistory covers locally tracked players; snapshots are not live match results.")
        show("Enter a player name to view Current, Peak and highest known arena title.\nAdd -Realm when searching the other realm.")
    end
    panel:Show()
    if query and query ~= "" then
        panel.input:SetText(query)
        panel.search()
    else
        panel.input:SetFocus()
    end
end
