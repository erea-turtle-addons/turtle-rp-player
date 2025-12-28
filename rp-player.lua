-- ============================================================================
-- RPPlayer.lua - Player Addon for RP Item Inventory
-- ============================================================================
-- PURPOSE: Provides a personal RP inventory system for players
--          Receives items from GMs, trades with other players, shows items
--
-- FEATURES:
--   - 16-slot bag for RP items (separate from regular inventory)
--   - Receive items from GMs (GIVE messages) with accept/decline popup
--   - Trade items to other players (TRADE messages) with confirmation
--   - Show items to others for preview (SHOW messages) without transfer
--   - Drag-drop reorganization (swap slots)
--   - Drag-drop to player portraits (quick trade/show)
--   - Right-click context menu (Read/Show/Give/Delete)
--   - Range detection (only show nearby raid/party members)
--   - Position persistence (remembers window locations)
--   - Debug logging system
--
-- ARCHITECTURE:
--   - Monolithic file (not modular like RPMaster)
--   - Creates 2 main windows: Bag frame + Read frame
--   - Listens for addon messages via CHAT_MSG_ADDON event
--   - Uses Base64 encoding for safe message transmission
--
-- COMMUNICATION:
--   - Receives: GIVE, TRADE, SHOW (from GMs or players)
--   - Sends: GIVE_ACCEPT, GIVE_REJECT, TRADE_ACCEPT, TRADE_REJECT, SHOW_REJECT
--   - Distribution: RAID, PARTY, or WHISPER (auto-selected)
--   - Delimiter: ^ (caret) instead of | (pipe) to avoid WoW escape sequence conflicts
--
-- DATA PERSISTENCE:
--   - RPPlayerDB (SavedVariablesPerCharacter) stores inventory per character
--   - RPPlayerDebugLog (SavedVariablesPerCharacter) stores debug logs
--
-- LUA 5.0 NOTES:
--   - Use table.getn(t) instead of #t
--   - Use string.gfind instead of string.gmatch
--   - Use math.mod instead of % for modulo
--   - Global event variables: event, arg1, arg2, arg3, etc.
-- ============================================================================

-- ============================================================================
-- IMPORTS - Business logic from turtle-rp-common
-- ============================================================================
local objectDatabase = RequireObjectDatabase()
local rpBusiness = RequireRPBusiness()
local inventory = RequireInventory()
local encoding = RequireEncoding()
local messaging = RequireMessaging()
local rpActions = RequireRPActions()
local playerActions = RequirePlayerActions()

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local ADDON_NAME = "RPPlayer"
local ADDON_PREFIX = messaging.ADDON_PREFIX  -- Use constant from messaging module
-- Version info loaded from version.lua (loaded first in .toc)
-- Show version tag unless it's the default "0.0.0", then show build time
local ADDON_VERSION = (RP_VERSION_TAG and RP_VERSION_TAG ~= "0.0.0") and RP_VERSION_TAG or (RP_BUILD_TIME or "unknown")
local MAX_SLOTS = inventory.MAX_INVENTORY_SLOTS  -- Use constant from inventory module

-- NOTE: RegisterAddonMessagePrefix() doesn't exist in WoW 1.12
-- Addon messages work without explicit registration in Vanilla WoW

-- ============================================================================
-- GLOBAL PENDING STATE VARIABLES
-- ============================================================================
-- These MUST be global (not local) because WoW's StaticPopup system can't
-- access local variables from callback functions (Lua 5.0 limitation)
--
-- PATTERN: Store pending operation data globally, clear after completion
-- SIMILAR TO: Static/singleton pattern for temporary state
-- ============================================================================

-- GIVE request state (from GM)
RPPlayer_PendingGiveItem = nil      -- Item instance being offered (v0.2.1: instance data only)
RPPlayer_PendingGiveObjectDef = nil -- Object definition (for display during popup)
RPPlayer_PendingGiveSender = nil    -- GM who sent it
RPPlayer_PendingGiveMessage = nil   -- Custom message from GM

-- TRADE request state (from another player)
RPPlayer_PendingTradeItem = nil     -- Item instance being offered (v0.2.1: instance data only)
RPPlayer_PendingTradeObjectDef = nil-- Object definition (for display during popup)
RPPlayer_PendingTradeSender = nil   -- Player who sent it

-- Outgoing TRADE state (waiting for recipient to accept)
RPPlayer_PendingOutgoingTrade = nil -- Item we're giving away

-- Chunked database sync state (for receiving multi-part DB_SYNC messages)
RPPlayer_ChunkedSyncs = RPPlayer_ChunkedSyncs or {}  -- {messageId -> {metadata, chunks, totalChunks}}

-- NOTE: Two-part message assembly removed - new GUID-based protocol doesn't need it

-- ============================================================================
-- DEBUG LOGGING SYSTEM
-- ============================================================================
-- Global SavedVariable (persisted per character)
-- Pattern: RPPlayerDebugLog = RPPlayerDebugLog or {}
--   If RPPlayerDebugLog exists (loaded from SavedVariables), keep it
--   Otherwise initialize as empty table
-- ============================================================================
RPPlayerDebugLog = RPPlayerDebugLog or {}

-- Log() - Internal logging function (circular buffer, max 500 entries)
local function Log(message)
    local timestamp = date("%H:%M:%S")
    local logEntry = string.format("[%s] RPPlayer: %s", timestamp, tostring(message))
    table.insert(RPPlayerDebugLog, logEntry)
    -- Keep only last 500 entries to prevent bloat
    if table.getn(RPPlayerDebugLog) > 500 then
        table.remove(RPPlayerDebugLog, 1)
    end
end

-- Base64 encode/decode moved to turtle-rp-common/rp-business.lua
-- Use encoding.Base64Encode() and encoding.Base64Decode()

-- GetDistribution, CleanupOldPartialMessages, SendTwoPartMessage moved to rp-business.lua
-- Use rpBusiness.GetDistribution() and rpBusiness.CreateGiveMessage() etc.

