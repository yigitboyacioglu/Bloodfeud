local addonName, addonTable = ...

-- =========================================================
-- SHARED HELPERS (safe with 12.x "secret values")
-- In Midnight some APIs (instance, encounter, PvP match, restricted maps)
-- can return unreadable "secret" values. Comparing a secret value, using it
-- in a string operation or as a table key raises a Lua error.
-- So every value coming from outside is checked with Readable() first.
-- =========================================================
local Util = {}
addonTable.Util = Util

local canaccessvalue = canaccessvalue
local issecretvalue = issecretvalue

Util.errors = 0
Util.lastError = nil

function Util.Readable(v)
    if canaccessvalue then
        local ok, res = pcall(canaccessvalue, v)
        return ok and res and true or false
    elseif issecretvalue then
        local ok, res = pcall(issecretvalue, v)
        return ok and not res
    end
    return true -- pre-12.x client: no secrets
end

-- pcall + secret filter: returns nil on error or when a value is unreadable
function Util.Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then return nil end
    if not Util.Readable(a) then a = nil end
    if not Util.Readable(b) then b = nil end
    if not Util.Readable(c) then c = nil end
    if not Util.Readable(d) then d = nil end
    return a, b, c, d
end

function Util.ReportError(err)
    Util.errors = Util.errors + 1
    Util.lastError = tostring(err)
    local handler = geterrorhandler and geterrorhandler()
    if handler then pcall(handler, err) end
end

function Util.IsValidName(n)
    return type(n) == "string" and n ~= "" and n ~= "Unknown" and n ~= UNKNOWNOBJECT
end

function Util.CleanName(n)
    if type(n) ~= "string" or n == "" then return nil end
    return n:match("^([^%-]+)") or n
end

-- Strips color codes, player links and square brackets
function Util.StripMarkup(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]*:", ""):gsub("|r", "")
    s = s:gsub("|H.-|h(.-)|h", "%1")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^%[(.-)%]$", "%1")
    return s
end

function Util.UnitName(unit)
    local name, realm = Util.Call(UnitName, unit)
    if not Util.IsValidName(name) then return nil end
    if type(realm) ~= "string" or realm == "" then realm = nil end
    return name, realm
end

-- =========================================================
-- NAME + REALM
-- Every player in the ledger is stored as "Name-Realm" (realm without spaces/dashes,
-- in GetNormalizedRealmName format). Our own realm is not shown on screen.
-- =========================================================
local function NormalizeRealm(r)
    if type(r) ~= "string" then return nil end
    r = r:gsub("[%s%-]", "")
    if r == "" then return nil end
    return r
end

local myRealm = nil -- the realm never changes during a session: read once (retried if not found)
function Util.MyRealm()
    if myRealm then return myRealm end
    local r = GetNormalizedRealmName and Util.Call(GetNormalizedRealmName)
    if not r or r == "" then
        local _, realm = Util.Call(UnitFullName, "player")
        r = realm
    end
    myRealm = NormalizeRealm(r)
    return myRealm
end

-- "Name" or "Name-Realm" -> "Name-Realm". Without a realm: defaultRealm (or our own realm)
function Util.NormalizeName(n, defaultRealm)
    if type(n) ~= "string" then return nil end
    n = n:gsub("^%s+", ""):gsub("%s+$", "")
    local name, realm = n:match("^([^%-]+)%-(.+)$")
    if not name then
        name, realm = n, defaultRealm or Util.MyRealm()
    end
    if not Util.IsValidName(name) then return nil end
    realm = NormalizeRealm(realm)
    if not realm then return nil end
    return name .. "-" .. realm
end

function Util.MyFullName()
    return Util.NormalizeName(Util.UnitName("player"))
end

function Util.UnitFullName(unit)
    local name, realm = Util.UnitName(unit)
    if not name then return nil end
    return Util.NormalizeName(realm and (name .. "-" .. realm) or name)
end

function Util.ShortName(full)
    if type(full) ~= "string" then return nil end
    return full:match("^([^%-]+)") or full
end

