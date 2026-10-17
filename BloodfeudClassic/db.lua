local addonName, addonTable = ...
addonTable.DB = {}
local DB = addonTable.DB

local Util = addonTable.Util
local NormalizeName = Util.NormalizeName
local ByteLess, H32, Job, TWO32 = Util.ByteLess, Util.H32, Util.Job, Util.TWO32

-- =========================================================
-- SHARED KILL LEDGER
-- Points are NOT stored or synced. Only records travel the network:
--   * E (death)  : written by the victim's OWN client -> "X killed me"
--   * C (claim)  : written by the client of a player who got the HK -> "I killed X, my active party: ..."
--   * D (dispute): a player's client cancels a FORGED record written in their name
-- Everyone computes the leaderboard and feed themselves from the same records with the same rules.
-- Editing SavedVariables by hand only changes your own screen; deleting the file gets
-- the records back from the network on login (no reset).
--
-- FORGED RECORD PROTECTION (all based on record content -> same result for everyone):
--   * A kill only counts if the victim's death record + a claim from the killer side MATCH.
--     A one-sided record does nothing; whoever forges a death in someone else's name has to
--     write a claim in their own name (the cheater is exposed).
--   * Everyone knows the records they wrote and the times they were online. If they see a
--     record in their name, dated to a time they were online, that they didn't write, they
--     publish a dispute (D); the record is cancelled for everyone.
--   * Only addon users with their own record in the ledger get points
--     (writing made-up names into the party list is useless).
-- If the victim has no addon there is no death record: the kill doesn't count.
--
-- SHARED KILLS
--   * Everyone who took part in a kill (killing blow, other attackers, other HK claimants and
--     their active party members) gets the same points: they are never split, but they are
--     reduced by group size (GROUP_SHARE_PCT): solo 100%, 2 players 90%, 3 players 80%, 4+ 50%.
--
-- STORAGE
--   * Records sit in SavedVariables as single-line canonical text (same format as on the network).
--     If two different records with the same id arrive, everyone keeps the smaller one in byte
--     order: the same ledger for everyone, whatever the arrival order.
--   * Week = Blizzard's weekly reset (per region). The weekly leaderboard resets with it.
--   * Raw records are only kept for this week + last week. Older ones are folded into the "base":
--     ONE line per player (FP, kills, deaths, KB, faction, guild + streak state at the boundary).
--     The computation continues from the base; the result is the same as replaying every record.
--   * Bases are compared on the network (hash inside PING). A client that differs adopts the majority's base.
-- =========================================================

local SCHEMA = 6                -- 6: points scaled down by 10, death spacing rule removed
local DEATH_PENALTY_FP = 6
local STARTING_FP = 50
local CLAIM_MATCH_WINDOW = 30   -- seconds: maximum time difference between a claim and a death record
local MAX_LIST = 4              -- length of the assist / party list in a record
local MAX_ID_LEN = 160
local MAX_MSG_LEN = 250         -- SendAddonMessage limit is 255 bytes
local MAX_FUTURE = 300          -- seconds: records dated further ahead than this are held back (clock skew)
local PENDING_MAX = 200
local FEED_SIZE = 50
local STREAK_WINDOW = 60        -- seconds: the first 3 killing blows must fall within this time
local MAX_SESSIONS = 500
local SESSION_SLACK = 10        -- seconds: tolerance at session boundaries
local RECOMPUTE_DELAY = 0.5     -- seconds: new records are collected and computed in one go
local HOUSEKEEP_INTERVAL = 30

-- Kill points: by victim level - killer level (capped at 15 for 3+ above, no points for 4+ below)
local KILL_FP_BY_DIFF = {
    [-3] = 3, [-2] = 5, [-1] = 8,
    [0] = 10,
    [1] = 11, [2] = 13, [3] = 15,
}
local SAME_LEVEL_FP = 10
local MAX_KILL_FP = 15

-- Shared kill points in percent, by the number of players who took part in the kill (4 or more = last entry)
local GROUP_SHARE_PCT = { 100, 90, 80, 50 }

local GODLIKE_MESSAGES = {
    "%s is GODLIKE! Somebody stop him!",
    "%s is GODLIKE! Who dares challenge him?",
    "%s is GODLIKE! Beg for mercy and you may live...",
    "%s is GODLIKE!",
    "%s is GODLIKE! Bow before his MIGHT!"
}

local function GetKillPoints(killerLevel, victimLevel)
    killerLevel = tonumber(killerLevel) or 0
    victimLevel = tonumber(victimLevel) or 0
    if killerLevel <= 0 or victimLevel <= 0 then
        return SAME_LEVEL_FP -- unknown level: treat as same level
    end

    local diff = victimLevel - killerLevel
    if diff > 3 then return KILL_FP_BY_DIFF[3] end
    return KILL_FP_BY_DIFF[diff] or 0
end

