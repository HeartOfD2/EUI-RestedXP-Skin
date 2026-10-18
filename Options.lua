-- EUI RestedXP Skin options: one EllesmereUI plugin section "RestedXP" with two modules.
-- Every option row is a DualRow (only DualRow can be greyed out). The Arrow page has the live preview header
-- (ArrowPreview.lua). Options only write ns.db and ask for a refresh; the modules apply them (ns.RefreshAll).
local addonName, ns = ...
local L = ns.L

local CONTENT_PAD = 45 -- EUI content padding

-- Internal page ids -> visible (localized) names. Visible names must be unique per module.
local PAGE_LABEL = {
    General = L["General"], Fonts = L["Fonts"], Colors = L["Colors"],
    Arrow = L["Arrow"], Compass = L["Compass bar"], Journey = L["Journey"], Map = L["Map"],
}
local ID_BY_LABEL = {}
for id, label in pairs(PAGE_LABEL) do ID_BY_LABEL[label] = id end

local SKIN_HINT = {
    MISSING = L["EllesmereUIBlizzardSkin is not loaded: the guide window skin is off and the colours use the fallback or custom colour."],
    MASTER = L["Skinning of other addons is switched off in EllesmereUI: the guide window skin is off (it returns after /reload once skinning is on)."],
    ADDON = L["Skinning of EUI RestedXP Skin is switched off in EllesmereUI (Third-Party Addons): the guide window skin is off (it returns after /reload once skinning is on)."],
    SILENT = L["EllesmereUI has not applied its skin to EUI RestedXP Skin: the guide window skin is off (it returns after /reload once the skin is applied)."],
}
local HINT_HEIGHT = 44

