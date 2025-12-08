-- Core.lua - Main frame, tabs, and module registry for RPPlayer
-- Modular architecture for RP Player addon

local ADDON_NAME = "RPPlayer"
local ADDON_VERSION = "2025-12-06 15:30"

-- RPPlayerDB will be initialized in VARIABLES_LOADED event
-- (saved variables aren't available until that event fires)

-- Module registry
RP_Modules = {}
RP_CurrentTab = nil
RP_DetachedFrames = {}

-- Main frame
RPMainFrame = CreateFrame("Frame", "RPMainFrame", UIParent)
RPMainFrame:SetWidth(400)
RPMainFrame:SetHeight(450)
RPMainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
RPMainFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
RPMainFrame:SetBackdropColor(0, 0, 0, 1)
RPMainFrame:SetMovable(true)
RPMainFrame:Hide()

-- Position will be loaded in VARIABLES_LOADED event

-- Title
local title = RPMainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -15)
title:SetText("RP Player")

-- Draggable title bar
local titleBar = CreateFrame("Frame", nil, RPMainFrame)
titleBar:SetPoint("TOPLEFT", 10, -10)
titleBar:SetPoint("TOPRIGHT", -30, -10)
titleBar:SetHeight(20)
titleBar:EnableMouse(true)
titleBar:RegisterForDrag("LeftButton")
titleBar:SetScript("OnDragStart", function()
    RPMainFrame:StartMoving()
end)
titleBar:SetScript("OnDragStop", function()
    RPMainFrame:StopMovingOrSizing()
    RP_SaveWindowPosition("main", RPMainFrame)
end)

-- Close button
local closeBtn = CreateFrame("Button", nil, RPMainFrame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -5, -5)

-- Tab bar container
local tabBar = CreateFrame("Frame", "RPTabBar", RPMainFrame)
tabBar:SetPoint("TOPLEFT", 15, -35)
tabBar:SetPoint("TOPRIGHT", -15, -35)
tabBar:SetHeight(30)

-- Content container (where active tab content shows)
local contentFrame = CreateFrame("Frame", "RPContentFrame", RPMainFrame)
contentFrame:SetPoint("TOPLEFT", 15, -70)
contentFrame:SetPoint("BOTTOMRIGHT", -15, 15)

-- Tab buttons
RP_TabButtons = {}

-- Function: Register a module
function RP_RegisterModule(name, callbacks)
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] Registering module: " .. name)
    RP_Modules[name] = {
        name = name,
        createContent = callbacks.createContent,
        onShow = callbacks.onShow,
        onHide = callbacks.onHide,
        content = nil,
        tabButton = nil,
        detachButton = nil
    }
end

-- Function: Create tab button
local function CreateTabButton(moduleName, index)
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] CreateTabButton called for: " .. moduleName .. " at index " .. index)

    local tabWidth = 120
    local tabHeight = 28
    local spacing = 5

    local tab = CreateFrame("Button", "RPTab_"..moduleName, tabBar)
    tab:SetWidth(tabWidth)
    tab:SetHeight(tabHeight)
    tab:SetPoint("LEFT", (tabWidth + spacing) * (index - 1), 0)
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] Tab frame created for: " .. moduleName)

    tab:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    tab:SetBackdropColor(0.1, 0.1, 0.1, 1)

    -- Tab label
    local label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", 8, 0)
    -- Lua 5.0 doesn't support string:method() syntax, use string.method() instead
    local displayName = string.upper(string.sub(moduleName, 1, 1)) .. string.sub(moduleName, 2)
    label:SetText(displayName)

    -- Detach button (small button on right side of tab)
    local detachBtn = CreateFrame("Button", nil, tab)
    detachBtn:SetWidth(16)
    detachBtn:SetHeight(16)
    detachBtn:SetPoint("RIGHT", -4, 0)

    local detachText = detachBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detachText:SetText("^")
    detachText:SetTextColor(0.7, 0.7, 0.7)

    detachBtn:SetScript("OnClick", function()
        RP_DetachTab(moduleName)
    end)

    detachBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Detach to separate window")
        GameTooltip:Show()
    end)

    detachBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Tab click handler
    tab:SetScript("OnClick", function()
        RP_SwitchTab(moduleName)
    end)

    RP_Modules[moduleName].tabButton = tab
    RP_Modules[moduleName].detachButton = detachBtn
    RP_TabButtons[moduleName] = tab

    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] CreateTabButton completed for: " .. moduleName)
    return tab
