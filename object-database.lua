-- ============================================================================
-- objectDatabase.lua - Shared database logic for RP Master and Player addons
-- ============================================================================
-- PURPOSE: Common database operations and structures used by both addons
-- ============================================================================

-- ============================================================================
-- Database Structure Definitions
-- ============================================================================

-- ============================================================================
-- GUID Generation Functions
-- ============================================================================

-- Generate a globally unique identifier for an item
-- Incorporates checksum of name to ensure uniqueness
local function GenerateGUID(name)
    local timestamp = time()  -- WoW global: Unix timestamp
    local random = math.random(10000000, 99999999)  -- 8-digit random number (existing approach)
    
    -- Create a simple checksum from the name if provided
    local checksum = ""
    if name then
        -- Simple hash function using basic string operations for Lua 5.0 compatibility
        local hash = 2166136261  -- FNV offset basis
        local prime = 16777619   -- FNV prime
        
        for i = 1, string.len(name) do
            local byte = string.byte(name, i)
            -- Manual XOR implementation without using ~ operator
            -- This is a simplified approach that should work in WoW's Lua 5.0
            hash = hash + byte * prime
            -- Keep hash within reasonable bounds to prevent overflow issues
            -- Lua 5.0: No hex literals, use decimal (2147483647 = 2^31 - 1)
            if hash > 2147483647 then
                hash = math.mod(hash, 2147483647)
            end
        end
        checksum = string.format("%08x", hash)
    end
    
    return timestamp .. "-" .. random .. (checksum ~= "" and "-" .. checksum or "")
end

-- ============================================================================
-- Base64 Encoding (for message transmission)
-- ============================================================================
-- ALGORITHM: Encodes binary data → printable ASCII (safe for addon messages)
-- INPUT: Plain text string
-- OUTPUT: Base64-encoded string (uses alphabet: A-Za-z0-9+/)
-- PADDING: Uses '=' for incomplete 3-byte groups
-- ============================================================================

local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Helper: Extract single character from base64 alphabet by index
local function base64char(index)
    return string.sub(base64_chars, index + 1, index + 1)  -- Lua 5.0: 1-indexed
end

-- ============================================================================
-- Checksum Functions
-- ============================================================================

-- Calculate a simple checksum for database consistency verification
-- This is a basic implementation - can be enhanced for better security if needed
local function CalculateDatabaseChecksum(databaseItems)
    if not databaseItems then return "" end

    -- Create a string representation of the database items
    local dbString = ""
    for id, item in pairs(databaseItems) do
        -- Serialize actions for checksum (v0.2.0: include methods)
        -- Lua 5.0: Use pairs() for robustness against hash tables
        local actionsStr = ""
        if item.actions then
            for i = 1, table.getn(item.actions) do
                local action = item.actions[i]
                actionsStr = actionsStr .. (action.id or "") .. ":" .. (action.label or "")

                -- Include methods in checksum
                if action.methods then
                    actionsStr = actionsStr .. "["
                    for j, method in pairs(action.methods) do
                        if type(j) == "number" and method.type then
                            actionsStr = actionsStr .. method.type
                        end
                    end
                    actionsStr = actionsStr .. "]"
                end
            end
        end

        dbString = dbString ..
            tostring(id) ..
            "|" .. tostring(item.name or "") ..
            "|" .. tostring(item.icon or "") ..
            "|" .. tostring(item.tooltip or "") ..
            "|" .. tostring(item.content or "") ..
            "|" .. tostring(item.guid or "") ..
            "|" .. actionsStr
    end
    
    -- Simple hash function using basic string operations for Lua 5.0 compatibility
    local hash = 2166136261  -- FNV offset basis
    local prime = 16777619   -- FNV prime
    
    for i = 1, string.len(dbString) do
        local byte = string.byte(dbString, i)
        -- Simple hash calculation without XOR operator for full WoW Lua 5.0 compatibility
        hash = hash + byte * prime
        -- Keep hash within reasonable bounds to prevent overflow issues
        -- Lua 5.0: No hex literals, use decimal (2147483647 = 2^31 - 1)
        if hash > 2147483647 then
            hash = math.mod(hash, 2147483647)
        end
    end
    
    return string.format("%08x", hash)
end

-- ============================================================================
-- Database Operations
-- ============================================================================

