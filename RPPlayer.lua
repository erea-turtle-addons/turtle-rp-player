-- RPPlayer.lua - Player Addon
-- Manages personal RP inventory

local ADDON_NAME = "RPPlayer"
local ADDON_PREFIX = "RPMSTR"
local ADDON_VERSION = "2025-12-07 21:40"
local MAX_SLOTS = 16

-- Note: RegisterAddonMessagePrefix() doesn't exist in WoW 1.12
-- Addon messages work without registration in Vanilla

-- Debug logging system
RPPlayerDebugLog = RPPlayerDebugLog or {}

local function Log(message)
    local timestamp = date("%H:%M:%S")
    local logEntry = string.format("[%s] RPPlayer: %s", timestamp, tostring(message))
    table.insert(RPPlayerDebugLog, logEntry)
    -- Keep only last 500 entries to prevent bloat
    if table.getn(RPPlayerDebugLog) > 500 then
        table.remove(RPPlayerDebugLog, 1)
    end
end

-- Base64 decoding
local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Base64Decode(data)
    if not data or data == "" then return "" end

    -- Create reverse lookup table
    local decode_table = {}
    for i = 1, string.len(base64_chars) do
        decode_table[string.sub(base64_chars, i, i)] = i - 1
    end

    local result = {}
    local len = string.len(data)

    for i = 1, len, 4 do
        local c1 = decode_table[string.sub(data, i, i)] or 0
        local c2 = decode_table[string.sub(data, i + 1, i + 1)] or 0
        local c3 = decode_table[string.sub(data, i + 2, i + 2)] or 0
        local c4 = decode_table[string.sub(data, i + 3, i + 3)] or 0

        local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4

        -- Use math.mod instead of mod (Lua 5.0)
        local b1 = math.mod(math.floor(n / 65536), 256)
        local b2 = math.mod(math.floor(n / 256), 256)
        local b3 = math.mod(n, 256)

        table.insert(result, string.char(b1))

        if string.sub(data, i + 2, i + 2) ~= "=" then
            table.insert(result, string.char(b2))
        end

        if string.sub(data, i + 3, i + 3) ~= "=" then
            table.insert(result, string.char(b3))
        end
    end

    return table.concat(result)
end

-- Base64 encoding
local function Base64Encode(data)
    if not data or data == "" then return "" end

    local result = {}
    local len = string.len(data)

    for i = 1, len, 3 do
        local b1 = string.byte(data, i)
        local b2 = string.byte(data, i + 1) or 0
        local b3 = string.byte(data, i + 2) or 0

        local n = b1 * 65536 + b2 * 256 + b3

        -- Use math.mod instead of mod (Lua 5.0)
        local c1 = math.mod(math.floor(n / 262144), 64) + 1
        local c2 = math.mod(math.floor(n / 4096), 64) + 1
        local c3 = math.mod(math.floor(n / 64), 64) + 1
        local c4 = math.mod(n, 64) + 1

        table.insert(result, string.sub(base64_chars, c1, c1))
        table.insert(result, string.sub(base64_chars, c2, c2))

        if i + 1 <= len then
            table.insert(result, string.sub(base64_chars, c3, c3))
        else
            table.insert(result, "=")
        end

        if i + 2 <= len then
            table.insert(result, string.sub(base64_chars, c4, c4))
        else
            table.insert(result, "=")
        end
    end

    return table.concat(result)
end

-- Initialize saved variables (per character)
Log("RPPlayer.lua file loading...")
RPPlayerDB = RPPlayerDB or {
    inventory = {
        {
            id = 0,
            name = "Welcome notice",
            icon = "Interface\\Icons\\INV_Misc_Note_01",
            tooltip = "Welcome to RP Player",
            content = "Welcome to RP Player, this addon gives you access to custom objects for RP events",
            guid = "system-welcome-0"
        }
    },
    bagFramePos = nil,
    readFramePos = nil
}
Log("RPPlayerDB initialized, inventory count: " .. table.getn(RPPlayerDB.inventory))

-- Main bag frame (styled like WoW bags)
local RPBagFrame = CreateFrame("Frame", "RPBagFrame", UIParent)
RPBagFrame:SetWidth(240)
RPBagFrame:SetHeight(280)
RPBagFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
RPBagFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
RPBagFrame:SetBackdropColor(0, 0, 0, 1)
RPBagFrame:SetMovable(true)
RPBagFrame:Hide()

-- Load saved position or use default
if RPPlayerDB.bagFramePos then
    RPBagFrame:ClearAllPoints()
    RPBagFrame:SetPoint(RPPlayerDB.bagFramePos[1], UIParent, RPPlayerDB.bagFramePos[2], RPPlayerDB.bagFramePos[3], RPPlayerDB.bagFramePos[4])
end

-- Title
local title = RPBagFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -15)
title:SetText("RP Player")

