-- A short session in the shape the AddonSim Recorder addon saves (SavedVariables/AddonSimRecorder.lua): an Undead
-- mage accepts Plainstrider Menace near the Crossroads, fights and kills a Greater Plainstrider, loots a beak,
-- and walks on. Used by scenarios/replay.lua.
AddonSimRecording = {
    sessions = {
        {
            character = {
                name = "Simmy",
                realm = "Simland",
                race = "Scourge",
                class = "MAGE",
                level = 14,
                faction = "Horde",
            },
            locale = "enUS",
            client = "1.60.1",
            build = "70938",
            startedAt = "2026-11-16 21:30",
            entries = {
                {
                    t = 0,
                    e = "START",
                    a = {},
                    level = 14,
                    position = { uiMapId = 1413, x = 0.52, y = 0.31, facing = 0 },
                },
                {
                    t = 1,
                    e = "QUEST_ACCEPTED",
                    a = { 844 },
                    level = 14,
                    position = { uiMapId = 1413, x = 0.52, y = 0.31 },
                    questLog = {
                        {
                            questId = 844,
                            isComplete = false,
                            objectives = { { type = "item", fulfilled = 0, required = 7 } },
                        },
                    },
                },
                {
                    t = 3,
                    e = "POSITION",
                    a = {},
                    level = 14,
                    position = { uiMapId = 1413, x = 0.515, y = 0.305, facing = 1.2 },
                },
                {
                    t = 4,
                    e = "PLAYER_TARGET_CHANGED",
                    a = { false },
                    level = 14,
                    position = { uiMapId = 1413, x = 0.515, y = 0.305 },
                    target = {
                        guid = "Creature-0-1-0-1-3244-0000ABCDEF",
                        name = "Greater Plainstrider",
                        isDead = false,
                        isTappedByOthers = false,
                        canAttack = true,
                    },
                },
                { t = 4.1, e = "PLAYER_REGEN_DISABLED", a = {}, level = 14 },
                {
                    t = 9,
                    e = "UNIT_DIED",
                    a = { "Creature-0-1-0-1-3244-0000ABCDEF" },
                    level = 14,
                    target = {
                        guid = "Creature-0-1-0-1-3244-0000ABCDEF",
                        name = "Greater Plainstrider",
                        isDead = true,
                        isTappedByOthers = false,
                        canAttack = true,
                    },
                },
                { t = 9.2, e = "PLAYER_REGEN_ENABLED", a = {}, level = 14 },
                {
                    t = 11,
                    e = "QUEST_LOG_UPDATE",
                    a = {},
                    level = 14,
                    questLog = {
                        {
                            questId = 844,
                            isComplete = false,
                            objectives = { { type = "item", fulfilled = 1, required = 7 } },
                        },
                    },
                },
                {
                    t = 14,
                    e = "POSITION",
                    a = {},
                    level = 14,
                    position = { uiMapId = 1413, x = 0.505, y = 0.29, facing = 1.4 },
                },
                { t = 15, e = "STOP", a = {}, level = 14 },
            },
        },
    },
}
