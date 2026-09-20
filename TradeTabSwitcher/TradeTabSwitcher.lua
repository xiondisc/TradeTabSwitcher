local addon = CreateFrame("Frame")
local AceGUI = LibStub("AceGUI-3.0")
local AceConsole = LibStub("AceConsole-3.0")
AceConsole:Embed(addon)

local state = {
    hasTradeAccess = false,
    manualOverride = false,
    autoSwitchedToTrade = false,
    previousFrame = nil,
    tradeFrame = nil,
    lastAutoSwitchAt = 0,
    isAutoSelecting = false,
    suppressDockSelectionHook = false,
    pendingEvaluations = {},
    userSelectingTab = false,
    debugLog = {},
    settingsWindow = nil,
    settingsGroup = nil,
    debugColumn = nil,
    debugGroup = nil,
    debugText = nil,
    enabledControl = nil,
    tabNameControl = nil,
    pendingTabName = nil,
    refreshingDebug = false,
}

local cancelScheduledEvaluation
local resetTransientState
local restorePreviousSelection
local scheduleEvaluation

local defaults = {
    enabled = true,
    tradeTabName = "Trade",
}

local MAX_DEBUG_ENTRIES = 200

local function refreshDebugWindow()
    if state.debugText then
        local scrollFrame = state.debugText.scrollFrame
        local currentOffset = scrollFrame:GetVerticalScroll()
        local maximumOffset = scrollFrame:GetVerticalScrollRange()
        local wasAtBottom = currentOffset >= maximumOffset - 1
        state.refreshingDebug = true
        state.debugText:SetText(table.concat(state.debugLog, "\n"))
        state.refreshingDebug = false
        scrollFrame:SetVerticalScroll(wasAtBottom and 999999 or currentOffset)
    end
end

local function logMessage(message)
    local timestamp = date and date("%I:%M:%S") or "??:??:??"
    table.insert(state.debugLog, timestamp .. " " .. tostring(message))
    while #state.debugLog > MAX_DEBUG_ENTRIES do
        table.remove(state.debugLog, 1)
    end
    refreshDebugWindow()
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize(text)
    return trim(text):lower()
end

local function getSettings()
    return TradeTabSwitcherDB or defaults
end

local function ensureSettings()
    if type(TradeTabSwitcherDB) ~= "table" then
        TradeTabSwitcherDB = {}
    end

    for key, value in pairs(defaults) do
        if TradeTabSwitcherDB[key] == nil then
            TradeTabSwitcherDB[key] = value
        end
    end
end

local function getSelectedDockFrame()
    return FCFDock_GetSelectedWindow(GENERAL_CHAT_DOCK)
end

local function getChatWindowInfo(frame)
    if not frame or not GetChatWindowInfo or not frame.GetID then
        return nil, nil
    end

    local ok, name = pcall(
        GetChatWindowInfo,
        frame:GetID()
    )
    if not ok then
        return nil, nil
    end

    return name
end

local function saveWindowSettings()
    local oldTabName = TradeTabSwitcherDB.tradeTabName
    if state.pendingTabName and state.pendingTabName ~= "" then
        TradeTabSwitcherDB.tradeTabName = state.pendingTabName
    end
    if oldTabName ~= TradeTabSwitcherDB.tradeTabName then
        resetTransientState()
        if TradeTabSwitcherDB.enabled then
            scheduleEvaluation(0)
        end
    end
end

local function updateWindowLayout()
    if not state.settingsWindow then
        return
    end

    local contentWidth = state.settingsWindow.content:GetWidth() or 466
    local contentHeight = state.settingsWindow.content:GetHeight() or 440
    local settingsWidth = 230
    local debugWidth = math.max(220, contentWidth - settingsWidth - 12)
    state.settingsGroup:SetWidth(settingsWidth)
    state.debugColumn:SetWidth(debugWidth)
    state.settingsGroup:SetHeight(contentHeight)
    state.debugColumn:SetHeight(contentHeight)
    state.debugGroup:SetHeight(contentHeight)
    state.settingsWindow:DoLayout()
    refreshDebugWindow()