-- Draggable title bar (invisible, covers title area)
local bagTitleBar = CreateFrame("Frame", nil, RPBagFrame)
bagTitleBar:SetPoint("TOPLEFT", 10, -10)
bagTitleBar:SetPoint("TOPRIGHT", -30, -10)
bagTitleBar:SetHeight(20)
bagTitleBar:EnableMouse(true)
bagTitleBar:RegisterForDrag("LeftButton")
bagTitleBar:SetScript("OnDragStart", function()
    RPBagFrame:StartMoving()
end)
bagTitleBar:SetScript("OnDragStop", function()
    RPBagFrame:StopMovingOrSizing()
    -- Save position
    local point, relativeTo, relativePoint, xOfs, yOfs = RPBagFrame:GetPoint()
    RPPlayerDB.bagFramePos = {point, relativePoint, xOfs, yOfs}
end)

-- Close button
local closeBtn = CreateFrame("Button", nil, RPBagFrame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -5, -5)

-- Container for item slots (4x4 grid)
local slotsContainer = CreateFrame("Frame", nil, RPBagFrame)
slotsContainer:SetPoint("TOPLEFT", 20, -40)
slotsContainer:SetWidth(200)
slotsContainer:SetHeight(200)

-- Item slot frames (created once)
local itemSlots = {}
local SLOT_SIZE = 47
local ICON_SIZE = 26
local SLOT_SPACING = 3

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

-- Item reading frame (for letters/documents)
local readFrame = CreateFrame("Frame", "RPReadFrame", UIParent)
DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] Read frame created: " .. tostring(readFrame ~= nil))
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
DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] Read frame initial hide called")

-- Load saved position or use default
if RPPlayerDB.readFramePos then
    readFrame:ClearAllPoints()
    readFrame:SetPoint(RPPlayerDB.readFramePos[1], UIParent, RPPlayerDB.readFramePos[2], RPPlayerDB.readFramePos[3], RPPlayerDB.readFramePos[4])
end

local readTitle = readFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
readTitle:SetPoint("TOP", 0, -20)

-- Draggable title bar (invisible, covers title area)
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

-- Item icon (shown below title)
local readIcon = readFrame:CreateTexture(nil, "ARTWORK")
readIcon:SetWidth(40)
readIcon:SetHeight(40)
readIcon:SetPoint("TOPLEFT", 20, -50)
readIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

-- Item name (next to icon)
local readItemName = readFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
readItemName:SetPoint("TOPLEFT", readIcon, "TOPRIGHT", 10, 0)
readItemName:SetPoint("RIGHT", -40, 0)
readItemName:SetJustifyH("LEFT")
readItemName:SetTextColor(1, 0.82, 0) -- Gold color

-- Item description/tooltip (below name)
local readItemDesc = readFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
readItemDesc:SetPoint("TOPLEFT", readIcon, "TOPRIGHT", 10, -20)
readItemDesc:SetPoint("RIGHT", -40, 0)
readItemDesc:SetJustifyH("LEFT")
readItemDesc:SetJustifyV("TOP")

-- Separator line (visual separator before content)
local readSeparator = readFrame:CreateTexture(nil, "ARTWORK")
readSeparator:SetHeight(1)
readSeparator:SetPoint("LEFT", 20, 0)
readSeparator:SetPoint("RIGHT", -40, 0)
readSeparator:SetPoint("TOP", readIcon, "BOTTOM", 0, -10)
readSeparator:SetTexture(0.5, 0.5, 0.5, 0.5)

-- Scrollable text area for content
local readScrollFrame = CreateFrame("ScrollFrame", "RPReadScrollFrame", readFrame, "UIPanelScrollFrameTemplate")
readScrollFrame:SetPoint("TOPLEFT", 20, -120)
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

-- Drag & drop variables
local draggedItem = nil
local dragFrame = nil

-- Function: Create drag frame
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
            RPPlayer_TradeItem(draggedItem, targetName)
        end
    end

    draggedItem = nil
end

-- Function: Show item to a specific player
function RPPlayer_ShowItem(item, targetName)
    if not targetName then
        Log("ERROR: ShowItem called without targetName")
        return
    end

    Log("ShowItem called - Item: " .. tostring(item.name) .. ", Target: " .. tostring(targetName))

    -- Build message with item details
    local rawData = "SHOW|" .. targetName .. "|" .. tostring(item.id) .. "|" .. (item.name or "") .. "|" .. (item.icon or "") .. "|" .. (item.tooltip or "") .. "|" .. (item.content or "")

    -- Base64 encode the message
    local data = Base64Encode(rawData)

    -- Determine best distribution method (same as TradeItem)
    local distribution = nil
    local whisperTarget = nil

    if GetNumRaidMembers() > 0 then
        distribution = "RAID"
        Log("Using RAID distribution (invisible)")
    elseif GetNumPartyMembers() > 0 then
        distribution = "PARTY"
        Log("Using PARTY distribution (invisible)")
    else
        distribution = "WHISPER"
        whisperTarget = targetName
        Log("Using WHISPER distribution to " .. targetName .. " (invisible, range limited)")
    end

    Log("Sending show request via " .. distribution)
    SendAddonMessage("RPMSTR", data, distribution, whisperTarget)
    Log("Item shown successfully via " .. distribution)
