local addonName, addonTable = ...
addonTable.Engine = {}

local Util = addonTable.Util
local Readable, Call, CleanName = Util.Readable, Util.Call, Util.CleanName

-- =========================================================
-- NOTE: 12.x (Midnight) rules
--   * COMBAT_LOG_EVENT_UNFILTERED is closed to addons (CombatLogGetCurrentEventInfo
--     moved to the secure environment). Kills are detected WITHOUT the combat log.
--   * In instances / encounters / PvP matches / restricted maps some APIs return
--     "secret" values. In the open world the honor message, enemy player names, death
--     recap and addon messages are readable; every value is still checked with Readable().
--
-- Detection sources:
--   * CHAT_MSG_COMBAT_HONOR_GAIN : killer side ("X dies, honorable kill ...")
--   * PLAYER_PVP_KILLS_CHANGED   : fallback - an enemy seen dead if the honor message can't be parsed
--   * PLAYER_DEAD + C_DeathRecap : victim side - who landed the killing blow
--   * Nameplate / target / mouseover : remember nearby enemy players (faction, guild, level)
--   * Sync (party/guild + Battle.net friends) : information from other clients
-- =========================================================

-- SETTINGS
local ENEMY_SEEN_WINDOW   = 20   -- recap unreadable: count as a PvP death if an enemy was seen this long before dying
local ENEMY_ENGAGE_WINDOW = 15   -- no known enemy in recap: count as a PvP death if an enemy targeted us / we targeted one within this time
local ENEMY_CACHE_TTL     = 180  -- seconds: how long info on a seen enemy player is kept
local DEAD_ENEMY_WINDOW   = 5    -- PLAYER_PVP_KILLS_CHANGED fallback: an enemy seen dead within this time
local HK_FALLBACK_DELAY   = 1.0  -- how long to wait for the honor message after PLAYER_PVP_KILLS_CHANGED
local RECAP_RETRY_DELAY   = 0.4
local RECAP_MAX_TRIES     = 6
local MAX_NAMEPLATES      = 40
local PARTY_ACTIVE_WINDOW = 60   -- seconds: a party member who did anything (movement included) within this time gets kill points
local PARTY_POLL_INTERVAL = 2    -- seconds: party member position/combat check

-- Race -> Faction (GetPlayerInfoByGUID fallback)
local RACE_FACTION = {
    Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
    Draenei = "Alliance", Worgen = "Alliance", VoidElf = "Alliance",
    LightforgedDraenei = "Alliance", DarkIronDwarf = "Alliance",
    KulTiran = "Alliance", Mechagnome = "Alliance",

    Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde",
    BloodElf = "Horde", Goblin = "Horde", Nightborne = "Horde",
    HighmountainTauren = "Horde", MagharOrc = "Horde",
    ZandalariTroll = "Horde", Vulpera = "Horde",
}

-- Debug counters (/bf debug)
local dbg = {
    honor = 0, honorSecret = 0, honorUnparsed = 0, hk = 0, hkFallback = 0, pvpKillEvents = 0,
    deaths = 0, recapKills = 0, unknownKiller = 0, pveDeaths = 0,
    recapStatus = nil, lastHonorMsg = nil, lastHK = nil, lastDeath = nil,
}
local enemies = {}                              -- [name] = { faction, guild, level, guid, seen, engaged, dead }
local lastHK = { victim = nil, time = -1000 }
local lastDeathTime = -1000
local lastRecapSignature = nil
local initialized = false

-- The addon only runs when NOT in a raid group and OUTSIDE instances/BGs/arenas
local function TrackingAllowed()
    if BloodfeudDB and BloodfeudDB.isActive == false then return false end
    if IsInRaid() then return false end
    if IsInInstance() then return false end
    return true
end

local function MyName() return (Util.UnitName("player")) end
local function MyFaction() return Call(UnitFactionGroup, "player") or "Neutral" end
local function MyGuild() return (Call(GetGuildInfo, "player")) end
local function MyLevel() return (Call(UnitLevel, "player")) end

-- =========================================================
-- ENEMY PLAYER MEMORY
-- =========================================================
local function IsPartyMember(name)
    if not IsInGroup() then return false end
    for i = 1, 4 do
        if Util.UnitName("party" .. i) == name then return true end
    end
    return false
end

