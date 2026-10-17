-- Header of the Arrow options page: live preview of the arrow in the chosen style, three state
-- chips (travelling / transport / arrived) and the route source with its status. The preview uses the arrow's own
-- measures and colours (ns.ArrowDesign), so what you see here is what the arrow looks like in the world.
local addonName, ns = ...
local L = ns.L

local CONTENT_PAD = 45 -- EUI content padding
local HEIGHT = 176
local STAGE_H = 150
local GAP = 2
local SWEEP = 0.6 -- radians per second: the arrow swings slowly so the direction colours can be seen

local STATES = {
    { key = "TRAVEL", label = "Travelling" },
    { key = "TRANSPORT", label = "Transport" },
    { key = "ARRIVED", label = "Arrived" },
}

local state = "TRAVEL" -- the chip last clicked, kept while the options window is open
local current -- the preview that is on screen

local Clamp = ns.Clamp

local SetFontFor = ns.SetFont

local function Label(parent, size)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, size, "") -- a font must be set before any text
    fs:SetJustifyH("LEFT")
    return fs
end

-- ---------------------------------------------------------------------------------------------------------------
-- The arrow itself (centre of the header)

local function BuildStage(header)
    local D = ns.ArrowDesign
    local stage = CreateFrame("Frame", nil, header)
    stage:SetSize(D.WIDTH, STAGE_H)
    stage:SetPoint("CENTER", header, "CENTER", 0, 0)

    local hub = CreateFrame("Frame", nil, stage)
    hub:SetSize(64, 64)
    hub:SetPoint("TOP", stage, "TOP", 0, -4)

    local function Tex(layer, file, sublevel)
        local tex = stage:CreateTexture(nil, layer, nil, sublevel or 0)
        if file then tex:SetTexture(D.MEDIA .. file .. ".tga") end
        tex:SetPoint("CENTER", hub, "CENTER", 0, 0)
        tex:Hide()
        return tex
    end

    local p = { stage = stage, hub = hub }
    p.ringFace = Tex("BACKGROUND", "ring")
    p.ringFace:SetVertexColor(10 / 255, 12 / 255, 12 / 255, 0.55)
    p.ringEdge = Tex("BORDER", "ring_edge")
    p.ringEdge:SetVertexColor(1, 1, 1, 0.25)
    p.ringNorth = Tex("BORDER")
    p.ringNorth:SetColorTexture(1, 1, 1, 0.6)
    p.ringNorth:SetSize(2, 8)
    p.ringNorth:ClearAllPoints()
    p.ringNorth:SetPoint("TOP", hub, "TOP", 0, -3)

    p.pillBg = stage:CreateTexture(nil, "BACKGROUND")
    p.pillBg:SetColorTexture(0x12 / 255, 0x0F / 255, 0x0C / 255, 0.88)
    p.pillBg:Hide()
    p.pillEdges = {}
    for i = 1, 4 do
        local edge = stage:CreateTexture(nil, "BORDER")
        edge:SetColorTexture(1, 1, 1, 0.10)
        edge:Hide()
        p.pillEdges[i] = edge
    end
    p.pillField = stage:CreateTexture(nil, "BORDER", nil, 1)
    p.pillField:Hide()

    p.cOutline = Tex("BACKGROUND", "chevron_outline", 1)
    p.cOutline:SetVertexColor(0, 0, 0, 0.7)
    p.cFill = Tex("ARTWORK", "chevron")
    p.cRelief = Tex("OVERLAY", "chevron_relief")
    p.cRelief:SetVertexColor(0, 0, 0, 0.22)
    p.bOutline = Tex("BACKGROUND", "block_outline", 1)
    p.bOutline:SetVertexColor(0, 0, 0, 0.7)
    p.bFill = Tex("ARTWORK", "block")
    p.symbolBack = Tex("BACKGROUND", nil, 2)
    p.symbolBack:SetVertexColor(0, 0, 0, 0.6)
    p.symbol = Tex("ARTWORK", nil, 1)
    p.chevronParts = { p.cOutline, p.cFill, p.cRelief }
    p.blockParts = { p.bOutline, p.bFill }
    p.symbolParts = { p.symbolBack, p.symbol }

    local function Row()
        local fs = stage:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
        fs:SetWordWrap(false)
        fs:Hide()
        return fs
    end
    p.dist, p.eta, p.name = Row(), Row(), Row()
    p.name:SetTextColor(1, 1, 1, 0.75)
    p.dist:SetTextColor(1, 1, 1, 1)
    return p
