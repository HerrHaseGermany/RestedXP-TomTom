local addonName = ...

local frame = CreateFrame("Frame")

local currentWaypointUid
local currentWaypointKey
local currentStepKey
local stepWaypointUids = {}
local stepWaypointElements = {}
local debugEnabled = false
local tick

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
                self:Hide()
            end
        end

        local originalSetShown = arrowFrame.SetShown
        arrowFrame.__rxptt_originalSetShown = originalSetShown
        arrowFrame.SetShown = function(self, shown)
            if type(originalSetShown) == "function" then
                originalSetShown(self, shown)
            end
            if not isRxpArrowAllowed() then
                self:Hide()
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
    if opts then
        if opts.minimap ~= nil then waypointOpts.minimap = opts.minimap end
        if opts.world ~= nil then waypointOpts.world = opts.world end
    end

    local uid = tomtom:AddWaypoint(map, x, y, waypointOpts)

    dbg("Add TomTom waypoint: map=%s x=%.4f y=%.4f title=%s", tostring(map), x, y, tostring(title))
    return uid
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
    local key = getElementKey(element)
    if not key then
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

    local elementKey = element.wpHash or key
    local arrivalDist = (tomtom.profile and tomtom.profile.arrow and tomtom.profile.arrow.arrival) or 0

    if currentWaypointKey and currentWaypointKey ~= elementKey then
        clearTomTomWaypoints(tomtom)
    end

    if currentWaypointUid and isTomTomWaypointValid(tomtom, currentWaypointUid) and currentWaypointKey == elementKey then
        if type(tomtom.SetCrazyArrow) == "function" then
            pcall(tomtom.SetCrazyArrow, tomtom, currentWaypointUid, arrivalDist, currentWaypointUid.title)
        end
        return
    end

    local uid = addTomTomWaypointFromElement(tomtom, element, { crazy = false })
    if uid then
        currentWaypointKey = elementKey
        currentWaypointUid = uid
        if type(tomtom.SetCrazyArrow) == "function" then
            pcall(tomtom.SetCrazyArrow, tomtom, uid, arrivalDist, uid.title)
        end
    end
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        SLASH_RXPTOMTOM1 = "/rxptomtom"
        SlashCmdList.RXPTOMTOM = function(msg)
            msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
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
            frame._t = (frame._t or 0) + elapsed
            if frame._t < 0.25 then
                return
            end
            frame._t = 0
            tick()
        end)

        -- RXP can populate the arrow element after login; retry for a bit until it exists.
        if type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
            local attempts = 0
            local ticker
            ticker = C_Timer.NewTicker(0.5, function()
                attempts = attempts + 1
                tick()
                local af = getRxpArrowFrame()
                if (af and af.element) or attempts >= 20 then
                    if ticker and type(ticker.Cancel) == "function" then
                        ticker:Cancel()
                    end
                end
            end)
        elseif type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(0.5, tick)
            C_Timer.After(1.5, tick)
            C_Timer.After(2.5, tick)
        end
        return
    end

    if event == "ADDON_LOADED" and (arg1 == "RXPGuides" or arg1 == "TomTom") then
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
