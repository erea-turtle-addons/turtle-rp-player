-- ============================================================================
-- rp-actions.lua - Item Action System for Turtle RP Addons (v0.2.0)
-- ============================================================================
-- PURPOSE: Define and execute multi-method actions with parameters
--
-- RESPONSIBILITIES:
--   - Method registry (schema-driven parameter definitions)
--   - Multi-method action execution (sequential)
--   - Built-in action methods (DestroyObject, CreateObject, AddText, etc.)
--   - Action validation and parameter schema
--
-- ARCHITECTURE (v0.2.0):
--   - Actions contain multiple methods (methods array)
--   - Each method has paramSchema defining GUI and validation
--   - ExecuteAction runs methods sequentially
--   - Uses item.customText and item.customNumber for instance data
--
-- USAGE:
--   local rpActions = RequireRPActions()
--   rpActions.ExecuteAction(playerName, item, actionId)

-- Import messaging for side-effect actions
local messaging = RequireMessaging()
-- ============================================================================

-- Import dependencies
local objectDatabase = RequireObjectDatabase()
local messaging = RequireMessaging()

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local RESULT_TYPES = {
    SUCCESS = "SUCCESS",
    DESTROY_ITEM = "DESTROY_ITEM",
    UPDATE_ITEM = "UPDATE_ITEM",
    REQUEST_INPUT = "REQUEST_INPUT",
    CREATE_OBJECT = "CREATE_OBJECT",
    SEND_GM_MESSAGE = "SEND_GM_MESSAGE",
    FAIL = "FAIL",
    ERROR = "ERROR"
}

-- ============================================================================
-- METHOD REGISTRY (v0.2.0)
-- ============================================================================
-- Schema-driven method definitions with parameter requirements
-- ============================================================================

local METHOD_REGISTRY = {
    -- ========================================================================
    -- DestroyObject - Remove item from inventory
    -- ========================================================================
    DestroyObject = {
        name = "Destroy Object",
        description = "Removes this object from inventory",
        requiresParams = false,
        paramSchema = {},
        execute = function(playerName, item, params)
            return {
                result = RESULT_TYPES.DESTROY_ITEM,
                message = item.name .. " has been destroyed",
                data = {}
            }
        end
    },

    -- ========================================================================
    -- CreateObject - Create new object in player inventory
    -- ========================================================================
    CreateObject = {
        name = "Create Object",
        description = "Creates a new object in player inventory",
        requiresParams = true,
        paramSchema = {
            {
                key = "objectGuid",
                type = "object_dropdown",
                label = "Object to create",
                required = true
            },
            {
                key = "customText",
                type = "text",
                label = "Initial custom text (optional)",
                required = false
            },
            {
                key = "customNumber",
                type = "number",
                label = "Initial custom number (optional)",
                required = false
            }
        },
        execute = function(playerName, item, params)
            if not params.objectGuid then
                return {
                    result = RESULT_TYPES.FAIL,
                    message = "No object GUID specified",
                    data = {}
                }
            end

            return {
                result = RESULT_TYPES.CREATE_OBJECT,
                message = "Creating object...",
                data = {
                    objectGuid = params.objectGuid,
                    customText = params.customText or "",
                    customNumber = tonumber(params.customNumber) or 0
                }
            }
        end
    },

    -- ========================================================================
    -- AddText - Request user input to set customText
    -- ========================================================================
    -- Uses item.contentTemplate for display formatting with {custom-text} placeholder
    AddText = {
        name = "Set Custom Text",
        description = "Prompts user for custom text input",
        requiresParams = true,
        paramSchema = {
            {
                key = "instruction",
                type = "text",
                label = "Instruction text (shown to user)",
                required = true
            }
        },
        execute = function(playerName, item, params)
            return {
                result = RESULT_TYPES.REQUEST_INPUT,
                message = "Requesting user input...",
                data = {
                    instruction = params.instruction or "Enter custom text:"
                }
            }
        end
    },

    -- ========================================================================
    -- ConsumeCharge - Decrement customNumber, destroy at 0
    -- ========================================================================
    ConsumeCharge = {
        name = "Consume Charge",
        description = "Decrements customNumber, destroys item at 0",
        requiresParams = false,
        paramSchema = {},
        execute = function(playerName, item, params)
            if not item.customNumber or item.customNumber <= 0 then
                return {
                    result = RESULT_TYPES.FAIL,
                    message = "No charges remaining",
                    data = {}
                }
            end

            item.customNumber = item.customNumber - 1

            if item.customNumber == 0 then
                return {
                    result = RESULT_TYPES.DESTROY_ITEM,
                    message = item.name .. " has been consumed (no charges remaining)",
                    data = {}
                }
            else
                return {
                    result = RESULT_TYPES.UPDATE_ITEM,
                    message = "Charges remaining: " .. item.customNumber,
                    data = {
                        customNumber = item.customNumber
                    }
                }
            end
        end
    },

    -- ========================================================================
    -- DisplayRaidWarning - Send GM message for raid warning
    -- ========================================================================
    DisplayRaidWarning = {
        name = "Display Raid Warning",
        description = "Sends message to GM for raid warning",
        requiresParams = true,
        paramSchema = {
            {
                key = "messageTemplate",
                type = "text_with_placeholder",
                label = "Message (use {playerName} or {customText})",
                required = true,
                placeholders = {"{playerName}", "{customText}"}
            }
        },
        execute = function(playerName, item, params)
            if not params.messageTemplate then
                return {
                    result = RESULT_TYPES.FAIL,
                    message = "No message template specified",
                    data = {}
                }
            end

            local message = params.messageTemplate
            message = string.gsub(message, "{playerName}", playerName)
            message = string.gsub(message, "{customText}", item.customText or "")

            -- Send raid warning request to GM immediately
            messaging.SendRaidWarningMessage(playerName, message)

            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Requesting raid warning from GM...", 0, 1, 0)
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700[Message]|r " .. message, 1, 1, 0)

            return {
                result = RESULT_TYPES.SUCCESS,
                message = "Raid warning request sent",
                data = {}
            }
        end
    }
}