end

local function SetShown(list, shown)
    for i = 1, #list do list[i]:SetShown(shown) end
end

-- Style, sizes and texts (everything except the swinging angle).
local function Layout(p)
    local D = ns.ArrowDesign
    local nav = ns.db.nav
    local style = D.STYLE[nav.style] and nav.style or "CHEVRON"
    local spec = D.STYLE[style]
    local pill = style == "PILL"
    local offset = (D.WIDTH - D.PILL_W) / 2
    p.style = style
    p.stage:SetScale(math.min(Clamp(nav.scale, 0.5, 2, 0.70), 1.3))
    p.stage:SetAlpha(Clamp(nav.alpha, 0.2, 1, 1))

    p.hub:ClearAllPoints()
    p.hub:SetSize(spec.hub, spec.hub)
    if pill then
        p.hub:SetPoint("TOPLEFT", p.stage, "TOPLEFT", offset, -4)
    else
        p.hub:SetPoint("TOP", p.stage, "TOP", 0, -4)
    end
    for _, part in ipairs(p.chevronParts) do part:SetSize(spec.glyph, spec.glyph) end
    for _, part in ipairs(p.blockParts) do part:SetSize(spec.glyph, spec.glyph) end
    for _, part in ipairs(p.symbolParts) do part:SetSize(spec.symbol, spec.symbol) end
    p.symbolBack:SetSize(spec.symbol * 1.12, spec.symbol * 1.12)

    local ring = style == "RING"
    p.ringFace:SetShown(ring); p.ringEdge:SetShown(ring); p.ringNorth:SetShown(ring)
    if ring then
        p.ringFace:SetSize(spec.hub, spec.hub)
        p.ringEdge:SetSize(spec.hub, spec.hub)
    end
    p.pillBg:SetShown(pill); p.pillField:SetShown(pill)
    for _, edge in ipairs(p.pillEdges) do edge:SetShown(pill) end
    if pill then
        local e = p.pillEdges
        p.pillBg:ClearAllPoints(); p.pillBg:SetPoint("TOPLEFT", p.hub, "TOPLEFT", 0, 0); p.pillBg:SetSize(D.PILL_W, spec.hub)
        p.pillField:ClearAllPoints(); p.pillField:SetPoint("TOPLEFT", p.pillBg, "TOPLEFT", 0, 0); p.pillField:SetSize(spec.hub, spec.hub)
        e[1]:ClearAllPoints(); e[1]:SetPoint("TOPLEFT", p.pillBg); e[1]:SetPoint("TOPRIGHT", p.pillBg); e[1]:SetHeight(1)
        e[2]:ClearAllPoints(); e[2]:SetPoint("BOTTOMLEFT", p.pillBg); e[2]:SetPoint("BOTTOMRIGHT", p.pillBg); e[2]:SetHeight(1)
        e[3]:ClearAllPoints(); e[3]:SetPoint("TOPLEFT", p.pillBg); e[3]:SetPoint("BOTTOMLEFT", p.pillBg); e[3]:SetWidth(1)
        e[4]:ClearAllPoints(); e[4]:SetPoint("TOPRIGHT", p.pillBg); e[4]:SetPoint("BOTTOMRIGHT", p.pillBg); e[4]:SetWidth(1)
    end

    -- Texts, in the same order and with the same measures as the arrow itself (Arrow.lua Layout).
    local path, flags = ns.Font()
    if flags == "" then flags = "OUTLINE" end
    local r, g, b = ns.Accent()
    p.eta:SetTextColor(r, g, b, 1)
    local rows = {
        { p.dist, pill and D.PILL_ROWS.dist or D.ROWS.dist, nav.showDistance },
        { p.eta, pill and D.PILL_ROWS.eta or D.ROWS.eta, nav.showETA },
    }
    local y = -spec.hub - GAP - 4
    if pill then
        local total = 0
        for _, row in ipairs(rows) do
            if row[3] ~= false then total = total + row[2][2] end
        end
        y = -4 - math.max(0, (spec.hub - total) / 2)
    end
    for _, row in ipairs(rows) do
        local fs, size, wanted = row[1], row[2], row[3]
        fs:ClearAllPoints()
        SetFontFor(fs, path, size[1], flags)
        if wanted ~= false then
            if pill then
                fs:SetWidth(D.PILL_W - spec.hub - 14)
                fs:SetJustifyH("LEFT")
                fs:SetPoint("TOPLEFT", p.stage, "TOPLEFT", offset + spec.hub + 8, y)
            else
                fs:SetWidth(D.WIDTH)
                fs:SetJustifyH("CENTER")
                fs:SetPoint("TOP", p.stage, "TOP", 0, y)
            end
            fs:SetHeight(size[2])
            fs:Show()
            y = y - size[2]
        else
            fs:Hide()
        end
    end
    if pill then y = -spec.hub - GAP - 4 end
    p.name:ClearAllPoints()
    SetFontFor(p.name, path, D.ROWS.name[1], flags)
    if nav.showName ~= false then
        p.name:SetWidth(D.WIDTH)
        p.name:SetJustifyH("CENTER")
        p.name:SetPoint("TOP", p.stage, "TOP", 0, y)
        p.name:SetHeight(D.ROWS.name[2])
        p.name:Show()
    else
        p.name:Hide()
    end

    local unit = nav.unit == "yd" and "yd" or "m"
    if state == "ARRIVED" then
        p.dist:SetText(L["Arrived"]); p.eta:SetText(""); p.name:SetText(L["Sample target"])
    elseif state == "TRANSPORT" then
        p.dist:SetText(L["Boat"]); p.eta:SetText(L["Departure %s"]:format("0:45")); p.name:SetText(L["Sample harbour"])
    else
        p.dist:SetText(("142 %s"):format(unit)); p.eta:SetText("1:05"); p.name:SetText(L["Sample target"])
    end
