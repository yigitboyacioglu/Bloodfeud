local addonName, addonTable = ...
addonTable.UI = {}

local Util = addonTable.Util
local Display = Util.DisplayName

local feedWindow = nil
local statsWindow = nil
local minimapButton = nil
local feedRows = {}
local uiNeedsUpdate = false

-- Addon icon (TGA, in media/). The 64px version is used in the UI; the 256px version is for the addon list (.toc)
local ICON_SMALL = "Interface\\AddOns\\" .. addonName .. "\\media\\icon64" -- follows the folder name
local ICON_INLINE = "|T" .. ICON_SMALL .. ":14:14|t"   -- inline icon in text
local SIZE_GRABBER = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber"

-- =========================================================
-- THEME
-- Flat dark panels, 1px borders and a blood red accent. Everything is drawn with
-- color textures, so it looks the same on every client (retail and Forever).
-- =========================================================
local C = {
    windowBg    = { 0.055, 0.050, 0.050, 0.95 },
    feedBg      = { 0.040, 0.035, 0.035, 0.75 },
    header      = { 0.110, 0.085, 0.085, 1 },
    border      = { 0.280, 0.070, 0.070, 1 },
    accent      = { 0.780, 0.120, 0.120, 1 },
    panel       = { 0.090, 0.080, 0.080, 0.95 },
    panelBorder = { 0.180, 0.150, 0.150, 1 },
    button      = { 0.140, 0.120, 0.120, 1 },
    stripe      = { 1, 1, 1, 0.025 },
    hover       = { 1, 1, 1, 0.07 },
    mine        = { 0.780, 0.120, 0.120, 0.20 },
    alliance    = { 0.200, 0.600, 1.000, 1 },
    horde       = { 1.000, 0.250, 0.250, 1 },
    neutral     = { 1.000, 0.820, 0.000, 1 },
    gold        = { 1.000, 0.820, 0.000, 1 },
}

local HEX_ACCENT   = "|cFFE03C3C"
local HEX_DIM      = "|cFF8C8C8C"
local HEX_GOLD     = "|cFFFFD100"
local HEX_WHITE    = "|cFFFFFFFF"
local HEX_GOOD     = "|cFF4DD94D"
local HEX_BAD      = "|cFFFF4D4D"

local COLOR_FRIENDLY = "|cFF4DFF4D"
local COLOR_HORDE    = "|cFFFF4040"
local COLOR_ALLIANCE = "|cFF3399FF"
local COLOR_NEUTRAL  = "|cFFFFD100"

local MEDAL = { "|cFFFFD100", "|cFFC8C8D0", "|cFFD9874A" } -- rank 1-3: gold, silver, bronze

local TITLE = HEX_ACCENT .. "BLOOD|r" .. HEX_WHITE .. "FEUD|r"

local function FactionHex(faction)
    if faction == "Horde" then return COLOR_HORDE end
    if faction == "Alliance" then return COLOR_ALLIANCE end
    return COLOR_NEUTRAL
end

local function FactionRGB(faction)
    if faction == "Horde" then return C.horde end
    if faction == "Alliance" then return C.alliance end
    return C.neutral
end

-- name: "Name-Realm". Ourselves and party members are green, everyone else by faction.
local function GetNameColor(name, faction)
    if not name then return COLOR_NEUTRAL end
    local shown = Display(name)
    if name == Util.MyFullName() or UnitInParty(shown) or UnitInRaid(shown) then
        return COLOR_FRIENDLY
    end
    return FactionHex(faction)
end

local function RankText(rank)
    if not rank then return HEX_DIM .. "-|r" end
    return (MEDAL[rank] or HEX_WHITE) .. "#" .. rank .. "|r"
end

local function Ratio(kills, deaths)
    kills, deaths = kills or 0, deaths or 0
    if deaths == 0 then return string.format("%.2f", kills) end
    return string.format("%.2f", kills / deaths)
end

-- =========================================================
-- WIDGET HELPERS
-- =========================================================
local function Tex(parent, layer, color, sublevel)
    local t = parent:CreateTexture(nil, layer, nil, sublevel)
    t:SetColorTexture(unpack(color))
    return t
end