-- ============================================================================
-- SAVED VARIABLES INITIALIZATION (Per-Character Database)
-- ============================================================================
-- RPPlayerDB is a SavedVariablesPerCharacter (persisted to disk per character)
-- Declared in .toc file: ## SavedVariablesPerCharacter: RPPlayerDB
--
-- PATTERN: RPPlayerDB = RPPlayerDB or { default structure }
--   - If RPPlayerDB exists (loaded from SavedVariables), keep it
--   - Otherwise initialize with default structure (first time use)
--
-- STRUCTURE:
--   - inventory: Array of item objects
--   - bagFramePos: Window position [point, relativePoint, x, y]
--   - readFramePos: Window position [point, relativePoint, x, y]
--   - syncedDatabaseId: ID of currently synced Master database (e.g., "1234567890-5432")
--   - syncedDatabaseName: Name of currently synced database (e.g., "Dragon Campaign")
--   - syncedDatabaseVersion: Version timestamp of synced database (for tracking updates)
--   - databases: Array of available databases from different Masters
--
-- DATABASE SYNC DESIGN:
--   - Player can receive items from multiple RPMasters (different database IDs)
--   - Only one database is "active" at a time (shown in UI)
--   - Future: May track multiple databases separately per Master
--
-- DEFAULT ITEM:
--   - First-time users get a welcome letter with user instructions
--   - guid = "system-welcome-0" prevents duplicates
--
-- SIMILAR TO: localStorage in JavaScript, SharedPreferences in Android
-- ============================================================================
Log("RPPlayer.lua file loading...")
RPPlayerDB = RPPlayerDB or {
    inventory = {
        {
            id = 0,  -- System item (not from GM)
            name = "Welcome to RP Player",
            icon = "Interface\\Icons\\INV_Misc_Note_01",
            tooltip = "Quick start guide",
            content = "RP PLAYER GUIDE\n\n" ..
                "Left-click items to read. Right-click for options.\n\n" ..
                "Drag items to player portraits to give or show.\n\n" ..
                "Use /rpplayer to open bag.",
            guid = "system-welcome-0"
        }
    },
    bagFramePos = nil,
    readFramePos = nil,
    -- NEW: Stores entire GM database locally for GUID lookup
    syncedDatabase = nil,         -- Full database {items: [...], metadata: {...}}
    syncState = {                 -- Sync status tracking
        databaseId = nil,
        databaseName = nil,
        version = nil,
        checksum = nil,
        lastSyncTime = nil
    }
}
Log("RPPlayerDB initialized, inventory count: " .. table.getn(RPPlayerDB.inventory))

-- ============================================================================
-- ENSURE DATABASE FIELDS EXIST (for existing saved variables)
-- ============================================================================
-- Migrate old SavedVariables structure to new GUID-based protocol structure
-- ============================================================================
if not RPPlayerDB.syncedDatabase then
    RPPlayerDB.syncedDatabase = nil
    Log("Added syncedDatabase field to RPPlayerDB")
end
if not RPPlayerDB.syncState then
    RPPlayerDB.syncState = {
        databaseId = nil,
        databaseName = nil,
        version = nil,
        checksum = nil,
        lastSyncTime = nil
    }
    Log("Added syncState field to RPPlayerDB")
end

-- Backward compatibility: migrate old fields to new structure if they exist
if RPPlayerDB.syncedDatabaseId or RPPlayerDB.syncedDatabaseName or RPPlayerDB.syncedDatabaseVersion then
    if not RPPlayerDB.syncState.databaseId then
        RPPlayerDB.syncState.databaseId = RPPlayerDB.syncedDatabaseId
        RPPlayerDB.syncState.databaseName = RPPlayerDB.syncedDatabaseName
        RPPlayerDB.syncState.version = RPPlayerDB.syncedDatabaseVersion
        Log("Migrated old database sync fields to new syncState structure")
    end
    -- Clean up old fields
    RPPlayerDB.syncedDatabaseId = nil
    RPPlayerDB.syncedDatabaseName = nil
    RPPlayerDB.syncedDatabaseVersion = nil
    RPPlayerDB.databases = nil
end

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

-- ========================================================================
-- DATABASE NAME DISPLAY (shows which Master database is synced)
-- ========================================================================
-- PURPOSE: Display the name of the synced database from RPMaster
-- EXAMPLE: "Database: Dragon Campaign"
-- BEHAVIOR:
--   - Shows "None" if no database synced yet
--   - Updates when database sync received from Master
--   - For information only (player cannot edit)
-- ========================================================================
local dbLabel = RPBagFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
dbLabel:SetPoint("TOP", 0, -30)
dbLabel:SetTextColor(0.7, 0.7, 0.7)  -- Grey text

-- Function to update database label
function RPBagFrame_UpdateDatabaseLabel()
    if RPPlayerDB and RPPlayerDB.syncState and RPPlayerDB.syncState.databaseName and RPPlayerDB.syncState.databaseName ~= "" then
        dbLabel:SetText("Database: " .. RPPlayerDB.syncState.databaseName)
        dbLabel:SetTextColor(0, 1, 0)  -- Green = synced
    else
        dbLabel:SetText("Database: None")
        dbLabel:SetTextColor(1, 0.5, 0)  -- Orange = not synced
    end
end

-- Set initial text
RPBagFrame_UpdateDatabaseLabel()

-- Store reference for later updates
RPBagFrame.dbLabel = dbLabel

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

    -- Counter text (like WoW's item count display)
    local count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -2, 2)
    count:SetJustifyH("RIGHT")
    count:Hide()

    slot.icon = icon
    slot.count = count
    slot.item = nil
    itemSlots[i] = slot
end

-- Item reading frame (for letters/documents)
local readFrame = CreateFrame("Frame", "RPReadFrame", UIParent)
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

-- Pending drag-to-player action
RPPlayer_PendingDragItem = nil
RPPlayer_PendingDragTarget = nil

-- Drag source for reorganization
local dragSourceSlot = nil

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

-- Helper function: Find next available slot
-- FindNextAvailableSlot and GetItemAtSlot moved to rp-business.lua
-- Use inventory.FindNextAvailableSlot(RPPlayerDB.inventory)
-- Use inventory.GetItemAtSlot(RPPlayerDB.inventory, slotIndex)

-- Function: Start drag
local function StartDrag(item, sourceSlot)
    draggedItem = item
    dragSourceSlot = sourceSlot
    local frame = CreateDragFrame()
    frame.icon:SetTexture(item.icon)
    frame:Show()
    Log("Started dragging item: " .. item.name .. " from slot " .. sourceSlot)
end

-- Function: Stop drag
local function StopDrag(targetSlot)
    if dragFrame then
        dragFrame:Hide()
    end

    -- Check if hovering over another player
    if draggedItem and UnitExists("mouseover") and UnitIsPlayer("mouseover") then
        local targetName = UnitName("mouseover")
        if targetName and targetName ~= UnitName("player") then
            -- Store pending drag action
            RPPlayer_PendingDragItem = draggedItem
            RPPlayer_PendingDragTarget = targetName

            -- Show confirmation dialog
            StaticPopup_Show("RPPLAYER_DRAG_TO_PLAYER", draggedItem.name, targetName)

            -- Clear drag state
            draggedItem = nil
            dragSourceSlot = nil
            return
        end
    end

    -- If we have a target slot (dropped within bag), reorganize
    if draggedItem and dragSourceSlot and targetSlot then
        Log("Dropped item in slot " .. targetSlot)

        -- Swap items between source and target slots
        local sourceItem = inventory.GetItemAtSlot(RPPlayerDB.inventory, dragSourceSlot)
        local targetItem = inventory.GetItemAtSlot(RPPlayerDB.inventory, targetSlot)

        if sourceItem then
            sourceItem.slot = targetSlot
        end
        if targetItem then
            targetItem.slot = dragSourceSlot
        end

        RPPlayer_RefreshBag()
    end

    -- Clear drag state
    draggedItem = nil
    dragSourceSlot = nil
end

