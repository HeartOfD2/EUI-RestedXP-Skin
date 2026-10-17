-- EUI RestedXP Skin arrow.
-- Our own frame, never RXP.arrowFrame. Four states (travelling, transport, arrived, wrong continent), four styles
-- (Chevron, Ring, Pill, Classic) and three colour modes (accent, direction, custom). Data comes from SPFBridge.lua
-- (ns.Target, ns.PlayerPos, ns.PlayerFacing, ns.DistanceTo, ns.ToUnit, ns.FormatTime, ns.ETA, ns.Transport).
local addonName, ns = ...
local L = ns.L

local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
local WIDTH = 220 -- frame width, long target names are cut off
local TICK = 0.05 -- visible: 20 Hz
local IDLE = 0.5 -- hidden: seconds between looks for a new target
local DEFAULT_POINT = { "TOP", "UIParent", "TOP", 0, -120 }
local GAP = 2

-- Per style: height of the glyph area, size of the arrowhead inside it, size of the state symbol.
local STYLE = {
    CHEVRON = { hub = 64, glyph = 64, symbol = 56 },
    RING = { hub = 72, glyph = 44, symbol = 40 },
    PILL = { hub = 40, glyph = 28, symbol = 28 },
    CLASSIC = { hub = 64, glyph = 64, symbol = 56 },
}
local PILL_W = 210
local PILL_ROWS = { dist = { 18, 20 }, eta = { 15, 18 } } -- inside the pill: font size, row height
local ROWS = { dist = { 24, 28 }, eta = { 15, 18 }, name = { 14, 16 } } -- below the glyph

-- Direction colours (green and yellow as in the design; red for "behind" is our choice).
local GREEN = { 0x3F / 255, 0xBF / 255, 0x5F / 255 }
local YELLOW = { 0xF0 / 255, 0xC8 / 255, 0x60 / 255 }
local RED = { 0xE5 / 255, 0x53 / 255, 0x4B / 255 }
local GREEN_LIMIT, YELLOW_LIMIT = math.rad(30), math.rad(110)

-- Labels of the transport state (keys of the locale catalog).
local TRANSPORT_LABEL = {
    flight = "Flight path", boat = "Boat", zeppelin = "Zeppelin", lift = "Lift", tram = "Tram",
    portal = "Portal", teleport = "Teleport", passage = "Passage",
}

local function atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    if x > 0 then return math.atan(y / x) end
    if x < 0 then return math.atan(y / x) + (y >= 0 and math.pi or -math.pi) end
    return y > 0 and math.pi / 2 or (y < 0 and -math.pi / 2 or 0)
end

local Clamp = ns.Clamp

-- ---------------------------------------------------------------------------------------------------------------
-- Frame. Every texture is white and tinted in code. All parts exist once; Layout shows the ones the style needs.

local arrow = CreateFrame("Frame", nil, UIParent)
arrow:SetSize(WIDTH, 64)
arrow:SetFrameStrata("MEDIUM")
arrow:SetClampedToScreen(true)
arrow:SetMovable(true)
arrow:Hide()

local hub = CreateFrame("Frame", nil, arrow) -- the glyph area; its position and size depend on the style
hub:SetSize(64, 64)
hub:SetPoint("TOP", arrow, "TOP", 0, 0)

local function MakeTex(layer, file, sublevel)
    local tex = arrow:CreateTexture(nil, layer, nil, sublevel or 0)
    if file then tex:SetTexture(MEDIA .. file .. ".tga") end
    tex:SetPoint("CENTER", hub, "CENTER", 0, 0)
    tex:Hide()
    return tex
end

-- Ring: face, edge line, north stroke (fixed on top).
local ringFace = MakeTex("BACKGROUND", "ring")
ringFace:SetVertexColor(10 / 255, 12 / 255, 12 / 255, 0.55)
local ringEdge = MakeTex("BORDER", "ring_edge")
ringEdge:SetVertexColor(1, 1, 1, 0.25)
local ringNorth = MakeTex("BORDER")
ringNorth:SetColorTexture(1, 1, 1, 0.6)
ringNorth:SetSize(2, 8)
ringNorth:ClearAllPoints()
ringNorth:SetPoint("TOP", hub, "TOP", 0, -3)

