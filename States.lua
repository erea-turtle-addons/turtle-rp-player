-- States.lua - States module for RPPlayer (placeholder)
-- Future: Manage character states/buffs/effects for RP

local statesContent = nil

-- Function: Create states content frame
function RPStates_CreateContent(parent)
    statesContent = CreateFrame("Frame", "RPStatesContent", parent)
    statesContent:SetAllPoints()

    -- Placeholder text
    local title = statesContent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", 0, 20)
    title:SetText("States Module")

    local description = statesContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    description:SetPoint("CENTER", 0, -10)
    description:SetText("Coming Soon")
    description:SetTextColor(0.7, 0.7, 0.7)

    local info = statesContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    info:SetPoint("CENTER", 0, -40)
    info:SetText("This module will manage character states,\nbuffs, and RP effects")
    info:SetTextColor(0.5, 0.5, 0.5)

    return statesContent
end

-- Function: Show callback
function RPStates_Show()
    -- Nothing to do yet
end

-- Function: Hide callback
function RPStates_Hide()
    -- Nothing to do yet
end

-- Register module with Core
RP_RegisterModule("states", {
    createContent = RPStates_CreateContent,
    onShow = RPStates_Show,
    onHide = RPStates_Hide
})