local function CleanupEnemies()
    local now = GetTime()
    for name, e in pairs(enemies) do
        if (now - e.seen) > ENEMY_CACHE_TTL then enemies[name] = nil end
    end
end

-- Records the unit's info if it is an enemy player. engaged: fighting us (targeting etc.)
local function NoteUnit(unit, engaged)
    if not Call(UnitExists, unit) or not Call(UnitIsPlayer, unit) then return end

    local name = Util.UnitName(unit)
    if not name then return end
    if Call(UnitInParty, unit) or Call(UnitInRaid, unit) then return end -- a cross-faction party member is not an enemy

    local myFaction = MyFaction()
    local faction = Call(UnitFactionGroup, unit)
    local hostile = Call(UnitIsEnemy, "player", unit)
    local opposite = faction and faction ~= "Neutral" and myFaction ~= "Neutral" and faction ~= myFaction
    if not hostile and not opposite then return end

    local now = GetTime()
    local e = enemies[name]
    if not e then
        CleanupEnemies()
        e = {}
        enemies[name] = e
    end
    e.seen = now
    e.full = Util.UnitFullName(unit) or e.full
    if faction and faction ~= "Neutral" then e.faction = faction end
    e.guild = Call(GetGuildInfo, unit) or e.guild
    local level = Call(UnitLevel, unit)
    if type(level) == "number" and level > 0 then e.level = level end
    local guid = Call(UnitGUID, unit)
    if type(guid) == "string" then e.guid = guid end
    if engaged then e.engaged = now end
    if Call(UnitIsDeadOrGhost, unit) then e.dead = now end
end

local function ForEachEnemyToken(fn)
    for _, unit in ipairs({ "target", "focus", "mouseover", "softenemy" }) do
        if fn(unit) then return unit end
    end
    for i = 1, MAX_NAMEPLATES do
        local unit = "nameplate" .. i
        if fn(unit) then return unit end
    end
    return nil
end

local function ScanVisibleEnemies()
    ForEachEnemyToken(function(unit) NoteUnit(unit) end)
end

local function FindUnitByName(name)
    return ForEachEnemyToken(function(unit)
        return Call(UnitExists, unit) and Util.UnitName(unit) == name
    end)
end

local function ResolveEnemy(name)
    local unit = FindUnitByName(name)
    if unit then NoteUnit(unit) end

    local e = enemies[name] or {}
    local faction = e.faction
    if not faction and e.guid then
        local _, _, _, englishRace = Call(GetPlayerInfoByGUID, e.guid)
        faction = englishRace and RACE_FACTION[englishRace]
    end
    return { faction = faction, guild = e.guild, level = e.level, guid = e.guid, full = e.full }
end

-- Turns an enemy name into "Name-Realm": the realm from the text if present, otherwise
-- the enemy memory (realm from UnitName), otherwise our own realm
local function FullEnemyName(raw)
    if type(raw) ~= "string" then return nil end
    local short = CleanName(raw)
    if not Util.IsValidName(short) then return nil end
    if raw:find("-", 1, true) then return Util.NormalizeName(raw) end
    local e = enemies[short]
    if e and e.full then return e.full end
    return Util.NormalizeName(short)
end

-- field: "seen" or "engaged"
local function RecentEnemy(field, window)
    local now = GetTime()
    for _, e in pairs(enemies) do
        if e[field] and (now - e[field]) <= window then return true end
    end
    return false
end

-- =========================================================
-- PARTY ACTIVITY (players idling AFK in town get no points)
-- Also works for members without the addon: movement, casts, combat and damage are watched from outside.
-- =========================================================
local partyActivity = {}                        -- [name] = { last = GetTime(), pos = "x:y:..." }

local function MarkPartyActive(unit)
    local name = Util.UnitName(unit)
    if not name then return end
    local a = partyActivity[name] or {}
    a.last = GetTime()
    partyActivity[name] = a
end

local function GetUnitPositionKey(unit)
    local y, x, _, instanceID = Call(UnitPosition, unit)
    if type(x) == "number" and type(y) == "number" then
        return string.format("%d:%.0f:%.0f", tonumber(instanceID) or 0, x, y) -- ~1 yard precision
    end
    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
        local mapID = Call(C_Map.GetBestMapForUnit, unit)
        local pos = mapID and Call(C_Map.GetPlayerMapPosition, mapID, unit)
        if pos and pos.GetXY then
            local px, py = Call(pos.GetXY, pos)
            if type(px) == "number" and type(py) == "number" then
                return string.format("m%d:%.4f:%.4f", mapID, px, py)
            end
        end
    end
    return nil