-- Function: Show item to a specific player
-- silent: if true, don't show feedback message (used when showing to "All")
function RPPlayer_ShowItem(item, targetName, silent)
    if not targetName then
        Log("ERROR: ShowItem called without targetName")
        return
    end

    Log("ShowItem called - Item: " .. tostring(item.name) .. ", Target: " .. tostring(targetName))

    -- Send message (messaging.lua handles creation + distribution + sending)
    -- Pass full item for player-to-player (receiver doesn't have sender's inventory)
    local success = messaging.SendShowMessage(targetName, item)

    if not success then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Failed to send show message!", 1, 0, 0)
        Log("ERROR: Failed to send SHOW message")
        return
    end

    Log("SHOW message sent for item: " .. item.name)

    -- Display feedback to user (unless silent for batch operations)
    if not silent then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FFFF[RP Player]|r Offering to show '%s' to %s (waiting for response)...", item.name, targetName), 0, 1, 1)
    end
end

-- Function: Delete item
function RPPlayer_DeleteItem(item)
    Log("DeleteItem called - Item: " .. tostring(item.name) .. ", Slot: " .. tostring(item.slot))

    -- Remove from inventory by slot (unique identifier for item instances)
    for i, invItem in ipairs(RPPlayerDB.inventory) do
        if invItem.slot == item.slot then
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

    -- Send message (messaging.lua handles creation + distribution + sending)
    -- Pass full item for player-to-player (receiver doesn't have sender's inventory)
    local success = messaging.SendTradeMessage(targetName, item)

    if not success then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Failed to send trade message!", 1, 0, 0)
        Log("ERROR: Failed to send TRADE message")
        return
    end

    Log("TRADE message sent for item: " .. item.name)

    -- Store pending trade (will be removed on acceptance)
    RPPlayer_PendingOutgoingTrade = item

    -- Display feedback to user
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r Offering '%s' to %s (waiting for response)...", item.name, targetName), 0, 1, 0)
end

-- Function: Read item
-- Optional shownBy parameter indicates who showed you this item
function RPPlayer_ReadItem(item, shownBy)
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

    -- Set content text (business logic delegated to objectDatabase.RenderItemContent)
    local displayContent = objectDatabase.RenderItemContent(
        item.guid,
        item.customText,
        RPPlayerDB.syncedDatabase
    )
    readText:SetText(displayContent)

    local textHeight = readText:GetHeight()
    if textHeight and textHeight > 0 then
        readScrollChild:SetHeight(textHeight)
    else
        -- Fallback to a reasonable default
        readScrollChild:SetHeight(400)
    end

    readFrame:Show()
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

-- ============================================================================
-- HasAvailableActions - Check if item has any actions that pass conditions
-- ============================================================================
-- @param item: Table - Item object (instance with guid, customText, customNumber)
-- @return boolean - true if item has at least one available action
-- ============================================================================
local function HasAvailableActions(item)
    if not item.actions or table.getn(item.actions) == 0 then
        return false
    end

    -- Check each action's conditions
    for i = 1, table.getn(item.actions) do
        local action = item.actions[i]
        local isAvailable = true

        if action.conditions then
            -- Check customTextEmpty condition
            if action.conditions.customTextEmpty then
                local customText = item.customText or ""
                if customText ~= "" then
                    isAvailable = false
                end
            end

            -- Check counterGreaterThanZero condition
            if action.conditions.counterGreaterThanZero and isAvailable then
                local customNumber = item.customNumber or 0
                if customNumber <= 0 then
                    isAvailable = false
                end
            end
        end

        -- If this action is available, return true
        if isAvailable then
            return true
        end
    end

    -- No available actions found
    return false
end

-- ============================================================================
-- IsItemReadable - Check if item has readable content
-- ============================================================================
-- @param item: Table - Item object (instance with content, customText, contentTemplate)
-- @return boolean - true if item has content to read
-- ============================================================================
local function IsItemReadable(item)
    -- Has regular content
    if item.content and item.content ~= "" then
        return true
    end

    -- Has custom template + custom text
    if item.contentTemplate and item.contentTemplate ~= "" and
       item.customText and item.customText ~= "" then
        return true
    end

    return false
end

-- Function: Show context menu for item
-- Function: Execute an action on an item
-- ============================================================================
-- ============================================================================
-- RPPlayer_ExecuteAction - Execute action (delegates to player-actions.lua)
-- ============================================================================
-- @param item: Table - Item object
-- @param action: Table - Action object
--
-- NOTE: All action GUI logic moved to player-actions.lua for separation of concerns
-- ============================================================================
function RPPlayer_ExecuteAction(item, action)
    playerActions.ExecuteAction(item, action)
end

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
            -- Actions first (always show if item has actions, grey out unavailable ones)
            if RPPlayerContextMenuFrame.contextItem.actions and table.getn(RPPlayerContextMenuFrame.contextItem.actions) > 0 then
                -- Add each action (v0.2.1: check conditions, grey out if unavailable)
                for i = 1, table.getn(RPPlayerContextMenuFrame.contextItem.actions) do
                    local action = RPPlayerContextMenuFrame.contextItem.actions[i]

                    -- Check conditions (v0.2.1)
                    local isAvailable = true
                    if action.conditions then
                        -- Check customTextEmpty condition
                        if action.conditions.customTextEmpty then
                            local customText = RPPlayerContextMenuFrame.contextItem.customText or ""
                            if customText ~= "" then
                                isAvailable = false  -- Custom text not empty, action unavailable
                            end
                        end

                        -- Check counterGreaterThanZero condition
                        if action.conditions.counterGreaterThanZero and isAvailable then
                            local customNumber = RPPlayerContextMenuFrame.contextItem.customNumber or 0
                            if customNumber <= 0 then
                                isAvailable = false  -- Counter not > 0, action unavailable
                            end
                        end
                    end

                    -- Always add action, but grey out if unavailable
                    local actionCopy = action
                    UIDropDownMenu_AddButton({
                        text = actionCopy.label,
                        func = isAvailable and function()
                            RPPlayer_ExecuteAction(RPPlayerContextMenuFrame.contextItem, actionCopy)
                        end or nil,
                        disabled = not isAvailable and 1 or nil,
                        notCheckable = 1
                    })
                end

                -- Add separator after actions
                UIDropDownMenu_AddButton({
                    text = "----------",
                    disabled = 1,
                    notCheckable = 1
                })
            end

            -- Read option (if item has readable content or custom template + text)
            if IsItemReadable(RPPlayerContextMenuFrame.contextItem) then
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
                    local playerNames = {}
                    for _, playerName in ipairs(RPPlayerContextMenuFrame.raidMembers) do
                        RPPlayer_ShowItem(item, playerName, true)  -- silent = true to suppress individual messages
                        table.insert(playerNames, playerName)
                    end
                    if table.getn(playerNames) > 0 then
                        local namesList = table.concat(playerNames, ", ")
                        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FFFF[RP Player]|r Offering to show '%s' to: %s (waiting for responses)...", item.name, namesList), 0, 1, 1)
                    else
                        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FFFF[RP Player]|r No nearby players to show '%s'", item.name), 0, 1, 1)
                    end
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

-- ============================================================================
-- REQUEST_INPUT Dialog moved to player-actions.lua
-- ============================================================================
-- All action-related dialogs and GUI logic now in player-actions.lua

