-- ============================================================================
-- messaging.lua - Message Protocol Logic for Turtle RP Addons
-- ============================================================================
-- PURPOSE: Item-related message protocol logic
--
-- RESPONSIBILITIES:
--   - Message creation (GIVE, TRADE, SHOW, responses)
--   - Message parsing (caret-delimited protocol)
--   - Message encoding/decoding (Base64 for responses)
--   - Distribution channel selection (RAID/PARTY)
--   - Protocol constants and message types
--
-- NOT INCLUDED:
--   - Database sync messages (see object-database.lua)
--     CreateSyncMessageChunks, ReassembleChunkedSync are in object-database.lua
--     because they're tightly coupled with database serialization
--
-- SEPARATION OF CONCERNS:
--   - This file: Item message protocol, message formatting
--   - object-database.lua: Database sync protocol, serialization
--   - Client code (rp-master/rp-player): Event handling, UI, user interaction
--   - encoding.lua: Base64 implementation details
--
-- USAGE:
--   local messaging = RequireMessaging()
--   local msg = messaging.CreateGiveMessage("PlayerName", "guid-123", "Custom message")
--   SendAddonMessage(messaging.ADDON_PREFIX, msg, messaging.GetDistribution("PlayerName"))
-- ============================================================================

-- Import encoding library for Base64
local encoding = RequireEncoding()

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local ADDON_PREFIX = "RPMSTR"
local MESSAGE_DELIMITER = "^"

-- Message type constants
local MESSAGE_TYPES = {
    -- Outgoing from GM to Player
    GIVE = "GIVE",
    TRADE = "TRADE",
    SHOW = "SHOW",

    -- Responses from Player to GM
    GIVE_ACCEPT = "GIVE_ACCEPT",
    GIVE_REJECT = "GIVE_REJECT",
    TRADE_ACCEPT = "TRADE_ACCEPT",
    TRADE_REJECT = "TRADE_REJECT",
    SHOW_REJECT = "SHOW_REJECT",

    -- Database sync protocol
    DB_SYNC_START = "DB_SYNC_START",
    DB_SYNC_CHUNK = "DB_SYNC_CHUNK",
    DB_SYNC_END = "DB_SYNC_END",

    -- Action execution protocol
    ACTION_EXECUTE = "ACTION_EXECUTE",
    ACTION_RESULT = "ACTION_RESULT",

    -- Action results
    RAID_WARNING = "RAID_WARNING",

    -- Player monitoring protocol
    STATUS_REQUEST = "STATUS_REQUEST",
    STATUS_RESPONSE = "STATUS_RESPONSE"
}

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- ============================================================================
-- ParseCaretDelimited() - Parse caret-delimited string
-- ============================================================================
-- @param message: String with ^ delimiters
-- @returns: Array of parts
--
-- EXAMPLE: "GIVE^PlayerName^123-456^Message" -> {"GIVE", "PlayerName", "123-456", "Message"}
--
-- IMPORTANT: Preserves empty fields (e.g., "a^^b" -> {"a", "", "b"})
-- ============================================================================
local function ParseCaretDelimited(message)
    if not message or message == "" then return {} end

    local parts = {}
    local lastPos = 1
    local msgLen = string.len(message)

    while lastPos <= msgLen do
        -- Lua 5.0: string.find(haystack, needle, start, plain)
        local caretPos = string.find(message, MESSAGE_DELIMITER, lastPos, true)  -- true = plain text search
        if caretPos then
            local field = string.sub(message, lastPos, caretPos - 1)
            table.insert(parts, field)
            lastPos = caretPos + 1

            -- Lua 5.0: If delimiter is at end of message, add final empty field
            if caretPos == msgLen then
                table.insert(parts, "")
                break
            end
        else
            -- Last field (no more carets)
            local field = string.sub(message, lastPos)
            table.insert(parts, field)
            break
        end
    end

    return parts
end

-- ============================================================================
-- GetDistribution() - Determine best addon message channel
-- ============================================================================
-- @param targetName: Player name (optional, for future WHISPER support)
-- @returns: "RAID" or "PARTY"
--
-- BEHAVIOR:
--   - Returns "RAID" if in raid (GetNumRaidMembers() > 0)
--   - Returns "PARTY" if in party (GetNumPartyMembers() > 0)
--   - Returns "RAID" as fallback (safest option)
--
-- NOTE: WoW 1.12 doesn't support WHISPER distribution for addon messages
-- ============================================================================
local function GetDistribution(targetName)
    -- Check if in raid first (raids take priority over parties)
    if GetNumRaidMembers() > 0 then
        return "RAID"
    -- Check if in party
    elseif GetNumPartyMembers() > 0 then
        return "PARTY"
    else
        -- Fallback: Return RAID even if not in one
        -- (message won't send, but won't cause error)
        return "RAID"
    end