-- Pill: bar, 1 px edge, left field.
local pillBg = arrow:CreateTexture(nil, "BACKGROUND")
pillBg:SetColorTexture(0x12 / 255, 0x0F / 255, 0x0C / 255, 0.88)
pillBg:Hide()
local pillEdges = {}
for i = 1, 4 do
    local edge = arrow:CreateTexture(nil, "BORDER")
    edge:SetColorTexture(1, 1, 1, 0.10)
    edge:Hide()
    pillEdges[i] = edge
end
local pillField = arrow:CreateTexture(nil, "BORDER", nil, 1)
pillField:Hide()

-- Arrowheads: chevron set (Chevron, Ring needle, Pill) and block set (Classic).
local cOutline = MakeTex("BACKGROUND", "chevron_outline", 1) -- border black 70 %
cOutline:SetVertexColor(0, 0, 0, 0.7)
local cFill = MakeTex("ARTWORK", "chevron")
local cRelief = MakeTex("OVERLAY", "chevron_relief") -- left half black 22 %
cRelief:SetVertexColor(0, 0, 0, 0.22)
local bOutline = MakeTex("BACKGROUND", "block_outline", 1)
bOutline:SetVertexColor(0, 0, 0, 0.7)
local bFill = MakeTex("ARTWORK", "block")

-- State symbol (arrived tick, transport arrows) with a dark copy behind it.
local symbolBack = MakeTex("BACKGROUND", nil, 2)
symbolBack:SetVertexColor(0, 0, 0, 0.6)
local symbol = MakeTex("ARTWORK", nil, 1)

local chevronParts = { cOutline, cFill, cRelief }
local blockParts = { bOutline, bFill }
local symbolParts = { symbolBack, symbol }

local function SetParts(list, shown)
    for i = 1, #list do list[i]:SetShown(shown) end
end

local function MakeRow()
    local fs = arrow:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE") -- a font must be set before any text
    fs:SetWidth(WIDTH)
    fs:SetJustifyH("CENTER")
    fs:SetWordWrap(false)
    fs:Hide()
    return fs
end

local distText, etaText, nameText = MakeRow(), MakeRow(), MakeRow()
nameText:SetTextColor(1, 1, 1, 0.75)
distText:SetTextColor(1, 1, 1, 1)

-- Only touch the widget when the text really changed (the update runs 20 times a second).
local function SetRow(fs, text)
    text = text or ""
    if fs.lastText ~= text then
        fs.lastText = text
        fs:SetText(text)
    end
end

local SetFontFor = ns.SetFont

-- ---------------------------------------------------------------------------------------------------------------
-- Position and layout (re-run on every RefreshAll: options, accent colour, font)

local dragging = false

-- nav.centerLock: the arrow stays on the vertical centre line of the screen; only its height can change.
local function CentreOnScreen()
    local nav = ns.db.nav
    local p = nav.point
    local y = type(p) == "table" and p[1] == "TOP" and p[3] == "TOP" and type(p[5]) == "number" and p[5] or nil
    if not y then
        local top, uiTop = arrow:GetTop(), UIParent:GetTop()
        if not (ns.CanAccess(top) and ns.CanAccess(uiTop) and type(top) == "number" and type(uiTop) == "number") then
            y = DEFAULT_POINT[5]
        else
            local uiScale = UIParent:GetEffectiveScale()
            y = (top * arrow:GetEffectiveScale() - uiTop * uiScale) / uiScale
        end
    end
    nav.point = { "TOP", "UIParent", "TOP", 0, math.floor(y * 10 + 0.5) / 10 }
end

-- Offsets are stored in UIParent units, so changing the scale does not move the arrow.
local function ApplyPoint()
    local scale = arrow:GetScale()
    if ns.db.nav.centerLock then CentreOnScreen() end
    local p = ns.db.nav.point
    arrow:ClearAllPoints()
    local ok = false
    if type(p) == "table" and type(p[1]) == "string" and type(p[3]) == "string"
        and type(p[4]) == "number" and type(p[5]) == "number" then
        ok = pcall(arrow.SetPoint, arrow, p[1], UIParent, p[3], p[4] / scale, p[5] / scale)
    end
    if not ok then
        arrow:ClearAllPoints()
        arrow:SetPoint(DEFAULT_POINT[1], UIParent, DEFAULT_POINT[3], DEFAULT_POINT[4] / scale, DEFAULT_POINT[5] / scale)
    end
