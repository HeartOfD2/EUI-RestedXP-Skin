-- ShortestPathForever skin: the Journey section of SPF's tracker column and SPF's compass in the EllesmereUI look.
-- Only SPF's own frames are touched, through post-hooks and restyling; no SPF function is replaced and no key is
-- written onto SPF's frames (all state lives in weak tables here). Switching a part off gives SPF its own look back.
local _, ns = ...
local L = ns.L

local Mix, Try = ns.Mix, ns.Try

local TRACKER_NAME = "ShortestPathForeverObjectiveTracker" -- SPF's Journey module (ObjectiveTrackerModuleTemplate)
local COLUMN_NAME = "ForeverTrackerCompanion" -- the shared Forever column that hosts the module
local COMPASS_NAME = "ShortestPathForeverCompass" -- created by SPF the first time the compass is shown

-- EllesmereUI quest tracker defaults, used when its own settings cannot be read.
local QT_TITLE = { 1.0, 0.910, 0.471 }
local QT_BG = { 0.035, 0.035, 0.035 }
local QT_SIZE = { header = 13, title = 12, line = 10 }
local LINE_TEXT = { 0.72, 0.72, 0.72 } -- EUI objective grey
local LINE_DIM = { 0.45, 0.45, 0.45 } -- SPF's greyed rows
local WHITE = { 1, 1, 1 }

-- SPF's own compass colours (UI/Compass.lua), put back when the compass skin is switched off.
local SPF_TICK = { 0.72, 0.67, 0.55, 0.7 }
local SPF_CENTER = { 1, 0.82, 0, 0.85 }

local function Weak() return setmetatable({}, { __mode = "k" }) end