end

local function resetWindowDefaults()
    state.pendingTabName = defaults.tradeTabName
    state.tabNameControl:SetText(state.pendingTabName)
    saveWindowSettings()
    updateWindowLayout()
end

local function openSettingsWindow()
    if not state.settingsWindow then
        state.pendingTabName = getSettings().tradeTabName

        state.settingsWindow = AceGUI:Create("Frame")
        state.settingsWindow:SetTitle("Trade Tab Switcher")
        state.settingsWindow:SetStatusText("Made by Xion :)")
        state.settingsWindow.statusbg:ClearAllPoints()
        state.settingsWindow.statusbg:SetPoint("BOTTOMLEFT", 15, 15)
        state.settingsWindow.statusbg:SetPoint("BOTTOMRIGHT", -15, 15)
        state.settingsWindow:SetLayout("Flow")
        state.settingsWindow:SetWidth(650)
        state.settingsWindow:SetHeight(400)
        state.settingsWindow:EnableResize(false)
        state.settingsWindow:SetCallback("OnClose", function(widget)
            saveWindowSettings()
            AceGUI:Release(widget)
            state.settingsWindow = nil
            state.settingsGroup = nil
            state.debugColumn = nil
            state.debugGroup = nil
            state.debugText = nil
        end)
        state.settingsWindow.frame:HookScript("OnSizeChanged", function()
            if state.settingsWindow then
                updateWindowLayout()
            end
        end)

        for _, child in ipairs({ state.settingsWindow.frame:GetChildren() }) do
            if child.GetText then
                local childText = child:GetText()
                if childText and childText == (_G.CLOSE or "Close") then
                    child:Hide()
                end
            end
        end

        local closeButton = CreateFrame("Button", nil, state.settingsWindow.frame, "UIPanelCloseButton")
        closeButton:SetPoint("TOPRIGHT", -6, -6)
        closeButton:SetScript("OnClick", function()
            state.settingsWindow:Hide()
        end)

        state.settingsGroup = AceGUI:Create("SimpleGroup")
        state.settingsGroup:SetLayout("List")
            state.settingsGroup:SetWidth(230)
        state.settingsGroup:SetHeight(440)
        state.settingsWindow:AddChild(state.settingsGroup)

        state.enabledControl = AceGUI:Create("CheckBox")
        state.enabledControl:SetLabel("Enable")
        state.enabledControl:SetValue(getSettings().enabled == true)
        state.enabledControl:SetCallback("OnValueChanged", function(_, _, value)
            TradeTabSwitcherDB.enabled = value == true
            if TradeTabSwitcherDB.enabled then
                scheduleEvaluation(0)
            else
                cancelScheduledEvaluation()
                if state.autoSwitchedToTrade or state.previousFrame then
                    restorePreviousSelection()
                end
                resetTransientState()
            end
        end)
        state.settingsGroup:AddChild(state.enabledControl)

        state.tabNameControl = AceGUI:Create("EditBox")
        state.tabNameControl:SetLabel("Chat Tab Name:")
        state.tabNameControl:SetText(state.pendingTabName)
        state.tabNameControl:SetCallback("OnTextChanged", function(_, _, value)
            state.pendingTabName = trim(value)
        end)
        state.tabNameControl:SetCallback("OnEnterPressed", function(_, _, value)
            local tabName = trim(value)
            if tabName ~= "" then
                state.pendingTabName = tabName
                saveWindowSettings()
            end
            return false
        end)
        state.settingsGroup:AddChild(state.tabNameControl)

        local defaultsButton = AceGUI:Create("Button")
        defaultsButton:SetText("Defaults")
        defaultsButton:SetCallback("OnClick", resetWindowDefaults)
        state.settingsGroup:AddChild(defaultsButton)

        state.debugColumn = AceGUI:Create("SimpleGroup")
        state.debugColumn:SetLayout("List")
            state.debugColumn:SetWidth(400)
        state.debugColumn:SetHeight(440)
        state.settingsWindow:AddChild(state.debugColumn)

        state.debugGroup = AceGUI:Create("SimpleGroup")
        state.debugGroup:SetLayout("Fill")
            state.debugGroup:SetFullWidth(true)
        state.debugGroup:SetHeight(398)
        state.debugColumn:AddChild(state.debugGroup)

        state.debugText = AceGUI:Create("MultiLineEditBox")
        state.debugText:SetLabel("Events:")
        state.debugText:SetNumLines(24)
        state.debugText:DisableButton(true)
        state.debugText.scrollBG:SetBackdropColor(0, 0, 0, 0)
        state.debugText:SetCallback("OnTextChanged", function()
            if not state.refreshingDebug then
                refreshDebugWindow()
            end
        end)
        state.debugGroup:AddChild(state.debugText)
    end

    state.enabledControl:SetValue(getSettings().enabled == true)
    state.tabNameControl:SetText(getSettings().tradeTabName)
    state.pendingTabName = getSettings().tradeTabName
    state.settingsWindow:Show()
    updateWindowLayout()