local hints = {} -- parent frame -> its skinning hint text, created once per page frame (not stored in EUI's frames)

-- ---------------------------------------------------------------------------------------------------------------
-- Row helpers

local function Db(section)
    return ns.db[section]
end

local function Blank()
    return { type = "label", text = "" }
end

-- After a change: let the modules apply it; `page` also rebuilds the page (greyed-out rows depend on it), `sync` names
-- the option whose ShortestPathForever counterpart has to follow.
local function Changed(opt)
    if opt.sync then
        ns.SPF.OnOptionChanged(opt.sync)
    elseif opt.rxpArrow then
        ns.RXPArrow.OnOptionChanged()
    else
        ns.RefreshAll()
    end
    if opt.page and EllesmereUI and type(EllesmereUI.RefreshPage) == "function" then EllesmereUI:RefreshPage() end
end

-- kind: toggle | slider | dropdown. opt: min, max, step, values, order, tooltip, disabled, disabledTooltip,
-- get/set (value transforms), page, sync, rxpArrow.
local function Row(section, key, kind, text, opt)
    opt = opt or {}
    local cfg = {
        type = kind, text = L[text], tooltip = opt.tooltip and L[opt.tooltip] or nil,
        disabled = opt.disabled, disabledTooltip = opt.disabledTooltip and L[opt.disabledTooltip] or nil,
        min = opt.min, max = opt.max, step = opt.step, values = opt.values, order = opt.order,
        getValue = function()
            local v = Db(section)[key]
            if opt.get then return opt.get(v) end
            if kind == "toggle" then return v and true or false end
            return v
        end,
        setValue = function(v)
            Db(section)[key] = opt.set and opt.set(v) or v
            Changed(opt)
        end,
    }
    return cfg
end

local function Pair(W, parent, y, left, right)
    local _, h = W:DualRow(parent, y, left, right or Blank())
    return y - (h or 0)
end

local function ColorRow(text, get, set, opt)
    opt = opt or {}
    return {
        type = "colorpicker", text = L[text], tooltip = opt.tooltip and L[opt.tooltip] or nil,
        disabled = opt.disabled, disabledTooltip = opt.disabledTooltip and L[opt.disabledTooltip] or nil,
        getValue = get,
        setValue = function(r, g, b)
            set(r, g, b)
            Changed(opt)
        end,
    }
end

local function ColorOf(c, default)
    if type(c) == "table" and type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
        return c.r, c.g, c.b
    end
    return default[1], default[2], default[3]
end

-- SPF-backed rows: the value lives in SPF; reading and writing go through the bridge.
local function SpfRow(key, kind, text, opt)
    opt = opt or {}
    return {
        type = kind, text = L[text], tooltip = opt.tooltip and L[opt.tooltip] or nil,
        min = opt.min, max = opt.max, step = opt.step,
        disabled = function() return not ns.SPF.Has(key) end,
        disabledTooltip = L["ShortestPathForever is not loaded."],
        getValue = function()
            local v = ns.SPF.Get(key)
            if kind == "toggle" then return v == true end
            return type(v) == "number" and v or opt.min
        end,
        setValue = function(v) ns.SPF.Set(key, v) end,
    }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Guide window > General

local function BuildGeneralActions(W, parent, y)
    local active = ns.ThemeActive()
    local label = active and L["Theme in RestedXP: active"] or L["Theme in RestedXP: inactive"]
    local off, reason = ns.SkinningOff()

    local _, h = W:WideButton(parent, L["Reset to defaults"], y, function()
        ns.ResetToDefaults()
        ns.Say(L["EUI RestedXP Skin options were reset to the defaults."])
        EllesmereUI:RefreshPage(true)
    end)
    y = y - (h or 0)

    local row
    row, h = W:WideButton(parent, label, y, function()
        if ns.SkinningOff() then return end -- greyed out while the guide skin is off
        ns.SetThemeActive(not ns.ThemeActive())
        EllesmereUI:RefreshPage(true)
    end)
    if off and type(row) == "table" and type(row.SetAlpha) == "function" then row:SetAlpha(0.4) end
    y = y - (h or 0)

    _, h = W:WideButton(parent, L["Reset window position"], y, function()
        if not ns.GuideSkin.ResetPosition() then ns.Say(L["The guide window is not available."]) end
    end)
    y = y - (h or 0)

    if not EllesmereUI.IsSearchPrebuild() and type(parent.CreateFontString) == "function" then
        local hint = hints[parent]
        if not hint then
            hint = parent:CreateFontString(nil, "OVERLAY")
            hint:SetFont(STANDARD_TEXT_FONT, 12, "")
            hint:SetTextColor(1, 0.82, 0.45)
            hint:SetJustifyH("LEFT")
            hint:SetJustifyV("TOP")
            hints[parent] = hint
        end
        if off then
            local path, outline = ns.Font()
            hint:SetFont(path, 12, outline)
            hint:ClearAllPoints()
            hint:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_PAD, y - 8)
            hint:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -CONTENT_PAD, y - 8)
            hint:SetHeight(HINT_HEIGHT)
            hint:SetText(SKIN_HINT[reason] or SKIN_HINT.SILENT)
            hint:Show()
            y = y - HINT_HEIGHT - 8
        else
            hint:Hide()
        end
    end
    return y
end