end

local function PollPartyActivity()
    if not IsInGroup() or not TrackingAllowed() then
        wipe(partyActivity)
        return
    end
    local present = {}
    for i = 1, 4 do
        local unit = "party" .. i
        local name = Util.UnitName(unit)
        if name then
            present[name] = true
            local a = partyActivity[name]
            if not a then
                a = {}
                partyActivity[name] = a
            end
            local pos = GetUnitPositionKey(unit)
            if pos and a.pos and pos ~= a.pos then a.last = GetTime() end -- first sighting does not count as movement
            if pos then a.pos = pos end
            if Call(UnitAffectingCombat, unit) then a.last = GetTime() end
        end
    end
    for name in pairs(partyActivity) do
        if not present[name] then partyActivity[name] = nil end
    end
end

local function IsPartyMemberActive(unit, name)
    if Call(UnitIsAFK, unit) then return false end
    local a = partyActivity[name]
    return a ~= nil and a.last ~= nil and (GetTime() - a.last) <= PARTY_ACTIVE_WINDOW
end

-- Party members (killer excluded). They get the same FP as the killer + a kill (no killing blow);
-- the FP is reduced by group size (see GROUP_SHARE_PCT in db.lua).
-- Only members active within the last PARTY_ACTIVE_WINDOW seconds (movement included) count.
local function GetPartyRecipients(excludeName)
    local list = {}
    if not IsInGroup() or IsInRaid() then return list end
    PollPartyActivity()

    for i = 1, 4 do
        local unit = "party" .. i
        if Call(UnitExists, unit) and Call(UnitIsPlayer, unit) then
            local n = Util.UnitName(unit)
            local full = Util.UnitFullName(unit)
            if n and full and n ~= excludeName and IsPartyMemberActive(unit, n) then
                table.insert(list, full)
            end
        end
    end
    return list
end

-- =========================================================
-- KILLER SIDE: HONOR MESSAGE -> KILL
-- =========================================================
local honorPatterns = nil

-- Converts a WoW format string (%s, %d, %.1f, %1$s ...) into a Lua pattern.
-- Returns: pattern, capture index of the victim name (1st argument)
local function FormatToPattern(fmt, anchorEnd)
    if type(fmt) ~= "string" or fmt == "" then return nil end

    local out = { "^" }
    local captures, nextArg, victimCapture = 0, 1, nil
    local i, n = 1, #fmt
    while i <= n do
        local c = fmt:sub(i, i)
        if c == "%" then
            local s, e, pos, dollar, conv = fmt:find("^%%(%d*)(%$?)[%-%+ #0]*%d*%.?%d*([%a%%])", i)
            if not s then
                table.insert(out, "%%")
                i = i + 1
            elseif conv == "%" then
                table.insert(out, "%%")
                i = e + 1
            else
                local argIndex
                if dollar == "$" and pos ~= "" then
                    argIndex = tonumber(pos)
                else
                    argIndex = nextArg
                    nextArg = nextArg + 1
                end
                captures = captures + 1
                if conv == "s" then
                    table.insert(out, "(.-)")
                    if argIndex == 1 then victimCapture = captures end
                else
                    table.insert(out, "([%d%.,]+)")
                end
                i = e + 1
            end
        else
            if c:find("^[%^%$%(%)%.%[%]%*%+%-%?]") then
                table.insert(out, "%" .. c)
            else
                table.insert(out, c)
            end
            i = i + 1
        end
    end
    if not victimCapture then return nil end
    if anchorEnd then table.insert(out, "$") end
    return table.concat(out), victimCapture
end

local function BuildHonorPatterns()
    honorPatterns = {}
    local formats = { _G.COMBATLOG_HONORGAIN, _G.COMBATLOG_HONORGAIN_NO_RANK, _G.COMBATLOG_HONORGAIN_EXHAUSTION1 }
    for _, anchorEnd in ipairs({ true, false }) do
        for _, fmt in ipairs(formats) do
            local p, idx = FormatToPattern(fmt, anchorEnd)
            if p then table.insert(honorPatterns, { pattern = p, index = idx }) end
        end
    end
    table.insert(honorPatterns, { pattern = "^(.-) dies, honorable kill", index = 1 })
end

