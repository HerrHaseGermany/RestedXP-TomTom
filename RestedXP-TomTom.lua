local addonName = ...

local frame = CreateFrame("Frame")

local currentWaypointUid
local currentWaypointKey
local currentStepKey
local stepWaypointUids = {}
local stepWaypointElements = {}
local debugEnabled = false
local tick
local currentOptionsKey
local rxpHooked = false
local lastElementSignature

local defaults = {
    showWorldMap = false,
    showMinimap = false,
}

local function getConfig()
    if type(_G.RXPTT_DB) ~= "table" then
        _G.RXPTT_DB = {}
    end
    local db = _G.RXPTT_DB
    if db.showWorldMap == nil then
        db.showWorldMap = defaults.showWorldMap
    end
    if db.showMinimap == nil then
        db.showMinimap = defaults.showMinimap
    end
    return db
end

local pendingElementKey
local pendingElement
local pendingSince
local arrivedCooldownUntil
local noTargetSince

local SWITCH_STABLE_SECONDS = 1.0     -- must remain the same target for this long
local ARRIVE_DISTANCE = 15            -- yards-ish (TomTom distance), switch immediately if closer than this
local SWITCH_DISTANCE_ADVANTAGE = 10  -- require new waypoint to be this much closer to switch
local NO_TARGET_CLEAR_SECONDS = 1.0   -- avoid flicker when RXP temporarily has no waypoint

local function dbg(fmt, ...)
    if not debugEnabled then
        return
    end
    if select("#", ...) > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffd200%s:|r %s", addonName, string.format(fmt, ...)))
    else
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffd200%s:|r %s", addonName, fmt))
    end
end

local function msg(fmt, ...)
    if select("#", ...) > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffd200%s:|r %s", addonName, string.format(fmt, ...)))
    else
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffd200%s:|r %s", addonName, fmt))
    end
end

local function getRxpArrowFrame()
    local af = _G.RXPG_ARROW
    if af and type(af) == "table" and type(af.Hide) == "function" then
        return af
    end
end

local function getRxpDebugState()
    local dbg = _G.RXPTOMTOM_DEBUG
    if type(dbg) == "table" then
        return dbg
    end
end

local function isRxpArrowAllowed()
    local dbg = getRxpDebugState()
    return dbg and dbg.allowRxpArrow
end

local function ensureTomTom()
    local tt = _G.TomTom
    if type(tt) == "table" and type(tt.AddWaypoint) == "function" and type(tt.RemoveWaypoint) == "function" then
        return tt
    end
end

local function safeDisableRxpArrow()
    local arrowFrame = getRxpArrowFrame()
    if not arrowFrame then
        return
    end

    if not arrowFrame.__rxptt_hooked then
        arrowFrame.__rxptt_hooked = true

        local originalShow = arrowFrame.Show
        arrowFrame.__rxptt_originalShow = originalShow
        arrowFrame.Show = function(self, ...)
            if type(originalShow) == "function" then
                originalShow(self, ...)
            end
            if not isRxpArrowAllowed() then
                if type(self.SetAlpha) == "function" then
                    self:SetAlpha(0)
                end
            end
        end

        local originalSetShown = arrowFrame.SetShown
        arrowFrame.__rxptt_originalSetShown = originalSetShown
        arrowFrame.SetShown = function(self, shown)
            if type(originalSetShown) == "function" then
                if not isRxpArrowAllowed() then
                    originalSetShown(self, true)
                else
                    originalSetShown(self, shown)
                end
            end
            if not isRxpArrowAllowed() then
                if type(self.SetAlpha) == "function" then
                    self:SetAlpha(0)
                end
            end
        end

        arrowFrame.__rxptt_originalOnUpdate = arrowFrame:GetScript("OnUpdate")
    end

    local originalOnUpdate = arrowFrame.__rxptt_originalOnUpdate
    if originalOnUpdate then
        arrowFrame:SetScript("OnUpdate", originalOnUpdate)
    end

    if isRxpArrowAllowed() then
        if type(arrowFrame.SetAlpha) == "function" then
            arrowFrame:SetAlpha(1)
        end
        arrowFrame:Show()
        return
    end

    -- Keep the frame alive so RestedXP continues updating its element.
    if type(arrowFrame.SetAlpha) == "function" then
        arrowFrame:SetAlpha(0)
    end
    arrowFrame:Show()
end

_G.RXPTOMTOM_ApplyRxpArrowState = safeDisableRxpArrow

local function q(n, scale)
    if type(n) ~= "number" then return 0 end
    return math.floor(n * scale + 0.5)
end

