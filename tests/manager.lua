-- Run from the repository root: lua tests/manager.lua
-- Includes the existing coexistence regression suite, then loads the manager.
dofile("tests/navigation.lua")
local noop = function() end
local methods = getmetatable(RXPG_ARROW).__index
local uiFrames = {}
local originalCreateFrame = CreateFrame
function CreateFrame(...)
    local result = originalCreateFrame(...)
    local kind, _, parent, template = ...
    result.kind, result.parent, result.template = kind, parent, template
    uiFrames[#uiFrames + 1] = result
    return result
end
function methods:SetSize(width, height) self.width, self.height = width, height end
function methods:SetHeight(value) self.height = value end
function methods:SetWidth(value) self.width = value end
function methods:GetHeight() return self.height or 0 end
function methods:GetText() return self.text or "" end
function methods:SetChecked(value) self.checked = value end
function methods:GetChecked() return self.checked end
function methods:IsShown() return self.shown == true end
function methods:Show()
    local old = self.shown
    self.shown = true
    if not old and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function methods:Hide()
    local old = self.shown
    self.shown = false
    if old and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function methods:SetShown(shown) if shown then self:Show() else self:Hide() end end
function methods:Enable() self.enabled = true end
function methods:Disable() self.enabled = false end
function methods:SetScrollChild(child) self.child = child end
function methods:GetVerticalScroll() return self.scroll or 0 end
function methods:SetVerticalScroll(value) self.scroll = value end
function methods:GetEffectiveScale() return 2 end
function methods:GetTop() return 500 end
function methods:GetBottom() return 500 - self:GetHeight() end
function methods:GetLeft() return 20 end
function methods:GetRight() return 20 + (self.width or 0) end
function methods:EnableMouse(value) self.mouseEnabled = value end
function methods:SetMovable(value) self.movable = value end
function methods:StartMoving() self.moving = true end
function methods:StopMovingOrSizing() self.moving = false end
function methods:SetBackdropColor(_, _, _, alpha) self.backgroundAlpha = alpha end
function methods:SetAlpha(alpha) self.alpha = alpha end
function methods:GetFrameLevel() return self.frameLevel or 1 end
function methods:SetFrameLevel(value) self.frameLevel = value end
function methods:HighlightText() self.highlighted = true end
function methods:SetOrientation(value) self.orientation = value end
function methods:SetThumbTexture(value)
    self.thumbPath = value
    self.thumb = self:CreateTexture()
end
function methods:GetThumbTexture() return self.thumb end
function methods:SetValue(value)
    self.value = value
    if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, value) end
end
local cursorX, cursorY = 100, 500
function GetCursorPosition() return cursorX * 2, cursorY * 2 end
function methods:CreateTexture() return setmetatable({ scripts = {} }, { __index = methods }) end
for _, name in ipairs({ "SetFrameStrata", "SetClampedToScreen", "RegisterForDrag", "ClearAllPoints",
    "SetMinMaxValues", "SetValueStep", "SetBackdrop", "SetBackdropBorderColor", "SetAllPoints", "SetColorTexture",
    "SetJustifyH", "SetWordWrap", "SetAutoFocus", "SetMaxLetters", "ClearFocus", "SetFocus", "SetTextColor" }) do
    methods[name] = noop
end
UIParent = CreateFrame("Frame", "UIParent")
UISpecialFrames = {}
C_Map = {
    GetMapInfo = function(id) if id == 1 or id == 2 or id == 1213 then return { name = "Zone " .. id } end end,
    GetBestMapForUnit = function() return 1 end,
}
function TomTom:GetCurrentPlayerPosition() return 1, 0.2, 0.3 end
function TomTom:GetDistanceToWaypoint(uid) return uid.testDistance end
local launcher, minimapVisible
local broker = { NewDataObject = function(_, _, object) launcher = object; return object end }
local icons = {
    Register = function(_, _, object, db) assert(object == launcher); minimapVisible = not db.hide end,
    Show = function() minimapVisible = true end,
    Hide = function() minimapVisible = false end,
}
function LibStub(name)
    if name == "LibDataBroker-1.1" then return broker end
    if name == "LibDBIcon-1.0" then return icons end