-- ============================================================================
-- MODIFY_CONTENT Dialog (Legacy) - May be removed in future
-- ============================================================================
StaticPopupDialogs["RPPLAYER_MODIFY_CONTENT"] = {
    text = "Modify '%s':\n\n",
    button1 = "Save",
    button2 = "Cancel",
    hasEditBox = 1,
    maxLetters = 500,
    OnAccept = function()
        local newContent = getglobal(this:GetParent():GetName().."EditBox"):GetText()
        if not newContent or newContent == "" then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Content cannot be empty!", 1, 0, 0)
            return
        end

        -- Get item and action from dialog data
        local data = getglobal(this:GetParent():GetName()).data
        if not data or not data.item or not data.action then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Error: Dialog data missing!", 1, 0, 0)
            return
        end

        -- Execute ModifyContent action with new content
        local playerName = UnitName("player")
        local result = rpActions.ExecuteAction(playerName, data.item, data.action.id, {newContent = newContent})

        if result.result == rpActions.ACTION_RESULTS.SUCCESS then
            -- Update item content in inventory by slot (unique identifier)
            for i, invItem in ipairs(RPPlayerDB.inventory) do
                if invItem.slot == data.item.slot then
                    invItem.content = newContent
                    break
                end
            end

            RPPlayer_RefreshBag()
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Content modified: " .. data.item.name, 0, 1, 0)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Failed to modify content: " .. tostring(result.message), 1, 0, 0)
        end
    end,
    OnShow = function()
        -- Pre-fill with current content
        local data = getglobal(this:GetName()).data
        if data and data.item and data.item.content then
            getglobal(this:GetName().."EditBox"):SetText(data.item.content)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true
}

-- Static popup for show item request
StaticPopupDialogs["RPPLAYER_SHOW_REQUEST"] = {
    text = "\n|cFF00FFFF%s wants to show you %s\n\n",
    button1 = "Look",
    button2 = "Ignore",
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
            messaging.SendShowRejectMessage(RPPlayer_PendingShowSender, myName, RPPlayer_PendingShowItem.name)
            Log("Sent SHOW_REJECT to " .. RPPlayer_PendingShowSender)
        end
        RPPlayer_PendingShowItem = nil
        RPPlayer_PendingShowSender = nil
    end,
    timeout = 20,
    whileDead = true,
    hideOnEscape = true
}

-- GIVE Request Popup (from GM) - Player finds an item
StaticPopupDialogs["RPPLAYER_GIVE_REQUEST"] = {
    text = "\n|cFFFFD700%s|r\n",
    button1 = "Take it",
    button2 = "Leave it",
    OnAccept = function()
        if RPPlayer_PendingGiveItem and RPPlayer_PendingGiveObjectDef then
            -- Add instance to inventory (v0.2.1: instance data only)
            table.insert(RPPlayerDB.inventory, RPPlayer_PendingGiveItem)
            RPPlayer_RefreshBag()

            -- Send acceptance message
            local myName = UnitName("player")
            messaging.SendGiveAcceptMessage(RPPlayer_PendingGiveSender, myName, RPPlayer_PendingGiveObjectDef.name)
            Log("Sent GIVE_ACCEPT to " .. RPPlayer_PendingGiveSender)

            -- Display message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r You accepted '%s' from %s", RPPlayer_PendingGiveObjectDef.name, RPPlayer_PendingGiveSender), 0, 1, 0)

            -- Clear pending
            RPPlayer_PendingGiveItem = nil
            RPPlayer_PendingGiveObjectDef = nil
            RPPlayer_PendingGiveSender = nil
            RPPlayer_PendingGiveMessage = nil
        end
    end,
    OnCancel = function()
        if RPPlayer_PendingGiveSender and RPPlayer_PendingGiveObjectDef then
            -- Send rejection message
            local myName = UnitName("player")
            messaging.SendGiveRejectMessage(RPPlayer_PendingGiveSender, myName, RPPlayer_PendingGiveObjectDef.name)
            Log("Sent GIVE_REJECT to " .. RPPlayer_PendingGiveSender)

            -- Display message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r You declined '%s' from %s", RPPlayer_PendingGiveObjectDef.name, RPPlayer_PendingGiveSender), 1, 0, 0)
        end

        -- Clear pending
        RPPlayer_PendingGiveItem = nil
        RPPlayer_PendingGiveObjectDef = nil
        RPPlayer_PendingGiveSender = nil
        RPPlayer_PendingGiveMessage = nil
    end,
    timeout = 30,
    whileDead = true,
    hideOnEscape = true
}

-- TRADE Request Popup (from other players)
StaticPopupDialogs["RPPLAYER_TRADE_REQUEST"] = {
    text = "\n|cFF00FF00%s wants to give you %s\n\n",
    button1 = "Accept",
    button2 = "Decline",
    OnAccept = function()
        if RPPlayer_PendingTradeItem and RPPlayer_PendingTradeObjectDef then
            -- Add instance to inventory (v0.2.1: instance data only)
            table.insert(RPPlayerDB.inventory, RPPlayer_PendingTradeItem)
            RPPlayer_RefreshBag()

            -- Send acceptance message
            local myName = UnitName("player")
            messaging.SendTradeAcceptMessage(RPPlayer_PendingTradeSender, myName, RPPlayer_PendingTradeObjectDef.name)
            Log("Sent TRADE_ACCEPT to " .. RPPlayer_PendingTradeSender)

            -- Display message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r You accepted '%s' from %s", RPPlayer_PendingTradeObjectDef.name, RPPlayer_PendingTradeSender), 0, 1, 0)

            -- Clear pending
            RPPlayer_PendingTradeItem = nil
            RPPlayer_PendingTradeObjectDef = nil
            RPPlayer_PendingTradeSender = nil
        end
    end,
    OnCancel = function()
        if RPPlayer_PendingTradeSender and RPPlayer_PendingTradeObjectDef then
            -- Send rejection message
            local myName = UnitName("player")
            messaging.SendTradeRejectMessage(RPPlayer_PendingTradeSender, myName, RPPlayer_PendingTradeObjectDef.name)
            Log("Sent TRADE_REJECT to " .. RPPlayer_PendingTradeSender)

            -- Display message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r You declined '%s' from %s", RPPlayer_PendingTradeObjectDef.name, RPPlayer_PendingTradeSender), 1, 0, 0)
        end

        -- Clear pending
        RPPlayer_PendingTradeItem = nil
        RPPlayer_PendingTradeObjectDef = nil
        RPPlayer_PendingTradeSender = nil
    end,
    timeout = 30,
    whileDead = true,
    hideOnEscape = true
}