local function ParseHonorVictim(msg)
    if not honorPatterns then BuildHonorPatterns() end
    for _, hp in ipairs(honorPatterns) do
        local caps = { msg:match(hp.pattern) }
        local victim = caps[hp.index]
        if type(victim) == "string" and victim ~= "" then return victim end
    end
    return nil
end

-- We got an HK on our own client: the victim is certain, whether we landed the killing blow is not.
local function OnLocalHonorKill(victimRaw, source)
    if not TrackingAllowed() then return end

    local stripped = Util.StripMarkup(victimRaw)
    local victim = CleanName(stripped)
    local myName = MyName()
    if not Util.IsValidName(victim) or not myName or victim == myName then return end

    local now = GetTime()
    if lastHK.victim == victim and (now - lastHK.time) < 5 then return end -- honor + fallback for the same kill
    lastHK.victim, lastHK.time = victim, now

    local myFaction = MyFaction()
    local v = ResolveEnemy(victim)
    local vFac = v.faction or Util.EnemyFaction(myFaction)
    if vFac == myFaction and myFaction ~= "Neutral" then return end -- only opposite-faction kills count

    dbg.hk = dbg.hk + 1
    dbg.lastHK = string.format("%s (%s, %s)", victim, source, date("%H:%M:%S"))

    -- Claim: counts only if it matches the victim's own death record (no points if the victim has no addon)
    addonTable.Sync.Publish("C", {
        t = GetServerTime(),
        c = Util.MyFullName(), cf = myFaction, cl = MyLevel(), cg = MyGuild(),
        v = FullEnemyName(stripped),
        p = GetPartyRecipients(myName),
    })
end

local function OnHonorGain(msg)
    dbg.honor = dbg.honor + 1
    if not Readable(msg) or type(msg) ~= "string" then
        dbg.honorSecret = dbg.honorSecret + 1
        return
    end
    dbg.lastHonorMsg = msg

    local victim = ParseHonorVictim(msg)
    if not victim then
        dbg.honorUnparsed = dbg.honorUnparsed + 1
        return
    end
    OnLocalHonorKill(victim, "honor")
end

-- An enemy seen dead in the last few seconds (our target first)
local function FindRecentlyDeadEnemy()
    NoteUnit("target")
    local targetName = Util.UnitName("target")
    local now = GetTime()
    local te = targetName and enemies[targetName]
    if te and te.dead and (now - te.dead) <= DEAD_ENEMY_WINDOW then return targetName end

    local best, bestTime
    for name, e in pairs(enemies) do
        if e.dead and (now - e.dead) <= DEAD_ENEMY_WINDOW and (not bestTime or e.dead > bestTime) then
            best, bestTime = name, e.dead
        end
    end
    return best
end

-- Fallback: the HK counter went up but the honor message did not arrive / could not be parsed
local function OnPvpKillsChanged(unit)
    if unit and unit ~= "player" then return end
    dbg.pvpKillEvents = dbg.pvpKillEvents + 1
    if not TrackingAllowed() then return end

    local eventTime = GetTime()
    C_Timer.After(HK_FALLBACK_DELAY, function()
        if lastHK.time >= eventTime - 2 then return end -- honor message already handled
        local victim = FindRecentlyDeadEnemy()
        if victim then
            dbg.hkFallback = dbg.hkFallback + 1
            OnLocalHonorKill(victim, "hk-counter")
        end
    end)
end

-- =========================================================
-- VICTIM SIDE: DEATH + DEATH RECAP
-- =========================================================
local function IsHostilePlayerSource(name, ev)
    local guid = ev.sourceGUID
    if Readable(guid) and type(guid) == "string" and guid:find("^Player%-") then
        -- In the open world friendly players can't deal damage; if not a party member it is an enemy
        return not IsPartyMember(name)
    end
    local e = enemies[name]
    return e ~= nil and (GetTime() - e.seen) <= ENEMY_CACHE_TTL
end

