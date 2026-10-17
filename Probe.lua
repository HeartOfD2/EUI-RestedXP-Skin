-- /euirxp probe: reports what this client actually provides, for bug reports.
-- Values that may be secret are printed only after ns.CanAccess.
local addonName, ns = ...

local function Has(value) return value ~= nil and "yes" or "NO" end

local function Fmt(value)
    if not ns.CanAccess(value) then return "secret" end
    return tostring(value)
end

local Try = ns.Try

local function Version(name)
    local v = Try(C_AddOns.GetAddOnMetadata, name, "Version")
    return v and Fmt(v) or "nil"
end

local function Loaded(name)
    return tostring(Try(C_AddOns.IsAddOnLoaded, name) == true)
end

local SPF_KEYS = {
    "arrow", "restedxp", "journey", "teleports", "taxiRoute", "guideStops", "metres", "compass",
    "compassScale", "compassBackground", "pins", "mapRoutes", "minimapPins", "mapPinScale",
}

local function ProbeBasics(say, safe)
    local _, build, _, iface = GetBuildInfo()
    say(("build %s  interface %s  locale %s (texts %s)"):format(safe(build, "?"), safe(iface, "?"), GetLocale(), ns.Locale())) -- lint:ignore
    say(("WOW_PROJECT_ID %s  WOW_PROJECT_CAMELOT %s  LE_EXPANSION_LEVEL_CURRENT %s"):format(
        safe(WOW_PROJECT_ID, "nil"), safe(WOW_PROJECT_CAMELOT, "nil"), safe(LE_EXPANSION_LEVEL_CURRENT, "nil")))
    say(("issecretvalue: %s  C_Spell: %s  GetSpellInfo global: %s  GetItemInfo global: %s"):format(
        Has(issecretvalue), Has(C_Spell), Has(GetSpellInfo), Has(GetItemInfo)))
    say(("CombatLogGetCurrentEventInfo: %s  loadstring_untainted: %s  C_GameRules: %s  C_DamageMeter: %s"):format( -- lint:ignore (probe only)
        Has(CombatLogGetCurrentEventInfo), Has(loadstring_untainted), Has(C_GameRules), Has(C_DamageMeter))) -- lint:ignore (probe only)
    say(("Settings.RegisterAddOnCategory: %s  AddonCompartmentFrame: %s  C_CurveUtil: %s  C_DurationUtil: %s"):format(
        Has(Settings and Settings.RegisterAddOnCategory), Has(AddonCompartmentFrame), Has(C_CurveUtil), Has(C_DurationUtil)))
    say("UnitHealth(player) secret: " .. tostring(ns.IsSecret(UnitHealth("player"))))
    say(("SavedVariables launches counter: %s (restart the client; it must grow)"):format(safe(ns.db and ns.db.launches, "?")))
    say("UnitName(player): " .. safe(UnitName("player"), "secret"))
end

-- position and facing readable? Run in the open world, in combat, in an instance.
local function ProbePosition(say)
    local x, y, _, inst = UnitPosition("player")
    local facing = GetPlayerFacing()
    local inInstance = Try(IsInInstance)
    say(("combat %s  instance %s | access x %s y %s map %s facing %s | x %s y %s map %s facing %s"):format(
        tostring(InCombatLockdown()), tostring(inInstance),
        tostring(ns.CanAccess(x)), tostring(ns.CanAccess(y)), tostring(ns.CanAccess(inst)), tostring(ns.CanAccess(facing)),
        Fmt(x), Fmt(y), Fmt(inst), Fmt(facing)))
end

-- continent id and axes from UnitPosition vs C_Map.GetWorldPosFromMapPos.
local function ProbeWorldPos(say)
    local x, y, _, inst = UnitPosition("player")
    local map = Try(C_Map.GetBestMapForUnit, "player")
    local pos = map and Try(C_Map.GetPlayerMapPosition, map, "player")
    local cont, world
    if map and pos then cont, world = Try(C_Map.GetWorldPosFromMapPos, map, pos) end
    local wx, wy
    if world then wx, wy = world:GetXY() end
    say(("UnitPosition map %s x %s y %s | GetWorldPosFromMapPos continent %s x %s y %s"):format(
        Fmt(inst), Fmt(x), Fmt(y), Fmt(cont), Fmt(wx), Fmt(wy)))
end