-- Background + 1px border
local function Skin(frame, bgColor, borderColor)
    local bg = Tex(frame, "BACKGROUND", bgColor)
    bg:SetAllPoints(frame)
    local edges = {}
    local sides = {
        { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
        { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" },
    }
    for i, s in ipairs(sides) do
        local e = Tex(frame, "BORDER", borderColor or C.border)
        e:SetPoint(s[1], frame, s[1])
        e:SetPoint(s[2], frame, s[2])
        if i <= 2 then e:SetHeight(1) else e:SetWidth(1) end
        edges[i] = e
    end
    frame.skinBg, frame.skinEdges = bg, edges
end

-- Font string with an explicit size (the game font, so it works with every locale)
local function NewText(parent, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if size then
        local font, _, flags = GameFontHighlight:GetFont()
        fs:SetFont(font, size, flags or "")
    end
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- Flat button with an accent bar under it when selected
local function CreateButton(parent, text, width, height)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width, height)

    btn.bg = Tex(btn, "BACKGROUND", C.button)
    btn.bg:SetAllPoints(btn)

    local hl = Tex(btn, "HIGHLIGHT", C.hover)
    hl:SetAllPoints(btn)

    btn.bar = Tex(btn, "ARTWORK", C.accent)
    btn.bar:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
    btn.bar:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
    btn.bar:SetHeight(2)
    btn.bar:Hide()

    btn.txt = NewText(btn, 11, "CENTER")
    btn.txt:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn.txt:SetText(text)
    btn.txt:SetTextColor(0.85, 0.85, 0.85)
    return btn
end

local function SetSelected(btn, selected, color)
    color = color or C.accent
    if selected then
        btn.bg:SetColorTexture(color[1] * 0.35, color[2] * 0.35, color[3] * 0.35, 1)
        btn.bar:SetColorTexture(color[1], color[2], color[3], 1)
        btn.bar:Show()
        btn.txt:SetTextColor(1, 1, 1)
    else
        btn.bg:SetColorTexture(unpack(C.button))
        btn.bar:Hide()
        btn.txt:SetTextColor(0.55, 0.55, 0.55)
    end
end

-- Hooked, so a button's own hover effect keeps working
local function AddTooltip(frame, title, line)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title, 1, 0.82, 0)
        if line then GameTooltip:AddLine(line, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function CreateCloseButton(parent, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(20, 18)
    local txt = NewText(btn, 12, "CENTER")
    txt:SetPoint("CENTER", btn, "CENTER", 0, 0)
    txt:SetText("X")
    txt:SetTextColor(0.6, 0.6, 0.6)
    btn:SetScript("OnEnter", function() txt:SetTextColor(1, 0.3, 0.3) end)
    btn:SetScript("OnLeave", function() txt:SetTextColor(0.6, 0.6, 0.6) end)
    btn:SetScript("OnClick", onClick)
    return btn
end

-- Small padlock drawn from color textures (no game files needed, same on every client).
-- Locked: red, shackle closed. Unlocked: grey, shackle raised.
local LOCK_OPEN_COLOR = { 0.65, 0.65, 0.65, 1 }

local function CreateLockButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(18, 18)
    Tex(btn, "HIGHLIGHT", C.hover):SetAllPoints(btn)

    local icon = CreateFrame("Frame", nil, btn)
    icon:SetSize(10, 13)
    icon:SetPoint("CENTER", btn, "CENTER", 0, -1)

    local body = Tex(icon, "ARTWORK", C.accent)
    body:SetSize(10, 7)
    body:SetPoint("BOTTOM", icon, "BOTTOM", 0, 0)
    local keyhole = Tex(icon, "OVERLAY", { 0, 0, 0, 0.6 })
    keyhole:SetSize(2, 3)
    keyhole:SetPoint("CENTER", body, "CENTER", 0, 0)

    local shackle = CreateFrame("Frame", nil, icon)
    shackle:SetSize(8, 6)
    local top = Tex(shackle, "ARTWORK", C.accent)
    top:SetPoint("TOPLEFT", shackle, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", shackle, "TOPRIGHT", 0, 0)
    top:SetHeight(2)
    local left = Tex(shackle, "ARTWORK", C.accent)
    left:SetPoint("TOPLEFT", shackle, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", shackle, "BOTTOMLEFT", 0, 0)
    left:SetWidth(2)
    local right = Tex(shackle, "ARTWORK", C.accent)
    right:SetPoint("TOPRIGHT", shackle, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", shackle, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(2)

    local parts = { body, top, left, right }
    function btn:SetLocked(locked)
        local c = locked and C.accent or LOCK_OPEN_COLOR
        for _, p in ipairs(parts) do p:SetColorTexture(c[1], c[2], c[3], c[4]) end
        shackle:ClearAllPoints()
        shackle:SetPoint("BOTTOM", body, "TOP", 0, locked and 0 or 3)
    end
    btn:SetLocked(false)
    return btn
end

-- Title bar: icon + title, red line under it, drag to move
local function CreateTitleBar(frame, height, title, canMove, onMoved)
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    bar:SetHeight(height)
    bar:EnableMouse(true)

    local bg = Tex(bar, "BACKGROUND", C.header)
    bg:SetAllPoints(bar)
    local line = Tex(bar, "BORDER", C.accent)
    line:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    line:SetHeight(1)

    local icon = bar:CreateTexture(nil, "ARTWORK")
    icon:SetSize(height - 6, height - 6)
    icon:SetPoint("LEFT", bar, "LEFT", 5, 0)
    icon:SetTexture(ICON_SMALL)

    local text = NewText(bar, 12)
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetText(title)
    bar.title = text

    bar:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and canMove() then frame:StartMoving() end
    end)
    bar:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            frame:StopMovingOrSizing()
            onMoved()
        end
    end)
    return bar
end

local function CreateResizeGrip(frame, canResize, onResized)
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel(frame:GetFrameLevel() + 10)
    grip:SetNormalTexture(SIZE_GRABBER .. "-Up")
    grip:SetHighlightTexture(SIZE_GRABBER .. "-Highlight")
    grip:SetPushedTexture(SIZE_GRABBER .. "-Down")
    grip:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and canResize() then frame:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            frame:StopMovingOrSizing()
            onResized()
        end
    end)
    return grip
end

-- Scroll area with a slim scroll bar (draggable + mouse wheel), between top and bottom of parent.
-- Returns the scroll frame, its child and Update(contentHeight) (no argument: keep the last height).
local function CreateScrollArea(parent, top, bottom, wheelStep)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent)
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, top)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -12, bottom)

    local child = CreateFrame("Frame", nil, scrollFrame)
    child:SetSize(400, 20)
    scrollFrame:SetScrollChild(child)

    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, top)
    bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -2, bottom)
    bar:SetWidth(6)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:EnableMouse(true)
    Tex(bar, "BACKGROUND", { 1, 1, 1, 0.05 }):SetAllPoints(bar)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.5, 0.15, 0.15, 1)
    thumb:SetSize(6, 30)
    bar:SetThumbTexture(thumb)
    bar:SetScript("OnEnter", function() thumb:SetColorTexture(unpack(C.accent)) end)
    bar:SetScript("OnLeave", function() thumb:SetColorTexture(0.5, 0.15, 0.15, 1) end)
    bar:SetScript("OnValueChanged", function(self, value) scrollFrame:SetVerticalScroll(value) end)

    local contentHeight = 0
    local function Update(height)
        if height then contentHeight = height end
        child:SetWidth(math.max(1, scrollFrame:GetWidth()))
        child:SetHeight(math.max(1, contentHeight))
        local maxScroll = math.max(0, contentHeight - scrollFrame:GetHeight())
        bar:SetMinMaxValues(0, maxScroll)
        if bar:GetValue() > maxScroll then bar:SetValue(maxScroll) end
        local ratio = (maxScroll > 0) and (scrollFrame:GetHeight() / contentHeight) or 1
        thumb:SetHeight(math.max(20, bar:GetHeight() * ratio))
        bar:SetShown(maxScroll > 0)
    end

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local _, maxScroll = bar:GetMinMaxValues()
        bar:SetValue(math.max(0, math.min(maxScroll, bar:GetValue() - delta * wheelStep)))
    end)
    return scrollFrame, child, Update
end

-- Small square checkbox with a label (the label is clickable too)
local function CreateCheckbox(parent, label, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(14, 14)
    Skin(btn, { 0.10, 0.09, 0.09, 1 }, C.panelBorder)
    local check = Tex(btn, "ARTWORK", C.accent)
    check:SetPoint("TOPLEFT", btn, "TOPLEFT", 3, -3)
    check:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -3, 3)
    Tex(btn, "HIGHLIGHT", C.hover):SetAllPoints(btn)
    local text = NewText(btn, 11)
    text:SetPoint("LEFT", btn, "RIGHT", 6, 0)
    text:SetText(label)
    btn:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0)
    function btn:SetChecked(checked) check:SetShown(checked) end
    btn:SetScript("OnClick", onClick)
    return btn
end

-- Zone titles in tooltips (on unless turned off)
local function ShowTitles()
    return not (BloodfeudDB and BloodfeudDB.showTitles == false)
end

-- =========================================================
-- KILL FEED
-- =========================================================
local FEED_ROW_HEIGHT = 18
local FEED_MAX_ROWS = 20
local FEED_MIN_W, FEED_MIN_H = 170, 60