-- Returns: killer, assists, status, signature
--   status: "ok" | "nohostile" | "stale" | "empty" | "secret" | "error" | "noapi"
local function ReadDeathRecap()
    if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then return nil, nil, "noapi" end

    local ok, events = pcall(C_DeathRecap.GetRecapEvents)
    if not ok then return nil, nil, "error" end
    if not Readable(events) then return nil, nil, "secret" end
    if type(events) ~= "table" then return nil, nil, "empty" end
    local first = events[1]
    if type(first) ~= "table" then return nil, nil, "empty" end

    local ts, src, amount = first.timestamp, first.sourceName, first.amount
    if not Readable(ts) or not Readable(src) then return nil, nil, "secret" end
    if not Readable(amount) then amount = nil end
    local signature = tostring(ts) .. "|" .. tostring(src) .. "|" .. tostring(amount) .. "|" .. #events
    if signature == lastRecapSignature then return nil, nil, "stale", signature end

    local myName = MyName()
    local killer, assists, seen = nil, {}, {}
    for _, ev in ipairs(events) do -- events[1] = the hit that caused the death
        local raw = type(ev) == "table" and Readable(ev.sourceName) and Util.StripMarkup(ev.sourceName)
        local name = raw and CleanName(raw)
        local hidden = type(ev) == "table" and Readable(ev.hideCaster) and ev.hideCaster
        if name and not hidden and name ~= myName and not seen[name] then
            seen[name] = true
            if IsHostilePlayerSource(name, ev) then
                local full = FullEnemyName(raw)
                if full and not killer then
                    killer = full
                elseif full and #assists < 4 then
                    table.insert(assists, full)
                end
            end
        end
    end
    return killer, assists, killer and "ok" or "nohostile", signature
end

local function ReportOwnDeath(killer, assists, status, deathTime)
    local me = MyName()
    if not me then return end
    local myFaction = MyFaction()

    -- Death record: this is the official record of the kill (written by the victim's own client)
    local rec = {
        t = deathTime or GetServerTime(),
        v = Util.MyFullName(), vf = myFaction, vl = MyLevel(), vg = MyGuild(),
        kf = Util.EnemyFaction(myFaction),
        z = GetZoneText(),
        m = C_Map and C_Map.GetBestMapForUnit and Call(C_Map.GetBestMapForUnit, "player"), -- zone titles
    }

    if killer then -- killer / assists: "Name-Realm"
        local k = ResolveEnemy(Util.ShortName(killer))
        rec.k = killer
        rec.kf = k.faction or rec.kf
        rec.kg = k.guild
        rec.kl = k.level
        rec.a = assists
        dbg.recapKills = dbg.recapKills + 1
        dbg.lastDeath = string.format("by %s (%s)", killer, date("%H:%M:%S"))
    else
        -- Recap was read but has no known enemy: stricter check (mutual targeting)
        local pvp
        if status == "nohostile" then
            pvp = RecentEnemy("engaged", ENEMY_ENGAGE_WINDOW)
        else
            pvp = RecentEnemy("seen", ENEMY_SEEN_WINDOW)
        end
        if not pvp then
            dbg.pveDeaths = dbg.pveDeaths + 1
            dbg.lastDeath = string.format("PvE (%s, %s)", tostring(status), date("%H:%M:%S"))
            return
        end
        dbg.unknownKiller = dbg.unknownKiller + 1
        dbg.lastDeath = string.format("unknown killer (%s, %s)", tostring(status), date("%H:%M:%S"))
    end

    -- The death is recorded even without a known killer; the killer is matched from their claim (HK)
    addonTable.Sync.Publish("E", rec)
end

local function TryReadRecap(attempt, deathTime)
    if not TrackingAllowed() then return end
    local killer, assists, status, signature = ReadDeathRecap()
    dbg.recapStatus = status

    -- The recap may not be ready right after death: try a few times
    if (status == "stale" or status == "empty") and attempt < RECAP_MAX_TRIES then
        C_Timer.After(RECAP_RETRY_DELAY, function() TryReadRecap(attempt + 1, deathTime) end)
        return
    end
    if signature and status ~= "stale" then
        lastRecapSignature = signature
    end
    ReportOwnDeath(killer, assists, status, deathTime)
end

local function OnPlayerDead()
    if not TrackingAllowed() then return end
    local now = GetTime()
    if (now - lastDeathTime) < 5 then return end
    lastDeathTime = now

    dbg.deaths = dbg.deaths + 1
    ScanVisibleEnemies()
    local deathTime = GetServerTime()
    C_Timer.After(0.2, function() TryReadRecap(1, deathTime) end)
end

-- =========================================================
-- EVENT REGISTRATION (COMBAT_LOG_EVENT_UNFILTERED IS NOT USED!)
-- Frequent unit events (health, target, nameplate, casts) are only listened to while
-- tracking is on: in raids / dungeons / BGs the addon handles none of these events.
-- =========================================================
local listenerFrame = CreateFrame("Frame")
-- Party member cast/health events only for party1-4 (RegisterUnitEvent takes at most 2 units)
local partyFrames = { CreateFrame("Frame"), CreateFrame("Frame") }
local PARTY_UNITS = { { "party1", "party2" }, { "party3", "party4" } }
local PARTY_EVENTS = { "UNIT_HEALTH", "UNIT_SPELLCAST_SUCCEEDED" }

local function EventValid(event)
    return not (C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event))