end

local function SavePoint()
    local point, _, relPoint, x, y = arrow:GetPoint(1)
    if not (point and ns.CanAccess(x) and ns.CanAccess(y) and type(x) == "number" and type(y) == "number") then return end
    local scale = arrow:GetScale()
    ns.db.nav.point = { point, "UIParent", relPoint, math.floor(x * scale * 10 + 0.5) / 10, math.floor(y * scale * 10 + 0.5) / 10 }
    if ns.db.nav.centerLock then CentreOnScreen() end
end

-- Right click on the unlocked arrow: centre it horizontally, keep the height.
local function CenterHorizontally()
    if not ns.db or ns.db.nav.locked ~= false or InCombatLockdown() then return end
    if ns.db.nav.centerLock then return end -- already centred
    local top, uiTop = arrow:GetTop(), UIParent:GetTop()
    if not (ns.CanAccess(top) and ns.CanAccess(uiTop) and type(top) == "number" and type(uiTop) == "number") then return end
    local uiScale = UIParent:GetEffectiveScale()
    local y = (top * arrow:GetEffectiveScale() - uiTop * uiScale) / uiScale
    ns.db.nav.point = { "TOP", "UIParent", "TOP", 0, math.floor(y * 10 + 0.5) / 10 }
    ApplyPoint()
end

local accentR, accentG, accentB = 1, 1, 1
local style = "CHEVRON"
local lastColor -- "r:g:b" of the last tint, so SetVertexColor only runs on a change

local function LayoutGlyph(spec, pill, offset)
    hub:ClearAllPoints()
    hub:SetSize(spec.hub, spec.hub)
    if pill then
        hub:SetPoint("TOPLEFT", arrow, "TOPLEFT", offset, 0)
    else
        hub:SetPoint("TOP", arrow, "TOP", 0, 0)
    end
    for _, part in ipairs(chevronParts) do part:SetSize(spec.glyph, spec.glyph) end
    for _, part in ipairs(blockParts) do part:SetSize(spec.glyph, spec.glyph) end
    for _, part in ipairs(symbolParts) do part:SetSize(spec.symbol, spec.symbol) end
    symbolBack:SetSize(spec.symbol * 1.12, spec.symbol * 1.12)

    local ring = style == "RING"
    ringFace:SetShown(ring); ringEdge:SetShown(ring); ringNorth:SetShown(ring)
    if ring then
        ringFace:SetSize(spec.hub, spec.hub)
        ringEdge:SetSize(spec.hub, spec.hub)
    end

    pillBg:SetShown(pill); pillField:SetShown(pill)
    for _, edge in ipairs(pillEdges) do edge:SetShown(pill) end
    if pill then
        pillBg:ClearAllPoints(); pillBg:SetPoint("TOPLEFT", arrow, "TOPLEFT", offset, 0); pillBg:SetSize(PILL_W, spec.hub)
        pillField:ClearAllPoints(); pillField:SetPoint("TOPLEFT", pillBg, "TOPLEFT", 0, 0); pillField:SetSize(spec.hub, spec.hub)
        local e = pillEdges
        e[1]:ClearAllPoints(); e[1]:SetPoint("TOPLEFT", pillBg); e[1]:SetPoint("TOPRIGHT", pillBg); e[1]:SetHeight(1)
        e[2]:ClearAllPoints(); e[2]:SetPoint("BOTTOMLEFT", pillBg); e[2]:SetPoint("BOTTOMRIGHT", pillBg); e[2]:SetHeight(1)
        e[3]:ClearAllPoints(); e[3]:SetPoint("TOPLEFT", pillBg); e[3]:SetPoint("BOTTOMLEFT", pillBg); e[3]:SetWidth(1)
        e[4]:ClearAllPoints(); e[4]:SetPoint("TOPRIGHT", pillBg); e[4]:SetPoint("BOTTOMRIGHT", pillBg); e[4]:SetWidth(1)
    end