-- Create an object based on the ITEM_SCHEMA structure
local function CreateObject(guid, name, icon, tooltip, content, actions, contentTemplate, initialCounter, defaultHandoutText)
    -- Validate required fields
    if not name then
        error("Object creation failed: 'name' is required")
    end

    return {
        guid = guid or GenerateGUID(name),
        name = name,
        icon = icon or "",
        tooltip = tooltip or "",
        content = content or "",
        contentTemplate = contentTemplate or "",
        actions = actions or {},
        initialCounter = tonumber(initialCounter) or 0,
        defaultHandoutText = defaultHandoutText or "You found this item, check /rpplayer"
    }
end

-- Create a database with metadata based on DATABASE_METADATA structure
local function CreateDatabase(guid, name, version, checksum)
    -- Validate required fields
    if not name then
        error("Database creation failed: 'name' is required")
    end
    if not version then
        error("Database creation failed: 'version' is required")
    end
    
    return {
        guid = guid or GenerateGUID(name),
        name = name,
        version = version,
        checksum = checksum or ""
    }
end

-- Create a committed snapshot of the database with metadata
local function CreateCommittedDatabase(itemLibrary, databaseName)
    -- Create a deep copy of the item library
    local committedCopy = {}
    for id, item in pairs(itemLibrary) do
        -- Deep copy actions array (v0.2.0: include methods array)
        -- Lua 5.0: Use pairs() for robustness against hash tables
        local actionsCopy = {}
        if item.actions then
            for i = 1, table.getn(item.actions) do
                local action = item.actions[i]

                -- Deep copy methods array
                local methodsCopy = {}
                if action.methods then
                    for j = 1, table.getn(action.methods) do
                        local method = action.methods[j]
                        local methodCopy = {
                            type = method.type
                        }

                        -- Deep copy params
                        if method.params then
                            methodCopy.params = {}
                            for key, value in pairs(method.params) do
                                methodCopy.params[key] = value
                            end
                        end

                        table.insert(methodsCopy, methodCopy)
                    end
                end

                -- Deep copy conditions (v0.2.1)
                local conditionsCopy = {
                    customTextEmpty = false,
                    counterGreaterThanZero = false
                }
                if action.conditions then
                    conditionsCopy.customTextEmpty = action.conditions.customTextEmpty and true or false
                    conditionsCopy.counterGreaterThanZero = action.conditions.counterGreaterThanZero and true or false
                end

                local actionCopy = {
                    id = action.id,
                    label = action.label,
                    methods = methodsCopy,
                    conditions = conditionsCopy
                }

                table.insert(actionsCopy, actionCopy)
            end
        end

        committedCopy[id] = {
            id = item.id,
            guid = item.guid,
            name = item.name,
            icon = item.icon,
            tooltip = item.tooltip,
            content = item.content,
            contentTemplate = item.contentTemplate,  -- v0.2.0: Include contentTemplate
            actions = actionsCopy,
            initialCounter = item.initialCounter or 0
        }
    end
    
    -- Calculate checksum
    local checksum = CalculateDatabaseChecksum(committedCopy)
    
    -- Return database with metadata
    return {
        items = committedCopy,
        metadata = {
            id = string.format("%d-%d", time(), math.random(10000000, 99999999)),  -- Unique ID
            name = databaseName or "Unnamed Database",
            version = time(),
            checksum = checksum
        }
    }
end

-- Verify database integrity using checksum
local function VerifyDatabaseIntegrity(databaseItems, expectedChecksum)
    if not databaseItems or not expectedChecksum then return false end
    
    local calculatedChecksum = CalculateDatabaseChecksum(databaseItems)
    return calculatedChecksum == expectedChecksum
end

-- ============================================================================
-- Serialization/Deserialization Functions
-- ============================================================================

-- Escape special characters in strings for safe serialization
-- Lua 5.0: No string:gsub method, use string.gsub instead
local function EscapeString(str)
    if not str then return "" end

    -- Escape delimiters that we use for serialization
    -- Order matters: escape the escape character first
    local result = string.gsub(tostring(str), "\\", "\\\\")  -- Escape backslash
    result = string.gsub(result, "|~|", "\\|\\~\\|")         -- Escape field separator
    result = string.gsub(result, "%^~%^", "\\^\\~\\^")       -- Escape item separator
    result = string.gsub(result, "#~#", "\\#\\~\\#")         -- Escape database separator

    return result