end

-- ============================================================================
-- MESSAGE CREATION FUNCTIONS
-- ============================================================================

-- ============================================================================
-- CreateGiveMessage() - Create GIVE message (GUID-based)
-- ============================================================================
-- @param targetName: Player name to receive item
-- @param itemGuid: Item GUID for lookup in synced database
-- @param customMessage: Optional custom message shown in popup
-- @param customText: Optional instance-specific text (v0.1.1)
-- @param customNumber: Optional instance-specific number (v0.1.1)
-- @returns: Message string
--
-- FORMAT v0.1.1: "GIVE^playerName^itemGuid^customMessage^customText^customNumber"
-- EXAMPLE: "GIVE^Malganis^1735056789-12345-a3f2^You found this item!^Sealed by magic^3"
-- ============================================================================
local function CreateGiveMessage(targetName, itemGuid, customMessage, customText, customNumber)
    if not targetName or not itemGuid then
        return nil
    end

    local msg = customMessage or ""
    local cText = customText or ""
    local cNum = tostring(customNumber or 0)
    return MESSAGE_TYPES.GIVE .. MESSAGE_DELIMITER .. targetName .. MESSAGE_DELIMITER .. itemGuid .. MESSAGE_DELIMITER .. msg .. MESSAGE_DELIMITER .. cText .. MESSAGE_DELIMITER .. cNum
end

-- ============================================================================
-- CreateTradeMessage() - Create TRADE message (GUID-based)
-- ============================================================================
-- @param targetName: Player name to trade to
-- @param itemGuid: Item GUID for lookup
-- @returns: Message string
--
-- FORMAT: "TRADE^playerName^itemGuid"
-- ============================================================================
local function CreateTradeMessage(targetName, itemGuid)
    if not targetName or not itemGuid then
        return nil
    end

    return MESSAGE_TYPES.TRADE .. MESSAGE_DELIMITER .. targetName .. MESSAGE_DELIMITER .. itemGuid
end

-- ============================================================================
-- CreateShowMessage() - Create SHOW message (GUID-based)
-- ============================================================================
-- @param targetName: Player name to show to
-- @param itemGuid: Item GUID for lookup
-- @returns: Message string
--
-- FORMAT: "SHOW^playerName^itemGuid"
-- ============================================================================
local function CreateShowMessage(targetName, itemGuid)
    if not targetName or not itemGuid then
        return nil
    end

    return MESSAGE_TYPES.SHOW .. MESSAGE_DELIMITER .. targetName .. MESSAGE_DELIMITER .. itemGuid
end

-- ============================================================================
-- RESPONSE MESSAGE FUNCTIONS
-- ============================================================================

-- ============================================================================
-- CreateGiveAcceptMessage() - Player accepted GIVE
-- ============================================================================
-- @param gmName: GM who sent the item
-- @param playerName: Player who accepted (usually self)
-- @param itemName: Item name for logging
-- @returns: Base64-encoded message string
--
-- FORMAT: "GIVE_ACCEPT^gmName^playerName^itemName"
-- NOTE: Base64-encoded for backward compatibility
-- ============================================================================
local function CreateGiveAcceptMessage(gmName, playerName, itemName)
    if not gmName or not playerName or not itemName then
        return nil
    end

    local rawData = MESSAGE_TYPES.GIVE_ACCEPT .. MESSAGE_DELIMITER .. gmName .. MESSAGE_DELIMITER .. playerName .. MESSAGE_DELIMITER .. itemName
    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- CreateGiveRejectMessage() - Player declined GIVE
-- ============================================================================
-- @param gmName: GM who sent the item
-- @param playerName: Player who declined (usually self)
-- @param itemName: Item name for logging
-- @returns: Base64-encoded message string
--
-- FORMAT: "GIVE_REJECT^gmName^playerName^itemName"
-- ============================================================================
local function CreateGiveRejectMessage(gmName, playerName, itemName)
    if not gmName or not playerName or not itemName then
        return nil
    end

    local rawData = MESSAGE_TYPES.GIVE_REJECT .. MESSAGE_DELIMITER .. gmName .. MESSAGE_DELIMITER .. playerName .. MESSAGE_DELIMITER .. itemName
    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- CreateTradeAcceptMessage() - Player accepted TRADE