end

-- Function: Delete item
function RPPlayer_DeleteItem(item)
    Log("DeleteItem called - Item: " .. tostring(item.name))

    -- Remove from inventory
    for i, invItem in ipairs(RPPlayerDB.inventory) do
        if invItem.id == item.id and invItem.guid == item.guid then
            table.remove(RPPlayerDB.inventory, i)
            break
        end
    end

    RPPlayer_RefreshBag()
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r You deleted: %s", item.name), 1, 0.5, 0)
    Log("Item deleted successfully")
end

-- Function: Trade item with another player
function RPPlayer_TradeItem(item, targetName)
    Log("TradeItem called - Item: " .. tostring(item.name) .. ", Target: " .. tostring(targetName))

    -- Build raw message
    local rawData = "TRADE|" .. targetName .. "|" .. tostring(item.id) .. "|" .. (item.name or "") .. "|" .. (item.icon or "") .. "|" .. (item.tooltip or "") .. "|" .. (item.content or "")

    -- Base64 encode the entire message to avoid any escape sequence issues
    local data = Base64Encode(rawData)

    -- Determine best distribution method
    local distribution = nil
    local target = nil

    if GetNumRaidMembers() > 0 then
        distribution = "RAID"
        Log("Using RAID distribution (invisible)")
    elseif GetNumPartyMembers() > 0 then
        distribution = "PARTY"
        Log("Using PARTY distribution (invisible)")
    else
        distribution = "WHISPER"
        target = targetName
        Log("Using WHISPER distribution to " .. targetName .. " (invisible, range limited)")
    end

    Log("Sending item via " .. distribution)
    SendAddonMessage("RPMSTR", data, distribution, target)

    -- Remove from inventory
    for i, invItem in ipairs(RPPlayerDB.inventory) do
        if invItem.id == item.id and invItem.guid == item.guid then
            table.remove(RPPlayerDB.inventory, i)
            break
        end
    end

    RPPlayer_RefreshBag()
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r You gave '%s' to %s", item.name, targetName), 0, 1, 0)
    Log("Item traded successfully via " .. distribution)
end

-- Function: Read item
-- Optional shownBy parameter indicates who showed you this item
function RPPlayer_ReadItem(item, shownBy)
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] RPPlayer_ReadItem called for: " .. item.name)
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] readFrame exists: " .. tostring(readFrame ~= nil))
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] readFrame type: " .. tostring(type(readFrame)))

    if readFrame.IsShown then
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] IsShown method exists")
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] readFrame IsShown before: " .. tostring(readFrame:IsShown()))
    else
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] IsShown method does NOT exist")
    end

    if readFrame.IsVisible then
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] IsVisible: " .. tostring(readFrame:IsVisible()))
    end

    -- Set title based on context
    if shownBy then
        readTitle:SetText("An item shown by " .. shownBy)
        readTitle:Show()
    else
        readTitle:SetText("")
        readTitle:Hide()
    end

    -- Set icon
    if item.icon and item.icon ~= "" then
        readIcon:SetTexture(item.icon)
    else
        readIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    end

    -- Set item name
    readItemName:SetText(item.name or "Unknown Item")

    -- Set description/tooltip
    if item.tooltip and item.tooltip ~= "" then
        readItemDesc:SetText(item.tooltip)
    else
        readItemDesc:SetText("")
    end

    -- Set content text
    if item.content and item.content ~= "" then
        readText:SetText(item.content)
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] Content length: " .. string.len(item.content))
    else
        readText:SetText("This item has no content to read.")
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] No content, showing default message")
    end

    local textHeight = readText:GetHeight()
    if textHeight and textHeight > 0 then
        readScrollChild:SetHeight(textHeight)
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] Text height: " .. textHeight)
    else
        -- Fallback to a reasonable default
        readScrollChild:SetHeight(400)
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] Text height was nil or 0, using fallback 400")
    end

    readFrame:Show()
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] Read frame Show() called")

    if readFrame.IsShown then
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] readFrame IsShown after: " .. tostring(readFrame:IsShown()))
    end

    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] readFrame FrameStrata: " .. tostring(readFrame:GetFrameStrata()))
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] readFrame GetWidth: " .. tostring(readFrame:GetWidth()))
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] readFrame GetHeight: " .. tostring(readFrame:GetHeight()))
end