local function getStepKey(step)
    if not step then
        return nil
    end
    if step.index ~= nil then
        return tostring(step.index)
    end
    return tostring(step)
end

local function getElementKey(element)
    if not element then
        return nil
    end

    local hasZone = (type(element.zone) == "number") and (type(element.x) == "number") and (type(element.y) == "number")
    local hasWorld = (type(element.wx) == "number") and (type(element.wy) == "number")
    if not hasZone and not hasWorld then
        return nil
    end

    local zone = (type(element.zone) == "number") and element.zone or 0
    local inst = (type(element.instance) == "number") and element.instance or 0

    -- RXP x/y are typically percent (0..100). Quantize to 0.01% to avoid jitter.
    local x = hasZone and q(element.x, 100) or 0
    local y = hasZone and q(element.y, 100) or 0

    -- World coords can exist too; quantize lightly.
    local wx = hasWorld and q(element.wx, 1) or 0
    local wy = hasWorld and q(element.wy, 1) or 0

    return table.concat({ inst, zone, x, y, wx, wy }, ":")
end

local function getElementSignature(element)
    if not element then
        return nil
    end

    local hasZone = (type(element.zone) == "number") and (type(element.x) == "number") and (type(element.y) == "number")
    local hasWorld = (type(element.wx) == "number") and (type(element.wy) == "number")
    if not hasZone and not hasWorld then
        return nil
    end

    local zone = (type(element.zone) == "number") and element.zone or 0
    local inst = (type(element.instance) == "number") and element.instance or 0

    local x = hasZone and q(element.x, 10000) or 0
    local y = hasZone and q(element.y, 10000) or 0
    local wx = hasWorld and q(element.wx, 10) or 0
    local wy = hasWorld and q(element.wy, 10) or 0

    return table.concat({ inst, zone, x, y, wx, wy }, ":")
end

local function clearTomTomWaypoints(tomtom)
    if not tomtom then
        return
    end
    for _, uid in pairs(stepWaypointUids) do
        pcall(tomtom.RemoveWaypoint, tomtom, uid)
    end
    stepWaypointUids = {}
    stepWaypointElements = {}
    currentWaypointUid = nil
    currentWaypointKey = nil
    currentOptionsKey = nil
    lastElementSignature = nil
end

local function clearWaypointByUid(tomtom, uid)
    if not (tomtom and uid) then
        return
    end
    pcall(tomtom.RemoveWaypoint, tomtom, uid)
end

local function clearStepWaypoint(tomtom, stepKey)
    if not stepKey then
        return
    end
    local uid = stepWaypointUids[stepKey]
    if uid then
        clearWaypointByUid(tomtom, uid)
    end
    stepWaypointUids[stepKey] = nil
    stepWaypointElements[stepKey] = nil
end

local function isTomTomWaypointValid(tomtom, uid)
    if not uid then
        return false
    end
    if type(tomtom.IsValidWaypoint) == "function" then
        local ok, valid = pcall(tomtom.IsValidWaypoint, tomtom, uid)
        return ok and valid
    end
    if type(tomtom.GetDistanceToWaypoint) ~= "function" then
        return true
    end

    local ok = pcall(tomtom.GetDistanceToWaypoint, tomtom, uid)
    return ok
end

local function addTomTomWaypointFromElement(tomtom, element, opts)
    if not (tomtom and element) then
        return
    end

    local map = element.zone
    local x = element.x and element.x / 100
    local y = element.y and element.y / 100

    if not (map and x and y) then
        local hbd = _G.LibStub and LibStub("HereBeDragons-2.0", true) or nil
        if hbd and element.wx and element.wy then
            map = map or hbd:GetPlayerZone()
            if type(map) == "number" then
                x, y = hbd:GetZoneCoordinatesFromWorld(element.wx, element.wy, map, true)
            end
        end
    end

    if not (type(map) == "number" and type(x) == "number" and type(y) == "number") then
        return
    end

    if x < 0 or y < 0 or x > 1 or y > 1 then
        return
    end

    local title
    if element.step and element.step.index then
        title = string.format("RXP Step %s", tostring(element.step.index))
    end

    title = title or element.title
    if not title and element.step then
        title = element.step.arrowtext or element.step.title
    end
    title = title or "RXP"

    local waypointOpts = {
        title = title,
        source = "RXPGuides",
        crazy = opts and opts.crazy or false,
        minimap = false,
        world = false,
        persistent = false,
        silent = true,
    }
    local db = getConfig()
    waypointOpts.minimap = db.showMinimap and true or false
    waypointOpts.world = db.showWorldMap and true or false
    if opts then
        if opts.minimap ~= nil then waypointOpts.minimap = opts.minimap end
        if opts.world ~= nil then waypointOpts.world = opts.world end
    end

    local uid = tomtom:AddWaypoint(map, x, y, waypointOpts)

    dbg("Add TomTom waypoint: map=%s x=%.4f y=%.4f title=%s", tostring(map), x, y, tostring(title))

    if uid and element.step and element.step.index ~= nil then
        local stepKey = getStepKey(element.step)
        if stepKey then
            stepWaypointUids[stepKey] = uid
            stepWaypointElements[stepKey] = element
        end
    end
    return uid