-- Integer math (rounded half up): every client gets exactly the same number
local function GetSharedPoints(points, groupSize)
    local pct = GROUP_SHARE_PCT[math.min(math.max(groupSize, 1), #GROUP_SHARE_PCT)]
    return math.floor((points * pct + 50) / 100)
end

-- =========================================================
-- ZONE TITLES (zones and titles: titles.lua)
--   * Every title zone has its own weekly tally per player: kill points earned there minus
--     DEATH_PENALTY_FP per death there (never below 0). The zone is where the victim died.
--   * Last week's top player per faction holds the title for the whole current week,
--     if they reached TITLE_MIN_FP. Tie: whoever reached that tally first.
--   * This week's tally decides next week's holders (shown as contenders).
-- =========================================================
local TITLE_MIN_FP = 100
local TITLE_ZONES = addonTable.TitleZones or {}
local titleRoots = {}  -- [uiMapID] = zone key
for _, z in ipairs(TITLE_ZONES) do titleRoots[z.map] = z.key end
local zoneOfMap = {}   -- cache: [uiMapID] = zone key or false

-- uiMapID -> title zone key: the map itself or one of its parent maps is a title zone
local function TitleZoneOf(m)
    if not m then return nil end
    local hit = zoneOfMap[m]
    if hit ~= nil then return hit or nil end
    local key, id = false, m
    for _ = 1, 10 do
        if titleRoots[id] then key = titleRoots[id]; break end
        local info = C_Map and C_Map.GetMapInfo and Util.Call(C_Map.GetMapInfo, id)
        id = type(info) == "table" and info.parentMapID
        if type(id) ~= "number" or id <= 0 then break end
    end
    zoneOfMap[m] = key
    return key or nil
end

-- =========================================================
-- WEEK: Blizzard's weekly reset (per region; EU Wednesday, US Tuesday)
-- The reset time comes from the server and is rounded to the full hour: everyone in a region gets the same moment.
-- Without the API the region's known reset time is used.
-- =========================================================
local WEEK = 7 * 86400
-- A weekly reset moment (UTC, from the first week of 1970): region -> seconds
local FALLBACK_RESET = {
    [1] = 5 * 86400 + 15 * 3600, -- US: Tuesday 15:00 UTC
    [2] = 6 * 86400 + 23 * 3600, -- KR: Wednesday 23:00 UTC
    [3] = 6 * 86400 + 4 * 3600,  -- EU: Wednesday 04:00 UTC
    [4] = 6 * 86400 + 23 * 3600, -- TW: Wednesday 23:00 UTC
}

-- Start of the week that contains now (the last weekly reset)
local function WeekStart(now)
    local nextReset
    local secs = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset
        and Util.Call(C_DateAndTime.GetSecondsUntilWeeklyReset)
    if type(secs) == "number" and secs >= 0 and secs <= WEEK + 3600 then
        nextReset = math.floor((now + secs + 1800) / 3600) * 3600
    else
        local ref = FALLBACK_RESET[Util.Call(GetCurrentRegion) or 0] or FALLBACK_RESET[1]
        nextReset = ref + (math.floor((now - ref) / WEEK) + 1) * WEEK
    end
    local start = nextReset - WEEK
    while start > now do start = start - WEEK end
    while start + WEEK <= now do start = start + WEEK end
    return start
end

-- Fold boundary: start of last week. Death records older than this are folded into the base.
local function FoldBoundary(now)
    return WeekStart(now) - WEEK
end

-- =========================================================
-- RECORD ENCODING (same format for the network and SavedVariables)
-- E:<t>:<victim>:<vFac>:<vLvl>:<vGuild>:<killer>:<kFac>:<kLvl>:<kGuild>:<zone>:<assist,assist>
-- C:<t>:<claimant>:<cFac>:<cLvl>:<cGuild>:<victim>:<party,party>
-- D:<t>:<owner>:<id of the cancelled record>
-- t = GetServerTime() (same clock for everyone)
-- The record owner (victim / claimant / disputer) is always written as "Name-Realm".
-- Other names on the owner's realm are written as just "Name" (so the message fits in 255 bytes).
-- =========================================================
local FAC_CODE = { Alliance = "A", Horde = "H" }
local CODE_FAC = { A = "Alliance", H = "Horde" }

local function Clean(s, maxBytes)
    if s == nil then return "" end
    s = tostring(s):gsub("[:,;|\r\n]", "")
    if maxBytes then s = Util.Truncate(s, maxBytes) end
    return s
end

-- "Name-Realm" -> "Name" if the realm equals baseRealm
local function Rel(full, baseRealm)
    if type(full) ~= "string" or full == "" then return "" end
    if baseRealm and Util.RealmOf(full) == baseRealm then return Clean(Util.ShortName(full)) end
    return Clean(full)
end

-- "Name" -> "Name-baseRealm"
local function Abs(s, baseRealm)
    if type(s) ~= "string" or s == "" then return nil end
    if s:find("-", 1, true) or not baseRealm then return s end
    return s .. "-" .. baseRealm
end

local function JoinList(list, baseRealm)
    local out = {}
    for _, n in ipairs(type(list) == "table" and list or {}) do
        if #out >= MAX_LIST then break end
        local c = Rel(n, baseRealm)
        if c ~= "" then table.insert(out, c) end
    end
    return table.concat(out, ",")
end

local function SplitList(s, baseRealm)
    local list = {}
    if s and s ~= "" then
        for name in string.gmatch(s, "[^,]+") do
            if #list >= MAX_LIST then break end
            table.insert(list, Abs(name, baseRealm))
        end
    end
    return list
end

-- If the message doesn't fit, these fields are emptied in order
local function Fit(fields, dropOrder)
    local msg = table.concat(fields, ":")
    for _, idx in ipairs(dropOrder) do
        if #msg <= MAX_MSG_LEN then break end
        fields[idx] = ""
        msg = table.concat(fields, ":")
    end
    if #msg > MAX_MSG_LEN then return nil end
    return msg
end

local function Int(n) return tostring(math.floor(tonumber(n) or 0)) end

-- Zone field: "<uiMapID>#<zone name>" (the map id is language independent, the name is for display).
-- It stays inside the old zone field so older clients store and relay the record byte for byte.
local function ZoneField(z, m)
    return Clean((m and (Int(m) .. "#") or "") .. (z or ""), 32)
end

local function SplitZone(s)
    local m, z = (s or ""):match("^(%d+)#(.*)$")
    if m then return z, tonumber(m) end
    return s, nil
end

function DB.Encode(kind, r)
    if kind == "E" then
        local base = Util.RealmOf(r.v)
        return Fit({
            "E", Int(r.t),
            Clean(r.v), FAC_CODE[r.vf] or "N", Int(r.vl), Clean(r.vg, 24),
            Rel(r.k, base), FAC_CODE[r.kf] or "N", Int(r.kl), Clean(r.kg, 24),
            ZoneField(r.z, r.m), JoinList(r.a, base),
        }, { 11, 10, 6, 12 })
    elseif kind == "C" then
        local base = Util.RealmOf(r.c)
        return Fit({
            "C", Int(r.t),
            Clean(r.c), FAC_CODE[r.cf] or "N", Int(r.cl), Clean(r.cg, 24),
            Rel(r.v, base), JoinList(r.p, base),
        }, { 6, 8 })
    elseif kind == "D" then
        return Fit({ "D", Int(r.t), Clean(r.a), Clean(r.x) }, {})
    end
    return nil
end

function DB.Decode(s)
    if type(s) ~= "string" or #s > 255 then return nil end
    local p = { strsplit(":", s) }
    if p[1] == "E" then
        local base = Util.RealmOf(p[3])
        local z, m = SplitZone(p[11])
        return "E", {
            t = tonumber(p[2]), v = p[3], vf = CODE_FAC[p[4]], vl = tonumber(p[5]), vg = p[6],
            k = Abs(p[7], base), kf = CODE_FAC[p[8]], kl = tonumber(p[9]), kg = p[10], z = z, m = m,
            a = SplitList(p[12], base),
        }
    elseif p[1] == "C" then
        local base = Util.RealmOf(p[3])
        return "C", {
            t = tonumber(p[2]), c = p[3], cf = CODE_FAC[p[4]], cl = tonumber(p[5]), cg = p[6],
            v = Abs(p[7], base), p = SplitList(p[8], base),
        }
    elseif p[1] == "D" then
        return "D", { t = tonumber(p[2]), a = p[3], x = p[4] }
    end
    return nil
end

-- =========================================================
-- RECORD VALIDATION
-- =========================================================
local function ValidTime(t)
    t = tonumber(t)
    if not t then return nil end
    t = math.floor(t)
    if t < 1600000000 then return nil end
    return t
end

local function Level(l)
    l = math.floor(tonumber(l) or 0)
    if l < 0 or l > 200 then return 0 end
    return l
end

local function Fac(f)
    if f == "Alliance" or f == "Horde" then return f end
    return nil
end

local function MapId(m)
    m = tonumber(m)
    if not m or m < 1 or m > 999999 or m ~= math.floor(m) then return nil end
    return m
end

local function Text(s)
    if type(s) == "string" and s ~= "" and s ~= "No Guild" then return s end
    return nil
end

local function FullName(n)
    if type(n) ~= "string" or not n:find("-", 1, true) then return nil end -- realm required
    return NormalizeName(n)
end

local function NameList(list, exclude)
    local out, seen = {}, {}
    for _, n in ipairs(type(list) == "table" and list or {}) do
        n = FullName(n)
        if #out < MAX_LIST and n and n ~= exclude and not seen[n] then
            seen[n] = true
            table.insert(out, n)
        end
    end
    return out
end

local function Author(kind, rec)
    if kind == "E" then return rec.v end
    if kind == "C" then return rec.c end
    if kind == "D" then return rec.a end
end

local function KindOf(id)
    if type(id) ~= "string" then return nil end
    if id:sub(1, 1) == "!" then return "D" end
    if id:find(">", 1, true) then return "C" end
    return "E"
end

-- Raw record -> clean record + id (content-based, the same for everyone)
local function Normalize(kind, rec)
    if type(rec) ~= "table" then return nil end
    local t = ValidTime(rec.t)
    if not t then return nil end

    local id, clean
    if kind == "E" then
        local v = FullName(rec.v)
        if not v then return nil end
        local k = FullName(rec.k)
        if k == v then k = nil end
        clean = {
            t = t, v = v, vf = Fac(rec.vf), vl = Level(rec.vl), vg = Text(rec.vg),
            k = k, kf = Fac(rec.kf), kl = Level(rec.kl), kg = Text(rec.kg),
            z = Text(rec.z), m = MapId(rec.m), a = NameList(rec.a, v),
        }
        id = v .. "@" .. t
    elseif kind == "C" then
        local c, v = FullName(rec.c), FullName(rec.v)
        if not c or not v or c == v then return nil end
        clean = {
            t = t, v = v, c = c, cf = Fac(rec.cf), cl = Level(rec.cl), cg = Text(rec.cg),
            p = NameList(rec.p, v),
        }
        id = c .. ">" .. v .. "@" .. t
    elseif kind == "D" then
        local a, x = FullName(rec.a), rec.x
        if not a or type(x) ~= "string" or x == "" or #x > MAX_ID_LEN or not KindOf(x) then return nil end
        clean = { t = t, a = a, x = x }
        id = "!" .. a .. "@" .. t
    else
        return nil
    end
    clean.id = id
    return clean, id
end

-- The record's canonical line: encode -> decode -> clean -> encode again must be identical.
-- The same content gives a byte-for-byte identical line on every client.
local function Canonical(kind, rec)
    local clean, id = Normalize(kind, rec)
    if not clean then return nil end
    local line = DB.Encode(kind, clean)
    if not line then return nil end
    local k2, r2 = DB.Decode(line)
    local clean2, id2 = Normalize(k2, r2)
    if not clean2 or id2 ~= id or DB.Encode(k2, clean2) ~= line then return nil end
    clean2.line = line
    return clean2, id, line
end

-- =========================================================
-- STATE
-- =========================================================
local KINDS = { "E", "C", "D" }
local cache = { E = {}, C = {}, D = {} }   -- [id] = decoded record (SavedVariables only holds the line)
local loaded = false
local pending = {}                         -- future-dated records: { kind, rec }
local changeGen = 0                        -- incremented on every ledger/base change
local computed = nil                       -- last computed leaderboard/feed
local lbCache = {}                         -- GetLeaderboard results (cleared when the computation changes)
local testFeed = {}                        -- /bf test lines (not saved)
local currentSession = nil
local forgeryAlerts = {}                   -- forged records already warned about this session
local pendingBase = nil                    -- base received from the network, waiting to be applied
local job = { running = false, timer = false, rerun = false, lastMs = 0, runs = 0, folds = 0 }

local EMPTY_TITLES = { holders = {}, contenders = {}, tally = {}, byPlayer = {} }
local EMPTY_COMPUTED = { players = {}, feed = {}, week = -1, stats = {}, gen = -1, titles = EMPTY_TITLES }

local MyName = Util.MyFullName

local function Store(kind)
    if kind == "E" then return BloodfeudClassicDB.events end
    if kind == "C" then return BloodfeudClassicDB.claims end
    if kind == "D" then return BloodfeudClassicDB.disputes end
end

local function NotifyUI()
    if addonTable.UI and addonTable.UI.RequestUpdate then addonTable.UI.RequestUpdate() end
end

local Schedule -- defined below

local function MarkDirty()
    changeGen = changeGen + 1
    Schedule()
end

-- =========================================================
-- BASE (folded old weeks): one line per player
--   "0"                                              : addon user, not on the leaderboard
--   "1;fp;kills;deaths;kb;fac;guild;streak"         : leaderboard player
--   streak    = "count.start.active(0/1)" (if still in effect at the boundary, else empty)
-- =========================================================
local function NewBase()
    return { B = 0, n = 0, rows = {}, used = {}, feed = {}, hash = 0 }
end

local function RowText(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("[;~=]", ""))
end

local function RowLine(p, s)
    if not p then return "0" end
    return table.concat({
        "1", Int(p.fp), Int(p.kills), Int(p.deaths), Int(p.kb),
        FAC_CODE[p.faction] or "", RowText(p.guild),
        s and (Int(s.count) .. "." .. Int(s.start) .. "." .. (s.active and "1" or "0")) or "",
    }, ";")
end

local function NonNegInt(s)
    local n = tonumber(s)
    if not n or n < 0 or n ~= math.floor(n) then return nil end
    return n
end

-- Lines from the network pass through here too: values an honest computation can't produce are rejected
local function ParseRow(row)
    if row == "0" then return { player = false } end
    if type(row) ~= "string" or select("#", strsplit(";", row)) ~= 8 then return nil end
    local p, fp, kills, deaths, kb, fac, guild, st = strsplit(";", row)
    if p ~= "1" then return nil end
    fp, kills, deaths, kb = NonNegInt(fp), NonNegInt(kills), NonNegInt(deaths), NonNegInt(kb)
    if not (fp and kills and deaths and kb) then return nil end
    if kb > kills or fp > STARTING_FP + MAX_KILL_FP * kills then return nil end
    if fac ~= "" and not CODE_FAC[fac] then return nil end
    local r = { player = true, fp = fp, kills = kills, deaths = deaths, kb = kb,
                faction = CODE_FAC[fac], guild = guild ~= "" and guild or nil }
    if st ~= "" then
        local c, s, a = st:match("^(%d+)%.(%d+)%.([01])$")
        if not c then return nil end
        r.sc, r.ss, r.sa = tonumber(c), tonumber(s), a == "1"
    end
    return r
end

-- The base's network lines ("#b=", "#n=", "#u=" + "Name-Realm=row")
local function BaseLines(base)
    local lines = { "#b=" .. Int(base.B), "#n=" .. Int(base.n) }
    for id in pairs(base.used) do lines[#lines + 1] = "#u=" .. id end
    for name, row in pairs(base.rows) do lines[#lines + 1] = name .. "=" .. row end
    return lines
end

-- Order-independent hash (sum of line hashes): no sorting needed, can be split inside a job
local function LinesHash(lines)
    local sum = 0
    for i, line in ipairs(lines) do
        sum = (sum + H32(line)) % TWO32
        if i % 200 == 0 then Job.Yield() end
    end
    return sum
end

-- =========================================================
-- STARTUP / LOADING
-- =========================================================
local function InitTables()
    BloodfeudClassicDB = BloodfeudClassicDB or {}
    local db = BloodfeudClassicDB
    if db.isActive == nil then db.isActive = true end
    db.windowPos = db.windowPos or { point = "CENTER", relativePoint = "CENTER", xOfs = 0, yOfs = 200 }
    db.windowSize = db.windowSize or { width = 450, height = 175 }
    db.events = db.events or {}
    db.claims = db.claims or {}
    db.disputes = db.disputes or {}
    db.mine = db.mine or {}         -- [id] = true : records written by this client
    db.sessions = db.sessions or {} -- { { s = start, e = last seen }, ... } times we were online on this client
    if type(db.base) ~= "table" then db.base = NewBase() end
    local b = db.base
    b.B, b.n, b.hash = tonumber(b.B) or 0, tonumber(b.n) or 0, tonumber(b.hash) or 0
    b.rows, b.used, b.feed = b.rows or {}, b.used or {}, b.feed or {}
end

-- Schema 6: points were divided by 10 (rounded half up) and the death spacing rule was removed.
-- Raw records are simply recomputed with the new rules; only the folded base holds old-scale
-- numbers. Its rows ("1;fp;kills;deaths;kb;fac;guild;streak;lastDeath") are rewritten in the new
-- format with fp / 10. Identical old bases give identical new bases on every client.
local function Scale10(n) return math.floor((n + 5) / 10) end

local function MigrateBaseTo6(base)
    if base.B == 0 and next(base.rows) == nil then return end -- nothing folded yet
    for name, row in pairs(base.rows) do
        local f = type(row) == "string" and { strsplit(";", row) } or {}
        if #f == 9 and f[1] == "1" then
            local fp = NonNegInt(f[2])
            if fp then f[2] = tostring(Scale10(fp)) end
            base.rows[name] = table.concat(f, ";", 1, 8)
        end
    end
    for _, line in ipairs(base.feed) do
        if type(line) == "table" and type(line.points) == "number" then line.points = Scale10(line.points) end
    end
    base.hash = LinesHash(BaseLines(base))
end

-- Decode the lines in SavedVariables into memory.
-- VERSION UPGRADES NEVER DELETE DATA: records stored as tables (schema 4) are converted to lines,
-- lines that can't be decoded (e.g. a newer version's format) are not deleted, just ignored.
-- So neither updating nor going back to an old version and updating again resets the leaderboard.
local function LoadStores()
    local db = BloodfeudClassicDB
    -- Fields from before the shared ledger (schema < 4, seen only by this client)
    db.killHistory, db.players, db.guilds, db.streaks, db.stats = nil, nil, nil, nil, nil
    for _, kind in ipairs(KINDS) do
        local store, c = Store(kind), {}
        local converted = {}
        for id, v in pairs(store) do
            local rec, newId, line
            if type(v) == "string" then
                local k2, r2 = DB.Decode(v)
                if k2 == kind then
                    rec, newId = Normalize(kind, r2)
                    line = v
                end
            elseif type(v) == "table" then
                rec, newId, line = Canonical(kind, v)
                converted[id] = true -- table: rewritten as a line (dropped if it can't be decoded)
            end
            if rec and newId then
                rec.line = line
                local old = c[newId]
                if not old or ByteLess(line, old.line) then c[newId] = rec end
                if newId ~= id then converted[id] = true end
            end
        end
        for id in pairs(converted) do store[id] = nil end
        for id, rec in pairs(c) do store[id] = rec.line end
        cache[kind] = c
    end
    if (tonumber(db.schema) or 0) < 6 then MigrateBaseTo6(db.base) end
    if (tonumber(db.schema) or 0) < SCHEMA then db.schema = SCHEMA end
end

function DB.Init()
    InitTables()
    if loaded then return end
    loaded = true
    LoadStores()
    C_Timer.NewTicker(HOUSEKEEP_INTERVAL, function() DB.Housekeep() end)
    MarkDirty()
end

function DB.EnsurePlayerLoaded()
    MarkDirty() -- add our own row (faction/guild) to the computation
end

-- Record the times we are online: records "in our name" dated within these ranges
-- that we didn't write are definitely forged (a character can't be in two places at once).
function DB.TouchSession()
    DB.Init()
    local now = GetServerTime()
    if not currentSession then
        currentSession = { s = now, e = now }
        table.insert(BloodfeudClassicDB.sessions, currentSession)
        while #BloodfeudClassicDB.sessions > MAX_SESSIONS do table.remove(BloodfeudClassicDB.sessions, 1) end
    end
    currentSession.e = now
end

local function WasOnlineAt(t)
    for _, s in ipairs(BloodfeudClassicDB.sessions) do
        if t >= (s.s - SESSION_SLACK) and t <= (s.e + SESSION_SLACK) then return true end
    end
    return false
end

-- =========================================================
-- ADDING RECORDS
-- =========================================================
-- A record from the folded period: no longer accepted since it's in the base (same boundary for everyone)
local function TooOld(kind, t, B)
    if kind == "E" then return t < B end
    return t < B - CLAIM_MATCH_WINDOW -- claim/dispute: can match deaths right after the boundary
end

-- kind: "E" (death), "C" (claim) or "D" (dispute). Returns: id, is new, canonical line
function DB.AddRecord(kind, rec)
    DB.Init()
    local clean, id, line = Canonical(kind, rec)
    if not clean then return nil end

    local now = GetServerTime()
    if clean.t > now + MAX_FUTURE then
        -- Client with a clock running ahead: don't lose the record, retry when its time comes
        if #pending < PENDING_MAX then table.insert(pending, { kind = kind, rec = rec }) end
        return nil
    end
    if TooOld(kind, clean.t, math.max(BloodfeudClassicDB.base.B, FoldBoundary(now))) then return nil end

    local store = Store(kind)
    local old = store[id]
    if old == line then return id, false, line end
    -- Same id, different content: everyone keeps the smaller one in byte order (arrival order doesn't matter)
    if old and not ByteLess(line, old) then return id, false, old end
    store[id] = line
    cache[kind][id] = clean
    MarkDirty()
    return id, true, line
end

-- A record written by this client itself
function DB.MarkMine(id)
    DB.Init()
    if id then BloodfeudClassicDB.mine[id] = true end
end

-- Is a record from the network in our name, and did we not write it? If forged, returns a dispute record (D).
function DB.CheckForgery(kind, id)
    DB.Init()
    local rec = cache[kind] and cache[kind][id]
    if not rec or BloodfeudClassicDB.mine[id] then return nil end
    local me = MyName()
    if not me or Author(kind, rec) ~= me then return nil end
    if currentSession then currentSession.e = GetServerTime() end

    local forged = false
    if kind == "D" and BloodfeudClassicDB.mine[rec.x] then
        forged = true -- we never dispute our own record
    elseif WasOnlineAt(rec.t) then
        forged = true -- we were online on this client at that time and didn't write this record
    end
    if not forged then return nil end

    if not forgeryAlerts[id] then
        forgeryAlerts[id] = true
        local who = ""
        if kind == "E" and rec.k then
            who = " (listed killer: " .. Util.DisplayName(rec.k) .. ")"
        elseif kind == "C" then
            who = " (listed victim: " .. Util.DisplayName(rec.v) .. ")"
        end
        print("|cFFFF3333[Bloodfeud Classic] A forged record in your name was detected and cancelled" .. who .. ".|r")
    end

    -- A dispute must be dated after its target
    return { t = math.max(GetServerTime(), rec.t + 1), a = me, x = id }
end

-- For catch-up: all records with t >= since, sorted by time { kind, id, line, t }
function DB.GetRecordsSince(since)
    DB.Init()
    since = tonumber(since) or 0
    local list = {}
    for _, kind in ipairs(KINDS) do
        for id, r in pairs(cache[kind]) do
            if r.t >= since then table.insert(list, { kind = kind, id = id, line = r.line, t = r.t }) end
        end
    end
    table.sort(list, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return ByteLess(a.id, b.id)
    end)
    return list
end

function DB.HasRecordsSince(since)
    DB.Init()
    since = tonumber(since) or 0
    for _, kind in ipairs(KINDS) do
        for _, r in pairs(cache[kind]) do
            if r.t >= since then return true end
        end
    end
    return false
end

-- Our last online time before this session (catch-up starts here). 0 if none: request everything.
function DB.GetPreviousSessionEnd()
    DB.Init()
    local latest = 0
    for _, s in ipairs(BloodfeudClassicDB.sessions) do
        if s ~= currentSession and s.e > latest then latest = s.e end
    end
    return latest
end

-- =========================================================
-- COMPUTATION (same result for everyone: depends only on the records, the base and byte order)
-- With foldB: deaths older than foldB are replayed and a new base is produced (fold).
-- =========================================================
local function ByTimeThenId(a, b)
    if a.t ~= b.t then return a.t < b.t end
    return ByteLess(a.id, b.id)
end

local function ByClaimId(a, b) return ByteLess(a.id, b.id) end

local function NewPlayer(name)
    return {
        name = name, fp = STARTING_FP, kills = 0, deaths = 0, kb = 0,
        weekly = { fp = STARTING_FP, kills = 0, deaths = 0, kb = 0, active = false },
    }
end

-- New records may arrive during the job: the computation runs on a copy taken at the start
-- Simulated records (dev build, /bf sim): only in memory, never saved, never sent, gone on /reload.
-- They join normal computations but never a fold, so they can't end up in the base.
local simRecords = { E = {}, C = {}, D = {} }

local function Snapshot(withSim)
    local snap = { byId = {} }
    for _, kind in ipairs(KINDS) do
        local list, byId = {}, {}
        for id, r in pairs(cache[kind]) do
            list[#list + 1] = r
            byId[id] = r
        end
        if withSim then
            for id, r in pairs(simRecords[kind]) do
                if not byId[id] then
                    list[#list + 1] = r
                    byId[id] = r
                end
            end
        end
        snap[kind], snap.byId[kind] = list, byId
    end
    return snap
end

-- A record is void if its own owner has a valid dispute against it.
-- No cycles are possible since a dispute must be dated after its target.
local function BuildVoidCheck(snap)
    local byTarget = {}
    for _, d in ipairs(snap.D) do
        local l = byTarget[d.x]
        if not l then l = {}; byTarget[d.x] = l end
        l[#l + 1] = d
    end
    local memo = {}
    local function IsVoid(id)
        if memo[id] ~= nil then return memo[id] end
        memo[id] = false
        local kind = KindOf(id)
        local rec = kind and snap.byId[kind][id]
        local list = byTarget[id]
        if rec and list then
            local author = Author(kind, rec)
            for _, d in ipairs(list) do
                if d.a == author and d.t > rec.t and not IsVoid(d.id) then
                    memo[id] = true
                    break
                end
            end
        end
        return memo[id]
    end
    return IsVoid
end

local function Compute(foldB)
    local db = BloodfeudClassicDB
    local base = db.base
    local now = GetServerTime()
    local currentWeek = WeekStart(now)
    local snap = Snapshot(not foldB)
    local IsVoid = BuildVoidCheck(snap)
    local used = base.used
    local stats = { events = 0, claims = 0, orphanClaims = 0, ignored = 0, unconfirmed = 0, voided = 0 }
    local claimLimit = foldB and (foldB - CLAIM_MATCH_WINDOW)
    local dead = { E = {}, C = {}, D = {} }  -- records to delete when folding
    local newUsed = {}

    -- Addon users: everyone with a valid record in the ledger (or the base)
    local users, usersByShort = {}, {}
    local function AddUser(name)
        if users[name] then return end
        users[name] = true
        local short = Util.ShortName(name)
        usersByShort[short] = usersByShort[short] or {}
        table.insert(usersByShort[short], name)
    end

    -- Starting state from the base
    local players, streaks = {}, {}
    local n = 0
    for name, row in pairs(base.rows) do
        local r = ParseRow(row)
        if r then
            AddUser(name)
            if r.player then
                local p = NewPlayer(name)
                p.fp, p.kills, p.deaths, p.kb = r.fp, r.kills, r.deaths, r.kb
                p.faction, p.guild = r.faction, r.guild
                players[name] = p
                if r.sc then streaks[name] = { count = r.sc, start = r.ss, active = r.sa } end
            end
        end
        n = n + 1
        if n % 200 == 0 then Job.Yield() end
    end

    -- A name with a guessed realm (the record writer's realm was assumed) is mapped to the real user:
    -- the only user with that name, if there is exactly one. A certain realm is kept as is.
    local function ResolveUser(name, guessedRealm)
        if not name or users[name] then return name end
        if Util.RealmOf(name) ~= guessedRealm then return name end
        local list = usersByShort[Util.ShortName(name)]
        if list and #list == 1 then return list[1] end
        return name
    end

    -- Death records
    local events, byVictim, byVictimShort = {}, {}, {}
    for i, ev in ipairs(snap.E) do
        if IsVoid(ev.id) then
            stats.voided = stats.voided + 1
            if foldB and ev.t < foldB then dead.E[#dead.E + 1] = ev.id end
        else
            local e = { id = ev.id, t = ev.t, rec = ev, claims = {} }
            table.insert(events, e)
            byVictim[ev.v] = byVictim[ev.v] or {}
            table.insert(byVictim[ev.v], e)
            local short = Util.ShortName(ev.v)
            byVictimShort[short] = byVictimShort[short] or {}
            table.insert(byVictimShort[short], e)
            AddUser(ev.v)
        end
        if i % 200 == 0 then Job.Yield() end
    end

    -- Each claim is matched to the closest death record of the same victim. If the killer couldn't
    -- see the victim's realm they wrote their own realm: in that case only the name is compared.
    for i, c in ipairs(snap.C) do
        if IsVoid(c.id) then
            stats.voided = stats.voided + 1
            if foldB and c.t < claimLimit then dead.C[#dead.C + 1] = c.id end
        elseif used[c.id] then
            -- Matched to a death that went into the base in an earlier fold: not used again
            AddUser(c.c)
            if foldB and c.t < claimLimit then dead.C[#dead.C + 1] = c.id end
        else
            stats.claims = stats.claims + 1
            AddUser(c.c)
            local candidates = byVictim[c.v] or {}
            if #candidates == 0 and Util.RealmOf(c.v) == Util.RealmOf(c.c) then
                candidates = byVictimShort[Util.ShortName(c.v)] or {}
            end
            local best, bestDiff
            for _, e in ipairs(candidates) do
                local d = math.abs(e.t - c.t)
                if d <= CLAIM_MATCH_WINDOW and (not bestDiff or d < bestDiff or (d == bestDiff and ByteLess(e.id, best.id))) then
                    best, bestDiff = e, d
                end
            end
            if best then
                table.insert(best.claims, { id = c.id, rec = c })
            else
                stats.orphanClaims = stats.orphanClaims + 1
                if foldB and c.t < claimLimit then dead.C[#dead.C + 1] = c.id end
            end
        end
        if i % 200 == 0 then Job.Yield() end
    end
    if foldB then
        for _, d in ipairs(snap.D) do
            if d.t < claimLimit then dead.D[#dead.D + 1] = d.id end
        end
    end
    stats.events = #events

    table.sort(events, ByTimeThenId)

    local function Info(name, faction, guild)
        local p = players[name]
        if not p then
            p = NewPlayer(name)
            players[name] = p
        end
        if faction then p.faction = faction end
        if guild then p.guild = guild end
        return p
    end

    local function Credit(p, points, isKB, thisWeek)
        p.fp = p.fp + points
        p.kills = p.kills + 1
        if isKB then p.kb = p.kb + 1 end
        if thisWeek then
            local w = p.weekly
            w.fp = w.fp + points
            w.kills = w.kills + 1
            if isKB then w.kb = w.kb + 1 end
            w.active = true
        end
    end

    local function Penalty(p, thisWeek)
        p.deaths = p.deaths + 1
        p.fp = math.max(0, p.fp - DEATH_PENALTY_FP)
        if thisWeek then
            local w = p.weekly
            w.deaths = w.deaths + 1
            w.fp = math.max(0, w.fp - DEATH_PENALTY_FP)
            w.active = true
        end
    end

    -- Streak: based on record time (the same announcement for everyone)
    local function StreakOnKB(name, t)
        local s = streaks[name]
        if not s then
            s = { count = 0, start = t, active = false }
            streaks[name] = s
        end
        local shown = Util.DisplayName(name)
        if not s.active then
            if (t - s.start) > STREAK_WINDOW then
                s.count, s.start = 1, t
            else
                s.count = s.count + 1
            end
            if s.count >= 3 then
                s.active = true
                return string.format("|cFFFFD100[%s Triple Kill!]|r", shown)
            end
            return nil
        end

        s.count = s.count + 1
        local c = s.count
        if c == 5 then
            return string.format("|cFFFF0000[%s PENTAKILL!]|r", shown)
        elseif c == 8 or c == 11 or c == 13 then
            return string.format("|cFFFF00FF[%s is on a RAMPAGE!!]|r", shown)
        elseif c >= 15 and ((c - 15) % 5 == 0) then
            local msg = GODLIKE_MESSAGES[((c - 15) / 5) % #GODLIKE_MESSAGES + 1]
            return "|cFF00FFFF[" .. string.format(msg, shown) .. "]|r"
        end
        return nil
    end

    -- Zone titles: separate weekly tallies ([week][zone][name] = { fp, t = time the tally last changed, faction })
    local lastWeek = currentWeek - WEEK
    local zoneTally = { last = {}, this = {} }
    local function Tally(week, zone, name, faction, delta, t)
        local list = zoneTally[week][zone]
        if not list then list = {}; zoneTally[week][zone] = list end
        local e = list[name]
        if not e then e = { fp = 0, t = t }; list[name] = e end
        if faction then e.faction = faction end
        local fp = math.max(0, e.fp + delta)
        if fp ~= e.fp then e.fp, e.t = fp, t end
    end

    local feed = {}
    for i, e in ipairs(events) do
        if foldB and e.t >= foldB then break end
        local ev = e.rec
        local thisWeek = ev.t >= currentWeek
        local skip = nil
        local victimRealm = Util.RealmOf(ev.v)

        if foldB then
            dead.E[#dead.E + 1] = e.id
            for _, c in ipairs(e.claims) do
                if c.rec.t < claimLimit then dead.C[#dead.C + 1] = c.id else newUsed[c.id] = true end
            end
        end

        -- Mutual confirmation: there must be at least one claim from the killer side
        if #e.claims == 0 then skip = "unconfirmed" end

        local killer, kf, kl, kg, points
        if not skip then
            table.sort(e.claims, ByClaimId)

            -- Killing blow: the recap's killer if they're an addon user who took part in the kill, otherwise the first claim.
            -- If the realm of a recap name is unknown, the victim's realm was written.
            local involved = {}
            for _, c in ipairs(e.claims) do
                involved[c.rec.c] = true
                for _, nm in ipairs(c.rec.p or {}) do involved[ResolveUser(nm, Util.RealmOf(c.rec.c))] = true end
            end
            local recapKiller = ResolveUser(ev.k, victimRealm)
            local fromRecap = recapKiller and users[recapKiller] and involved[recapKiller]
            if fromRecap then
                killer = recapKiller
            else
                killer = e.claims[1].rec.c
            end

            local kClaim
            for _, c in ipairs(e.claims) do
                if c.rec.c == killer then kClaim = c.rec; break end
            end
            if not kClaim then kClaim = e.claims[1].rec end -- party member: the claimant's faction
            kf = kClaim.cf or ev.kf
            -- Level: what the victim saw first (not what the killer wrote -> points can't be inflated by writing a low level)
            kl = (fromRecap and ev.kl > 0 and ev.kl) or (kClaim.c == killer and kClaim.cl > 0 and kClaim.cl) or 0
            kg = (kClaim.c == killer and kClaim.cg) or (fromRecap and ev.kg) or nil

            if kf and ev.vf and kf == ev.vf then
                skip = "faction"
            else
                points = GetKillPoints(kl, ev.vl)
                if points <= 0 then skip = "level" end -- 4+ levels below: doesn't count at all
            end
        end

        if skip == "unconfirmed" then
            stats.unconfirmed = stats.unconfirmed + 1
        elseif skip then
            stats.ignored = stats.ignored + 1
        else
            -- Group size: every distinct player who took part (killing blow, other attackers, claimants
            -- and their active party members), addon user or not. Matched by short name: the same
            -- player can appear with a guessed realm in one list and the real realm in another.
            local group, groupSize = {}, 0
            local function Join(name)
                local short = name and name ~= ev.v and Util.ShortName(name)
                if short and not group[short] then
                    group[short] = true
                    groupSize = groupSize + 1
                end
            end
            Join(killer)
            for _, nm in ipairs(ev.a or {}) do Join(nm) end
            for _, c in ipairs(e.claims) do
                Join(c.rec.c)
                for _, nm in ipairs(c.rec.p or {}) do Join(nm) end
            end
            points = GetSharedPoints(points, groupSize)

            -- Title zone tally (last week / this week only)
            local zone = not foldB and ev.t >= lastWeek and TitleZoneOf(ev.m)
            local week = zone and (thisWeek and "this" or "last")

            -- Victim: death penalty (points are only lost by dying)
            Penalty(Info(ev.v, ev.vf, ev.vg), thisWeek)
            if week then Tally(week, zone, ev.v, ev.vf, -DEATH_PENALTY_FP, ev.t) end
            streaks[ev.v] = nil

            -- Killing blow: points + kill + KB
            Credit(Info(killer, kf, kg), points, true, thisWeek)
            if week then Tally(week, zone, killer, kf, points, ev.t) end

            -- Other attackers, HK claimants and active party members: the same points, never split.
            -- Only addon users (those with their own record in the ledger) get points.
            local credited = { [killer] = true, [ev.v] = true }
            local function Assist(name, faction, guild)
                if name and users[name] and not credited[name] then
                    credited[name] = true
                    Credit(Info(name, faction, guild), points, false, thisWeek)
                    if week then Tally(week, zone, name, faction, points, ev.t) end
                end
            end
            for _, nm in ipairs(ev.a or {}) do Assist(ResolveUser(nm, victimRealm), kf) end
            for _, c in ipairs(e.claims) do
                Assist(c.rec.c, c.rec.cf, c.rec.cg)
                local claimRealm = Util.RealmOf(c.rec.c)
                for _, nm in ipairs(c.rec.p or {}) do Assist(ResolveUser(nm, claimRealm), c.rec.cf) end
            end

            -- Only the killing blow goes into the feed
            table.insert(feed, {
                killer = killer,
                victim = ev.v,
                points = points,
                killerFaction = kf or Util.EnemyFaction(ev.vf),
                victimFaction = ev.vf or "Neutral",
                zone = ev.z or "Open World",
                time = date("%H:%M:%S", ev.t),
            })
            local announcement = StreakOnKB(killer, ev.t)
            if announcement then
                table.insert(feed, { announcement = announcement, time = date("%H:%M:%S", ev.t) })
            end
        end
        if i % 50 == 0 then Job.Yield() end
    end

    -- Feed: old lines from the base + new ones, newest FEED_SIZE
    local allFeed = {}
    for _, f in ipairs(base.feed) do allFeed[#allFeed + 1] = f end
    for _, f in ipairs(feed) do allFeed[#allFeed + 1] = f end

    if foldB then
        -- New base: one line per user
        local rows = {}
        for name in pairs(players) do users[name] = true end
        for name in pairs(users) do
            local p = players[name]
            local s = streaks[name]
            if s and not (s.count > 0 and (s.active or (foldB - s.start) <= STREAK_WINDOW)) then s = nil end
            rows[name] = RowLine(p, p and s)
        end
        local keptFeed = {}
        for i = math.max(1, #allFeed - FEED_SIZE + 1), #allFeed do keptFeed[#keptFeed + 1] = allFeed[i] end
        local folded = #dead.E + #dead.C + #dead.D
        local newBase = { B = foldB, n = base.n + folded, rows = rows, used = newUsed, feed = keptFeed }
        newBase.hash = LinesHash(BaseLines(newBase))
        return { base = newBase, dead = dead }
    end

    -- Show ourselves on the list even without any kills/deaths
    local me = MyName()
    if me then
        local p = players[me] or Info(me)
        p.faction = UnitFactionGroup("player") or p.faction
        p.guild = GetGuildInfo("player") or p.guild
    end

    local newestFirst = {}
    for i = #allFeed, math.max(1, #allFeed - FEED_SIZE + 1), -1 do
        table.insert(newestFirst, allFeed[i])
    end

    -- Top player per zone and faction: higher tally, then whoever reached it first, then byte order
    local function Leaders(week)
        local out = {}
        for zone, list in pairs(zoneTally[week]) do
            local best = {}
            for name, e in pairs(list) do
                local fac = e.faction or (players[name] and players[name].faction)
                if (fac == "Alliance" or fac == "Horde") and e.fp > 0 then
                    local b = best[fac]
                    if not b or e.fp > b.fp or (e.fp == b.fp and (e.t < b.t or (e.t == b.t and ByteLess(name, b.name)))) then
                        best[fac] = { name = name, fp = e.fp, t = e.t }
                    end
                end
            end
            out[zone] = best
        end
        return out
    end

    local holders, byPlayer = {}, {}
    for zone, best in pairs(Leaders("last")) do
        for fac, b in pairs(best) do
            if b.fp >= TITLE_MIN_FP then
                holders[zone] = holders[zone] or {}
                holders[zone][fac] = b
            end
        end
    end
    for _, z in ipairs(TITLE_ZONES) do
        for _, fac in ipairs({ "Alliance", "Horde" }) do
            local b = holders[z.key] and holders[z.key][fac]
            if b and z[fac] then
                byPlayer[b.name] = byPlayer[b.name] or {}
                table.insert(byPlayer[b.name], { key = z.key, title = z[fac] })
            end
        end
    end
    local titles = { holders = holders, contenders = Leaders("this"), tally = zoneTally.this, byPlayer = byPlayer }

    return { players = players, feed = newestFirst, week = currentWeek, stats = stats, titles = titles }
end

-- Apply the fold result: replace the base, delete the folded raw records
local function ApplyFold(result)
    local db = BloodfeudClassicDB
    for _, kind in ipairs(KINDS) do
        local store, c = Store(kind), cache[kind]
        for _, id in ipairs(result.dead[kind]) do
            store[id] = nil
            c[id] = nil
        end
    end
    db.base = result.base
    for id in pairs(db.mine) do
        if not (db.events[id] or db.claims[id] or db.disputes[id]) then db.mine[id] = nil end
    end
    -- Session entries are only needed for the forgery check of records still kept
    local limit = result.base.B - CLAIM_MATCH_WINDOW - SESSION_SLACK
    local kept = {}
    for _, s in ipairs(db.sessions) do
        if s == currentSession or s.e >= limit then kept[#kept + 1] = s end
    end
    db.sessions = kept
    job.folds = job.folds + 1
end

-- Verify and apply a base received from the network (runs inside the job)
local function ApplyPendingBase()
    local cand = pendingBase
    pendingBase = nil
    if not cand then return false end
    local base = BloodfeudClassicDB.base
    if cand.B ~= base.B then return false end
    local nb = { B = cand.B, n = 0, rows = {}, used = {}, feed = base.feed }
    local sawB, sawN = false, false
    for i, line in ipairs(cand.lines) do
        local key, val = line:match("^([^=]+)=(.*)$")
        if not key then return false end
        if key == "#b" then
            if tonumber(val) ~= cand.B then return false end
            sawB = true
        elseif key == "#n" then
            nb.n = NonNegInt(val)
            if not nb.n then return false end
            sawN = true
        elseif key == "#u" then
            if KindOf(val) ~= "C" or #val > MAX_ID_LEN then return false end
            nb.used[val] = true
        else
            if FullName(key) ~= key or nb.rows[key] or not ParseRow(val) then return false end
            nb.rows[key] = val
        end
        if i % 200 == 0 then Job.Yield() end
    end
    if not (sawB and sawN) then return false end
    nb.hash = LinesHash(BaseLines(nb))
    if nb.hash ~= cand.hash or nb.hash == base.hash then return false end
    BloodfeudClassicDB.base = nb
    job.adopted = (job.adopted or 0) + 1
    return true
end

local function NeedsFold()
    return BloodfeudClassicDB.base.B < FoldBoundary(GetServerTime())
end

local function RunJob()
    job.timer = false
    if not loaded then return end
    if job.running then job.rerun = true; return end
    job.running = true
    job.rerun = false -- changes arriving during the job (AddRecord -> Schedule) set this back to true
    local started = debugprofilestop and debugprofilestop() or 0
    local baseChanged = false
    Job.Start("Bloodfeud recompute", function()
        if pendingBase and ApplyPendingBase() then baseChanged = true end
        if NeedsFold() then
            ApplyFold(Compute(FoldBoundary(GetServerTime())))
            baseChanged = true
        end
        local result = Compute(nil)
        result.gen = changeGen
        computed = result
        lbCache = {}
    end, function(ok)
        job.running = false
        job.runs = job.runs + 1
        job.lastMs = (debugprofilestop and debugprofilestop() or 0) - started
        if not ok then computed = computed or EMPTY_COMPUTED end
        NotifyUI()
        if baseChanged and addonTable.Sync and addonTable.Sync.OnBaseChanged then
            addonTable.Sync.OnBaseChanged()
        end
        if job.rerun or pendingBase then
            job.rerun = false
            Schedule()
        end
    end)
end

-- New records are collected briefly, then a single computation (split across frames) runs
Schedule = function()
    if not loaded then return end
    if job.running then job.rerun = true; return end
    if job.timer then return end
    job.timer = true
    -- If the last computation took long (large data) the wait gets a bit longer
    local delay = math.min(5, math.max(RECOMPUTE_DELAY, (job.lastMs or 0) / 1000 * 3))
    C_Timer.After(delay, RunJob)
end

local function EnsureComputed()
    DB.Init()
    if not computed or computed.week ~= WeekStart(GetServerTime()) then Schedule() end
    return computed or EMPTY_COMPUTED
end

function DB.Housekeep()
    if not loaded then return end
    if #pending > 0 then
        local list = pending
        pending = {}
        local any = false
        for _, p in ipairs(list) do
            local id, isNew = DB.AddRecord(p.kind, p.rec)
            if id and isNew then any = true end
        end
        if any then NotifyUI() end
    end
    if NeedsFold() or (computed and computed.week ~= WeekStart(GetServerTime())) then Schedule() end
end

-- =========================================================
-- BASE (for the network)
-- =========================================================
-- Returns: B, n, hash, ready (fold is up to date and no base is waiting to be applied).
-- The base only changes on a fold or when received from the network; a normal recompute doesn't touch it.
function DB.GetBaseInfo()
    DB.Init()
    local b = BloodfeudClassicDB.base
    return b.B, b.n, b.hash, (not NeedsFold() and not pendingBase)
end

function DB.GetBaseLines()
    DB.Init()
    return BaseLines(BloodfeudClassicDB.base)
end

-- A complete base from the network: verified on the next computation, applied if the hash matches
function DB.OfferBase(B, hash, lines)
    DB.Init()
    if type(lines) ~= "table" or B ~= BloodfeudClassicDB.base.B then return end
    pendingBase = { B = B, hash = hash, lines = lines }
    Schedule()
end

-- =========================================================
-- FEED / LEADERBOARD / STATS
-- =========================================================
function DB.GetFeed()
    local c = EnsureComputed()
    if #testFeed == 0 then return c.feed end
    local list = {}
    for _, r in ipairs(testFeed) do table.insert(list, r) end
    for _, r in ipairs(c.feed) do table.insert(list, r) end
    return list
end

DB.STARTING_FP = STARTING_FP
DB.DEATH_PENALTY_FP = DEATH_PENALTY_FP

function DB.SecondsUntilWeeklyReset()
    local now = GetServerTime()
    return WeekStart(now) + WEEK - now
end

function DB.GetPlayer(name)
    return EnsureComputed().players[NormalizeName(name) or ""]
end

-- Zone titles
DB.TITLE_MIN_FP = TITLE_MIN_FP

function DB.GetTitleZones() return TITLE_ZONES end

-- { holders = { [zone] = { Alliance = { name, fp }, Horde = ... } }, contenders = (same, this week),
--   tally = { [zone] = { [name] = { fp } } } (this week), byPlayer = { [name] = { { key, title }, ... } } }
function DB.GetTitles()
    return EnsureComputed().titles or EMPTY_TITLES
end

function DB.GetPlayerTitles(name)
    return DB.GetTitles().byPlayer[NormalizeName(name) or ""]
end

-- The title a player shows: the one they chose (zone key, if they hold it), otherwise their first
function DB.GetShownTitle(name, chosenKey)
    local list = DB.GetPlayerTitles(name)
    if not list or #list == 0 then return nil end
    for _, t in ipairs(list) do
        if t.key == chosenKey then return t end
    end
    return list[1]
end

-- Our own choice (zone key); sent to others inside PING/PONG
function DB.GetActiveTitle()
    return BloodfeudClassicDB and BloodfeudClassicDB.activeTitle
end

function DB.SetActiveTitle(key)
    DB.Init()
    BloodfeudClassicDB.activeTitle = key
end

function DB.TitleZoneOf(m) return TitleZoneOf(m) end

-- =========================================================
-- SIMULATION (dev build only, /bf sim): fake kills for testing without other addon users
-- =========================================================
-- One confirmed kill: the victim's death record + the killer's claim.
-- s = { killer, kf, kg, victim, vf, vg (names "Name-Realm"), map, zone, t, level }
function DB.SimKill(s)
    DB.Init()
    local level = s.level or 80
    local e, eid = Normalize("E", { t = s.t, v = s.victim, vf = s.vf, vl = level, vg = s.vg,
        k = s.killer, kf = s.kf, kl = level, kg = s.kg, z = s.zone or "Open World", m = s.map })
    local c, cid = Normalize("C", { t = s.t, c = s.killer, cf = s.kf, cl = level, cg = s.kg, v = s.victim })
    if not (e and c) then return false end
    e.line, c.line = "sim", "sim"
    simRecords.E[eid], simRecords.C[cid] = e, c
    MarkDirty()
    return true
end

function DB.ClearSim()
    local n = 0
    for _, kind in ipairs(KINDS) do
        for id in pairs(simRecords[kind]) do n = n + 1; simRecords[kind][id] = nil end
    end
    MarkDirty()
    return n
end

function DB.SimCount()
    local n = 0
    for _ in pairs(simRecords.E) do n = n + 1 end
    return n
end

function DB.WeekStart() return WeekStart(GetServerTime()) end
DB.WEEK = WEEK

local function ByFpThenName(a, b)
    if a.fp ~= b.fp then return a.fp > b.fp end
    return ByteLess(a.name, b.name)
end

-- The result is cached (the UI asks every 2 seconds): not re-sorted unless the computation changed
function DB.GetLeaderboard(isWeekly, factionFilter, isGuildMode)
    local c = EnsureComputed()
    local me = MyName()
    local cacheKey = (isWeekly and "w" or "a") .. (isGuildMode and "G" or tostring(factionFilter)) .. (me or "")
    local hit = lbCache[cacheKey]
    if hit and hit.computed == c then return hit.list end
    local list = {}

    local function Values(p)
        if isWeekly then
            if not p.weekly.active and p.name ~= me then return nil end
            return p.weekly
        end
        return p
    end

    if isGuildMode then
        local guildTotals = {}
        for _, p in pairs(c.players) do
            local v = Values(p)
            if v and p.guild and p.guild ~= "" then
                -- Guilds with the same name can exist on different realms
                local key = p.guild .. "-" .. (Util.RealmOf(p.name) or "")
                local g = guildTotals[key]
                if not g then
                    g = { name = p.guild, faction = p.faction, fp = 0, kills = 0, members = 0 }
                    guildTotals[key] = g
                end
                g.fp = g.fp + v.fp
                g.kills = g.kills + v.kills
                g.members = g.members + 1
            end
        end
        for _, g in pairs(guildTotals) do table.insert(list, g) end
    else
        for _, p in pairs(c.players) do
            local v = Values(p)
            if v and (not factionFilter or factionFilter == "ALL" or p.faction == factionFilter) then
                table.insert(list, {
                    name = p.name, faction = p.faction, guild = p.guild,
                    fp = v.fp, kills = v.kills, kb = v.kb, deaths = v.deaths,
                })
            end
        end
    end

    table.sort(list, ByFpThenName)
    lbCache[cacheKey] = { computed = c, list = list }
    return list
end

-- /bf test: shows the points table in the feed. Does NOT touch points, disappears on /reload.
function DB.AddTestRecords()
    local myName = MyName() or "Player"
    local myFaction = UnitFactionGroup("player") or "Neutral"
    local myLevel = tonumber(UnitLevel("player")) or 80
    local zone = GetZoneText() or "Open World"
    local now = date("%H:%M:%S")

    for _, diff in ipairs({ -3, -2, -1, 0, 1, 2, 3 }) do
        table.insert(testFeed, 1, {
            killer = myName,
            victim = string.format("Test%+d", diff),
            points = GetKillPoints(myLevel, myLevel + diff),
            killerFaction = myFaction,
            victimFaction = Util.EnemyFaction(myFaction),
            zone = zone,
            time = now,
        })
    end
    while #testFeed > FEED_SIZE do table.remove(testFeed) end
    print("|cFFFFD100[Bloodfeud Classic]|r Test: added sample kills for level differences -3..+3 to the feed. Points are unchanged; they disappear on /reload.")
end

function DB.GetDebugInfo()
    local c = EnsureComputed()
    local players = 0
    for _ in pairs(c.players) do players = players + 1 end
    local base = BloodfeudClassicDB.base
    local baseRows = 0
    for _ in pairs(base.rows) do baseRows = baseRows + 1 end
    local raw = 0
    for _, kind in ipairs(KINDS) do for _ in pairs(cache[kind]) do raw = raw + 1 end end
    local info = {
        players = players, raw = raw, pending = #pending,
        baseB = base.B, baseN = base.n, baseHash = base.hash, baseRows = baseRows,
        jobMs = job.lastMs, jobRuns = job.runs, folds = job.folds, adopted = job.adopted or 0,
    }
    for k, v in pairs(c.stats or {}) do info[k] = v end
    return info
end