-- Helper function: Check if a unit is in range (approximately 28 yards, like /say)
local function IsPlayerInRange(unitId)
    if not unitId or not UnitExists(unitId) then
        return false
    end

    -- CheckInteractDistance(unitId, distanceIndex)
    -- 1 = Inspect (28 yards) - closest to /say range (~25 yards)
    -- 2 = Trade (11.11 yards)
    -- 3 = Duel (9.9 yards)
    -- 4 = Follow (28 yards)
    -- Using 1 (Inspect) as it's approximately /say range
    return CheckInteractDistance(unitId, 1)
end

-- Function: Show context menu for item
function RPPlayer_ShowContextMenu(item, anchorFrame)
    Log("ShowContextMenu called for item: " .. tostring(item.name))

    -- Create dropdown frame if it doesn't exist
    if not RPPlayerContextMenuFrame then
        RPPlayerContextMenuFrame = CreateFrame("Frame", "RPPlayerContextMenuFrame", UIParent, "UIDropDownMenuTemplate")
        Log("Created new dropdown frame")
    end

    -- Get raid members alphabetically, filtered by range
    local raidMembers = {}
    local allMembers = {}  -- Track all members for counting

    if GetNumRaidMembers() > 0 then
        Log("In raid mode, scanning " .. GetNumRaidMembers() .. " members")
        for i = 1, GetNumRaidMembers() do
            local name = GetRaidRosterInfo(i)
            Log("Raid slot " .. i .. ": " .. tostring(name) .. " (me: " .. tostring(UnitName("player")) .. ")")
            if name and name ~= UnitName("player") then
                table.insert(allMembers, name)
                -- Check if player is in range
                local unitId = "raid" .. i
                Log("Checking range for " .. unitId .. " (" .. name .. ")")
                if IsPlayerInRange(unitId) then
                    table.insert(raidMembers, name)
                    Log("Player " .. name .. " is in range")
                else
                    Log("Player " .. name .. " is OUT OF RANGE")
                end
            end
        end
    elseif GetNumPartyMembers() > 0 then
        -- In party (not raid)
        for i = 1, GetNumPartyMembers() do
            local name = UnitName("party"..i)
            if name then
                table.insert(allMembers, name)
                local unitId = "party" .. i
                if IsPlayerInRange(unitId) then
                    table.insert(raidMembers, name)
                    Log("Player " .. name .. " is in range")
                else
                    Log("Player " .. name .. " is OUT OF RANGE")
                end
            end
        end
    end

    -- Sort alphabetically
    table.sort(raidMembers)
    Log("Found " .. table.getn(raidMembers) .. " in-range players out of " .. table.getn(allMembers) .. " total")

    -- Store item for use in callbacks
    RPPlayerContextMenuFrame.contextItem = item
    RPPlayerContextMenuFrame.raidMembers = raidMembers
    RPPlayerContextMenuFrame.totalMembers = table.getn(allMembers)

    -- Initialize dropdown with proper WoW 1.12 syntax
    UIDropDownMenu_Initialize(RPPlayerContextMenuFrame, function(level)
        -- In WoW 1.12, level might be in UIDROPDOWNMENU_MENU_LEVEL global
        local menuLevel = level or UIDROPDOWNMENU_MENU_LEVEL or 1
        Log("UIDropDownMenu_Initialize callback, level param: " .. tostring(level) .. ", UIDROPDOWNMENU_MENU_LEVEL: " .. tostring(UIDROPDOWNMENU_MENU_LEVEL) .. ", using: " .. tostring(menuLevel))

        if menuLevel == 1 then
            -- Read option (if item has content)
            if RPPlayerContextMenuFrame.contextItem.content and RPPlayerContextMenuFrame.contextItem.content ~= "" then
                UIDropDownMenu_AddButton({
                    text = "Read",
                    func = function()
                        RPPlayer_ReadItem(RPPlayerContextMenuFrame.contextItem)
                    end,
                    notCheckable = 1
                })
            end

            -- Show to nearby submenu
            if table.getn(RPPlayerContextMenuFrame.raidMembers) > 0 then
                UIDropDownMenu_AddButton({
                    text = "Show to",
                    hasArrow = 1,
                    notCheckable = 1,
                    value = "showto"
                })
            else
                -- Determine correct message: "not in group" vs "no one in range"
                local disabledText = "Show to (not in group)"
                if RPPlayerContextMenuFrame.totalMembers > 0 then
                    disabledText = "Show to (no one in range)"
                end
                UIDropDownMenu_AddButton({
                    text = disabledText,
                    disabled = 1,
                    notCheckable = 1
                })
            end

            -- Give to submenu
            if table.getn(RPPlayerContextMenuFrame.raidMembers) > 0 then
                UIDropDownMenu_AddButton({
                    text = "Give to",
                    hasArrow = 1,
                    notCheckable = 1,
                    value = "giveto"
                })
            else
                -- Determine correct message: "not in group" vs "no one in range"
                local disabledText = "Give to (not in group)"
                if RPPlayerContextMenuFrame.totalMembers > 0 then
                    disabledText = "Give to (no one in range)"
                end
                UIDropDownMenu_AddButton({
                    text = disabledText,
                    disabled = 1,
                    notCheckable = 1
                })
            end

            -- Delete option
            UIDropDownMenu_AddButton({
                text = "Delete",
                func = function()
                    RPPlayer_PendingDeleteItem = RPPlayerContextMenuFrame.contextItem
                    StaticPopup_Show("RPPLAYER_DELETE_ITEM", RPPlayerContextMenuFrame.contextItem.name)
                end,
                notCheckable = 1
            })
        elseif menuLevel == 2 and UIDROPDOWNMENU_MENU_VALUE == "showto" then
            -- Show to submenu: All option first
            UIDropDownMenu_AddButton({
                text = "All",
                func = function()
                    -- Show to all players in range (iterate through the list)
                    local item = RPPlayerContextMenuFrame.contextItem
                    local count = 0
                    for _, playerName in ipairs(RPPlayerContextMenuFrame.raidMembers) do
                        RPPlayer_ShowItem(item, playerName)
                        count = count + 1
                    end
                    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FFFF[RP Player]|r You showed '%s' to %d nearby player(s)", item.name, count), 0, 1, 1)
                end,
                notCheckable = 1
            }, 2)

            -- Separator
            UIDropDownMenu_AddButton({
                text = "----------",
                disabled = 1,
                notCheckable = 1
            }, 2)

            -- Individual player names
            for _, playerName in ipairs(RPPlayerContextMenuFrame.raidMembers) do
                -- Create closure-safe local copy
                local targetPlayer = playerName
                UIDropDownMenu_AddButton({
                    text = targetPlayer,
                    func = function()
                        RPPlayer_ShowItem(RPPlayerContextMenuFrame.contextItem, targetPlayer)
                    end,
                    notCheckable = 1
                }, 2)
            end

        elseif menuLevel == 2 and UIDROPDOWNMENU_MENU_VALUE == "giveto" then
            -- Give to submenu with player names
            for _, playerName in ipairs(RPPlayerContextMenuFrame.raidMembers) do
                -- Create closure-safe local copy
                local targetPlayer = playerName
                UIDropDownMenu_AddButton({
                    text = targetPlayer,
                    func = function()
                        RPPlayer_TradeItem(RPPlayerContextMenuFrame.contextItem, targetPlayer)
                    end,
                    notCheckable = 1
                }, 2)
            end
        end
    end, "MENU")

    Log("Calling ToggleDropDownMenu")
    -- WoW 1.12: ToggleDropDownMenu(level, value, dropdownFrame, anchorName, xOffset, yOffset)
    -- Use "cursor" as anchor to show at mouse position
    ToggleDropDownMenu(1, nil, RPPlayerContextMenuFrame, "cursor", 0, 0)
    Log("Menu should be visible now")
