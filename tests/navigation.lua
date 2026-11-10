-- Run from the repository root: lua tests/navigation.lua
local frames, clock = {}, 0
local noop = function() end
local methods = {
    SetPoint = noop, SetSize = noop, SetAlpha = noop, Show = noop,
    Hide = noop, RegisterEvent = noop, SetChecked = noop,
    SetText = function(self, text) self.text = text end,
    GetName = function(self) return self.name end,
    SetScript = function(self, event, fn) self.scripts[event] = fn end,
    GetScript = function(self, event) return self.scripts[event] end,
}
local function widget(name)
    return setmetatable({ name = name, scripts = {} }, { __index = methods })
end
function methods:CreateFontString() return widget() end
function CreateFrame(_, name)
    local result = widget(name)
    result.Text = widget()
    frames[#frames + 1] = result
    if name then _G[name] = result end
    return result
end
function GetTime() return clock end
function hooksecurefunc(object, method, callback)
    local original = object[method]
    object[method] = function(...)
        original(...)
        callback(...)
    end
end
DEFAULT_CHAT_FRAME = { AddMessage = noop }
SlashCmdList = {}
CLOSE = "Close"
RXPFrame = { bottomMenu = { { text = CLOSE } } }
RXPG_ARROW = widget("RXPG_ARROW")
RXPG_ARROW.element = { zone = 1, x = 20, y = 30, step = { index = 1 } }
RXPGuides = { DrawArrow = noop, settings = { profile = {} } }
TomTom = {
    waypoints = {}, profile = { arrow = { arrival = 10 } },
    adds = 0, selections = 0,
}
local waypointStorage = TomTom.waypoints
function TomTom:AddWaypoint(map, x, y, options)
    local uid = { map, x, y, title = options.title }
    for k, v in pairs(options) do uid[k] = v end
    waypointStorage[map] = waypointStorage[map] or {}
    waypointStorage[map][uid] = uid
    self.adds = self.adds + 1
    if options.crazy then self:SetCrazyArrow(uid) end
    return uid
end
function TomTom:SetCrazyArrow(uid)
    self.active = uid
    self.selections = self.selections + 1
end
function TomTom:RemoveWaypoint(uid) waypointStorage[uid[1]][uid] = nil end
function TomTom:IsValidWaypoint(uid)
    return waypointStorage[uid[1]] and waypointStorage[uid[1]][uid] ~= nil
end
local startupTarget
if arg[1] == "preexisting" then
    startupTarget = TomTom:AddWaypoint(1, 0.3, 0.4, { title = "Existing route", crazy = true })
end
assert(loadfile("RestedXP-TomTom.lua"))("RestedXP-TomTom")
if arg[1] == "with-manager" then assert(loadfile("WaypointManager.lua"))() end
local driver = frames[1]
driver.scripts.OnEvent(driver, "PLAYER_LOGIN")
local function advance(seconds)
    clock = clock + seconds
    driver.scripts.OnUpdate(driver, seconds)
end
advance(0.25)
if startupTarget then
    assert(TomTom.active == startupTarget, "preserve a manager target selected before addon login")
    TomTom:RemoveWaypoint(startupTarget)
    advance(0.25)
    advance(0.5)
end
local initial = TomTom.active
assert(initial and initial.source == "RXPGuides", "initial RXP navigation")
local adds, selections = TomTom.adds, TomTom.selections
advance(0.25)
assert(TomTom.adds == adds and TomTom.selections == selections, "stable target must not churn")

local a = TomTom:AddWaypoint(1, 0.4, 0.5, { title = "A", crazy = true })
local b = TomTom:AddWaypoint(2, 0.6, 0.7, { title = "B" })
RXPG_ARROW.element = { zone = 1, x = 25, y = 35, step = { index = 2 } }
RXPGuides.DrawArrow()
assert(TomTom.active == a, "RXP step changes must not interrupt a foreign target")
TomTom:RemoveWaypoint(a)
TomTom:SetCrazyArrow(b)
advance(1)
assert(TomTom.active == b, "the manager's second waypoint retains priority")
TomTom.active = nil
advance(1)
assert(TomTom.active == nil, "stored foreign waypoints block automatic resume even without an arrow")
TomTom:RemoveWaypoint(b)
advance(0.25)
if arg[1] == "with-manager" then
    assert(TomTom.active and TomTom.active.source == "RXPGuides", "manager immediately resumes after its final active target is removed")
else
    assert(TomTom.active == nil, "wait for manager removal/selection to settle")
end
advance(0.5)
assert(TomTom.active and TomTom.active.title == "RXP Step 2", "resume the CURRENT RXP target")
local resumed = TomTom.active
TomTom:RemoveWaypoint(resumed)
advance(0.25)
assert(TomTom.active ~= resumed and TomTom:IsValidWaypoint(TomTom.active), "recreate a deleted RXP waypoint")

local c = TomTom:AddWaypoint(1, 0.8, 0.9, { title = "C", crazy = true })
local d = TomTom:AddWaypoint(2, 0.2, 0.3, { title = "D" })
local resumeButton
for _, frame in ipairs(frames) do
    if frame.text == "Resume RXP navigation" then resumeButton = frame end
end
assert(resumeButton, "resume action appears in addon options")
resumeButton.scripts.OnClick(resumeButton)
assert(TomTom.active.source == "RXPGuides", "explicit menu action resumes with foreign waypoints present")
assert(TomTom:IsValidWaypoint(c) and TomTom:IsValidWaypoint(d), "manual resume preserves all manager waypoints")
assert(RXPFrame.bottomMenu[1].text == "Resume RXP navigation", "resume action appears before Close in RXP menu")
TomTom:SetCrazyArrow(c)
advance(1)
assert(TomTom.active == c, "a subsequent manager selection pauses RXP again")
local storage = TomTom.waypoints
TomTom.waypoints = nil
advance(1)
assert(TomTom.active == c, "unknown waypoint storage never authorizes auto-resume")
TomTom.waypoints = storage
TomTom:RemoveWaypoint(c)
TomTom:RemoveWaypoint(d)
local e = TomTom:AddWaypoint(1, 0.1, 0.2, { title = "E", crazy = true })
advance(1)
assert(TomTom.active == e, "replacement routes added after a bulk removal retain priority")
TomTom:RemoveWaypoint(e)
advance(0.25)
advance(0.5)
assert(TomTom.active.source == "RXPGuides", "resume after the final replacement waypoint is removed")
print("Navigation regression checks passed")
