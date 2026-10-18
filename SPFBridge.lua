-- ShortestPathForever bridge. Data only, no drawing:
-- navigation target (direction point plus RXP step target), own distance, cached arrival time, transport state,
-- and the sync of our options into SPF's settings with remembering and restoring the previous values.
local addonName, ns = ...
local L = ns.L

local OWNER = "RestedXP" -- SPF's owner id for RXP guidance
local METRES_PER_YARD = 0.9144 -- SPF/Distance.lua:9
local ETA_INTERVAL = 1 -- seconds between SPF queries
local BEND_RADIUS = 30 -- yards to the SPF waypoint for the transport state
local TRANSPORT_MODES = {
    flight = true, boat = true, zeppelin = true, lift = true, tram = true,
    portal = true, passage = true, teleport = true,
}

local SPF = {}
ns.SPF = SPF

-- ---------------------------------------------------------------------------------------------------------------
-- Small helpers

local function IsNum(v)
    return ns.CanAccess(v) and type(v) == "number"
end

local Try = ns.Try

-- x, y of a map position: Vector2D object (GetXY) or a plain table with x/y (waypoint position on Forever).
local function RawXY(pos)
    if pos.GetXY then return pos:GetXY() end
    return pos.x, pos.y
end

local function PosXY(pos)
    local t = type(pos)
    if t ~= "table" and t ~= "userdata" then return end
    local ok, x, y = pcall(RawXY, pos) -- no closure: this runs at the arrow's 20 Hz
    if ok and IsNum(x) and IsNum(y) then return x, y end
end