end

-- Glyph and colour for the current state; `angle` swings in the travelling state.
local function Draw(p, angle)
    local D = ns.ArrowDesign
    local style = p.style
    if state == "TRAVEL" then
        local classic = style == "CLASSIC"
        SetShown(p.symbolParts, false)
        SetShown(p.chevronParts, not classic)
        SetShown(p.blockParts, classic)
        for _, part in ipairs(classic and p.blockParts or p.chevronParts) do part:SetRotation(angle) end
    else
        SetShown(p.chevronParts, false)
        SetShown(p.blockParts, false)
        local file = state == "ARRIVED" and "check" or "transport"
        if p.symbolFile ~= file then
            p.symbolFile = file
            p.symbol:SetTexture(D.MEDIA .. file .. ".tga")
            p.symbolBack:SetTexture(D.MEDIA .. file .. ".tga")
        end
        SetShown(p.symbolParts, true)
    end
    local r, g, b = D.Color(style, state == "TRAVEL" and angle or nil)
    p.cFill:SetVertexColor(r, g, b, 1)
    p.bFill:SetVertexColor(r, g, b, 1)
    p.symbol:SetVertexColor(r, g, b, 1)
    p.pillField:SetColorTexture(r, g, b, 0.15)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Chips (left) and route source (right)

local function BuildChip(header, key, text, anchor)
    local chip = CreateFrame("Button", nil, header)
    chip:SetSize(120, 24)
    chip:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
    chip.bg = chip:CreateTexture(nil, "BACKGROUND")
    chip.bg:SetAllPoints()
    chip.label = Label(chip, 12)
    chip.label:SetPoint("LEFT", chip, "LEFT", 10, 0)
    chip.label:SetText(text)
    chip.key = key
    chip:SetScript("OnClick", function()
        state = key
        if current then current.Update() end
    end)
    return chip
