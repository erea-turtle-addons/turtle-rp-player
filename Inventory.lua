-- Inventory.lua - Inventory module for RPPlayer
-- Manages player RP inventory, item display, reading, and trading

local ADDON_PREFIX = "RPMSTR"
local MAX_SLOTS = 16

-- Note: RPPlayerDB is initialized by Core.lua, which loads first in the TOC
-- No initialization here - just use the table created by Core.lua

-- Local references to frames
local inventoryContent = nil
local itemSlots = {}
local readFrame = nil
local draggedItem = nil
local dragFrame = nil

-- Constants
local SLOT_SIZE = 47
local ICON_SIZE = 26
local SLOT_SPACING = 3

-- Function: Create inventory content frame
function RPInventory_CreateContent(parent)
    inventoryContent = CreateFrame("Frame", "RPInventoryContent", parent)
    inventoryContent:SetAllPoints()

    -- Container for item slots (4x4 grid)
    local slotsContainer = CreateFrame("Frame", nil, inventoryContent)
    slotsContainer:SetPoint("CENTER", inventoryContent, "CENTER", 0, 0)
    slotsContainer:SetWidth(200)
    slotsContainer:SetHeight(200)

    -- Create item slot frames (created once)
    for i = 1, MAX_SLOTS do
        local row = math.floor((i - 1) / 4)
        local col = math.mod(i - 1, 4)

        local slotName = "RPBagSlot"..i
        local slot = CreateFrame("Button", slotName, slotsContainer)
        slot:SetWidth(SLOT_SIZE)
        slot:SetHeight(SLOT_SIZE)
        slot:SetPoint("TOPLEFT", col * (SLOT_SIZE + SLOT_SPACING), -row * (SLOT_SIZE + SLOT_SPACING))
        slot:EnableMouse(true)
        slot:RegisterForClicks("LeftButtonUp", "RightButtonDown", "RightButtonUp")
        slot.slotName = slotName

        -- Empty slot background
        local bg = slot:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\Buttons\\UI-EmptySlot")
        slot.bg = bg

        -- Item icon texture (centered, smaller than slot)
        local icon = slot:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(ICON_SIZE)
        icon:SetHeight(ICON_SIZE)
        icon:SetPoint("CENTER", slot, "CENTER", 0, 0)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        icon:Hide()

        slot.icon = icon
        slot.item = nil
        itemSlots[i] = slot
    end

    -- Create read frame (item viewing window)
    RPInventory_CreateReadFrame()

    return inventoryContent
end

-- Function: Create read frame for viewing item content
function RPInventory_CreateReadFrame()
    readFrame = CreateFrame("Frame", "RPReadFrame", UIParent)
    readFrame:SetWidth(450)
    readFrame:SetHeight(500)
    readFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    readFrame:SetFrameStrata("DIALOG")
    readFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    readFrame:SetBackdropColor(0, 0, 0, 1)
    readFrame:SetMovable(true)
    readFrame:Hide()

    -- Load saved position (backward compat with old bagFramePos)
    if RPPlayerDB.readFramePos then
        readFrame:ClearAllPoints()
        readFrame:SetPoint(RPPlayerDB.readFramePos[1], UIParent, RPPlayerDB.readFramePos[2], RPPlayerDB.readFramePos[3], RPPlayerDB.readFramePos[4])
    end

    local readTitle = readFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    readTitle:SetPoint("TOP", 0, -20)
    readFrame.title = readTitle

    -- Draggable title bar
    local readTitleBar = CreateFrame("Frame", nil, readFrame)
    readTitleBar:SetPoint("TOPLEFT", 10, -10)
    readTitleBar:SetPoint("TOPRIGHT", -30, -10)
    readTitleBar:SetHeight(30)
    readTitleBar:EnableMouse(true)
    readTitleBar:RegisterForDrag("LeftButton")
    readTitleBar:SetScript("OnDragStart", function()
        readFrame:StartMoving()
    end)
    readTitleBar:SetScript("OnDragStop", function()
        readFrame:StopMovingOrSizing()
        -- Save position
        local point, relativeTo, relativePoint, xOfs, yOfs = readFrame:GetPoint()
        RPPlayerDB.readFramePos = {point, relativePoint, xOfs, yOfs}
    end)

    local readCloseBtn = CreateFrame("Button", nil, readFrame, "UIPanelCloseButton")
    readCloseBtn:SetPoint("TOPRIGHT", -5, -5)

    -- Scrollable text area for content
    local readScrollFrame = CreateFrame("ScrollFrame", "RPReadScrollFrame", readFrame, "UIPanelScrollFrameTemplate")
    readScrollFrame:SetPoint("TOPLEFT", 20, -50)
    readScrollFrame:SetPoint("BOTTOMRIGHT", -40, 20)

    local readScrollChild = CreateFrame("Frame", nil, readScrollFrame)
    readScrollChild:SetWidth(380)
    readScrollChild:SetHeight(1)

    local readText = readScrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    readText:SetWidth(380)
    readText:SetJustifyH("LEFT")
    readText:SetJustifyV("TOP")
    readText:SetSpacing(3)
    readText:SetPoint("TOPLEFT", readScrollChild, "TOPLEFT", 0, 0)

    readScrollFrame:SetScrollChild(readScrollChild)
    readFrame.scrollChild = readScrollChild
    readFrame.text = readText