end

-- Unescape special characters after deserialization
-- Lua 5.0: Use string.gsub instead of string:gsub
local function UnescapeString(str)
    if not str then return "" end

    -- Unescape in reverse order
    local result = string.gsub(str, "\\#\\~\\#", "#~#")      -- Unescape database separator
    result = string.gsub(result, "\\%^\\~\\%^", "^~^")       -- Unescape item separator
    result = string.gsub(result, "\\|\\~\\|", "|~|")         -- Unescape field separator
    result = string.gsub(result, "\\\\", "\\")               -- Unescape backslash

    return result
end

-- Serialize a single item to string format
-- Format: guid|~|name|~|icon|~|tooltip|~|content|~|actions|~|contentTemplate
local function SerializeItem(item)
    if not item then return "" end

    -- Serialize actions array (v0.2.0: multi-method support)
    -- Format: action1@~@action2@~@action3
    -- Each action: id:label:[method1_type~method1_params|method2_type~method2_params]
    -- Params: key=value&key=value
    local actionsStr = ""
    if item.actions and table.getn(item.actions) > 0 then
        for i = 1, table.getn(item.actions) do
            local action = item.actions[i]
            if i > 1 then
                actionsStr = actionsStr .. "@~@"
            end

            -- Serialize action ID and label
            local actionStr = EscapeString(action.id or "") .. ":" ..
                            EscapeString(action.label or "") .. ":"

            -- Serialize methods array (v0.2.0)
            -- Lua 5.0: Use pairs() instead of table.getn() for robustness
            -- (SavedVariables can corrupt array structure on save/load)
            local methodsStr = "["
            if action.methods then
                local methodCount = 0
                local methodsArray = {}

                -- Collect methods from table (handles both array and hash table)
                for idx, method in pairs(action.methods) do
                    if type(idx) == "number" and method.type then
                        table.insert(methodsArray, {idx = idx, method = method})
                        methodCount = methodCount + 1
                    end
                end

                -- Sort by index to preserve order
                table.sort(methodsArray, function(a, b) return a.idx < b.idx end)

                -- Serialize sorted methods
                for i = 1, table.getn(methodsArray) do
                    local method = methodsArray[i].method
                    if i > 1 then
                        methodsStr = methodsStr .. "|"
                    end

                    -- Serialize method type
                    methodsStr = methodsStr .. EscapeString(method.type or "")

                    -- Serialize params if present
                    if method.params then
                        methodsStr = methodsStr .. "~"
                        local first = true
                        for key, value in pairs(method.params) do
                            if not first then
                                methodsStr = methodsStr .. "&"
                            end
                            methodsStr = methodsStr .. EscapeString(key) .. "=" .. EscapeString(tostring(value))
                            first = false
                        end
                    end
                end
            end
            methodsStr = methodsStr .. "]"

            actionStr = actionStr .. methodsStr

            -- Serialize conditions (v0.2.1)
            -- Format: :customTextEmpty,counterGreaterThanZero
            local conditionsStr = ":"
            if action.conditions then
                if action.conditions.customTextEmpty then
                    conditionsStr = conditionsStr .. "customTextEmpty"
                end
                if action.conditions.counterGreaterThanZero then
                    if conditionsStr ~= ":" then
                        conditionsStr = conditionsStr .. ","
                    end
                    conditionsStr = conditionsStr .. "counterGreaterThanZero"
                end
            end

            actionStr = actionStr .. conditionsStr
            actionsStr = actionsStr .. actionStr
        end
    end

    local parts = {
        EscapeString(item.guid or ""),
        EscapeString(item.name or ""),
        EscapeString(item.icon or ""),
        EscapeString(item.tooltip or ""),
        EscapeString(item.content or ""),
        actionsStr,  -- Don't escape the whole actions string as it contains structure
        EscapeString(item.contentTemplate or ""),
        EscapeString(tostring(item.initialCounter or 0))
    }

    -- Lua 5.0: Manual concatenation instead of table.concat
    local result = parts[1]
    for i = 2, table.getn(parts) do
        result = result .. "|~|" .. parts[i]
    end

    return result