end

-- Function: Switch to a tab
function RP_SwitchTab(tabName)
    if not RPPlayerDB then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP]|r RPPlayerDB not initialized yet", 1, 0, 0)
        return
    end

    if not RP_Modules[tabName] then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP]|r Unknown tab: "..tabName, 1, 0, 0)
        return
    end

    -- Don't switch if tab is detached
    if RPPlayerDB.preferences.detachedTabs[tabName] then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[RP]|r "..tabName.." is detached", 1, 1, 0)
        return
    end

    -- Hide current content
    if RP_CurrentTab then
        local currentModule = RP_Modules[RP_CurrentTab]
        if currentModule.content then
            currentModule.content:Hide()
        end
        if currentModule.onHide then
            currentModule.onHide()
        end
        -- Unhighlight tab
        if currentModule.tabButton then
            currentModule.tabButton:SetBackdropColor(0.1, 0.1, 0.1, 1)
        end
    end

    -- Show new content
    local module = RP_Modules[tabName]
    if not module.content then
        -- Create content on first access
        module.content = module.createContent(contentFrame)
    end

    module.content:SetParent(contentFrame)
    module.content:SetAllPoints(contentFrame)
    module.content:Show()

    if module.onShow then
        module.onShow()
    end

    -- Highlight active tab
    if module.tabButton then
        module.tabButton:SetBackdropColor(0.2, 0.2, 0.2, 1)
    end

    RP_CurrentTab = tabName
    RPPlayerDB.preferences.activeTab = tabName
end

-- Function: Detach a tab to separate window
function RP_DetachTab(tabName)
    if RPPlayerDB.preferences.detachedTabs[tabName] then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[RP]|r "..tabName.." is already detached", 1, 1, 0)
        return
    end

    local module = RP_Modules[tabName]
    if not module then return end

    -- Create content if not exists
    if not module.content then
        module.content = module.createContent(contentFrame)
    end

    -- Create detached window
    local frameName = "RP" .. string.upper(string.sub(tabName, 1, 1)) .. string.sub(tabName, 2) .. "Detached"
    local detachedFrame = CreateFrame("Frame", frameName, UIParent)
    detachedFrame:SetWidth(400)
    detachedFrame:SetHeight(450)
    detachedFrame:SetPoint("CENTER", UIParent, "CENTER", 50, 50)
    detachedFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    detachedFrame:SetBackdropColor(0, 0, 0, 1)
    detachedFrame:SetMovable(true)
    detachedFrame:SetFrameStrata("MEDIUM")

    -- Load saved position
    if RPPlayerDB.preferences.windowPositions[tabName] then
        local pos = RPPlayerDB.preferences.windowPositions[tabName]
        detachedFrame:ClearAllPoints()
        detachedFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    end

    -- Title
    local detachedTitle = detachedFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detachedTitle:SetPoint("TOP", 0, -15)
    local titleText = string.upper(string.sub(tabName, 1, 1)) .. string.sub(tabName, 2)
    detachedTitle:SetText(titleText)

    -- Draggable title bar
    local detachedTitleBar = CreateFrame("Frame", nil, detachedFrame)
    detachedTitleBar:SetPoint("TOPLEFT", 10, -10)
    detachedTitleBar:SetPoint("TOPRIGHT", -60, -10)
    detachedTitleBar:SetHeight(20)
    detachedTitleBar:EnableMouse(true)
    detachedTitleBar:RegisterForDrag("LeftButton")
    detachedTitleBar:SetScript("OnDragStart", function()
        detachedFrame:StartMoving()
    end)
    detachedTitleBar:SetScript("OnDragStop", function()
        detachedFrame:StopMovingOrSizing()
        RP_SaveWindowPosition(tabName, detachedFrame)
    end)

    -- Reattach button
    local reattachBtn = CreateFrame("Button", nil, detachedFrame, "UIPanelButtonTemplate")
    reattachBtn:SetWidth(20)
    reattachBtn:SetHeight(20)
    reattachBtn:SetPoint("TOPRIGHT", -30, -8)
    reattachBtn:SetText("v")
    reattachBtn:SetScript("OnClick", function()
        RP_ReattachTab(tabName)
    end)
    reattachBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Reattach to main window")
        GameTooltip:Show()
    end)
    reattachBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Close button
    local detachedCloseBtn = CreateFrame("Button", nil, detachedFrame, "UIPanelCloseButton")
    detachedCloseBtn:SetPoint("TOPRIGHT", -5, -5)

    -- Content container
    local detachedContent = CreateFrame("Frame", nil, detachedFrame)
    detachedContent:SetPoint("TOPLEFT", 15, -40)
    detachedContent:SetPoint("BOTTOMRIGHT", -15, 15)

    -- Move content to detached window
    module.content:SetParent(detachedContent)
    module.content:SetAllPoints(detachedContent)
    module.content:Show()

    if module.onShow then
        module.onShow()
    end

    -- Hide tab button in main window
    if module.tabButton then
        module.tabButton:Hide()
    end

    -- Save state
    RPPlayerDB.preferences.detachedTabs[tabName] = true
    RP_DetachedFrames[tabName] = detachedFrame

    -- Switch to next available tab in main window
    if RP_CurrentTab == tabName then
        local nextTab = nil
        for name, mod in pairs(RP_Modules) do
            if not RPPlayerDB.preferences.detachedTabs[name] then
                nextTab = name
                break
            end
        end
        if nextTab then
            RP_SwitchTab(nextTab)
        else
            RP_CurrentTab = nil
        end
    end

    detachedFrame:Show()
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP]|r "..tabName.." detached", 0, 1, 0)
end