-- ============================================================================
-- @param senderName: Player who sent the trade
-- @param receiverName: Player who accepted (usually self)
-- @param itemName: Item name for logging
-- @returns: Base64-encoded message string
--
-- FORMAT: "TRADE_ACCEPT^senderName^receiverName^itemName"
-- ============================================================================
local function CreateTradeAcceptMessage(senderName, receiverName, itemName)
    if not senderName or not receiverName or not itemName then
        return nil
    end

    local rawData = MESSAGE_TYPES.TRADE_ACCEPT .. MESSAGE_DELIMITER .. senderName .. MESSAGE_DELIMITER .. receiverName .. MESSAGE_DELIMITER .. itemName
    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- CreateTradeRejectMessage() - Player declined TRADE
-- ============================================================================
-- @param senderName: Player who sent the trade
-- @param receiverName: Player who declined (usually self)
-- @param itemName: Item name for logging
-- @returns: Base64-encoded message string
--
-- FORMAT: "TRADE_REJECT^senderName^receiverName^itemName"
-- ============================================================================
local function CreateTradeRejectMessage(senderName, receiverName, itemName)
    if not senderName or not receiverName or not itemName then
        return nil
    end

    local rawData = MESSAGE_TYPES.TRADE_REJECT .. MESSAGE_DELIMITER .. senderName .. MESSAGE_DELIMITER .. receiverName .. MESSAGE_DELIMITER .. itemName
    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- CreateShowRejectMessage() - Player closed SHOW preview
-- ============================================================================
-- @param senderName: Player who showed the item
-- @param receiverName: Player who rejected (usually self)
-- @param itemName: Item name for logging
-- @returns: Base64-encoded message string
--
-- FORMAT: "SHOW_REJECT^senderName^receiverName^itemName"
-- ============================================================================
local function CreateShowRejectMessage(senderName, receiverName, itemName)
    if not senderName or not receiverName or not itemName then
        return nil
    end

    local rawData = MESSAGE_TYPES.SHOW_REJECT .. MESSAGE_DELIMITER .. senderName .. MESSAGE_DELIMITER .. receiverName .. MESSAGE_DELIMITER .. itemName
    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- ACTION EXECUTION MESSAGES
-- ============================================================================

-- ============================================================================
-- CreateActionExecuteMessage() - Player executes action on item
-- ============================================================================
-- @param playerName: Player executing the action
-- @param itemGuid: GUID of item with action
-- @param actionId: ID of action to execute
-- @param params: Optional parameters (will be encoded as JSON-like string)
-- @returns: Message string
--
-- FORMAT: "ACTION_EXECUTE^playerName^itemGuid^actionId^paramsString"
-- EXAMPLE: "ACTION_EXECUTE^Malganis^1735-123-abc^write_scroll^newContent=Hello"
--
-- NOTE: Params are encoded as key=value&key2=value2
-- ============================================================================
local function CreateActionExecuteMessage(playerName, itemGuid, actionId, params)
    if not playerName or not itemGuid or not actionId then
        return nil
    end

    -- Encode params as key=value pairs
    local paramsStr = ""
    if params then
        local first = true
        for key, value in pairs(params) do
            if not first then
                paramsStr = paramsStr .. "&"
            end
            -- Simple encoding (assume no & or = in values for now)
            paramsStr = paramsStr .. tostring(key) .. "=" .. tostring(value)
            first = false
        end
    end

    return MESSAGE_TYPES.ACTION_EXECUTE .. MESSAGE_DELIMITER ..
           playerName .. MESSAGE_DELIMITER ..
           itemGuid .. MESSAGE_DELIMITER ..
           actionId .. MESSAGE_DELIMITER ..
           paramsStr
end

-- ============================================================================
-- CreateActionResultMessage() - Send action result back to player
-- ============================================================================
-- @param playerName: Player who executed action
-- @param itemGuid: GUID of item
-- @param actionId: ID of action executed
-- @param result: Result code (SUCCESS, FAILURE, etc.)
-- @param message: Result message
-- @returns: Base64-encoded message string
--
-- FORMAT: "ACTION_RESULT^playerName^itemGuid^actionId^result^message"
-- ============================================================================
local function CreateActionResultMessage(playerName, itemGuid, actionId, result, message)
    if not playerName or not itemGuid or not actionId or not result then
        return nil
    end

    local rawData = MESSAGE_TYPES.ACTION_RESULT .. MESSAGE_DELIMITER ..
                    playerName .. MESSAGE_DELIMITER ..
                    itemGuid .. MESSAGE_DELIMITER ..
                    actionId .. MESSAGE_DELIMITER ..
                    result .. MESSAGE_DELIMITER ..
                    (message or "")

    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- NOTE: DATABASE SYNC MESSAGE CREATION