end

local function SourceText()
    local effective, configured = ns.NavSource()
    local version = ns.SPF.Version()
    if effective == "SPF" then
        return true, version and ("ShortestPathForever " .. version) or "ShortestPathForever"
    end
    if configured ~= "RXP" and not ns.SPF.Loaded() then
        return false, L["ShortestPathForever not found - the arrow points in a straight line."]
    end
    return false, L["RestedXP step target (straight line)"]
end

function ns.BuildArrowHeader(header)
    local pad = CONTENT_PAD
    local preview = { frame = header }

    local title = Label(header, 11)
    title:SetPoint("TOPLEFT", header, "TOPLEFT", pad, -18)
    title:SetTextColor(1, 1, 1, 0.41)
    title:SetText(L["PREVIEW"])

    local chips, anchor = {}, title
    for _, s in ipairs(STATES) do
        local chip = BuildChip(header, s.key, L[s.label], anchor)
        chips[#chips + 1] = chip
        anchor = chip
    end

    local sourceTitle = Label(header, 11)
    sourceTitle:SetPoint("TOPRIGHT", header, "TOPRIGHT", -pad, -18)
    sourceTitle:SetWidth(240)
    sourceTitle:SetJustifyH("LEFT")
    sourceTitle:SetTextColor(1, 1, 1, 0.41)
    sourceTitle:SetText(L["ROUTE SOURCE"])

    local dot = header:CreateTexture(nil, "ARTWORK")
    dot:SetSize(8, 8)
    dot:SetPoint("TOPLEFT", sourceTitle, "BOTTOMLEFT", 0, -12)
    local sourceText = Label(header, 12)
    sourceText:SetPoint("TOPLEFT", dot, "TOPRIGHT", 8, 4)
    sourceText:SetWidth(222)
    sourceText:SetJustifyV("TOP")
    sourceText:SetWordWrap(true)
    sourceText:SetTextColor(1, 1, 1, 0.8)

    local stage = BuildStage(header)

    local sweep, t = 0, 0
    local function Render()
        if not ns.db then return end
        local path, flags = ns.Font()
        for _, fs in ipairs({ title, sourceTitle, sourceText }) do
            SetFontFor(fs, path, fs == sourceText and 12 or 11, flags)
        end
        Layout(stage)
        Draw(stage, math.pi * math.sin(sweep))
        local r, g, b = ns.Accent()
        for _, chip in ipairs(chips) do
            SetFontFor(chip.label, path, 12, flags)
            if chip.key == state then
                chip.bg:SetColorTexture(r, g, b, 0.22)
                chip.label:SetTextColor(1, 1, 1, 1)
            else
                chip.bg:SetColorTexture(1, 1, 1, 0.05)
                chip.label:SetTextColor(1, 1, 1, 0.6)
            end
        end
        local active, text = SourceText()
        if active then dot:SetColorTexture(r, g, b, 1) else dot:SetColorTexture(0.5, 0.5, 0.5, 1) end
        sourceText:SetText(text)
    end

    function preview.Update()
        if header:IsVisible() then Render() end
    end

    -- Only while the options window shows this header (the header frame is hidden otherwise).
    stage.stage:SetScript("OnUpdate", function(_, elapsed) -- lint:ignore (preview of the arrow, runs only while the Arrow page is visible)
        t = t + elapsed
        if t < 0.05 then return end
        local dt = t
        t = 0
        if state ~= "TRAVEL" then return end
        sweep = (sweep + SWEEP * dt) % (2 * math.pi)
        local angle = math.pi * math.sin(sweep)
        Draw(stage, angle)
    end)

    current = preview
    Render()
    return HEIGHT
end

ns.RegisterRefresh(function()
    if current then current.Update() end
end)