end

local function isSelectableFrame(frame)
    if not frame or not GENERAL_CHAT_DOCK then
        return false
    end

    for _, dockedFrame in ipairs(FCFDock_GetChatFrames(GENERAL_CHAT_DOCK)) do
        if dockedFrame == frame then
            return true
        end
    end

    return false
end

local function normalizeTabName(tabName)
    return normalize(tabName):gsub("%s+tab$", "")
end

local function getTabText(frame)
    if not frame or not frame.GetName then
        return nil
    end

    local name = getChatWindowInfo(frame)
    if type(name) == "string" and name ~= "" then
        return name
    end

    local tab = _G[frame:GetName() .. "Tab"]
    if tab and tab.GetText then
        return tab:GetText()
    end

    return nil
end

local function findFrameByTabName(tabName)
    local desiredName = normalizeTabName(tabName)
    if desiredName == "" then
        return nil
    end

    for _, frame in ipairs(FCFDock_GetChatFrames(GENERAL_CHAT_DOCK)) do
        if isSelectableFrame(frame) and normalizeTabName(getTabText(frame)) == desiredName then
            return frame
        end
    end

    return nil
end

local function getDockedTabNames()
    local names = {}
    for _, frame in ipairs(FCFDock_GetChatFrames(GENERAL_CHAT_DOCK)) do
        table.insert(names, getTabText(frame) or frame:GetName())
    end
    return table.concat(names, ", ")
end

local function getFallbackFrame()
    local generalFrame = findFrameByTabName(_G.GENERAL or "General")
    if generalFrame and generalFrame ~= state.tradeFrame then
        return generalFrame
    end

    for _, frame in ipairs(FCFDock_GetChatFrames(GENERAL_CHAT_DOCK)) do
        if frame ~= state.tradeFrame then
            return frame
        end
    end

    return nil
end

local function getReturnFrame()
    if isSelectableFrame(state.previousFrame) and state.previousFrame ~= state.tradeFrame then
        return state.previousFrame
    end

    return getFallbackFrame()
end

local function isChatEditActive()
    return ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() ~= nil
end

local function getTradeChannelName()
    return _G.TRADE or "Trade"
end

local function normalizeChannelName(channelName)
    if type(channelName) ~= "string" then
        return channelName
    end

    return normalize(
        channelName
            :gsub("|c%x%x%x%x%x%x%x%x", "")
            :gsub("|r", "")
            :gsub("%[(.-)%]", "%1")
            :gsub("^%d+%.%s*", "")
    )
end

