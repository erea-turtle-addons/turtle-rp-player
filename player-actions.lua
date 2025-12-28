-- ============================================================================
-- player-actions.lua - Player-side Action GUI for Turtle RP Player
-- ============================================================================
-- PURPOSE: Handle all GUI aspects of action execution on the player side
--
-- RESPONSIBILITIES:
--   - Display REQUEST_INPUT dialogs (Set Custom Text)
--   - Update inventory on DESTROY_ITEM and UPDATE_ITEM
--   - Handle CREATE_OBJECT requests
--   - Display messages for action results
--
-- ARCHITECTURE:
--   - rp-common/rp-actions.lua: Pure business logic (ExecuteAction)
--   - player-actions.lua: Player-side GUI (THIS FILE)
--   - Calls RPPlayer_RefreshBag() to update inventory display
--   - Uses StaticPopupDialogs for user input
--
-- USAGE:
--   local playerActions = RequirePlayerActions()
--   playerActions.ExecuteAction(item, action)
-- ============================================================================

-- Import dependencies (lazy loading to avoid initialization order issues)
local rpActions = nil
local function GetRPActions()
    if not rpActions then
        rpActions = RequireRPActions()
    end
    return rpActions
end

local inventory = nil
local function GetInventory()
    if not inventory then
        inventory = RequireInventory()
    end
    return inventory
end

-- ============================================================================
-- Log() - Local logging function wrapper
-- ============================================================================
local function Log(message)
    if RPPlayerDebugLog then
        -- WoW 1.12: No date() function, use simple logging
        local logEntry = string.format("RPPlayer: %s", tostring(message))
        table.insert(RPPlayerDebugLog, logEntry)
        if table.getn(RPPlayerDebugLog) > 500 then
            table.remove(RPPlayerDebugLog, 1)
        end
    end
end

-- ============================================================================
-- STATIC POPUP DIALOGS
-- ============================================================================

-- ============================================================================
-- REQUEST_INPUT Dialog - For "Set Custom Text" action
-- ============================================================================
-- Shows popup asking for user input, stores directly in customText
-- Template formatting (contentTemplate with {custom-text}) happens on display
-- ============================================================================
StaticPopupDialogs["RPPLAYER_REQUEST_INPUT"] = {
    text = "%s",  -- Will be set dynamically in OnShow
    button1 = "OK",
    button2 = "Cancel",
    hasEditBox = 1,
    maxLetters = 150,  -- Match customText max length
    OnAccept = function()
        local userInput = getglobal(this:GetParent():GetName().."EditBox"):GetText()
        if not userInput or userInput == "" then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Input cannot be empty!", 1, 0, 0)
            return
        end

        -- Get item from global state (WoW 1.12 compat)
        if not RPPlayer_PendingInputItem then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Error: Dialog data missing!", 1, 0, 0)
            return
        end

        -- Store user input directly in customText (no template substitution here)
        -- Template formatting happens when displaying via contentTemplate
        if string.len(userInput) > 150 then
            userInput = string.sub(userInput, 1, 150)
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r Text truncated to 150 characters", 1, 1, 0)
        end

        -- v0.2.1: Update instance customText in inventory (instances have only {guid, customText, customNumber, slot})
        for i, instance in ipairs(RPPlayerDB.inventory) do
            if instance.slot == RPPlayer_PendingInputItem.slot then
                instance.customText = userInput
                break
            end
        end

        -- Refresh UI to show updated text
        if RPPlayer_RefreshBag then
            RPPlayer_RefreshBag()
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Custom text set: " .. RPPlayer_PendingInputItem.name, 0, 1, 0)

        -- Clear global state
        RPPlayer_PendingInputItem = nil
        RPPlayer_PendingInputAction = nil
        RPPlayer_PendingInputInstruction = nil
    end,
    OnShow = function()
        -- Clear edit box on show
        getglobal(this:GetName().."EditBox"):SetText("")

        -- Get instruction from global state (WoW 1.12 compat)
        if RPPlayer_PendingInputInstruction then
            getglobal(this:GetName().."Text"):SetText(RPPlayer_PendingInputInstruction)
        else
            getglobal(this:GetName().."Text"):SetText("Enter custom text for '" .. (RPPlayer_PendingInputItem and RPPlayer_PendingInputItem.name or "item") .. "':")
        end
    end,
    OnCancel = function()
        -- Clear global state
        RPPlayer_PendingInputItem = nil
        RPPlayer_PendingInputAction = nil
        RPPlayer_PendingInputInstruction = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true
}

-- ============================================================================
-- GLOBAL STATE (WoW 1.12 StaticPopup compatibility)
-- ============================================================================
-- WoW 1.12: StaticPopup 4th parameter unreliable, use globals instead
RPPlayer_PendingInputItem = nil
RPPlayer_PendingInputAction = nil
RPPlayer_PendingInputInstruction = nil

-- ============================================================================
-- RESULT HANDLERS
-- ============================================================================