end

-- Deserialize a string back to an item
local function DeserializeItem(serialized)
    if not serialized or serialized == "" then return nil end

    -- Split by field separator |~|
    local parts = {}
    local current = ""
    local i = 1
    local len = string.len(serialized)

    -- Lua 5.0: Manual string parsing
    while i <= len do
        local char = string.sub(serialized, i, i)

        -- Check for field separator |~|
        if char == "|" and i + 2 <= len then
            local next3 = string.sub(serialized, i, i + 2)
            if next3 == "|~|" then
                table.insert(parts, current)
                current = ""
                i = i + 3
            else
                current = current .. char
                i = i + 1
            end
        else
            current = current .. char
            i = i + 1
        end
    end

    -- Add the last part
    if current ~= "" then
        table.insert(parts, current)
    end

    -- Lua 5.0: Use table.getn instead of #
    if table.getn(parts) < 5 then return nil end

    -- Parse actions (part 6, optional)
    local actions = {}
    if table.getn(parts) >= 6 and parts[6] ~= "" then
        -- Split actions by @~@
        local actionStrings = {}
        local current = ""
        local i = 1
        local len = string.len(parts[6])

        while i <= len do
            local char = string.sub(parts[6], i, i)

            if char == "@" and i + 2 <= len then
                local next3 = string.sub(parts[6], i, i + 2)
                if next3 == "@~@" then
                    table.insert(actionStrings, current)
                    current = ""
                    i = i + 3
                else
                    current = current .. char
                    i = i + 1
                end
            else
                current = current .. char
                i = i + 1
            end
        end

        if current ~= "" then
            table.insert(actionStrings, current)
        end

        -- Parse each action string (v0.2.0: multi-method support)
        for idx = 1, table.getn(actionStrings) do
            local actionStr = actionStrings[idx]

            -- Split by : to get id, label, methods_serialized
            local actionParts = {}
            current = ""
            i = 1
            len = string.len(actionStr)

            while i <= len do
                local char = string.sub(actionStr, i, i)
                if char == ":" then
                    table.insert(actionParts, current)
                    current = ""
                    i = i + 1
                else
                    current = current .. char
                    i = i + 1
                end
            end

            if current ~= "" then
                table.insert(actionParts, current)
            end

            if table.getn(actionParts) >= 3 then
                local action = {
                    id = UnescapeString(actionParts[1]),
                    label = UnescapeString(actionParts[2]),
                    methods = {}
                }

                -- Parse methods array (part 3): [method1_type~params|method2_type~params]
                local methodsStr = actionParts[3]
                if methodsStr and string.len(methodsStr) > 2 then
                    -- Strip [ and ]
                    methodsStr = string.sub(methodsStr, 2, string.len(methodsStr) - 1)

                    -- Split by | to get individual methods
                    local methodStrings = {}
                    current = ""
                    i = 1
                    len = string.len(methodsStr)

                    while i <= len do
                        local char = string.sub(methodsStr, i, i)
                        if char == "|" then
                            table.insert(methodStrings, current)
                            current = ""
                            i = i + 1
                        else
                            current = current .. char
                            i = i + 1
                        end
                    end

                    if current ~= "" then
                        table.insert(methodStrings, current)
                    end

                    -- Parse each method string (type~params)
                    for midx = 1, table.getn(methodStrings) do
                        local methodStr = methodStrings[midx]

                        -- Split by ~ to get type and params
                        local tildaPos = string.find(methodStr, "~")
                        local methodType = ""
                        local paramsStr = ""

                        if tildaPos then
                            methodType = string.sub(methodStr, 1, tildaPos - 1)
                            paramsStr = string.sub(methodStr, tildaPos + 1)
                        else
                            methodType = methodStr
                        end

                        local method = {
                            type = UnescapeString(methodType),
                            params = {}
                        }

                        -- Parse params if present (key=value&key=value)
                        if paramsStr and paramsStr ~= "" then
                            -- Split by & to get key=value pairs
                            local paramPairs = {}
                            current = ""
                            i = 1
                            len = string.len(paramsStr)

                            while i <= len do
                                local char = string.sub(paramsStr, i, i)
                                if char == "&" then
                                    table.insert(paramPairs, current)
                                    current = ""
                                    i = i + 1
                                else
                                    current = current .. char
                                    i = i + 1
                                end
                            end

                            if current ~= "" then
                                table.insert(paramPairs, current)
                            end

                            -- Parse each key=value pair
                            for pidx = 1, table.getn(paramPairs) do
                                local pair = paramPairs[pidx]
                                local eqPos = string.find(pair, "=")
                                if eqPos then
                                    local key = UnescapeString(string.sub(pair, 1, eqPos - 1))
                                    local value = UnescapeString(string.sub(pair, eqPos + 1))
                                    method.params[key] = value
                                end
                            end
                        end

                        table.insert(action.methods, method)
                    end
                end

                -- Parse conditions (v0.2.1) - part 4 if present
                action.conditions = {
                    customTextEmpty = false,
                    counterGreaterThanZero = false
                }
                if table.getn(actionParts) >= 4 and actionParts[4] ~= "" then
                    local conditionsStr = actionParts[4]
                    -- Parse comma-separated condition names
                    if string.find(conditionsStr, "customTextEmpty") then
                        action.conditions.customTextEmpty = true
                    end
                    if string.find(conditionsStr, "counterGreaterThanZero") then
                        action.conditions.counterGreaterThanZero = true
                    end
                end

                table.insert(actions, action)
            end
        end
    end

    return {
        guid = UnescapeString(parts[1]),
        name = UnescapeString(parts[2]),
        icon = UnescapeString(parts[3]),
        tooltip = UnescapeString(parts[4]),
        content = UnescapeString(parts[5]),
        actions = actions,
        contentTemplate = parts[7] and UnescapeString(parts[7]) or "",
        initialCounter = parts[8] and tonumber(UnescapeString(parts[8])) or 0
    }
