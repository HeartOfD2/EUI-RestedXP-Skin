-- RXP theme "EUIRestedXPSkin": built from the EUI accent and guide.tint,
-- registered with RestedXP Guides, rebuilt on every look change. A theme the user picked is never replaced.
local addonName, ns = ...
local L = ns.L

local THEME_NAME = "EUIRestedXPSkin"
local TEXTURE_PATH = "Interface/AddOns/RXPGuides/Textures/DarkMode/" -- RXP's own textures, none shipped here

-- EUI PANEL_BG, kept as our own constant rather than read from EUI.
ns.PANEL_BG = { 0.069, 0.058, 0.047 }

local Mix, Rxp = ns.Mix, ns.Rxp

local function Channel(v)
    return math.max(0, math.min(255, math.floor(v * 255 + 0.5)))
end

-- The user's own window colour (guide.background = { r, g, b }), or nil: then the window takes the accent tint.
function ns.CustomBackground()
    local c = ns.db and ns.db.guide and ns.db.guide.background
    if type(c) ~= "table" then return end
    local r, g, b = c.r, c.g, c.b
    if type(r) == "number" and type(g) == "number" and type(b) == "number"
        and r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1 then
        return r, g, b
    end
end

local function Tinted(r, g, b, amount)
    local bg = ns.PANEL_BG
    return { Mix(bg[1], r, amount), Mix(bg[2], g, amount), Mix(bg[3], b, amount), 1 }
end

-- Returns the RXP theme table and a signature that changes whenever any input changes.
local function Build()
    local r, g, b = ns.Accent()
    local k = ns.Clamp(ns.db.guide.tint, 0, 1, ns.DEFAULTS.guide.tint)
    local font = ns.Font()
    local cr, cg, cb = ns.CustomBackground()
    local background, bottom = Tinted(r, g, b, k * 0.5), Tinted(r, g, b, k)
    if cr then
        background = { cr, cg, cb, 1 }
        bottom = { Mix(cr, 1, 0.04), Mix(cg, 1, 0.04), Mix(cb, 1, 0.04), 1 } -- a hair lighter than the window
    end

    local theme = {
        name = THEME_NAME,
        author = addonName, -- RegisterTheme refuses themes without name or author
        displayName = "EllesmereUI (EUI RestedXP Skin)",
        version = 2, -- lets RXP.v2:ConvertThemes convert again after a rebuild
        background = background,
        bottomFrameBG = bottom,
        bottomFrameHighlight = { r, g, b, 0.5 },
        mapPins = { r, g, b, 1 },
        tooltip = string.format("|cff%02x%02x%02x", Channel(r), Channel(g), Channel(b)),
        texturePath = TEXTURE_PATH,
        headerTexture = "rxp-banner",
        textColor = { 1, 1, 1 },
        font = font,
        applicable = function() return true end,
    }
    return theme, string.format("%.4f,%.4f,%.4f,%.4f,%s,%s", r, g, b, k, font,
        cr and string.format("%.4f,%.4f,%.4f", cr, cg, cb) or "-")
end

-- Hand the theme to RXP: directly once RXP has initialised, else through its import global.
local function Register(theme)
    local rxp = Rxp()
    if rxp and type(rxp.themes) == "table" and type(rxp.RegisterTheme) == "function" then
        local ok, err = pcall(rxp.RegisterTheme, rxp, theme)
        if not ok then geterrorhandler()(err) end
        return
    end
    _G.RXPGuides_Themes = _G.RXPGuides_Themes or {}
    _G.RXPGuides_Themes[THEME_NAME] = theme
end

local renderQueued = false

-- Re-render RXP's frames with the active theme; touches RXP frames, so never in combat.
local function Render()
    if renderQueued then return end
    renderQueued = true
    ns.Queue(function()
        renderQueued = false
        local rxp = Rxp()
        if rxp and type(rxp.RenderFrame) == "function" then rxp.RenderFrame(true) end
    end)
end

function ns.ThemeActive()
    local profile = ns.RxpProfile()
    return profile ~= nil and profile.activeTheme == THEME_NAME
end

local lastSignature

-- Rebuild and register when an input changed (or when forced); re-render only if our theme is the
-- active one and RXP has already drawn with something else or with the previous colours.
local function Apply(force)
    if not ns.db then return end
    local theme, signature = Build()
    local changed = force or signature ~= lastSignature
    if changed then
        Register(theme)
        lastSignature = signature
    end
    if not ns.ThemeActive() then return end
    local current = Rxp().activeTheme
    -- activeTheme is nil until RXP's first render, which will then already find our theme.
    if current and (changed or current.name ~= THEME_NAME) then Render() end
end

-- "Theme in RestedXP: active/inactive" (the only place that changes activeTheme).
function ns.SetThemeActive(on)
    local profile = ns.RxpProfile()
    if not profile or not ns.db then
        ns.Say(L["RestedXP settings are not available."])
        return false
    end
    if on then
        Apply(true) -- the theme must exist in RXP before it can be selected
        if profile.activeTheme ~= THEME_NAME then
            ns.db.themeBackup = profile.activeTheme
            profile.activeTheme = THEME_NAME
        end
    else
        if profile.activeTheme == THEME_NAME then
            local backup = ns.db.themeBackup
            if type(backup) ~= "string" or backup == "" or backup == THEME_NAME then backup = "RXP Blue" end
            profile.activeTheme = backup
        end
        ns.db.themeBackup = nil
    end
    Render()
    return true
end

-- Registered before RXP's first render when possible (our ADDON_LOADED follows RXP's).
ns.OnLoaded(function() Apply(true) end)
ns.RegisterRefresh(function() Apply(false) end)