local origFont = Weak()   -- FontString -> { obj, path, size, flags } before our first change
local origColor = Weak()  -- FontString -> { r, g, b } before our first change
local fontSig = Weak()    -- FontString -> signature of the font we applied (skip identical re-applies)
local baseStyle = Weak()  -- FontString -> colour style SPF asked for (before Blizzard's hover reversal)
local origAtlas = Weak()  -- Texture -> atlas we blanked
local hookedBlock = Weak()
local own = Weak()        -- SPF frame -> our textures on it { bg, divider } / { top, bottom }

local S = { trackerHooked = false, compassHooked = false, compassAlpha = nil, busy = false }

-- ---------------------------------------------------------------------------------------------------------------
-- Settings and look sources

local function Cfg()
    return ns.db and ns.db.spfSkin
end

local function SkinAllowed()
    return not (ns.SkinningOff())
end

local function JourneyOn()
    local c = Cfg()
    return c ~= nil and c.journey == true and SkinAllowed()
end

local function CompassOn()
    local c = Cfg()
    return c ~= nil and c.compass == true and SkinAllowed()
end

-- EllesmereUIQuestTracker's settings (read only), so the Journey matches the quest list under it.
local function TrackerDb()
    local db = _G._EQT_DB
    local profile = type(db) == "table" and db.profile
    local qt = type(profile) == "table" and profile.questTracker
    if type(qt) == "table" then return qt end
end

local function Num(v, default)
    if type(v) == "number" and v == v then return v end
    return default
end

local function Sizes()
    local qt = TrackerDb() or {}
    return Num(qt.headerFontSize, QT_SIZE.header), Num(qt.titleFontSize, QT_SIZE.title), Num(qt.objectiveFontSize, QT_SIZE.line)
end

local function TitleColor()
    local qt = TrackerDb()
    if qt then return { Num(qt.titleR, QT_TITLE[1]), Num(qt.titleG, QT_TITLE[2]), Num(qt.titleB, QT_TITLE[3]) } end
    return QT_TITLE
end

-- The quest tracker's background when EllesmereUIQuestTracker is there, else the guide window colour.
local function BackgroundColor()
    local qt = TrackerDb()
    if qt and type(qt.bgR) == "number" then return Num(qt.bgR, QT_BG[1]), Num(qt.bgG, QT_BG[2]), Num(qt.bgB, QT_BG[3]) end
    local r, g, b = ns.CustomBackground()
    if r then return r, g, b end
    local p = ns.PANEL_BG
    return p[1], p[2], p[3]
end

local function WindowColor()
    local r, g, b = ns.CustomBackground()
    if r then return r, g, b end
    return 0x16 / 255, 0x16 / 255, 0x18 / 255
end

-- Font of the EllesmereUI quest tracker (falls back to the EUI skin font, then the game font).
local function TrackerFont()
    local E = _G.EllesmereUI
    local path, flags, shadow
    if type(E) == "table" then
        if type(E.GetFontPath) == "function" then path = Try(E.GetFontPath, "questTracker") end
        if type(E.GetFontOutlineFlag) == "function" then flags = Try(E.GetFontOutlineFlag, "questTracker") end
        if type(E.GetFontUseShadow) == "function" then shadow = Try(E.GetFontUseShadow, "questTracker") end
    end
    if type(path) ~= "string" or path == "" then path, flags = ns.Font() end
    if type(flags) ~= "string" then flags = "" end
    if shadow == nil then shadow = flags == "" end
    shadow = shadow and true or false
    return { path = path, flags = flags, shadow = shadow, sig = path .. "|" .. flags .. "|" .. tostring(shadow) .. "|" }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Font, colour and texture helpers (remember the original once, restore on demand)

local function RememberFont(fs)
    if origFont[fs] then return end
    local path, size, flags = fs:GetFont()
    origFont[fs] = { obj = fs:GetFontObject(), path = path, size = size, flags = flags }
end

-- Returns true when the font actually changed (the caller may need a new layout).
local function StyleFont(fs, size, font)
    if not fs then return false end
    local sig = font.sig .. size
    if fontSig[fs] == sig then return false end
    RememberFont(fs)
    local E = _G.EllesmereUI
    -- A drop shadow only renders when carried by a font object (EUI's PrimeFontShadow), so prime first, then SetFont.
    if type(E) == "table" and type(E.PrimeFontShadow) == "function" then pcall(E.PrimeFontShadow, fs, font.shadow) end
    ns.SetFont(fs, font.path, size, font.flags)
    fontSig[fs] = sig
    return true
end

local function RestoreFont(fs)
    local o = fs and origFont[fs]
    if not o then return end
    if o.obj then fs:SetFontObject(o.obj) end
    if o.path and o.size then ns.SetFont(fs, o.path, o.size, o.flags or "") end
    fontSig[fs] = nil
end

local function SetColor(fs, c, highlight)
    if not fs then return end
    if not origColor[fs] then
        local r, g, b = fs:GetTextColor()
        origColor[fs] = { r or 1, g or 1, b or 1 }
    end
    local r, g, b = c[1], c[2], c[3]
    if highlight then r, g, b = Mix(r, 1, 0.35), Mix(g, 1, 0.35), Mix(b, 1, 0.35) end
    fs:SetTextColor(r, g, b)
end

-- Back to the colour style Blizzard's tracker code last applied, else to the colour before our first change.
local function RestoreColor(fs)
    if not fs then return end
    local style = fs.colorStyle
    if type(style) == "table" and type(style.r) == "number" then
        fs:SetTextColor(style.r, style.g, style.b)
    elseif origColor[fs] then
        local c = origColor[fs]
        fs:SetTextColor(c[1], c[2], c[3])
    end
end

-- Blank a decorative texture (SetTexture("") as EllesmereUI does, which no fade animation can bring back).
local function Blank(tex)
    if not tex or not tex.SetTexture then return end
    if origAtlas[tex] == nil then
        local atlas = tex.GetAtlas and tex:GetAtlas()
        origAtlas[tex] = atlas or false
    end
    tex:SetTexture("")
end

local function Unblank(tex)
    local atlas = tex and origAtlas[tex]
    if atlas then tex:SetAtlas(atlas, true) end
    if tex then origAtlas[tex] = nil end
end

local function Tint(tex, r, g, b)
    if not tex then return end
    if tex.SetDesaturated then tex:SetDesaturated(r ~= nil) end
    if tex.SetVertexColor then tex:SetVertexColor(r or 1, g or 1, b or 1) end
end

local function OnePixel(tex, horizontal)
    if PixelUtil and PixelUtil.SetHeight and horizontal then
        PixelUtil.SetHeight(tex, 1)
    elseif PixelUtil and PixelUtil.SetWidth and not horizontal then
        PixelUtil.SetWidth(tex, 1)
    elseif horizontal then
        tex:SetHeight(1)
    else
        tex:SetWidth(1)
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Journey (SPF's tracker module)

local layoutQueued = false

-- Line heights are measured when SPF sets a text; after a font change SPF lays the section out again.
local function RequestLayout()
    if layoutQueued then return end
    layoutQueued = true
    C_Timer.After(0, function()
        layoutQueued = false
        local module = _G[TRACKER_NAME]
        if type(module) == "table" and type(module.MarkDirty) == "function" then pcall(module.MarkDirty, module) end
    end)
end

-- Our colour for a colour style SPF asked for; nil keeps Blizzard's (failed or time-limited lines).
local function LineColor(style)
    local C = OBJECTIVE_TRACKER_COLOR
    if C and style == C.NormalHighlight then -- SPF's current step
        local c = Cfg()
        if c and c.currentAccent then
            local r, g, b = ns.Accent()
            return { r, g, b }
        end
        return WHITE
    elseif style == GRAY_FONT_COLOR then
        return LINE_DIM
    elseif C and (style == C.Header or style == C.HeaderHighlight) then
        return TitleColor()
    elseif C and style ~= nil and style ~= C.Normal and style ~= C.Complete then
        return nil
    end
    return LINE_TEXT
end

local function StyleBlockText(block, fs, font)
    if not fs then return false end
    local _, titleSize, lineSize = Sizes()
    local isTitle = fs == block.HeaderText
    local changed = StyleFont(fs, isTitle and titleSize or lineSize, font)
    local C = OBJECTIVE_TRACKER_COLOR
    local style = baseStyle[fs] or (isTitle and C and C.Header) or (C and C.Normal)
    local color = LineColor(style)
    local highlight = block.isHighlighted and true or false
    if color then SetColor(fs, color, highlight) end
    local line = not isTitle and fs:GetParent()
    if line and line.Dash and line.Text == fs then
        changed = StyleFont(line.Dash, lineSize, font) or changed
        if color then SetColor(line.Dash, color, highlight) end
    end
    return changed
end

local function EachLine(block, fn)
    if type(block.usedLines) ~= "table" then return end
    for _, line in pairs(block.usedLines) do
        if type(line) == "table" and line.Text then fn(line) end
    end
end

local function StyleBlock(block, font)
    local changed = StyleBlockText(block, block.HeaderText, font)
    EachLine(block, function(line)
        changed = StyleBlockText(block, line.Text, font) or changed
    end)
    return changed
end

local function UnstyleBlock(block)
    for _, fs in ipairs({ block.HeaderText }) do
        RestoreFont(fs)
        RestoreColor(fs)
    end
    EachLine(block, function(line)
        RestoreFont(line.Text)
        RestoreColor(line.Text)
        if line.Dash then
            RestoreFont(line.Dash)
            RestoreColor(line.Dash)
        end
    end)
end

local function HookBlock(block)
    if hookedBlock[block] then return end
    hookedBlock[block] = true
    if type(block.SetStringText) == "function" then
        hooksecurefunc(block, "SetStringText", function(self, fs, _, _, colorStyle)
            if not fs then return end
            local C = OBJECTIVE_TRACKER_COLOR
            baseStyle[fs] = colorStyle or (C and C.Normal)
            if not JourneyOn() then return end
            if StyleBlockText(self, fs, TrackerFont()) then RequestLayout() end
        end)
    end
    if type(block.UpdateHighlight) == "function" then
        hooksecurefunc(block, "UpdateHighlight", function(self)
            if JourneyOn() then StyleBlock(self, TrackerFont()) end
        end)
    end
end

local function EachBlock(module, fn)
    local used = module.usedBlocks
    if type(used) ~= "table" then return end
    for _, byTemplate in pairs(used) do
        if type(byTemplate) == "table" then
            for _, block in pairs(byTemplate) do
                if type(block) == "table" then fn(block) end
            end
        end
    end
end

local function Decor(module)
    local d = own[module]
    if not d then
        d = {}
        d.bg = module:CreateTexture(nil, "BACKGROUND", nil, -8)
        d.bg:SetPoint("TOPLEFT", module, "TOPLEFT", -6, 4)
        d.bg:SetPoint("BOTTOMRIGHT", module, "BOTTOMRIGHT", 4, -6)
        d.divider = module:CreateTexture(nil, "ARTWORK")
        OnePixel(d.divider, true)
        own[module] = d
    end
    return d
end

-- The column's drag handle ("Forever tracker") shown while the column is detached: its label is the only
-- FontString of the column's own button.
local function GripLabel()
    local column = _G[COLUMN_NAME]
    if type(column) ~= "table" or type(column.GetChildren) ~= "function" then return end
    for _, child in ipairs({ column:GetChildren() }) do
        if child:GetObjectType() == "Button" then
            for _, region in ipairs({ child:GetRegions() }) do
                if region:GetObjectType() == "FontString" then return region end
            end
        end
    end
end

local function HeaderTextures(header)
    return header.Background, header.Shine, header.Glow
end

local function MinimizeTextures(button)
    if not button then return end
    return button.GetNormalTexture and button:GetNormalTexture(),
        button.GetPushedTexture and button:GetPushedTexture(),
        button.GetHighlightTexture and button:GetHighlightTexture()
end

local function StyleModule(module)
    local font = TrackerFont()
    local headerSize = Sizes()
    local r, g, b = ns.Accent()
    local header = module.Header
    if type(header) == "table" then
        local a, s, gl = HeaderTextures(header)
        Blank(a); Blank(s); Blank(gl)
        StyleFont(header.Text, headerSize, font)
        SetColor(header.Text, { r, g, b })
        local n, p, h = MinimizeTextures(header.MinimizeButton)
        Tint(n, r, g, b); Tint(p, r, g, b); Tint(h, r, g, b)
        local d = Decor(module)
        d.divider:ClearAllPoints()
        d.divider:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 7, 0)
        d.divider:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -1, 0)
        d.divider:SetColorTexture(r, g, b, 1)
        d.divider:Show()
        local opacity = ns.Clamp(Cfg().journeyBackground, 0, 100, 75) / 100
        local br, bgc, bb = BackgroundColor()
        d.bg:SetColorTexture(br, bgc, bb, opacity)
        d.bg:SetShown(opacity > 0)
    end
    local changed = false
    EachBlock(module, function(block)
        HookBlock(block)
        changed = StyleBlock(block, font) or changed
    end)
    local grip = GripLabel()
    if grip then
        StyleFont(grip, headerSize, font)
        SetColor(grip, { r, g, b })
    end
    if changed then RequestLayout() end
end

local function UnstyleModule(module)
    local header = module.Header
    if type(header) == "table" then
        local a, s, gl = HeaderTextures(header)
        Unblank(a); Unblank(s); Unblank(gl)
        RestoreFont(header.Text)
        if header.Text and origColor[header.Text] then
            local c = origColor[header.Text]
            header.Text:SetTextColor(c[1], c[2], c[3])
        end
        local n, p, h = MinimizeTextures(header.MinimizeButton)
        Tint(n); Tint(p); Tint(h)
    end
    local d = own[module]
    if d then
        d.bg:Hide()
        d.divider:Hide()
    end
    EachBlock(module, UnstyleBlock)
    local grip = GripLabel()
    if grip then
        RestoreFont(grip)
        if origColor[grip] then
            local c = origColor[grip]
            grip:SetTextColor(c[1], c[2], c[3])
        end
    end
    RequestLayout()
end

local journeyStyled = false

local function ApplyJourney()
    local module = _G[TRACKER_NAME]
    if type(module) ~= "table" or type(module.Update) ~= "function" then return false end
    if not S.trackerHooked then
        S.trackerHooked = true
        -- The shared column lays the module out through Update; new blocks and lines only appear there.
        hooksecurefunc(module, "Update", function(self)
            if JourneyOn() then StyleModule(self) end
        end)
    end
    if JourneyOn() then
        StyleModule(module)
        journeyStyled = true
    elseif journeyStyled then
        UnstyleModule(module)
        journeyStyled = false
    end
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Compass

local function CompassFrame()
    local f = _G[COMPASS_NAME]
    if type(f) == "table" and type(f.ticks) == "table" then return f end
end

local function CompassDecor(f)
    local d = own[f]
    if not d and f.Backdrop then
        d = {}
        d.top = f:CreateTexture(nil, "BACKGROUND", nil, 1)
        d.top:SetPoint("TOPLEFT", f.Backdrop, "TOPLEFT", 0, 0)
        d.top:SetPoint("TOPRIGHT", f.Backdrop, "TOPRIGHT", 0, 0)
        OnePixel(d.top, true)
        d.bottom = f:CreateTexture(nil, "BACKGROUND", nil, 1)
        d.bottom:SetPoint("BOTTOMLEFT", f.Backdrop, "BOTTOMLEFT", 0, 0)
        d.bottom:SetPoint("BOTTOMRIGHT", f.Backdrop, "BOTTOMRIGHT", 0, 0)
        OnePixel(d.bottom, true)
        own[f] = d
    end
    return d
end

local function CompassAlpha()
    if S.compassAlpha then return S.compassAlpha end
    local v = ns.SPF and ns.SPF.Get and ns.SPF.Get("compassBackground")
    return ns.Clamp(v, 0, 100, 0) / 100
end

-- The band behind the marks: SPF's opacity, our window colour, a 1 px accent edge above and below.
local function StyleBackdrop(f)
    local tex = f.Backdrop
    if not tex then return end
    local alpha = CompassAlpha()
    local d = CompassDecor(f)
    S.busy = true
    if CompassOn() then
        local r, g, b = WindowColor()
        tex:SetColorTexture(r, g, b, alpha)
    else
        tex:SetColorTexture(0, 0, 0, alpha)
    end
    S.busy = false
    if d then
        local on = CompassOn() and alpha > 0 and tex:IsShown()
        local r, g, b = ns.Accent()
        for _, line in ipairs({ d.top, d.bottom }) do
            line:SetColorTexture(r, g, b, 0.8)
            line:SetShown(on and true or false)
        end
    end
end

local function HookCompass(f)
    if S.compassHooked then return end
    S.compassHooked = true
    local tex = f.Backdrop
    if tex then
        -- SPF sets the band's opacity through SetColorTexture(0, 0, 0, opacity) and SetShown.
        hooksecurefunc(tex, "SetColorTexture", function(_, _, _, _, a)
            if S.busy then return end
            if type(a) == "number" then S.compassAlpha = a end
            StyleBackdrop(f)
        end)
        hooksecurefunc(tex, "SetShown", function()
            if not S.busy then StyleBackdrop(f) end
        end)
    end
end

local function StyleCompass(f)
    local font = TrackerFont()
    local r, g, b = ns.Accent()
    for _, tick in ipairs(f.ticks) do
        local north = tick.angle == 0
        if north then
            tick:SetColorTexture(r, g, b, 1)
        elseif tick.major then
            tick:SetColorTexture(0.92, 0.92, 0.92, 0.9)
        else
            tick:SetColorTexture(0.75, 0.75, 0.75, 0.6)
        end
        if tick.label then
            StyleFont(tick.label, 11, font)
            SetColor(tick.label, north and { r, g, b } or { 0.92, 0.92, 0.92 })
        end
    end
    if f.Center then
        f.Center:SetColorTexture(r, g, b, 1)
        f.Center:SetSize(2, 8)
    end
    StyleFont(f.Distance, 11, font)
    SetColor(f.Distance, WHITE)
    StyleFont(f.Time, 11, font)
    SetColor(f.Time, { r, g, b })
    StyleFont(f.MoverHint, 11, font)
    -- The walking marks take the accent like our arrow; destination and transport pins keep the game's art.
    Tint(f.Bend, r, g, b)
    Tint(f.Next, r, g, b)
    StyleBackdrop(f)
end

local function UnstyleCompass(f)
    for _, tick in ipairs(f.ticks) do
        tick:SetColorTexture(SPF_TICK[1], SPF_TICK[2], SPF_TICK[3], SPF_TICK[4])
        if tick.label then
            RestoreFont(tick.label)
            RestoreColor(tick.label)
        end
    end
    if f.Center then
        f.Center:SetColorTexture(SPF_CENTER[1], SPF_CENTER[2], SPF_CENTER[3], SPF_CENTER[4])
        f.Center:SetSize(1, 6)
    end
    for _, fs in ipairs({ f.Distance, f.Time, f.MoverHint }) do
        RestoreFont(fs)
        RestoreColor(fs)
    end
    Tint(f.Bend)
    Tint(f.Next)
    StyleBackdrop(f)
end

local compassStyled = false

local function ApplyCompass()
    local f = CompassFrame()
    if not f then return false end
    HookCompass(f)
    if CompassOn() then
        StyleCompass(f)
        compassStyled = true
    elseif compassStyled then
        UnstyleCompass(f)
        compassStyled = false
    end
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Wiring: SPF builds the module at its init and the compass the first time it shows, so look once a second
-- until both exist (and only while SPF is loaded).

local ticker

local function Apply()
    if not ns.db then return end
    local okJ, foundJourney = pcall(ApplyJourney)
    if not okJ then geterrorhandler()(foundJourney) end
    local okC, foundCompass = pcall(ApplyCompass)
    if not okC then geterrorhandler()(foundCompass) end
    if foundJourney and foundCompass and ticker then
        ticker:Cancel()
        ticker = nil
    end
    return foundJourney, foundCompass
end

local function StartWatching()
    if ticker or not (ns.SPF and ns.SPF.Loaded()) then return end
    ticker = C_Timer.NewTicker(1, function()
        local journeyFound, compassFound = Apply()
        if journeyFound and compassFound and ticker then
            ticker:Cancel()
            ticker = nil
        end
    end)
end

ns.SPFSkin = { Apply = Apply }

ns.OnLoaded(function()
    Apply()
    StartWatching()
end)

ns.RegisterRefresh(function()
    Apply()
    StartWatching()
end)

-- /euirxp spf: what the skin found and whether it is on.
function ns.SPFSkinDebug()
    local c = Cfg() or {}
    local module, compass = _G[TRACKER_NAME], CompassFrame()
    ns.Say(string.format(L["Journey: frame %s, hooked %s, skin %s (option %s)"],
        tostring(type(module) == "table"), tostring(S.trackerHooked), tostring(journeyStyled), tostring(c.journey)))
    ns.Say(string.format(L["Compass: frame %s, hooked %s, skin %s (option %s)"],
        tostring(compass ~= nil), tostring(S.compassHooked), tostring(compassStyled), tostring(c.compass)))
    ns.Say(string.format(L["EllesmereUI skinning available: %s, quest tracker settings found: %s"],
        tostring(SkinAllowed()), tostring(TrackerDb() ~= nil)))
end