end

-- Serialize an entire database including metadata and all items
-- Format: metadata#~#item1^~^item2^~^item3...
local function SerializeDatabase(database)
    if not database then return "" end

    -- Serialize metadata
    local metadata = database.metadata or {}
    local metadataParts = {
        EscapeString(metadata.id or ""),
        EscapeString(metadata.name or ""),
        EscapeString(tostring(metadata.version or "")),
        EscapeString(metadata.checksum or "")
    }

    -- Lua 5.0: Manual concatenation
    local metadataStr = metadataParts[1]
    for i = 2, table.getn(metadataParts) do
        metadataStr = metadataStr .. "|~|" .. metadataParts[i]
    end

    -- Serialize items
    local itemsStr = ""
    local items = database.items or {}
    local first = true

    -- Lua 5.0: pairs iteration
    for id, item in pairs(items) do
        if not first then
            itemsStr = itemsStr .. "^~^"
        end
        itemsStr = itemsStr .. SerializeItem(item)
        first = false
    end

    -- Combine metadata and items
    return metadataStr .. "#~#" .. itemsStr
end

-- Deserialize a database from string format
local function DeserializeDatabase(serialized)
    if not serialized or serialized == "" then return nil end

    -- Split into metadata and items sections by #~#
    local metadataEnd = string.find(serialized, "#~#")
    if not metadataEnd then return nil end

    local metadataStr = string.sub(serialized, 1, metadataEnd - 1)
    local itemsStr = string.sub(serialized, metadataEnd + 3)

    -- Parse metadata
    local metadataParts = {}
    local current = ""
    local i = 1
    local len = string.len(metadataStr)

    while i <= len do
        local char = string.sub(metadataStr, i, i)

        if char == "|" and i + 2 <= len then
            local next3 = string.sub(metadataStr, i, i + 2)
            if next3 == "|~|" then
                table.insert(metadataParts, current)
                current = ""
                i = i + 3
            else
                current = current .. char
                i = i + 1
            end
        else
            current = current .. char
            i = i + 1
        end
    end

    if current ~= "" then
        table.insert(metadataParts, current)
    end

    -- Lua 5.0: Use table.getn
    if table.getn(metadataParts) < 4 then return nil end

    local metadata = {
        id = UnescapeString(metadataParts[1]),
        name = UnescapeString(metadataParts[2]),
        version = tonumber(UnescapeString(metadataParts[3])) or 0,
        checksum = UnescapeString(metadataParts[4])
    }

    -- Parse items
    local items = {}
    if itemsStr ~= "" then
        -- Split items by ^~^
        local itemStrings = {}
        current = ""
        i = 1
        len = string.len(itemsStr)

        while i <= len do
            local char = string.sub(itemsStr, i, i)

            if char == "^" and i + 2 <= len then
                local next3 = string.sub(itemsStr, i, i + 2)
                if next3 == "^~^" then
                    table.insert(itemStrings, current)
                    current = ""
                    i = i + 3
                else
                    current = current .. char
                    i = i + 1
                end
            else
                current = current .. char
                i = i + 1
            end
        end

        if current ~= "" then
            table.insert(itemStrings, current)
        end

        -- Deserialize each item
        for idx = 1, table.getn(itemStrings) do
            local item = DeserializeItem(itemStrings[idx])
            if item then
                items[idx] = item
            end
        end
    end

    return {
        metadata = metadata,
        items = items
    }