-- Function: Reattach a tab to main window
function RP_ReattachTab(tabName)
    if not RPPlayerDB.preferences.detachedTabs[tabName] then
        return
    end

    local module = RP_Modules[tabName]
    local detachedFrame = RP_DetachedFrames[tabName]

    if not module or not detachedFrame then return end

    -- Move content back to main window
    module.content:SetParent(contentFrame)
    module.content:SetAllPoints(contentFrame)
    module.content:Hide()

    if module.onHide then
        module.onHide()
    end

    -- Show tab button
    if module.tabButton then
        module.tabButton:Show()
    end

    -- Destroy detached window
    detachedFrame:Hide()
    RP_DetachedFrames[tabName] = nil

    -- Save state
    RPPlayerDB.preferences.detachedTabs[tabName] = false

    -- Switch to reattached tab
    RP_SwitchTab(tabName)

    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP]|r "..tabName.." reattached", 0, 1, 0)
end

-- Function: Save window position
function RP_SaveWindowPosition(windowName, frame)
    if not RPPlayerDB or not RPPlayerDB.preferences then
        return
    end
    local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint()
    RPPlayerDB.preferences.windowPositions[windowName] = {point, relativePoint, xOfs, yOfs}
end

-- Function: Initialize modules and tabs
function RP_InitializeModules()
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] Initializing modules...")

    -- Debug: show registered modules
    local count = 0
    for name, mod in pairs(RP_Modules) do
        count = count + 1
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] Found module: " .. name)
    end
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] Total modules registered: " .. count)

    -- Module order for tabs
    local moduleOrder = {"inventory", "states", "mjchat"}

    -- Create tab buttons
    for index, moduleName in ipairs(moduleOrder) do
        if RP_Modules[moduleName] then
            DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] Creating tab for: " .. moduleName)
            CreateTabButton(moduleName, index)
        else
            DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] WARNING: Module not found: " .. moduleName)
        end
    end

    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] All tabs created, checking for detached windows...")

    -- Restore detached windows
    for tabName, isDetached in pairs(RPPlayerDB.preferences.detachedTabs) do
        if isDetached and RP_Modules[tabName] then
            RP_DetachTab(tabName)
        end
    end

    -- Switch to last active tab or first available
    local startTab = RPPlayerDB.preferences.activeTab or "inventory"
    if RPPlayerDB.preferences.detachedTabs[startTab] then
        -- Find first non-detached tab
        for name, mod in pairs(RP_Modules) do
            if not RPPlayerDB.preferences.detachedTabs[name] then
                startTab = name
                break
            end
        end
    end

    if RP_Modules[startTab] and not RPPlayerDB.preferences.detachedTabs[startTab] then
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] Switching to initial tab: " .. startTab)
        RP_SwitchTab(startTab)
    else
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] WARNING: Could not switch to tab: " .. tostring(startTab))
    end