end

-- Function: Create drag frame for item trading
local function CreateDragFrame()
    if not dragFrame then
        dragFrame = CreateFrame("Frame", "RPDragFrame", UIParent)
        dragFrame:SetWidth(SLOT_SIZE)
        dragFrame:SetHeight(SLOT_SIZE)
        dragFrame:SetFrameStrata("TOOLTIP")
        dragFrame:Hide()

        local icon = dragFrame:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        dragFrame.icon = icon

        dragFrame:SetScript("OnUpdate", function()
            local x, y = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            dragFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
        end)
    end
    return dragFrame
end

-- Function: Start drag
local function StartDrag(item)
    draggedItem = item
    local frame = CreateDragFrame()
    frame.icon:SetTexture(item.icon)
    frame:Show()
end

-- Function: Stop drag
local function StopDrag()
    if dragFrame then
        dragFrame:Hide()
    end

    -- Check if hovering over another player
    if draggedItem and UnitExists("mouseover") and UnitIsPlayer("mouseover") then
        local targetName = UnitName("mouseover")
        if targetName and targetName ~= UnitName("player") then
            RPInventory_TradeItem(draggedItem, targetName)
        end
    end

    draggedItem = nil
end

-- Function: Trade item with another player
function RPInventory_TradeItem(item, targetName)
    -- Send item (Lua 5.0: use string.gsub instead of string:gsub)
    local data = string.format("TRADE|%d|%s|%s|%s|%s",
        item.id,
        string.gsub(item.name, "|", ""),
        string.gsub(item.icon, "|", ""),
        string.gsub(item.tooltip or "", "|", ""),
        string.gsub(item.content or "", "|", "")
    )

    SendAddonMessage(ADDON_PREFIX, data, "WHISPER", targetName)

    -- Remove from inventory
    for i, invItem in ipairs(RPPlayerDB.inventory) do
        if invItem.id == item.id and invItem.guid == item.guid then
            table.remove(RPPlayerDB.inventory, i)
            break
        end
    end

    RPInventory_RefreshBag()
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r You gave '%s' to %s", item.name, targetName), 0, 1, 0)
end

-- Function: Read item
function RPInventory_ReadItem(item)
    if not readFrame then return end

    readFrame.title:SetText(item.name)

    if item.content and item.content ~= "" then
        readFrame.text:SetText(item.content)
    else
        readFrame.text:SetText(item.tooltip or "This item has no content to read.")
    end

    local textHeight = readFrame.text:GetHeight()
    if textHeight and textHeight > 0 then
        readFrame.scrollChild:SetHeight(textHeight)
    else
        readFrame.scrollChild:SetHeight(400)
    end

    readFrame:Show()
end