end
assert(loadfile("WaypointManager.lua"))()
local manager = RXPTOMTOM_Manager
manager:Initialize()
local parentCategory, registeredParent
parentCategory = {}
Settings = { RegisterCanvasLayoutSubcategory = function(parent)
    registeredParent = parent
    return { GetID = function() return 123 end }
end }
manager:CreateSettings({ name = "RestedXP-TomTom", category = parentCategory })
assert(registeredParent == parentCategory and manager.settingsPanel.categoryID == 123, "manager settings nested under addon category")
local controls = manager.settingsControls
assert(controls.minimap:GetChecked() and controls.transparency.value == 2 and controls.transparency.thumb,
    "checkbox and slider thumb initialized before the settings panel is opened")
controls.lock:SetChecked(true)
controls.lock.scripts.OnClick(controls.lock)
controls.transparency:SetValue(70)
assert(launcher and minimapVisible, "optional minimap launcher registered")
RXPTOMTOM.GetConfig().managerMinimap.hide = true
manager:UpdateMinimapButton()
manager.settingsPanel.OnRefresh()
assert(not controls.minimap:GetChecked(), "settings reflect a hidden minimap button")
assert(not minimapVisible, "minimap visibility preference applies immediately")
RXPTOMTOM.GetConfig().managerMinimap.hide = false
manager:UpdateMinimapButton()
manager.settingsPanel.OnRefresh()
assert(controls.minimap:GetChecked(), "settings reflect a visible minimap button")
assert(minimapVisible, "minimap button can be restored")
launcher.OnClick(nil, "LeftButton")
assert(manager.window:IsShown(), "left-click creates and opens the complete manager UI")
assert(not manager.window.movable and math.abs(manager.window.backgroundAlpha - 0.3) < 0.001,
    "saved lock and transparency apply when manager is first created")
manager.window.scripts.OnDragStart()
assert(not manager.window.moving, "position lock blocks window dragging")
controls.lock:SetChecked(false)
controls.lock.scripts.OnClick(controls.lock)
manager.window.scripts.OnDragStart()
assert(manager.window.movable and manager.window.moving, "unlock allows moving the window immediately")
controls.lock:SetChecked(true)
controls.lock.scripts.OnClick(controls.lock)
assert(not manager.window.moving, "locking stops a move already in progress")
controls.lock:SetChecked(false)
controls.lock.scripts.OnClick(controls.lock)
controls.transparency:SetValue(100)
assert(manager.window.backgroundAlpha == 0, "fully transparent background retains independently rendered controls")
controls.transparency:SetValue(0)
assert(manager.window.backgroundAlpha == 1, "transparency slider can restore an opaque background")
controls.controlsTransparency:SetValue(65)
assert(math.abs(manager.controls.alpha - 0.35) < 0.001 and manager.window.backgroundAlpha == 1,
    "controls transparency is independent of background transparency")
controls.controlsTransparency:SetValue(0)
manager.settingsPanel.refresh()
assert(controls.transparency.value == 0 and not controls.lock:GetChecked(), "settings synchronize with saved values")
assert(manager.inputs.map:GetText() == "1" and manager.inputs.x:GetText() == "20.00", "current zone prefilled")
assert(manager.inputs.map.width == 54 and manager.inputs.x.width == 54 and manager.inputs.y.width == 54
    and manager.inputs.title.width == 174, "all inputs compacted to two thirds of their original width")
launcher.OnClick(nil, "LeftButton")
assert(not manager.window:IsShown(), "left-click toggles window closed")
SlashCmdList.RXPTOMTOM("manager")
assert(manager.window:IsShown(), "manager remains accessible without the minimap button")