end

local function Layout()
    local nav = ns.db.nav
    style = STYLE[nav.style] and nav.style or "CHEVRON"
    local spec = STYLE[style]
    local pill = style == "PILL"
    local offset = (WIDTH - PILL_W) / 2
    arrow:SetScale(Clamp(nav.scale, 0.5, 2, 0.70))
    arrow:SetAlpha(Clamp(nav.alpha, 0.2, 1, 1))
    if not dragging then ApplyPoint() end
    arrow:EnableMouse(nav.locked == false) -- a locked arrow never catches clicks meant for the world

    accentR, accentG, accentB = ns.Accent()
    etaText:SetTextColor(accentR, accentG, accentB, 1)
    lastColor = nil
    LayoutGlyph(spec, pill, offset)

    -- text rows: stacked below the glyph, or inside the pill next to its field (name stays below)
    local path, flags = ns.Font()
    if flags == "" then flags = "OUTLINE" end -- readable over the game world
    local rows = {
        { distText, pill and PILL_ROWS.dist or ROWS.dist, nav.showDistance },
        { etaText, pill and PILL_ROWS.eta or ROWS.eta, nav.showETA },
    }
    local y = -spec.hub - GAP
    if pill then
        local total = 0
        for _, row in ipairs(rows) do
            if row[3] ~= false then total = total + row[2][2] end
        end
        y = -math.max(0, (spec.hub - total) / 2)
    end
    for _, row in ipairs(rows) do
        local fs, size, wanted = row[1], row[2], row[3]
        fs:ClearAllPoints()
        SetFontFor(fs, path, size[1], flags)
        if wanted ~= false then
            if pill then
                fs:SetWidth(PILL_W - spec.hub - 14)
                fs:SetJustifyH("LEFT")
                fs:SetPoint("TOPLEFT", arrow, "TOPLEFT", offset + spec.hub + 8, y)
            else
                fs:SetWidth(WIDTH)
                fs:SetJustifyH("CENTER")
                fs:SetPoint("TOP", arrow, "TOP", 0, y)
            end
            fs:SetHeight(size[2])
            fs:Show()
            y = y - size[2]
        else
            fs:Hide()
        end
    end
    if pill then y = -spec.hub - GAP end
    nameText:ClearAllPoints()
    SetFontFor(nameText, path, ROWS.name[1], flags)
    if nav.showName ~= false then
        nameText:SetWidth(WIDTH)
        nameText:SetJustifyH("CENTER")
        nameText:SetPoint("TOP", arrow, "TOP", 0, y)
        nameText:SetHeight(ROWS.name[2])
        nameText:Show()
        y = y - ROWS.name[2]
    else
        nameText:Hide()
    end
    arrow:SetHeight(-y)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Colour: accent, by direction, or custom. Classic always colours by direction unless a custom colour is set.

local function ColorFor(styleName, angle, ar, ag, ab)
    local nav = ns.db.nav
    local mode = nav.color
    if styleName == "CLASSIC" and mode ~= "CUSTOM" then mode = "DIRECTION" end
    if mode == "CUSTOM" then
        local c = nav.customColor
        if type(c) == "table" and type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
            return c.r, c.g, c.b
        end
    elseif mode == "DIRECTION" and angle then
        local off = math.abs((angle + math.pi) % (2 * math.pi) - math.pi) -- 0 = straight ahead, pi = behind
        local c = off <= GREEN_LIMIT and GREEN or (off <= YELLOW_LIMIT and YELLOW or RED)
        return c[1], c[2], c[3]
    end
    return ar, ag, ab
end

local function ArrowColor(angle)
    return ColorFor(style, angle, accentR, accentG, accentB)
end

-- What the options page needs to draw a preview of the arrow (ArrowPreview.lua): the same measures and colours.
ns.ArrowDesign = {
    STYLE = STYLE, WIDTH = WIDTH, PILL_W = PILL_W, ROWS = ROWS, PILL_ROWS = PILL_ROWS, MEDIA = MEDIA,
    Color = function(styleName, angle)
        local r, g, b = ns.Accent()
        return ColorFor(styleName, angle, r, g, b)
    end,
}