-- Drag-to-player confirmation dialog
StaticPopupDialogs["RPPLAYER_DRAG_TO_PLAYER"] = {
    text = "\n|cFFFFFFFF%s to %s:\n\n",
    button1 = "Give",
    button2 = "Show",
    OnAccept = function()
        if RPPlayer_PendingDragItem and RPPlayer_PendingDragTarget then
            -- Give (trade) the item
            RPPlayer_TradeItem(RPPlayer_PendingDragItem, RPPlayer_PendingDragTarget)

            -- Clear pending
            RPPlayer_PendingDragItem = nil
            RPPlayer_PendingDragTarget = nil
        end
    end,
    OnShow = function()
        -- Override button2's click handler to trigger Show action
        -- In WoW 1.12, button2 normally triggers OnCancel, so we need custom handling
        local dialog = this
        local button2 = getglobal(dialog:GetName().."Button2")
        if button2 then
            button2:SetScript("OnClick", function()
                -- Show action
                if RPPlayer_PendingDragItem and RPPlayer_PendingDragTarget then
                    RPPlayer_ShowItem(RPPlayer_PendingDragItem, RPPlayer_PendingDragTarget)

                    -- Clear pending
                    RPPlayer_PendingDragItem = nil
                    RPPlayer_PendingDragTarget = nil
                end

                -- Hide dialog
                dialog:Hide()
            end)
        end
    end,
    OnCancel = function()
        -- ESC pressed or X clicked - cancel action (do nothing, item stays)
        RPPlayer_PendingDragItem = nil
        RPPlayer_PendingDragTarget = nil
    end,
    OnHide = function()
        -- Final cleanup when dialog closes
        RPPlayer_PendingDragItem = nil
        RPPlayer_PendingDragTarget = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true
}

-- ============================================================================
-- RPPlayer_RefreshBag() - Rebuild entire bag UI from inventory data
-- ============================================================================
-- @returns: void
--
-- CALLED:
--   - After adding/removing items
--   - After slot reorganization (drag-drop)
--   - On PLAYER_LOGIN (initial display)
--   - When opening bag via /rpplayer command
--
-- PROCESS:
--   1. Auto-assign slots to items that don't have one
--   2. Clear all slot visuals and event handlers
--   3. Rebuild each slot with current item
--   4. Attach event handlers (tooltip, clicks, drag-drop)
--
-- SLOT ASSIGNMENT:
--   - Items have optional 'slot' field (1-16)
--   - Items without slot get auto-assigned to first available
--   - Allows items to remember position after reorganization
--
-- PATTERN: Similar to React's render() - rebuilds entire UI from state
-- ============================================================================
function RPPlayer_RefreshBag()
    Log("RefreshBag called, inventory count: " .. table.getn(RPPlayerDB.inventory))

    -- STEP 1: Auto-assign slots to items that don't have them
    -- (New items don't have slot field yet)
    -- v0.2.1: inventory contains instances (guid only), not full items
    for _, instance in ipairs(RPPlayerDB.inventory) do
        if not instance.slot then
            local nextSlot = inventory.FindNextAvailableSlot(RPPlayerDB.inventory)
            if nextSlot then
                instance.slot = nextSlot
                Log("Auto-assigned slot " .. nextSlot .. " to instance: " .. tostring(instance.guid))
            else
                Log("ERROR: No available slots for instance: " .. tostring(instance.guid))
            end
        end
    end

    -- Clear all slot visuals and scripts
    for i = 1, MAX_SLOTS do
        local slot = itemSlots[i]
        slot.icon:Hide()
        slot.count:Hide()
        slot.item = nil

        -- Clear scripts
        slot:SetScript("OnEnter", nil)
        slot:SetScript("OnLeave", nil)
        slot:SetScript("OnClick", nil)
        slot:SetScript("OnMouseDown", nil)
        slot:SetScript("OnMouseUp", nil)
        slot:SetScript("OnDragStart", nil)
        slot:SetScript("OnDragStop", nil)
        slot:SetScript("OnReceiveDrag", nil)
        slot:EnableMouse(true)  -- Keep mouse enabled for empty slots
    end
    Log("All slots cleared")

    -- Place items in their assigned slots
    for _, instance in ipairs(RPPlayerDB.inventory) do
        if instance.slot and instance.slot <= MAX_SLOTS then
            local slotIndex = instance.slot
            local slot = itemSlots[slotIndex]

            -- v0.2.1: Merge instance + definition (or use full item for system items)
            local item = nil
            if instance.name then
                -- Old format or system item (has full data already)
                item = instance
            else
                -- New format: instance data only, lookup definition
                item = inventory.GetFullItem(instance, RPPlayerDB.syncedDatabase)
            end

            -- Skip if object not found in database
            if item then
                Log("Placing item '" .. item.name .. "' in slot " .. slotIndex)
            slot.item = item
            slot.icon:SetTexture(item.icon)
            slot.icon:Show()

            -- Show counter if customNumber > 0
            if item.customNumber and item.customNumber > 0 then
                slot.count:SetText(tostring(item.customNumber))
                slot.count:Show()
            else
                slot.count:Hide()
            end

            -- Create closure-safe local references
            local currentItem = item
            local currentSlotIndex = slotIndex
            local currentSlotName = slot.slotName

            -- Tooltip
            slot:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                GameTooltip:ClearLines()

                -- Object name always in white
                GameTooltip:AddLine(currentItem.name, 1, 1, 1)  -- White

                if currentItem.tooltip and currentItem.tooltip ~= "" then
                    GameTooltip:AddLine(currentItem.tooltip, 1, 0.82, 0, 1)
                end

                -- Show "Actions available" only if item has available actions (after condition checks)
                if HasAvailableActions(currentItem) then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Actions available", 0.4, 0.6, 1)  -- Blue
                end

                -- Show "Customized" if customText present
                if currentItem.customText and currentItem.customText ~= "" then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Customized", 0.8, 0.4, 1)  -- Purple
                end

                -- Show custom number if > 0 (v0.1.1)
                if currentItem.customNumber and currentItem.customNumber > 0 then
                    GameTooltip:AddLine("Charges: " .. currentItem.customNumber, 1, 1, 1)
                end

                GameTooltip:AddLine(" ")
                if currentItem.content and currentItem.content ~= "" then
                    GameTooltip:AddLine("Left-click to read", 0, 1, 0)
                end
                GameTooltip:AddLine("Right-click for options", 0, 1, 0)
                GameTooltip:ClearAllPoints()
                GameTooltip:SetPoint("BOTTOMRIGHT", currentSlotName, "TOPLEFT", 10, -10)
                GameTooltip:Show()
            end)

            slot:SetScript("OnLeave", function()
                GameTooltip:Hide()
                GameTooltip:ClearAllPoints()
            end)

            -- Left click: Read item (if has content)
            -- Right click: Show context menu
            slot:SetScript("OnClick", function(self, button)
                local clickButton = button or arg1

                if clickButton == "LeftButton" then
                    -- Read item if it has content
                    if currentItem.content and currentItem.content ~= "" then
                        Log("Left click detected, reading item")
                        RPPlayer_ReadItem(currentItem)
                    else
                        Log("Left click ignored - item has no content")
                    end
                elseif clickButton == "RightButton" then
                    Log("Right click detected, showing menu")
                    RPPlayer_ShowContextMenu(currentItem, self)
                end
            end)

            -- Drag handlers for reorganizing and drag-to-player
            slot:SetScript("OnDragStart", function(self)
                StartDrag(currentItem, currentSlotIndex)
            end)

            slot:SetScript("OnDragStop", function(self)
                -- Check if we're hovering over this slot or another slot
                local mouseoverSlot = nil
                for i = 1, MAX_SLOTS do
                    if MouseIsOver(itemSlots[i]) then
                        mouseoverSlot = i
                        break
                    end
                end

                StopDrag(mouseoverSlot)
            end)

            -- Allow receiving drags (for reorganization)
            slot:SetScript("OnReceiveDrag", function(self)
                -- Same as OnDragStop - handle the drop
                local mouseoverSlot = nil
                for i = 1, MAX_SLOTS do
                    if MouseIsOver(itemSlots[i]) then
                        mouseoverSlot = i
                        break
                    end
                end

                StopDrag(mouseoverSlot)
            end)

            slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            slot:RegisterForDrag("LeftButton")
            else
                Log("ERROR: Object not found for GUID: " .. tostring(instance.guid))
            end
        end
    end

    -- Enable empty slots to receive drags for reorganization
    for i = 1, MAX_SLOTS do
        local slot = itemSlots[i]
        if not slot.item then
            local emptySlotIndex = i

            -- Allow receiving drags on empty slots
            slot:SetScript("OnReceiveDrag", function(self)
                StopDrag(emptySlotIndex)
            end)
        end
    end

    -- Update database label (shows which GM database is synced)
    RPBagFrame_UpdateDatabaseLabel()
