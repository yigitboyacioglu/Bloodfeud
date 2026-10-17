local addonName, addonTable = ...

-- =========================================================
-- ZONE TITLES (Classic Era / Season of Discovery / Hardcore: world PvP hotspots + capitals)
-- This file is different for every game version; everything else reads it.
--   key  : internal id (never shown, must stay the same between versions)
--   map  : uiMapID of the zone (Classic Era ids). Its sub-maps count as part of it.
--   name : fallback name (the client's own zone name is shown when available)
-- Names avoid the classic honor rank titles (Knight, Champion, General, Warlord, ...).
-- Find a map id in game with /bf zone.
-- =========================================================
addonTable.TitleZones = {
    { key = "stranglethorn", map = 1434, name = "Stranglethorn Vale",
      Alliance = "Terror of Stranglethorn", Horde = "Stranglethorn's Headhunter" },
    { key = "hillsbrad",     map = 1424, name = "Hillsbrad Foothills",
      Alliance = "Avenger of Southshore",   Horde = "Reaper of Tarren Mill" },
    { key = "ashenvale",     map = 1440, name = "Ashenvale",
      Alliance = "Sentinel of Ashenvale",   Horde = "Warsong Ravager" },
    { key = "arathi",        map = 1417, name = "Arathi Highlands",
      Alliance = "Shield of Stromgarde",    Horde = "Fury of Hammerfall" },
    -- Level 60 zones
    { key = "easternplaguelands", map = 1423, name = "Eastern Plaguelands",
      Alliance = "Crusader of the Plaguelands", Horde = "Blight of the Plaguelands" },
    { key = "burningsteppes",     map = 1428, name = "Burning Steppes",
      Alliance = "Breaker of Blackrock",        Horde = "Warbringer of the Steppes" },
    { key = "silithus",           map = 1451, name = "Silithus",
      Alliance = "Duneslayer of Silithus",      Horde = "Sandreaver of Silithus" },
    { key = "winterspring",       map = 1452, name = "Winterspring",
      Alliance = "Frostblade of Winterspring",  Horde = "Winterspring Stalker" },
    { key = "felwood",            map = 1448, name = "Felwood",
      Alliance = "Purifier of Felwood",         Horde = "Corruptor of Felwood" },
    -- Capitals
    { key = "orgrimmar",     map = 1454, name = "Orgrimmar",
      Alliance = "Bane of Orgrimmar",       Horde = "Defender of Orgrimmar" },
    { key = "stormwind",     map = 1453, name = "Stormwind City",
      Alliance = "Defender of Stormwind",   Horde = "Bane of Stormwind" },
}