end

-- Compare two checksums to determine if database needs to be sent
local function NeedsDatabaseSync(localChecksum, remoteChecksum)
    -- If no remote checksum, sync is needed
    if not remoteChecksum or remoteChecksum == "" then
        return true
    end

    -- If no local checksum, something is wrong
    if not localChecksum or localChecksum == "" then
        return false
    end

    -- Compare checksums
    return localChecksum ~= remoteChecksum
end

-- ============================================================================
-- Chunked Transmission Functions
-- ============================================================================
-- WoW 1.12 SendAddonMessage has 255 byte limit - need to chunk large messages

local CHUNK_SIZE = 200  -- Safe limit under 255 bytes

-- Split a string into chunks
local function ChunkString(str, chunkSize)
    if not str then return {} end

    local chunks = {}
    local len = string.len(str)
    local pos = 1

    while pos <= len do
        local chunk = string.sub(str, pos, pos + chunkSize - 1)
        table.insert(chunks, chunk)
        pos = pos + chunkSize
    end

    return chunks
end

-- Create chunked DB_SYNC messages
-- Returns array of messages: DB_SYNC_START, DB_SYNC_CHUNK, DB_SYNC_END
local function CreateSyncMessageChunks(committedDatabase)
    if not committedDatabase or not committedDatabase.metadata then
        return nil
    end

    local encoding = RequireEncoding()
    local meta = committedDatabase.metadata

    -- Serialize the database
    local serializedData = SerializeDatabase(committedDatabase)

    if not serializedData or serializedData == "" then
        return nil
    end

    -- Base64 encode the ENTIRE serialized data first to avoid pipe character issues
    -- The serialization uses |~| and ^~^ delimiters which WoW interprets as escape codes
    local encodedData = encoding.Base64Encode(serializedData)

    -- Generate a unique message ID for this sync operation
    local messageId = GenerateGUID("sync")

    -- Create header with metadata
    local header = "DB_SYNC_START^" ..
                   messageId .. "^" ..
                   (meta.id or "") .. "^" ..
                   (meta.name or "") .. "^" ..
                   tostring(meta.version or 0) .. "^" ..
                   (meta.checksum or "") .. "^" ..
                   tostring(string.len(encodedData))

    -- Split BASE64-ENCODED data into chunks (no pipe characters in Base64)
    local dataChunks = ChunkString(encodedData, CHUNK_SIZE)
    local totalChunks = table.getn(dataChunks)

    -- Build message array
    local messages = {}

    -- 1. Start message with metadata
    table.insert(messages, header)

    -- 2. Data chunks (already Base64 encoded, safe for SendAddonMessage)
    for i = 1, totalChunks do
        local chunkMsg = "DB_SYNC_CHUNK^" .. messageId .. "^" .. i .. "^" .. totalChunks .. "^" .. dataChunks[i]
        table.insert(messages, chunkMsg)
    end

    -- 3. End message
    local endMsg = "DB_SYNC_END^" .. messageId
    table.insert(messages, endMsg)

    return messages
end