end

-- Global variables to store pending items (WoW 1.12 compatibility)
RPPlayer_PendingDeleteItem = nil
RPPlayer_PendingShowItem = nil
RPPlayer_PendingShowSender = nil

-- Static popup for delete confirmation
StaticPopupDialogs["RPPLAYER_DELETE_ITEM"] = {
    text = "Delete '%s'?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function()
        if RPPlayer_PendingDeleteItem then
            RPPlayer_DeleteItem(RPPlayer_PendingDeleteItem)
            RPPlayer_PendingDeleteItem = nil
        end
    end,
    OnCancel = function()
        RPPlayer_PendingDeleteItem = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true
}

-- Static popup for show item request
StaticPopupDialogs["RPPLAYER_SHOW_REQUEST"] = {
    text = "%s wants to show you an object",
    button1 = "Accept",
    button2 = "Reject",
    OnAccept = function()
        if RPPlayer_PendingShowItem then
            -- Show the read frame with the item content, including who showed it
            RPPlayer_ReadItem(RPPlayer_PendingShowItem, RPPlayer_PendingShowSender)

            -- Send acceptance message to chat
            if RPPlayer_PendingShowSender then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r You accepted to view '%s' from %s", RPPlayer_PendingShowItem.name, RPPlayer_PendingShowSender), 0, 1, 0)
            end

            RPPlayer_PendingShowItem = nil
            RPPlayer_PendingShowSender = nil
        end
    end,
    OnCancel = function()
        if RPPlayer_PendingShowSender and RPPlayer_PendingShowItem then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r You rejected to view '%s' from %s", RPPlayer_PendingShowItem.name, RPPlayer_PendingShowSender), 1, 0, 0)

            -- Send rejection notification back to sender
            local myName = UnitName("player")
            local rawData = "SHOW_REJECT|" .. RPPlayer_PendingShowSender .. "|" .. myName .. "|" .. RPPlayer_PendingShowItem.name
            local data = Base64Encode(rawData)

            -- Use same channel selection as other messages
            local distribution = nil
            local whisperTarget = nil

            if GetNumRaidMembers() > 0 then
                distribution = "RAID"
            elseif GetNumPartyMembers() > 0 then
                distribution = "PARTY"
            else
                distribution = "WHISPER"
                whisperTarget = RPPlayer_PendingShowSender
            end

            SendAddonMessage("RPMSTR", data, distribution, whisperTarget)
            Log("Sent SHOW_REJECT to " .. RPPlayer_PendingShowSender .. " via " .. distribution)
        end
        RPPlayer_PendingShowItem = nil
        RPPlayer_PendingShowSender = nil
    end,
    timeout = 20,
    whileDead = true,
    hideOnEscape = true
}

