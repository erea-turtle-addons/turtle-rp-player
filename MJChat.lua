-- MJChat.lua - MJ Chat module for RPPlayer (placeholder)
-- Future: Master/Joueur chat system for RP communication

local mjchatContent = nil

-- Function: Create MJ chat content frame
function RPMJChat_CreateContent(parent)
    mjchatContent = CreateFrame("Frame", "RPMJChatContent", parent)
    mjchatContent:SetAllPoints()

    -- Placeholder text
    local title = mjchatContent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", 0, 20)
    title:SetText("MJ Chat Module")

    local description = mjchatContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    description:SetPoint("CENTER", 0, -10)
    description:SetText("Coming Soon")
    description:SetTextColor(0.7, 0.7, 0.7)

    local info = mjchatContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    info:SetPoint("CENTER", 0, -40)
    info:SetText("This module will enable Master-Joueur\ncommunication for RP events")
    info:SetTextColor(0.5, 0.5, 0.5)

    return mjchatContent
end

-- Function: Show callback
function RPMJChat_Show()
    -- Nothing to do yet
end

-- Function: Hide callback
function RPMJChat_Hide()
    -- Nothing to do yet
end

-- Register module with Core
RP_RegisterModule("mjchat", {
    createContent = RPMJChat_CreateContent,
    onShow = RPMJChat_Show,
    onHide = RPMJChat_Hide
})
