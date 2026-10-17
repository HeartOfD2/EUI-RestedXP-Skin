-- EUI RestedXP Skin guide window: hooks, window chrome, header, progress bar, current step,
-- upcoming steps list, animations, step boxes, guide window v2 and the hide rules.
--
-- Method: RXP stays in charge of content and layout. We mute its backdrops (colour alpha 0), draw flat chrome
-- with textures of our own next to them, restyle fonts and add a header. Everything runs from hooksecurefunc
-- post-hooks and is idempotent: textures are created once, later runs only recolour and re-measure.
-- RXPFrame:Hide() is never called. RXP's window has no protected frames of its own, so the skin may run
-- in combat; the two step boxes (RXPItemFrame / RXPTargetFrame) hold secure buttons and are only touched outside combat
-- (ns.Queue); pinned under the window they lock RXPFrame itself in combat (see WindowLocked).
-- Our own state lives in `data`, never in fields of RXP's frames.
local addonName, ns = ...
local L = ns.L

local WHITE = "Interface\\Buttons\\WHITE8X8"
local HEADER_H = 46 -- header height
local RXP_HEADER_H = 35 -- RXP's own GuideName height, put back when the skin is switched off
local BUTTON, BUTTON_GAP, COUNTER_W = 26, 3, 60
local NUMBER_H, NUMBER_EXTRA = 22, 16 -- step number row; room added above the first goal (RXP starts it at -10)
local COUNT_BAR_H = 3
local COUNT_LEFT = 29 -- RXP's goal text starts 29 px from the step frame's left edge (check box 6 + 12 + 11)
local SIZE_TITLE, SIZE_SUB, SIZE_COUNTER, SIZE_NUMBER, SIZE_GOAL = 16, 12, 13, 18, 15
local SIZE_ROW, SIZE_ROW_NUMBER = 14, 11 -- upcoming steps: text and step number
local ROW_TEXT_A, ROW_NUMBER_A, ROW_SEPARATOR_A, ROW_HOVER_A = 0.75, 0.40, 0.05, 0.04
local LINE_H, ROW_PAD, MAX_LINES = 17, 10, 5 -- one line per goal of a listed step, at most 5 goals
local LIST_PAD = 34 -- window height = height of the rows + LIST_PAD (13 header overlap + 20 footer + 1)
local WINDOW_INSET = 3 -- RXP insets its panels from RXPFrame by 3 px (GuideWindow.lua:1388-1389, 1413)
local MIN_HEIGHT = 28 -- RXP's own minimum window height (GuideWindow.lua:2350)
local SEP = " \194\183 " -- middle dot
local STEP_TINT = 0.07 -- current step: accent over the window colour
local STEP_TINT_NEUTRAL = 0.04 -- the same with white, while a theme other than ours is active
local FLASH_EXTRA, FLASH_TIME = 0.10, 0.45 -- animations "SUBTLE": extra accent tint that fades out on a new step
local BOX_GAP = 16 -- distance of the step boxes below the window (their title sticks out 10 px above the frame)
local THEME_NAME = "EUIRestedXPSkin"

local S = {
    hooked = false, applying = false, skinned = false, reported = false,
    layoutKey = nil, width = nil, widthBefore = nil, applies = 0, hookCount = 0,
    sig = nil, dirty = true, skipped = { frame = 0, refresh = 0 }, reruns = 0, go = nil,
    calls = { visuals = 0, text = 0, frame = 0, render = 0, step = 0 },
    -- upcoming list, hiding, v2 and target boxes
    growUp = true, rowsDirty = true, listRows = 0, listHeight = 0, listShift = 0, listProgress = nil, heightBefore = nil, lastProgress = nil,
    hidden = false, alphaWas = nil, v2Pending = false, windowDeferred = false,
    boxHooks = { item = false, target = false }, boxQueued = false, boxes = 0, boxPoints = {},
}
local data = setmetatable({}, { __mode = "k" }) -- per-frame state of ours
local cur -- colours and flags of the latest apply (hover handlers read them)
local Request -- defined below with the apply machinery; click hooks above it need it

local Clamp, Mix, Rxp = ns.Clamp, ns.Mix, ns.Rxp

local function Data(object)
    local d = data[object]
    if not d then
        d = {}
        data[object] = d
    end
    return d
end

