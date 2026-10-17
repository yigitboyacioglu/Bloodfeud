local addonName, addonTable = ...

-- =========================================================
-- ZONE TITLES (retail: Midnight open-world zones)
-- This file is different for retail and Forever; everything else reads it.
--   key  : internal id (never shown, must stay the same between versions)
--   map  : uiMapID of the zone. Its sub-maps (cities, caves, ...) count as part of it.
--   name : fallback name (the client's own zone name is shown when available)
-- Find a map id in game with /bf zone.
-- =========================================================
addonTable.TitleZones = {
    { key = "eversong",  map = 2395, name = "Eversong Woods",
      Alliance = "Butcher of Silvermoon",         Horde = "Silvermoon's Champion" },
    { key = "zulaman",   map = 2437, name = "Zul'Aman",
      Alliance = "Conqueror of Zul'Aman",         Horde = "Zul'Aman's Chosen" },
    { key = "voidstorm", map = 2405, name = "Voidstorm",
      Alliance = "Slayer of Voidstorm",           Horde = "Voidstorm's Executioner" },
    { key = "harandar",  map = 2412, name = "Harandar",
      Alliance = "Warden of Harandar",            Horde = "Terror of Harandar" },
    { key = "coiled",    map = 2512, name = "Coiled Isles",
      Alliance = "Sovereign of the Coiled Isles", Horde = "Reaver of the Coiled Isles" },
}