end

-- Function: Open main interface
function RP_OpenMainFrame()
    -- Fallback: if modules haven't been initialized yet, do it now
    if not RP_CurrentTab then
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] Modules not initialized, initializing now...")

        -- Initialize RPPlayerDB if needed
        if not RPPlayerDB then
            RPPlayerDB = {
                inventory = {},
                preferences = {
                    detachedTabs = {inventory = false, states = false, mjchat = false},
                    windowPositions = {main = nil, inventory = nil, states = nil, mjchat = nil},
                    activeTab = "inventory"
                }
            }
        end

        RP_InitializeModules()
    end

    RPMainFrame:Show()
    -- Refresh active tab if exists
    if RP_CurrentTab and RP_Modules[RP_CurrentTab] and RP_Modules[RP_CurrentTab].onShow then
        RP_Modules[RP_CurrentTab].onShow()
    end
end

-- Function: Toggle main interface
function RP_ToggleMainFrame()
    if RPMainFrame:IsShown() then
        RPMainFrame:Hide()
    else
        RP_OpenMainFrame()
    end
end

-- Function: Reset all window positions
function RP_ResetPositions()
    RPPlayerDB.preferences.windowPositions = {
        main = nil,
        inventory = nil,
        states = nil,
        mjchat = nil
    }

    -- Reset main frame
    RPMainFrame:ClearAllPoints()
    RPMainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

    -- Reset detached frames
    for tabName, frame in pairs(RP_DetachedFrames) do
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 50, 50)
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP]|r All window positions reset", 0, 1, 0)
end

-- Slash commands
SLASH_RP1 = "/rp"
SlashCmdList["RP"] = function(msg)
    if msg == "reset" then
        RP_ResetPositions()
    else
        RP_ToggleMainFrame()
    end
end

-- Backward compatibility
SLASH_RPPLAYER1 = "/rpplayer"
SlashCmdList["RPPLAYER"] = function(msg)
    if msg == "reset" then
        RP_ResetPositions()
    else
        RP_ToggleMainFrame()
    end
end

-- Event frame for initialization
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("VARIABLES_LOADED")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

local variablesLoaded = false
local playerEntered = false

initFrame:SetScript("OnEvent", function(self, event)
    DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] Event received: " .. tostring(event))

    if event == "VARIABLES_LOADED" then
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] VARIABLES_LOADED fired")

        -- Initialize RPPlayerDB now that saved variables are loaded
        RPPlayerDB = RPPlayerDB or {
            inventory = {},
            preferences = {
                detachedTabs = {inventory = false, states = false, mjchat = false},
                windowPositions = {main = nil, inventory = nil, states = nil, mjchat = nil},
                activeTab = "inventory"
            }
        }

        -- Ensure preferences structure exists (backward compatibility)
        if not RPPlayerDB.preferences then
            RPPlayerDB.preferences = {
                detachedTabs = {inventory = false, states = false, mjchat = false},
                windowPositions = {main = nil, inventory = nil, states = nil, mjchat = nil},
                activeTab = "inventory"
            }
        end

        -- Load saved main frame position
        if RPPlayerDB.preferences.windowPositions.main then
            local pos = RPPlayerDB.preferences.windowPositions.main
            RPMainFrame:ClearAllPoints()
            RPMainFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        end

        variablesLoaded = true
        self:UnregisterEvent("VARIABLES_LOADED")

    elseif event == "PLAYER_ENTERING_WORLD" then
        DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] PLAYER_ENTERING_WORLD fired")

        if not variablesLoaded then
            DEFAULT_CHAT_FRAME:AddMessage("[DEBUG RP] WARNING: Variables not loaded yet!")
            return
        end

        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700[RP Player] Version: " .. ADDON_VERSION .. "|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FFFF[RP Player]|r Commands: /rp or /rpplayer", 0, 1, 1)

        -- Initialize modules after a short delay to ensure all files loaded
        initFrame.timer = 0
        initFrame:SetScript("OnUpdate", function(self, elapsed)
            self.timer = self.timer + elapsed
            if self.timer >= 0.5 then
                RP_InitializeModules()
                self:SetScript("OnUpdate", nil)
            end
        end)

        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end)