-- RXP texts carry colour codes, texture escapes and literal "\n"; none of that belongs in a header or a count.
local function Strip(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    text = text:gsub("|T.-|t", "")
    text = text:gsub("|A.-|a", "")
    text = text:gsub("\\n", " ")
    text = text:gsub("\n", " ")
    return text
end

-- Sets a font once per (path, size, flags); true when it actually changed (heights must be measured again then).
-- The size is read back as well: RXP sets the fonts of its upcoming-step rows again whenever a guide loads.
local function SetFontFor(fs, path, size, flags)
    local d = Data(fs)
    local sig = path .. "|" .. size .. "|" .. flags
    if d.fontSig == sig then
        local _, actual = fs:GetFont()
        if type(actual) == "number" and math.abs(actual - size) < 0.01 then return false end
    end
    d.fontSig = sig
    ns.SetFont(fs, path, size, flags)
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Flat boxes: one background texture and four 1 px edges per frame, created once and only recoloured afterwards

local function Box(frame)
    local d = Data(frame)
    if d.box then return d.box end
    local box = { edges = {} }
    box.bg = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    box.bg:SetAllPoints(frame)
    local specs = {
        { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
        { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false },
    }
    for i, spec in ipairs(specs) do
        local edge = frame:CreateTexture(nil, "BORDER", nil, -6)
        edge:SetPoint(spec[1])
        edge:SetPoint(spec[2])
        if spec[3] then edge:SetHeight(1) else edge:SetWidth(1) end
        box.edges[i] = edge
    end
    d.box = box
    return box
end

-- r == nil: no background; er == nil: no edges; skipTop leaves the top edge off (a box that continues upwards).
local function PaintBox(box, r, g, b, a, er, eg, eb, ea, skipTop)
    if r then
        box.bg:SetColorTexture(r, g, b, a)
        box.bg:Show()
    else
        box.bg:Hide()
    end
    for i = 1, 4 do
        local edge = box.edges[i]
        if er and not (skipTop and i == 1) then
            edge:SetColorTexture(er, eg, eb, ea)
            edge:Show()
        else
            edge:Hide()
        end
    end
end

-- A 1 px ring drawn over a button, `inset` px inside its edge (the step boxes get two: black outside, white inside).
local function Ring(frame, inset, sub)
    local ring = {}
    local specs = {
        { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
        { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false },
    }
    for i, spec in ipairs(specs) do
        local edge = frame:CreateTexture(nil, "OVERLAY", nil, sub)
        for p = 1, 2 do
            local point = spec[p]
            edge:SetPoint(point, frame, point, point:find("LEFT") and inset or -inset, point:find("TOP") and -inset or inset)
        end
        if spec[3] then edge:SetHeight(1) else edge:SetWidth(1) end
        ring[i] = edge
    end
    return ring
end

local function PaintRing(ring, r, g, b, a)
    for i = 1, 4 do
        if r then
            ring[i]:SetColorTexture(r, g, b, a)
            ring[i]:Show()
        else
            ring[i]:Hide()
        end
    end
end

-- RXP (re)sets its backdrops on every UpdateVisuals; muting them again after each hook keeps them invisible.
local function Mute(frame)
    if frame and frame.SetBackdropColor then
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

-- Mouse off/on that remembers each frame's own state under `key`, so RXP's choice comes back exactly. Used for the
-- hide rules ("mouseWas") and for RXP's scrolling list, which we replace by our own rows ("listWas").
local function MouseOff(frame, key)
    if not (frame and frame.EnableMouse) then return end
    local d = Data(frame)
    if d[key] == nil then d[key] = frame:IsMouseEnabled() and true or false end
    if frame:IsMouseEnabled() then frame:EnableMouse(false) end
end

local function MouseOn(frame, key)
    local d = frame and data[frame]
    if d and d[key] ~= nil then
        local was = d[key]
        d[key] = nil
        if was then frame:EnableMouse(true) end
    end
end

-- Alpha for a list of regions that may contain nil holes (ipairs would stop at the first one).
local function SetAlphaAll(alpha, ...)
    for i = 1, select("#", ...) do
        local region = select(i, ...)
        if region then region:SetAlpha(alpha) end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- RXP access

local function GetFrames()
    local f = _G.RXPFrame
    if type(f) ~= "table" or not (f.GuideName and f.Footer and f.BottomFrame and f.CurrentStepFrame) then return end
    return f
end

-- The beta guide window v2 hides the classic window's children; then there is nothing to skin.
-- RXP evaluates this live from the profile: enableBetaFeatures and enableV2Interface.
local function IsV2()
    local rxp = Rxp()
    if rxp and type(rxp.v2) == "table" and type(rxp.v2.IsGuideWindowEnabled) == "function" then
        local ok, enabled = pcall(rxp.v2.IsGuideWindowEnabled, rxp.v2)
        return ok and enabled and true or false
    end
    return false
end

-- The skin is off while EUI's skinning of other addons is off, without touching guide.enabled: it comes back
-- by itself once the skinning is on again (after /reload). It is also off while v2 is switched off but not yet
-- reloaded (the classic window's children were hidden by v2).
local function Wanted()
    local g = ns.db and ns.db.guide
    return g ~= nil and g.enabled == true and g.layout ~= "STANDARD" and not IsV2() and not S.v2Pending
        and not (ns.SkinningOff())
end

local function Progress()
    local rxp = Rxp()
    if rxp and type(rxp.GetGuideProgress) == "function" then
        local ok, value = pcall(rxp.GetGuideProgress)
        if ok and type(value) == "number" then return value end
    end
end

-- Title, subtitle, step and step count of the loaded guide. RXP has no level fields: the range is the guide name's
-- "1-6 Coldridge Valley" prefix.
local function GuideInfo()
    local rxp = Rxp()
    local guide = rxp and rxp.currentGuide
    if type(guide) ~= "table" or guide.empty then return end

    local name = type(guide.title) == "string" and guide.title or nil
    if not name and type(rxp.GetGuideName) == "function" then
        local ok, value = pcall(rxp.GetGuideName, guide)
        if ok and type(value) == "string" then name = value end
    end
    if not name or name == "" then name = guide.displayname or guide.name end
    if type(name) ~= "string" then name = "" end
    name = Strip(name)

    local lo, hi
    if type(guide.name) == "string" then lo, hi = guide.name:match("^(%d+)%s*%-%s*(%d+)") end
    name = name:gsub("^%d+%s*%-%s*%d+%s*", "")
    if name == "" then name = "RestedXP" end

    local sub = "RestedXP"
    if lo then
        sub = L["Level %s-%s"]:format(lo, hi) .. SEP .. sub
    elseif type(guide.subgroup) == "string" and guide.subgroup ~= "" then
        sub = Strip(guide.subgroup) .. SEP .. sub
    end

    local total = type(guide.steps) == "table" and #guide.steps or 0
    return { title = name, subtitle = sub, step = Progress(), total = total }
end

-- Header buttons go through RXP's own function, exactly like the "Go to step n" menu: RXP.SetStep(n).
-- GetGuideProgress() is the step SetStep ended on, i.e. the highest of the active steps. Steps with
-- `completewith` are sticky and stay active next to it; SetStep never stops on a sticky step but walks on to the
-- next one (GuideWindow.lua:799-801). So "back" must aim at the nearest earlier step that is not sticky, or it would
-- land on the current step again. Forward needs no help: SetStep itself walks over sticky and completed steps.
local function GoStep(delta)
    local rxp = Rxp()
    if not (rxp and type(rxp.SetStep) == "function" and type(rxp.GetGuideProgress) == "function") then return end
    local guide = rxp.currentGuide
    if type(guide) ~= "table" or type(guide.steps) ~= "table" then return end
    local step = rxp.GetGuideProgress()
    if type(step) ~= "number" then return end
    local target = step + delta
    if delta < 0 then
        local level = UnitLevel("player")
        while target >= 1 do
            local candidate = guide.steps[target]
            local hidden = candidate and type(candidate.level) == "number" and type(level) == "number"
                and candidate.level > level -- a step above the player's level is not shown (GuideWindow.lua:2152)
            if candidate and not candidate.sticky and not hidden then break end
            target = target - 1
        end
    end
    if target < 1 or target > #guide.steps then return end -- beyond the last step RXP would jump to the next guide
    S.go = { from = step, want = target, time = GetTime() }
    rxp.SetStep(target)
    S.go.got = rxp.GetGuideProgress()
end

local function OpenMenu()
    local f = GetFrames()
    if f and type(f.DropDownMenu) == "function" then f.DropDownMenu() end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Animations "SUBTLE": a short accent flash on the current step after a step change, and a progress bar that glides.
-- One driver frame whose OnUpdate only exists while something is moving.

local anim = { flash = nil, bar = nil }
local driver = CreateFrame("Frame")

local function FlashExtra()
    local flash = anim.flash
    if not flash then return 0 end
    local t = (GetTime() - flash.start) / FLASH_TIME
    if t >= 1 then
        anim.flash = nil
        return 0
    end
    return FLASH_EXTRA * (1 - t) * (1 - t)
end

local function PaintFill(box, fill, extra)
    local k = fill.k + extra
    box.bg:SetColorTexture(Mix(fill.r, fill.er, k), Mix(fill.g, fill.eg, k), Mix(fill.b, fill.eb, k), fill.a)
end

local function AnimTick(_, elapsed)
    local busy = false
    if anim.flash then
        busy = true
        local extra = FlashExtra()
        local f = GetFrames()
        local pool = f and f.CurrentStepFrame.framePool
        if type(pool) == "table" then
            for i = 1, #pool do
                local d = data[pool[i]]
                if d and d.skinned and d.fill and d.box then PaintFill(d.box, d.fill, extra) end
            end
        end
    end
    local bar = anim.bar
    if bar then
        local diff = bar.target - bar.d.shown
        if math.abs(diff) < 0.02 then
            bar.d.shown = bar.target
            anim.bar = nil
        else
            bar.d.shown = bar.d.shown + diff * math.min(1, elapsed * 10)
            busy = true
        end
        bar.frame:SetValue(bar.d.shown)
    end
    if not busy then driver:SetScript("OnUpdate", nil) end
end

local function StartAnim()
    if not driver:GetScript("OnUpdate") then driver:SetScript("OnUpdate", AnimTick) end
end

local function StopAnim()
    anim.flash, anim.bar = nil, nil
    driver:SetScript("OnUpdate", nil)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Window and header (built once)

local function EnsureWindow(f)
    local d = Data(f)
    if d.window then return d.window end
    -- One flat panel from the top of the header to the bottom of the footer; RXP's frames sit on top of it.
    local w = CreateFrame("Frame", nil, f)
    w:SetFrameLevel(f:GetFrameLevel())
    w:SetPoint("TOPLEFT", f.GuideName, "TOPLEFT", 0, 0)
    w:SetPoint("BOTTOMRIGHT", f.Footer, "BOTTOMRIGHT", 0, 0)
    d.window = w
    return w
end

local function PaintButton(button)
    local d = Data(button)
    if not (cur and d.box) then return end
    if d.hover then
        PaintBox(d.box, 1, 1, 1, 0.06, cur.ar, cur.ag, cur.ab, 0.9)
    else
        PaintBox(d.box, nil, nil, nil, nil, 1, 1, 1, 0.12)
    end
    local shade = d.hover and 1 or 0.7
    if d.label then d.label:SetTextColor(1, 1, 1, shade) end
    if d.icon then
        if d.iconAccent then -- the cog: accent coloured
            d.icon:SetDesaturated(true)
            local k = d.hover and 0.35 or 0 -- full accent when idle, lightened towards white on hover
            local pr, pg, pb = cur.pr or cur.ar, cur.pg or cur.ag, cur.pb or cur.ab -- same colour as the progress bar
            local r, g, b = pr + (1 - pr) * k, pg + (1 - pg) * k, pb + (1 - pb) * k
            d.icon:SetVertexColor(r, g, b, 1)
            if d.glow then d.glow:SetVertexColor(r, g, b, d.hover and 0.6 or 0.4) end
        else
            d.icon:SetVertexColor(1, 1, 1, shade)
        end
    end
end

local function MakeButton(parent, tooltip, onClick, onRightClick, hint)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(BUTTON, BUTTON)
    if onRightClick then button:RegisterForClicks("LeftButtonUp", "RightButtonUp") else button:RegisterForClicks("LeftButtonUp") end
    local d = Data(button)
    d.box = Box(button)
    button:SetScript("OnEnter", function(self)
        Data(self).hover = true
        PaintButton(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(tooltip)
        if hint then GameTooltip:AddLine(hint, 1, 1, 1) end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
        Data(self).hover = false
        PaintButton(self)
        if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
    end)
    button:SetScript("OnClick", function(_, mouseButton)
        local ok, err = pcall(mouseButton == "RightButton" and onRightClick or onClick)
        if not ok then geterrorhandler()(err) end
    end)
    return button
end

local function EnsureHeader(f)
    local d = Data(f)
    if d.header then return d.header end
    local gn = f.GuideName
    local h = CreateFrame("Frame", nil, gn)
    h:SetAllPoints(gn)
    h:SetFrameLevel(gn:GetFrameLevel() + 2) -- mouse stays off: clicks outside our buttons still reach RXP's header

    h.bar = h:CreateTexture(nil, "ARTWORK")
    h.bar:SetSize(4, 20)
    h.bar:SetPoint("LEFT", h, "LEFT", 10, 0)

    local reserve = 8 + BUTTON * 3 + BUTTON_GAP * 2 + 10 + COUNTER_W + 8 -- right-hand cluster the title must not enter
    h.title = h:CreateFontString(nil, "OVERLAY")
    h.title:SetFont(STANDARD_TEXT_FONT, SIZE_TITLE, "")
    h.title:SetPoint("TOPLEFT", h, "TOPLEFT", 22, -8)
    h.title:SetPoint("TOPRIGHT", h, "TOPRIGHT", -reserve, -8)
    h.title:SetHeight(SIZE_TITLE + 3)
    h.title:SetJustifyH("LEFT")
    h.title:SetWordWrap(false)

    h.subtitle = h:CreateFontString(nil, "OVERLAY")
    h.subtitle:SetFont(STANDARD_TEXT_FONT, SIZE_SUB, "")
    h.subtitle:SetPoint("TOPLEFT", h, "TOPLEFT", 22, -28)
    h.subtitle:SetPoint("TOPRIGHT", h, "TOPRIGHT", -reserve, -28)
    h.subtitle:SetHeight(SIZE_SUB + 3)
    h.subtitle:SetJustifyH("LEFT")
    h.subtitle:SetWordWrap(false)

    h.menu = MakeButton(h, L["Guide menu"], OpenMenu, function() ns.OpenOptions("Guide") end,
        L["Right-click: EUI RestedXP Skin options"])
    h.menu:SetPoint("RIGHT", h, "RIGHT", -8, 1)
    local icon = h.menu:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("CENTER")
    local path = "Interface\\Buttons\\UI-OptionsButton"
    local rxp = Rxp()
    if rxp and type(rxp.GetV1Texture) == "function" then
        local ok, value = pcall(rxp.GetV1Texture, "rxp_cog-32")
        if ok and type(value) == "string" and value ~= "" then path = value end
    end
    icon:SetTexture(path)
    -- the cog texture is dark; the same texture added on top lifts it to the full accent colour
    local glow = h.menu:CreateTexture(nil, "OVERLAY")
    glow:SetAllPoints(icon)
    glow:SetTexture(path)
    glow:SetBlendMode("ADD")
    glow:SetDesaturated(true)
    Data(h.menu).glow = glow
    Data(h.menu).icon = icon
    Data(h.menu).iconAccent = true

    h.next = MakeButton(h, L["Next step"], function() GoStep(1) end)
    h.next:SetPoint("RIGHT", h.menu, "LEFT", -BUTTON_GAP, 0)
    h.next.label = h.next:CreateFontString(nil, "OVERLAY")
    h.next.label:SetPoint("CENTER", 0, 1)
    h.next.label:SetFont(STANDARD_TEXT_FONT, SIZE_TITLE, "")
    h.next.label:SetText(">")
    Data(h.next).label = h.next.label

    h.prev = MakeButton(h, L["Previous step"], function() GoStep(-1) end)
    h.prev:SetPoint("RIGHT", h.next, "LEFT", -BUTTON_GAP, 0)
    h.prev.label = h.prev:CreateFontString(nil, "OVERLAY")
    h.prev.label:SetPoint("CENTER", 0, 1)
    h.prev.label:SetFont(STANDARD_TEXT_FONT, SIZE_TITLE, "")
    h.prev.label:SetText("<")
    Data(h.prev).label = h.prev.label

    h.counter = h:CreateFontString(nil, "OVERLAY")
    h.counter:SetFont(STANDARD_TEXT_FONT, SIZE_COUNTER, "")
    h.counter:SetSize(COUNTER_W, SIZE_COUNTER + 3)
    h.counter:SetPoint("RIGHT", h.prev, "LEFT", -10, 0)
    h.counter:SetJustifyH("RIGHT")
    h.counter:SetWordWrap(false)

    -- Progress: 2 px along the bottom edge of the header (track white 6 %, fill accent).
    h.progress = CreateFrame("StatusBar", nil, h)
    h.progress:SetPoint("BOTTOMLEFT", h, "BOTTOMLEFT", 0, 0)
    h.progress:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", 0, 0)
    h.progress:SetHeight(2)
    h.progress:SetStatusBarTexture(WHITE)
    h.progress:SetMinMaxValues(0, 1)
    h.progress:SetValue(0)
    h.progress.track = h.progress:CreateTexture(nil, "BACKGROUND")
    h.progress.track:SetAllPoints(h.progress)

    d.header = h
    return h
end

-- ---------------------------------------------------------------------------------------------------------------
-- Colours and flags of one run

local function Context(g)
    local c = { g = g }
    c.ar, c.ag, c.ab = ns.Accent()
    c.path, c.flags = ns.Font()
    if g.font == "GAME" then c.path, c.flags = STANDARD_TEXT_FONT, "" end -- Fonts page: the game's own font instead of EUI's
    c.sTitle = Clamp(g.sizeTitle, 12, 20, SIZE_TITLE)
    c.sGoal = Clamp(g.sizeGoal, 11, 20, SIZE_GOAL)
    c.sRow = Clamp(g.sizeRow, 11, 16, SIZE_ROW)
    local rxp = Rxp()
    local colors = rxp and (rxp.colors or rxp.activeTheme)
    local bg = colors and colors.background

    -- accent tint, step number and count bars are ours only while our theme is the active one; with another
    -- RXP theme they take that theme's text colour and a neutral fill.
    local active = rxp and rxp.activeTheme
    local name = type(active) == "table" and active.name or nil
    c.ours = name == THEME_NAME or (name == nil and ns.ThemeActive())
    c.tr, c.tg, c.tb = 1, 1, 1
    local text = type(active) == "table" and active.textColor
    if type(text) == "table" and type(text[1]) == "number" and type(text[2]) == "number" and type(text[3]) == "number" then
        c.tr, c.tg, c.tb = text[1], text[2], text[3]
    end

    if type(bg) == "table" and type(bg[1]) == "number" and type(bg[2]) == "number" and type(bg[3]) == "number" then
        c.bgR, c.bgG, c.bgB = bg[1], bg[2], bg[3] -- follows the RXP theme: another theme's colours stay as they are
    else
        local cr, cg, cb = ns.CustomBackground()
        if cr then
            c.bgR, c.bgG, c.bgB = cr, cg, cb
        else
            local base = ns.PANEL_BG
            local k = Clamp(g.tint, 0, 1, 0.12) * 0.5
            c.bgR, c.bgG, c.bgB = Mix(base[1], c.ar, k), Mix(base[2], c.ag, k), Mix(base[3], c.ab, k)
        end
    end
    c.custom = ns.CustomBackground() ~= nil -- own window colour: no accent in the panels
    c.pr, c.pg, c.pb = c.ar, c.ag, c.ab -- progress bars: the accent, or the colour the user chose on the Colors page
    local pc = g.progressColor
    if type(pc) == "table" and type(pc.r) == "number" and type(pc.g) == "number" and type(pc.b) == "number" then
        c.pr, c.pg, c.pb = Clamp(pc.r, 0, 1, c.ar), Clamp(pc.g, 0, 1, c.ag), Clamp(pc.b, 0, 1, c.ab)
    end
    c.alpha = Clamp(g.alpha, 0.3, 1, 0.9)
    c.border = g.border ~= "NONE"
    c.header = g.header ~= false
    c.progress = g.progress ~= false
    c.stepNumbers = g.stepNumbers ~= false
    c.upcoming = math.floor(Clamp(g.upcoming, 0, 5, 3) + 0.5)
    c.lockBoxes = g.lockBoxes ~= false
    c.boxEdge, c.boxAlong, c.growUp = g.boxEdge, g.boxAlong, g.growth ~= "DOWN"
    c.growth = g.growth == "DOWN" and "DOWN" or "UP"
    c.animate = g.animations ~= "OFF"
    -- Only a width the user set is applied; RXP does not save the window width, so anything else keeps the current one.
    c.width = type(g.width) == "number" and g.width >= 240 and Clamp(g.width, 240, 480, nil) or nil
    return c
end

-- ---------------------------------------------------------------------------------------------------------------
-- Pieces of one run

-- Fonts of RXP's current-step frames. They are set once at creation by RXP, so this only fires for new frames or
-- after a font change; the caller then lets RXP measure again.
local function StyleStepFonts(f, c)
    local pool = f.CurrentStepFrame.framePool
    if type(pool) ~= "table" then return false end
    local changed = false
    for i = 1, #pool do
        local sf = pool[i]
        if sf.number and sf.number.text then
            if SetFontFor(sf.number.text, c.path, SIZE_NUMBER, c.flags) then changed = true end
        end
        for e = 1, #(sf.elements or {}) do
            local ef = sf.elements[e]
            if ef and ef.text and SetFontFor(ef.text, c.path, c.sGoal, c.flags) then changed = true end
        end
    end
    return changed
end

local function Relayout(f)
    local rxp = Rxp()
    if not (rxp and type(rxp.currentGuide) == "table") then return end
    if type(f.BottomFrame.UpdateFrame) == "function" then pcall(f.BottomFrame.UpdateFrame) end
    if type(f.CurrentStepFrame.UpdateText) == "function" then pcall(f.CurrentStepFrame.UpdateText) end
    -- RXP scrolled the list with the old row heights; scroll to the current step again with the new ones
    local step = Progress()
    if step and type(f.BottomFrame.StepScroll) == "function" then pcall(f.BottomFrame.StepScroll, f.BottomFrame, step) end
end

local function SkinWindow(f, c)
    local w = EnsureWindow(f)
    w:Show()
    PaintBox(Box(w), c.bgR, c.bgG, c.bgB, c.alpha, c.border and 1 or nil, 1, 1, 0.08)

    local gn, foot = f.GuideName, f.Footer
    Mute(f.BottomFrame)
    Mute(gn)
    Mute(foot)
    if foot.bg then foot.bg:SetAlpha(0) end
    if foot.text then foot.text:SetAlpha(0) end
    -- RXP's gear sits on the footer; with our header it moves into the header, without it stays where it is.
    if foot.cog then
        if c.header then foot.cog:Hide() else foot.cog:Show() end
    end
end

local function SkinHeader(f, c)
    local gn = f.GuideName
    local height = c.header and HEADER_H or RXP_HEADER_H
    if gn:GetHeight() ~= height then gn:SetHeight(height) end
    local alpha = c.header and 0 or 1
    SetAlphaAll(alpha, gn.bg, gn.icon, gn.classIcon, gn.text)

    local h = EnsureHeader(f)
    if not c.header then
        h:Hide()
        return
    end
    h:Show()

    h.bar:SetColorTexture(c.ar, c.ag, c.ab, 1)
    SetFontFor(h.title, c.path, c.sTitle, c.flags)
    SetFontFor(h.subtitle, c.path, SIZE_SUB, c.flags)
    SetFontFor(h.counter, c.path, SIZE_COUNTER, c.flags)
    SetFontFor(h.prev.label, c.path, SIZE_TITLE, c.flags)
    SetFontFor(h.next.label, c.path, SIZE_TITLE, c.flags)
    h.title:SetTextColor(1, 1, 1, 1)
    h.subtitle:SetTextColor(1, 1, 1, 0.5)
    h.counter:SetTextColor(1, 1, 1, 1)

    local info = GuideInfo()
    local title, subtitle, counter = "RestedXP", L["Right-click to pick a guide"], ""
    local step, total = 0, 0
    if info then
        title, subtitle = info.title, info.subtitle
        step, total = info.step or 0, info.total
        if info.step and total > 0 then counter = ("%d|cff7d7d7d / %d|r"):format(info.step, total) end
    end
    local d = Data(h)
    if d.title ~= title then d.title = title; h.title:SetText(title) end
    if d.subtitle ~= subtitle then d.subtitle = subtitle; h.subtitle:SetText(subtitle) end
    if d.counter ~= counter then d.counter = counter; h.counter:SetText(counter) end

    local p = h.progress
    if c.progress and total > 0 then
        p:SetStatusBarColor(c.pr, c.pg, c.pb, 1)
        p.track:SetColorTexture(1, 1, 1, 0.06)
        p:SetMinMaxValues(0, total)
        local target = math.max(0, math.min(step, total))
        local dp = Data(p)
        -- animations: the fill glides to a new value instead of jumping (a new guide or the first draw jumps)
        if c.animate and dp.shown and dp.total == total and math.abs(dp.shown - target) >= 0.5 then
            anim.bar = { frame = p, target = target, d = dp }
            StartAnim()
        else
            p:SetValue(target)
            dp.shown = target
            anim.bar = nil
        end
        dp.total = total
        p:Show()
    else
        p:Hide()
    end

    for _, button in ipairs({ h.prev, h.next, h.menu }) do PaintButton(button) end
end

-- Count goals ("Name: 3/8") only exist as text in RXP: a 3 px bar along the bottom of the goal row.
local function SkinCount(ef, c)
    local d = Data(ef)
    local value, max
    local element = ef.element
    if type(element) == "table" and type(element.text) == "string" and ef:IsShown() then
        local a, b = Strip(element.text):match("(%d+)%s*/%s*(%d+)")
        a, b = tonumber(a), tonumber(b)
        if a and b and b > 0 then value, max = a, b end
    end
    if not value then
        if d.bar then d.bar:Hide() end
        return
    end
    local bar = d.bar
    if not bar then
        bar = CreateFrame("StatusBar", nil, ef)
        bar:SetStatusBarTexture(WHITE)
        bar:SetHeight(COUNT_BAR_H)
        bar:SetPoint("BOTTOMLEFT", ef, "BOTTOMLEFT", COUNT_LEFT, 0)
        bar:SetPoint("BOTTOMRIGHT", ef, "BOTTOMRIGHT", -8, 0)
        bar.track = bar:CreateTexture(nil, "BACKGROUND")
        bar.track:SetAllPoints(bar)
        d.bar = bar
    end
    bar.track:SetColorTexture(1, 1, 1, 0.10)
    if c.ours then
        bar:SetStatusBarColor(c.pr, c.pg, c.pb, 0.75)
    else
        bar:SetStatusBarColor(c.tr, c.tg, c.tb, 0.6)
    end
    bar:SetMinMaxValues(0, max)
    bar:SetValue(math.min(value, max))
    bar:Show()
end

-- Hand a step frame back to RXP (tip windows, and frames that left the active list).
local function UnskinStepFrame(sf)
    local d = Data(sf)
    if not d.skinned then return end
    d.skinned = false
    d.fill = nil
    local rxp = Rxp()
    local colors = rxp and (rxp.colors or rxp.activeTheme)
    local bg = colors and colors.background
    for _, frame in ipairs({ sf, sf.number }) do
        if frame and frame.SetBackdropColor then
            if type(bg) == "table" then frame:SetBackdropColor(unpack(bg)) else frame:SetBackdropColor(0, 0, 0, 1) end
            frame:SetBackdropBorderColor(1, 1, 1, 1)
        end
    end
    local box = Data(sf).box
    if box then PaintBox(box) end
    if sf.number then
        sf.number:ClearAllPoints()
        sf.number:SetPoint("TOPLEFT", sf, "TOPLEFT", 7, 5)
    end
    for e = 1, #(sf.elements or {}) do
        local bar = Data(sf.elements[e]).bar
        if bar then bar:Hide() end
    end
end

-- One active, non-tip step frame; returns true when we made room for the number above the first goal.
local function SkinStepFrame(sf, c)
    local d = Data(sf)
    d.skinned = true
    Mute(sf)
    local er, eg, eb = c.ar, c.ag, c.ab -- number colour: accent only with our own theme
    local fr, fg, fb, k = c.ar, c.ag, c.ab, STEP_TINT -- panel fill: accent tint, unless the window colour is the user's
    if not c.ours then
        er, eg, eb = c.tr, c.tg, c.tb
        fr, fg, fb, k = c.tr, c.tg, c.tb, STEP_TINT_NEUTRAL
    elseif c.custom then
        fr, fg, fb, k = 1, 1, 1, STEP_TINT_NEUTRAL
    end
    local fill = { r = c.bgR, g = c.bgG, b = c.bgB, a = c.alpha, er = fr, eg = fg, eb = fb, k = k }
    d.fill = fill
    local box, extra = Box(sf), FlashExtra()
    PaintBox(box, Mix(c.bgR, fr, k + extra), Mix(c.bgG, fg, k + extra), Mix(c.bgB, fb, k + extra), c.alpha,
        c.border and 1 or nil, 1, 1, 0.06)

    local shown = false
    local nf = sf.number
    if nf and nf.text then
        Mute(nf)
        local text = nf.text:GetText()
        shown = c.stepNumbers and type(text) == "string" and text ~= ""
        if shown then
            nf:SetAlpha(1)
            nf.text:SetTextColor(er, eg, eb, 1)
            nf:SetSize(math.ceil(nf.text:GetStringWidth()) + 6, NUMBER_H)
            nf:ClearAllPoints()
            nf:SetPoint("TOPLEFT", sf, "TOPLEFT", 8, -4)
        else
            nf:SetAlpha(0)
        end
    end

    for e = 1, #(sf.elements or {}) do
        local ef = sf.elements[e]
        if ef then SkinCount(ef, c) end
    end

    -- RXP starts the first goal 10 px below the top (UpdateText). Right after a RXP layout pass it still sits there:
    -- push it, and with it the whole chain below, down by one number row. A second run finds it already moved.
    local first = sf.elements and sf.elements[1]
    if shown and first and first:IsShown() then
        local _, _, _, x, y = first:GetPoint(1)
        if type(y) == "number" and ns.CanAccess(y) and y > -10 - NUMBER_EXTRA / 2 then
            x = type(x) == "number" and x or 0
            first:ClearAllPoints()
            first:SetPoint("TOPLEFT", sf, "TOPLEFT", x, y - NUMBER_EXTRA)
            first:SetPoint("TOPRIGHT", sf, "TOPRIGHT", x, y - NUMBER_EXTRA)
            sf:SetHeight(sf:GetHeight() + NUMBER_EXTRA)
            return true
        end
    end
    return false
end

local function SkinSteps(f, c)
    local csf = f.CurrentStepFrame
    local pool = csf.framePool
    if type(pool) ~= "table" then return end
    local added = 0
    for i = 1, #pool do
        local sf = pool[i]
        local step = sf.step
        if step and not step.tip then
            if SkinStepFrame(sf, c) then added = added + 1 end
        else
            UnskinStepFrame(sf)
        end
    end
    if added > 0 then csf:SetHeight(csf:GetHeight() + NUMBER_EXTRA * added) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Upcoming steps: our own list. RXP's scrolling list stays hidden: its rows reappear on hover and scrolling, its
-- rebuild resets whatever is done to them, and its heights and scroll positions are private. We read what RXP has
-- already worked out for each step (`step.text`) and list `guide.upcoming` steps, one line per goal (scrollable).

-- The goals of a step, one line each (RXP joins them with a line break in step.text), at most MAX_LINES.
local function Lines(text)
    text = text:gsub("\\n", " ") -- a literal backslash-n inside one goal is a space
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            lines[#lines + 1] = line
            if #lines >= MAX_LINES then break end
        end
    end
    return lines
end

-- Right click or double click on a row jumps to that step: RXP's own "Go to step n", without its menu.
local function JumpTo(row, button)
    local d = Data(row)
    local now = GetTime()
    local double = d.lastClick and now - d.lastClick < 0.4
    d.lastClick = now
    if not (button == "RightButton" or (button == "LeftButton" and double)) or not d.index then return end
    local rxp = Rxp()
    if rxp and type(rxp.SetStep) == "function" then
        local ok, err = pcall(rxp.SetStep, d.index)
        if not ok then geterrorhandler()(err) end
    end
end

local RefreshList -- the mouse wheel moves the visible part of the list (S.listShift) and redraws it

local function OnWheel(_, delta)
    S.listShift = S.listShift + (delta > 0 and -1 or 1)
    RefreshList()
end

local function EnsureList(f)
    local d = Data(f)
    if d.list then return d.list end
    local list = CreateFrame("Frame", nil, f)
    list:SetPoint("TOPLEFT", f.GuideName, "BOTTOMLEFT", 0, -1)
    list:SetPoint("TOPRIGHT", f.GuideName, "BOTTOMRIGHT", 0, -1)
    list:SetHeight(1)
    list:SetFrameLevel(f.GuideName:GetFrameLevel())
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", OnWheel)
    list.rows = {}
    d.list = list
    return list
end

local function MakeRow(list, i)
    local row = CreateFrame("Frame", nil, list)
    row:SetHeight(ROW_PAD + LINE_H)
    row:EnableMouse(true)
    row:EnableMouseWheel(true)
    local d = Data(row)
    d.hl = row:CreateTexture(nil, "BACKGROUND")
    d.hl:SetAllPoints(row)
    d.hl:Hide()
    d.sep = row:CreateTexture(nil, "ARTWORK")
    d.sep:SetHeight(1)
    d.sep:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    d.sep:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    d.lines = {}
    row.number = row:CreateFontString(nil, "OVERLAY")
    row.number:SetFont(STANDARD_TEXT_FONT, SIZE_ROW_NUMBER, "")
    row.number:SetPoint("TOPRIGHT", row, "TOPRIGHT", -12, -5)
    row.number:SetJustifyH("RIGHT")
    row.lines = {}
    row:SetScript("OnEnter", function(self) Data(self).hl:Show() end)
    row:SetScript("OnLeave", function(self) Data(self).hl:Hide() end)
    row:SetScript("OnMouseUp", JumpTo)
    row:SetScript("OnMouseWheel", OnWheel)
    list.rows[i] = row
    return row
end

-- One text line of a row: a single line each, cut off at the right with "..." when it is too long.
local function MakeLine(row, k)
    local line = row:CreateFontString(nil, "OVERLAY")
    line:SetFont(STANDARD_TEXT_FONT, SIZE_ROW, "")
    line:SetPoint("TOPLEFT", row, "TOPLEFT", 12, -5 - (k - 1) * LINE_H)
    line:SetPoint("TOPRIGHT", row, "TOPRIGHT", -44, -5 - (k - 1) * LINE_H)
    line:SetHeight(LINE_H)
    line:SetJustifyH("LEFT")
    line:SetJustifyV("MIDDLE")
    line:SetWordWrap(false)
    row.lines[k] = line
    return line
end

-- A step RXP lists: not hidden, optional, a tip, empty or above the player's level.
local function Listable(step, level)
    return type(step) == "table" and type(step.text) == "string" and step.text ~= ""
        and not (step.hidewindow or step.hidetip or step.optional or step.tip) and (tonumber(step.level) or 0) <= level
end

-- Rows: the first one is the next step after the current one; the mouse wheel moves the window over the whole guide,
-- backwards into the steps already done as well (S.listShift counts listed steps, negative = earlier). A new current
-- step puts the list back to the next step.
local function SkinList(f, c)
    local list = EnsureList(f)
    local rxp = Rxp()
    local guide = rxp and rxp.currentGuide
    local progress = Progress()
    local level = UnitLevel("player")
    if type(level) ~= "number" then level = 0 end
    local skips = _G.RXPCData
    skips = type(skips) == "table" and type(skips.stepSkip) == "table" and skips.stepSkip or {}
    local shown, total, previous = 0, 0, nil
    local steps = type(guide) == "table" and type(guide.steps) == "table" and guide.steps
    if c.upcoming > 0 and progress and steps and not guide.hidewindow then
        if S.listProgress ~= progress then
            S.listProgress = progress
            S.listShift = 0
        end
        local first = progress + 1
        while first <= #steps and not Listable(steps[first], level) do first = first + 1 end
        local start, moved = first, 0
        if S.listShift < 0 then
            local j = first - 1
            while moved < -S.listShift and j >= 1 do
                if Listable(steps[j], level) then start, moved = j, moved + 1 end
                j = j - 1
            end
            S.listShift = -moved
        elseif S.listShift > 0 then
            local j = first + 1
            while moved < S.listShift and j <= #steps do
                if Listable(steps[j], level) then start, moved = j, moved + 1 end
                j = j + 1
            end
            S.listShift = moved
        end
        local i = start
        while shown < c.upcoming and i <= #steps do
            local step = steps[i]
            if Listable(step, level) then
                shown = shown + 1
                local row = list.rows[shown] or MakeRow(list, shown)
                local d = Data(row)
                d.index = i
                local lines = Lines(step.text)
                local height = ROW_PAD + math.max(1, #lines) * LINE_H
                row:ClearAllPoints()
                if previous then
                    row:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, 0)
                    row:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT", 0, 0)
                else
                    row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
                    row:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, 0)
                end
                row:SetHeight(height)
                total = total + height
                for k = 1, MAX_LINES do
                    local text = row.lines[k] or (lines[k] and MakeLine(row, k))
                    if text then
                        if lines[k] then
                            SetFontFor(text, c.path, c.sRow, c.flags)
                            text:SetTextColor(1, 1, 1, ROW_TEXT_A)
                            if d.lines[k] ~= lines[k] then
                                d.lines[k] = lines[k]
                                text:SetText(lines[k])
                            end
                            text:Show()
                        else
                            d.lines[k] = nil
                            text:Hide()
                        end
                    end
                end
                SetFontFor(row.number, c.path, SIZE_ROW_NUMBER, c.flags)
                row.number:SetTextColor(1, 1, 1, ROW_NUMBER_A)
                local number = c.stepNumbers and tostring(i) or ""
                if d.number ~= number then
                    d.number = number
                    row.number:SetText(number)
                end
                d.sep:SetColorTexture(1, 1, 1, ROW_SEPARATOR_A)
                d.hl:SetColorTexture(1, 1, 1, ROW_HOVER_A)
                -- steps already done or passed are dimmed, like RXP's list does
                local past = i <= progress or step.completed or skips[i]
                row:SetAlpha(past and 0.55 or 1)
                row:Show()
                previous = row
            end
            i = i + 1
        end
    end
    for k = shown + 1, #list.rows do list.rows[k]:Hide() end
    list:SetHeight(math.max(1, total))
    S.listHeight = total
    list:SetShown(shown > 0)
    S.listRows = shown
end

-- RXP's scrolling list stays hidden and click-through (its rows are mouse-enabled again after every guide load).
local function SetRxpList(f, hidden, full)
    local scroll = f.ScrollFrame
    if not scroll then return end
    local d = Data(scroll)
    local bar = scroll.ScrollBar
    local rows = f.ScrollChild and f.ScrollChild.framePool
    if hidden then
        scroll:SetAlpha(0)
        if d.wheelWas == nil and scroll.IsMouseWheelEnabled then d.wheelWas = scroll:IsMouseWheelEnabled() and true or false end
        if scroll.EnableMouseWheel then scroll:EnableMouseWheel(false) end
        if not full then return end
        MouseOff(scroll, "listWas")
        MouseOff(bar, "listWas")
        MouseOff(bar and bar.ScrollUpButton, "listWas")
        MouseOff(bar and bar.ScrollDownButton, "listWas")
        MouseOff(f.ScrollChild, "listWas")
        if type(rows) == "table" then
            for i = 1, #rows do
                MouseOff(rows[i], "listWas")
                MouseOff(rows[i].number, "listWas")
            end
        end
    else
        scroll:SetAlpha(1)
        if d.wheelWas ~= nil then
            if scroll.EnableMouseWheel then scroll:EnableMouseWheel(d.wheelWas) end
            d.wheelWas = nil
        end
        MouseOn(scroll, "listWas")
        MouseOn(bar, "listWas")
        MouseOn(bar and bar.ScrollUpButton, "listWas")
        MouseOn(bar and bar.ScrollDownButton, "listWas")
        MouseOn(f.ScrollChild, "listWas")
        if type(rows) == "table" then
            for i = 1, #rows do
                MouseOn(rows[i], "listWas")
                MouseOn(rows[i].number, "listWas")
            end
        end
    end
end

-- RXPFrame may not be moved, sized, clamped or made click-through in combat once it is protected, which it becomes
-- implicitly as soon as a step box with secure buttons is anchored to it (guide.lockBoxes; wiki: anchoring or parenting
-- a protected frame protects the frame it hangs on). Its children are not affected. Every change to RXPFrame
-- itself asks WindowLocked first; a skipped change is redone by one skin run after combat (S.windowDeferred). The
-- mouse of the hide rules asks IsLocked only: UpdateVisibility runs after combat anyway.
local function IsLocked(f)
    return InCombatLockdown() and f.IsProtected and f:IsProtected() and true or false
end

local function WindowLocked(f)
    local locked = IsLocked(f)
    if locked then S.windowDeferred = true end
    return locked
end

-- RXP anchors its window by the centre of its left edge (LEFT, UIParent): every change of height then moves the top
-- and bottom edge by half each, which made the window drift up or down when it was resized. Anchored by a corner it
-- grows from the other side only: guide.growth "UP" (default) keeps the bottom-left corner and grows upwards, "DOWN"
-- keeps the top-left corner and grows downwards. RXP saves any anchor (SaveFramePositions stores GetPoint).
local function AnchorWindow(f, up)
    if f:GetNumPoints() ~= 1 then return end
    local point = up and "BOTTOMLEFT" or "TOPLEFT"
    if f:GetPoint(1) == point or WindowLocked(f) then return end
    local left, y = f:GetLeft(), up and f:GetBottom() or f:GetTop()
    if not (left and y and ns.CanAccess(left) and ns.CanAccess(y)) then return end
    f:ClearAllPoints()
    f:SetPoint(point, UIParent, "BOTTOMLEFT", left, y)
end

local function SetHeightAnchored(f, height)
    if WindowLocked(f) then return end
    AnchorWindow(f, S.growUp)
    f:SetHeight(height)
end

-- The window is as tall as its rows: a constant for a given `upcoming`, so it does not jump from step to step.
-- Not while the user drags the size grip (RXP runs its OnUpdate then; the mouse-up SetStep brings us back here) and not
-- for guides that collapse the window themselves (`hidewindow`).
local function FitHeight(f, c)
    local rxp = Rxp()
    local guide = rxp and rxp.currentGuide
    if f:GetScript("OnUpdate") or (type(guide) == "table" and guide.hidewindow) then return end
    local target = math.max(MIN_HEIGHT, S.listHeight + LIST_PAD)
    if c.upcoming > 0 and not f.BottomFrame:IsShown() then f.BottomFrame:Show() end
    local height = f:GetHeight()
    if math.abs(height - target) < 0.5 then return end
    S.heightBefore = S.heightBefore or height
    SetHeightAnchored(f, target)
end

-- RXP rebuilds step.text after our run (LoadGuide: SetStep, then UpdateFrame) and the mouse wheel moves the list: redraw
-- the rows and fit the window to them, cheaply. Not while the size grip is dragged: UpdateFrame is RXP's OnUpdate then
--, the rows follow the width through their anchors and the mouse-up SetStep redraws.
function RefreshList()
    local f = GetFrames()
    if f and cur and S.skinned and not f:GetScript("OnUpdate") then
        pcall(SkinList, f, cur)
        pcall(FitHeight, f, cur)
    end
end

-- Give RXP its list and its window height back (guide skin off).
local function ReleaseList(f)
    local d = data[f]
    if d and d.list then d.list:Hide() end
    SetRxpList(f, false, true)
    local height = S.heightBefore
    S.heightBefore = nil
    if height then
        local profile = ns.RxpProfile()
        local own = profile and profile.frameHeight
        if type(own) == "number" and own >= 50 then height = own end -- RXP's saved height wins over a fitted one
        SetHeightAnchored(f, height)
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Step boxes: RXPItemFrame and RXPTargetFrame. Their buttons are secure, so everything here goes through
-- ns.Queue (immediately outside combat, else after it). RXP keeps its own 25 px grid; we only restyle (S.SquareIcon
-- look) and, with guide.lockBoxes, anchor them under the window.

local function BoxFrames()
    local item, target = _G.RXPItemFrame, _G.RXPTargetFrame
    if type(item) ~= "table" or not item.CreateTexture then item = nil end
    if type(target) ~= "table" or not target.CreateTexture then target = nil end
    return item, target
end

local function BoxButtons(frame)
    local list = {}
    for _, key in ipairs({ "buttonList", "friendlyTargetButtons", "enemyTargetButtons" }) do
        local buttons = frame[key]
        if type(buttons) == "table" then
            for i = 1, #buttons do list[#list + 1] = buttons[i] end
        end
    end
    return list
end

local function SkinBoxButton(btn)
    local d = Data(btn)
    local icon = btn.icon
    if icon and icon.SetTexCoord then pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92) end -- S.SquareIcon's crop
    if not d.ringOuter then
        d.ringOuter = Ring(btn, 0, 1)
        d.ringInner = Ring(btn, 1, 2)
    end
    PaintRing(d.ringOuter, 0, 0, 0, 1)
    PaintRing(d.ringInner, 1, 1, 1, 0.10)
    d.boxed = true
end

local function ReleaseBoxButton(btn)
    local d = data[btn]
    if not (d and d.boxed) then return end
    d.boxed = false
    local icon = btn.icon
    if icon and icon.SetTexCoord then pcall(icon.SetTexCoord, icon, 0, 1, 0, 1) end
    PaintRing(d.ringOuter)
    PaintRing(d.ringInner)
end

-- The window colour behind the frame and its small title, unless the user hid RXP's background for that frame.
local function SkinBoxFrame(frame, c, hideBackground)
    Mute(frame)
    local title = frame.title
    if title then Mute(title) end
    local panel, tab = Box(frame), title and Box(title)
    if hideBackground then
        PaintBox(panel)
        if tab then PaintBox(tab) end
    else
        PaintBox(panel, c.bgR, c.bgG, c.bgB, c.alpha, c.border and 1 or nil, 1, 1, 0.08)
        if tab then PaintBox(tab, c.bgR, c.bgG, c.bgB, c.alpha, c.border and 1 or nil, 1, 1, 0.08) end
    end
    local buttons = BoxButtons(frame)
    for i = 1, #buttons do SkinBoxButton(buttons[i]) end
end

local function SamePoint(frame, point, relative, relativePoint, x, y)
    local p, r, rp, px, py = frame:GetPoint(1)
    return frame:GetNumPoints() == 1 and p == point and r == relative and rp == relativePoint
        and math.abs((px or 0) - x) < 0.01 and math.abs((py or 0) - y) < 0.01
end

-- Where the boxes sit on the window (guide.boxEdge / guide.boxAlong): on one of its four edges, `along` pixels
-- (window units) from the start of that edge. The start is the left end of the top/bottom edge and the fixed corner of
-- the left/right edge (bottom with guide.growth UP, top with DOWN), so a growing window does not move the boxes.
-- "AUTO" picks the bottom edge unless there is no room under the window, then the top edge.
local EDGE_ROOM = 100 -- screen pixels the boxes need under the window (stack of two boxes, their gap and title)

local function BoxEdge(f, c)
    local edge = c.boxEdge
    if edge == "TOP" or edge == "BOTTOM" or edge == "LEFT" or edge == "RIGHT" then return edge end
    local bottom = f:GetBottom()
    if bottom and ns.CanAccess(bottom) and bottom * f:GetEffectiveScale() < EDGE_ROOM then return "TOP" end
    return "BOTTOM"
end

-- anchor of `frame` on the window edge: frame corner, window corner, x, y (in the frame's own units)
local function EdgeAnchor(frame, f, c, edge, along)
    local a = along * f:GetEffectiveScale() / frame:GetEffectiveScale()
    if edge == "BOTTOM" then return "TOPLEFT", "BOTTOMLEFT", a, -BOX_GAP end
    if edge == "TOP" then return "BOTTOMLEFT", "TOPLEFT", a, BOX_GAP end
    if edge == "RIGHT" then
        if c.growUp then return "BOTTOMLEFT", "BOTTOMRIGHT", BOX_GAP, a end
        return "TOPLEFT", "TOPRIGHT", BOX_GAP, -a
    end
    if c.growUp then return "BOTTOMRIGHT", "BOTTOMLEFT", -BOX_GAP, a end
    return "TOPRIGHT", "TOPLEFT", -BOX_GAP, -a
end

-- the second box sits right behind the first one, away from the window
local function StackAnchor(edge)
    if edge == "BOTTOM" then return "TOPLEFT", "BOTTOMLEFT", 0, -BOX_GAP end
    if edge == "TOP" then return "BOTTOMLEFT", "TOPLEFT", 0, BOX_GAP end
    if edge == "RIGHT" then return "TOPLEFT", "TOPRIGHT", BOX_GAP, 0 end
    return "TOPRIGHT", "TOPLEFT", -BOX_GAP, 0
end

local function ClampAlong(f, frame, edge, along)
    local horizontal = edge == "TOP" or edge == "BOTTOM"
    local win = horizontal and f:GetWidth() or f:GetHeight()
    local box = (horizontal and frame:GetWidth() or frame:GetHeight()) * frame:GetEffectiveScale() / f:GetEffectiveScale()
    return math.max(0, math.min(along, math.max(0, win - box)))
end

local function PlaceBox(frame, relative, stacked)
    if not relative or relative == frame then return end
    if S.boxPoints[frame] == nil then -- remember the free position once, so it can be given back (never our own anchor)
        local _, rel = frame:GetPoint(1)
        if frame:GetNumPoints() > 0 and rel ~= _G.RXPFrame and rel ~= _G.RXPItemFrame then
            local points = {}
            for i = 1, frame:GetNumPoints() do points[i] = { frame:GetPoint(i) } end
            S.boxPoints[frame] = points
        else
            S.boxPoints[frame] = false
        end
    end
    if S.boxDragging then return end -- the user is moving a box: it is put on the edge when the mouse is released
    local f, c = _G.RXPFrame, cur
    if not (f and c) then return end
    local edge = BoxEdge(f, c)
    local point, rpoint, x, y
    if stacked then
        point, rpoint, x, y = StackAnchor(edge)
    else
        point, rpoint, x, y = EdgeAnchor(frame, f, c, edge, ClampAlong(f, frame, edge, tonumber(c.boxAlong) or 0))
    end
    if SamePoint(frame, point, relative, rpoint, x, y) then return end
    frame:ClearAllPoints()
    frame:SetPoint(point, relative, rpoint, x, y)
end

-- A box was dropped (RXP moved it freely with StartMoving): snap it to the nearest window edge and remember where
-- along the edge it was left. Only the first box counts; the second one follows it.
-- Nearest window edge for a dragged box and the (clamped) distance along it, in window units. The distance to an
-- edge is measured to the edge segment itself, so a box beside a corner picks the edge it really is closest to.
local function DropSpot(frame)
    local f, c = _G.RXPFrame, cur
    if not (f and c) then return end
    local wl, wr, wb, wt = f:GetLeft(), f:GetRight(), f:GetBottom(), f:GetTop()
    local bl, bb, bt = frame:GetLeft(), frame:GetBottom(), frame:GetTop()
    local cx = frame:GetCenter()
    if not (wl and wr and wb and wt and bl and bb and bt and cx) then return end
    if not (ns.CanAccess(wl) and ns.CanAccess(bl) and ns.CanAccess(cx)) then return end
    local fs, bs = f:GetEffectiveScale(), frame:GetEffectiveScale()
    wl, wr, wb, wt = wl * fs, wr * fs, wb * fs, wt * fs
    local cy = (bb + bt) / 2 * bs
    cx, bl, bb, bt = cx * bs, bl * bs, bb * bs, bt * bs
    local function gap(lo, hi, v) return math.max(lo - v, 0, v - hi) end
    local function dist(dx, dy) return math.sqrt(dx * dx + dy * dy) end
    local best, distance = "BOTTOM", dist(gap(wl, wr, cx), cy - wb)
    local others = {
        { "TOP", dist(gap(wl, wr, cx), cy - wt) },
        { "LEFT", dist(cx - wl, gap(wb, wt, cy)) },
        { "RIGHT", dist(cx - wr, gap(wb, wt, cy)) },
    }
    for _, o in ipairs(others) do
        if o[2] < distance then best, distance = o[1], o[2] end
    end
    local along
    if best == "TOP" or best == "BOTTOM" then
        along = bl - wl
    elseif c.growUp then
        along = bb - wb
    else
        along = wt - bt
    end
    return best, ClampAlong(f, frame, best, along / fs)
end

local function DropBox(frame)
    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then return end
    local f, c = _G.RXPFrame, cur
    local g = ns.db and ns.db.guide
    if not (f and c and g and c.lockBoxes and frame:IsShown()) then return end
    local item = BoxFrames()
    if frame ~= item and item and item:IsShown() then return end -- behind the first box: it snaps back
    local best, along = DropSpot(frame)
    if not best then return end
    g.boxEdge = best
    g.boxAlong = math.floor(along + 0.5)
    c.boxEdge, c.boxAlong = g.boxEdge, g.boxAlong
end

-- While a box is dragged: an accent line on the window edge shows where it will dock (a faint line for the whole edge,
-- a bright one for the stretch the box will cover). Parented to the window, so scale and hiding follow it.
local function EdgeLines()
    local f = _G.RXPFrame
    if not f then return end
    if not S.edgeHost then
        S.edgeHost = CreateFrame("Frame", nil, f)
        S.edgeHost:SetFrameStrata("TOOLTIP")
        S.edgeHost:SetAllPoints(f)
        S.edgeFull = S.edgeHost:CreateTexture(nil, "OVERLAY", nil, 6)
        S.edgeSpan = S.edgeHost:CreateTexture(nil, "OVERLAY", nil, 7)
        S.edgeHost:Hide()
    end
    return S.edgeFull, S.edgeSpan
end

local function PlaceLine(tex, edge, along, len, thick, growUp, f)
    local off = BOX_GAP / 2
    tex:ClearAllPoints()
    if edge == "BOTTOM" then
        tex:SetPoint("TOPLEFT", f, "BOTTOMLEFT", along, -off + thick / 2)
        tex:SetSize(len, thick)
    elseif edge == "TOP" then
        tex:SetPoint("BOTTOMLEFT", f, "TOPLEFT", along, off - thick / 2)
        tex:SetSize(len, thick)
    elseif edge == "RIGHT" then
        if growUp then
            tex:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", off - thick / 2, along)
        else
            tex:SetPoint("TOPLEFT", f, "TOPRIGHT", off - thick / 2, -along)
        end
        tex:SetSize(thick, len)
    else
        if growUp then
            tex:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", -off + thick / 2, along)
        else
            tex:SetPoint("TOPRIGHT", f, "TOPLEFT", -off + thick / 2, -along)
        end
        tex:SetSize(thick, len)
    end
end

local function UpdateEdgeLine(frame)
    local f, c = _G.RXPFrame, cur
    local edge, along = DropSpot(frame)
    local full, span = EdgeLines()
    if not (f and c and edge and full and span) then return end
    local horizontal = edge == "TOP" or edge == "BOTTOM"
    local ratio = frame:GetEffectiveScale() / f:GetEffectiveScale()
    local len = (horizontal and frame:GetWidth() or frame:GetHeight()) * ratio
    local winLen = horizontal and f:GetWidth() or f:GetHeight()
    full:SetColorTexture(c.ar, c.ag, c.ab, 0.35)
    span:SetColorTexture(c.ar, c.ag, c.ab, 1)
    PlaceLine(full, edge, 0, winLen, 1, c.growUp, f)
    PlaceLine(span, edge, along, len, 3, c.growUp, f)
    S.edgeHost:Show()
end

local function BoxDragStart(frame)
    S.boxDragging = frame
    if not S.edgeDriver then S.edgeDriver = CreateFrame("Frame") end
    S.edgeDriver:SetScript("OnUpdate", function()
        local dragged = S.boxDragging
        if dragged and cur and cur.lockBoxes then pcall(UpdateEdgeLine, dragged) end
    end)
end

local function BoxDragStop()
    S.boxDragging = false
    if S.edgeDriver then S.edgeDriver:SetScript("OnUpdate", nil) end
    if S.edgeHost then S.edgeHost:Hide() end
end

local function FreeBox(frame)
    local points = S.boxPoints[frame]
    if points == nil then return end
    S.boxPoints[frame] = nil
    frame:ClearAllPoints()
    if points then
        for i = 1, #points do frame:SetPoint(unpack(points[i])) end
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0) -- RXP's own default (ResetItemPosition)
    end
end

local function ApplyBoxes()
    S.boxQueued = false
    local f, c = GetFrames(), cur
    if not (f and c and S.skinned) then return end
    local item, target = BoxFrames()
    local profile = ns.RxpProfile() or {}
    S.boxes = 0
    if item and not item.v2 then
        SkinBoxFrame(item, c, profile.activeItemHideBG)
        S.boxes = S.boxes + 1
    end
    if target and not target.v2 then
        SkinBoxFrame(target, c, profile.hideActiveTargetsBackground)
        S.boxes = S.boxes + 1
    end
    if c.lockBoxes then
        if item and not item.v2 then PlaceBox(item, f) end
        if target and not target.v2 then
            local behind = item and not item.v2 and item:IsShown()
            PlaceBox(target, behind and item or f, behind)
        end
    else
        if item then FreeBox(item) end
        if target then FreeBox(target) end
    end
end

local function BoxRequest()
    if S.boxQueued or not S.skinned then return end
    S.boxQueued = true
    ns.Queue(function()
        local ok, err = pcall(ApplyBoxes)
        if not ok then
            S.boxQueued = false
            if not S.reported then
                S.reported = true
                geterrorhandler()(err)
            end
        end
    end)
end

local function ReleaseBoxes()
    ns.Queue(function()
        local item, target = BoxFrames()
        for _, frame in ipairs({ item or false, target or false }) do
            if frame then
                local d = data[frame]
                if d and d.box then PaintBox(d.box) end
                local title = frame.title
                local td = title and data[title]
                if td and td.box then PaintBox(td.box) end
                local buttons = BoxButtons(frame)
                for i = 1, #buttons do ReleaseBoxButton(buttons[i]) end
                FreeBox(frame)
                if type(frame.UpdateVisuals) == "function" then pcall(frame.UpdateVisuals, frame) end -- RXP repaints
            end
        end
    end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Hide rules: hidden = alpha 0 plus mouse off on every frame of the window, never RXPFrame:Hide().
-- RXP never sets RXPFrame's alpha itself. The step boxes stay: they hold the buttons the player needs in combat.

local function WantHidden()
    local g = ns.db and ns.db.guide
    if not g then return false end
    if g.hideCombat then
        local fighting = InCombatLockdown()
        if not fighting then
            local ok, engaged = pcall(UnitAffectingCombat, "player")
            fighting = ok and ns.CanAccess(engaged) and engaged and true or false
        end
        if fighting then return true end
    end
    if g.hideInstance and ns.InInstance() then return true end
    return false
end

-- `fn` copes with nil (a table with holes cannot be walked with ipairs).
local function EachWindowFrame(f, fn)
    if not IsLocked(f) then fn(f) end -- only RXPFrame itself can be locked (WindowLocked)
    local foot = f.Footer
    fn(f.GuideName)
    fn(foot)
    fn(foot and foot.icon)
    fn(foot and foot.cog)
    fn(f.BottomFrame)
    fn(f.CurrentStepFrame)
    local header = Data(f).header
    if header then
        fn(header.prev)
        fn(header.next)
        fn(header.menu)
    end
    local steps = f.CurrentStepFrame.framePool
    if type(steps) == "table" then
        for i = 1, #steps do
            local sf = steps[i]
            fn(sf)
            fn(sf.number)
            for e = 1, #(sf.elements or {}) do
                local ef = sf.elements[e]
                fn(ef)
                if ef then fn(ef.button) end
            end
        end
    end
    local list = Data(f).list -- RXP's own scrolling list is click-through for good (SetRxpList)
    if list then
        for i = 1, #list.rows do fn(list.rows[i]) end
    end
end

local function HideMouse(frame) MouseOff(frame, "mouseWas") end
local function ShowMouse(frame) MouseOn(frame, "mouseWas") end

local function UpdateVisibility()
    local f = GetFrames()
    if not f or IsV2() then return end
    if WantHidden() then
        if not S.hidden then
            S.hidden = true
            S.alphaWas = f:GetAlpha()
        end
        f:SetAlpha(0)
        EachWindowFrame(f, HideMouse) -- again every time: RXP switches mouse handling back on when it lays out
    elseif S.hidden then
        S.hidden = false
        f:SetAlpha(S.alphaWas or 1)
        S.alphaWas = nil
        EachWindowFrame(f, ShowMouse)
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Guide window v2

-- RXP's beta window v2 hides the classic window. With guide.blockV2 we switch v2 off through RXP's own profile value
-- (RXP offers it in its settings) and ask for one /reload; until then the skin stays off.
local function CheckV2()
    local g = ns.db and ns.db.guide
    if not (g and g.blockV2 and not S.v2Pending and IsV2()) then return end
    local profile = ns.RxpProfile()
    if not profile then return end
    profile.enableV2Interface = false
    S.v2Pending = true
    ns.Say(L["RestedXP's guide window v2 was switched off so EUI RestedXP Skin can style the classic window. Type /reload to apply."])
end

-- ---------------------------------------------------------------------------------------------------------------
-- Apply and restore

local function DoApply(f, g)
    local c = Context(g)
    cur = c
    S.growUp = c.growth ~= "DOWN"
    local locked = WindowLocked(f)
    AnchorWindow(f, S.growUp)
    -- RXP clamps the window to the screen, but its visible panel sits 3 px inside the frame (BottomFrame and the
    -- footer are inset by 3): let the frame go 3 px past the screen edge on both sides (offset convention).
    if f.SetClampRectInsets and not S.clampSet and not locked then
        S.clampSet = true
        f:SetClampRectInsets(WINDOW_INSET, -WINDOW_INSET, 0, 0)
    end

    -- RXP lays the window out from its own measurements; anything that changes a measurement asks it to measure again
    -- before we adjust the result (so the adjustments below always start from a fresh RXP layout).
    local key = table.concat({
        tostring(c.width), c.path, c.flags, tostring(c.stepNumbers), tostring(c.header),
    }, "|")
    local relayout = false
    if S.layoutKey ~= key then
        S.layoutKey = key
        relayout = true
    end
    if S.width ~= c.width and not locked then
        if c.width then
            S.widthBefore = S.widthBefore or f:GetWidth() -- what Restore puts back
            f:SetWidth(c.width)
        elseif S.widthBefore then
            f:SetWidth(S.widthBefore) -- the user went back to "keep RXP's width"
            S.widthBefore = nil
        end
        S.width = c.width
        relayout = true
    end
    if StyleStepFonts(f, c) then relayout = true end
    if relayout then Relayout(f) end

    -- a new main step: let the new step panel flash once (animations "SUBTLE")
    local progress = Progress()
    if c.animate and progress and S.lastProgress and progress ~= S.lastProgress then
        anim.flash = { start = GetTime() }
        StartAnim()
    elseif not c.animate then
        StopAnim()
    end
    S.lastProgress = progress

    SkinWindow(f, c)
    SkinHeader(f, c)
    SkinSteps(f, c)
    SetRxpList(f, true, S.rowsDirty) -- RXP's own list stays hidden; its rows regain the mouse after a guide load
    S.rowsDirty = false
    SkinList(f, c)
    FitHeight(f, c)
    S.skinned = true
    BoxRequest()
    if S.hidden then EachWindowFrame(f, HideMouse) end
end

local function Restore()
    local f = GetFrames()
    S.skinned = false
    S.layoutKey = nil
    S.rowsDirty = true
    S.lastProgress = nil
    StopAnim()
    if S.clampSet and f and f.SetClampRectInsets then
        S.clampSet = false
        f:SetClampRectInsets(0, 0, 0, 0)
    end
    ReleaseBoxes()
    if not f then return end
    local rxp = Rxp()
    local d = Data(f)
    if d.window then d.window:Hide() end
    if d.header then d.header:Hide() end

    local gn, foot = f.GuideName, f.Footer
    gn:SetHeight(RXP_HEADER_H)
    SetAlphaAll(1, gn.bg, gn.icon, gn.classIcon, gn.text, foot.bg, foot.text)
    if foot.cog then foot.cog:Show() end
    if rxp and type(rxp.UpdateGuideFontSize) == "function" then pcall(rxp.UpdateGuideFontSize) end
    if type(f.UpdateVisuals) == "function" then pcall(f.UpdateVisuals, f) end -- RXP repaints its own backdrops

    local pool = f.CurrentStepFrame.framePool
    if type(pool) == "table" then
        local profile = ns.RxpProfile()
        local size = profile and profile.guideFontSize or 9
        local font = rxp and rxp.font
        for i = 1, #pool do
            local sf = pool[i]
            UnskinStepFrame(sf)
            if font and sf.number and sf.number.text then
                Data(sf.number.text).fontSig = nil
                sf.number.text:SetFont(font, size, "")
                local text = sf.number.text:GetText()
                if type(text) == "string" and text ~= "" then sf.number:SetAlpha(1) end
            end
            for e = 1, #(sf.elements or {}) do
                local ef = sf.elements[e]
                if font and ef and ef.text then
                    Data(ef.text).fontSig = nil
                    ef.text:SetFont(font, size + 2, "")
                end
            end
        end
    end
    ReleaseList(f)
    if S.widthBefore then f:SetWidth(S.widthBefore) end -- only when we had set a width: the one from before that
    S.width, S.widthBefore = nil, nil
    Relayout(f)
    if S.hidden then EachWindowFrame(f, HideMouse) end
end

-- Everything the skin's look depends on besides RXP's own redraws; a changed value means the skin has to run again.
local function Signature()
    local g = ns.db and ns.db.guide
    if not g then return "", false end
    local wanted = Wanted()
    local r, gr, b = ns.Accent()
    local path, flags = ns.Font()
    local rxp = Rxp()
    local active = rxp and rxp.activeTheme
    local theme = type(active) == "table" and active.name or "-"
    return table.concat({
        tostring(wanted), ("%.3f,%.3f,%.3f"):format(r, gr, b), path, flags, tostring(theme),
        tostring(g.alpha), tostring(g.tint), tostring(g.border), tostring(g.header), tostring(g.progress),
        tostring(g.stepNumbers), tostring(g.width), tostring(g.layout),
        tostring(g.upcoming), tostring(g.lockBoxes),
        tostring(g.animations), tostring(g.growth), tostring(g.font), tostring(g.sizeTitle), tostring(g.sizeGoal),
        tostring(g.sizeRow), (function()
            local pc = g.progressColor
            return type(pc) == "table" and ("%s,%s,%s"):format(tostring(pc.r), tostring(pc.g), tostring(pc.b)) or "-"
        end)(), (function()
            local cr, cg, cb = ns.CustomBackground()
            return cr and ("%.3f,%.3f,%.3f"):format(cr, cg, cb) or "-"
        end)(),
    }, "|"), wanted
end

local function RunApply()
    local g = ns.db and ns.db.guide
    if not g then return end
    S.applying = true
    S.dirty = false
    local sig, wanted = Signature()
    if S.sig ~= sig then S.rowsDirty = true end -- options of the rows changed
    local ok, err
    if wanted then
        local f = GetFrames()
        if f then ok, err = pcall(DoApply, f, g) else ok = true end
    else
        ok = true
        if S.skinned then -- RXPFrame's size and clamping cannot be given back while locked: wait for combat's end
            local f = GetFrames()
            if not (f and WindowLocked(f)) then ok, err = pcall(Restore) end
        end
    end
    S.applying = false
    S.applies = S.applies + 1
    S.sig = (wanted == S.skinned) and sig or nil -- nil: wanted but not done yet (no RXP window, error): try again
    if not ok and not S.reported then
        S.reported = true -- one report, not one per RXP update
        geterrorhandler()(err)
    end
end

-- Leading edge: apply at once, inside RXP's own call, so its look never shows for a frame. Further requests in the
-- same frame are collapsed into one trailing run, except RXP redraws that undo our work after the
-- first run of the frame: RenderFrame repaints in UpdateVisuals and then lays the steps out again through
-- ReloadGuide -> UpdateText; waiting for the trailing run would show RXP's look for one frame. Those run again
-- at once, at most MAX_RUNS times per frame.
-- kind "frame" (BottomFrame.UpdateFrame, which RXP runs as OnUpdate every frame while the window is resized, 25 000+
-- calls) and "refresh" (EUI or an option asked) do not mean that RXP rewrote our work: they only run when
-- the skin's inputs changed. RXP's own redraws (visuals, text, render, step) always run. A "frame" call additionally
-- puts the hidden upcoming rows back to alpha 0, which a list rebuild resets.
local MAX_RUNS = 3
local REDRAW = { visuals = true, text = true } -- hooks after RXP rewrote backdrops or step layout
local DIRTIES_ROWS = { visuals = true, render = true, step = true } -- the list of rows may have been rebuilt or restyled
local queued, again = false, false
local runTime, runs = nil, 0

-- One trailing timer at a time; it runs the collapsed requests (if any) on the next frame.
local function Schedule()
    if queued then return end
    queued = true
    C_Timer.After(0, function()
        queued = false
        if again then
            again = false
            Request("again")
        end
    end)
end

function Request(kind)
    if S.applying then return end -- our own relayout calls RXP, whose hooks land here again
    if kind == "frame" then RefreshList() end -- RXP rewrites step.text after our run (LoadGuide)
    if kind == "frame" or kind == "refresh" then
        if S.sig ~= nil and not S.dirty and (kind == "frame" or S.sig == Signature()) then
            S.skipped[kind] = S.skipped[kind] + 1
            return
        end
    else
        S.dirty = true
        if DIRTIES_ROWS[kind] then S.rowsDirty = true end
    end
    local now = GetTime() -- the same value for the whole frame
    if runTime ~= now then runTime, runs = now, 0 end
    if runs > 0 and not (REDRAW[kind] and runs < MAX_RUNS) then
        again = true
        Schedule()
        return
    end
    if runs > 0 then S.reruns = S.reruns + 1 end
    runs = runs + 1
    RunApply()
    Schedule()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Hooks: all on RXP's public entry points, never replacing them

local function Hook(target, method, counter)
    if type(target) == "table" and type(target[method]) == "function" then
        hooksecurefunc(target, method, function()
            S.calls[counter] = S.calls[counter] + 1
            Request(counter)
        end)
        S.hookCount = S.hookCount + 1
    end
end

local function InstallHooks()
    if S.hooked then return true end
    local f, rxp = GetFrames(), Rxp()
    if not (f and rxp) then return false end
    Hook(f, "UpdateVisuals", "visuals")
    Hook(f.CurrentStepFrame, "UpdateText", "text")
    Hook(f.BottomFrame, "UpdateFrame", "frame")
    Hook(rxp, "RenderFrame", "render")
    Hook(rxp, "SetStep", "step")
    S.hooked = true
    return true
end

-- The boxes are created by RXP at its own pace: hook each one as soon as it exists (retried on every refresh).
local function HookDrag(frame)
    local d = Data(frame)
    if d.dragHooked then return end
    d.dragHooked = true
    local function Down() BoxDragStart(frame) end
    local function Up()
        BoxDragStop()
        pcall(DropBox, frame)
        BoxRequest()
    end
    for _, widget in ipairs({ frame, frame.title or false }) do
        if widget then
            widget:HookScript("OnMouseDown", Down)
            widget:HookScript("OnMouseUp", Up)
        end
    end
end

local function InstallBoxHooks()
    local rxp = Rxp()
    if not rxp then return end
    local item, target = BoxFrames()
    if item then HookDrag(item) end
    if target then HookDrag(target) end
    if item and not S.boxHooks.item and type(rxp.UpdateItemFrame) == "function" then
        S.boxHooks.item = true
        hooksecurefunc(rxp, "UpdateItemFrame", BoxRequest)
        if type(item.UpdateVisuals) == "function" then hooksecurefunc(item, "UpdateVisuals", BoxRequest) end
    end
    local targeting = rxp.targeting
    if target and not S.boxHooks.target and type(targeting) == "table" and type(targeting.UpdateTargetFrame) == "function" then
        S.boxHooks.target = true
        hooksecurefunc(targeting, "UpdateTargetFrame", BoxRequest)
        if type(target.UpdateVisuals) == "function" then hooksecurefunc(target, "UpdateVisuals", BoxRequest) end
    end
end

-- "Reset window position" (Guide window > General): back to RXP's own default place (GuideWindow.lua:461), held by our
-- corner anchor at once. RXP stores the place itself (SaveFramePositions on logout and /reload).
local function ResetPosition()
    local f = GetFrames()
    if not f then return false end
    local function Reset()
        f:ClearAllPoints()
        f:SetPoint("LEFT", UIParent, "LEFT", 0, 35)
        if S.skinned then AnchorWindow(f, S.growUp) end -- the same place, held by the corner of guide.growth
    end
    if IsLocked(f) then ns.Queue(Reset) else Reset() end -- see WindowLocked
    return true
end

ns.GuideSkin = { state = S, Request = Request, UpdateVisibility = UpdateVisibility, ResetPosition = ResetPosition }

ns.OnLoaded(function()
    -- The width used to default to 320 and was applied on every start. It is now only applied when the user sets it
    -- (0 = keep RXP's width), so a stored 320 from the old default is reset once.
    local g = ns.db.guide
    if not ns.db.widthMigrated then
        ns.db.widthMigrated = true
        if g.width == 320 then g.width = 0 end
    end
    CheckV2()
    InstallHooks()
    InstallBoxHooks()
    UpdateVisibility()
    Request("load")
end)

ns.RegisterRefresh(function()
    CheckV2()
    InstallHooks() -- retry when RXP's window did not exist yet
    InstallBoxHooks()
    UpdateVisibility()
    Request("refresh")
end)

-- Combat and instance changes only need the cheap visibility pass, not a full skin run.
local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event)
    local ok, err = pcall(UpdateVisibility)
    if not ok and not S.reportedVisibility then
        S.reportedVisibility = true
        geterrorhandler()(err)
    end
    if event == "PLAYER_REGEN_ENABLED" and S.windowDeferred then -- redo what WindowLocked held back in combat
        S.windowDeferred = false
        Request("deferred")
    end
end)

-- Indexes of the steps RXP has active ("s" sticky, "t" tip). Several steps are active at once when sticky ones
-- (steps with `completewith`) stay open next to the main step.
local function ActiveList(f)
    local list = f and f.activeSteps
    if type(list) ~= "table" then return "-" end
    local parts = {}
    for i = 1, #list do
        local step = list[i]
        if type(step) == "table" then
            parts[#parts + 1] = tostring(step.index or "?") .. (step.sticky and "s" or "") .. (step.tip and "t" or "")
        end
    end
    return #parts > 0 and table.concat(parts, ",") or "-"
end

-- Options that /euirxp guide set can change (debug path next to the option pages): bool, int or an enum.
local OPTIONS = {
    upcoming = { min = 0, max = 5 },
    stepNumbers = "bool", progress = "bool", header = "bool", lockBoxes = "bool",
    hideCombat = "bool", hideInstance = "bool", blockV2 = "bool",
    animations = { off = "OFF", subtle = "SUBTLE" },
    boxEdge = { auto = "AUTO", bottom = "BOTTOM", top = "TOP", left = "LEFT", right = "RIGHT" },
    growth = { up = "UP", down = "DOWN" }, -- which way the window grows when its list gets taller
    border = { none = "NONE", thin = "THIN" },
    background = "color", -- hex like 161618 or 0f172a; off = back to the accent-tinted colour
}
local BOOLEANS = { ["on"] = true, ["true"] = true, ["1"] = true, ["yes"] = true,
    ["off"] = false, ["false"] = false, ["0"] = false, ["no"] = false }

local function SetOption(text)
    local name, value = text:match("^(%S+)%s+(%S+)")
    local spec
    for key, option in pairs(OPTIONS) do
        if key:lower() == (name or ""):lower() then name, spec = key, option end
    end
    if not spec then
        local names = {}
        for key in pairs(OPTIONS) do names[#names + 1] = key end
        table.sort(names)
        ns.Say("guide set <option> <value>, options: " .. table.concat(names, ", "))
        return
    end
    local new
    if spec == "bool" then
        new = BOOLEANS[value]
    elseif spec == "color" then
        local hex = value:match("^#?(%x%x%x%x%x%x)$")
        if hex then
            new = { r = tonumber(hex:sub(1, 2), 16) / 255, g = tonumber(hex:sub(3, 4), 16) / 255, b = tonumber(hex:sub(5, 6), 16) / 255 }
        elseif value == "off" or value == "default" then
            new = false
        end
    elseif spec.min then
        local number = tonumber(value)
        new = number and math.floor(Clamp(number, spec.min, spec.max, spec.min) + 0.5)
    else
        new = spec[value]
    end
    if new == nil then
        ns.Say(("guide set %s: '%s' is not a valid value"):format(name, value))
        return
    end
    ns.db.guide[name] = new
    ns.Say(("guide %s = %s"):format(name, type(new) == "table" and value or tostring(new)))
    ns.RefreshAll()
end

-- /euirxp guide [on|off|set <option> <value>]: switch the skin or set an option by hand (debug path next to the
-- option pages); no argument prints the state (debug output, English like /euirxp probe and nav).
function ns.GuideCommand(arg)
    local sub, rest = (arg or ""):match("^(%S*)%s*(.-)$")
    if sub == "on" or sub == "off" then
        ns.db.guide.enabled = sub == "on"
        ns.Say(sub == "on" and L["Guide skin on."] or L["Guide skin off."])
        ns.RefreshAll()
        return
    elseif sub == "set" then
        SetOption(rest)
        return
    end
    local f = GetFrames()
    local w = f and Data(f).window
    local off, reason = ns.SkinningOff()
    ns.Say(("guide: enabled %s layout %s v2 %s (pending reload %s) skinning-off %s hooks %d (%s) skinned %s applies %d"):format(
        tostring(ns.db.guide.enabled), tostring(ns.db.guide.layout), tostring(IsV2()), tostring(S.v2Pending),
        off and tostring(reason) or "false", S.hookCount, S.hooked and "installed" or "missing",
        tostring(S.skinned), S.applies))
    ns.Say(("guide: hook calls visuals %d text %d frame %d render %d step %d  skipped (unchanged) frame %d refresh %d  re-runs in frame %d"):format(
        S.calls.visuals, S.calls.text, S.calls.frame, S.calls.render, S.calls.step, S.skipped.frame, S.skipped.refresh,
        S.reruns))
    local rxp = Rxp()
    local progress = Progress()
    local guide = rxp and rxp.currentGuide
    local go = S.go
    ns.Say(("guide: window %s  width %s (set %s, before %s)  progress %s/%d  active %s  theme %s  last go %s"):format(
        w and ("%.0fx%.0f"):format(w:GetWidth(), w:GetHeight()) or "-", f and ("%.0f"):format(f:GetWidth()) or "-",
        tostring(S.width), tostring(S.widthBefore), tostring(progress or "?"),
        type(guide) == "table" and type(guide.steps) == "table" and #guide.steps or 0, ActiveList(f),
        tostring(cur and (cur.ours and "ours" or "other")),
        go and ("%d -> wanted %d -> landed %s, %.0fs ago"):format(go.from, go.want, tostring(go.got), GetTime() - go.time)
            or "-"))
    local item, target = BoxFrames()
    local g = ns.db.guide
    ns.Say(("guide: upcoming %s (list rows %d, shifted %d)  animations %s  window hidden %s (combat %s instance %s)  boxes skinned %d (item %s target %s, hooks %s/%s) lock %s"):format(
        tostring(g.upcoming), S.listRows, S.listShift, tostring(g.animations),
        tostring(S.hidden), tostring(g.hideCombat), tostring(g.hideInstance), S.boxes, item and "yes" or "no",
        target and "yes" or "no", tostring(S.boxHooks.item), tostring(S.boxHooks.target), tostring(g.lockBoxes)))
    -- where RXP's active step frames are (a step that "vanishes": hidden, collapsed, transparent or off-screen?)
    local csf = f and f.CurrentStepFrame
    if csf then
        local pool, parts = csf.framePool, {}
        for i = 1, type(pool) == "table" and #pool or 0 do
            local sf = pool[i]
            parts[#parts + 1] = ("#%d step %s %s h%.0f a%.2f top%.0f"):format(i, sf.step and tostring(sf.step.index) or "-",
                sf:IsShown() and "shown" or "HIDDEN", sf:GetHeight(), sf:GetAlpha(), sf:GetTop() or -1)
        end
        ns.Say(("guide: step frames: container h%.0f top%.0f %s, screen height %.0f, window top %.0f  %s"):format(
            csf:GetHeight(), csf:GetTop() or -1, csf:IsShown() and "shown" or "HIDDEN", GetScreenHeight(),
            f:GetTop() or -1, table.concat(parts, " | ")))
    end
end