local function ApplyColor(angle)
    local r, g, b = ArrowColor(angle)
    local key = ("%.3f:%.3f:%.3f"):format(r, g, b)
    if key == lastColor then return end
    lastColor = key
    cFill:SetVertexColor(r, g, b, 1)
    bFill:SetVertexColor(r, g, b, 1)
    symbol:SetVertexColor(r, g, b, 1)
    pillField:SetColorTexture(r, g, b, 0.15)
end

-- ---------------------------------------------------------------------------------------------------------------
-- State and update

local current = { kind = "NONE" } -- last computed state, for /euirxp nav
local latch = { key = nil, arrived = false } -- "arrived" holds until the step target changes (RXP ticks the step off)

-- kind: "ARROW" (arrowhead rotated by angle), "CHECK", "TRANSPORT" or "NONE".
local function Draw(kind, angle)
    if kind == "ARROW" then
        local classic = style == "CLASSIC"
        SetParts(symbolParts, false)
        SetParts(chevronParts, not classic)
        SetParts(blockParts, classic)
        for _, part in ipairs(classic and blockParts or chevronParts) do part:SetRotation(angle) end
    elseif kind == "CHECK" or kind == "TRANSPORT" then
        SetParts(chevronParts, false)
        SetParts(blockParts, false)
        local name = kind == "CHECK" and "check" or "transport"
        if symbol.file ~= name then
            symbol.file = name
            symbol:SetTexture(MEDIA .. name .. ".tga")
            symbolBack:SetTexture(MEDIA .. name .. ".tga")
        end
        SetParts(symbolParts, true)
    else
        SetParts(chevronParts, false)
        SetParts(blockParts, false)
        SetParts(symbolParts, false)
    end
    ApplyColor(kind == "ARROW" and angle or nil)
end

local function UnitLabel(nav)
    return nav.unit == "yd" and "yd" or "m"
end

-- Reads the world, draws the matching state and returns true when the arrow should be visible.
local function Update()
    local nav = ns.db and ns.db.nav
    current.angle, current.mode = nil, nil
    if not nav then current.kind = "NONE"; return false end
    if nav.hideCombat and InCombatLockdown() then current.kind = "COMBAT"; return false end
    if ns.InInstance() then current.kind = "INSTANCE"; return false end

    local t = ns.Target()
    local px, py, inst = ns.PlayerPos()
    if not (t and px) then
        if nav.locked == false then -- placeholder, so an unlocked arrow can always be found and dragged
            current.kind = "PLACEHOLDER"
            Draw("ARROW", 0)
            SetRow(distText, ""); SetRow(etaText, ""); SetRow(nameText, L["Drag to move the arrow"])
            return true
        end
        current.kind = t and "UNREADABLE" or "NONE"
        return false
    end

    -- Distance and arrival time refer to the RXP step target, the direction to SPF's next bend.
    local goal = t.goal or t
    local yards, why = ns.DistanceTo(goal.cont, goal.x, goal.y)
    local key = t.goal and t.goal.key or nil
    if key ~= latch.key then latch.key, latch.arrived = key, false end
    local radius = t.goal and t.goal.radius
    if yards and radius and radius > 0 and yards <= radius then latch.arrived = true end
    if yards then
        SetRow(distText, ("%d %s"):format(math.floor(ns.ToUnit(yards, nav.unit) + 0.5), UnitLabel(nav)))
    else
        SetRow(distText, why == "continent" and "~" or "")
    end
    local eta = ns.ETA()
    SetRow(etaText, eta.seconds and ns.FormatTime(eta.seconds) or "")
    SetRow(nameText, t.goal and t.goal.name or "")

    if inst ~= t.cont then -- wrong continent: arrow off, "~" like RXP
        current.kind = "WRONG_CONTINENT"
        Draw("NONE")
        return nav.showDistance ~= false or nav.showName ~= false
    end

    if latch.arrived then -- arrived: tick and "Arrived" until RXP completes the step
        current.kind = "ARRIVED"
        Draw("CHECK")
        SetRow(distText, L["Arrived"]); SetRow(etaText, "")
        return true
    end

    local transport = ns.Transport()
    if transport then -- walking to a boat, zeppelin, portal ...: symbol, mode, departure and destination
        current.kind, current.mode = "TRANSPORT", transport.mode
        Draw("TRANSPORT")
        SetRow(distText, L[TRANSPORT_LABEL[transport.mode] or "Transport"])
        SetRow(etaText, transport.wait and L["Departure %s"]:format(ns.FormatTime(transport.wait)) or "")
        SetRow(nameText, transport.to or (t.goal and t.goal.name) or "")
        return true
    end

    local facing = ns.PlayerFacing()
    if not facing then current.kind = "UNREADABLE"; return false end
    local angle = atan2(t.y - py, t.x - px) - facing
    current.kind, current.angle = "TRAVEL", angle
    Draw("ARROW", angle)
    return true