local function hasTradeChannelAccess()
    local tradeChannelName = normalize(getTradeChannelName())

    if not GetChannelList then
        return false
    end

    local channels = { GetChannelList() }
    local prefix = tradeChannelName .. " -"

    for index = 1, #channels, 3 do
        local channelId = channels[index]
        local channelName = normalizeChannelName(channels[index + 1])
        if type(channelId) == "number" and channelId > 0 and type(channelName) == "string" and not channels[index + 2] then
            if channelName == tradeChannelName or channelName:find(prefix, 1, true) == 1 then
                return true
            end
        end
    end

    return false
end

scheduleEvaluation = function(delaySeconds)
    if not GetTime then
        return
    end

    local runAt = GetTime() + math.max(0, delaySeconds or 0)
    for _, scheduledAt in ipairs(state.pendingEvaluations) do
        if math.abs(scheduledAt - runAt) < 0.001 then
            return
        end
    end

    table.insert(state.pendingEvaluations, runAt)

    addon:SetScript("OnUpdate", function(self)
        if #state.pendingEvaluations == 0 then
            self:SetScript("OnUpdate", nil)
            return
        end

        local now = GetTime()
        local nextIndex
        local nextRunAt
        for index, scheduledAt in ipairs(state.pendingEvaluations) do
            if not nextRunAt or scheduledAt < nextRunAt then
                nextIndex = index
                nextRunAt = scheduledAt
            end
        end

        if not nextRunAt or now < nextRunAt then
            return
        end

        table.remove(state.pendingEvaluations, nextIndex)
        if #state.pendingEvaluations == 0 then
            self:SetScript("OnUpdate", nil)
        end
        addon:EvaluateState()
    end)
end

cancelScheduledEvaluation = function()
    state.pendingEvaluations = {}
    addon:SetScript("OnUpdate", nil)
end

local function scheduleSettlingRechecks()
    scheduleEvaluation(0.5)
    scheduleEvaluation(3)
end

local function selectChatFrame(frame, recordCooldown)
    if not isSelectableFrame(frame) or not FCFDock_SelectWindow or not GENERAL_CHAT_DOCK then
        return false
    end

    if recordCooldown and GetTime then
        state.lastAutoSwitchAt = GetTime()
    end

    state.isAutoSelecting = true
    state.suppressDockSelectionHook = true
    local ok, errorMessage = pcall(FCFDock_SelectWindow, GENERAL_CHAT_DOCK, frame)
    if not ok then
        state.isAutoSelecting = false
        state.suppressDockSelectionHook = false
        logMessage("ERROR selecting chat frame: " .. tostring(errorMessage))
        return false
    end

    local wasSelected = getSelectedDockFrame() == frame
    state.isAutoSelecting = false
    state.suppressDockSelectionHook = false

    if wasSelected then
        return true
    end

    return false
end

local function getSwitchCooldownRemaining()
    if not GetTime or state.lastAutoSwitchAt <= 0 then
        return 0
    end

    local remaining = 1 - (GetTime() - state.lastAutoSwitchAt)
    return remaining > 0 and remaining or 0
end

local function clearAutoSwitchState()
    state.autoSwitchedToTrade = false
    state.previousFrame = nil
    state.manualOverride = false
end

resetTransientState = function()
    clearAutoSwitchState()
    state.hasTradeAccess = false
    state.tradeFrame = nil
    state.lastAutoSwitchAt = 0
end

restorePreviousSelection = function()
    local returnFrame = getReturnFrame()
    if not returnFrame then
        clearAutoSwitchState()
        return false
    end

    if getSelectedDockFrame() == returnFrame then
        clearAutoSwitchState()
        return true
    end

    if selectChatFrame(returnFrame, false) then
        clearAutoSwitchState()
        return true
    end

    return false
end