-- ============================================================================
-- DB sync message creation is handled by object-database.lua:
--   - CreateSyncMessageChunks() - Creates DB_SYNC_START/CHUNK/END messages
--   - ReassembleChunkedSync() - Reassembles received chunks
--
-- messaging.lua only provides MESSAGE_TYPES constants for parsing received
-- DB sync messages. The actual creation logic stays in object-database.lua
-- since it's tightly coupled with database serialization and chunking.
-- ============================================================================

-- ============================================================================
-- MESSAGE PARSING FUNCTIONS
-- ============================================================================

-- ============================================================================
-- ParseMessage() - Parse message and determine type
-- ============================================================================
-- @param message: Message string (already decoded if needed)
-- @returns: messageType (string), parts (array)
--
-- BEHAVIOR:
--   - Automatically detects if message is Base64 encoded
--   - Decodes if needed (for backward compatibility with old clients)
--   - Parses caret-delimited fields
--   - Returns message type and all parts
--
-- MESSAGE TYPES:
--   - GIVE^playerName^itemGuid^customMessage
--   - TRADE^playerName^itemGuid
--   - SHOW^playerName^itemGuid
--   - GIVE_ACCEPT^gmName^playerName^itemName (Base64)
--   - GIVE_REJECT^gmName^playerName^itemName (Base64)
--   - TRADE_ACCEPT^playerName^playerName^itemName (Base64)
--   - TRADE_REJECT^playerName^playerName^itemName (Base64)
--   - SHOW_REJECT^senderName^receiverName^itemName (Base64)
--   - DB_SYNC_START^messageId^databaseId^databaseName^version^checksum^totalSize
--   - DB_SYNC_CHUNK^messageId^chunkIndex^totalChunks^chunkData
--   - DB_SYNC_END^messageId
--
-- @returns: messageType, parts table
-- ============================================================================
local function ParseMessage(message)
    if not message or message == "" then
        return nil, {}
    end

    -- Check if message starts with known protocol commands (plain text)
    -- If not, it might be Base64 encoded (backward compatibility)
    local needsDecode = true
    for _, msgType in pairs(MESSAGE_TYPES) do
        if string.find(message, "^" .. msgType) then
            needsDecode = false
            break
        end
    end

    -- Decode if needed
    local decodedMessage = message
    if needsDecode then
        -- Try to decode as Base64
        local decoded = encoding.Base64Decode(message)
        if decoded and string.len(decoded) > 0 then
            decodedMessage = decoded
        end
    end

    -- Parse caret-delimited fields
    local parts = ParseCaretDelimited(decodedMessage)
    if table.getn(parts) == 0 then
        return nil, {}
    end

    local messageType = parts[1]
    return messageType, parts
end

-- ============================================================================
-- SEND FUNCTIONS - Complete message sending (create + send)
-- ============================================================================
-- These functions encapsulate the entire messaging flow so client code
-- only needs to call one function without touching SendAddonMessage directly