function Util.RealmOf(full)
    return type(full) == "string" and full:match("^[^%-]+%-(.+)$") or nil
end

-- On screen: players from our own realm show just the name, others Name-Realm
function Util.DisplayName(full)
    if type(full) ~= "string" then return full end
    local realm = Util.RealmOf(full)
    if not realm or realm == Util.MyRealm() then return Util.ShortName(full) end
    return full
end

-- Shortens a string to at most maxBytes bytes, dropping a cut-off UTF-8 character
function Util.Truncate(s, maxBytes)
    if type(s) ~= "string" or #s <= maxBytes then return s end
    s = s:sub(1, maxBytes)
    local i = #s
    while i > 0 do
        local b = s:byte(i)
        if b < 0x80 then break end
        if b >= 0xC0 then
            local need = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or 2
            if (#s - i + 1) < need then s = s:sub(1, i - 1) end
            break
        end
        i = i - 1
    end
    return s
end

function Util.EnemyFaction(faction)
    if faction == "Alliance" then return "Horde" end
    if faction == "Horde" then return "Alliance" end
    return "Neutral"
end

-- =========================================================
-- DETERMINISM HELPERS
-- Lua's "<" string comparison can depend on the locale. Everywhere it affects the
-- result (killing blow choice, tie ordering) byte order is used instead:
-- clients in different languages compute the same table.
-- =========================================================
local byte = string.byte

function Util.ByteLess(a, b)
    if a == b then return false end
    local la, lb = #a, #b
    for i = 1, (la < lb and la or lb) do
        local x, y = byte(a, i), byte(b, i)
        if x ~= y then return x < y end
    end
    return la < lb
end

-- Polynomial hash (prime modulus, intermediate values below 2^53: no bit library needed)
local HP, HB = 4294967291, 1000003
Util.TWO32 = 4294967296
function Util.H32(s)
    local h = 2166136261
    for i = 1, #s do h = (h * HB + byte(s, i)) % HP end
    return (h * HB + #s) % HP
end

-- =========================================================
-- JOB SCHEDULER (coroutine)
-- Splits long computations into slices of a few ms per frame (1 ms in combat).
-- Note: Job.Yield must not be called from inside a pcall or a table.sort comparator.
-- =========================================================
local Job = {}
Util.Job = Job
local JOB_BUDGET_MS, JOB_BUDGET_COMBAT_MS = 3, 1
local runningJob = nil

function Job.Yield()
    local job = runningJob
    if not job or not debugprofilestop or coroutine.running() ~= job.co then return end
    if debugprofilestop() - job.started > job.budget then coroutine.yield() end
end

function Job.Start(name, fn, onDone)
    local job = { co = coroutine.create(fn) }
    local function step()
        job.started = debugprofilestop and debugprofilestop() or 0
        job.budget = Util.Call(UnitAffectingCombat, "player") and JOB_BUDGET_COMBAT_MS or JOB_BUDGET_MS
        runningJob = job
        local ok, err = coroutine.resume(job.co)
        runningJob = nil
        if not ok then
            Util.ReportError(name .. ": " .. tostring(err))
            if onDone then onDone(false) end
        elseif coroutine.status(job.co) == "dead" then
            if onDone then onDone(true) end
        else
            C_Timer.After(0, step)
        end
    end
    step()
end

-- =========================================================
-- STARTUP
-- =========================================================
local mainFrame = CreateFrame("Frame")

mainFrame:RegisterEvent("ADDON_LOADED")
mainFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

mainFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        self:UnregisterEvent("ADDON_LOADED")
        if addonTable.DB and addonTable.DB.Init then
            addonTable.DB.Init()
        end
        if addonTable.Sync and addonTable.Sync.Init then
            addonTable.Sync.Init()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if addonTable.DB and addonTable.DB.EnsurePlayerLoaded then
            addonTable.DB.EnsurePlayerLoaded()
        end
        if addonTable.Engine and addonTable.Engine.Init then
            addonTable.Engine.Init()
        end
        if addonTable.UI and addonTable.UI.Init then
            addonTable.UI.Init()
        end
    end
end)