-- Map position (uiMapID, 0-1 coordinates) to world position in UnitPosition coordinates.
-- Returns continentID, x, y or nothing.
local function WorldPos(mapID, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
    if not (IsNum(mapID) and IsNum(x) and IsNum(y)) then return end
    local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
    if not ok or not IsNum(cont) then return end
    local wx, wy = PosXY(pos)
    if wx then return cont, wx, wy end
end

-- RXP wraps names in colour tokens ("RXP_FRIENDLY_") and escape codes; keep the plain words.
local function CleanName(text)
    if type(text) ~= "string" or not ns.CanAccess(text) then return end
    text = text:gsub("RXP_%u+_", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:match("^%s*(.-)%s*$")
    if text ~= "" then return text end
end

function ns.FormatTime(seconds)
    if not IsNum(seconds) or seconds < 0 then return end
    seconds = math.floor(seconds + 0.5)
    local h, m, s = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
    if h > 0 then return ("%d:%02d:%02d"):format(h, m, s) end
    return ("%d:%02d"):format(m, s)
end

-- Yards to the display unit (nav.unit "m" or "yd"); SPF counts metres as yards * 0.9144.
function ns.ToUnit(yards, unit)
    if unit == "yd" then return yards end
    return yards * METRES_PER_YARD
end

-- ---------------------------------------------------------------------------------------------------------------
-- SPF presence

function SPF.Loaded()
    local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
    return isLoaded and Try(isLoaded, "ShortestPathForever") == true or false
end

-- ShortestPathForever.API, only when it has the calls we use.
function SPF.Api()
    local spf = _G.ShortestPathForever
    local api = type(spf) == "table" and spf.API
    if type(api) == "table" and type(api.CurrentStop) == "function" and type(api.EstimateDetail) == "function" then
        return api
    end
end

function SPF.Version()
    local get = C_AddOns and C_AddOns.GetAddOnMetadata
    local v = get and Try(get, "ShortestPathForever", "Version")
    if type(v) == "string" and ns.CanAccess(v) and v ~= "" then return v end
end

-- Effective source: "SPF" only when chosen (SPF or AUTO) and SPF is there; else "RXP".
function ns.NavSource()
    local nav = ns.db and ns.db.nav
    local configured = nav and nav.source or "SPF"
    if configured ~= "RXP" and SPF.Api() then return "SPF", configured end
    return "RXP", configured
end

-- ---------------------------------------------------------------------------------------------------------------
-- Player

-- x (north), y (west), instance/continent id; nothing when not readable (instance, secret, loading).
function ns.PlayerPos()
    if type(UnitPosition) ~= "function" then return end
    local x, y, _, inst = UnitPosition("player")
    if not (IsNum(x) and IsNum(y) and IsNum(inst)) then return end
    return x, y, inst
end

function ns.PlayerFacing()
    if type(GetPlayerFacing) ~= "function" then return end
    local facing = GetPlayerFacing()
    if IsNum(facing) then return facing end
end

-- uiMapID and 0-1 coordinates of the player for SPF estimates.
local function PlayerMapPos()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not IsNum(mapID) then return end
    local x, y = PosXY(C_Map.GetPlayerMapPosition(mapID, "player"))
    if x then return mapID, x, y end
end

-- Straight-line yards from the player to a world point; nil plus a reason otherwise.
function ns.DistanceTo(cont, x, y)
    local px, py, inst = ns.PlayerPos()
    if not px then return nil, "unreadable" end
    if inst ~= cont then return nil, "continent" end
    local dx, dy = x - px, y - py
    return math.sqrt(dx * dx + dy * dy)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Target: direction point plus the RXP step target ("goal") for distance, ETA and radius.

-- Last computed goal per RXP element and coordinates; the element changes only when RXP moves to another target.
local goalCache = {}

-- The RXP step target from zone/x/y, never wx/wy. Table with mapID, mx, my (0-1), cont, x, y, name, radius and
-- key (identifies the target for the ETA cache and the arrow's "arrived" latch). Read only: the table is shared.
local function RXPGoal()
    local frame = _G.RXP and _G.RXP.arrowFrame
    local e = type(frame) == "table" and frame.element
    if type(e) ~= "table" then return end
    if not (IsNum(e.zone) and IsNum(e.x) and IsNum(e.y)) then return end
    local c = goalCache
    if c.e == e and c.zone == e.zone and c.ex == e.x and c.ey == e.y then return c.value end
    local mx, my = e.x / 100, e.y / 100
    local cont, x, y = WorldPos(e.zone, mx, my)
    if not cont then return end -- not cached: may be readable again after a loading screen
    local step = type(e.step) == "table" and e.step or nil
    local value = {
        mapID = e.zone, mx = mx, my = my, cont = cont, x = x, y = y,
        name = CleanName(e.title) or (step and (CleanName(step.arrowtext) or CleanName(step.title))) or nil,
        radius = IsNum(e.radius) and e.radius > 0 and e.radius or nil,
        key = ("%d:%.5f:%.5f"):format(e.zone, mx, my),
    }
    c.e, c.zone, c.ex, c.ey, c.value = e, e.zone, e.x, e.y, value
    return value
end

-- SPF's current waypoint (the next bend of its route) while SPF guides RestedXP and that waypoint is tracked.
local function SPFWaypoint()
    local api = SPF.Api()
    if not api then return end
    if not Try(api.CurrentStop, OWNER) then return end
    local tracking = C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint
    if not (tracking and Try(tracking)) then return end
    local wp = C_Map.GetUserWaypoint and Try(C_Map.GetUserWaypoint)
    if type(wp) ~= "table" or not ns.CanAccess(wp) then return end
    local x, y = PosXY(wp.position)
    if not x then return end
    return WorldPos(wp.uiMapID, x, y)
end

local targetCache = { time = -1 }

-- Returns { source = "SPF"|"RXP", cont, x, y, goal = <RXP step target or nil> } or nil.
-- Cached for the current frame; callers may run at 20 Hz.
function ns.Target()
    local now = GetTime()
    if targetCache.time == now then return targetCache.value end
    local value
    local goal = RXPGoal()
    if ns.NavSource() == "SPF" then
        local cont, x, y = SPFWaypoint()
        if cont then value = { source = "SPF", cont = cont, x = x, y = y, goal = goal } end
    end
    if not value and goal then
        value = { source = "RXP", cont = goal.cont, x = goal.x, y = goal.y, goal = goal } -- fallback
    end
    targetCache.time, targetCache.value = now, value
    return value
end

-- ---------------------------------------------------------------------------------------------------------------
-- Arrival time: EstimateDetail at most once per second, held in combat.

local eta = { time = -ETA_INTERVAL, key = nil, seconds = nil, legs = nil, reason = nil, stale = false }

local function ClearETA(reason)
    eta.seconds, eta.legs, eta.reason, eta.stale = nil, nil, reason, false
end

-- Returns the shared table { seconds, legs, reason, stale }; read only. seconds is nil when unknown.
function ns.ETA()
    local api = SPF.Api()
    local t = ns.Target()
    local goal = t and t.goal
    if not api or not goal then
        eta.key = nil
        ClearETA(api and "nogoal" or "nospf")
        return eta
    end
    local key = goal.key
    if InCombatLockdown() then -- SPF answers "combat"; keep the last value for the same goal
        if key ~= eta.key then eta.key = key; ClearETA("combat") else eta.stale = eta.seconds ~= nil end
        return eta
    end
    local now = GetTime()
    if key == eta.key and now - eta.time < ETA_INTERVAL then return eta end
    eta.time, eta.key = now, key
    local mapID, mx, my = PlayerMapPos()
    if not mapID then
        ClearETA("unreadable")
        return eta
    end
    local ok, detail, reason = pcall(api.EstimateDetail, mapID, mx, my, goal.mapID, goal.mx, goal.my)
    if ok and type(detail) == "table" and IsNum(detail.seconds) then
        eta.seconds, eta.legs, eta.reason, eta.stale = detail.seconds, detail.legs, nil, false
    elseif ok and reason == "combat" then
        eta.stale = eta.seconds ~= nil
    else
        ClearETA(ok and type(reason) == "string" and reason or "error")
    end
    return eta
end

-- Transport state, data only: first leg walking, the SPF bend within 30 yards, second leg a
-- vehicle. Returns { mode, to, wait } or nil. Needs SPF guidance (the bend is SPF's waypoint).
function ns.Transport()
    local t = ns.Target()
    if not t or t.source ~= "SPF" then return end
    local legs = ns.ETA().legs
    if type(legs) ~= "table" or type(legs[1]) ~= "table" or type(legs[2]) ~= "table" then return end
    if legs[1].mode ~= "walk" or not TRANSPORT_MODES[legs[2].mode] then return end
    local bend = ns.DistanceTo(t.cont, t.x, t.y)
    if not bend or bend >= BEND_RADIUS then return end
    local second = legs[2]
    return {
        mode = second.mode,
        to = type(second.to) == "string" and second.to or nil,
        wait = IsNum(second.wait) and second.wait or nil, -- only when SPF reports >= 60 s
    }
end

-- ---------------------------------------------------------------------------------------------------------------
-- SPF settings sync

local SPF_TYPE = {
    arrow = "boolean", restedxp = "boolean", journey = "boolean", teleports = "boolean", guideStops = "boolean",
    metres = "boolean", compass = "boolean", pins = "boolean", mapRoutes = "boolean", minimapPins = "boolean",
    compassScale = "number", compassBackground = "number", mapPinScale = "number",
    transit = "boolean", portals = "boolean", mapFlightMasters = "boolean",
    flightPinScale = "number", minimapPinScale = "number", -- only where this SPF version has them (Write checks)
    journeyTracker = "boolean", compassTime = "boolean",
}

local reloadHinted = false

local function SettingObject(key)
    local get = Settings and Settings.GetSetting
    local s = get and Try(get, "ShortestPathForever_" .. key)
    if type(s) == "table" and type(s.GetValue) == "function" and type(s.SetValue) == "function" then return s end
end

function SPF.Has(key)
    return SPF.Loaded() and SPF.Get(key) ~= nil
end

function SPF.Get(key)
    local s = SettingObject(key)
    if s then
        local ok, value = pcall(s.GetValue, s)
        if ok then return value end
    end
    local db = _G.ShortestPathForeverDB
    if type(db) == "table" then return db[key] end
end

-- Writes through the Settings API so SPF runs its own callbacks; without it, straight into SPF's DB plus a
-- /reload hint. With remember, the previous value is stored once in EUIRestedXPSkinDB.spfBackup.
local function Write(key, value, remember)
    if SPF_TYPE[key] == nil or type(value) ~= SPF_TYPE[key] or not SPF.Loaded() then return false end
    local previous = SPF.Get(key)
    if previous == value then return true end
    if remember and ns.db and previous ~= nil then
        ns.db.spfBackup = ns.db.spfBackup or {}
        if ns.db.spfBackup[key] == nil then ns.db.spfBackup[key] = previous end
    end
    local s = SettingObject(key)
    if s and pcall(s.SetValue, s, value) and SPF.Get(key) == value then return true end -- SPF ran its own refresh
    local db = _G.ShortestPathForeverDB
    if type(db) ~= "table" or db[key] == nil then return false end -- never invent a key this SPF version does not know
    db[key] = value
    if not reloadHinted then
        reloadHinted = true
        ns.Say(L["ShortestPathForever settings were saved directly. Type /reload to apply them."])
    end
    return true
end

-- Set an SPF setting on behalf of the user; deferred until combat ends (settings callbacks stay out of combat).
function SPF.Set(key, value)
    if SPF_TYPE[key] == nil or type(value) ~= SPF_TYPE[key] or not SPF.Loaded() then return false end
    ns.Queue(function() Write(key, value, true) end)
    return true
end

-- Put one remembered SPF value back (e.g. arrow when the source leaves RXP).
function SPF.RestoreKey(key)
    ns.Queue(function()
        local backup = ns.db and ns.db.spfBackup
        if type(backup) ~= "table" or backup[key] == nil then return end
        -- forget the remembered value only once it is back in SPF (SPF may be missing this session)
        if Write(key, backup[key], false) then backup[key] = nil end
    end)
end

-- "Reset to defaults": write all remembered values back and forget them. Call before wiping EUIRestedXPSkinDB.
function SPF.RestoreAll()
    local backup = ns.db and ns.db.spfBackup
    if type(backup) ~= "table" then return end
    local snapshot = {}
    for key, value in pairs(backup) do snapshot[key] = value end
    ns.db.spfBackup = nil
    ns.Queue(function()
        for key, value in pairs(snapshot) do Write(key, value, false) end
    end)
end

-- Source SPF/AUTO needs restedxp + journey on; arrow stays as the user had it. Source RXP gives those back and
-- hides SPF's arrow only when asked (arrow = false takes SPF its waypoints, so never with SPF guiding).
local function SyncSource(nav)
    if nav.source == "RXP" then
        SPF.RestoreKey("restedxp")
        SPF.RestoreKey("journey")
        if nav.replaceSpfArrow then SPF.Set("arrow", false) else SPF.RestoreKey("arrow") end
    else
        SPF.Set("restedxp", true)
        SPF.Set("journey", true)
        SPF.RestoreKey("arrow")
    end
end

local SYNC = {
    source = SyncSource,
    replaceSpfArrow = SyncSource,
    transports = function(nav) SPF.Set("teleports", nav.transports == true) end, -- teleports only
    stepEndOnly = function(nav) SPF.Set("guideStops", nav.stepEndOnly == true) end,
    unit = function(nav) SPF.Set("metres", nav.unit == "m") end,
}

-- Call after the user changed one of nav.source, replaceSpfArrow, transports, stepEndOnly, unit
-- (no argument: all of them). Not called on load: SPF's values are only touched on a user change.
function SPF.OnOptionChanged(name)
    local nav = ns.db and ns.db.nav
    if not nav then return end
    targetCache.time = -1
    eta.key = nil
    if SPF.Loaded() then
        if name then
            if SYNC[name] then SYNC[name](nav) end
        else
            SyncSource(nav)
            SYNC.transports(nav)
            SYNC.stepEndOnly(nav)
            SYNC.unit(nav)
        end
    end
    ns.RefreshAll()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Debug: /euirxp nav prints the route source and arrow target

local function S(v) return tostring(v) end

local function Num(v, decimals)
    if not IsNum(v) then return "-" end
    return (("%%.%df"):format(decimals or 1)):format(v)
end

function ns.NavDebug()
    local say = ns.Say
    local effective, configured = ns.NavSource()
    local t = ns.Target()
    local api = SPF.Api()
    local stop = api and Try(api.CurrentStop, OWNER)
    local tracking = C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint and Try(C_SuperTrack.IsSuperTrackingUserWaypoint)
    say(("source: configured %s  effective %s  actual %s"):format(S(configured), S(effective), S(t and t.source or "none")))
    say(("SPF: loaded %s  version %s  API %s  CurrentStop(%s) %s  waypoint tracked %s"):format(
        S(SPF.Loaded()), S(SPF.Version()), S(api ~= nil), OWNER, S(stop), S(tracking)))
    local px, py, inst = ns.PlayerPos()
    say(("player: instance %s  x %s  y %s  facing %s"):format(S(inst), Num(px), Num(py), Num(ns.PlayerFacing(), 2)))
    if not t then
        say("target: none (no RXP step target and no SPF waypoint)")
        return
    end
    say(("direction point: continent %s  x %s  y %s"):format(S(t.cont), Num(t.x), Num(t.y)))
    local goal = t.goal
    if goal then
        local yards, why = ns.DistanceTo(goal.cont, goal.x, goal.y)
        local unit = ns.db.nav.unit
        say(("goal: map %s  %s / %s  name %s  radius %s"):format(
            S(goal.mapID), Num(goal.mx * 100, 2), Num(goal.my * 100, 2), S(goal.name), S(goal.radius)))
        if yards then
            say(("distance: %s yd = %s m  (arrow shows %s %s)"):format(
                Num(yards, 0), Num(ns.ToUnit(yards, "m"), 0), Num(ns.ToUnit(yards, unit), 0), S(unit)))
        else
            say("distance: none (" .. S(why) .. ")")
        end
    else
        say("goal: none (SPF waypoint only)")
    end
    if t.source == "SPF" then
        say(("next bend: %s yd away"):format(Num((ns.DistanceTo(t.cont, t.x, t.y)), 0)))
    end
    local e = ns.ETA()
    if e.seconds then
        local modes = {}
        for i, leg in ipairs(type(e.legs) == "table" and e.legs or {}) do modes[i] = S(leg.mode) end
        say(("ETA: %s  (%s s)%s  legs: %s"):format(
            S(ns.FormatTime(e.seconds)), Num(e.seconds, 0), e.stale and "  held (combat)" or "",
            #modes > 0 and table.concat(modes, " > ") or "-"))
    else
        say("ETA: none (" .. S(e.reason) .. ")")
    end
    local tr = ns.Transport()
    if tr then
        say(("transport: %s to %s  wait %s s"):format(S(tr.mode), S(tr.to), Num(tr.wait, 0)))
    else
        say("transport: no")
    end
end
