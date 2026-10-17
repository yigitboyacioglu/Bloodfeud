local addonName, addonTable = ...
addonTable.Sync = {}

local Util = addonTable.Util
local NormalizeName = Util.NormalizeName

-- =========================================================
-- NETWORK
-- Records from the kill ledger (db.lua: E = death, C = claim, D = dispute) are spread to
-- everyone using the addon. Channels:
--   * NET   : hidden "BloodfeudForeverNet" channel + guild (everyone in the same faction)
--   * GROUP : party (joins both factions in a cross-faction party)
--   * BN    : Battle.net friends with the addon (faction difference doesn't matter)
-- A client that hears a new record relays it to the other channels (bridge). To keep
-- several people from relaying the same record there is a short random wait; if the
-- record is heard on that channel meanwhile, the relay is cancelled.
-- On login missed records are requested with "SYNC"; a single person answers.
--
-- BASE (folded old weeks, db.lua): the base hash is announced inside PING/PONG.
-- If at least 2 different players announce a base different from ours (or our base
-- is empty) that base is requested (BREQ), arrives in parts (BASE) and is applied if the hash matches.
-- A single person can't change anyone's table with a fake base.
--
-- 12.x: addon messages can be locked down during instances/encounters/PvP matches
-- (C_ChatInfo.InChatMessagingLockdown). Messages wait in the queue meanwhile.
-- =========================================================

local PREFIX = "BFF_SYNC"
local BULK_PREFIX = "BFF_BULK"     -- catch-up data uses its own prefix (so it doesn't eat the live messages' throttle)
local PROTOCOL = 7                 -- 7: points / 10, no death spacing (bases from older versions are not adopted)
local CHANNEL_NAME = "BloodfeudForeverNet"
local MAX_MSG_LEN = 250            -- SendAddonMessage limit is 255 bytes
local FORWARD_DELAY_MIN, FORWARD_DELAY_MAX = 0.5, 2.5
local FORWARD_MAX_AGE = 3600       -- seconds: records older than this (from catch-up) are not relayed again
local CATCHUP_OVERLAP = 3 * 3600   -- seconds: catch-up starts this far before the last time we were online
                                   -- (so records arriving late from the other faction are caught too)
local OFFER_DELAY_MIN, OFFER_DELAY_MAX = 0.5, 4
local MAX_RESPONDERS = 2           -- at most this many people answer a catch-up request (if one is incomplete the other fills in)
local PING_INTERVAL = 60
local DIRECT_PING_INTERVAL = 30
local CHANNEL_RETRY = 30
local SEEN_TTL = 600
local QUEUE_LIMIT = 60
local BULK_QUEUE_LIMIT = 5000
local QUEUE_MAX_TRIES = 30
-- base
local ANNOUNCE_INTERVAL = 900      -- seconds: the base hash is announced every so often (+ random jitter)
local BASE_ANN_TTL = 1800          -- seconds: how long a player's announcement stays valid
local BASE_REQ_TIMEOUT = 120       -- seconds: if a requested base isn't complete by then, ask someone else
local BASE_FAIL_BACKOFF = 600      -- seconds: a base that failed verification isn't requested again for this long
local BASE_SERVE_COOLDOWN = 300    -- seconds: the base is sent to the same person at most this often
local BASE_MAX_PARTS = 2000
-- receive limit (transport only, doesn't affect scoring)
local RECV_PER_MIN = 200
local MUTE_SECONDS = 1800

local activeUsers = {}         -- ["Name-Realm"] = protocol version (lower than PROTOCOL = old version)
local userTitles = {}          -- ["Name-Realm"] = the zone title key they chose to show (from PING/PONG)
local bnUsers = {}             -- [gameAccountID] = true : Battle.net friends with the addon
local lastPong = {}
local lastDirectPing = {}
local lastGroupPing = -1000
local seen = {}                -- [record line] = { time, keys = { [network] = true } }
local pendingOffers = {}       -- [requester] = number of OFFERs heard : waiting to answer a catch-up
local initialized = false
local loginDone = false
local channelWasJoined = false
local queue, bulkQueue = {}, {}
local queueTicker = nil
local baseAnn = {}             -- [Name-Realm] = { B, n, h, at, bnetID, sourceKey, sender }
local baseReq = nil            -- requested base: { B, h, peer, at, parts, got, total }
local baseFailed = {}          -- [hash] = time : base that failed verification / never completed
local lastBaseServe = {}
local chanReply = nil
local nextAnnounce = 0
local recvCount, muted = {}, {}
local dbg = {
    sent = 0, received = 0, bnSent = 0, bnReceived = 0, queued = 0, dropped = 0,
    newRecords = 0, forwarded = 0, catchupSent = 0, catchupReceived = 0, legacy = 0, disputes = 0, lastResult = nil,
    baseReq = 0, baseServed = 0, baseRecv = 0, mutedMsgs = 0,
}

local RESULT = (Enum and Enum.SendAddonMessageResult) or {}
local RESULT_THROTTLE = RESULT.AddonMessageThrottle or 3
local RESULT_CHANNEL_THROTTLE = RESULT.ChannelThrottle or 8
local RESULT_LOCKDOWN = RESULT.AddOnMessageLockdown or 11
local BNET_CLIENT = BNET_CLIENT_WOW or "WoW"

local function IsActive()
    return not (BloodfeudForeverDB and BloodfeudForeverDB.isActive == false)
end

local function InLockdown()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, res = pcall(C_ChatInfo.InChatMessagingLockdown)
        return ok and res == true
    end
    return false
end

local function NotifyUI()
    if addonTable.UI and addonTable.UI.RequestUpdate then
        addonTable.UI.RequestUpdate()
    end
end

local function RandomDelay(minD, maxD)
    return minD + math.random() * (maxD - minD)
end

-- =========================================================
-- SENDING (queue + throttle/lockdown protection)
-- =========================================================
-- Returns: true = done (sent or permanent error), false = retry later
local function RawSend(item)
    local ok, res
    if item.kind == "BN" then
        local fn = (C_BattleNet and C_BattleNet.SendGameData) or BNSendGameData
        if not fn then return true end
        ok, res = pcall(fn, item.target, item.prefix, item.msg)
        if ok then dbg.bnSent = dbg.bnSent + 1 end
    else
        if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return true end
        ok, res = pcall(C_ChatInfo.SendAddonMessage, item.prefix, item.msg, item.kind, item.target)
        if ok then dbg.sent = dbg.sent + 1 end
    end
    if not ok then
        Util.ReportError(res)
        return true
    end
    dbg.lastResult = res
    if res == RESULT_THROTTLE or res == RESULT_CHANNEL_THROTTLE or res == RESULT_LOCKDOWN then
        return false
    end
    return true
end

-- Send from the queue: live messages first, catch-up data one message per second
local function FlushQueue()
    while #queue > 0 and not InLockdown() do
        local item = queue[1]
        if RawSend(item) then
            table.remove(queue, 1)
        else
            item.tries = item.tries + 1
            if item.tries >= QUEUE_MAX_TRIES then
                table.remove(queue, 1)
                dbg.dropped = dbg.dropped + 1
            end
            break
        end
    end
    if #queue == 0 and #bulkQueue > 0 and not InLockdown() then
        local item = bulkQueue[1]
        if RawSend(item) then
            table.remove(bulkQueue, 1)
            dbg.catchupSent = dbg.catchupSent + 1
        else
            item.tries = item.tries + 1
            if item.tries >= QUEUE_MAX_TRIES then
                table.remove(bulkQueue, 1)
                dbg.dropped = dbg.dropped + 1
            end
        end
    end
    if #queue == 0 and #bulkQueue == 0 and queueTicker then
        queueTicker:Cancel()
        queueTicker = nil
    end
end

local function EnsureTicker()
    if not queueTicker then
        queueTicker = C_Timer.NewTicker(1, FlushQueue)
    end
end

local function Send(kind, msg, target)
    local item = { prefix = PREFIX, kind = kind, msg = msg, target = target, tries = 0 }
    if not InLockdown() and #queue == 0 and RawSend(item) then
        return
    end
    if #queue >= QUEUE_LIMIT then
        dbg.dropped = dbg.dropped + 1
        return
    end
    table.insert(queue, item)
    dbg.queued = dbg.queued + 1
    EnsureTicker()
end

local function SendBulk(kind, msg, target)
    if #bulkQueue >= BULK_QUEUE_LIMIT then
        dbg.dropped = dbg.dropped + 1
        return
    end
    table.insert(bulkQueue, { prefix = BULK_PREFIX, kind = kind, msg = msg, target = target, tries = 0 })
    EnsureTicker()
end

-- =========================================================
-- CHANNELS
-- =========================================================
local function ChannelId()
    if not GetChannelName then return nil end
    local ok, id = pcall(GetChannelName, CHANNEL_NAME)
    if ok and type(id) == "number" and id > 0 then return id end
    return nil
end

local function HideChannelFromChat()
    local remove = ChatFrame_RemoveChannel or (ChatFrameUtil and ChatFrameUtil.RemoveChannel)
    if not remove then return end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then pcall(remove, frame, CHANNEL_NAME) end
    end
end

local function JoinNetworkChannel()
    if ChannelId() then
        HideChannelFromChat()
        return
    end
    if JoinTemporaryChannel then
        pcall(JoinTemporaryChannel, CHANNEL_NAME)
    elseif JoinChannelByName then
        pcall(JoinChannelByName, CHANNEL_NAME)
    end
    HideChannelFromChat()
end

local function GroupKind()
    local instanceCategory = _G.LE_PARTY_CATEGORY_INSTANCE or 2
    if IsInGroup(instanceCategory) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function SendToNet(msg, bulk)
    local fn = bulk and SendBulk or Send
    local chan = ChannelId()
    if chan then fn("CHANNEL", msg, chan) end
    if IsInGuild() then fn("GUILD", msg) end
end

local function SendToGroup(msg, bulk)
    local kind = GroupKind()
    if kind then (bulk and SendBulk or Send)(kind, msg) end
end

-- Network keys: "NET" (channel + guild), "GROUP", "BN:<id>", "WHISPER"
local function NetworkKey(channel, bnetID)
    if bnetID then return "BN:" .. tostring(bnetID) end
    if channel == "CHANNEL" or channel == "GUILD" then return "NET" end
    if channel == "PARTY" or channel == "RAID" or channel == "INSTANCE_CHAT" then return "GROUP" end
    return "WHISPER"
end

local function Targets()
    local list = {}
    if ChannelId() or IsInGuild() then table.insert(list, { key = "NET" }) end
    if GroupKind() then table.insert(list, { key = "GROUP" }) end
    for id in pairs(bnUsers) do table.insert(list, { key = "BN:" .. tostring(id), bnID = id }) end
    return list
end

local function SendToTarget(target, msg)
    if target.key == "NET" then
        SendToNet(msg)
    elseif target.key == "GROUP" then
        SendToGroup(msg)
    elseif target.bnID then
        Send("BN", msg, target.bnID)
    end
end

-- Answer a player over the path we heard them on (BN / party / whisper)
local function SendToPeer(msg, bulk, sender, sourceKey, bnetID)
    if bnetID then
        (bulk and SendBulk or Send)("BN", msg, bnetID)
    elseif sourceKey == "GROUP" then
        SendToGroup(msg, bulk) -- a whisper may not reach a cross-faction party member
    else
        (bulk and SendBulk or Send)("WHISPER", msg, sender)
    end
end

-- =========================================================
-- BATTLE.NET (friends on the opposite faction)
-- =========================================================
local function IsSameProject(info)
    return not (WOW_PROJECT_ID and info.wowProjectID and info.wowProjectID ~= WOW_PROJECT_ID)
end

-- All online WoW Battle.net friends on the same game version: { gameAccountID, ... }
local function OnlineBNetGameAccounts()
    local list = {}
    if not (C_BattleNet and BNGetNumFriends and C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendGameAccountInfo) then
        return list
    end
    local ok, numFriends = pcall(BNGetNumFriends)
    if not ok or type(numFriends) ~= "number" then return list end
    for i = 1, numFriends do
        local okN, numAccounts = pcall(C_BattleNet.GetFriendNumGameAccounts, i)
        for j = 1, (okN and numAccounts or 0) do
            local okI, info = pcall(C_BattleNet.GetFriendGameAccountInfo, i, j)
            if okI and type(info) == "table" and info.isOnline and info.clientProgram == BNET_CLIENT
                and IsSameProject(info) and info.gameAccountID then
                table.insert(list, info.gameAccountID)
            end
        end
    end
    return list
end

local function FindBNetGameAccount(name, guid)
    if not C_BattleNet then return nil end

    if type(guid) == "string" and C_BattleNet.GetGameAccountInfoByGUID then
        local ok, info = pcall(C_BattleNet.GetGameAccountInfoByGUID, guid)
        if ok and type(info) == "table" and info.gameAccountID and info.isOnline ~= false and IsSameProject(info) then
            return info.gameAccountID
        end
    end

    name = NormalizeName(name)
    if not name or not C_BattleNet.GetGameAccountInfoByID then return nil end
    for _, id in ipairs(OnlineBNetGameAccounts()) do
        local ok, info = pcall(C_BattleNet.GetGameAccountInfoByID, id)
        if ok and type(info) == "table" and type(info.characterName) == "string"
            and NormalizeName(info.characterName, info.realmName) == name then
            return id
        end
    end
    return nil
end

-- Returns: "Name-Realm"
local function BNetSenderName(gameAccountID)
    if not (C_BattleNet and C_BattleNet.GetGameAccountInfoByID) then return nil end
    local ok, info = pcall(C_BattleNet.GetGameAccountInfoByID, gameAccountID)
    if not ok or type(info) ~= "table" then return nil end
    if info.clientProgram and info.clientProgram ~= BNET_CLIENT then return nil end
    if type(info.characterName) ~= "string" or info.characterName == "" then return nil end
    return NormalizeName(info.characterName, info.realmName)
end

-- =========================================================
-- SPREADING (bridge)
-- Seen-tracking is by canonical line: the "winning" version of the same id can spread too.
-- =========================================================
local function MarkSeen(line, key)
    local s = seen[line]
    if not s then
        s = { time = GetTime(), keys = {} }
        seen[line] = s
    end
    s.keys[key] = true
end

local function HasSeen(line, key)
    local s = seen[line]
    return s ~= nil and s.keys[key] == true
end

local function CleanupSeen()
    local now = GetTime()
    for line, s in pairs(seen) do
        if (now - s.time) > SEEN_TTL then seen[line] = nil end
    end
end

-- A record heard from NET (or a catch-up whisper) is not sent back to NET
local function ShouldForward(sourceKey, targetKey)
    if sourceKey == targetKey then return false end
    if (sourceKey == "NET" or sourceKey == "WHISPER") and targetKey == "NET" then return false end
    return true
end

local function ScheduleForward(line, sourceKey)
    if not IsActive() then return end
    for _, target in ipairs(Targets()) do
        if ShouldForward(sourceKey, target.key) and not HasSeen(line, target.key) then
            C_Timer.After(RandomDelay(FORWARD_DELAY_MIN, FORWARD_DELAY_MAX), function()
                if HasSeen(line, target.key) then return end -- someone else relayed it / already there
                MarkSeen(line, target.key)
                dbg.forwarded = dbg.forwarded + 1
                SendToTarget(target, line)
            end)
        end
    end
end

-- A record written by our own client: add it to the ledger, send it to everyone.
-- The ledger converts it to canonical form: we store exactly the line that goes to others.
function addonTable.Sync.Publish(kind, rec)
    if type(rec) ~= "table" then return end
    local id, isNew, line = addonTable.DB.AddRecord(kind, rec)
    if not id or not isNew then return end
    addonTable.DB.MarkMine(id)
    NotifyUI()

    if not IsActive() then return end
    for _, target in ipairs(Targets()) do
        MarkSeen(line, target.key)
        SendToTarget(target, line)
    end
end

-- A single record from the network
local function ReceiveRecord(msg, sourceKey)
    local kind, rec = addonTable.DB.Decode(msg)
    if not kind then return false end
    local id, isNew, line = addonTable.DB.AddRecord(kind, rec)
    if not id then return false end
    MarkSeen(line, sourceKey)
    if isNew then
        dbg.newRecords = dbg.newRecords + 1
        if (GetServerTime() - (tonumber(rec.t) or 0)) <= FORWARD_MAX_AGE then
            ScheduleForward(line, sourceKey)
        end
        -- A record in our name that we didn't write: dispute it (cancelled for everyone)
        local dispute = addonTable.DB.CheckForgery(kind, id)
        if dispute then
            dbg.disputes = dbg.disputes + 1
            addonTable.Sync.Publish("D", dispute)
        end
    end
    return isNew
end

-- =========================================================
-- CATCH-UP (records missed while offline, requested on login)
-- =========================================================
local function SendRecordsTo(records, kind, target)
    local batch, size = {}, 0
    local function FlushBatch()
        if #batch == 0 then return end
        local msg = table.concat(batch, ";")
        if kind == "NET" then
            SendToNet(msg, true)
        elseif kind == "GROUP" then
            SendToGroup(msg, true)
        else
            SendBulk(kind, msg, target)
        end
        batch, size = {}, 0
    end
    for _, r in ipairs(records) do
        local msg = r.line
        if size + #msg + 1 > MAX_MSG_LEN then FlushBatch() end
        table.insert(batch, msg)
        size = size + #msg + 1
    end
    FlushBatch()
end

function addonTable.Sync.RequestCatchUp()
    if not IsActive() then return end
    -- Based on when we were last online, not on our latest record: a single live kill
    -- arriving at login must not make us skip the days we were offline
    local lastOnline = addonTable.DB.GetPreviousSessionEnd()
    local since = lastOnline > 0 and math.max(0, lastOnline - CATCHUP_OVERLAP) or 0
    local msg = "SYNC:" .. PROTOCOL .. ":" .. since
    SendToNet(msg)
    SendToGroup(msg)
    for id in pairs(bnUsers) do Send("BN", msg, id) end
end

local function HandleSyncRequest(since, sender, sourceKey, bnetID)
    if not IsActive() then return end
    if not addonTable.DB.HasRecordsSince(since) then return end

    if bnetID then
        SendRecordsTo(addonTable.DB.GetRecordsSince(since), "BN", bnetID)
        return
    end

    -- Request from the channel/guild/party: wait a random time; if MAX_RESPONDERS people
    -- haven't taken it on meanwhile, we answer too
    local requester = NormalizeName(sender)
    if not requester or pendingOffers[requester] then return end
    pendingOffers[requester] = 0
    C_Timer.After(RandomDelay(OFFER_DELAY_MIN, OFFER_DELAY_MAX), function()
        local offers = pendingOffers[requester]
        pendingOffers[requester] = nil
        if not offers or offers >= MAX_RESPONDERS then return end
        local offer = "OFFER:" .. requester
        SendToNet(offer)
        SendToGroup(offer)
        local records = addonTable.DB.GetRecordsSince(since)
        if sourceKey == "GROUP" then
            SendRecordsTo(records, "GROUP") -- a whisper may not reach a cross-faction party member
        else
            SendRecordsTo(records, "WHISPER", sender)
        end
    end)
end

-- =========================================================
-- BASE: ANNOUNCE, VOTE, TRANSFER
-- =========================================================
-- "PING:<proto>:<B>:<n>:<hash>" (just "PING:<proto>" if the base isn't ready)
-- Zone title key: letters, digits, underscore
local function ValidTitleKey(key)
    return type(key) == "string" and #key <= 24 and key:match("^[%w_]+$") ~= nil
end

-- "KIND:protocol:B:n:hash:title" (base fields empty while our base isn't ready; title = chosen zone title key)
local function PingMsg(kind)
    local B, n, h, ready = addonTable.DB.GetBaseInfo()
    local title = addonTable.DB.GetActiveTitle()
    if not ValidTitleKey(title) then title = "" end
    if not ready or B == 0 then
        if title == "" then return kind .. ":" .. PROTOCOL end
        return kind .. ":" .. PROTOCOL .. ":::" .. ":" .. title
    end
    return kind .. ":" .. PROTOCOL .. ":" .. tostring(B) .. ":" .. tostring(n) .. ":" .. tostring(h) .. ":" .. title
end

local function SendBaseRequest(a)
    dbg.baseReq = dbg.baseReq + 1
    local msg = "BREQ:" .. tostring(a.B) .. ":" .. tostring(a.h)
    if a.sourceKey == "GROUP" and not a.bnetID then msg = msg .. ":" .. a.name end -- everyone in the party hears it: name the target
    SendToPeer(msg, false, a.sender, a.sourceKey, a.bnetID)
end

-- Check the announcements: if the majority's base differs from ours, request it
local function EvaluateBase()
    if not IsActive() then return end
    local myB, myN, myH, ready = addonTable.DB.GetBaseInfo()
    if not ready or myB == 0 then return end
    local now = GetTime()

    if baseReq and (now - baseReq.at) > BASE_REQ_TIMEOUT then
        baseFailed[baseReq.h] = now - BASE_FAIL_BACKOFF + BASE_REQ_TIMEOUT -- short wait, then from someone else
        baseReq = nil
    end
    if baseReq then return end

    local cands = {}
    local function cand(h, n)
        local c = cands[h]
        if not c then
            c = { h = h, n = n, votes = 0, peers = {} }
            cands[h] = c
        end
        return c
    end
    if myN > 0 then cand(myH, myN).votes = 1 end -- our empty base doesn't count as a vote
    for name, a in pairs(baseAnn) do
        if (now - a.at) > BASE_ANN_TTL then
            baseAnn[name] = nil
        elseif a.B == myB then
            local c = cand(a.h, a.n)
            c.votes = c.votes + 1
            table.insert(c.peers, a)
        end
    end

    local best
    for _, c in pairs(cands) do
        if not best or c.votes > best.votes
            or (c.votes == best.votes and (c.n > best.n or (c.n == best.n and c.h > best.h))) then
            best = c
        end
    end
    if not best or best.h == myH or #best.peers == 0 then return end
    if best.votes < 2 and myN > 0 then return end -- don't replace a non-empty base on a single person's word
    if baseFailed[best.h] and (now - baseFailed[best.h]) < BASE_FAIL_BACKOFF then return end

    -- Request it from the most recent announcer
    table.sort(best.peers, function(x, y) return x.at > y.at end)
    local a = best.peers[1]
    baseReq = { B = myB, h = best.h, at = now, parts = {}, got = 0, total = nil, peer = a.name }
    SendBaseRequest(a)
end

local function NoteBase(name, sender, sourceKey, bnetID, B, n, h)
    B, n, h = tonumber(B), tonumber(n), tonumber(h)
    if not (B and n and h) then return end
    baseAnn[name] = { name = name, sender = sender, sourceKey = sourceKey, bnetID = bnetID,
                      B = B, n = n, h = h, at = GetTime() }
    -- If someone on the channel announces the same base as ours, our pending channel reply is unnecessary
    local myB, _, myH = addonTable.DB.GetBaseInfo()
    if chanReply and B == myB and h == myH then chanReply.heard = chanReply.heard + 1 end
    EvaluateBase()
end

-- If a player pinging the channel has a different base (e.g. a new user): wait a random time and,
-- unless two people announced our base meanwhile, PONG the channel (if everyone answered, the channel would flood)
local function ScheduleChannelPong()
    if chanReply then return end
    chanReply = { heard = 0 }
    C_Timer.After(RandomDelay(1, 6), function()
        local r = chanReply
        chanReply = nil
        if not r or r.heard >= 2 or not IsActive() then return end
        local chan = ChannelId()
        if chan then Send("CHANNEL", PingMsg("PONG"), chan) end
    end)
end

local function HandleBaseRequest(B, h, target, sender, sourceKey, bnetID, requester)
    if not IsActive() then return end
    if target and target ~= "" and target ~= Util.MyFullName() then return end
    local myB, _, myH, ready = addonTable.DB.GetBaseInfo()
    if not ready or tonumber(B) ~= myB or tonumber(h) ~= myH then return end
    local now = GetTime()
    if lastBaseServe[requester] and (now - lastBaseServe[requester]) < BASE_SERVE_COOLDOWN then return end
    lastBaseServe[requester] = now
    dbg.baseServed = dbg.baseServed + 1

    -- Join the lines with ~ and split into 250-byte parts
    local head = "BASE:" .. tostring(myB) .. ":" .. tostring(myH) .. ":"
    local room = MAX_MSG_LEN - #head - 10 -- room for "<i>:<total>:"
    local chunks, buf, size = {}, {}, 0
    for _, line in ipairs(addonTable.DB.GetBaseLines()) do
        if #line <= room then
            if size + #line + 1 > room and #buf > 0 then
                chunks[#chunks + 1] = table.concat(buf, "~")
                buf, size = {}, 0
            end
            buf[#buf + 1] = line
            size = size + #line + 1
        end
    end
    if #buf > 0 then chunks[#chunks + 1] = table.concat(buf, "~") end
    if #chunks == 0 or #chunks > BASE_MAX_PARTS then return end
    for i, payload in ipairs(chunks) do
        SendToPeer(head .. i .. ":" .. #chunks .. ":" .. payload, true, sender, sourceKey, bnetID)
    end
end

local function HandleBaseChunk(message)
    local B, h, i, total, payload = message:match("^BASE:(%d+):(%d+):(%d+):(%d+):(.*)$")
    B, h, i, total = tonumber(B), tonumber(h), tonumber(i), tonumber(total)
    local r = baseReq
    if not (r and B == r.B and h == r.h and i and total) then return end
    if total < 1 or total > BASE_MAX_PARTS or i < 1 or i > total or (r.total and r.total ~= total) then return end
    r.total = total
    r.at = GetTime() -- data is flowing: extend the timeout
    if r.parts[i] then return end
    r.parts[i] = payload
    r.got = r.got + 1
    if r.got < total then return end

    local lines = {}
    for k = 1, total do
        for line in r.parts[k]:gmatch("[^~]+") do lines[#lines + 1] = line end
    end
    baseReq = nil
    baseFailed[h] = GetTime() -- if verified, the base changes and this hash becomes ours anyway
    dbg.baseRecv = dbg.baseRecv + 1
    addonTable.DB.OfferBase(B, h, lines)
end

-- db.lua: the base changed (fold or received from the network): announce it shortly
function addonTable.Sync.OnBaseChanged()
    if not loginDone then return end
    nextAnnounce = math.min(nextAnnounce, GetTime() + RandomDelay(5, 30))
end

-- =========================================================
-- RECEIVING
-- =========================================================
-- Anyone sending more than RECV_PER_MIN messages a minute is ignored for a while (flood protection)
local function RecvAllowed(name)
    local now = GetTime()
    local m = muted[name]
    if m then
        if now < m then dbg.mutedMsgs = dbg.mutedMsgs + 1; return false end
        muted[name] = nil
    end
    local r = recvCount[name]
    if not r or (now - r.since) > 60 then
        r = { n = 0, since = now }
        recvCount[name] = r
    end
    r.n = r.n + 1
    if r.n > RECV_PER_MIN then
        muted[name] = now + MUTE_SECONDS
        recvCount[name] = nil
        return false
    end
    return true
end

local function Reply(msg, sender, bnetID)
    if bnetID then
        Send("BN", msg, bnetID)
    else
        Send("WHISPER", msg, sender)
    end
end

local function HandleMessage(message, channel, sender, bnetID)
    local cleanSender = NormalizeName(sender)
    if not cleanSender or cleanSender == Util.MyFullName() then return end
    if not RecvAllowed(cleanSender) then return end

    local sourceKey = NetworkKey(channel, bnetID)
    local msgType, arg1, arg2, arg3, arg4, arg5 = strsplit(":", message)

    if msgType == "E" or msgType == "C" or msgType == "D" then
        activeUsers[cleanSender] = math.max(activeUsers[cleanSender] or 0, PROTOCOL)
        if bnetID then bnUsers[bnetID] = true end
        if ReceiveRecord(message, sourceKey) then NotifyUI() end
        return
    end

    if msgType == "PING" or msgType == "PONG" then
        local version = tonumber(arg1) or 1
        activeUsers[cleanSender] = version
        userTitles[cleanSender] = ValidTitleKey(arg5) and arg5 or nil
        if bnetID and version >= PROTOCOL then bnUsers[bnetID] = true end
        if version >= PROTOCOL and arg2 then
            NoteBase(cleanSender, sender, sourceKey, bnetID, arg2, arg3, arg4)
        end
        if msgType == "PING" and IsActive() then
            if channel == "CHANNEL" then
                -- Channel pings normally get no answer; one person answers someone with a different base
                local myB, _, myH, ready = addonTable.DB.GetBaseInfo()
                if ready and version >= PROTOCOL and tonumber(arg2) == myB and tonumber(arg4) ~= myH then
                    ScheduleChannelPong()
                end
            else
                local now = GetTime()
                if not lastPong[cleanSender] or (now - lastPong[cleanSender]) > 5 then
                    lastPong[cleanSender] = now
                    Reply(PingMsg("PONG"), sender, bnetID)
                end
            end
        end
        return
    end

    if msgType == "SYNC" then
        activeUsers[cleanSender] = math.max(activeUsers[cleanSender] or 0, tonumber(arg1) or PROTOCOL)
        if bnetID then bnUsers[bnetID] = true end
        HandleSyncRequest(tonumber(arg2) or 0, sender, sourceKey, bnetID)
        return
    end

    if msgType == "OFFER" then
        local requester = NormalizeName(arg1)
        if requester and pendingOffers[requester] then
            pendingOffers[requester] = pendingOffers[requester] + 1 -- someone else is answering
        end
        return
    end

    if msgType == "BREQ" then
        HandleBaseRequest(arg1, arg2, arg3, sender, sourceKey, bnetID, cleanSender)
        return
    end

    if msgType == "K2" or msgType == "KILL" then
        -- Old version message: incompatible with the new ledger, just mark the sender as "should update"
        activeUsers[cleanSender] = math.min(activeUsers[cleanSender] or 2, 2)
        dbg.legacy = dbg.legacy + 1
    end
end

local function HandleBulk(message, channel, sender, bnetID)
    local cleanSender = NormalizeName(sender)
    if not cleanSender or cleanSender == Util.MyFullName() then return end
    if not RecvAllowed(cleanSender) then return end
    activeUsers[cleanSender] = math.max(activeUsers[cleanSender] or 0, PROTOCOL)
    if bnetID then bnUsers[bnetID] = true end

    if message:sub(1, 5) == "BASE:" then
        HandleBaseChunk(message)
        return
    end

    local sourceKey = NetworkKey(channel, bnetID)
    local anyNew = false
    for part in string.gmatch(message, "[^;]+") do
        dbg.catchupReceived = dbg.catchupReceived + 1
        if ReceiveRecord(part, sourceKey) then anyNew = true end
    end
    if anyNew then NotifyUI() end
end

-- =========================================================
-- PING / USER DISCOVERY
-- =========================================================
function addonTable.Sync.BroadcastPing(force)
    if not IsActive() then return end
    local now = GetTime()
    if not force and (now - lastGroupPing) < PING_INTERVAL then return end
    lastGroupPing = now
    local msg = PingMsg("PING")
    SendToNet(msg)
    SendToGroup(msg)
end

-- Ping online Battle.net friends: those with the addon answer with PONG and become bridges
local function PingBNetFriends()
    if not IsActive() then return end
    local msg = PingMsg("PING")
    for _, id in ipairs(OnlineBNetGameAccounts()) do
        Send("BN", msg, id)
    end
end

-- Base announcement: channel/guild/party + Battle.net friends known to have the addon
local function Announce()
    if not IsActive() then return end
    addonTable.Sync.BroadcastPing(true)
    local msg = PingMsg("PING")
    for id in pairs(bnUsers) do Send("BN", msg, id) end
end

function addonTable.Sync.SendDirectPing(unit)
    if not unit or not IsActive() then return end
    local Call = Util.Call
    if not Call(UnitExists, unit) or not Call(UnitIsPlayer, unit) then return end

    local name = Util.UnitName(unit)
    if not name or name == UnitName("player") then return end

    local now = GetTime()
    if lastDirectPing[name] and (now - lastDirectPing[name]) < DIRECT_PING_INTERVAL then return end
    lastDirectPing[name] = now

    local msg = PingMsg("PING")
    local myFaction, faction = Call(UnitFactionGroup, "player"), Call(UnitFactionGroup, unit)
    if faction and myFaction and faction ~= myFaction then
        -- Whispers don't reach the opposite faction: only ask if they're a Battle.net friend
        local id = FindBNetGameAccount(name, Call(UnitGUID, unit))
        if id then Send("BN", msg, id) end
        return
    end

    Send("WHISPER", msg, name) -- WoW Forever has no servers: whisper by character name
end

function addonTable.Sync.IsUserActive(name)
    local full = NormalizeName(name)
    if not full then return false end
    if full == Util.MyFullName() then return true end
    return activeUsers[full] ~= nil
end

-- The zone title key a player chose to show (nil = not known / no choice). Only used if they hold it.
function addonTable.Sync.GetUserTitle(name)
    local full = NormalizeName(name)
    if full and full == Util.MyFullName() then return addonTable.DB.GetActiveTitle() end
    return full and userTitles[full]
end

-- Our title choice changed: announce it once a few seconds later (switching quickly sends one ping)
local titleAnnouncePending = false
function addonTable.Sync.OnTitleChanged()
    if titleAnnouncePending then return end
    titleAnnouncePending = true
    C_Timer.After(3, function()
        titleAnnouncePending = false
        Announce()
    end)
end

-- PROTOCOL = this version, lower = old version, nil = unknown
function addonTable.Sync.GetUserVersion(name)
    local full = NormalizeName(name)
    if full and full == Util.MyFullName() then return PROTOCOL end
    return full and activeUsers[full]
end

-- =========================================================
-- STARTUP
-- =========================================================
local function OnLogin()
    JoinNetworkChannel()
    PingBNetFriends()
    C_Timer.After(3, function()
        channelWasJoined = ChannelId() ~= nil
        addonTable.Sync.BroadcastPing(true)
    end)
    -- Let the BN friends' PONGs arrive, then request what we missed
    C_Timer.After(8, function() addonTable.Sync.RequestCatchUp() end)
    nextAnnounce = GetTime() + ANNOUNCE_INTERVAL * RandomDelay(0.5, 1)
end

local function Housekeep()
    CleanupSeen()
    local now = GetTime()
    for name, r in pairs(recvCount) do
        if (now - r.since) > 60 then recvCount[name] = nil end
    end
    if not loginDone then return end
    addonTable.DB.TouchSession()
    if not ChannelId() then
        JoinNetworkChannel()
    elseif not channelWasJoined then
        channelWasJoined = true
        addonTable.Sync.BroadcastPing(true)
        addonTable.Sync.RequestCatchUp()
    end
    if now >= nextAnnounce then
        nextAnnounce = now + ANNOUNCE_INTERVAL * RandomDelay(0.8, 1.2)
        Announce()
    end
    EvaluateBase()
end

function addonTable.Sync.Init()
    if initialized then return end
    initialized = true

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        C_ChatInfo.RegisterAddonMessagePrefix(BULK_PREFIX)
    end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("BN_CHAT_MSG_ADDON")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")

    frame:SetScript("OnEvent", function(self, event, prefix, message, channel, sender)
        if event == "PLAYER_ENTERING_WORLD" then
            if not loginDone then
                loginDone = true
                addonTable.DB.TouchSession()
                C_Timer.After(2, OnLogin)
            end
            return
        end

        if prefix ~= PREFIX and prefix ~= BULK_PREFIX then return end
        if not Util.Readable(message) or type(message) ~= "string" then return end
        local handler = (prefix == BULK_PREFIX) and HandleBulk or HandleMessage

        local ok, err
        if event == "BN_CHAT_MSG_ADDON" then
            -- Here the 4th argument is the sender's Battle.net gameAccountID
            local name = BNetSenderName(sender)
            if not name then return end
            dbg.bnReceived = dbg.bnReceived + 1
            ok, err = pcall(handler, message, "BN", name, sender)
        else
            if not Util.Readable(sender) or type(sender) ~= "string" then return end
            if not Util.Readable(channel) then channel = nil end
            dbg.received = dbg.received + 1
            ok, err = pcall(handler, message, channel, sender, nil)
        end
        if not ok then
            Util.ReportError(err)
        end
    end)

    -- Retry if we couldn't join the channel; if we just joined, announce ourselves and request what we missed
    C_Timer.NewTicker(CHANNEL_RETRY, function()
        local ok, err = pcall(Housekeep)
        if not ok then Util.ReportError(err) end
    end)
end

function addonTable.Sync.PrintDebug()
    local users, old = 0, {}
    for name, version in pairs(activeUsers) do
        users = users + 1
        if version < PROTOCOL then table.insert(old, name) end
    end
    local bn = 0
    for _ in pairs(bnUsers) do bn = bn + 1 end
    print(string.format("  Network: channel %s | guild %s | party %s | BN bridges: %d",
        ChannelId() and "|cFF00FF00connected|r" or "|cFFFF3333not joined|r",
        IsInGuild() and "yes" or "no", GroupKind() or "no", bn))
    print(string.format("  Sync: sent %d (BN %d) | received %d (BN %d) | new records %d | forwarded %d | catch-up sent %d / received %d",
        dbg.sent, dbg.bnSent, dbg.received, dbg.bnReceived, dbg.newRecords, dbg.forwarded, dbg.catchupSent, dbg.catchupReceived))
    print(string.format("  Queue: %d live / %d catch-up | dropped %d | last result: %s | forged records in your name (disputed): %d | muted msgs: %d",
        #queue, #bulkQueue, dbg.dropped, tostring(dbg.lastResult), dbg.disputes, dbg.mutedMsgs))

    local myB, _, myH = addonTable.DB.GetBaseInfo()
    local same, other = 0, 0
    for _, a in pairs(baseAnn) do
        if a.B == myB and a.h == myH then same = same + 1 elseif a.B == myB then other = other + 1 end
    end
    print(string.format("  Base sync: peers agreeing %d / different %d | requests %d | received %d | served %d%s",
        same, other, dbg.baseReq, dbg.baseRecv, dbg.baseServed,
        baseReq and string.format(" | downloading %d/%s", baseReq.got, tostring(baseReq.total or "?")) or ""))
    print(string.format("  Addon users: %d%s", users,
        #old > 0 and (" | OUTDATED VERSION (should update): " .. table.concat(old, ", ")) or ""))
end