local bad, err = manager:Add("1", "101", "50", "Invalid")
assert(not bad and err, "out of range coordinates rejected")
assert(not manager:Add("999", "50", "50", "Invalid map"), "unknown maps rejected")
assert(not manager:Add("1e999", "50", "50", "Infinite map"), "non-finite map IDs rejected")
local rxpTarget = TomTom.active
TomTom:SetCrazyArrow(rxpTarget)
local a = assert(manager:Add("1", "40", "50", "A"))
local b = assert(manager:Add("2", "60", "70", "B"))
assert(TomTom.active == rxpTarget, "adding targets does not interrupt current RXP navigation")
for _, row in ipairs(manager.rows) do
    if row.uid == rxpTarget then assert(not row.go.enabled, "Go disabled for the active RXP waypoint")
    else assert(row.go.enabled, "Go enabled for inactive waypoints") end
end
assert(a.persistent and a.world and a.minimap and not a.crazy, "added waypoints saved and visible")
assert(manager.order[1] == a and manager.order[2] == b, "all maps included in deterministic initial order")
manager.rows[2].scripts.OnDragStart()
assert(manager.dragUid == b and manager.dropMarker:IsShown(), "row dragging shows the insertion marker")
manager.rows[2].scripts.OnDragStop()
assert(manager.order[1] == b and manager.order[2] == a, "reorder controls change route order")
manager.order = {}
manager:Sync()
assert(manager.order[1] == b and manager.order[2] == a, "saved order restored when rebuilding the list")
local rxpRow
for _, row in ipairs(manager.rows) do if row.uid == rxpTarget then rxpRow = row end end
assert(rxpRow and not rxpRow.delete.enabled and not rxpRow.grip:IsShown(), "RXP targets protected from delete/reorder")
rxpRow.scripts.OnDragStart()
assert(not manager.dragUid, "protected rows cannot start dragging")
assert(not rxpRow.up and not rxpRow.down and rxpRow.delete.text == "", "up/down and remove text replaced")
manager:Remove(rxpTarget)
assert(TomTom:IsValidWaypoint(rxpTarget), "protected RXP targets cannot be removed through manager")

assert(manager:Start() and TomTom.active == b, "route starts at first chosen target")
for _, row in ipairs(manager.rows) do
    assert(row.go.enabled == (row.uid ~= b), "Go availability follows the active route waypoint")
end
RXPGuides.DrawArrow()
assert(TomTom.active == b, "RXP updates preserve active route")
manager:Remove(manager.routeTarget)
assert(not TomTom:IsValidWaypoint(b) and TomTom.active == a and manager.running, "remove-and-next advances in chosen order")
a.testDistance = 5
UnitOnTaxi = function() return true end
manager:Update()
assert(TomTom:IsValidWaypoint(a) and manager.running, "taxi travel must not consume a route target")
UnitOnTaxi = function() return false end
manager:Update()
assert(not TomTom:IsValidWaypoint(a) and not manager.running, "arrival consumes the final route target")
assert(TomTom:IsValidWaypoint(rxpTarget), "route completion preserves RXP waypoint")

local c = assert(manager:Add("1", "20", "30", "C"))
local d = assert(manager:Add("2", "30", "40", "D"))
manager:Start()
launcher.OnClick(nil, "RightButton")
assert(not manager.running and TomTom.active == rxpTarget, "right-click stops the route and resumes RXP")
assert(TomTom:IsValidWaypoint(c) and TomTom:IsValidWaypoint(d), "resuming RXP preserves queued targets")
manager:Start()
TomTom:SetCrazyArrow(d)
assert(not manager.running and TomTom.active == d, "an external manual selection stops route automation")
manager:Start()
manager:Stop()
manager:Update()
assert(not manager.running, "stopped routes remain stopped")
manager:Start()
TomTom:RemoveWaypoint(c)
TomTom:SetCrazyArrow(rxpTarget)
manager:Update()
assert(manager.running and TomTom.active == d, "TomTom closest fallback cannot replace explicit route order after removal")
manager:Remove(manager.routeTarget)
assert(not manager.running, "external deletion and completion leave no stale route")

local p = assert(manager:Add("1", "21", "31", "P"))
local q = assert(manager:Add("1", "22", "32", "Q"))
local r = assert(manager:Add("1", "23", "33", "R"))
manager:Navigate(q)
manager:Remove(p)
assert(TomTom.active == q, "removing an inactive target does not interrupt current navigation")
manager:Remove(q)
assert(TomTom.active == r and not manager.running, "removing a Go-selected target selects the next without starting a route")
manager:Remove(r)
assert(TomTom.active == rxpTarget, "removing the final manual target immediately resumes RXP")