end

local function IsTrackedUnit(unit)
    return unit == "target" or unit == "focus" or (type(unit) == "string" and unit:find("^nameplate%d+$") ~= nil)
end

-- Always listened to (rare; the tracking check is in the handler)
local handlers = {
    CHAT_MSG_COMBAT_HONOR_GAIN = function(msg) OnHonorGain(msg) end,
    PLAYER_PVP_KILLS_CHANGED = function(unit) OnPvpKillsChanged(unit) end,
    PLAYER_DEAD = function() OnPlayerDead() end,
    PLAYER_TARGET_CHANGED = function() NoteUnit("target", true) end,
    PLAYER_FOCUS_CHANGED = function() NoteUnit("focus") end,
}

-- Only listened to while tracking is on
local hotHandlers = {
    NAME_PLATE_UNIT_ADDED = function(unit) NoteUnit(unit) end,
    NAME_PLATE_UNIT_REMOVED = function(unit) NoteUnit(unit) end, -- when a dying player's nameplate is removed
    PLAYER_SOFT_ENEMY_CHANGED = function() NoteUnit("softenemy") end,
    UPDATE_MOUSEOVER_UNIT = function() NoteUnit("mouseover") end,
    UNIT_TARGET = function(unit)
        -- If an enemy targeted us, count it as "engaged"
        if IsTrackedUnit(unit) and Call(UnitIsUnit, unit .. "target", "player") then
            NoteUnit(unit, true)
        end
    end,
    UNIT_HEALTH = function(unit)
        if IsTrackedUnit(unit) and Call(UnitIsDeadOrGhost, unit) then
            NoteUnit(unit)
        end
    end,
}

local hotRegistered = nil
local function UpdateTrackingEvents()
    local want = TrackingAllowed()
    if want == hotRegistered then return end
    hotRegistered = want
    for event in pairs(hotHandlers) do
        if EventValid(event) then
            if want then
                pcall(listenerFrame.RegisterEvent, listenerFrame, event)
            else
                pcall(listenerFrame.UnregisterEvent, listenerFrame, event)
            end
        end
    end
    for i, f in ipairs(partyFrames) do
        for _, event in ipairs(PARTY_EVENTS) do
            if want then
                pcall(f.RegisterUnitEvent, f, event, PARTY_UNITS[i][1], PARTY_UNITS[i][2])
            else
                pcall(f.UnregisterEvent, f, event)
            end
        end
    end
    if not want then wipe(enemies) end
end

-- Events that can change the tracking state
local stateEvents = {
    PLAYER_ENTERING_WORLD = true, ZONE_CHANGED_NEW_AREA = true, GROUP_ROSTER_UPDATE = true,
}

for event in pairs(handlers) do
    if EventValid(event) then pcall(listenerFrame.RegisterEvent, listenerFrame, event) end
end
for event in pairs(stateEvents) do
    if EventValid(event) then pcall(listenerFrame.RegisterEvent, listenerFrame, event) end
end

listenerFrame:SetScript("OnEvent", function(self, event, ...)
    if stateEvents[event] then
        local ok, err = pcall(UpdateTrackingEvents)
        if not ok then Util.ReportError(err) end
        return
    end
    local handler = handlers[event] or hotHandlers[event]
    if not handler then return end
    local ok, err = pcall(handler, ...)
    if not ok then
        Util.ReportError(err)
    end
end)

local function OnPartyEvent(self, event, unit)
    local ok, err = pcall(MarkPartyActive, unit) -- cast a spell / took damage / got healed
    if not ok then Util.ReportError(err) end
end
for _, f in ipairs(partyFrames) do f:SetScript("OnEvent", OnPartyEvent) end

C_Timer.NewTicker(PARTY_POLL_INTERVAL, function()
    local ok, err = pcall(PollPartyActivity)
    if not ok then Util.ReportError(err) end
end)

