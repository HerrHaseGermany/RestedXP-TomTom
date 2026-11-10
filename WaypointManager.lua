local api = _G.RXPTOMTOM
local manager = { order = {}, rows = {}, afterRxp = {}, running = false }
local ROW_HEIGHT = 40
_G.RXPTOMTOM_Manager = manager

local function managed(uid)
    return not api.IsRxpWaypoint(uid) and not uid.corpse
end

local function valid(uid)
    local tt = api.GetTomTom()
    return tt and uid and tt:IsValidWaypoint(uid)
end

local function mapName(id)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
    return info and info.name or ("Map " .. tostring(id))
end

local function waypointKey(uid)
    return string.format("%d:%.8f:%.8f:%s", uid[1], uid[2], uid[3], uid.title or "")
end

function manager:SaveOrder()
    local keys, after = {}, {}
    for _, uid in ipairs(self.order) do
        local key = waypointKey(uid)
        keys[#keys + 1] = key
        if self.afterRxp[uid] then after[key] = true end
    end
    api.GetConfig().managerOrder = keys
    api.GetConfig().managerAfterRxp = after
end

-- Preserve the user's order, append newly discovered targets deterministically.
function manager:Sync()
    local tt = api.GetTomTom()
    if not tt or type(tt.waypoints) ~= "table" then return false end
    local present, additions, protected = {}, {}, {}
    for _, entries in pairs(tt.waypoints) do
        for _, uid in pairs(entries) do
            if type(uid) == "table" then
                if managed(uid) then present[uid] = true else protected[#protected + 1] = uid end
            end
        end
    end
    local order = {}
    for _, uid in ipairs(self.order) do
        if present[uid] then
            order[#order + 1] = uid
            present[uid] = nil
        end
    end
    for uid in pairs(present) do additions[#additions + 1] = uid end
    local ranks = {}
    for index, key in ipairs(api.GetConfig().managerOrder or {}) do ranks[key] = index end
    local function less(a, b)
        local rankA, rankB = ranks[waypointKey(a)] or math.huge, ranks[waypointKey(b)] or math.huge
        if rankA ~= rankB then return rankA < rankB end
        if a[1] ~= b[1] then return a[1] < b[1] end
        if (a.title or "") ~= (b.title or "") then return (a.title or "") < (b.title or "") end
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[3] < b[3]
    end
    table.sort(additions, less)
    table.sort(protected, less)
    for _, uid in ipairs(additions) do order[#order + 1] = uid end
    local before, after, flags = {}, {}, {}
    local savedAfter = api.GetConfig().managerAfterRxp or {}
    for _, uid in ipairs(order) do
        local isAfter = self.afterRxp[uid]
        if isAfter == nil then isAfter = savedAfter[waypointKey(uid)] == true end
        flags[uid] = isAfter
        local group = isAfter and after or before
        group[#group + 1] = uid
    end
    for _, uid in ipairs(after) do before[#before + 1] = uid end
    self.order, self.protected, self.afterRxp = before, protected, flags
    return true
end

function manager:GetEntries()
    local entries, rxp, other = {}, nil, {}
    for _, uid in ipairs(self.protected or {}) do
        if api.IsRxpWaypoint(uid) then rxp = uid else other[#other + 1] = uid end
    end
    for _, uid in ipairs(self.order) do if not self.afterRxp[uid] then entries[#entries + 1] = uid end end
    if rxp then entries[#entries + 1] = rxp end
    for _, uid in ipairs(self.order) do if self.afterRxp[uid] then entries[#entries + 1] = uid end end
    for _, uid in ipairs(other) do entries[#entries + 1] = uid end
    return entries, rxp
end

function manager:Stop()
    self.running, self.routeTarget = false, nil
    self.waitingStep, self.waitingGuide, self.waitingProgress = nil, nil, nil
end

function manager:AdvanceRoute()
    if not self:Sync() then self:Stop(); return false end
    local target = self.order[1]
    if not target then self:Stop(); api.ResumeRxp(); return false end
    if self.afterRxp[target] and not self.rxpPassed then
        local step, guide, progress = api.GetRxpState()
        if not step then
            self:Stop()
            if self.error then self.error:SetText("Load an RXP step before starting this route.") end
            return false
        end
        self.routeTarget = nil
        self.waitingStep, self.waitingGuide, self.waitingProgress = step, guide, progress
        self.resumingRxp = true
        api.ResumeRxp()
        self.resumingRxp = false
        return true
    end
    self.routeTarget = target
    if not self:Select(target) then self:Stop(); return false end
    return true
end

function manager:Select(uid)
    if not valid(uid) then return false end
    local tt = api.GetTomTom()
    if not tt.SetCrazyArrow then return false end
    self.selecting = true
    tt:SetCrazyArrow(uid, (tt.profile.arrow and tt.profile.arrow.arrival) or 15, uid.title)
    self.selecting = false
    self.active = uid
    return true
end

function manager:Navigate(uid)
    self:Stop()
    if api.IsRxpWaypoint(uid) then api.ResumeRxp() else self:Select(uid) end
    self:Refresh()
end

function manager:Start()
    if not self:Sync() or not self.order[1] then return false end
    self.running, self.rxpPassed = true, false
    if not self:AdvanceRoute() then return false end
    self:Refresh()
    return true
end

function manager:Reorder(uid, beforeUid)
    if not self:Sync() or not uid or not managed(uid) or uid == beforeUid then return end
    local _, rxp = self:GetEntries()
    local source, destination
    for index, item in ipairs(self.order) do
        if item == uid then source = index end
        if item == beforeUid then destination = index end
    end
    if not source or (beforeUid and not destination and beforeUid ~= rxp) then return end
    if beforeUid == rxp then
        self.afterRxp[uid] = false
        destination = #self.order + 1
        for index, item in ipairs(self.order) do
            if self.afterRxp[item] then destination = index; break end
        end
    else
        if beforeUid then self.afterRxp[uid] = self.afterRxp[beforeUid] == true
        else self.afterRxp[uid] = rxp ~= nil end
    end
    table.remove(self.order, source)
    destination = destination or (#self.order + 2)
    if destination > source then destination = destination - 1 end
    table.insert(self.order, destination, uid)
    self:SaveOrder()
    self:Refresh()
end

function manager:CancelDrag()
    self.dragUid, self.dragOrder, self.dropBefore, self.dropValid = nil, nil, nil, false
    if self.dropMarker then self.dropMarker:Hide() end
    if self.dragRow then
        self.dragRow:SetAlpha(1)
        self.dragRow:SetScript("OnUpdate", nil)
        self.dragRow = nil
    end
end

function manager:UpdateDrag(elapsed)
    if not self.dragUid then return end
    if not valid(self.dragUid) then self:CancelDrag(); self:Refresh(); return end
    local x, y = GetCursorPosition()
    local scroll = self.scroll
    local scale = scroll:GetEffectiveScale()
    x, y = x / scale, y / scale
    self.dropValid = x >= scroll:GetLeft() and x <= scroll:GetRight()
        and y >= scroll:GetBottom() and y <= scroll:GetTop()
    if not self.dropValid then self.dropMarker:Hide(); return end
    -- Scroll near either edge so routes longer than the viewport can be sorted.
    local offset = scroll:GetVerticalScroll()
    local maximum = math.max(0, self.content:GetHeight() - scroll:GetHeight())
    local step = (elapsed or 0) * 180
    if y > scroll:GetTop() - 20 then offset = math.max(0, offset - step)
    elseif y < scroll:GetBottom() + 20 then offset = math.min(maximum, offset + step) end
    scroll:SetVerticalScroll(offset)
    local gap = math.floor((scroll:GetTop() - y + offset) / ROW_HEIGHT + 0.5)
    gap = math.max(0, math.min(#self.dragOrder, gap))
    self.dropBefore = self.dragOrder[gap + 1]
    self.dropMarker:ClearAllPoints()
    self.dropMarker:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -gap * ROW_HEIGHT)
    self.dropMarker:Show()
end

function manager:BeginDrag(row)
    if not row.uid or not managed(row.uid) or not valid(row.uid) then return end
    self:CancelDrag()
    self:Sync()
    self.dragUid, self.dragRow = row.uid, row
    self.dragOrder = self:GetEntries()
    -- Corpse entries are informational and are not route insertion targets.
    while self.dragOrder[#self.dragOrder] and self.dragOrder[#self.dragOrder].corpse do
        table.remove(self.dragOrder)
    end
    row:SetAlpha(0.45)
    row:SetScript("OnUpdate", function(_, elapsed) self:UpdateDrag(elapsed) end)
    self:UpdateDrag(0)
end

function manager:FinishDrag()
    if not self.dragUid then return end
    self:UpdateDrag(0)
    local uid, beforeUid, allowed = self.dragUid, self.dropBefore, self.dropValid
    self:CancelDrag()
    if allowed then self:Reorder(uid, beforeUid) end
    self:Refresh()
end

function manager:Remove(uid)
    if not uid or not managed(uid) or not valid(uid) then return end
    api.GetTomTom():RemoveWaypoint(uid)
    self:Update()
end

function manager:ClearAndResume()
    local tt = api.GetTomTom()
    if not tt or type(tt.waypoints) ~= "table" then return end
    self:Stop()
    self:CancelDrag()
    -- Snapshot the list: TomTom mutates its tables during each removal.
    local targets = {}
    for _, entries in pairs(tt.waypoints) do
        for _, uid in pairs(entries) do targets[#targets + 1] = uid end
    end
    for _, uid in ipairs(targets) do tt:RemoveWaypoint(uid) end
    if tt.ClearCrazyArrowPoint then tt:ClearCrazyArrowPoint(false) end
    self.active = nil
    self.order = {}
    self:SaveOrder()
    api.ResumeRxp()
    self:Refresh()
end

function manager:Add(mapText, xText, yText, title)
    local map, x, y = tonumber(mapText), tonumber(xText), tonumber(yText)
    if not map or map ~= math.floor(map) or map <= 0 or map == math.huge or not x or not y
        or x ~= x or y ~= y or x < 0 or x > 100 or y < 0 or y > 100 then
        return nil, "Enter a valid map ID and X/Y coordinates from 0 to 100."
    end
    if C_Map and C_Map.GetMapInfo and not C_Map.GetMapInfo(map) then
        return nil, "Unknown map ID. Use Current zone or enter another map ID."
    end
    local tt = api.GetTomTom()
    if not tt then return nil, "TomTom is unavailable." end
    title = (title or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then title = "Waypoint" end
    local uid = tt:AddWaypoint(map, x / 100, y / 100, {
        title = title, source = "RestedXP-TomTom Manager", crazy = false,
        persistent = true, minimap = true, world = true,
    })
    if not uid then return nil, "TomTom could not create this waypoint." end
    self:Sync()
    self:SaveOrder()
    self:Refresh()
    return uid
end

function manager:Update()
    local tt = api.GetTomTom()
    if not tt then return end
    if tt.IsCrazyArrowEmpty and tt:IsCrazyArrowEmpty() and valid(self.active) then self.active = nil end
    if self.running then
        if not self:Sync() then self:Stop(); return end
        if self.waitingStep then
            local _, guide, progress = api.GetRxpState()
            local step = self.waitingStep
            local advanced = type(progress) == "number" and type(step.index) == "number"
                and type(self.waitingProgress) == "number" and self.waitingProgress <= step.index
                and progress > step.index and guide == self.waitingGuide
            if step.completed or advanced then
                self.rxpPassed = true
                self.waitingStep, self.waitingGuide, self.waitingProgress = nil, nil, nil
                self:AdvanceRoute()
            elseif guide ~= self.waitingGuide then
                self:Stop()
            elseif not self.order[1] or not self.afterRxp[self.order[1]] then
                self.waitingStep, self.waitingGuide, self.waitingProgress = nil, nil, nil
                self:AdvanceRoute()
            end
        end
        if self.running and not self.waitingStep then
            local target = self.routeTarget
            if valid(target) and tt.GetDistanceToWaypoint and not (UnitOnTaxi and UnitOnTaxi("player")) then
                local distance = tt:GetDistanceToWaypoint(target)
                local arrival = tonumber(tt.profile.arrow and tt.profile.arrow.arrival) or 15
                if arrival <= 0 then arrival = 15 end
                if distance and distance <= arrival then
                    tt:RemoveWaypoint(target)
                    self:Sync()
                end
            end
            if not valid(target) then self:AdvanceRoute() end
        end
    elseif self.active and managed(self.active) and not valid(self.active) then
        if self:Sync() then
            if self.order[1] and not self.afterRxp[self.order[1]] then self:Select(self.order[1])
            elseif self.order[1] then self.running, self.rxpPassed = true, false; self:AdvanceRoute()
            else self.active = nil; api.ResumeRxp() end
        end
    end
    if self.window and self.window:IsShown() then self:Refresh() end
end

local function text(parent, value, x, y, font)
    local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", x, y)
    label:SetText(value)
    return label
end

local function button(parent, value, width, x, y, action)
    local result = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    result:SetSize(width, 24)
    result:SetPoint("TOPLEFT", x, y)
    result:SetText(value)
    result:SetScript("OnClick", action)
    return result
end

local function enabled(control, value)
    if value then control:Enable() else control:Disable() end
end

local function trashButton(parent, action)
    local control = button(parent, "", 24, 220, -7, action)
    local icon = CreateFrame("Frame", nil, control)
    icon:SetSize(14, 16)
    icon:SetPoint("CENTER")
    -- Draw a small trash can using solid UI textures, available on all clients.
    for _, rect in ipairs({ { 5, 0, 4, 2 }, { 0, -3, 14, 2 }, { 2, -6, 2, 10 },
        { 10, -6, 2, 10 }, { 4, -14, 6, 2 }, { 6, -6, 2, 6 } }) do
        local part = icon:CreateTexture(nil, "ARTWORK")
        part:SetColorTexture(0.85, 0.85, 0.85, 1)
        part:SetSize(rect[3], rect[4])
        part:SetPoint("TOPLEFT", rect[1], rect[2])
    end
    control.icon = icon
    control:SetScript("OnEnter", function()
        GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove waypoint")
        GameTooltip:Show()
    end)
    control:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return control
end

function manager:Refresh()
    if not self.window or self.dragUid then return end
    local available = self:Sync()
    local all = self:GetEntries()
    self.summary:SetText(not available and "TomTom waypoint list is unavailable."
        or string.format("%d waypoints  |  %s", #all,
            self.waitingStep and "After RXP step" or (self.running and "Route running" or (api.IsPaused() and "RXP paused" or "RXP navigation"))))
    self.routeButton:SetText(self.running and "Stop route" or "Start route")
    enabled(self.routeButton, available and #self.order > 0)
    self.empty:SetShown(#all == 0)
    for index, uid in ipairs(all) do
        local row = self.rows[index]
        if not row then
            row = CreateFrame("Frame", nil, self.content)
            row:SetSize(248, 38)
            row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
            row:RegisterForDrag("LeftButton")
            row:SetScript("OnDragStart", function() self:BeginDrag(row) end)
            row:SetScript("OnDragStop", function() self:FinishDrag() end)
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.025 or 0.06)
            row.grip = text(row, "::", 4, -12, "GameFontNormal")
            row.label = text(row, "", 22, -4, "GameFontHighlightSmall")
            row.label:SetWidth(142)
            row.label:SetWordWrap(false)
            row.label:SetJustifyH("LEFT")
            row.detail = text(row, "", 22, -21)
            row.detail:SetWidth(142)
            row.detail:SetWordWrap(false)
            row.detail:SetJustifyH("LEFT")
            row.go = button(row, "Go", 42, 170, -7, function() self:Navigate(row.uid) end)
            row.go:SetScript("OnEnter", function()
                GameTooltip:SetOwner(row.go, "ANCHOR_RIGHT")
                GameTooltip:SetText(row.uid.title or "Waypoint")
                GameTooltip:AddLine(string.format("%s (%.2f, %.2f)", mapName(row.uid[1]), row.uid[2] * 100, row.uid[3] * 100), 1, 1, 1)
                GameTooltip:Show()
            end)
            row.go:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.delete = trashButton(row, function() self:Remove(row.uid) end)
            self.rows[index] = row
        end
        row.uid = uid
        local rxp = api.IsRxpWaypoint(uid)
        local prefix = rxp and "RXP" or (uid.corpse and "Corpse" or tostring(index))
        local active = self.active == uid and valid(uid)
        enabled(row.go, not active)
        row.label:SetText(string.format("%s  %s%s", prefix, uid.title or "Waypoint", active and "  |cffffd200<|r" or ""))
        row.detail:SetText(string.format("%s  |  %.2f, %.2f", mapName(uid[1]), uid[2] * 100, uid[3] * 100))
        row:EnableMouse(managed(uid))
        row.grip:SetShown(managed(uid))
        enabled(row.delete, managed(uid))
        row.delete.icon:SetAlpha(managed(uid) and 1 or 0.25)
        row:Show()
    end
    for index = #all + 1, #self.rows do self.rows[index]:Hide() end
    self.content:SetHeight(math.max(1, #all * ROW_HEIGHT))
    local offset = self.scroll:GetVerticalScroll()
    local maximum = math.max(0, #all * ROW_HEIGHT - self.scroll:GetHeight())
    if offset > maximum then self.scroll:SetVerticalScroll(maximum) end
end

function manager:ApplyDisplaySettings()
    if not self.window then return end
    local config = api.GetConfig()
    local opacity = 1 - config.managerTransparency / 100
    self.window:SetBackdropColor(0.035, 0.045, 0.065, opacity)
    self.window:SetBackdropBorderColor(0.7, 0.58, 0.3, opacity)
    if config.managerLocked then self.window:StopMovingOrSizing() end
    self.window:SetMovable(not config.managerLocked)
    if self.controls then self.controls:SetAlpha(1 - config.managerControlsTransparency / 100) end
end

function manager:CreateSettings(parent)
    if self.settingsPanel then return end
    local modern = Settings and Settings.RegisterCanvasLayoutSubcategory and parent.category
    local legacy = InterfaceOptions_AddCategory or InterfaceOptionsFrameAddCategory
    if not modern and not legacy then return end
    local panel = CreateFrame("Frame", "RXPTOMTOM_ManagerOptionsPanel", UIParent)
    self.settingsPanel = panel
    panel.name, panel.parent = "Waypoint Manager", parent.name
    text(panel, "Waypoint Manager", 16, -16, "GameFontNormalLarge")
    text(panel, "Window appearance and controls. Changes apply immediately.", 16, -44)
    local lock = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    lock:SetPoint("TOPLEFT", 16, -72)
    lock.Text:SetText("Lock window position")
    lock:SetScript("OnClick", function(control)
        api.GetConfig().managerLocked = control:GetChecked() and true or false
        self:ApplyDisplaySettings()
    end)
    local minimap = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    minimap:SetPoint("TOPLEFT", 16, -108)
    minimap.Text:SetText("Show minimap button")
    minimap:SetScript("OnClick", function(control)
        api.GetConfig().managerMinimap.hide = not control:GetChecked()
        self:UpdateMinimapButton()
    end)
    local refreshing = false
    local function transparencySlider(name, key, caption, y)
        local label = text(panel, "", 20, y, "GameFontNormal")
        local slider = CreateFrame("Slider", name, panel, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", 20, y - 26)
        slider:SetSize(240, 18)
        slider:SetOrientation("HORIZONTAL")
        slider:SetMinMaxValues(0, 100)
        slider:SetValueStep(1)
        if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
        slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        slider:GetThumbTexture():SetSize(32, 32)
        local low = slider.Low or _G[name .. "Low"]
        local high = slider.High or _G[name .. "High"]
        local title = slider.Text or _G[name .. "Text"]
        if low then low:SetText("0%") end
        if high then high:SetText("100%") end
        if title then title:SetText("") end
        slider:SetScript("OnValueChanged", function(_, value)
            value = math.floor(value + 0.5)
            label:SetText(string.format("%s: %d%%", caption, value))
            if not refreshing then
                api.GetConfig()[key] = value
                self:ApplyDisplaySettings()
            end
        end)
        return slider, label
    end
    local slider, label = transparencySlider("RXPTOMTOM_ManagerTransparency", "managerTransparency", "Background transparency", -156)
    local controls, controlsLabel = transparencySlider("RXPTOMTOM_ManagerControlsTransparency", "managerControlsTransparency", "Controls transparency", -228)
    text(panel, "Controls transparency affects text, buttons and the waypoint list.", 20, -292)
    button(panel, "Toggle Waypoint Manager", 200, 20, -324, function() self:Toggle() end)
    panel.refresh = function()
        local config = api.GetConfig()
        lock:SetChecked(config.managerLocked)
        minimap:SetChecked(not config.managerMinimap.hide)
        refreshing = true
        slider:SetValue(config.managerTransparency)
        controls:SetValue(config.managerControlsTransparency)
        label:SetText(string.format("Background transparency: %d%%", config.managerTransparency))
        controlsLabel:SetText(string.format("Controls transparency: %d%%", config.managerControlsTransparency))
        refreshing = false
    end
    panel:SetScript("OnShow", panel.refresh)
    panel.OnRefresh = panel.refresh
    self.settingsControls = { lock = lock, minimap = minimap, transparency = slider, controlsTransparency = controls }
    panel.refresh()
    panel:Hide()
    if modern then
        local category = Settings.RegisterCanvasLayoutSubcategory(parent.category, panel, panel.name)
        panel.categoryID = category:GetID()
    else
        legacy(panel)
    end
end

function manager:CreateWindow()
    local window = CreateFrame("Frame", "RXPTOMTOM_WaypointManager", UIParent, "BackdropTemplate")
    self.window = window
    window:SetSize(300, 350)
    window:SetFrameStrata("LOW")
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    window:SetBackdropColor(0.035, 0.045, 0.065, 0.98)
    window:SetBackdropBorderColor(0.7, 0.58, 0.3, 1)
    local position = api.GetConfig().managerPosition
    if position and type(position.x) == "number" and type(position.y) == "number" then
        window:SetPoint("CENTER", UIParent, "CENTER", position.x, position.y)
    else
        window:SetPoint("CENTER")
    end
    window:SetScript("OnDragStart", function()
        if not api.GetConfig().managerLocked then window:StartMoving() end
    end)
    window:SetScript("OnDragStop", function()
        if api.GetConfig().managerLocked then return end
        window:StopMovingOrSizing()
        local x, y = window:GetCenter()
        local px, py = UIParent:GetCenter()
        api.GetConfig().managerPosition = { x = x - px, y = y - py }
        window:ClearAllPoints()
        window:SetPoint("CENTER", UIParent, "CENTER", x - px, y - py)
    end)
    local contents = CreateFrame("Frame", nil, window)
    contents:SetAllPoints(window)
    self.controls = contents
    text(contents, "Waypoint Manager", 12, -12, "GameFontNormal")
    self.summary = text(contents, "", 12, -34)
    self.routeButton = button(contents, "Start route", 110, 12, -53, function()
        if self.running then self:Stop(); self:Refresh() else self:Start() end
    end)
    self.clearButton = button(contents, "Clear & RXP", 110, 130, -53, function() self:ClearAndResume() end)
    self.clearButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(self.clearButton, "ANCHOR_RIGHT")
        GameTooltip:SetText("Clear all & resume RXP")
        GameTooltip:AddLine("Removes all TomTom waypoints, including saved targets, then resumes the current RXP target.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    self.clearButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local scroll = CreateFrame("ScrollFrame", nil, contents, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -86)
    scroll:SetSize(252, ROW_HEIGHT * 3)
    self.scroll = scroll
    self.content = CreateFrame("Frame", nil, scroll)
    self.content:SetSize(248, 1)
    scroll:SetScrollChild(self.content)
    self.dropMarker = self.content:CreateTexture(nil, "OVERLAY")
    self.dropMarker:SetSize(248, 2)
    self.dropMarker:SetColorTexture(1, 0.82, 0.3, 1)
    self.dropMarker:Hide()
    self.empty = text(contents, "No waypoints. Add a target below or load an RXP guide.", 20, -96)
    self.empty:SetWidth(230)
    self.empty:SetJustifyH("LEFT")
    text(contents, "Add waypoint", 12, -216, "GameFontNormal")
    self.inputs = {}
    local function input(key, label, width, x, y)
        text(contents, label, x, y + 18)
        local field = CreateFrame("EditBox", nil, contents, "InputBoxTemplate")
        field:SetAutoFocus(false)
        field:SetSize(width, 24)
        field:SetPoint("TOPLEFT", x + 4, y)
        field:SetMaxLetters(key == "title" and 100 or 12)
        field:SetScript("OnEscapePressed", function() field:ClearFocus() end)
        self.inputs[key] = field
        return field
    end
    input("map", "Map ID", 54, 12, -252)
    input("x", "X", 54, 76, -252)
    input("y", "Y", 54, 140, -252)
    input("title", "Title", 174, 12, -299)
    local keys = { "map", "x", "y", "title" }
    for index, key in ipairs(keys) do
        self.inputs[key]:SetScript("OnTabPressed", function() self.inputs[keys[index % #keys + 1]]:SetFocus() end)
    end
    self.error = text(contents, "", 12, -328)
    self.error:SetTextColor(1, 0.4, 0.3)
    self.error:SetWidth(276)
    self.error:SetJustifyH("LEFT")
    local function add()
        local fields = self.inputs
        local uid, err = self:Add(fields.map:GetText(), fields.x:GetText(), fields.y:GetText(), fields.title:GetText())
        self.error:SetText(err or "Waypoint added.")
        if uid then
            for _, field in pairs(fields) do field:ClearFocus() end
        end
    end
    button(contents, "Add", 78, 210, -299, add)
    self.inputs.title:SetScript("OnEnterPressed", add)
    button(contents, "My zone", 78, 210, -252, function() self:FillCurrentZone() end)
    window:SetScript("OnShow", function()
        if self.inputs.map:GetText() == "" then self:FillCurrentZone() end
        self:Refresh()
    end)
    window:SetScript("OnHide", function() self:CancelDrag() end)
    self:ApplyDisplaySettings()
    window:Hide()
end

function manager:FillCurrentZone()
    local tt = api.GetTomTom()
    local map, x, y
    if tt and tt.GetCurrentPlayerPosition then map, x, y = tt:GetCurrentPlayerPosition() end
    map = map or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
    if map then self.inputs.map:SetText(tostring(map)) end
    if x and y then
        self.inputs.x:SetText(string.format("%.2f", x * 100))
        self.inputs.y:SetText(string.format("%.2f", y * 100))
    end
end

function manager:Toggle()
    if not self.window then self:CreateWindow() end
    local open = not self.window:IsShown()
    api.GetConfig().managerOpen = open
    self.window:SetShown(open)
end

function manager:UpdateMinimapButton()
    if not self.minimapLib then return end
    if api.GetConfig().managerMinimap.hide then
        self.minimapLib:Hide("RestedXP-TomTom")
    else
        self.minimapLib:Show("RestedXP-TomTom")
    end
end

function manager:Initialize()
    local tt = api.GetTomTom()
    if not tt or self.initialized then return end
    self.initialized = true
    hooksecurefunc(tt, "SetCrazyArrow", function(_, uid)
        self.active = uid
        -- TomTom can select the closest waypoint after a removal. Our next
        -- update replaces that choice with the next item in the explicit route.
        if self.running and not self.selecting and uid ~= self.routeTarget
            and (valid(self.routeTarget) or (self.waitingStep and not api.IsRxpWaypoint(uid))) then
            self:Stop()
        end
    end)
    if api.GetConfig().managerOpen then
        if not self.window then self:CreateWindow() end
        self.window:Show()
    end
    local broker = LibStub and LibStub("LibDataBroker-1.1", true)
    local icons = LibStub and LibStub("LibDBIcon-1.0", true)
    if broker and icons then
        local object = broker:NewDataObject("RestedXP-TomTom", {
            type = "launcher", label = "Waypoint Manager",
            icon = "Interface\\AddOns\\RestedXP-TomTom\\Media\\logo.blp",
            OnClick = function(_, mouseButton)
                if mouseButton == "RightButton" then api.ResumeRxp() else self:Toggle() end
            end,
            OnTooltipShow = function(tooltip)
                tooltip:AddLine("RestedXP-TomTom")
                tooltip:AddLine("Left-click: Waypoint Manager", 1, 1, 1)
                tooltip:AddLine("Right-click: Resume RXP navigation", 1, 1, 1)
                tooltip:AddLine("Drag to move", 0.7, 0.7, 0.7)
            end,
        })
        icons:Register("RestedXP-TomTom", object, api.GetConfig().managerMinimap)
        self.minimapLib = icons
        self:UpdateMinimapButton()
    end
end