-- SPF settings reachable through the Settings API.
local function ProbeSpfSettings(say)
    local missing, values = {}, {}
    for _, key in ipairs(SPF_KEYS) do
        local setting = Settings and Settings.GetSetting and Try(Settings.GetSetting, "ShortestPathForever_" .. key)
        if setting then
            values[#values + 1] = key .. "=" .. Fmt(Try(setting.GetValue, setting))
        else
            missing[#missing + 1] = key
        end
    end
    say("SPF settings missing: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
    say("values: " .. table.concat(values, " "))
end

-- EllesmereUI plugin/skin API (SetContentHeader exists only after the EUI window was opened once).
local function ProbeEui(say)
    local E = EllesmereUI or {}
    say(("EUI RegisterPlugin %s  OpenPlugin %s  RegisterSkin %s  IsSearchPrebuild %s  SetContentHeader %s  RefreshPage %s"):format(
        type(E.RegisterPlugin), type(E.OpenPlugin), type(E.RegisterSkin),
        type(E.IsSearchPrebuild), type(E.SetContentHeader), type(E.RefreshPage)))
end

-- versions and the skin child addon.
local function ProbeVersions(say)
    say(("RXPGuides %s  EllesmereUI %s  ShortestPathForever %s  EllesmereUIBlizzardSkin loaded %s  SPF loaded %s"):format(
        Version("RXPGuides"), Version("EllesmereUI"), Version("ShortestPathForever"),
        Loaded("EllesmereUIBlizzardSkin"), Loaded("ShortestPathForever")))
end

-- SPF guidance state (needs SPF enabled and an active RXP guide step with a walking target).
local function ProbeSpfGuidance(say)
    local api = ShortestPathForever and ShortestPathForever.API
    local stop = api and Try(api.CurrentStop, "RestedXP")
    local superTracking = C_SuperTrack and Try(C_SuperTrack.IsSuperTrackingUserWaypoint)
    local nativeFrame = C_Navigation and Try(C_Navigation.GetFrame)
    say(("SPF API %s  CurrentStop(RestedXP) %s  supertracking waypoint %s  C_Navigation frame %s"):format(
        Has(api), Fmt(stop), tostring(superTracking), tostring(nativeFrame ~= nil)))
end

-- did the EUI skin callback run? Plus the two read-only EUI switches.
local function ProbeSkin(say)
    local r, g, b
    if ns.skin and type(ns.skin.GetAccentColor) == "function" then r, g, b = Try(ns.skin.GetAccentColor) end
    local db = EllesmereUIDB
    say(("skin callback %s  accent r %s g %s b %s  thirdPartySkinsOff %s  thirdPartySkinAddons.EUI_RestedXP_Skin %s"):format(
        ns.skinRan and "yes" or "no", Fmt(r), Fmt(g), Fmt(b),
        tostring(db and db.thirdPartySkinsOff), tostring(db and db.thirdPartySkinAddons and db.thirdPartySkinAddons[addonName])))
end

-- RXP theme registration timing, v2 state, active theme.
local function ProbeRxp(say)
    local profile = ns.RxpProfile()
    local v2 = RXP and RXP.v2 and RXP.v2.IsGuideWindowEnabled and Try(RXP.v2.IsGuideWindowEnabled, RXP.v2)
    say(("RXP.themes at file load %s  now %s  RXPGuides_Themes global %s"):format(
        tostring(ns.rxpThemesAtLoad), tostring(RXP ~= nil and RXP.themes ~= nil), type(RXPGuides_Themes)))
    say(("IsGuideWindowEnabled %s  enableV2Interface %s  enableBetaFeatures %s  activeTheme %s"):format(
        tostring(v2), tostring(profile and profile.enableV2Interface), tostring(profile and profile.enableBetaFeatures),
        tostring(profile and profile.activeTheme)))
end

-- RXP step target, SPF estimate with legs, SPF waypoint.
local function ProbeTarget(say)
    local e = RXP and RXP.arrowFrame and RXP.arrowFrame.element
    if e then
        say(("element zone %s x %s y %s radius %s"):format(Fmt(e.zone), Fmt(e.x), Fmt(e.y), Fmt(e.radius)))
    else
        say("no RXP arrow element (activate a guide step with a walking target)")
    end

    local api = ShortestPathForever and ShortestPathForever.API
    local map = Try(C_Map.GetBestMapForUnit, "player")
    local pos = map and Try(C_Map.GetPlayerMapPosition, map, "player")
    if api and e and map and pos and ns.CanAccess(e.zone) and ns.CanAccess(e.x) and ns.CanAccess(e.y) then
        local px, py = pos:GetXY()
        local ok, detail, reason = pcall(api.EstimateDetail, map, px, py, e.zone, e.x / 100, e.y / 100)
        if not ok then
            say("EstimateDetail error: " .. tostring(detail))
        elseif detail and detail.legs then
            say(("seconds %s  legs %d"):format(Fmt(detail.seconds), #detail.legs))
            for i, leg in ipairs(detail.legs) do
                say(("leg %d: mode %s  to %s  seconds %s  wait %s"):format(
                    i, Fmt(leg.mode), Fmt(leg.to), Fmt(leg.seconds), Fmt(leg.wait)))
            end
        else
            say("no estimate, reason: " .. Fmt(reason))
        end
    else
        say("skipped (needs SPF, an RXP target and a readable player map position)")
    end

    local wp = C_Map.GetUserWaypoint and Try(C_Map.GetUserWaypoint)
    if wp then
        -- Forever returns a position without GetXY: read x/y fields, fall back to the method.
        local pos = wp.position
        local wx, wy = pos and pos.x, pos and pos.y
        if wx == nil and pos and type(pos.GetXY) == "function" then wx, wy = pos:GetXY() end
        say(("position type %s  GetXY %s"):format(type(pos), type(pos and pos.GetXY)))
        say(("waypoint map %s x %s y %s"):format(Fmt(wp.uiMapID), Fmt(wx), Fmt(wy)))
    else
        say("no user waypoint set")
    end
end

function ns.Probe()
    local say, safe = ns.Say, ns.SafeString
    local steps = {
        ProbeBasics, ProbePosition, ProbeWorldPos, ProbeSpfSettings, ProbeEui,
        ProbeVersions, ProbeSpfGuidance, ProbeSkin, ProbeRxp, ProbeTarget,
    }
    for _, step in ipairs(steps) do
        local ok, err = pcall(step, say, safe)
        if not ok then say("probe error: " .. tostring(err)) end
    end
end