-- Function: Refresh bag display
function RPPlayer_RefreshBag()
    Log("RefreshBag called, inventory count: " .. table.getn(RPPlayerDB.inventory))

    -- Clear all slots
    for i = 1, MAX_SLOTS do
        local slot = itemSlots[i]
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
    Log("All slots cleared")

    -- Fill slots with items
    for i, item in ipairs(RPPlayerDB.inventory) do
        if i > MAX_SLOTS then break end

        Log("Setting up slot " .. i .. " with item: " .. tostring(item.name))
        local slot = itemSlots[i]
        slot.item = item
        slot.icon:SetTexture(item.icon)
        slot.icon:Show()
        slot:EnableMouse(true)
        Log("Slot " .. i .. " configured, mouse enabled")

        -- Create closure-safe local references
        local currentItem = item
        local slotIndex = i
        local currentSlotName = slot.slotName

        -- Tooltip
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] Setting OnEnter handler for slot " .. slotIndex)
        slot:SetScript("OnEnter", function(self)
            DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] OnEnter triggered for: " .. currentItem.name)
            -- Position tooltip above-left of item slot
            GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(currentItem.name, 1, 1, 1)
            if currentItem.tooltip and currentItem.tooltip ~= "" then
                GameTooltip:AddLine(currentItem.tooltip, 1, 0.82, 0, 1)
            end

            GameTooltip:AddLine(" ")
            if currentItem.content and currentItem.content ~= "" then
                GameTooltip:AddLine("Left-click to read", 0, 1, 0)
            end
            GameTooltip:AddLine("Right-click for options", 0, 1, 0)
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("BOTTOMRIGHT", currentSlotName, "TOPLEFT", 10, -10)
            GameTooltip:Show()
            DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] GameTooltip:Show() called")
        end)
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] OnEnter handler set for slot " .. slotIndex)

        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] Setting OnLeave handler for slot " .. slotIndex)
        slot:SetScript("OnLeave", function()
            DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] OnLeave triggered for slot " .. slotIndex)
            GameTooltip:Hide()
            GameTooltip:ClearAllPoints()
        end)
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG] OnLeave handler set for slot " .. slotIndex)

        -- Left click: Read item (only if has content)
        -- Right click: Show context menu
        slot:SetScript("OnClick", function(self, button)
            Log("OnClick fired - button: " .. tostring(button) .. ", arg1: " .. tostring(arg1))

            -- Try both self parameter and arg1 (WoW 1.12 compatibility)
            local clickButton = button or arg1

            if clickButton == "LeftButton" then
                -- Only allow reading if item has content
                if currentItem.content and currentItem.content ~= "" then
                    Log("Left click detected, reading item")
                    RPPlayer_ReadItem(currentItem)
                else
                    Log("Left click ignored - item has no content")
                end
            elseif clickButton == "RightButton" then
                Log("Right click detected, showing menu")
                RPPlayer_ShowContextMenu(currentItem, self)
            else
                Log("Unknown button: " .. tostring(clickButton))
            end
        end)

        -- Register for both left and right clicks
        slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end
end

-- Message reception
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_LOGIN")