local function RefreshDisplay()
    if not feedWindow or not addonTable.DB.GetFeed then return end

    local feed = addonTable.DB.GetFeed()
    local visible = feedWindow.visibleRows or 8
    local shown = math.min(visible, #feed)

    for i, row in ipairs(feedRows) do
        local record = (i <= visible) and feed[i]
        if record then
            if record.announcement then
                row.text:SetText(record.announcement)
                row.points:SetText("")
            else
                local kColor = GetNameColor(record.killer, record.killerFaction)
                local vColor = GetNameColor(record.victim, record.victimFaction)
                row.text:SetText(string.format("%s%s|r %skilled|r %s%s|r  %sin %s|r",
                    kColor, Display(record.killer), HEX_DIM, vColor, Display(record.victim),
                    HEX_DIM, record.zone or "Open World"))
                row.points:SetText(string.format("%s+%d|r", HEX_GOLD, record.points or 0))
            end
            -- The newest 3 lines are fully visible, older ones fade a little (down to 70%)
            row:SetAlpha(1 - 0.3 * math.max(0, i - 3) / math.max(1, shown - 3))
            row:Show()
        else
            row:Hide()
        end
    end
    feedWindow.empty:SetShown(#feed == 0)
end

local function LayoutFeed()
    if not feedWindow then return end
    local h = feedWindow.content:GetHeight() or 0
    feedWindow.visibleRows = math.max(1, math.min(FEED_MAX_ROWS, math.floor((h - 4) / FEED_ROW_HEIGHT)))
    RefreshDisplay()
end

local function SaveWindowDimensions()
    if not feedWindow or not BloodfeudDB then return end
    local point, _, relativePoint, xOfs, yOfs = feedWindow:GetPoint()
    BloodfeudDB.windowPos = { point = point or "CENTER", relativePoint = relativePoint or "CENTER", xOfs = xOfs or 0, yOfs = yOfs or 200 }
    BloodfeudDB.windowSize = { width = feedWindow:GetWidth(), height = feedWindow:GetHeight() }
end

-- Locked: the feed can't be moved or resized
local function UpdateLockState()
    if not feedWindow then return end
    local isLocked = BloodfeudDB.isLocked or false
    feedWindow.lockBtn:SetLocked(isLocked)
    feedWindow.resizeGrip:SetShown(not isLocked)
end

local function ToggleFeedWindow()
    if not feedWindow then return end
    feedWindow:SetShown(not feedWindow:IsShown())
end

-- =========================================================
-- STATS & LEADERBOARD WINDOW
-- =========================================================
local activeTab = 1
local leaderboardTimeMode = "alltime"
local leaderboardFilterMode = "ALL"
local LEADERBOARD_ROWS = 100   -- ranking covers all players, the top 100 are shown
local ROW_HEIGHT = 20
local RECENT_ROWS = 10
local STATS_MIN_W, STATS_MIN_H = 480, 340
local COLUMN_WIDTHS = { 60, 48, 40, 52 } -- right side of a leaderboard row: FP, Kills, KB, Deaths

local function FindPlayer(list, name)
    for rank, p in ipairs(list) do
        if p.name == name then return rank, p end
    end
end

local function FormatDuration(secs)
    secs = math.max(0, math.floor(secs or 0))
    local d, h, m = math.floor(secs / 86400), math.floor(secs % 86400 / 3600), math.floor(secs % 3600 / 60)
    if d > 0 then return string.format("%dd %dh", d, h) end
    return string.format("%dh %dm", h, m)
end

local function UpdateMyStats(w, me)
    local DB = addonTable.DB
    local page = w.myPage
    local start = DB.STARTING_FP or 0
    local empty = { fp = start, kills = 0, kb = 0, deaths = 0 }

    local rank, all = FindPlayer(DB.GetLeaderboard(false, "ALL", false), me)
    local weekRank, week = FindPlayer(DB.GetLeaderboard(true, "ALL", false), me)
    all, week = all or empty, week or empty

    local faction = UnitFactionGroup("player")
    local guild = GetGuildInfo("player")
    page.name:SetText(FactionHex(faction) .. (me and Display(me) or UnitName("player") or "") .. "|r")
    page.sub:SetText(HEX_DIM .. (guild and ("<" .. guild .. ">  ") or "") .. (faction or "") .. "|r")
    page.week:SetText(string.format("%sThis week:|r  %s  %s%d FP|r", HEX_DIM, RankText(weekRank), HEX_GOLD, week.fp))

    local titles = me and DB.GetPlayerTitles(me)
    local shown = me and DB.GetShownTitle(me, DB.GetActiveTitle())
    if shown then
        page.title:SetText("|cFFFF8000" .. shown.title .. "|r" ..
            (#titles > 1 and string.format("  %s(%d titles)|r", HEX_DIM, #titles) or ""))
    else
        page.title:SetText(HEX_DIM .. "No zone title - see the Titles tab|r")
    end
    page.switchBtn.titles, page.switchBtn.current = titles, shown and shown.key
    page.switchBtn:SetShown(titles ~= nil and #titles > 1)
    page.rank:SetText(RankText(rank))
    page.fp:SetText(HEX_GOLD .. all.fp .. "|r")

    local tiles = page.tiles
    tiles[1].value:SetText(HEX_GOOD .. all.kills .. "|r")
    tiles[2].value:SetText(HEX_ACCENT .. all.kb .. "|r")
    tiles[3].value:SetText(HEX_WHITE .. all.deaths .. "|r")
    tiles[4].value:SetText(HEX_GOLD .. Ratio(all.kills, all.deaths) .. "|r")
    tiles[1].sub:SetText(string.format("This week: %d", week.kills))
    tiles[2].sub:SetText(string.format("This week: %d", week.kb))
    tiles[3].sub:SetText(string.format("This week: %d", week.deaths))
    tiles[4].sub:SetText("This week: " .. Ratio(week.kills, week.deaths))

    -- Recent killing blows and deaths (from the feed)
    local n = 0
    for _, r in ipairs(DB.GetFeed()) do
        if n >= RECENT_ROWS then break end
        if not r.announcement and (r.killer == me or r.victim == me) then
            n = n + 1
            local line = page.recent[n]
            line.time:SetText(HEX_DIM .. (r.time or ""):sub(1, 5) .. "|r")
            if r.killer == me then
                line.text:SetText(string.format("%sKilled|r %s%s|r  %sin %s|r", HEX_GOOD,
                    FactionHex(r.victimFaction), Display(r.victim), HEX_DIM, r.zone or "Open World"))
                line.points:SetText(string.format("%s+%d|r", HEX_GOLD, r.points or 0))
            else
                line.text:SetText(string.format("%sKilled by|r %s%s|r  %sin %s|r", HEX_BAD,
                    FactionHex(r.killerFaction), Display(r.killer), HEX_DIM, r.zone or "Open World"))
                line.points:SetText(string.format("%s-%d|r", HEX_BAD, DB.DEATH_PENALTY_FP or 0))
            end
            line:Show()
        end
    end
    for i = n + 1, RECENT_ROWS do page.recent[i]:Hide() end
    page.recentEmpty:SetShown(n == 0)
end

local function UpdateLeaderboard(w, me)
    local DB = addonTable.DB
    local page = w.lbPage
    local isWeekly = (leaderboardTimeMode == "weekly")
    local isGuildMode = (leaderboardFilterMode == "GUILDS")

    SetSelected(page.btnAllTime, not isWeekly)
    SetSelected(page.btnWeekly, isWeekly)
    for mode, btn in pairs(page.filters) do SetSelected(btn, leaderboardFilterMode == mode, btn.color) end

    local h = page.header
    h.name:SetText(isGuildMode and "Guild" or "Player")
    h.cols[1]:SetText("FP")
    h.cols[2]:SetText("Kills")
    h.cols[3]:SetText(isGuildMode and "" or "KB")
    h.cols[4]:SetText(isGuildMode and "Members" or "Deaths")

    -- The whole list is sorted by points; only the top 100 are shown
    local leaderboard = DB.GetLeaderboard(isWeekly, leaderboardFilterMode, isGuildMode)
    local myGuild = GetGuildInfo("player")

    if isGuildMode then
        page.footer:SetText(string.format("%s%d guilds|r", HEX_DIM, #leaderboard))
    else
        local myRank, myData = FindPlayer(leaderboard, me)
        page.footer:SetText(string.format("%s%d players|r%s", HEX_DIM, #leaderboard,
            myRank and string.format("   %sYour rank|r %s  %s%d FP|r", HEX_DIM, RankText(myRank), HEX_GOLD, myData.fp) or ""))
    end
    page.reset:SetText(isWeekly and DB.SecondsUntilWeeklyReset
        and (HEX_DIM .. "Resets in " .. FormatDuration(DB.SecondsUntilWeeklyReset()) .. "|r") or "")
    page.empty:SetShown(#leaderboard == 0)

    w.UpdateScrollRange(math.min(#leaderboard, LEADERBOARD_ROWS))

    for i = 1, LEADERBOARD_ROWS do
        local row = w.leaderboardRows[i]
        local p = leaderboard[i]
        if p then
            row.data, row.isGuild = p, isGuildMode
            row.rank:SetText(RankText(i))
            local c = FactionRGB(p.faction)
            row.factionBar:SetColorTexture(c[1], c[2], c[3], 0.9)
            if isGuildMode then
                row.name:SetText(FactionHex(p.faction) .. p.name .. "|r")
                row.cols[3]:SetText("")
                row.cols[4]:SetText(p.members or 0)
                row.mine:SetShown(myGuild ~= nil and p.name == myGuild)
            else
                local guild = p.guild and ("  " .. HEX_DIM .. "<" .. p.guild .. ">|r") or ""
                row.name:SetText(FactionHex(p.faction) .. Display(p.name) .. "|r" .. guild)
                row.cols[3]:SetText(p.kb or 0)
                row.cols[4]:SetText(p.deaths or 0)
                row.mine:SetShown(p.name == me)
            end
            row.cols[1]:SetText(HEX_GOLD .. p.fp .. "|r")
            row.cols[2]:SetText(p.kills or 0)
            row:Show()
        else
            row.data = nil
            row:Hide()
        end
    end
end

local FACTIONS = { "Alliance", "Horde" }

local function UpdateTitles(w, me)
    local DB = addonTable.DB
    local page = w.titlesPage
    local t = DB.GetTitles()
    local minFP = DB.TITLE_MIN_FP or 0

    for i, z in ipairs(DB.GetTitleZones()) do
        local card = page.cards[i]
        local mine = me and t.tally[z.key] and t.tally[z.key][me]
        card.mine:SetText(string.format("%sYour tally this week:|r %s%d FP|r", HEX_DIM, HEX_GOLD, mine and mine.fp or 0))

        for s, fac in ipairs(FACTIONS) do
            local side = card.sides[s]
            side.title:SetText(FactionHex(fac) .. (z[fac] or "") .. "|r")

            local h = t.holders[z.key] and t.holders[z.key][fac]
            if h then
                side.holder:SetText(string.format("%s%s|r%s  %s%d FP|r", HEX_WHITE, Display(h.name),
                    h.name == me and (COLOR_FRIENDLY .. " (you)|r") or "", HEX_GOLD, h.fp))
            else
                side.holder:SetText(HEX_DIM .. "Unclaimed - claim it this week!|r")
            end

            local c = t.contenders[z.key] and t.contenders[z.key][fac]
            if c then
                side.contender:SetText(string.format("%sLeading this week:|r %s %s(%d FP%s)|r", HEX_DIM, Display(c.name),
                    HEX_DIM, c.fp, c.fp < minFP and (", needs " .. minFP) or ""))
            else
                side.contender:SetText(HEX_DIM .. "No contenders this week yet|r")
            end
        end
    end

    page.UpdateScroll()
    page.showTitles:SetChecked(ShowTitles())
    page.reset:SetText(DB.SecondsUntilWeeklyReset
        and (HEX_DIM .. "New holders in " .. FormatDuration(DB.SecondsUntilWeeklyReset()) .. "|r") or "")
end

local function UpdateStatsContent()
    local w = statsWindow
    if not w or not w:IsShown() then return end
    local me = Util.MyFullName()

    SetSelected(w.tab1Btn, activeTab == 1)
    SetSelected(w.tab2Btn, activeTab == 2)
    SetSelected(w.tab3Btn, activeTab == 3)
    w.myPage:SetShown(activeTab == 1)
    w.lbPage:SetShown(activeTab == 2)
    w.titlesPage:SetShown(activeTab == 3)

    if activeTab == 1 then
        UpdateMyStats(w, me)
    elseif activeTab == 2 then
        UpdateLeaderboard(w, me)
    else
        UpdateTitles(w, me)
    end
end

-- Columns are anchored from the right edge, the name takes the remaining width
local function AnchorColumns(parent, cols, rightPad)
    for i = #COLUMN_WIDTHS, 1, -1 do
        local fs = cols[i]
        fs:SetWidth(COLUMN_WIDTHS[i])
        if i == #COLUMN_WIDTHS then
            fs:SetPoint("RIGHT", parent, "RIGHT", -rightPad, 0)
        else
            fs:SetPoint("RIGHT", cols[i + 1], "LEFT", 0, 0)
        end
    end
end

local function ShowRowTooltip(row)
    local p = row.data
    if not p then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if row.isGuild then
        GameTooltip:AddLine(FactionHex(p.faction) .. p.name .. "|r")
        GameTooltip:AddDoubleLine("Members", p.members or 0, 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine("Faction points", p.fp, 0.7, 0.7, 0.7, 1, 0.82, 0)
        GameTooltip:AddDoubleLine("Kills", p.kills or 0, 0.7, 0.7, 0.7, 1, 1, 1)
    else
        GameTooltip:AddLine(FactionHex(p.faction) .. p.name .. "|r")
        if p.guild then GameTooltip:AddLine("<" .. p.guild .. ">", 0.7, 0.7, 0.7) end
        GameTooltip:AddDoubleLine("Faction points", p.fp, 0.7, 0.7, 0.7, 1, 0.82, 0)
        GameTooltip:AddDoubleLine("Kills", p.kills or 0, 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine("Killing blows", p.kb or 0, 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine("Deaths", p.deaths or 0, 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine("K/D", Ratio(p.kills, p.deaths), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    GameTooltip:Show()
end

local function CreateMyStatsPage(w)
    local page = CreateFrame("Frame", nil, w)
    page:SetPoint("TOPLEFT", w, "TOPLEFT", 10, -66)
    page:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", -10, 12)
    page:SetClipsChildren(true)
    w.myPage = page

    -- Header card: name, guild, rank and points
    local card = CreateFrame("Frame", nil, page)
    card:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    card:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
    card:SetHeight(100)
    Skin(card, C.panel, C.panelBorder)
    local stripe = Tex(card, "ARTWORK", C.accent)
    stripe:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
    stripe:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 1, 1)
    stripe:SetWidth(3)

    page.name = NewText(card, 17)
    page.name:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -12)

    -- Zone title (the one shown in tooltips). Holding several: "Switch" cycles through them.
    page.title = NewText(card, 12)
    page.title:SetPoint("TOPLEFT", page.name, "BOTTOMLEFT", 0, -4)
    page.switchBtn = CreateButton(card, "Switch", 54, 16)
    page.switchBtn:SetPoint("LEFT", page.title, "RIGHT", 8, 0)
    page.switchBtn:SetScript("OnClick", function(self)
        local list = self.titles
        if not list or #list < 2 then return end
        local index = 1
        for i, t in ipairs(list) do
            if t.key == self.current then index = i end
        end
        addonTable.DB.SetActiveTitle(list[index % #list + 1].key)
        if addonTable.Sync.OnTitleChanged then addonTable.Sync.OnTitleChanged() end
        UpdateStatsContent()
    end)
    AddTooltip(page.switchBtn, "Switch title", "Choose which of your titles other players see in your tooltip.")

    page.sub = NewText(card, 11)
    page.sub:SetPoint("TOPLEFT", page.title, "BOTTOMLEFT", 0, -4)
    page.week = NewText(card, 11)
    page.week:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 12)

    page.rank = NewText(card, 28, "RIGHT")
    page.rank:SetPoint("TOPRIGHT", card, "TOPRIGHT", -16, -16)
    local rankLabel = NewText(card, 9, "RIGHT")
    rankLabel:SetPoint("TOPRIGHT", page.rank, "BOTTOMRIGHT", 0, -4)
    rankLabel:SetText(HEX_DIM .. "ALL-TIME RANK|r")

    page.fp = NewText(card, 28, "RIGHT")
    page.fp:SetPoint("TOPRIGHT", card, "TOPRIGHT", -120, -16)
    local fpLabel = NewText(card, 9, "RIGHT")
    fpLabel:SetPoint("TOPRIGHT", page.fp, "BOTTOMRIGHT", 0, -4)
    fpLabel:SetText(HEX_DIM .. "FACTION POINTS|r")

    -- Stat tiles
    page.tiles = {}
    for i, label in ipairs({ "KILLS", "KILLING BLOWS", "DEATHS", "K/D RATIO" }) do
        local t = CreateFrame("Frame", nil, page)
        t:SetHeight(70)
        Skin(t, C.panel, C.panelBorder)
        t.label = NewText(t, 9)
        t.label:SetPoint("TOPLEFT", t, "TOPLEFT", 10, -10)
        t.label:SetPoint("TOPRIGHT", t, "TOPRIGHT", -6, -10)
        t.label:SetText(HEX_DIM .. label .. "|r")
        t.value = NewText(t, 22)
        t.value:SetPoint("TOPLEFT", t.label, "BOTTOMLEFT", 0, -5)
        t.sub = NewText(t, 10)
        t.sub:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 10, 9)
        t.sub:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -6, 9)
        t.sub:SetTextColor(0.55, 0.55, 0.55)
        page.tiles[i] = t
    end
    function page.LayoutTiles()
        local gap = 8
        local tw = math.max(1, math.floor(((page:GetWidth() or 0) - gap * (#page.tiles - 1)) / #page.tiles))
        for i, t in ipairs(page.tiles) do
            t:ClearAllPoints()
            t:SetWidth(tw)
            t:SetPoint("TOPLEFT", card, "BOTTOMLEFT", (i - 1) * (tw + gap), -8)
        end
    end
    page.LayoutTiles()

    -- Recent fights
    local recentTitle = NewText(page, 11)
    recentTitle:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 2, -90)
    recentTitle:SetText(HEX_GOLD .. "Recent killing blows & deaths|r")
    local line = Tex(page, "BORDER", C.panelBorder)
    line:SetPoint("TOPLEFT", recentTitle, "BOTTOMLEFT", -2, -4)
    line:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    line:SetHeight(1)

    page.recent = {}
    for i = 1, RECENT_ROWS do
        local r = CreateFrame("Frame", nil, page)
        r:SetHeight(18)
        r:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -2 - (i - 1) * 18)
        r:SetPoint("RIGHT", page, "RIGHT", 0, 0)
        if i % 2 == 0 then Tex(r, "BACKGROUND", C.stripe):SetAllPoints(r) end
        r.time = NewText(r, 10)
        r.time:SetPoint("LEFT", r, "LEFT", 4, 0)
        r.time:SetWidth(38)
        r.points = NewText(r, 11, "RIGHT")
        r.points:SetPoint("RIGHT", r, "RIGHT", -6, 0)
        r.points:SetWidth(40)
        r.text = NewText(r, 11)
        r.text:SetPoint("LEFT", r.time, "RIGHT", 4, 0)
        r.text:SetPoint("RIGHT", r.points, "LEFT", -4, 0)
        page.recent[i] = r
    end
    page.recentEmpty = NewText(page, 11)
    page.recentEmpty:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 4, -8)
    page.recentEmpty:SetText(HEX_DIM .. "No killing blows or deaths yet. The open world awaits.|r")
end

local function CreateLeaderboardPage(w)
    local page = CreateFrame("Frame", nil, w)
    page:SetPoint("TOPLEFT", w, "TOPLEFT", 10, -66)
    page:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", -10, 12)
    w.lbPage = page

    page.btnAllTime = CreateButton(page, "All-Time", 76, 20)
    page.btnAllTime:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    page.btnAllTime:SetScript("OnClick", function() leaderboardTimeMode = "alltime"; UpdateStatsContent() end)

    page.btnWeekly = CreateButton(page, "Weekly", 70, 20)
    page.btnWeekly:SetPoint("LEFT", page.btnAllTime, "RIGHT", 4, 0)
    page.btnWeekly:SetScript("OnClick", function() leaderboardTimeMode = "weekly"; UpdateStatsContent() end)

    -- Filters, right to left
    page.filters = {}
    local prev
    for _, f in ipairs({
        { mode = "GUILDS", text = "Guilds", width = 58, color = C.gold },
        { mode = "Horde", text = "Horde", width = 56, color = C.horde },
        { mode = "Alliance", text = "Alliance", width = 64, color = C.alliance },
        { mode = "ALL", text = "All", width = 40, color = C.accent },
    }) do
        local btn = CreateButton(page, f.text, f.width, 20)
        if prev then
            btn:SetPoint("RIGHT", prev, "LEFT", -4, 0)
        else
            btn:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
        end
        btn.color = f.color
        btn:SetScript("OnClick", function() leaderboardFilterMode = f.mode; UpdateStatsContent() end)
        page.filters[f.mode] = btn
        prev = btn
    end

    -- Column headers
    local header = CreateFrame("Frame", nil, page)
    header:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -28)
    header:SetPoint("TOPRIGHT", page, "TOPRIGHT", -12, -28)
    header:SetHeight(18)
    local hLine = Tex(header, "BORDER", C.panelBorder)
    hLine:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    hLine:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    hLine:SetHeight(1)
    header.rank = NewText(header, 10)
    header.rank:SetPoint("LEFT", header, "LEFT", 8, 0)
    header.rank:SetText("#")
    header.cols = {}
    for i = 1, #COLUMN_WIDTHS do header.cols[i] = NewText(header, 10, "RIGHT") end
    AnchorColumns(header, header.cols, 8)
    header.name = NewText(header, 10)
    header.name:SetPoint("LEFT", header, "LEFT", 46, 0)
    header.name:SetPoint("RIGHT", header.cols[1], "LEFT", -8, 0)
    for _, fs in ipairs({ header.rank, header.name, unpack(header.cols) }) do fs:SetTextColor(0.55, 0.55, 0.55) end
    page.header = header

    -- Footer: total players and our real rank (even if we're not in the top 100)
    page.footer = NewText(page, 11)
    page.footer:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 2, 0)
    page.reset = NewText(page, 11, "RIGHT")
    page.reset:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -16, 0)

    local scrollFrame, scrollChild, UpdateScroll = CreateScrollArea(page, -48, 18, ROW_HEIGHT * 3)

    page.empty = NewText(page, 12, "CENTER")
    page.empty:SetPoint("CENTER", scrollFrame, "CENTER", 0, 0)
    page.empty:SetText(HEX_DIM .. "Nobody here yet.|r")

    -- Update the scroll range when the list length (rows shown) or the window height changes
    function w.UpdateScrollRange(rowCount)
        UpdateScroll(rowCount and math.max(ROW_HEIGHT, rowCount * ROW_HEIGHT))
    end

    w.leaderboardRows = {}
    for i = 1, LEADERBOARD_ROWS do
        local row = CreateFrame("Button", nil, scrollChild)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)
        if i % 2 == 0 then Tex(row, "BACKGROUND", C.stripe):SetAllPoints(row) end
        row.mine = Tex(row, "BACKGROUND", C.mine, 1)
        row.mine:SetAllPoints(row)
        row.mine:Hide()
        Tex(row, "HIGHLIGHT", C.hover):SetAllPoints(row)

        row.factionBar = Tex(row, "ARTWORK", C.neutral)
        row.factionBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
        row.factionBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 2)
        row.factionBar:SetWidth(2)

        row.rank = NewText(row, 11)
        row.rank:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.rank:SetWidth(36)
        row.cols = {}
        for c = 1, #COLUMN_WIDTHS do row.cols[c] = NewText(row, 11, "RIGHT") end
        AnchorColumns(row, row.cols, 8)
        row.name = NewText(row, 11)
        row.name:SetPoint("LEFT", row, "LEFT", 46, 0)
        row.name:SetPoint("RIGHT", row.cols[1], "LEFT", -8, 0)

        row:SetScript("OnEnter", ShowRowTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        w.leaderboardRows[i] = row
    end
end

local TITLE_CARD_HEIGHT, TITLE_CARD_GAP = 80, 6

local function CreateTitlesPage(w)
    local page = CreateFrame("Frame", nil, w)
    page:SetPoint("TOPLEFT", w, "TOPLEFT", 10, -66)
    page:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", -10, 12)
    w.titlesPage = page
    local DB = addonTable.DB

    local intro = NewText(page, 11)
    intro:SetPoint("TOPLEFT", page, "TOPLEFT", 2, 0)
    intro:SetPoint("TOPRIGHT", page, "TOPRIGHT", -2, 0)
    intro:SetWordWrap(true)
    intro:SetText(string.format("%sLast week's top scorer per faction holds each title this week. " ..
        "Score: kill points in the zone minus %d per death there (min. %d).|r",
        HEX_DIM, DB.DEATH_PENALTY_FP or 0, DB.TITLE_MIN_FP or 0))

    -- Footer: tooltip option + time until the next holders
    page.showTitles = CreateCheckbox(page, "Show titles in tooltips", function()
        BloodfeudDB.showTitles = not ShowTitles()
        UpdateStatsContent()
    end)
    page.showTitles:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 2, 1)
    page.reset = NewText(page, 11, "RIGHT")
    page.reset:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -16, 2)

    local _, child, UpdateScroll = CreateScrollArea(page, -36, 22, TITLE_CARD_HEIGHT)
    page.UpdateScroll = UpdateScroll

    page.cards = {}
    for i, z in ipairs(DB.GetTitleZones()) do
        local y = -(i - 1) * (TITLE_CARD_HEIGHT + TITLE_CARD_GAP)
        local card = CreateFrame("Frame", nil, child)
        card:SetHeight(TITLE_CARD_HEIGHT)
        card:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
        card:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
        Skin(card, C.panel, C.panelBorder)

        -- The client's own zone name (localized); the fallback name if the map isn't known
        local info = C_Map and C_Map.GetMapInfo and Util.Call(C_Map.GetMapInfo, z.map)
        card.zone = NewText(card, 13)
        card.zone:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)
        card.zone:SetText(HEX_GOLD .. ((type(info) == "table" and info.name) or z.name or "") .. "|r")
        card.mine = NewText(card, 10, "RIGHT")
        card.mine:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -10)

        local line = Tex(card, "BORDER", C.panelBorder)
        line:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -26)
        line:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -26)
        line:SetHeight(1)
        local split = Tex(card, "BORDER", C.panelBorder)
        split:SetPoint("TOP", card, "TOP", 0, -32)
        split:SetPoint("BOTTOM", card, "BOTTOM", 0, 8)
        split:SetWidth(1)

        card.sides = {}
        for s = 1, #FACTIONS do
            local side = {}
            side.title = NewText(card, 12)
            if s == 1 then
                side.title:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -32)
                side.title:SetPoint("TOPRIGHT", card, "TOP", -8, -32)
            else
                side.title:SetPoint("TOPLEFT", card, "TOP", 10, -32)
                side.title:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -32)
            end
            side.holder = NewText(card, 11)
            side.holder:SetPoint("TOPLEFT", side.title, "BOTTOMLEFT", 0, -4)
            side.holder:SetPoint("TOPRIGHT", side.title, "BOTTOMRIGHT", 0, -4)
            side.contender = NewText(card, 10)
            side.contender:SetPoint("TOPLEFT", side.holder, "BOTTOMLEFT", 0, -4)
            side.contender:SetPoint("TOPRIGHT", side.holder, "BOTTOMRIGHT", 0, -4)
            card.sides[s] = side
        end
        page.cards[i] = card
    end
    local count = #page.cards
    UpdateScroll(count * TITLE_CARD_HEIGHT + math.max(0, count - 1) * TITLE_CARD_GAP)
end

local function ToggleStatsWindow()
    if not statsWindow then
        local size = BloodfeudDB.statsSize or {}
        local pos = BloodfeudDB.statsPos or {}

        local w = CreateFrame("Frame", "BloodfeudStatsFrame", UIParent)
        statsWindow = w
        w:SetSize(math.max(STATS_MIN_W, size.width or 540), math.max(STATS_MIN_H, size.height or 400))
        w:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or "CENTER", pos.xOfs or 0, pos.yOfs or 0)
        w:SetMovable(true)
        w:SetResizable(true)
        w:SetResizeBounds(STATS_MIN_W, STATS_MIN_H, 1000, 900)
        w:EnableMouse(true)
        w:SetClampedToScreen(true)
        w:SetFrameStrata("HIGH")
        w:SetToplevel(true)
        Skin(w, C.windowBg)
        table.insert(UISpecialFrames, "BloodfeudStatsFrame") -- Escape closes it

        local function SaveStatsWindow()
            local point, _, relativePoint, xOfs, yOfs = w:GetPoint()
            BloodfeudDB.statsPos = { point = point or "CENTER", relativePoint = relativePoint or "CENTER", xOfs = xOfs or 0, yOfs = yOfs or 0 }
            BloodfeudDB.statsSize = { width = w:GetWidth(), height = w:GetHeight() }
        end

        local titleBar = CreateTitleBar(w, 26, TITLE .. "   " .. HEX_DIM .. "Statistics & Leaderboard|r",
            function() return true end, SaveStatsWindow)
        CreateCloseButton(titleBar, function() w:Hide() end):SetPoint("RIGHT", titleBar, "RIGHT", -4, 0)

        w.tab1Btn = CreateButton(w, "My Stats", 96, 22)
        w.tab1Btn:SetPoint("TOPLEFT", w, "TOPLEFT", 10, -36)
        w.tab1Btn:SetScript("OnClick", function() activeTab = 1; UpdateStatsContent() end)

        w.tab2Btn = CreateButton(w, "Leaderboard", 110, 22)
        w.tab2Btn:SetPoint("LEFT", w.tab1Btn, "RIGHT", 4, 0)
        w.tab2Btn:SetScript("OnClick", function() activeTab = 2; UpdateStatsContent() end)

        w.tab3Btn = CreateButton(w, "Titles", 76, 22)
        w.tab3Btn:SetPoint("LEFT", w.tab2Btn, "RIGHT", 4, 0)
        w.tab3Btn:SetScript("OnClick", function() activeTab = 3; UpdateStatsContent() end)

        CreateMyStatsPage(w)
        CreateLeaderboardPage(w)
        CreateTitlesPage(w)

        CreateResizeGrip(w, function() return true end, function()
            SaveStatsWindow()
            w.UpdateScrollRange()
            w.titlesPage.UpdateScroll()
        end)
        w:SetScript("OnSizeChanged", function()
            w.UpdateScrollRange()
            w.titlesPage.UpdateScroll()
            w.myPage.LayoutTiles()
        end)
        w:Hide()
    end

    if statsWindow:IsShown() then
        statsWindow:Hide()
    else
        statsWindow:Show()
        UpdateStatsContent()
    end
end

addonTable.UI.ToggleStatsWindow = ToggleStatsWindow

-- =========================================================
-- MINIMAP BUTTON
-- =========================================================
local function UpdateMinimapButtonPosition()
    if not minimapButton or not BloodfeudDB then return end
    local angle = math.rad(BloodfeudDB.minimapPos or 45)
    local radius = 103
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    if minimapButton then return end

    minimapButton = CreateFrame("Button", "BloodfeudMinimapButton", Minimap)
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)

    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", minimapButton, "CENTER", 0, 0)
    icon:SetTexture(ICON_SMALL)
    -- Round minimap button: circle mask like other addons
    if icon.SetMask then
        pcall(icon.SetMask, icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask")
    end

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetSize(52, 52)
    border:SetPoint("TOPLEFT", minimapButton, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    minimapButton:EnableMouse(true)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")

    local isDragging = false
    local wasDragged = false

    minimapButton:SetScript("OnDragStart", function() isDragging = true; wasDragged = false end)
    minimapButton:SetScript("OnDragStop", function() isDragging = false end)

    minimapButton:SetScript("OnUpdate", function()
        if isDragging then
            wasDragged = true
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            BloodfeudDB.minimapPos = math.deg(math.atan2(cy - my, cx - mx))
            UpdateMinimapButtonPosition()
        end
    end)

    minimapButton:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            ToggleStatsWindow()
        elseif not wasDragged then
            ToggleFeedWindow()
        end
        wasDragged = false
    end)

    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(ICON_INLINE .. " " .. TITLE)
        GameTooltip:AddLine("Left Click: Toggle Kill Feed", 1, 1, 1)
        GameTooltip:AddLine("Right Click: Statistics & Leaderboard", 1, 1, 1)
        GameTooltip:AddLine("Drag: Move Icon", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdateMinimapButtonPosition()
end

-- =========================================================
-- STARTUP
-- =========================================================
function addonTable.UI.Init()
    if feedWindow then return end

    BloodfeudDB = BloodfeudDB or {}
    BloodfeudDB.windowPos = BloodfeudDB.windowPos or { point = "CENTER", relativePoint = "CENTER", xOfs = 0, yOfs = 200 }
    BloodfeudDB.windowSize = BloodfeudDB.windowSize or { width = 450, height = 175 }
    BloodfeudDB.isLocked = BloodfeudDB.isLocked or false

    local pos = BloodfeudDB.windowPos
    local size = BloodfeudDB.windowSize

    feedWindow = CreateFrame("Frame", "BloodfeudMainFrame", UIParent)
    feedWindow:SetSize(math.max(FEED_MIN_W, size.width or 450), math.max(FEED_MIN_H, size.height or 175))
    feedWindow:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or "CENTER", pos.xOfs or 0, pos.yOfs or 200)
    feedWindow:SetMovable(true)
    feedWindow:SetResizable(true)
    feedWindow:SetResizeBounds(FEED_MIN_W, FEED_MIN_H, 900, 450)
    feedWindow:SetClampedToScreen(true)
    Skin(feedWindow, C.feedBg)

    local function Unlocked() return not BloodfeudDB.isLocked end

    local titleBar = CreateTitleBar(feedWindow, 22, TITLE, Unlocked, SaveWindowDimensions)
    feedWindow.titleBar = titleBar

    local closeBtn = CreateCloseButton(titleBar, function() feedWindow:Hide() end)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -3, 0)
    AddTooltip(closeBtn, "Hide the kill feed", "Bring it back with /bf or the minimap button.")

    local lockBtn = CreateLockButton(titleBar)
    lockBtn:SetPoint("RIGHT", closeBtn, "LEFT", -1, 0)
    lockBtn:SetScript("OnClick", function()
        BloodfeudDB.isLocked = not BloodfeudDB.isLocked
        UpdateLockState()
    end)
    AddTooltip(lockBtn, "Lock / Unlock", "Locked: the feed can't be moved or resized.")
    feedWindow.lockBtn = lockBtn

    local statsBtn = CreateButton(titleBar, "Stats", 48, 16)
    statsBtn:SetPoint("RIGHT", lockBtn, "LEFT", -3, 0)
    statsBtn:SetScript("OnClick", function() ToggleStatsWindow() end)
    AddTooltip(statsBtn, "Statistics & Leaderboard")
    titleBar.title:SetPoint("RIGHT", statsBtn, "LEFT", -4, 0) -- narrow window: the title is cut with "..."

    local content = CreateFrame("Frame", nil, feedWindow)
    content:SetPoint("TOPLEFT", feedWindow, "TOPLEFT", 1, -23)
    content:SetPoint("BOTTOMRIGHT", feedWindow, "BOTTOMRIGHT", -1, 1)
    content:SetClipsChildren(true)
    feedWindow.content = content

    for i = 1, FEED_MAX_ROWS do
        local row = CreateFrame("Frame", nil, content)
        row:SetHeight(FEED_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -2 - (i - 1) * FEED_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -2 - (i - 1) * FEED_ROW_HEIGHT)
        if i % 2 == 0 then Tex(row, "BACKGROUND", C.stripe):SetAllPoints(row) end
        row.points = NewText(row, 11, "RIGHT")
        row.points:SetPoint("RIGHT", row, "RIGHT", -14, 0)
        row.points:SetWidth(36)
        row.text = NewText(row, 11)
        row.text:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.text:SetPoint("RIGHT", row.points, "LEFT", -4, 0)
        row:Hide()
        feedRows[i] = row
    end

    feedWindow.empty = NewText(content, 11, "CENTER")
    feedWindow.empty:SetPoint("CENTER", content, "CENTER", 0, 0)
    feedWindow.empty:SetText(HEX_DIM .. "No kills yet. Go find some enemies.|r")

    feedWindow.resizeGrip = CreateResizeGrip(feedWindow, Unlocked, SaveWindowDimensions)
    feedWindow:SetScript("OnSizeChanged", LayoutFeed)

    CreateMinimapButton()
    UpdateLockState()
    LayoutFeed()