end

local function setTomTomFromCurrentArrow()
    local tomtom = ensureTomTom()
    local arrowFrame = getRxpArrowFrame()
    if not (tomtom and arrowFrame and arrowFrame.element) then
        msg("Unable to set TomTom waypoint (missing arrow element)")
        return
    end

    clearTomTomWaypoints(tomtom)
    local arrivalDist = (tomtom.profile and tomtom.profile.arrow and tomtom.profile.arrow.arrival) or 0
    local uid = addTomTomWaypointFromElement(tomtom, arrowFrame.element, { crazy = false })
    if uid and type(tomtom.SetCrazyArrow) == "function" then
        pcall(tomtom.SetCrazyArrow, tomtom, uid, arrivalDist, uid.title)
    end
end

_G.RXPTOMTOM_SetCurrentWaypoint = setTomTomFromCurrentArrow

local function ensureRxpMenuHook()
    if _G.RXPTOMTOM_MenuHooked then
        return
    end
    _G.RXPTOMTOM_MenuHooked = true

    if type(hooksecurefunc) ~= "function" then
        return
    end

    local function injectMenuItem(menu, frame)
        if type(menu) ~= "table" then
            return
        end

        local frameName = frame and frame.GetName and frame:GetName() or nil
        local isStepMenu = false
        local isMinimapMenu = false

        if _G.RXPFrame and menu == _G.RXPFrame.menuList then
            isStepMenu = true
        elseif frameName == "RXP_MMMenuFrame" then
            isMinimapMenu = true
        end

        if debugEnabled then
            local texts = {}
            for i = 1, math.min(#menu, 6) do
                local item = menu[i]
                if type(item) == "table" then
                    texts[#texts + 1] = tostring(item.text or "?")
                end
            end
            dbg("Menu hook: frame=%s stepMenu=%s minimapMenu=%s items=%d first=%s",
                tostring(frameName),
                isStepMenu and "yes" or "no",
                isMinimapMenu and "yes" or "no",
                #menu,
                table.concat(texts, " | "))
        end

        if not (isStepMenu or isMinimapMenu) then
            return
        end

        local alreadyAdded
        local insertIndex = #menu + 1
        for i, item in ipairs(menu) do
            if type(item) == "table" then
                if item.text == "Set TomTom waypoint" then
                    alreadyAdded = true
                elseif item.text == _G.CLOSE then
                    insertIndex = i
                end
            end
        end

        if alreadyAdded then
            return
        end

        table.insert(menu, insertIndex, {
            text = "Set TomTom waypoint",
            notCheckable = 1,
            func = function()
                if type(_G.RXPTOMTOM_SetCurrentWaypoint) == "function" then
                    _G.RXPTOMTOM_SetCurrentWaypoint()
                end
            end,
        })
    end

    -- Step list menu is a static table; inject immediately so it appears on first open.
    if _G.RXPFrame and type(_G.RXPFrame.bottomMenu) == "table" then
        injectMenuItem(_G.RXPFrame.bottomMenu, _G.RXPFrame.MenuFrame)
    end

    if type(EasyMenu) == "function" then
        hooksecurefunc("EasyMenu", function(menu, frame, anchor, x, y, displayMode, autoHideDelay)
            injectMenuItem(menu, frame)
        end)
    end

    local libdd = _G.LibStub and LibStub("LibUIDropDownMenu-4.0", true) or nil
    if libdd and type(libdd.EasyMenu) == "function" then
        hooksecurefunc(libdd, "EasyMenu", function(_, menu, frame, anchor, x, y, displayMode, autoHideDelay)
            injectMenuItem(menu, frame)
        end)
    end
end

local function collectStepWaypoints(arrowElement)
    if not arrowElement or not arrowElement.step then
        return {}
    end

    local step = arrowElement.step
    local out = {}

    local rxp = _G.RXP
    if rxp and type(rxp.activeWaypoints) == "table" then
        for _, element in ipairs(rxp.activeWaypoints) do
            if element.step == step then
                table.insert(out, element)
            end
        end
    end

    if #out == 0 and type(step.elements) == "table" then
        for _, element in ipairs(step.elements) do
            if element.arrow and not element.hidden and not element.skip then
                table.insert(out, element)
            end
        end
    end

    if #out == 0 then
        table.insert(out, arrowElement)
    end

    return out
end

local function selectBestWaypointKey(tomtom, keys, excludeKey)
    if not keys or not tomtom then
        return nil
    end

    if type(tomtom.GetDistanceToWaypoint) ~= "function" then
        for key in pairs(keys) do
            if key ~= excludeKey then
                return key, nil
            end
        end
        for key in pairs(keys) do
            return key, nil
        end
        return nil
    end

    local bestKey
    local bestDist
    for key in pairs(keys) do
        if key ~= excludeKey then
        local uid = stepWaypointUids[key]
        if uid then
            local ok, dist = pcall(tomtom.GetDistanceToWaypoint, tomtom, uid)
            if ok and type(dist) == "number" then
                if not bestDist or dist < bestDist then
                    bestDist = dist
                    bestKey = key
                end
            end
        end
        end
    end
    if bestKey then
        return bestKey, bestDist
    end
    if excludeKey then
        return selectBestWaypointKey(tomtom, keys, nil)
    end
    for key in pairs(keys) do
        return key, nil
    end
    return nil
end

tick = function()
    local tomtom = ensureTomTom()
    local arrowFrame = getRxpArrowFrame()
    if not (tomtom and arrowFrame) then
        return
    end

    safeDisableRxpArrow()

    local now = GetTime()

    local element = arrowFrame.element
    local db = getConfig()
    local signature = getElementSignature(element)
    if not signature then
        if not noTargetSince then
            noTargetSince = now
        end
        if (now - noTargetSince) >= NO_TARGET_CLEAR_SECONDS then
            clearTomTomWaypoints(tomtom)
            currentStepKey = nil
            pendingElementKey = nil
            pendingElement = nil
            pendingSince = nil
            arrivedCooldownUntil = nil
            noTargetSince = nil
        end
        return
    end

    noTargetSince = nil

    local optionsKey = (db.showWorldMap and "1" or "0") .. (db.showMinimap and "1" or "0")
    if currentOptionsKey ~= optionsKey then
        clearTomTomWaypoints(tomtom)
        currentOptionsKey = optionsKey
    end

    local elementKey = element.wpHash or signature
    local stepKey = (element and element.step) and getStepKey(element.step) or nil

    if stepKey and currentStepKey and stepKey ~= currentStepKey then
        clearStepWaypoint(tomtom, currentStepKey)
    end
    currentStepKey = stepKey

    if lastElementSignature and lastElementSignature == signature and currentWaypointUid and currentWaypointKey == elementKey then
        return
    end
    local arrivalDist = (tomtom.profile and tomtom.profile.arrow and tomtom.profile.arrow.arrival) or 0

    if currentWaypointKey and currentWaypointKey ~= elementKey then
        clearWaypointByUid(tomtom, currentWaypointUid)
        currentWaypointUid = nil
        currentWaypointKey = nil
        lastElementSignature = nil
    end

    local uid = addTomTomWaypointFromElement(tomtom, element, { crazy = false })
    if uid then
        currentWaypointKey = elementKey
        currentWaypointUid = uid
        lastElementSignature = signature
        if type(tomtom.SetCrazyArrow) == "function" then
            pcall(tomtom.SetCrazyArrow, tomtom, uid, arrivalDist, uid.title)
        end
    end
end

local function ensureRxpHook()
    if rxpHooked then
        return
    end
    local rxp = _G.RXPGuides
    if rxp and type(rxp.DrawArrow) == "function" then
        hooksecurefunc(rxp, "DrawArrow", function()
            tick()
        end)
        rxpHooked = true
    end
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        ensureRxpMenuHook()
        ensureRxpHook()
        local function createOptionsPanel()
            local panel = CreateFrame("Frame", "RXPTOMTOM_OptionsPanel", UIParent)
            panel.name = "RestedXP-TomTom"

            local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
            title:SetPoint("TOPLEFT", 16, -16)
            title:SetText("RestedXP-TomTom")

            local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
            subtitle:SetText("TomTom waypoint display options")

            local worldCheck = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
            worldCheck:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -12)
            worldCheck.Text:SetText("Show waypoint on world map")

            local minimapCheck = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
            minimapCheck:SetPoint("TOPLEFT", worldCheck, "BOTTOMLEFT", 0, -8)
            minimapCheck.Text:SetText("Show waypoint on minimap")

            local reloadBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
            reloadBtn:SetSize(140, 22)
            reloadBtn:SetPoint("TOPLEFT", minimapCheck, "BOTTOMLEFT", 0, -12)
            reloadBtn:SetText("Reload to apply")

            panel.refresh = function()
                local db = getConfig()
                worldCheck:SetChecked(db.showWorldMap)
                minimapCheck:SetChecked(db.showMinimap)
            end
            panel:SetScript("OnShow", panel.refresh)

            worldCheck:SetScript("OnClick", function(self)
                local db = getConfig()
                db.showWorldMap = self:GetChecked() and true or false
                local tt = ensureTomTom()
                if tt then
                    clearTomTomWaypoints(tt)
                end
                currentOptionsKey = nil
                tick()
            end)

            minimapCheck:SetScript("OnClick", function(self)
                local db = getConfig()
                db.showMinimap = self:GetChecked() and true or false
                local tt = ensureTomTom()
                if tt then
                    clearTomTomWaypoints(tt)
                end
                currentOptionsKey = nil
                tick()
            end)

            reloadBtn:SetScript("OnClick", function()
                if type(ReloadUI) == "function" then
                    ReloadUI()
                end
            end)

            if type(Settings) == "table" and type(Settings.RegisterCanvasLayoutCategory) == "function" then
                local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
                Settings.RegisterAddOnCategory(category)
            elseif type(InterfaceOptions_AddCategory) == "function" then
                InterfaceOptions_AddCategory(panel)
            elseif type(InterfaceOptionsFrameAddCategory) == "function" then
                InterfaceOptionsFrameAddCategory(panel)
            end

            _G.RXPTOMTOM_OptionsPanel = panel
        end

        createOptionsPanel()

        SLASH_RXPTOMTOM1 = "/rxptomtom"
        SlashCmdList.RXPTOMTOM = function(msg)
            msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
            if msg == "options" or msg == "opt" then
                local panel = _G.RXPTOMTOM_OptionsPanel
                if panel then
                    if type(Settings) == "table" and type(Settings.OpenToCategory) == "function" then
                        Settings.OpenToCategory(panel.name)
                    elseif type(InterfaceOptionsFrame_OpenToCategory) == "function" then
                        InterfaceOptionsFrame_OpenToCategory(panel)
                        InterfaceOptionsFrame_OpenToCategory(panel)
                    end
                end
                return
            end
            if msg == "debug" then
                debugEnabled = not debugEnabled
                dbg("Debug %s", debugEnabled and "enabled" or "disabled")
                return
            end
            if msg == "clear" then
                local tt = ensureTomTom()
                if tt then
                    clearTomTomWaypoints(tt)
                    msg("Cleared TomTom waypoints")
                end
                return
            end

            local tt = ensureTomTom()
            local af = getRxpArrowFrame()
            local el = af and af.element
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffd200%s:|r TomTom=%s RXP_ARROW=%s element=%s",
                addonName,
                tt and "ok" or "missing",
                af and "ok" or "missing",
                el and "yes" or "no"
            ))
            if el then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffd200%s:|r zone=%s x=%s y=%s wx=%s wy=%s title=%s",
                    addonName,
                    tostring(el.zone), tostring(el.x), tostring(el.y), tostring(el.wx), tostring(el.wy), tostring(el.title)
                ))
            end
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffd200%s:|r hint=auto-updates from RestedXP arrow target", addonName))
        end
        msg("For the best experience, make sure to keep your RestedXP Guides up to date.")

        frame:SetScript("OnUpdate", function(_, elapsed)
            if rxpHooked then
                return
            end
            frame._t = (frame._t or 0) + elapsed
            if frame._t < 0.25 then
                return
            end
            frame._t = 0
            tick()
        end)

        -- RXP can populate the arrow element after login; retry briefly in case hook isn't ready yet.
        if type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
            local attempts = 0
            local ticker
            ticker = C_Timer.NewTicker(0.5, function()
                attempts = attempts + 1
                ensureRxpHook()
                tick()
                local af = getRxpArrowFrame()
                if (af and af.element) or attempts >= 10 then
                    if ticker and type(ticker.Cancel) == "function" then
                        ticker:Cancel()
                    end
                end
            end)
        elseif type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(0.5, function()
                ensureRxpHook()
                tick()
            end)
            C_Timer.After(1.5, function()
                ensureRxpHook()
                tick()
            end)
        end
        return
    end

    if event == "ADDON_LOADED" and (arg1 == "RXPGuides" or arg1 == "TomTom") then
        ensureRxpMenuHook()
        ensureRxpHook()
        tick()
        return
    end

    if event == "PLAYER_CONTROL_GAINED" or event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_ALIVE" then
        tick()
    end
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_CONTROL_GAINED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_ALIVE")