local function BuildGeneral(W, parent, y)
    y = BuildGeneralActions(W, parent, y)

    y = y - (select(2, W:SectionHeader(parent, L["DISPLAY"], y)) or 0)
    y = Pair(W, parent, y,
        Row("guide", "enabled", "toggle", "Restyle RestedXP", { page = true, tooltip = "Switches the whole guide window skin on or off. Off gives RestedXP's own look back." }),
        Row("guide", "layout", "dropdown", "Layout", {
            values = { COMPACT = L["Compact"], STANDARD = L["RestedXP standard"] }, order = { "COMPACT", "STANDARD" },
            tooltip = "Compact is the EllesmereUI look; RestedXP standard leaves the window as RestedXP draws it.",
        }))
    y = Pair(W, parent, y,
        Row("guide", "alpha", "slider", "Window opacity", { min = 0.3, max = 1, step = 0.05 }),
        Row("guide", "width", "slider", "Window width", {
            min = 230, max = 480, step = 10,
            get = function(v) return (type(v) == "number" and v >= 240) and v or 230 end,
            set = function(v) return v < 240 and 0 or v end,
            tooltip = "The lowest position (230) keeps the width RestedXP uses. Higher values set the width in pixels (240 to 480).",
        }))
    y = Pair(W, parent, y,
        Row("guide", "followAccent", "toggle", "Follow the EllesmereUI accent colour", {
            page = true, tooltip = "Off: the accent colour set on the Colors page is used.",
        }),
        Row("guide", "tint", "slider", "Background tint (%)", {
            min = 0, max = 30, step = 1,
            get = function(v) return math.floor((type(v) == "number" and v or 0.12) * 100 + 0.5) end,
            set = function(v) return v / 100 end,
            tooltip = "How strongly the accent colour tints the window background.",
        }))
    y = Pair(W, parent, y,
        Row("guide", "header", "toggle", "Show header"),
        Row("guide", "border", "dropdown", "Border", {
            values = { NONE = L["None"], THIN = L["Thin (1 px)"] }, order = { "NONE", "THIN" },
        }))
    y = Pair(W, parent, y, Row("guide", "growth", "dropdown", "Window grows", {
        values = { UP = L["Upwards"], DOWN = L["Downwards"] }, order = { "UP", "DOWN" },
        tooltip = "Which edge of the window stays in place when its height changes.",
    }))

    y = y - (select(2, W:SectionHeader(parent, L["STEPS"], y)) or 0)
    y = Pair(W, parent, y,
        Row("guide", "upcoming", "slider", "Upcoming steps", {
            min = 0, max = 5, step = 1,
            tooltip = "How many upcoming steps are listed. This also sets the window height; the mouse wheel scrolls through the whole guide.",
        }),
        Row("guide", "stepNumbers", "toggle", "Step numbers"))
    y = Pair(W, parent, y,
        Row("guide", "progress", "toggle", "Progress bar"),
        Row("guide", "lockBoxes", "toggle", "Pin target icons to the window", {
            tooltip = "Keeps RestedXP's item and target boxes on the edge of the window. Drag a box (Alt, if RestedXP locks its frames) to move it along the edge or to another edge. Changes apply outside of combat.",
        }))
    y = Pair(W, parent, y, Row("guide", "boxEdge", "dropdown", "Box position", {
        values = { AUTO = L["Automatic"], BOTTOM = L["Bottom"], TOP = L["Top"], LEFT = L["Left"], RIGHT = L["Right"] },
        order = { "AUTO", "BOTTOM", "TOP", "LEFT", "RIGHT" },
        tooltip = "Which edge of the window the item and target boxes sit on. Automatic uses the bottom edge unless there is no room under the window.",
    }))

    y = y - (select(2, W:SectionHeader(parent, L["BEHAVIOR"], y)) or 0)
    y = Pair(W, parent, y,
        Row("guide", "hideCombat", "toggle", "Hide in combat"),
        Row("guide", "hideInstance", "toggle", "Hide in instances"))
    y = Pair(W, parent, y,
        Row("guide", "blockV2", "toggle", "Block guide window v2 (needs /reload)", {
            tooltip = "RestedXP's beta window v2 replaces the classic window that EUI RestedXP Skin styles. On: v2 is switched off in RestedXP; type /reload afterwards.",
        }),
        Row("guide", "animations", "dropdown", "Animations", {
            values = { OFF = L["Off"], SUBTLE = L["Subtle"] }, order = { "OFF", "SUBTLE" },
        }))
    return y
end

-- ---------------------------------------------------------------------------------------------------------------
-- Guide window > Fonts and Colors

local function BuildFonts(W, parent, y)
    y = y - (select(2, W:SectionHeader(parent, L["FONT"], y)) or 0)
    y = Pair(W, parent, y, Row("guide", "font", "dropdown", "Font", {
        values = { EUI = L["Follow EllesmereUI"], GAME = L["Game font"] }, order = { "EUI", "GAME" },
        tooltip = "Follow EllesmereUI uses the font chosen in EllesmereUI. The game font is the client's default font.",
    }))
    y = y - (select(2, W:SectionHeader(parent, L["SIZES"], y)) or 0)
    y = Pair(W, parent, y,
        Row("guide", "sizeTitle", "slider", "Title", { min = 12, max = 20, step = 1 }),
        Row("guide", "sizeGoal", "slider", "Current step", { min = 11, max = 20, step = 1 }))
    y = Pair(W, parent, y, Row("guide", "sizeRow", "slider", "Upcoming steps text", { min = 11, max = 16, step = 1 }))
    return y
end