-- Reassemble chunked database sync messages
-- Takes a table of received chunks and returns the full database
local function ReassembleChunkedSync(chunksTable)
    if not chunksTable or not chunksTable.metadata then
        return nil
    end

    -- Check if all chunks received
    if table.getn(chunksTable.chunks) ~= chunksTable.totalChunks then
        return nil  -- Not all chunks received yet
    end

    local encoding = RequireEncoding()

    -- Reassemble Base64-encoded data in order
    local reassembledEncoded = ""
    for i = 1, chunksTable.totalChunks do
        if not chunksTable.chunks[i] then
            return nil  -- Missing chunk
        end
        reassembledEncoded = reassembledEncoded .. chunksTable.chunks[i]
    end

    -- Base64 decode the reassembled data
    local reassembledDecoded = encoding.Base64Decode(reassembledEncoded)

    if not reassembledDecoded or reassembledDecoded == "" then
        return nil  -- Decode failed
    end

    -- Deserialize the database
    local database = DeserializeDatabase(reassembledDecoded)

    if not database or not database.items then
        return nil
    end

    return {
        items = database.items,
        metadata = chunksTable.metadata
    }
end

-- Prepare database for transmission (serialized string)
local function PrepareTransmission(database)
    if not database then return nil end

    return SerializeDatabase(database)
end

-- Receive and reconstruct database from transmission
local function ReceiveTransmission(serializedData)
    if not serializedData or serializedData == "" then
        return nil, "No data provided"
    end

    local database = DeserializeDatabase(serializedData)

    -- Check if deserialization failed
    if not database then
        return nil, "Failed to deserialize database"
    end

    -- Verify integrity if checksum is present
    if database.metadata and database.metadata.checksum then
        local valid = VerifyDatabaseIntegrity(database.items, database.metadata.checksum)
        if not valid then
            return nil, "Checksum verification failed"
        end
    end

    return database
end

-- ============================================================================
-- RenderItemContent - Render item content with custom text substitution
-- ============================================================================
-- PURPOSE: Pure business logic for rendering item content (NO GUI code)
-- @param guid: String - Object GUID to look up in database
-- @param customText: String - Custom text to substitute (may be nil or "")
-- @param database: Table - Database to look up object definition
-- @return String - Rendered content ready for display
-- ============================================================================
local function RenderItemContent(guid, customText, database)
    if not guid or not database or not database.items then
        return "This item has no content to read."
    end

    -- Look up object definition by GUID
    local objectDef = nil
    for _, obj in pairs(database.items) do
        if obj.guid == guid then
            objectDef = obj
            break
        end
    end

    if not objectDef then
        return "This item has no content to read."
    end

    -- Apply template substitution logic
    local displayContent = ""

    if customText and customText ~= "" then
        -- If customText is set, use contentTemplate with substitution
        if objectDef.contentTemplate and objectDef.contentTemplate ~= "" then
            -- Replace {custom-text} placeholder with actual customText
            displayContent = string.gsub(objectDef.contentTemplate, "{custom%-text}", customText)
        else
            -- No template defined, just show customText
            displayContent = customText
        end
    else
        -- No customText, use default content
        displayContent = objectDef.content or ""
    end

    if displayContent == "" then
        return "This item has no content to read."
    end

    return displayContent
end

-- ============================================================================
-- Export Functions
-- ============================================================================

function RequireObjectDatabase()

    return {
        -- Object creation
        CreateObject = CreateObject,
        CreateDatabase = CreateDatabase,

        -- GUID and checksums
        GenerateGUID = GenerateGUID,
        CalculateDatabaseChecksum = CalculateDatabaseChecksum,

        -- Database operations
        CreateCommittedDatabase = CreateCommittedDatabase,
        VerifyDatabaseIntegrity = VerifyDatabaseIntegrity,

        -- Serialization functions
        SerializeItem = SerializeItem,
        DeserializeItem = DeserializeItem,
        SerializeDatabase = SerializeDatabase,
        DeserializeDatabase = DeserializeDatabase,

        -- Transmission functions
        NeedsDatabaseSync = NeedsDatabaseSync,
        PrepareTransmission = PrepareTransmission,
        ReceiveTransmission = ReceiveTransmission,

        -- Chunked transmission functions (for 255 byte limit)
        CreateSyncMessageChunks = CreateSyncMessageChunks,
        ReassembleChunkedSync = ReassembleChunkedSync,

        -- String utility functions (exposed for testing)
        EscapeString = EscapeString,
        UnescapeString = UnescapeString,

        -- Content rendering (business logic)
        RenderItemContent = RenderItemContent
    }

end
