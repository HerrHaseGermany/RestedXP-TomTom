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

    arrowFrame:Hide()
    arrowFrame:SetScript("OnUpdate", nil)

    if not arrowFrame.__rxptt_hooked then
        arrowFrame.__rxptt_hooked = true

        local originalShow = arrowFrame.Show
        arrowFrame.Show = function(self, ...)
            if type(originalShow) == "function" then
                originalShow(self, ...)
            end
            self:Hide()
        end

        local originalSetShown = arrowFrame.SetShown
        arrowFrame.SetShown = function(self, shown)
            if type(originalSetShown) == "function" then
                originalSetShown(self, shown)
            end
            self:Hide()
        end
    end
end

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

    local stepKey = getStepKey(element.step)
    if stepKey ~= currentStepKey then
        clearTomTomWaypoints(tomtom)
        currentStepKey = stepKey
        pendingElementKey = nil
        pendingElement = nil
        pendingSince = nil
        arrivedCooldownUntil = nil
    end

    local candidates = collectStepWaypoints(element)
    local desiredKeys = {}
    for _, candidate in ipairs(candidates) do
        local ckey = candidate.wpHash or getElementKey(candidate)
        if ckey and not desiredKeys[ckey] then
            desiredKeys[ckey] = true
            stepWaypointElements[ckey] = candidate
            local existing = stepWaypointUids[ckey]
            if not isTomTomWaypointValid(tomtom, existing) then
                local uid = addTomTomWaypointFromElement(tomtom, candidate, { crazy = false })
                if uid then
                    stepWaypointUids[ckey] = uid
                end
            end
        end
    end

    for ckey, uid in pairs(stepWaypointUids) do
        if not desiredKeys[ckey] then
            pcall(tomtom.RemoveWaypoint, tomtom, uid)
            stepWaypointUids[ckey] = nil
            stepWaypointElements[ckey] = nil
        end
    end

    if not next(stepWaypointUids) then
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

    if currentWaypointUid and not isTomTomWaypointValid(tomtom, currentWaypointUid) then
        currentWaypointUid = nil
        currentWaypointKey = nil
    end

    local currentDist
    if currentWaypointUid and type(tomtom.GetDistanceToWaypoint) == "function" then
        local ok, dist = pcall(tomtom.GetDistanceToWaypoint, tomtom, currentWaypointUid)
        if ok and type(dist) == "number" then
            currentDist = dist
        end
    end

    if currentDist and currentDist <= ARRIVE_DISTANCE then
        arrivedCooldownUntil = now + 1.5
    end

    local excludeKey = currentWaypointKey
    if arrivedCooldownUntil and now <= arrivedCooldownUntil then
        excludeKey = currentWaypointKey
    else
        excludeKey = nil
    end
    local bestKey, bestDist = selectBestWaypointKey(tomtom, desiredKeys, excludeKey)
    if not bestKey then
        return
    end

    local bestUid = stepWaypointUids[bestKey]
    local arrivalDist = (tomtom.profile and tomtom.profile.arrow and tomtom.profile.arrow.arrival) or 0

    if not currentWaypointKey or not currentWaypointUid then
        currentWaypointKey = bestKey
        currentWaypointUid = bestUid
        if bestUid and type(tomtom.SetCrazyArrow) == "function" then
            pcall(tomtom.SetCrazyArrow, tomtom, bestUid, arrivalDist, bestUid.title)
        end
        pendingElementKey = nil
        pendingElement = nil
        pendingSince = nil
        return
    end

    if bestKey == currentWaypointKey then
        pendingElementKey = nil
        pendingElement = nil
        pendingSince = nil
        return
    end

    -- Prevent snapping back unless new target is meaningfully closer
    if currentDist and bestDist and (bestDist + SWITCH_DISTANCE_ADVANTAGE) > currentDist then
        pendingElementKey = nil
        pendingElement = nil
        pendingSince = nil
        return
    end

    -- If we're very close to current waypoint, allow immediate switch
    if type(tomtom.GetDistanceToWaypoint) == "function" and currentWaypointUid then
        local ok, dist = pcall(tomtom.GetDistanceToWaypoint, tomtom, currentWaypointUid)
        if ok and type(dist) == "number" and dist <= ARRIVE_DISTANCE then
            currentWaypointKey = bestKey
            currentWaypointUid = bestUid
            pendingElementKey = nil
            pendingElement = nil
            pendingSince = nil
            if bestUid and type(tomtom.SetCrazyArrow) == "function" then
                pcall(tomtom.SetCrazyArrow, tomtom, bestUid, arrivalDist, bestUid.title)
            end
            return
        end
    end

    -- Debounce: require the new key to be stable for SWITCH_STABLE_SECONDS
    if pendingElementKey ~= bestKey then
        pendingElementKey = bestKey
        pendingElement = stepWaypointElements[bestKey] or element
        pendingSince = now
        return
    end

    if pendingSince and (now - pendingSince) >= SWITCH_STABLE_SECONDS then
        currentWaypointKey = bestKey
        currentWaypointUid = bestUid
        pendingElementKey = nil
        pendingSince = nil
        pendingElement = nil

        if bestUid and type(tomtom.SetCrazyArrow) == "function" then
            pcall(tomtom.SetCrazyArrow, tomtom, bestUid, arrivalDist, bestUid.title)
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

        frame:SetScript("OnUpdate", function(_, elapsed)
            frame._t = (frame._t or 0) + elapsed
            if frame._t < 0.25 then
                return
            end
            frame._t = 0
            tick()
        end)
        return
    end

    if event == "ADDON_LOADED" and (arg1 == "RXPGuides" or arg1 == "TomTom") then
        tick()
    end
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ADDON_LOADED")