eventFrame:SetScript("OnEvent", function()
    if event == "CHAT_MSG_ADDON" then
        -- Handle all addon messages (GIVE from GM, TRADE from players)
        local prefix, encodedMessage, distribution, sender = arg1, arg2, arg3, arg4

        -- Only process and log our addon messages
        if prefix ~= ADDON_PREFIX then
            return
        end

        Log("CHAT_MSG_ADDON received - prefix: " .. tostring(prefix) .. ", distribution: " .. tostring(distribution) .. ", sender: " .. tostring(sender))
        Log("Base64 encoded (original): " .. encodedMessage)

        -- Decode Base64 message
        local message = Base64Decode(encodedMessage)
        Log("Decoded message length: " .. string.len(message))
        Log("Decoded message (full): " .. message)

        -- Parse message (Lua 5.0 uses gfind, not gmatch)
        local parts = {}
        for part in string.gfind(message, "([^|]+)") do
            table.insert(parts, part)
        end

        Log("Message parts count: " .. table.getn(parts) .. ", Command: " .. tostring(parts[1]))

        -- Log all parts for debugging
        for i = 1, table.getn(parts) do
            Log("Part " .. i .. ": " .. tostring(parts[i]))
        end

        if parts[1] == "GIVE" or parts[1] == "TRADE" then
            -- Format: GIVE/TRADE|targetName|id|name|icon|tooltip|content
            local targetName = parts[2]
            local myName = UnitName("player")

            Log(parts[1] .. " - Target: " .. tostring(targetName) .. ", MyName: " .. tostring(myName))

            if targetName ~= myName then
                Log("Message not for me")
                return
            end

            local item = {
                id = tonumber(parts[3]),
                name = parts[4],
                icon = parts[5],
                tooltip = parts[6],
                content = parts[7],
                guid = string.format("%d-%s-%d", time(), sender, tonumber(parts[3]))
            }

            Log("Item received - ID: " .. tostring(item.id) .. ", Name: " .. tostring(item.name) .. ", Icon: " .. tostring(item.icon))

            if table.getn(RPPlayerDB.inventory) >= MAX_SLOTS then
                Log("Bag is full!")
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Your bag is full!", 1, 0, 0)
                return
            end

            table.insert(RPPlayerDB.inventory, item)
            RPPlayer_RefreshBag()

            if parts[1] == "GIVE" then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r You received: %s from %s", item.name, sender), 0, 1, 0)
            else
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r %s gave you: %s", sender, item.name), 0, 1, 0)
            end

        elseif parts[1] == "SHOW" then
            -- Format: SHOW|targetName|id|name|icon|tooltip|content
            local targetName = parts[2]
            local myName = UnitName("player")

            -- Check if message is for me
            if targetName ~= myName then
                Log("SHOW message not for me (target: " .. tostring(targetName) .. ", me: " .. tostring(myName) .. ")")
                return
            end

            -- Don't add to inventory, just display
            local item = {
                id = tonumber(parts[3]),
                name = parts[4],
                icon = parts[5],
                tooltip = parts[6],
                content = parts[7]
            }

            Log("SHOW received from " .. sender .. " - Item: " .. tostring(item.name))

            -- Store item and sender for popup callbacks
            RPPlayer_PendingShowItem = item
            RPPlayer_PendingShowSender = sender

            -- Show standard confirmation popup
            StaticPopup_Show("RPPLAYER_SHOW_REQUEST", sender)

        elseif parts[1] == "SHOW_REJECT" then
            -- Format: SHOW_REJECT|targetName|rejecterName|itemName
            local targetName = parts[2]
            local rejecterName = parts[3]
            local itemName = parts[4]
            local myName = UnitName("player")

            -- Check if message is for me
            if targetName ~= myName then
                Log("SHOW_REJECT not for me (target: " .. tostring(targetName) .. ", me: " .. tostring(myName) .. ")")
                return
            end

            Log("SHOW_REJECT received from " .. rejecterName .. " for item: " .. tostring(itemName))

            -- Display rejection message to the shower
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r %s rejected to view '%s'", rejecterName, itemName), 1, 0.5, 0)
        end

    elseif event == "PLAYER_LOGIN" then
        Log("PLAYER_LOGIN event fired")

        -- This event fires once after SavedVariables are loaded
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700[RP Player] Version: " .. ADDON_VERSION .. "|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FFFF[RP Player]|r Commands: /rpplayer, /rpplayer log", 0, 1, 1)
        Log("Version message displayed")

        -- Check if RPPlayerDB exists
        if RPPlayerDB then
            Log("RPPlayerDB exists: " .. type(RPPlayerDB))
            if RPPlayerDB.inventory then
                Log("RPPlayerDB.inventory exists, count: " .. table.getn(RPPlayerDB.inventory))
            else
                Log("RPPlayerDB.inventory is nil!")
            end
        else
            Log("RPPlayerDB is nil!")
        end

        -- Ensure inventory table exists
        RPPlayerDB.inventory = RPPlayerDB.inventory or {}
        Log("After safety check, inventory count: " .. table.getn(RPPlayerDB.inventory))

        -- Add welcome item if inventory is empty (first time use)
        if table.getn(RPPlayerDB.inventory) == 0 then
            Log("Inventory is empty, creating welcome letter")
            local welcomeItem = {
                id = 0,
                name = "Welcome notice",
                icon = "Interface\\Icons\\INV_Misc_Note_01",
                tooltip = "Welcome to RP Player",
                content = "Welcome to RP Player, this addon gives you access to custom objects for RP events",
                guid = "system-welcome-0"
            }
            table.insert(RPPlayerDB.inventory, welcomeItem)
            Log("Welcome letter inserted, new count: " .. table.getn(RPPlayerDB.inventory))
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Welcome letter added to inventory", 0, 1, 0)
        else
            Log("Inventory not empty, count: " .. table.getn(RPPlayerDB.inventory))
        end

        -- Refresh bag display after initialization
        Log("Calling RPPlayer_RefreshBag()")
        RPPlayer_RefreshBag()
        Log("RPPlayer_RefreshBag() completed")

        -- Unregister this event since we only need to run once per session
        eventFrame:UnregisterEvent("PLAYER_LOGIN")
        Log("PLAYER_LOGIN event unregistered")
    end
end)