end

function addonTable.UI.RequestUpdate()
    uiNeedsUpdate = true
end

local lastStatsRefresh = 0
C_Timer.NewTicker(0.5, function()
    local statsShown = statsWindow and statsWindow:IsShown()
    if uiNeedsUpdate then
        uiNeedsUpdate = false
        RefreshDisplay()
        if statsShown then
            UpdateStatsContent()
            lastStatsRefresh = GetTime()
        end
    elseif statsShown and (GetTime() - lastStatsRefresh) > 2 then
        -- While the leaderboard is open, refresh it on its own every 2 seconds
        UpdateStatsContent()
        lastStatsRefresh = GetTime()
    end
end)

-- =========================================================
-- TOOLTIP & UNITFRAME PORTRAIT INTEGRATION
-- =========================================================
local INDICATOR_ICON = ICON_SMALL

-- Title holders show their chosen zone title instead of "Bloodfeud" (if enabled); the icon always stays
local function OnTooltipSetUnit(tooltip)
    local _, unit = tooltip:GetUnit()
    if not unit or not UnitIsPlayer(unit) then return end
    local fullName = Util.UnitFullName(unit)
    if not fullName then return end
    local shown = ShowTitles() and addonTable.DB and addonTable.Sync
        and addonTable.DB.GetShownTitle(fullName, addonTable.Sync.GetUserTitle(fullName))
    if shown then
        tooltip:AddLine(ICON_INLINE .. " |cFFFF8000" .. shown.title .. "|r")
    elseif addonTable.Sync and addonTable.Sync.IsUserActive(fullName) then
        tooltip:AddLine(ICON_INLINE .. " |cFFFFD100Bloodfeud|r")
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipSetUnit)
end