end

-- ============================================================================
-- MAIN EVENT HANDLER (Message Reception)
-- ============================================================================
-- Listens for addon messages and PLAYER_LOGIN event
--
-- EVENTS:
--   - CHAT_MSG_ADDON: Fires when addon message received
--     - arg1: prefix (string) - Addon identifier
--     - arg2: message (string) - Base64-encoded data
--     - arg3: distribution (string) - RAID/PARTY/WHISPER/etc.
--     - arg4: sender (string) - Player name who sent
--
--   - PLAYER_LOGIN: Fires once when character finishes loading
--     - SavedVariables are now available
--     - Safe to access RPPlayerDB
--
-- MESSAGE TYPES HANDLED:
--   - GIVE: GM gives item → Show accept/decline popup
--   - TRADE: Player trades item → Show accept/decline popup
--   - SHOW: Player shows item → Show preview popup (no inventory add)
--   - SHOW_REJECT: Player rejected preview → Notify sender
--   - TRADE_ACCEPT: Player accepted trade → Remove item from our inventory
--   - TRADE_REJECT: Player rejected trade → Keep item in our inventory
--
-- MESSAGE FORMAT: "TYPE^targetName^id^name^icon^tooltip^content^extra"
--   - Caret-delimited fields (^ instead of | to avoid WoW escape sequence conflicts)
--   - Base64-encoded for safe transmission
--
-- PATTERN: Event-driven architecture (observer pattern)
--   - Similar to addEventListener() in JavaScript
--   - Similar to EventHandler in C#
-- ============================================================================
local eventFrame = CreateFrame("Frame")  -- Invisible event listener

Log("Registering event: CHAT_MSG_ADDON")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")  -- Subscribe to addon messages
Log("CHAT_MSG_ADDON registered successfully")

Log("Registering event: PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_LOGIN")    -- Subscribe to login event
Log("PLAYER_LOGIN registered successfully")

Log("Setting up OnEvent handler")
Log("ADDON_PREFIX configured as: " .. tostring(ADDON_PREFIX))