end

local reported = false

local function SafeUpdate()
    local ok, show = pcall(Update)
    if ok then return show end
    if not reported then -- one report, not 20 per second
        reported = true
        geterrorhandler()(show)
    end
    current.kind = "ERROR"
    return false
end

local acc = 0
arrow:SetScript("OnUpdate", function(self, elapsed) -- lint:ignore (the arrow turns every 0.05 s, only while visible)
    acc = acc + elapsed
    if acc < TICK then return end
    acc = 0
    if not SafeUpdate() then self:Hide() end
end)

-- Hidden: look for a target twice a second; the OnUpdate above takes over once the arrow is shown.
local function IdleTick()
    if arrow:IsShown() or not ns.loggedIn then return end
    if SafeUpdate() then arrow:Show() end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Dragging: only when unlocked and out of combat. Right click centres the arrow horizontally.

arrow:RegisterForDrag("LeftButton")
-- With nav.centerLock the arrow is not moved by StartMoving but follows the mouse height only.
local slide = CreateFrame("Frame")
slide:Hide()
slide:SetScript("OnUpdate", function(self)
    local _, cy = GetCursorPosition()
    local uiScale = UIParent:GetEffectiveScale()
    if not (ns.CanAccess(cy) and type(cy) == "number" and uiScale > 0) then return end
    local limit = UIParent:GetHeight() or 0
    local y = math.max(-limit, math.min(0, self.y0 + (cy - self.cy0) / uiScale))
    ns.db.nav.point = { "TOP", "UIParent", "TOP", 0, math.floor(y * 10 + 0.5) / 10 }
    ApplyPoint()
end)

arrow:SetScript("OnDragStart", function(self)
    if not ns.db or ns.db.nav.locked ~= false or InCombatLockdown() then return end
    dragging = true
    if ns.db.nav.centerLock then
        ApplyPoint()
        local _, cy = GetCursorPosition()
        slide.cy0, slide.y0 = cy, ns.db.nav.point[5]
        if ns.CanAccess(cy) and type(cy) == "number" then slide:Show() end
        return
    end
    self:StartMoving()
end)
arrow:SetScript("OnDragStop", function(self)
    slide:Hide()
    self:StopMovingOrSizing()
    dragging = false
    SavePoint()
end)
arrow:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then CenterHorizontally() end
end)

-- ---------------------------------------------------------------------------------------------------------------
-- RXP's own arrow: hidden through RXP's own option "Hide waypoint arrow" (profile.disableArrow), the previous
-- value is remembered once and put back when the option is switched off or the settings are reset.

local RXPArrow = {}
ns.RXPArrow = RXPArrow

local rxpSynced = false

-- Puts RXP's remembered value back and forgets it.
local function Release(profile, rxp)
    profile.disableArrow = ns.db.rxpArrowBackup
    ns.db.rxpArrowBackup = nil
    if type(rxp.UpdateGotoSteps) == "function" then pcall(rxp.UpdateGotoSteps) end -- lets RXP show its arrow again
end

