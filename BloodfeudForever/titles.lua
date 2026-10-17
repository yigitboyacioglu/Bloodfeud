local addonName, addonTable = ...

-- =========================================================
-- ZONE TITLES (WoW Forever: classic world PvP hotspots + capitals)
-- This file is different for retail and Forever; everything else reads it.
--   key  : internal id (never shown, must stay the same between versions)
--   map  : uiMapID of the zone (classic ids). Its sub-maps count as part of it.
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
    { key = "orgrimmar",     map = 1454, name = "Orgrimmar",
      Alliance = "Bane of Orgrimmar",       Horde = "Defender of Orgrimmar" },
    { key = "stormwind",     map = 1453, name = "Stormwind City",
      Alliance = "Defender of Stormwind",   Horde = "Bane of Stormwind" },
}