local function SendGiveMessage(targetName, itemGuid, customMessage, customText, customNumber)
    local message = CreateGiveMessage(targetName, itemGuid, customMessage, customText, customNumber)
    if not message then return false end

    local distribution = GetDistribution(targetName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- Player-to-player TRADE: send full item data (receiver doesn't have sender's inventory)
local function SendTradeMessage(targetName, item)
    if not targetName or not item then return false end

    -- Format v0.1.1: TRADE^targetName^objectGuid^customText^customNumber
    local message = string.format("TRADE^%s^%s^%s^%s",
        targetName,
        item.guid or "",
        item.customText or "",
        tostring(item.customNumber or 0))

    local distribution = GetDistribution(targetName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- Player-to-player SHOW: send full item data (receiver doesn't have sender's inventory)
local function SendShowMessage(targetName, item)
    if not targetName or not item then return false end

    -- Format v0.1.1: SHOW^targetName^objectGuid^customText^customNumber
    local message = string.format("SHOW^%s^%s^%s^%s",
        targetName,
        item.guid or "",
        item.customText or "",
        tostring(item.customNumber or 0))

    local distribution = GetDistribution(targetName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendGiveAcceptMessage(gmName, playerName, itemName)
    local message = CreateGiveAcceptMessage(gmName, playerName, itemName)
    if not message then return false end

    local distribution = GetDistribution(gmName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendGiveRejectMessage(gmName, playerName, itemName)
    local message = CreateGiveRejectMessage(gmName, playerName, itemName)
    if not message then return false end

    local distribution = GetDistribution(gmName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendTradeAcceptMessage(senderName, receiverName, itemName)
    local message = CreateTradeAcceptMessage(senderName, receiverName, itemName)
    if not message then return false end

    local distribution = GetDistribution(senderName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendTradeRejectMessage(senderName, receiverName, itemName)
    local message = CreateTradeRejectMessage(senderName, receiverName, itemName)
    if not message then return false end

    local distribution = GetDistribution(senderName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendShowRejectMessage(senderName, receiverName, itemName)
    local message = CreateShowRejectMessage(senderName, receiverName, itemName)
    if not message then return false end

    local distribution = GetDistribution(senderName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- Action execution messages
local function SendActionExecuteMessage(playerName, itemGuid, actionId, params)
    local message = CreateActionExecuteMessage(playerName, itemGuid, actionId, params)
    if not message then return false end

    local distribution = GetDistribution(playerName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendActionResultMessage(playerName, itemGuid, actionId, result, resultMessage)
    local message = CreateActionResultMessage(playerName, itemGuid, actionId, result, resultMessage)
    if not message then return false end

    local distribution = GetDistribution(playerName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- ============================================================================
-- SendRaidWarningMessage - Send raid warning request to GM
-- ============================================================================
-- @param playerName: Player requesting the warning
-- @param warningMessage: The message to display
-- @returns: success boolean
--
-- FORMAT: "RAID_WARNING^playerName^message"
-- EXAMPLE: "RAID_WARNING^Gremnor^The ancient seal breaks!"
-- ============================================================================
local function SendRaidWarningMessage(playerName, warningMessage)
    if not playerName or not warningMessage then
        return false
    end

    local message = MESSAGE_TYPES.RAID_WARNING .. MESSAGE_DELIMITER ..
                   playerName .. MESSAGE_DELIMITER ..
                   warningMessage

    -- Send to RAID channel (GM should be in raid)
    SendAddonMessage(ADDON_PREFIX, message, "RAID")
    return true
end

-- ============================================================================
-- EXPORT FUNCTIONS
-- ============================================================================

function RequireMessaging()
    return {
        -- Constants
        ADDON_PREFIX = ADDON_PREFIX,
        MESSAGE_DELIMITER = MESSAGE_DELIMITER,
        MESSAGE_TYPES = MESSAGE_TYPES,

        -- Distribution
        GetDistribution = GetDistribution,

        -- SEND functions (complete flow: create + send)
        SendGiveMessage = SendGiveMessage,
        SendTradeMessage = SendTradeMessage,
        SendShowMessage = SendShowMessage,
        SendGiveAcceptMessage = SendGiveAcceptMessage,
        SendGiveRejectMessage = SendGiveRejectMessage,
        SendTradeAcceptMessage = SendTradeAcceptMessage,
        SendTradeRejectMessage = SendTradeRejectMessage,
        SendShowRejectMessage = SendShowRejectMessage,

        -- CREATE functions (for advanced use, testing)
        CreateGiveMessage = CreateGiveMessage,
        CreateTradeMessage = CreateTradeMessage,
        CreateShowMessage = CreateShowMessage,

        -- Response messages (Player -> GM)
        CreateGiveAcceptMessage = CreateGiveAcceptMessage,
        CreateGiveRejectMessage = CreateGiveRejectMessage,
        CreateTradeAcceptMessage = CreateTradeAcceptMessage,
        CreateTradeRejectMessage = CreateTradeRejectMessage,
        CreateShowRejectMessage = CreateShowRejectMessage,

        -- Action messages
        CreateActionExecuteMessage = CreateActionExecuteMessage,
        CreateActionResultMessage = CreateActionResultMessage,
        SendActionExecuteMessage = SendActionExecuteMessage,
        SendActionResultMessage = SendActionResultMessage,
        SendRaidWarningMessage = SendRaidWarningMessage,

        -- NOTE: DB sync message creation is in object-database.lua
        -- (CreateSyncMessageChunks, ReassembleChunkedSync)

        -- Parsing
        ParseMessage = ParseMessage,
        ParseCaretDelimited = ParseCaretDelimited
    }
end