local function BuildColors(W, parent, y)
    local guide = function() return ns.db.guide end
    local ownWindow = function() return type(guide().background) == "table" end
    local ownProgress = function() return type(guide().progressColor) == "table" end

    y = y - (select(2, W:SectionHeader(parent, L["ACCENT"], y)) or 0)
    y = Pair(W, parent, y, ColorRow("Accent colour",
        function() return ColorOf(guide().customColor, ns.FALLBACK_ACCENT) end,
        function(r, g, b) guide().customColor = { r = r, g = g, b = b } end,
        {
            disabled = function() return guide().followAccent ~= false end,
            disabledTooltip = "Switch off \"Follow the EllesmereUI accent colour\" on the General page to use your own.",
        }))
    y = Pair(W, parent, y,
        {
            type = "toggle", text = L["Own window colour"],
            tooltip = L["Off: the window colour comes from the accent tint. Examples: 161618 or 0F172A."],
            getValue = function() return ownWindow() end,
            setValue = function(on)
                guide().background = on and { r = 0x16 / 255, g = 0x16 / 255, b = 0x18 / 255 } or false
                Changed({ page = true })
            end,
        },
        ColorRow("Window colour",
            function() return ColorOf(guide().background, { 0x16 / 255, 0x16 / 255, 0x18 / 255 }) end,
            function(r, g, b) guide().background = { r = r, g = g, b = b } end,
            { disabled = function() return not ownWindow() end, disabledTooltip = "Switch on \"Own window colour\" first." }))

    y = y - (select(2, W:SectionHeader(parent, L["PROGRESS"], y)) or 0)
    y = Pair(W, parent, y,
        {
            type = "toggle", text = L["Own progress colour"],
            tooltip = L["Off: progress bars use the accent colour."],
            getValue = function() return ownProgress() end,
            setValue = function(on)
                local r, g, b = ns.Accent()
                guide().progressColor = on and { r = r, g = g, b = b } or false
                Changed({ page = true })
            end,
        },
        ColorRow("Progress colour",
            function() return ColorOf(guide().progressColor, ns.FALLBACK_ACCENT) end,
            function(r, g, b) guide().progressColor = { r = r, g = g, b = b } end,
            { disabled = function() return not ownProgress() end, disabledTooltip = "Switch on \"Own progress colour\" first." }))
    return y
end

-- ---------------------------------------------------------------------------------------------------------------
-- Navigation > Arrow, Compass bar, Map