-- ============================================================================
-- HandleRequestInput - Show input dialog for Set Custom Text
-- ============================================================================
local function HandleRequestInput(item, action, result)
    -- WoW 1.12: Use global variables instead of dialog data parameter
    RPPlayer_PendingInputItem = item
    RPPlayer_PendingInputAction = action
    RPPlayer_PendingInputInstruction = result.data.instruction or "Enter custom text:"

    StaticPopup_Show("RPPLAYER_REQUEST_INPUT", item.name)
end

-- ============================================================================
-- HandleCreateObject - Create object instance in inventory
-- ============================================================================
local function HandleCreateObject(item, action, result)
    local objectGuid = result.data.objectGuid
    local customText = result.data.customText or ""
    local customNumber = tonumber(result.data.customNumber) or 0

    -- Look up object definition from synced database
    local objectDef = nil
    if RPPlayerDB and RPPlayerDB.syncedDatabase and RPPlayerDB.syncedDatabase.items then
        for id, obj in pairs(RPPlayerDB.syncedDatabase.items) do
            if obj.guid == objectGuid then
                objectDef = obj
                break
            end
        end
    end

    if not objectDef then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Cannot create object: Not found in database", 1, 0, 0)
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r Object GUID: " .. objectGuid, 1, 1, 0)
        return
    end

    -- Check if bag is full
    local inventoryModule = GetInventory()
    if inventoryModule.IsBagFull(RPPlayerDB.inventory) then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Cannot create object: Bag is full", 1, 0, 0)
        return
    end

    -- Create instance (minimal data: guid, customText, customNumber, slot)
    local instance = inventoryModule.CreateItemInstance(objectGuid, customText, customNumber)

    -- Add to inventory
    table.insert(RPPlayerDB.inventory, instance)

    -- Refresh UI
    if RPPlayer_RefreshBag then
        RPPlayer_RefreshBag()
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Created: " .. objectDef.name, 0, 1, 0)
end

-- ============================================================================
-- HandleDestroyItem - Remove item from inventory and refresh UI
-- ============================================================================
local function HandleDestroyItem(item, action, result)
    -- Remove item from inventory
    if RPPlayer_DeleteItem then
        RPPlayer_DeleteItem(item)
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r " .. (result.message or "Item destroyed"), 0, 1, 0)
end

-- ============================================================================
-- HandleUpdateItem - Refresh UI to show updated item (e.g. charges)
-- ============================================================================
local function HandleUpdateItem(item, action, result)
    -- Update item in inventory if result.data contains updates
    if result.data then
        for i, invItem in ipairs(RPPlayerDB.inventory) do
            if invItem.slot == item.slot then
                -- Update customNumber if provided (e.g. ConsumeCharge)
                if result.data.customNumber then
                    invItem.customNumber = result.data.customNumber
                end
                -- Update customText if provided
                if result.data.customText then
                    invItem.customText = result.data.customText
                end
                break
            end
        end
    end

    -- Refresh UI to show updated item
    if RPPlayer_RefreshBag then
        RPPlayer_RefreshBag()
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r " .. (result.message or "Item updated"), 0, 1, 0)
end

-- ============================================================================
-- HandleSuccess - Generic success message
-- ============================================================================
local function HandleSuccess(item, action, result)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r " .. (result.message or "Action executed: " .. action.label), 0, 1, 0)
end

-- ============================================================================
-- HandleFail - Action failed (not an error, just failed validation)
-- ============================================================================
local function HandleFail(item, action, result)
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r " .. (result.message or "Action failed"), 1, 1, 0)
end

-- ============================================================================
-- HandleError - Execution error
-- ============================================================================
local function HandleError(item, action, result)
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Error: " .. (result.message or "Unknown error"), 1, 0, 0)
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- ============================================================================
-- ExecuteAction - Execute action and handle GUI for result
-- ============================================================================
-- @param item: Table - Item object with actions
-- @param action: Table - Action object to execute
-- @returns: void
--
-- FLOW:
--   1. Call rpActions.ExecuteAction (business logic)
--   2. Handle result.result type (GUI logic)
--   3. Update inventory/UI as needed
-- ============================================================================
local function ExecuteAction(item, action)
    Log("ExecuteAction called - Item: " .. tostring(item.name) .. ", Action: " .. tostring(action.id))

    local playerName = UnitName("player")
    local rpActions = GetRPActions()  -- Lazy load
    local result = rpActions.ExecuteAction(playerName, item, action.id)

    if not result then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Action execution failed: No result returned", 1, 0, 0)
        return
    end

    -- Dispatch to appropriate handler based on result type
    if result.result == rpActions.RESULT_TYPES.REQUEST_INPUT then
        HandleRequestInput(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.CREATE_OBJECT then
        HandleCreateObject(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.DESTROY_ITEM then
        HandleDestroyItem(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.UPDATE_ITEM then
        HandleUpdateItem(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.SUCCESS then
        HandleSuccess(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.FAIL then
        HandleFail(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.ERROR then
        HandleError(item, action, result)

    else
        -- Unknown result type
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Unknown result type: " .. tostring(result.result), 1, 0, 0)
    end
end

-- ============================================================================
-- EXPORT FUNCTIONS
-- ============================================================================

function RequirePlayerActions()
    return {
        ExecuteAction = ExecuteAction
    }
end