function addonTable.Engine.Init()
    UpdateTrackingEvents()
    if initialized then return end
    initialized = true
    -- Store the signature of the death recap left over from before login/reload so it isn't taken for a new death
    local _, _, _, signature = ReadDeathRecap()
    lastRecapSignature = signature
end

-- Can be called when tracking is turned on/off (e.g. when isActive changes)
addonTable.Engine.UpdateTrackingEvents = function() pcall(UpdateTrackingEvents) end

function addonTable.Engine.PrintDebug()
    local tag = "|cFFFFD100[Bloodfeud]|r "
    print(tag .. "Debug:")
    print(string.format("  Honor messages: %d (secret: %d, unparsed: %d)  | HK: %d (from fallback: %d)  | HK counter events: %d",
        dbg.honor, dbg.honorSecret, dbg.honorUnparsed, dbg.hk, dbg.hkFallback, dbg.pvpKillEvents))
    print(string.format("  Deaths: %d  | killer found via recap: %d  | unknown killer: %d  | PvE: %d  | last recap status: %s",
        dbg.deaths, dbg.recapKills, dbg.unknownKiller, dbg.pveDeaths, tostring(dbg.recapStatus)))

    local count, newestName, newestTime = 0, nil, nil
    for name, e in pairs(enemies) do
        count = count + 1
        if not newestTime or e.seen > newestTime then newestName, newestTime = name, e.seen end
    end
    if newestName then
        print(string.format("  Enemy players in memory: %d  | last seen: %s (%ds ago)", count, newestName, GetTime() - newestTime))
    else
        print("  Enemy players in memory: none")
    end

    if IsInGroup() and not IsInRaid() then
        local parts = {}
        for i = 1, 4 do
            local unit = "party" .. i
            local n = Util.UnitName(unit)
            if n then
                local a = partyActivity[n]
                local ago = a and a.last and string.format("%ds ago", GetTime() - a.last) or "never"
                table.insert(parts, string.format("%s: %s (%s)", n,
                    IsPartyMemberActive(unit, n) and "|cFF00FF00active|r" or "|cFFFF3333inactive|r", ago))
            end
        end
        print("  Party activity: " .. (#parts > 0 and table.concat(parts, " | ") or "none"))
    end

    if dbg.lastHK then print("  Last HK: " .. dbg.lastHK) end
    if dbg.lastDeath then print("  Last death: " .. dbg.lastDeath) end
    if dbg.lastHonorMsg then print("  Last honor message: " .. dbg.lastHonorMsg) end

    local dbInfo = addonTable.DB.GetDebugInfo and addonTable.DB.GetDebugInfo()
    if dbInfo then
        print(string.format("  Ledger: %d death records | %d claims (%d unmatched) | %d players on leaderboard",
            dbInfo.events or 0, dbInfo.claims or 0, dbInfo.orphanClaims or 0, dbInfo.players or 0))
        print(string.format("  Not counted: %d unconfirmed (no claim from killer side) | %d other (same faction / 4+ levels lower / spam) | %d cancelled by dispute",
            dbInfo.unconfirmed or 0, dbInfo.ignored or 0, dbInfo.voided or 0))
        print(string.format("  Storage: %d raw records (last 2 weeks) | base: %d players, %d records folded (before %s UTC), hash %s | waiting (clock skew): %d",
            dbInfo.raw or 0, dbInfo.baseRows or 0, dbInfo.baseN or 0,
            (dbInfo.baseB or 0) > 0 and date("!%Y-%m-%d", dbInfo.baseB) or "-", tostring(dbInfo.baseHash), dbInfo.pending or 0))
        print(string.format("  Recompute: %d runs, last %.1f ms (split across frames) | folds %d | bases adopted from network %d",
            dbInfo.jobRuns or 0, dbInfo.jobMs or 0, dbInfo.folds or 0, dbInfo.adopted or 0))
    end

    if addonTable.Sync and addonTable.Sync.PrintDebug then addonTable.Sync.PrintDebug() end

    print(string.format("  Lua errors: %d%s", Util.errors, Util.lastError and (" | last: " .. Util.lastError) or ""))
    print(string.format("  In raid: %s  | In instance: %s  | Tracking on: %s",
        tostring(IsInRaid()), tostring(IsInInstance() and true or false), tostring(TrackingAllowed())))
end