local many = {}
for index = 1, 12 do many[index] = assert(manager:Add("1", tostring(index), "50", "Target " .. index)) end
local function dragRow(uid, y, x)
    manager.scroll:SetVerticalScroll(0)
    cursorX, cursorY = x or 100, y
    for _, row in ipairs(manager.rows) do
        if row.uid == uid then row.scripts.OnDragStart(); return row end
    end
    error("Missing drag row")
end
local row = dragRow(many[1], 500 - 3 * 40)
row.scripts.OnDragStop()
assert(manager.order[3] == many[1] and manager.order[1] == many[2], "drag down inserts rather than swapping distant rows")
row = dragRow(many[12], 500)
row.scripts.OnDragStop()
assert(manager.order[1] == many[12], "drag last target to first")
local savedFirst = manager.order[1]
row = dragRow(savedFirst, 480)
cursorX = 1000
row.scripts.OnDragStop()
assert(manager.order[1] == savedFirst and not manager.dropMarker:IsShown(), "drop outside list cancels")
row = dragRow(savedFirst, manager.scroll:GetBottom() + 3)
row.scripts.OnUpdate(row, 1)
assert(manager.scroll:GetVerticalScroll() > 0, "edge dragging scrolls long lists")
manager.scroll:SetVerticalScroll(manager.content:GetHeight() - manager.scroll:GetHeight())
cursorY = manager.scroll:GetBottom() + 1
row.scripts.OnDragStop()
assert(manager.order[#manager.order] == savedFirst, "drop at bottom appends before protected RXP targets")
row = dragRow(manager.order[1], 480)
manager.window:Hide()
assert(not manager.dragUid and not row.scripts.OnUpdate, "closing the window cancels drag tracking")
manager.window:Show()
local removedDuringDrag = manager.order[1]
row = dragRow(removedDuringDrag, 480)
TomTom:RemoveWaypoint(removedDuringDrag)
row.scripts.OnDragStop()
assert(not manager.dragUid, "removal of a dragged target safely cancels the drag")
-- Return to the surviving targets' original order for the row-reuse checks.
manager.order = {}
for _, uid in ipairs(many) do if TomTom:IsValidWaypoint(uid) then manager.order[#manager.order + 1] = uid end end
manager:SaveOrder()
manager:Refresh()
manager.scroll:SetVerticalScroll(1000)
manager:Refresh()
assert(manager.scroll:GetVerticalScroll() <= manager.content:GetHeight() - manager.scroll:GetHeight(), "scroll clamps to content")
local reusedRow = manager.rows[1]
local removedUid = reusedRow.uid
reusedRow.delete.scripts.OnClick()
assert(not TomTom:IsValidWaypoint(removedUid), "row remove action targets its current UID")
manager:Refresh()
reusedRow.go.scripts.OnClick()
assert(TomTom.active == reusedRow.uid, "reused row callbacks navigate to the refreshed UID")
for _, uid in ipairs(many) do manager:Remove(uid) end
manager:Refresh()
assert(manager.rows[2]:IsShown() == false, "unused rows hidden after deletion")

local clearA = assert(manager:Add("1", "10", "20", "Clear A"))
local clearB = assert(manager:Add("2", "30", "40", "Clear B"))
manager:Start()
manager.clearButton.scripts.OnClick()
assert(not manager.running and not TomTom:IsValidWaypoint(clearA) and not TomTom:IsValidWaypoint(clearB),
    "Clear & RXP stops the route and removes all regular targets across maps")
assert(not TomTom:IsValidWaypoint(rxpTarget) and TomTom.active.source == "RXPGuides" and TomTom:IsValidWaypoint(TomTom.active),
    "Clear & RXP replaces the cleared RXP target with the latest valid guide target")
manager:Sync()
assert(#manager.order == 0 and #manager.protected == 1, "only the current RXP waypoint remains after clearing")

local before = assert(manager:Add("1", "45", "55", "Before RXP"))
local after = assert(manager:Add("2", "65", "75", "After RXP"))
row = dragRow(after, manager.scroll:GetBottom() + 1)
row.scripts.OnDragStop()
local entries, liveRxp = manager:GetEntries()
assert(entries[1] == before and entries[2] == liveRxp and entries[3] == after,
    "drop below the RXP row places a target after the guide step")
assert(manager.afterRxp[after], "after-RXP placement recorded")
manager.afterRxp = {}
manager:Sync()
assert(manager.afterRxp[after], "after-RXP placement restored from saved ordering")
manager:Reorder(after, liveRxp)
assert(not manager.afterRxp[after], "a deferred target can be moved back above RXP")
row = dragRow(after, manager.scroll:GetBottom() + 1)
row.scripts.OnDragStop()
local waitingStep = RXPG_ARROW.element.step
assert(manager:Start() and TomTom.active == before, "route starts with targets above RXP")
manager:Remove(before)
assert(manager.running and manager.waitingStep == waitingStep and TomTom.active.source == "RXPGuides",
    "route resumes RXP and waits at the RXP boundary")
TomTom.active.testDistance = 0
manager:Update()
assert(manager.waitingStep == waitingStep and TomTom:IsValidWaypoint(after),
    "RXP coordinate arrival alone does not complete its guide step")
RXPG_ARROW.element = { zone = 1, x = 31, y = 41, step = waitingStep }
RXPGuides.DrawArrow()
manager:Update()
assert(manager.waitingStep == waitingStep and TomTom.active.source == "RXPGuides",
    "changing the arrow target within the same RXP step keeps the route waiting")
waitingStep.completed = true
RXPG_ARROW.element = { zone = 1, x = 32, y = 42, step = { index = 3 } }
RXPGuides.DrawArrow()
manager:Update()
assert(manager.running and not manager.waitingStep and TomTom.active == after,
    "completed RXP step activates the deferred waypoint")
manager:Remove(after)
assert(not manager.running and TomTom.active.title == "RXP Step 3", "route returns to the current guide after the deferred target")

local deferred = assert(manager:Add("2", "40", "50", "Progress test"))
manager:Reorder(deferred, nil)
RXPGuides.currentGuide = {}
local progress = 3
RXPGuides.GetGuideProgress = function() return progress end
assert(manager:Start() and manager.waitingStep, "route with only after-RXP targets begins by waiting")
local element = RXPG_ARROW.element
RXPG_ARROW.element = nil
manager:Update()
assert(manager.waitingStep and TomTom:IsValidWaypoint(deferred), "temporary missing RXP arrow does not release deferred targets")
RXPG_ARROW.element = element
progress = 4
manager:Update()
assert(TomTom.active == deferred and not manager.waitingStep, "advancing past the captured RXP step releases the queued target")
manager:Remove(deferred)
local switched = assert(manager:Add("2", "41", "51", "Guide switch"))
manager:Reorder(switched, nil)
progress = 3
assert(manager:Start() and manager.waitingStep)
RXPGuides.currentGuide = {}
manager:Update()
assert(not manager.running and TomTom:IsValidWaypoint(switched), "unrelated guide switch cancels waiting and preserves queued targets")
manager:ClearAndResume()

local pasteCases = {
    { "/way #1213 35.2 57.2 Target 7", { map = 1213, x = 35.2, y = 57.2, title = "Target 7" } },
    { "#1213 35.2 57.2", { map = 1213, x = 35.2, y = 57.2 } },
    { "1213 35.2 57.2", { map = 1213, x = 35.2, y = 57.2 } },
    { "35.2 57.2", { x = 35.2, y = 57.2 } },
    { "/WAY 35.2 57.2 Bare coordinates", { x = 35.2, y = 57.2, title = "Bare coordinates" } },
    { "35,2 57,2", { x = 35.2, y = 57.2 } },
    { "35.2,57.2 Compact pair", { x = 35.2, y = 57.2, title = "Compact pair" } },
    { "(35.2, 57.2)", { x = 35.2, y = 57.2 } },
    { "35,57", { x = 35, y = 57 } },
    { "# 1213", { map = 1213 } },
    { "/tway #1213 35,2 57,2 Target", { map = 1213, x = 35.2, y = 57.2, title = "Target" } },
    { "57.2", { y = 57.2 }, "y" },
    { "2", { map = 2 }, "map" },
    { "#1213 35.2", { map = 1213, x = 35.2 } },
}
for _, case in ipairs(pasteCases) do
    local fields, err = manager:ParseWaypointText(case[1], case[3])
    assert(fields, case[1] .. ": " .. tostring(err))
    for key, value in pairs(case[2]) do assert(fields[key] == value, case[1] .. " / " .. key) end
    for key in pairs(fields) do assert(case[2][key] ~= nil, "unexpected parsed field: " .. case[1]) end
end
for _, bad in ipairs({ "", "/run print('bad')", "/way reset all", "#invalid 10 20", "#999 10 20",
    "10 101", "#1.5 10 20", "10 20\n30 40", "#1 10 invalid" }) do
    assert(not manager:ParseWaypointText(bad), "invalid or ambiguous paste must not change the form: " .. bad)
end
manager.inputs.map:SetText("2")
manager.inputs.title:SetText("Keep title")
local previousAdds = TomTom.adds
assert(manager:ApplyPastedText("35.2 57.2"))
assert(manager.inputs.map:GetText() == "2" and manager.inputs.title:GetText() == "Keep title",
    "coordinate-only pastes preserve the existing map and title")
assert(TomTom.adds == previousAdds, "paste fills the form without creating a waypoint")
local oldX = manager.inputs.x:GetText()
assert(not manager:ApplyPastedText("#1213 bad coordinates") and manager.inputs.x:GetText() == oldX,
    "failed paste leaves existing values untouched")
local originalGetTime = GetTime
local now = GetTime()
GetTime = function() return now end
IsControlKeyDown = function() return true end
local function nativePaste(key, value)
    local field = manager.inputs[key]
    field.scripts.OnKeyDown(field, "V")
    assert(field.highlighted, "native paste replaces the existing field rather than appending")
    field:SetText(value)
    field.scripts.OnTextChanged(field, true)
    now = now + 0.2
    manager:Update()
end
for _, key in ipairs({ "map", "x", "y", "title" }) do
    manager.inputs.map:SetText("2")
    manager.inputs.title:SetText("Previous title")
    nativePaste(key, "/way #1213 35.2 57.2 Imported target")
    assert(manager.inputs.map:GetText() == "1213" and manager.inputs.x:GetText() == "35.2"
        and manager.inputs.y:GetText() == "57.2" and manager.inputs.title:GetText() == "Imported target",
        "full waypoint paste distributed correctly from " .. key)
    manager.inputs.map:SetText("2")
    manager.inputs.title:SetText("Keep title")
    nativePaste(key, "35.2 57.2")
    assert(manager.inputs.map:GetText() == "2" and manager.inputs.title:GetText() == "Keep title",
        "coordinate-only paste preserves map and title when pasted into " .. key)
end
nativePaste("y", "64.5")
assert(manager.inputs.y:GetText() == "64.5", "single pasted coordinate respects the Y field")
nativePaste("title", "Meeting point 42")
assert(manager.inputs.title:GetText() == "Meeting point 42", "plain title paste remains a title")
local oldMap = manager.inputs.map:GetText()
nativePaste("map", "#999 10 20")
assert(manager.inputs.map:GetText() == oldMap, "invalid paste restores the source field")
-- Mac's modifier follows the same native paste handling.
IsControlKeyDown = function() return false end
IsMetaKeyDown = function() return true end
nativePaste("title", "/way #1213 35.2 57.2 Imported target")
IsMetaKeyDown = function() return false end
assert(not manager.pasteButton and not manager.pasteCapture and not manager.fieldPaste,
    "direct field paste requires no button or hidden activation input")
local titleField = manager.inputs.title
titleField:SetText("")
titleField.scripts.OnTextChanged(titleField, false)
local typed = "42 53 meeting point"
for index = 1, #typed do
    titleField:SetText(typed:sub(1, index))
    titleField.scripts.OnTextChanged(titleField, true)
end
assert(not manager.fieldPaste and titleField:GetText() == typed, "ordinary typing of numeric-looking titles does not trigger import")
manager.inputs.map:SetText("2")
manager.inputs.x:SetText("10")
manager.inputs.x.scripts.OnTextChanged(manager.inputs.x, false)
manager.inputs.x:SetText("35.2 57.2")
manager.inputs.x.scripts.OnTextChanged(manager.inputs.x, true)
now = now + 0.2
manager:Update()
assert(manager.inputs.map:GetText() == "2" and manager.inputs.y:GetText() == "57.2",
    "compound paste fallback works when a client omits the key callback")
local previousX = manager.inputs.x:GetText()
manager:PrepareFieldPaste("x")
manager.inputs.x:SetText("/way #1213 1 2")
manager.inputs.x.scripts.OnTextChanged(manager.inputs.x, true)
manager.inputs.x.scripts.OnEscapePressed()
assert(not manager.fieldPaste and manager.inputs.x:GetText() == previousX, "Escape cancels a pending import and restores its source")
IsControlKeyDown = function() return true end
nativePaste("title", "/way #1213 35.2 57.2 Imported target")
assert(manager.mapNotice:IsShown() and manager.mapNotice.text:find("Zone 1213", 1, true),
    "pasting a map ID briefly identifies its zone")
now = now + 4
manager:Update()
assert(not manager.mapNotice:IsShown() and manager.addLabel:IsShown(), "zone notice expires")
GetTime = originalGetTime
manager.inputs.map:SetText("#1213")
manager.inputs.map.scripts.OnEditFocusLost(manager.inputs.map)
assert(manager.inputs.map:GetText() == "1213", "manually entered # map IDs are normalized")
local imported = assert(manager:Add("#1213", "35,2", "57,2", "Imported target"))
assert(imported[1] == 1213 and math.abs(imported[2] - 0.352) < 1e-10 and math.abs(imported[3] - 0.572) < 1e-10,
    "TomTom receives numeric map IDs and normalized decimal coordinates")
local copyRow
for _, item in ipairs(manager.rows) do if item.uid == imported then copyRow = item end end
copyRow.scripts.OnMouseUp(copyRow, "RightButton")
assert(manager.clipboardMode == "copy" and manager.clipboardEdit.highlighted, "right-click selects the exported waypoint for copying")
local exported = manager.clipboardEdit:GetText()
assert(exported:find("/way #1213 35.2000 57.2000 Imported target", 1, true), "copy export uses explicit map ID and title")
local roundTrip = assert(manager:ParseWaypointText(exported))
assert(roundTrip.map == 1213 and roundTrip.x == 35.2 and roundTrip.y == 57.2 and roundTrip.title == "Imported target",
    "copy output round-trips through the paste parser")
manager.clipboardEdit.scripts.OnEnterPressed()
assert(not manager.clipboardPanel:IsShown(), "Enter closes copy view without importing or adding anything")
manager:Remove(imported)

assert(RXPTOMTOM.GetConfig().managerOpen, "desired window visibility saved by explicit toggle")
manager.window:Hide()
assert(RXPTOMTOM.GetConfig().managerOpen, "temporary window hides do not overwrite saved visibility")
for _, frame in ipairs(uiFrames) do
    assert(not (frame.template == "UIPanelCloseButton" and frame.parent == manager.window), "manager has no close X")
end
for _, name in ipairs(UISpecialFrames) do assert(name ~= "RXPTOMTOM_WaypointManager", "Escape does not close manager") end
assert(loadfile("WaypointManager.lua"))()
local restored = RXPTOMTOM_Manager
restored:Initialize()
assert(restored.window and restored.window:IsShown(), "open manager restored during next login initialization")
restored:Toggle()
assert(not RXPTOMTOM.GetConfig().managerOpen and not restored.window:IsShown(), "explicit hide persists")
assert(loadfile("WaypointManager.lua"))()
RXPTOMTOM_Manager:Initialize()
assert(not RXPTOMTOM_Manager.window, "saved closed manager remains closed next session")
print("Waypoint Manager UI and route checks passed")
