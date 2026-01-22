local addonName = ...

local frame = CreateFrame("Frame")

local currentWaypointUid
local lastElementId
local debugEnabled = false
local tick

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

local function getElementKey(element)
    if not element then
        return nil
    end

    local zone = element.zone or 0
    local x = element.x or 0
    local y = element.y or 0
    local wx = element.wx or 0
    local wy = element.wy or 0
    local inst = element.instance or 0
    local title = element.title or ""

    return table.concat({ zone, x, y, wx, wy, inst, title }, ":")
end

local function clearTomTomWaypoint(tomtom)
    if currentWaypointUid then
        pcall(tomtom.RemoveWaypoint, tomtom, currentWaypointUid)
        currentWaypointUid = nil
    end
end

local function ensureTomTomWaypointStillExists(tomtom)
    if not currentWaypointUid then
        return false
    end
    if type(tomtom.GetDistanceToWaypoint) ~= "function" then
        return true
    end

    local ok, dist = pcall(tomtom.GetDistanceToWaypoint, tomtom, currentWaypointUid)
    if not ok or dist == nil then
        currentWaypointUid = nil
        return false
    end
    return true
end

local function setTomTomWaypointFromElement(tomtom, element)
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

    clearTomTomWaypoint(tomtom)

    currentWaypointUid = tomtom:AddWaypoint(map, x, y, {
        title = title,
        source = "RXPGuides",
        crazy = true,
        minimap = false,
        world = false,
        persistent = false,
        silent = true,
    })

    dbg("Set TomTom waypoint: map=%s x=%.4f y=%.4f title=%s", tostring(map), x, y, tostring(title))
end

tick = function()
    local tomtom = ensureTomTom()
    local arrowFrame = getRxpArrowFrame()
    if not (tomtom and arrowFrame) then
        return
    end

    safeDisableRxpArrow()

    local element = arrowFrame.element
    local key = getElementKey(element)
    if not key then
        clearTomTomWaypoint(tomtom)
        lastElementId = nil
        return
    end

    local changed = (key ~= lastElementId)
    if changed then
        lastElementId = key
    end

    local haveWaypoint = ensureTomTomWaypointStillExists(tomtom)
    if not haveWaypoint then
        setTomTomWaypointFromElement(tomtom, element)
        return
    end

    if not changed then
        return
    end

    setTomTomWaypointFromElement(tomtom, element)
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
                    clearTomTomWaypoint(tt)
                    msg("Cleared TomTom waypoint")
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