-- Brings RXP's setting in line with nav.hideRxpArrow. Returns false while RXP's profile is not ready yet.
function RXPArrow.Sync()
    local profile, rxp = ns.RxpProfile()
    if not (profile and ns.db) then return false end
    if ns.db.nav.hideRxpArrow ~= false and ns.db.rxpArrowBackup ~= nil and profile.disableArrow ~= true then
        -- We had hidden RXP's arrow and it has since been switched on again in RXP's own options ("Hide waypoint
        -- arrow"): the user's latest choice wins, our option follows it instead of hiding the arrow again.
        ns.db.nav.hideRxpArrow = false
        ns.db.rxpArrowBackup = nil
    elseif ns.db.nav.hideRxpArrow ~= false then
        if ns.db.rxpArrowBackup == nil then ns.db.rxpArrowBackup = profile.disableArrow == true end
        profile.disableArrow = true
        local frame = rxp.arrowFrame
        if type(frame) == "table" and type(frame.Hide) == "function" then pcall(frame.Hide, frame) end -- RXP's frame is not protected
    elseif ns.db.rxpArrowBackup ~= nil then
        Release(profile, rxp)
    end
    rxpSynced = true
    return true
end

-- "Reset to defaults" (before EUIRestedXPSkinDB is wiped): RXP's value back; the next refresh syncs with the reset option.
function RXPArrow.Restore()
    local profile, rxp = ns.RxpProfile()
    if profile and ns.db and ns.db.rxpArrowBackup ~= nil then Release(profile, rxp) end
    rxpSynced = false
end

-- Option changed (Navigation > Arrow): apply on the next refresh.
function RXPArrow.OnOptionChanged()
    rxpSynced = false
    ns.RefreshAll()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Wiring

ns.Arrow = { frame = arrow }

ns.RegisterRefresh(function()
    if not ns.db then return end
    if ns.loggedIn and not rxpSynced then RXPArrow.Sync() end
    Layout()
    if SafeUpdate() then arrow:Show() else arrow:Hide() end
end)

ns.OnLoaded(function()
    -- Step 8 made the default size smaller (0.85); a stored size of exactly 1.0 is the old default, move it once.
    if not ns.db.navScaleMigrated then
        ns.db.navScaleMigrated = true
        if ns.db.nav.scale == 1 then ns.db.nav.scale = 0.70 end
    end
    Layout() -- anchors, fonts and scale must exist before the first Show; RefreshAll refines them later
    C_Timer.NewTicker(IDLE, IdleTick)
end)

-- /euirxp lock | unlock
-- Options page: back to the default place (the arrow is drawn from nav.point on the next refresh).
function ns.ResetArrowPosition()
    ns.db.nav.point = { unpack(DEFAULT_POINT) }
    ns.RefreshAll()
end

function ns.SetArrowLocked(locked)
    ns.db.nav.locked = locked and true or false
    ns.Say(locked and L["Arrow locked."] or L["Arrow unlocked. Drag it with the left mouse button, right-click centres it horizontally; lock it again with /euirxp lock."])
    ns.RefreshAll()
end

-- /euirxp nav: add the arrow's own state to the navigation debug output.
local baseNavDebug = ns.NavDebug
function ns.NavDebug()
    if baseNavDebug then baseNavDebug() end
    local angle = current.angle and ("%.0f deg"):format(math.deg(current.angle)) or "-"
    ns.Say(("arrow: shown %s  state %s%s  style %s  angle %s  distance '%s'  eta '%s'  name '%s'  scale %.2f  point %s"):format(
        tostring(arrow:IsShown()), current.kind, current.mode and ("/" .. current.mode) or "", style, angle,
        tostring(distText.lastText), tostring(etaText.lastText), tostring(nameText.lastText), arrow:GetScale(),
        ns.db and ns.db.nav.point and table.concat(ns.db.nav.point, ",") or "-"))
    local profile = ns.RxpProfile()
    ns.Say(("rxp arrow: hide wanted %s  RXP disableArrow %s  backup %s  synced %s  arrived latch %s"):format(
        tostring(ns.db and ns.db.nav.hideRxpArrow), tostring(profile and profile.disableArrow),
        tostring(ns.db and ns.db.rxpArrowBackup), tostring(rxpSynced), tostring(latch.arrived)))
end
