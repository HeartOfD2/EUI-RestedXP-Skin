-- EUI RestedXP Skin core: namespace, SavedVariables, defaults, events, refresh, slash command, compartment.
local addonName, ns = ...
local L = ns.L

local PREFIX = "|cffd4a85a[" .. addonName .. "]|r "

-- Missing keys are filled in recursively on ADDON_LOADED.
ns.DEFAULTS = {
    launches = 0, -- SavedVariables smoke counter for /euirxp probe
    guide = {
        enabled = true, layout = "COMPACT", alpha = 0.90,
        width = 0, -- 0 = keep RXP's current window width; 240-480 = width the user chose
        followAccent = true, customColor = { r = 12 / 255, g = 210 / 255, b = 157 / 255 },
        tint = 0.12, header = true, border = "THIN",
        growth = "UP", -- the window grows upwards (bottom edge stays) or "DOWN" (top edge stays)
        background = { r = 0x16 / 255, g = 0x16 / 255, b = 0x18 / 255 }, -- false = accent-tinted window colour; {r, g, b} = the user's own, default 161618
        upcoming = 3, stepNumbers = true, progress = true,
        lockBoxes = true,
        boxEdge = "AUTO", boxAlong = 0, -- window edge of the step boxes (AUTO|BOTTOM|TOP|LEFT|RIGHT) and the distance along it
        hideCombat = false, hideInstance = true, blockV2 = true, animations = "SUBTLE",
        font = "EUI", -- "EUI" = the font of the EllesmereUI skin, "GAME" = the game's own font (Fonts page)
        sizeTitle = 16, sizeGoal = 15, sizeRow = 14, -- title (12-20), goals of the current step (11-20), upcoming rows (11-16)
        progressColor = false, -- false = accent; {r, g, b} = the user's own colour for the progress bars
    },
    nav = {
        source = "SPF", replaceSpfArrow = true, transports = true, stepEndOnly = false, hideRxpArrow = true,
        style = "CHEVRON", scale = 0.70, color = "ACCENT", customColor = nil, alpha = 1.0,
        showDistance = true, showETA = true, showName = true, unit = "m",
        hideCombat = false, locked = true, centerLock = false, point = { "TOP", "UIParent", "TOP", 0, -120 },
    },
    spfSkin = {
        journey = true, -- ShortestPathForever's Journey section in the tracker column in the EllesmereUI look
        journeyBackground = 75, -- opacity (%) of the panel behind the Journey; 0 = none
        currentAccent = true, -- the current journey step in the accent colour (off: white)
        compass = true, -- ShortestPathForever's compass in the EllesmereUI look
    },
}

local frame = CreateFrame("Frame")
local events = {}
local pending = {}

-- Secret values may not be compared, branched on or printed. Guard before use.
function ns.IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) and true or false
end

-- True when the value may be read, compared and calculated with.
function ns.CanAccess(value)
    if type(canaccessvalue) == "function" then return canaccessvalue(value) and true or false end
    return not ns.IsSecret(value)
end

function ns.SafeString(value, fallback)
    if value == nil or ns.IsSecret(value) then return fallback end
    return tostring(value)
end

-- Shared helpers (one copy for all modules).
function ns.Clamp(value, low, high, default)
    if type(value) ~= "number" then return default end
    return math.max(low, math.min(high, value))
end

function ns.Mix(base, target, amount)
    return base + (target - base) * amount
end

-- pcall that returns the first four results, or nothing on an error.
function ns.Try(fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
end

function ns.Rxp()
    local rxp = _G.RXP
    if type(rxp) == "table" then return rxp end
end

-- RXP's active profile table (and RXP itself), or nothing while RXP's settings are not ready.
function ns.RxpProfile()
    local rxp = ns.Rxp()
    local settings = rxp and rxp.settings
    local profile = type(settings) == "table" and settings.profile
    if type(profile) == "table" then return profile, rxp end
end

-- Inside a dungeon, raid, battleground, arena or scenario (not the open world); false when unreadable.
function ns.InInstance()
    local ok, inside, kind = pcall(IsInInstance)
    if not ok or not ns.CanAccess(inside) or not inside then return false end
    return not (ns.CanAccess(kind) and kind == "none")
end

function ns.Say(text)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text, 0.95, 0.92, 0.86)
end