local function AttachIndicator(frame)
    if not frame or frame.bfIndicator then return end
    local parentPortrait = frame.portrait or frame
    local texture = frame:CreateTexture(nil, "OVERLAY", nil, 7)
    texture:SetSize(14, 14)
    texture:SetPoint("TOPLEFT", parentPortrait, "TOPLEFT", -2, 2)
    texture:SetTexture(INDICATOR_ICON)
    texture:Hide()
    frame.bfIndicator = texture
end

if TargetFrame then AttachIndicator(TargetFrame) end
if PlayerFrame then AttachIndicator(PlayerFrame) end

local indicatorFrame = CreateFrame("Frame")
indicatorFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
indicatorFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

indicatorFrame:SetScript("OnEvent", function(self, event)
    if PlayerFrame and PlayerFrame.bfIndicator then
        PlayerFrame.bfIndicator:Show()
    end

    if TargetFrame and TargetFrame.bfIndicator then
        if UnitExists("target") and UnitIsPlayer("target") then
            local tName = Util.UnitFullName("target")
            if addonTable.Sync and addonTable.Sync.SendDirectPing then
                addonTable.Sync.SendDirectPing("target")
            end
            if addonTable.Sync and addonTable.Sync.IsUserActive(tName) then
                TargetFrame.bfIndicator:Show()
            else
                TargetFrame.bfIndicator:Hide()
            end
        else
            TargetFrame.bfIndicator:Hide()
        end
    end
end)