local function BuildArrow(W, parent, y)
    local nav = function() return ns.db.nav end
    local noSpf = function() return not ns.SPF.Loaded() end
    local NO_SPF = "ShortestPathForever is not loaded."

    y = y - (select(2, W:SectionHeader(parent, L["SOURCE"], y)) or 0)
    y = Pair(W, parent, y,
        Row("nav", "source", "dropdown", "Navigation source", {
            values = { AUTO = L["Automatic"], SPF = "ShortestPathForever", RXP = "RestedXP" }, order = { "AUTO", "SPF", "RXP" },
            page = true, sync = "source",
            tooltip = "Where the arrow gets its route from. Without ShortestPathForever the arrow points in a straight line to the step target.",
        }),
        Row("nav", "replaceSpfArrow", "toggle", "Hide the ShortestPathForever arrow", {
            sync = "replaceSpfArrow",
            disabled = function() return noSpf() or nav().source ~= "RXP" end,
            disabledTooltip = "Only available with ShortestPathForever loaded and the source set to RestedXP. With ShortestPathForever guiding, its own arrow is not shown anyway.",
        }))
    y = Pair(W, parent, y,
        Row("nav", "transports", "toggle", "Plan transport", {
            sync = "transports", disabled = noSpf, disabledTooltip = NO_SPF,
            tooltip = "ShortestPathForever may use the hearthstone and teleports when planning the route.",
        }),
        Row("nav", "stepEndOnly", "toggle", "Aim at the step end only", {
            sync = "stepEndOnly", disabled = noSpf, disabledTooltip = NO_SPF,
            tooltip = "ShortestPathForever marks only the end of each walking stretch instead of every bend.",
        }))
    y = Pair(W, parent, y, Row("nav", "hideRxpArrow", "toggle", "Hide RestedXP's own arrow", {
        rxpArrow = true,
        tooltip = "Switches on RestedXP's \"Hide waypoint arrow\" setting for you, so only one arrow is shown. Off puts your previous RestedXP setting back.",
    }))

    y = y - (select(2, W:SectionHeader(parent, L["ARROW"], y)) or 0)
    y = Pair(W, parent, y,
        Row("nav", "style", "dropdown", "Arrow style", {
            values = { CHEVRON = L["Chevron"], RING = L["Ring"], PILL = L["Pill"], CLASSIC = L["Classic"] },
            order = { "CHEVRON", "RING", "PILL", "CLASSIC" },
        }),
        Row("nav", "scale", "slider", "Size (%)", {
            min = 50, max = 200, step = 5,
            get = function(v) return math.floor((type(v) == "number" and v or 0.70) * 100 + 0.5) end,
            set = function(v) return v / 100 end,
        }))
    y = Pair(W, parent, y,
        Row("nav", "color", "dropdown", "Colour", {
            values = { ACCENT = L["Follow accent colour"], DIRECTION = L["By direction"], CUSTOM = L["Custom"] },
            order = { "ACCENT", "DIRECTION", "CUSTOM" }, page = true,
        }),
        Row("nav", "alpha", "slider", "Opacity", { min = 0.2, max = 1, step = 0.05 }))
    y = Pair(W, parent, y,
        ColorRow("Custom arrow colour",
            function() return ColorOf(nav().customColor, ns.FALLBACK_ACCENT) end,
            function(r, g, b) nav().customColor = { r = r, g = g, b = b } end,
            { disabled = function() return nav().color ~= "CUSTOM" end, disabledTooltip = "Set the colour to \"Custom\" first." }),
        Row("nav", "showDistance", "toggle", "Show distance"))
    y = Pair(W, parent, y,
        Row("nav", "showETA", "toggle", "Show arrival time"),
        Row("nav", "showName", "toggle", "Show target name"))
    y = Pair(W, parent, y,
        Row("nav", "unit", "dropdown", "Unit", {
            values = { m = L["Metres"], yd = L["Yards"] }, order = { "m", "yd" }, sync = "unit",
        }),
        Row("nav", "hideCombat", "toggle", "Hide in combat"))
    y = Pair(W, parent, y,
        Row("nav", "locked", "toggle", "Lock position", {
            tooltip = "Off: drag the arrow with the left mouse button; right-click centres it horizontally.",
        }),
        Row("nav", "centerLock", "toggle", "Keep arrow centred", { tooltip = "Keeps the arrow on the vertical centre line of the screen. When unlocked, dragging only moves it up and down." }))
    local _, h = W:WideButton(parent, L["Reset arrow position"], y, function() ns.ResetArrowPosition() end)
    return y - (h or 0)
end

local function BuildCompass(W, parent, y)
    y = y - (select(2, W:SectionHeader(parent, L["COMPASS BAR"], y)) or 0)
    y = Pair(W, parent, y,
        SpfRow("compass", "toggle", "Show compass bar"),
        SpfRow("compassScale", "slider", "Compass size (%)", { min = 50, max = 200, step = 10 }))
    y = Pair(W, parent, y,
        SpfRow("compassBackground", "slider", "Compass background (%)", { min = 0, max = 80, step = 10 }),
        SpfRow("compassTime", "toggle", "Show the time left under the compass"))
    y = y - (select(2, W:SectionHeader(parent, L["LOOK"], y)) or 0)
    y = Pair(W, parent, y, Row("spfSkin", "compass", "toggle", "Restyle the compass", {
        disabled = function() return not ns.SPF.Loaded() end, disabledTooltip = "ShortestPathForever is not loaded.",
        tooltip = "Ticks, letters and the centre mark in the EllesmereUI look: accent colour for north, the centre and the walking marks, the EllesmereUI font, the window colour behind the band. Off gives ShortestPathForever's own look back.",
    }))
    return y
end