function addon:EvaluateState()
    if not TradeTabSwitcherDB or not TradeTabSwitcherDB.enabled then
        cancelScheduledEvaluation()
        return
    end

    local hadTradeAccess = state.hasTradeAccess
    local hasTradeAccess = hasTradeChannelAccess()

    state.hasTradeAccess = hasTradeAccess
    state.tradeFrame = findFrameByTabName(getSettings().tradeTabName)

    if hadTradeAccess ~= hasTradeAccess then
        logMessage(string.format("Trade access changed: %s -> %s", tostring(hadTradeAccess), tostring(hasTradeAccess)))
    end

    if not hadTradeAccess and hasTradeAccess then
        state.manualOverride = false
    end

    if hasTradeAccess then
        if state.manualOverride then
            logMessage("Skipping Trade selection: manual override is active")
            return
        end

        if not state.tradeFrame then
            logMessage(string.format(
                "Skipping Trade selection: tab %q not found among docked tabs [%s]",
                tostring(getSettings().tradeTabName),
                getDockedTabNames()
            ))
            return
        end

        if isChatEditActive() then
            scheduleEvaluation(1)
            return
        end

        local cooldownRemaining = getSwitchCooldownRemaining()
        if cooldownRemaining > 0 then
            return
        end

        local selectedFrame = getSelectedDockFrame()
        if selectedFrame == state.tradeFrame then
            logMessage("Trade tab is already selected")
            return
        end

        if selectedFrame and selectedFrame ~= state.tradeFrame then
            state.previousFrame = selectedFrame
        end

        if selectChatFrame(state.tradeFrame, true) then
            state.manualOverride = false
            state.autoSwitchedToTrade = true
            logMessage("Selected Trade tab")
        else
            logMessage("Failed to select Trade tab")
        end
        return
    end

    if hadTradeAccess and not state.autoSwitchedToTrade then
        logMessage("Trade access lost; no addon-selected Trade tab to restore")
        return
    end

    if not state.autoSwitchedToTrade then
        return
    end

    local returnFrame = getReturnFrame()
    if not returnFrame then
        logMessage("Trade access lost; previous chat tab is unavailable")
        clearAutoSwitchState()
        return
    end

    if getSelectedDockFrame() == returnFrame then
        state.autoSwitchedToTrade = false
        state.manualOverride = false
        return
    end

    if selectChatFrame(returnFrame, false) then
        clearAutoSwitchState()
        logMessage("Restored previous chat tab")
    else
        logMessage("Failed to restore previous chat tab")
    end
end

function addon:HandleEvent(event, ...)
    if event == "PLAYER_LOGIN" then
        if self.isInitialized then
            return
        end

        self.isInitialized = true
        self:UnregisterEvent("PLAYER_LOGIN")
        ensureSettings()
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("ZONE_CHANGED")
        self:RegisterEvent("ZONE_CHANGED_INDOORS")
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        self:RegisterEvent("CHANNEL_UI_UPDATE")
        self:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
        self:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER")

        hooksecurefunc("FCFDock_SelectWindow", function(dock, frame)
            local currentTradeFrame = findFrameByTabName(getSettings().tradeTabName) or state.tradeFrame
            if state.isAutoSelecting or state.suppressDockSelectionHook or not state.userSelectingTab or dock ~= GENERAL_CHAT_DOCK or not hasTradeChannelAccess() or not currentTradeFrame then
                return
            end
            state.userSelectingTab = false

            state.tradeFrame = currentTradeFrame
            if frame ~= currentTradeFrame then
                state.manualOverride = true
                state.autoSwitchedToTrade = false
            end
        end)

        for _, frame in ipairs(FCFDock_GetChatFrames(GENERAL_CHAT_DOCK)) do
            local tab = _G[frame:GetName() .. "Tab"]
            if tab and tab.HookScript then
                tab:HookScript("OnMouseDown", function()
                    state.userSelectingTab = true
                end)
            end
        end

        addon:RegisterChatCommand("tradetab", openSettingsWindow)
        logMessage("Addon initialized")
        scheduleSettlingRechecks()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED_NEW_AREA" then
        logMessage(event)
        scheduleSettlingRechecks()
        return
    end

    scheduleEvaluation(0)
end

addon:SetScript("OnEvent", function(_, event, ...)
    addon:HandleEvent(event, ...)
end)
addon:RegisterEvent("PLAYER_LOGIN")