-- =========================================================
-- SIMULATION COMMANDS (/bf sim): dev build only (folder name contains "Test").
-- Fake players and kills live only in memory: never saved, never sent, gone on /reload.
-- =========================================================
local DEV_BUILD = addonName:find("Test", 1, true) ~= nil
local simCounter, simClock = 0, 0

local function SimPrint(msg) print("|cFFFF8000[Bloodfeud sim]|r " .. msg) end

local function Pick(list) return list[math.random(#list)] end

local function SimName(faction, i)
    return (faction == "Horde" and "Simhorde" or "Simally") .. i .. "-" .. (Util.MyRealm() or "Sim")
end

-- A unique, always increasing time (newer commands = newer kills): this week (from an hour ago) or last week
local function SimTime(lastWeek)
    local weekStart = addonTable.DB.WeekStart()
    if lastWeek then
        simCounter = simCounter + 1
        return weekStart - addonTable.DB.WEEK + 3600 + simCounter * 37
    end
    simClock = math.max(simClock + 7, weekStart + 1, GetServerTime() - 3600)
    return simClock
end

-- Arguments in any order: a number (count), "last" (last week), a title zone key, "none" (no zone).
-- No zone given: the zone you're standing in.
local function SimArgs(args)
    local o = { count = nil, lastWeek = false }
    for word in args:gmatch("%S+") do
        if tonumber(word) then
            o.count = math.max(1, math.min(200, math.floor(tonumber(word))))
        elseif word == "last" then
            o.lastWeek = true
        elseif word == "none" then
            o.zoneName = "Open World"
            o.noZone = true
        else
            for _, z in ipairs(addonTable.DB.GetTitleZones()) do
                if z.key == word then o.map, o.zoneName = z.map, z.name end
            end
            if not o.map then o.unknown = word end
        end
    end
    if not o.map and not o.noZone then
        o.map = C_Map and C_Map.GetBestMapForUnit and Util.Call(C_Map.GetBestMapForUnit, "player")
        o.zoneName = GetZoneText()
    end
    return o
end

local function SimHelp()
    local keys = {}
    for _, z in ipairs(addonTable.DB.GetTitleZones()) do table.insert(keys, z.key) end
    SimPrint("Fake data for testing (memory only, cleared by /reload or /bf sim clear):")
    print("  /bf sim kill [n] [zone] [last]  - you kill n enemies")
    print("  /bf sim death [n] [zone] [last] - you die n times")
    print("  /bf sim title [zone]            - you win that zone's title (12 kills last week)")
    print("  /bf sim crowd [n]               - n fake players fight everywhere (both weeks)")
    print("  /bf sim clear                   - remove all fake data")
    print("  zone: " .. table.concat(keys, ", ") .. ", none (no zone), default: where you stand")
    print("  last: put it in last week (that decides this week's titles)")
    SimPrint(string.format("%d fake kills loaded.", addonTable.DB.SimCount()))
end

local function SimCommand(args)
    local DB = addonTable.DB
    local sub, rest = args:match("^(%S*)%s*(.*)$")
    local me = Util.MyFullName()
    local myFaction = UnitFactionGroup("player")
    if sub == "" or sub == "help" then return SimHelp() end
    if sub == "clear" then
        SimPrint(string.format("Removed %d fake records.", DB.ClearSim()))
        return
    end
    if not me or (myFaction ~= "Alliance" and myFaction ~= "Horde") then
        SimPrint("Needs a character with a faction.")
        return
    end
    local enemy = Util.EnemyFaction(myFaction)
    local level = UnitLevel("player") or 80
    local o = SimArgs(rest or "")
    if o.unknown then
        SimPrint("Unknown zone '" .. o.unknown .. "'. Type /bf sim for the list.")
        return
    end
    local when = o.lastWeek and "last week" or "this week"

    if sub == "kill" or sub == "death" or sub == "title" then
        local n = (sub == "title") and 12 or (o.count or 1)
        local lastWeek = o.lastWeek or sub == "title"
        for i = 1, n do
            local foe = SimName(enemy, math.random(5))
            local s = { map = o.map, zone = o.zoneName, t = SimTime(lastWeek), level = level }
            if sub == "death" then
                s.killer, s.kf, s.victim, s.vf = foe, enemy, me, myFaction
            else
                s.killer, s.kf, s.victim, s.vf = me, myFaction, foe, enemy
            end
            DB.SimKill(s)
        end
        if sub == "title" then
            SimPrint(string.format("12 kills in %s last week: the title is yours (if no fake player beats you). Check the Titles tab and your own tooltip.", o.zoneName or "?"))
        else
            SimPrint(string.format("%d simulated %s in %s (%s).", n, sub == "kill" and "kill(s)" or "death(s)", o.zoneName or "?", when))
        end
    elseif sub == "crowd" then
        local n = math.max(2, o.count or 12)
        local players = { Alliance = {}, Horde = {} }
        local guilds = { Alliance = { "Lions Pride", "Silver Hand" }, Horde = { "Blood Fangs", "Warsong Raiders" } }
        local guildOf = {}
        for i = 1, n do
            local fac = (i % 2 == 0) and "Horde" or "Alliance"
            local name = SimName(fac, 100 + i)
            table.insert(players[fac], name)
            guildOf[name] = (i % 3 ~= 0) and Pick(guilds[fac]) or nil
        end
        local count = 0
        local function Kill(killerFac, killer, map, zoneName, lastWeek)
            local victimFac = Util.EnemyFaction(killerFac)
            local victim = Pick(players[victimFac])
            DB.SimKill({ killer = killer, kf = killerFac, kg = guildOf[killer], victim = victim, vf = victimFac,
                vg = guildOf[victim], map = map, zone = zoneName, t = SimTime(lastWeek), level = level })
            count = count + 1
        end
        -- Per zone and faction: a strong player last week (sometimes not enough for the title)
        -- and a few contenders this week
        for _, z in ipairs(DB.GetTitleZones()) do
            for _, fac in ipairs(FACTIONS) do
                local champ = Pick(players[fac])
                for _ = 1, math.random(8, 16) do Kill(fac, champ, z.map, z.name, true) end
                for _ = 1, math.random(3, 12) do Kill(fac, Pick(players[fac]), z.map, z.name, false) end
            end
        end
        -- Some open world fights for the leaderboard
        for _ = 1, n * 3 do
            local fac = Pick(FACTIONS)
            Kill(fac, Pick(players[fac]), nil, "Open World", math.random(2) == 1)
        end
        SimPrint(string.format("%d fake players, %d kills (this week and last week). Open /bf stats.", n, count))
    else
        SimHelp()
    end
end

-- =========================================================
-- SLASH COMMAND (/bf)
-- =========================================================
SLASH_BLOODFEUD1 = "/bf"
SlashCmdList["BLOODFEUD"] = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)") or ""

    if cmd == "debug" then
        if addonTable.Engine and addonTable.Engine.PrintDebug then
            addonTable.Engine.PrintDebug()
        end
    elseif cmd == "test" then
        if addonTable.DB and addonTable.DB.AddTestRecords then
            addonTable.DB.AddTestRecords()
            RefreshDisplay()
            if feedWindow and not feedWindow:IsShown() then feedWindow:Show() end
        end
    elseif cmd == "sync" then
        if addonTable.Sync and addonTable.Sync.BroadcastPing then
            addonTable.Sync.BroadcastPing(true)
            addonTable.Sync.RequestCatchUp()
            print("|cFFFFD100[Bloodfeud]|r Pinged the network and requested missed kills.")
        end
    elseif cmd == "stats" then
        ToggleStatsWindow()
    elseif cmd == "sim" and DEV_BUILD then
        SimCommand((msg or ""):match("^%s*%S+%s*(.*)$") or "")
    elseif cmd == "titles" then
        BloodfeudDB.showTitles = not ShowTitles()
        print("|cFFFFD100[Bloodfeud]|r Zone titles in tooltips: " .. (ShowTitles() and "on" or "off"))
        UpdateStatsContent()
    elseif cmd == "zone" then
        -- Current map id and its parents: which title zone (if any) a death here counts for
        local m = C_Map and C_Map.GetBestMapForUnit and Util.Call(C_Map.GetBestMapForUnit, "player")
        if not m then
            print("|cFFFFD100[Bloodfeud]|r No map id here.")
            return
        end
        local chain, id = {}, m
        for _ = 1, 10 do
            local info = Util.Call(C_Map.GetMapInfo, id)
            if type(info) ~= "table" then break end
            table.insert(chain, string.format("%s (%d)", tostring(info.name), id))
            id = info.parentMapID
            if type(id) ~= "number" or id <= 0 then break end
        end
        print("|cFFFFD100[Bloodfeud]|r Map: " .. table.concat(chain, " > "))
        local key = addonTable.DB.TitleZoneOf(m)
        local zoneName
        for _, z in ipairs(addonTable.DB.GetTitleZones()) do
            if z.key == key then zoneName = z.name end
        end
        print("|cFFFFD100[Bloodfeud]|r " .. (zoneName and ("Kills here count for the " .. zoneName .. " titles.") or "Not a title zone."))
    elseif cmd == "help" or cmd == "?" then
        -- debug, test and zone work but are not listed
        print("|cFFFFD100[Bloodfeud]|r Commands:")
        print("  /bf        - Toggle the kill feed")
        print("  /bf stats  - Statistics & leaderboard window")
        print("  /bf titles - Show / hide zone titles in tooltips")
        print("  /bf sync   - Request missed kills from the network now")
        if DEV_BUILD then print("  /bf sim    - Test data (dev build only)") end
    else
        ToggleFeedWindow()
    end
end