local function BuildJourney(W, parent, y)
    local skin = function() return ns.db.spfSkin end
    local noSkin = function() return not ns.SPF.Loaded() or not skin().journey end
    y = y - (select(2, W:SectionHeader(parent, L["JOURNEY"], y)) or 0)
    y = Pair(W, parent, y,
        SpfRow("journeyTracker", "toggle", "Show journey in tracker", {
            tooltip = "ShortestPathForever's Journey section in the objective tracker column: where you are going, the time left and each step.",
        }),
        Row("spfSkin", "journey", "toggle", "Restyle the journey", {
            page = true, disabled = function() return not ns.SPF.Loaded() end, disabledTooltip = "ShortestPathForever is not loaded.",
            tooltip = "The Journey section in the look of the EllesmereUI quest tracker: header in the accent colour with a thin line, its fonts and text colours, a dark panel behind it. Off gives ShortestPathForever's own look back.",
        }))
    y = Pair(W, parent, y,
        Row("spfSkin", "journeyBackground", "slider", "Journey background (%)", {
            min = 0, max = 100, step = 5, disabled = noSkin, disabledTooltip = "Switch on \"Restyle the journey\" first.",
            tooltip = "Opacity of the panel behind the Journey. Its colour is the one of the EllesmereUI quest tracker, otherwise the window colour. 0 shows no panel.",
        }),
        Row("spfSkin", "currentAccent", "toggle", "Current step in the accent colour", {
            disabled = noSkin, disabledTooltip = "Switch on \"Restyle the journey\" first.",
            tooltip = "Off: the current step is white.",
        }))
    return y
end

local function BuildMap(W, parent, y)
    y = y - (select(2, W:SectionHeader(parent, L["MAP"], y)) or 0)
    y = Pair(W, parent, y,
        SpfRow("mapRoutes", "toggle", "Show routes on the map"),
        SpfRow("pins", "toggle", "Show map pins"))
    y = Pair(W, parent, y,
        SpfRow("minimapPins", "toggle", "Show minimap pins"),
        SpfRow("mapPinScale", "slider", "Pin size (%)", { min = 25, max = 200, step = 5 }))
    y = Pair(W, parent, y,
        SpfRow("transit", "toggle", "Show lifts and tram"),
        SpfRow("portals", "toggle", "Show portals"))
    y = Pair(W, parent, y,
        SpfRow("mapFlightMasters", "toggle", "Show flight masters"),
        SpfRow("flightPinScale", "slider", "Flight master size (%)", { min = 25, max = 200, step = 5 }))
    y = Pair(W, parent, y, SpfRow("minimapPinScale", "slider", "Minimap pin size (%)", { min = 25, max = 200, step = 5 }))
    return y
end

local BUILDERS = {
    General = BuildGeneral, Fonts = BuildFonts, Colors = BuildColors,
    Arrow = BuildArrow, Compass = BuildCompass, Journey = BuildJourney, Map = BuildMap,
}

local function BuildPage(pageName, parent, yOffset)
    local id = ID_BY_LABEL[pageName]
    local build = id and BUILDERS[id]
    if not build or not ns.db then return math.abs(yOffset) end

    -- EUI's search pre-build runs this with stub widgets: no side effects then.
    if id == "Arrow" and not EllesmereUI.IsSearchPrebuild() and type(EllesmereUI.SetContentHeader) == "function" then
        EllesmereUI:SetContentHeader(ns.BuildArrowHeader)
    end

    local W = EllesmereUI.Widgets -- fetched inside buildPage: the search pre-build swaps it
    return math.abs(build(W, parent, yOffset))
end

local function PageNames(ids)
    local names = {}
    for i, id in ipairs(ids) do names[i] = PAGE_LABEL[id] end
    return names
end

if EllesmereUI and type(EllesmereUI.RegisterPlugin) == "function" then
    EllesmereUI.RegisterPlugin(addonName, {
        label = "RestedXP",
        modules = {
            {
                key = "Guide", title = L["Guide window"],
                description = L["RestedXP Guides in the EllesmereUI look: window, steps and colors."],
                pages = PageNames({ "General", "Fonts", "Colors" }),
                buildPage = BuildPage,
            },
            {
                key = "Nav", title = L["Navigation"],
                description = L["Arrow and route. Route planning comes from ShortestPathForever, the EUI-style arrow from EUI RestedXP Skin."],
                pages = PageNames({ "Arrow", "Compass", "Journey", "Map" }),
                buildPage = BuildPage,
                getHeaderBuilder = function(pageName)
                    if ID_BY_LABEL[pageName] == "Arrow" then return ns.BuildArrowHeader end
                end,
            },
        },
    })
end