eventFrame:SetScript("OnEvent", function()  -- Event handler callback
    Log("OnEvent triggered - event type: " .. tostring(event))

    if event == "CHAT_MSG_ADDON" then
        -- Extract event parameters (Lua 5.0 uses global arg1, arg2, etc.)
        local prefix, encodedMessage, distribution, sender = arg1, arg2, arg3, arg4

        Log("CHAT_MSG_ADDON handler - prefix: " .. tostring(prefix) .. ", expected: " .. tostring(ADDON_PREFIX))
        Log("  distribution: " .. tostring(distribution) .. ", sender: " .. tostring(sender))
        Log("  message length: " .. tostring(string.len(encodedMessage or "")))

        -- Filter: Only process messages with our addon prefix
        if prefix ~= ADDON_PREFIX then
            Log("Prefix mismatch - ignoring message from prefix: " .. tostring(prefix))
            return  -- Ignore messages from other addons
        end

        Log("CHAT_MSG_ADDON received - prefix: " .. tostring(prefix) .. ", distribution: " .. tostring(distribution) .. ", sender: " .. tostring(sender))
        Log("Message: " .. encodedMessage)

        -- Parse message using messaging module
        -- Automatically handles Base64 decoding and caret-delimited parsing
        local messageType, parts = messaging.ParseMessage(encodedMessage)

        Log("Message type: " .. tostring(messageType) .. ", parts count: " .. table.getn(parts))

        -- Log all parts for debugging
        for i = 1, table.getn(parts) do
            Log("Part " .. i .. ": " .. tostring(parts[i]))
        end

        -- Handle different message types (pattern similar to switch/case)
        if messageType == messaging.MESSAGE_TYPES.DB_SYNC_START then
            -- Format: DB_SYNC_START^messageId^databaseId^databaseName^version^checksum^totalSize
            local messageId = parts[2]
            Log("Received DB_SYNC_START from " .. sender .. " (msgId: " .. messageId .. ")")

            -- Initialize chunked sync tracking
            RPPlayer_ChunkedSyncs[messageId] = {
                metadata = {
                    id = parts[3],
                    name = parts[4],
                    version = tonumber(parts[5]),
                    checksum = parts[6]
                },
                totalSize = tonumber(parts[7]),
                chunks = {},
                totalChunks = 0,
                sender = sender
            }

            Log("Sync started: " .. parts[4] .. " (total size: " .. parts[7] .. " bytes)")

        elseif messageType == messaging.MESSAGE_TYPES.DB_SYNC_CHUNK then
            -- Format: DB_SYNC_CHUNK^messageId^chunkIndex^totalChunks^chunkData
            local messageId = parts[2]
            local chunkIndex = tonumber(parts[3])
            local totalChunks = tonumber(parts[4])
            local chunkData = parts[5]

            Log("Received DB_SYNC_CHUNK " .. chunkIndex .. "/" .. totalChunks .. " (msgId: " .. messageId .. ")")

            if not RPPlayer_ChunkedSyncs[messageId] then
                Log("ERROR: No DB_SYNC_START for message ID: " .. messageId)
                return
            end

            -- Store chunk
            RPPlayer_ChunkedSyncs[messageId].chunks[chunkIndex] = chunkData
            RPPlayer_ChunkedSyncs[messageId].totalChunks = totalChunks

            -- Show progress
            local received = table.getn(RPPlayer_ChunkedSyncs[messageId].chunks)
            Log("Progress: " .. received .. "/" .. totalChunks .. " chunks received")

        elseif messageType == messaging.MESSAGE_TYPES.DB_SYNC_END then
            -- Format: DB_SYNC_END^messageId
            local messageId = parts[2]
            Log("Received DB_SYNC_END (msgId: " .. messageId .. ")")

            if not RPPlayer_ChunkedSyncs[messageId] then
                Log("ERROR: No DB_SYNC_START for message ID: " .. messageId)
                return
            end

            -- Reassemble the database
            local syncedDatabase = objectDatabase.ReassembleChunkedSync(RPPlayer_ChunkedSyncs[messageId])

            if syncedDatabase then
                -- Store synced database in SavedVariables
                RPPlayerDB.syncedDatabase = syncedDatabase

                -- Update sync state metadata
                RPPlayerDB.syncState = {
                    databaseId = syncedDatabase.metadata.id,
                    databaseName = syncedDatabase.metadata.name,
                    version = syncedDatabase.metadata.version,
                    checksum = syncedDatabase.metadata.checksum,
                    lastSyncTime = time()
                }

                -- Count items (hash table indexed by ID)
                local itemCount = 0
                for _ in pairs(syncedDatabase.items) do
                    itemCount = itemCount + 1
                end
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r Database synced from %s: '%s' (%d items)",
                    sender, syncedDatabase.metadata.name, itemCount), 0, 1, 0)
                Log("Database synced successfully: " .. syncedDatabase.metadata.name .. " (" .. itemCount .. " items)")

                -- Refresh bag UI to show database name
                RPPlayer_RefreshBag()

                -- Clean up chunked sync data
                RPPlayer_ChunkedSyncs[messageId] = nil
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Failed to reassemble database sync from " .. sender, 1, 0, 0)
                Log("ERROR: Failed to reassemble DB_SYNC chunks")
            end

        elseif messageType == messaging.MESSAGE_TYPES.GIVE then
            -- FORMAT v0.1.1: GIVE^targetName^itemGuid^customMessage^customText^customNumber
            local targetName = parts[2]
            local itemGuid = parts[3]
            local customMessage = parts[4] or "A Game Master wants to give you an item."
            local customText = parts[5] or ""
            local customNumber = tonumber(parts[6]) or 0
            local myName = UnitName("player")

            Log("GIVE - Target: " .. tostring(targetName) .. ", GUID: " .. tostring(itemGuid) .. ", MyName: " .. tostring(myName))

            if targetName ~= myName then
                Log("GIVE not for me")
                return
            end

            -- Look up item by GUID in synced database
            if not RPPlayerDB.syncedDatabase or not RPPlayerDB.syncedDatabase.items then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r No database synced from GM!", 1, 0, 0)
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r Ask " .. sender .. " to click 'Sync to Raid' first.", 1, 1, 0)
                Log("ERROR: No synced database to look up item GUID: " .. itemGuid .. " from " .. sender)
                return
            end

            local objectDef = nil
            for _, dbItem in pairs(RPPlayerDB.syncedDatabase.items) do
                if dbItem.guid == itemGuid then
                    objectDef = dbItem
                    break
                end
            end

            if not objectDef then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Item not found in database!", 1, 0, 0)
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r Ask " .. sender .. " to click 'Sync to Raid' to update your database.", 1, 1, 0)
                Log("ERROR: Item GUID not found in synced database: " .. itemGuid .. " (database: " .. tostring(RPPlayerDB.syncState.databaseName) .. ")")
                return
            end

            -- Check if bag is full
            if inventory.IsBagFull(RPPlayerDB.inventory) then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Bag is full! Cannot receive item.", 1, 0, 0)
                Log("Bag is full, cannot receive item: " .. objectDef.name)
                return
            end

            -- v0.2.1: Create instance data only (minimal storage)
            local instance = inventory.CreateItemInstance(itemGuid, customText, customNumber)

            -- Store instance + object reference for popup
            RPPlayer_PendingGiveItem = instance
            RPPlayer_PendingGiveObjectDef = objectDef  -- For display during popup
            RPPlayer_PendingGiveSender = sender
            RPPlayer_PendingGiveMessage = customMessage

            -- Show accept/decline popup (only custom message in gold)
            StaticPopup_Show("RPPLAYER_GIVE_REQUEST", customMessage)
            Log("Showing GIVE popup for item: " .. objectDef.name)

        elseif messageType == "GIVE_CONTENT" then
            -- DEPRECATED: Old two-part protocol, no longer used
            Log("WARNING: Received deprecated GIVE_CONTENT message - ignoring")

        elseif messageType == messaging.MESSAGE_TYPES.TRADE then
            -- FORMAT v0.1.1: TRADE^targetName^objectGuid^customText^customNumber
            local targetName = parts[2]
            local myName = UnitName("player")

            Log("TRADE - Target: " .. tostring(targetName) .. ", MyName: " .. tostring(myName))

            if targetName ~= myName then
                Log("TRADE not for me")
                return
            end

            local objectGuid = parts[3] or ""
            local customText = parts[4] or ""
            local customNumber = tonumber(parts[5]) or 0

            -- Look up object in syncedDatabase
            local objectDef = nil
            if RPPlayerDB.syncedDatabase and RPPlayerDB.syncedDatabase.items then
                for id, obj in pairs(RPPlayerDB.syncedDatabase.items) do
                    if obj.guid == objectGuid then
                        objectDef = obj
                        break
                    end
                end
            end

            if not objectDef then
                -- Error: object not in database
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Object not found in database!", 1, 0, 0)
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r Ask GM to 'Sync to Raid' first.", 1, 1, 0)
                Log("TRADE failed: Object " .. objectGuid .. " not found in syncedDatabase")
                return
            end

            -- v0.2.1: Create instance data only (minimal storage)
            local instance = inventory.CreateItemInstance(objectGuid, customText, customNumber)

            Log("TRADE complete - Item: " .. tostring(objectDef.name) .. " from " .. sender)

            -- Check if bag is full
            if inventory.IsBagFull(RPPlayerDB.inventory) then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Bag is full! Cannot accept trade.", 1, 0, 0)
                Log("Bag is full, cannot accept trade")
                return
            end

            -- Store instance + object reference for popup
            RPPlayer_PendingTradeItem = instance
            RPPlayer_PendingTradeObjectDef = objectDef  -- For display during popup
            RPPlayer_PendingTradeSender = sender

            -- Show popup
            StaticPopup_Show("RPPLAYER_TRADE_REQUEST", sender, objectDef.name or "an item")
            Log("Showing TRADE_REQUEST popup from " .. sender)

        elseif messageType == "TRADE_CONTENT" then
            -- DEPRECATED: Old two-part protocol, no longer used
            Log("WARNING: Received deprecated TRADE_CONTENT message - ignoring")

        elseif messageType == messaging.MESSAGE_TYPES.SHOW then
            -- FORMAT v0.1.1: SHOW^targetName^objectGuid^customText^customNumber
            local targetName = parts[2]
            local myName = UnitName("player")

            Log("SHOW - Target: " .. tostring(targetName) .. ", MyName: " .. tostring(myName))

            if targetName ~= myName then
                Log("SHOW not for me")
                return
            end

            local objectGuid = parts[3] or ""
            local customText = parts[4] or ""
            local customNumber = tonumber(parts[5]) or 0

            -- Look up object in syncedDatabase
            local objectDef = nil
            if RPPlayerDB.syncedDatabase and RPPlayerDB.syncedDatabase.items then
                for id, obj in pairs(RPPlayerDB.syncedDatabase.items) do
                    if obj.guid == objectGuid then
                        objectDef = obj
                        break
                    end
                end
            end

            if not objectDef then
                -- Error: object not in database
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Object not found in database!", 1, 0, 0)
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r Ask GM to 'Sync to Raid' first.", 1, 1, 0)
                Log("SHOW failed: Object " .. objectGuid .. " not found in syncedDatabase")
                return
            end

            -- Build item from object definition + instance data (don't add to inventory, just for display)
            local item = {
                guid = objectDef.guid,
                name = objectDef.name,
                icon = objectDef.icon,
                tooltip = objectDef.tooltip,
                content = objectDef.content,
                contentTemplate = objectDef.contentTemplate,  -- v0.2.0: Include template for custom text display
                actions = objectDef.actions,  -- Shared reference (read-only)
                customText = customText,
                customNumber = customNumber
            }

            Log("SHOW complete - Item: " .. tostring(item.name) .. " from " .. sender)

            -- Store item and sender for popup callbacks
            RPPlayer_PendingShowItem = item
            RPPlayer_PendingShowSender = sender

            -- Show standard confirmation popup
            StaticPopup_Show("RPPLAYER_SHOW_REQUEST", sender, item.name or "an object")
            Log("Showing SHOW_REQUEST popup from " .. sender)

        elseif messageType == "SHOW_CONTENT" then
            -- DEPRECATED: Old two-part protocol, no longer used
            Log("WARNING: Received deprecated SHOW_CONTENT message - ignoring")

        elseif messageType == messaging.MESSAGE_TYPES.SHOW_REJECT then
            -- Format: SHOW_REJECT^targetName^rejecterName^itemName
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

        elseif messageType == messaging.MESSAGE_TYPES.TRADE_ACCEPT then
            -- Format: TRADE_ACCEPT^senderName^receiverName^itemName
            local targetName = parts[2]
            local accepterName = parts[3]
            local itemName = parts[4]
            local myName = UnitName("player")

            -- Check if message is for me
            if targetName ~= myName then
                Log("TRADE_ACCEPT not for me (target: " .. tostring(targetName) .. ", me: " .. tostring(myName) .. ")")
                return
            end

            Log("TRADE_ACCEPT received from " .. accepterName .. " for item: " .. tostring(itemName))

            -- Display acceptance message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r %s accepted your gift: '%s'", accepterName, itemName), 0, 1, 0)

            -- Remove pending outgoing trade if exists
            if RPPlayer_PendingOutgoingTrade then
                -- Remove from inventory by slot (unique identifier)
                for i, invItem in ipairs(RPPlayerDB.inventory) do
                    if invItem.slot == RPPlayer_PendingOutgoingTrade.slot then
                        table.remove(RPPlayerDB.inventory, i)
                        RPPlayer_RefreshBag()
                        Log("Removed item from inventory after TRADE_ACCEPT (slot " .. tostring(invItem.slot) .. ")")
                        break
                    end
                end
                RPPlayer_PendingOutgoingTrade = nil
            end

        elseif messageType == "TRADE_REJECT" then
            -- Format: TRADE_REJECT^senderName^receiverName^itemName
            local targetName = parts[2]
            local rejecterName = parts[3]
            local itemName = parts[4]
            local myName = UnitName("player")

            -- Check if message is for me
            if targetName ~= myName then
                Log("TRADE_REJECT not for me (target: " .. tostring(targetName) .. ", me: " .. tostring(myName) .. ")")
                return
            end

            Log("TRADE_REJECT received from " .. rejecterName .. " for item: " .. tostring(itemName))

            -- Display rejection message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r %s declined your gift: '%s'", rejecterName, itemName), 1, 0.5, 0)

            -- Clear pending outgoing trade (item stays in inventory)
            RPPlayer_PendingOutgoingTrade = nil

        elseif messageType == messaging.MESSAGE_TYPES.STATUS_REQUEST then
            -- Format: STATUS_REQUEST^requestId
            local requestId = parts[2]
            local myName = UnitName("player")

            Log("STATUS_REQUEST received (reqId: " .. tostring(requestId) .. ")")

            -- Collect current state
            local playerVersion = ADDON_VERSION or "unknown"

            -- Encode sync state
            local syncStateStr = ""
            if RPPlayerDB.syncState then
                syncStateStr = string.format("%s^%s^%d^%s^%d",
                    RPPlayerDB.syncState.databaseId or "",
                    RPPlayerDB.syncState.databaseName or "",
                    RPPlayerDB.syncState.version or 0,
                    RPPlayerDB.syncState.checksum or "",
                    RPPlayerDB.syncState.lastSyncTime or 0)
            end
            local syncStateEncoded = encoding.Base64Encode(syncStateStr)

            -- Encode inventory (16 slots, GUIDs only)
            local inventoryGuids = {}
            for i = 1, 16 do
                local item = RPPlayerDB.inventory and RPPlayerDB.inventory[i]
                if item and item.guid then
                    inventoryGuids[i] = item.guid
                else
                    inventoryGuids[i] = ""
                end
            end
            local inventoryStr = table.concat(inventoryGuids, "^")
            local inventoryEncoded = encoding.Base64Encode(inventoryStr)

            -- Build response message
            local responseMsg = messaging.MESSAGE_TYPES.STATUS_RESPONSE .. "^" ..
                               requestId .. "^" ..
                               playerVersion .. "^" ..
                               syncStateEncoded .. "^" ..
                               inventoryEncoded

            -- Send response
            local distribution = "RAID"
            if GetNumRaidMembers() == 0 then
                distribution = "PARTY"
            end
            SendAddonMessage(ADDON_PREFIX, responseMsg, distribution)

            Log("STATUS_RESPONSE sent (reqId: " .. tostring(requestId) .. ")")
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

        -- Migrate inventory to v0.1.1 (add customText and customNumber fields)
        local migrated = false
        for i = 1, table.getn(RPPlayerDB.inventory) do
            local item = RPPlayerDB.inventory[i]

            if not item.customText then
                item.customText = ""
                migrated = true
            end

            if not item.customNumber then
                item.customNumber = 0
                migrated = true
            end
        end

        if migrated then
            Log("Inventory migrated to v0.1.1 format")
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Inventory migrated to v0.1.1", 0, 1, 0)
        end

        -- Add welcome item if inventory is empty (first time use)
        if table.getn(RPPlayerDB.inventory) == 0 then
            Log("Inventory is empty, creating welcome letter")
            local welcomeItem = {
                id = 0,
                name = "Welcome to RP Player",
                icon = "Interface\\Icons\\INV_Misc_Note_01",
                tooltip = "Quick start guide",
                content = "RP PLAYER GUIDE\n\n" ..
                    "Left-click items to read. Right-click for options.\n\n" ..
                    "Drag items to player portraits to give or show.\n\n" ..
                    "Use /rpplayer to open bag.",
                guid = "system-welcome-0",
                customText = "",  -- v0.1.1: Instance-specific text
                customNumber = 0  -- v0.1.1: Instance-specific number
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