-- Function: Reset frame positions to default
function RPPlayer_ResetPositions()
    RPPlayerDB.bagFramePos = nil
    RPPlayerDB.readFramePos = nil

    -- Reset bag frame
    RPBagFrame:ClearAllPoints()
    RPBagFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

    -- Reset read frame
    readFrame:ClearAllPoints()
    readFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Frame positions reset to default", 0, 1, 0)
end

-- Debug log viewer frame
local logFrame = CreateFrame("Frame", "RPPlayerLogFrame", UIParent)
logFrame:SetWidth(600)
logFrame:SetHeight(400)
logFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
logFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
logFrame:SetBackdropColor(0, 0, 0, 1)
logFrame:SetMovable(true)
logFrame:EnableMouse(true)
logFrame:SetFrameStrata("DIALOG")
logFrame:Hide()

local logTitle = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
logTitle:SetPoint("TOP", 0, -15)
logTitle:SetText("RPPlayer Debug Log")

-- Draggable
local logTitleBar = CreateFrame("Frame", nil, logFrame)
logTitleBar:SetPoint("TOPLEFT", 10, -10)
logTitleBar:SetPoint("TOPRIGHT", -30, -10)
logTitleBar:SetHeight(30)
logTitleBar:EnableMouse(true)
logTitleBar:RegisterForDrag("LeftButton")
logTitleBar:SetScript("OnDragStart", function() logFrame:StartMoving() end)
logTitleBar:SetScript("OnDragStop", function() logFrame:StopMovingOrSizing() end)

local logCloseBtn = CreateFrame("Button", nil, logFrame, "UIPanelCloseButton")
logCloseBtn:SetPoint("TOPRIGHT", -5, -5)

-- Scrollable log area with EditBox for copy/paste
local logScrollFrame = CreateFrame("ScrollFrame", "RPPlayerLogScrollFrame", logFrame, "UIPanelScrollFrameTemplate")
logScrollFrame:SetPoint("TOPLEFT", 20, -50)
logScrollFrame:SetPoint("BOTTOMRIGHT", -40, 50)

local logEditBox = CreateFrame("EditBox", nil, logScrollFrame)
logEditBox:SetWidth(520)
logEditBox:SetHeight(1)
logEditBox:SetMultiLine(true)
logEditBox:SetAutoFocus(false)
logEditBox:SetFontObject(GameFontNormalSmall)
logEditBox:SetTextColor(1, 1, 1, 1)
logEditBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)

logScrollFrame:SetScrollChild(logEditBox)

-- Clear button
local clearBtn = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
clearBtn:SetWidth(80)
clearBtn:SetHeight(22)
clearBtn:SetPoint("BOTTOM", logFrame, "BOTTOM", 0, 15)
clearBtn:SetText("Clear Log")
clearBtn:SetScript("OnClick", function()
    RPPlayerDebugLog = {}
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Debug log cleared")
    logFrame:Hide()
end)

-- Function to show log viewer
function RPPlayer_ShowLog()
    if table.getn(RPPlayerDebugLog) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[RP Player]|r Debug log is empty")
        return
    end

    local logContent = table.concat(RPPlayerDebugLog, "\n")
    logEditBox:SetText(logContent)
    logEditBox:HighlightText()

    -- Calculate height needed for all text
    local numLines = table.getn(RPPlayerDebugLog)
    local lineHeight = 14 -- approximate height per line
    local totalHeight = numLines * lineHeight + 20
    logEditBox:SetHeight(totalHeight)

    logFrame:Show()
    logEditBox:SetFocus()
end

-- Slash command
SLASH_RPPLAYER1 = "/rpplayer"
SlashCmdList["RPPLAYER"] = function(msg)
    -- Handle log command
    if msg == "log" then
        RPPlayer_ShowLog()
        return
    end

    -- Handle clearlog command
    if msg == "clearlog" then
        RPPlayerDebugLog = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Debug log cleared")
        return
    end

    -- Handle reset command
    if msg == "reset" then
        RPPlayer_ResetPositions()
        return
    end

    -- Toggle bag
    if RPBagFrame:IsShown() then
        RPBagFrame:Hide()
    else
        Log("Opening bag via slash command")
        RPBagFrame:Show()
        RPPlayer_RefreshBag()
    end
end