-- ============================================================================
-- CORE ACTION SYSTEM
-- ============================================================================

-- ============================================================================
-- FindActionById - Find action definition in item's actions array
-- ============================================================================
local function FindActionById(item, actionId)
    if not item or not item.actions then
        return nil
    end

    for i = 1, table.getn(item.actions) do
        local action = item.actions[i]
        if action.id == actionId then
            return action
        end
    end

    return nil
end

-- ============================================================================
-- ValidateAction - Validate action definition (v0.2.0: supports methods array)
-- ============================================================================
local function ValidateAction(action)
    if not action then
        return false, "Action is nil"
    end

    if not action.id or action.id == "" then
        return false, "Action missing id"
    end

    -- v0.2.0: Check for methods array
    if not action.methods then
        return false, "Action missing methods array"
    end

    if table.getn(action.methods) == 0 then
        return false, "Action has no methods"
    end

    -- Validate each method
    for i = 1, table.getn(action.methods) do
        local method = action.methods[i]

        if not method.type or method.type == "" then
            return false, "Method " .. i .. " missing type"
        end

        if not METHOD_REGISTRY[method.type] then
            return false, "Unknown method type: " .. tostring(method.type)
        end
    end

    return true, nil
end

-- ============================================================================
-- ExecuteAction - Main entry point for executing multi-method actions (v0.2.0)
-- ============================================================================
-- @param playerName: Player executing the action
-- @param item: Item object with actions
-- @param actionId: ID of action to execute
-- @returns: { result, message, data }
--
-- FLOW:
--   1. Find action in item.actions by actionId
--   2. Validate action definition
--   3. Execute each method sequentially
--   4. Return result (early exit on REQUEST_INPUT)
-- ============================================================================
local function ExecuteAction(playerName, item, actionId)
    -- Find action definition
    local action = FindActionById(item, actionId)
    if not action then
        return {
            result = RESULT_TYPES.ERROR,
            message = "Action not found: " .. tostring(actionId),
            data = nil
        }
    end

    -- Validate action
    local valid, errorMsg = ValidateAction(action)
    if not valid then
        return {
            result = RESULT_TYPES.ERROR,
            message = errorMsg,
            data = nil
        }
    end

    -- Execute methods sequentially
    local results = {}
    for i = 1, table.getn(action.methods) do
        local method = action.methods[i]
        local methodDef = METHOD_REGISTRY[method.type]

        if methodDef then
            -- Merge method params with default params
            local params = method.params or {}

            -- Execute method
            local success, result = pcall(methodDef.execute, playerName, item, params)

            if not success then
                -- Handler threw error
                return {
                    result = RESULT_TYPES.ERROR,
                    message = "Method execution failed: " .. tostring(result),
                    data = nil
                }
            end

            table.insert(results, result)

            -- Early exit for REQUEST_INPUT (player needs to provide input first)
            if result.result == RESULT_TYPES.REQUEST_INPUT then
                return result
            end

            -- Early exit for errors
            if result.result == RESULT_TYPES.ERROR or result.result == RESULT_TYPES.FAIL then
                return result
            end
        end
    end

    -- Combine results (last result wins for now - could be more sophisticated)
    if table.getn(results) > 0 then
        return results[table.getn(results)]
    else
        return {
            result = RESULT_TYPES.SUCCESS,
            message = "Action completed",
            data = {}
        }
    end
end

-- ============================================================================
-- GetMethodRegistry - Get complete method registry
-- ============================================================================
local function GetMethodRegistry()
    return METHOD_REGISTRY
end

-- ============================================================================
-- GetMethodSchema - Get parameter schema for a method type
-- ============================================================================
local function GetMethodSchema(methodType)
    local method = METHOD_REGISTRY[methodType]
    return method and method.paramSchema or {}
end

-- ============================================================================
-- GetAvailableMethods - Get list of available method types for GUI
-- ============================================================================
local function GetAvailableMethods()
    local methods = {}
    for methodType, methodDef in pairs(METHOD_REGISTRY) do
        table.insert(methods, {
            type = methodType,
            name = methodDef.name,
            description = methodDef.description
        })
    end
    return methods
end

-- ============================================================================
-- EXPORT FUNCTIONS
-- ============================================================================

function RequireRPActions()
    return {
        -- Core execution
        ExecuteAction = ExecuteAction,
        FindActionById = FindActionById,
        ValidateAction = ValidateAction,

        -- Method registry
        GetMethodRegistry = GetMethodRegistry,
        GetMethodSchema = GetMethodSchema,
        GetAvailableMethods = GetAvailableMethods,

        -- Constants
        RESULT_TYPES = RESULT_TYPES
    }
end