-- Run an action now, or after combat ends if protected frames are involved.
function ns.Queue(action)
    if InCombatLockdown() then
        pending[#pending + 1] = action
    else
        action()
    end
end

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = DeepCopy(v) end
    return copy
end

local function MergeDefaults(db, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(db[key]) ~= "table" then
                db[key] = DeepCopy(value)
            else
                MergeDefaults(db[key], value)
            end
        elseif db[key] == nil then
            db[key] = value
        end
    end
end

-- "Reset to defaults": only EUIRestedXPSkinDB. The values we changed in RXP and SPF go back first (the remembered
-- originals), then our options are replaced by the defaults. RXP's own settings stay as they are.
function ns.ResetToDefaults()
    if not ns.db then return end
    if ns.RXPArrow then ns.RXPArrow.Restore() end
    if ns.SPF then ns.SPF.RestoreAll() end
    ns.db.guide = DeepCopy(ns.DEFAULTS.guide)
    ns.db.nav = DeepCopy(ns.DEFAULTS.nav)
    ns.db.spfSkin = DeepCopy(ns.DEFAULTS.spfSkin)
    ns.db.rxpArrowBackup = nil
    ns.RefreshAll()
end

-- Refresh modules (theme, guide window, arrow) register here; RefreshAll runs them
-- in registration order, at most once per frame however often it is requested.
local refreshers = {}
local refreshQueued = false

function ns.RegisterRefresh(fn)
    refreshers[#refreshers + 1] = fn
end

function ns.RefreshAll()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        for i = 1, #refreshers do
            local ok, err = pcall(refreshers[i])
            if not ok then geterrorhandler()(err) end
        end
    end)
end

-- Modules that need SavedVariables (ns.db) register here; run once on our ADDON_LOADED.
local loadedHooks = {}

function ns.OnLoaded(fn)
    loadedHooks[#loadedHooks + 1] = fn
end

-- Colour/font source: the EllesmereUI skinning facade S, handed to the
-- callback once per session. ns.Accent/ns.Font read from it with a safe fallback.
ns.FALLBACK_ACCENT = { 12 / 255, 210 / 255, 157 / 255 } -- #0CD29D (the only hard-coded accent)
ns.FALLBACK_FONT = STANDARD_TEXT_FONT
ns.skin = nil
ns.skinRan = false
if EllesmereUI and type(EllesmereUI.RegisterSkin) == "function" then
    EllesmereUI.RegisterSkin(addonName, function(S)
        ns.skin = S
        ns.skinRan = true
        if type(S.OnLooksChanged) == "function" then
            S.OnLooksChanged(function() ns.RefreshAll() end)
        end
        ns.RefreshAll()
    end)
end

local function SkinCall(name)
    local S = ns.skin
    if S and type(S[name]) == "function" then
        local ok, a, b, c = pcall(S[name])
        if ok then return a, b, c end
    end
end

local function IsChannel(v)
    return type(v) == "number" and v >= 0 and v <= 1
end

-- Accent colour r, g, b (0-1): custom colour, else EUI's accent, else the fallback.
function ns.Accent()
    local guide = ns.db and ns.db.guide
    if guide and not guide.followAccent and type(guide.customColor) == "table" then
        local c = guide.customColor
        if IsChannel(c.r) and IsChannel(c.g) and IsChannel(c.b) then return c.r, c.g, c.b end
    end
    local r, g, b = SkinCall("GetAccentColor")
    if IsChannel(r) and IsChannel(g) and IsChannel(b) then return r, g, b end
    local f = ns.FALLBACK_ACCENT
    return f[1], f[2], f[3]
end

-- Font path and outline flags from EUI; own sizes are applied with SetFont(path, size, outline).
function ns.Font()
    local path, outline = SkinCall("GetFont")
    if type(path) ~= "string" or path == "" then return ns.FALLBACK_FONT, "" end
    return path, type(outline) == "string" and outline or ""
end

-- SetFont with the game font as fallback when the path cannot be loaded.
function ns.SetFont(fs, path, size, flags)
    if not fs:SetFont(path, size, flags) then fs:SetFont(STANDARD_TEXT_FONT, size, flags) end
end

-- Seconds after PLAYER_LOGIN in which EUI's skin callback may still be pending.
local SKIN_GRACE = 3

-- is EUI's third-party skinning unavailable for us? There is no public getter.
-- Returns false, or true plus a reason: "MISSING" (EllesmereUIBlizzardSkin not loaded),
-- "MASTER" / "ADDON" (switched off in EUI's saved variables, read-only), "SILENT" (callback never ran).
function ns.SkinningOff()
    if ns.skinRan then return false end
    local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
    if isLoaded and not isLoaded("EllesmereUIBlizzardSkin") then return true, "MISSING" end
    if not ns.loginTime or GetTime() - ns.loginTime < SKIN_GRACE then return false end
    local eui = _G.EllesmereUIDB
    if type(eui) == "table" then
        if eui.thirdPartySkinsOff == true then return true, "MASTER" end
        if type(eui.thirdPartySkinAddons) == "table" and eui.thirdPartySkinAddons[addonName] == false then
            return true, "ADDON"
        end
    end
    return true, "SILENT"
end

-- Remembered at file load: had RXP already run OnInitialize (themes table present)?
ns.rxpThemesAtLoad = RXP ~= nil and RXP.themes ~= nil

function ns.OpenOptions(moduleKey, pageName)
    if not (EllesmereUI and type(EllesmereUI.OpenPlugin) == "function") then
        ns.Say(L["The EllesmereUI options are not available."])
    elseif InCombatLockdown() then
        ns.Say(L["The options cannot be opened in combat."])
    elseif EllesmereUI.OpenPlugin(addonName, moduleKey, pageName) == false then
        ns.Say(L["The options could not be opened."])
    end
end

-- SavedVariables exist only from ADDON_LOADED on; never touch them at file scope.
function events:ADDON_LOADED(loaded)
    if loaded ~= addonName then return end
    EUIRestedXPSkinDB = EUIRestedXPSkinDB or {}
    MergeDefaults(EUIRestedXPSkinDB, ns.DEFAULTS)
    ns.db = EUIRestedXPSkinDB
    self:UnregisterEvent("ADDON_LOADED")
    for i = 1, #loadedHooks do
        local ok, err = pcall(loadedHooks[i])
        if not ok then geterrorhandler()(err) end
    end
end

function events:PLAYER_LOGIN()
    ns.db.launches = ns.db.launches + 1
    ns.loggedIn = true
    ns.loginTime = GetTime()
    ns.RefreshAll()
    -- Once the grace period is over a missing EUI skin callback counts as "skinning off" (ns.SkinningOff), which
    -- switches the guide skin off; nothing else would notice that moment.
    C_Timer.After(SKIN_GRACE + 0.5, ns.RefreshAll)
end

function events:PLAYER_REGEN_ENABLED()
    local run = pending
    pending = {}
    for i = 1, #run do
        local ok, err = pcall(run[i])
        if not ok then geterrorhandler()(err) end
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    local handler = events[event]
    if handler then handler(self, ...) end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

SLASH_EUIRESTEDXPSKIN1 = "/euirxp"
SlashCmdList["EUIRESTEDXPSKIN"] = function(msg)
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$") -- arg: the rest of the line ("guide set upcoming 2")
    if cmd == "" or cmd == "options" then
        ns.OpenOptions()
    elseif cmd == "probe" then
        ns.Probe()
    elseif cmd == "nav" then
        ns.NavDebug()
    elseif cmd == "lock" or cmd == "unlock" then
        ns.SetArrowLocked(cmd == "lock")
    elseif cmd == "guide" then
        ns.GuideCommand(arg)
    elseif cmd == "spf" then
        ns.SPFSkinDebug()
    else
        ns.Say(L["Usage: /euirxp [probe|nav|lock|unlock|guide|spf]"])
    end
end

-- Addon compartment callbacks must be real globals (named in the TOC).
function EUIRestedXPSkin_OnCompartmentClick()
    ns.OpenOptions()
end

function EUIRestedXPSkin_OnCompartmentEnter(_, owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText(addonName, 1, 0.82, 0.45)
    GameTooltip:AddLine(L["Click to open the options."], 1, 1, 1)
    GameTooltip:Show()
end

function EUIRestedXPSkin_OnCompartmentLeave()
    GameTooltip:Hide()
end