-- Function: Refresh bag display
function RPInventory_RefreshBag()
    -- Safety check
    if not RPPlayerDB or not RPPlayerDB.inventory then
        return
    end

    -- Clear all slots
    for i = 1, MAX_SLOTS do
        local slot = itemSlots[i]
        if slot then
            slot.icon:Hide()
            slot.item = nil

            -- Clear scripts
            slot:SetScript("OnEnter", nil)
            slot:SetScript("OnLeave", nil)
            slot:SetScript("OnClick", nil)
            slot:SetScript("OnMouseDown", nil)
            slot:SetScript("OnMouseUp", nil)
            slot:EnableMouse(false)
        end
    end

    -- Fill slots with items
    for i, item in ipairs(RPPlayerDB.inventory) do
        if i > MAX_SLOTS then break end

        local slot = itemSlots[i]
        if slot then
            slot.item = item
            slot.icon:SetTexture(item.icon)
            slot.icon:Show()
            slot:EnableMouse(true)

            -- Create closure-safe local references
            local currentItem = item
            local slotIndex = i
            local currentSlotName = slot.slotName

            -- Tooltip
            slot:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(currentItem.name, 1, 1, 1)
                if currentItem.tooltip and currentItem.tooltip ~= "" then
                    GameTooltip:AddLine(currentItem.tooltip, 1, 0.82, 0, 1)
                end

                if currentItem.content and currentItem.content ~= "" then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Right-click to read", 0, 1, 0)
                end
                GameTooltip:AddLine("Left-click to give", 0, 1, 0)
                GameTooltip:ClearAllPoints()
                GameTooltip:SetPoint("BOTTOMRIGHT", currentSlotName, "TOPLEFT", 10, -10)
                GameTooltip:Show()
            end)

            slot:SetScript("OnLeave", function()
                GameTooltip:Hide()
                GameTooltip:ClearAllPoints()
            end)

            -- Right click: Read (only if has content)
            slot:SetScript("OnClick", function(self)
                if arg1 == "RightButton" then
                    if currentItem.content and currentItem.content ~= "" then
                        RPInventory_ReadItem(currentItem)
                    end
                end
            end)

            -- Left click: Drag to give
            slot:SetScript("OnMouseDown", function(self)
                if arg1 == "LeftButton" then
                    StartDrag(currentItem)
                end
            end)

            slot:SetScript("OnMouseUp", function(self)
                if arg1 == "LeftButton" then
                    StopDrag()
                end
            end)
        end
    end
end

-- Function: Show callback (called when tab becomes active)
function RPInventory_Show()
    RPInventory_RefreshBag()
end

-- Function: Hide callback (called when tab becomes inactive)
function RPInventory_Hide()
    -- Nothing special needed
end

-- Message reception
local eventFrame = CreateFrame("Frame")

-- Wait for PLAYER_LOGIN before registering for events
-- PLAYER_LOGIN fires AFTER VARIABLES_LOADED, so RPPlayerDB will be ready
eventFrame:RegisterEvent("PLAYER_LOGIN")

eventFrame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        -- Now register for the events we actually care about
        eventFrame:RegisterEvent("CHAT_MSG_ADDON")
        eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        eventFrame:UnregisterEvent("PLAYER_LOGIN")
        return
    end

    -- Safety check (should never happen now, but just in case)
    if not RPPlayerDB then
        return
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender = arg1, arg2, arg3, arg4

        if prefix == ADDON_PREFIX then
            -- Parse message
            local parts = {}
            for part in string.gmatch(message, "([^|]+)") do
                table.insert(parts, part)
            end

            if parts[1] == "GIVE" then
                -- Received item from GM
                local item = {
                    id = tonumber(parts[2]),
                    name = parts[3],
                    icon = parts[4],
                    tooltip = parts[5],
                    content = parts[6],
                    guid = string.format("%d-%s-%d", time(), sender, tonumber(parts[2]))
                }

                -- Check if bag is full
                if table.getn(RPPlayerDB.inventory) >= MAX_SLOTS then
                    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Your bag is full!", 1, 0, 0)
                    return
                end

                table.insert(RPPlayerDB.inventory, item)
                RPInventory_RefreshBag()

                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r You received: %s", item.name), 0, 1, 0)

            elseif parts[1] == "TRADE" then
                -- Received item from another player
                local item = {
                    id = tonumber(parts[2]),
                    name = parts[3],
                    icon = parts[4],
                    tooltip = parts[5],
                    content = parts[6],
                    guid = string.format("%d-%s-%d", time(), sender, tonumber(parts[2]))
                }

                -- Check if bag is full
                if table.getn(RPPlayerDB.inventory) >= MAX_SLOTS then
                    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Your bag is full!", 1, 0, 0)
                    return
                end

                table.insert(RPPlayerDB.inventory, item)
                RPInventory_RefreshBag()

                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r %s gave you: %s", sender, item.name), 0, 1, 0)
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Ensure inventory table exists
        if not RPPlayerDB.inventory then
            RPPlayerDB.inventory = {}
        end

        -- Add welcome item if inventory is empty (first time use)
        if table.getn(RPPlayerDB.inventory) == 0 then
            local welcomeItem = {
                id = 0,
                name = "Welcome notice",
                icon = "Interface\\Icons\\INV_Misc_Note_01",
                tooltip = "Welcome to RP Player",
                content = "Welcome to RP Player, this addon gives you access to custom objects for RP events",
                guid = "system-welcome-0"
            }
            table.insert(RPPlayerDB.inventory, welcomeItem)
        end
    end
end)

-- Register module with Core
RP_RegisterModule("inventory", {
    createContent = RPInventory_CreateContent,
    onShow = RPInventory_Show,
    onHide = RPInventory_Hide
})
