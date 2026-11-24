-- The few entries of QuestieDB's data (GPL-3.0, github.com/Questie/QuestieDB) the simulator's own scenarios use,
-- copied as its Get returns them (recorded while they ran against QuestieDB). A new scenario's quest or creature is
-- added the same way: its fields as QuestieDB gives them. `localized`: another language's values, only those that
-- differ from the English.
local _, ns = ...

ns.data = {
    Item = {
        [3712] = {
            name = "Turtle Meat",
            npcDrops = {
                [1] = 2408,
                [2] = 2505,
                [3] = 4142,
                [4] = 4143,
                [5] = 4144,
                [6] = 4396,
                [7] = 4397,
                [8] = 4398,
                [9] = 4399,
                [10] = 4400,
                [11] = 4824,
                [12] = 4825,
                [13] = 4887,
                [14] = 5431,
                [15] = 5432,
                [16] = 6352,
                [17] = 6369,
                [18] = 7977,
                [19] = 8213,
                [20] = 13599,
                [21] = 13896,
                [22] = 14123,
                [23] = 14223,
            },
        },
        [3713] = {
            name = "Soothing Spices",
            npcDrops = { [1] = 2381, [2] = 4897 },
        },
        [5062] = {
            name = "Raptor Head",
        },
        [5087] = {
            name = "Plainstrider Beak",
        },
    },
    Npc = {
        [2381] = {
            name = "Micha Yance",
        },
        [2393] = {
            name = "Christoph Jeffcoat",
            questEnds = { [1] = 7321 },
            questStarts = { [1] = 7321 },
        },
        [2408] = {
            minLevel = 29,
            name = "Snapjaw",
            rank = 0,
        },
        [2505] = {
            name = "Saltwater Snapjaw",
        },
        [3111] = {
            factionID = 109,
            friendlyToFaction = nil,
            maxLevel = 7,
            maxLevelHealth = 1,
            minLevel = 6,
            minLevelHealth = 0,
            name = "Razormane Quilboar",
            rank = 0,
            subName = nil,
        },
        [3112] = {
            name = "Razormane Scout",
        },
        [3113] = {
            name = "Razormane Dustrunner",
        },
        [3114] = {
            factionID = 109,
            friendlyToFaction = nil,
            maxLevel = 10,
            maxLevelHealth = 1,
            minLevel = 9,
            minLevelHealth = 0,
            name = "Razormane Battleguard",
            rank = 0,
            subName = nil,
        },
        [3244] = {
            factionID = 189,
            friendlyToFaction = "AH",
            maxLevel = 12,
            maxLevelHealth = 1,
            minLevel = 11,
            minLevelHealth = 0,
            name = "Greater Plainstrider",
            questStarts = nil,
            rank = 0,
            subName = nil,
        },
        [3273] = {
            factionID = 130,
            friendlyToFaction = nil,
            maxLevel = 14,
            maxLevelHealth = 1,
            minLevel = 13,
            minLevelHealth = 0,
            name = "Kolkar Stormer",
            questStarts = nil,
            rank = 0,
            subName = nil,
        },
        [3338] = {
            name = "Sergra Darkthorn",
            questEnds = { [1] = 842, [2] = 844, [3] = 845, [4] = 860, [5] = 881, [6] = 903, [7] = 905 },
            questStarts = { [1] = 844, [2] = 845, [3] = 881, [4] = 903, [5] = 905, [6] = 3261 },
        },
        [3464] = {
            name = "Gazrog",
            questEnds = { [1] = 869, [2] = 1509, [3] = 3281 },
            questStarts = { [1] = 869, [2] = 1510, [3] = 3281 },
        },
        [4142] = {
            name = "Sparkleshell Tortoise",
        },
        [4143] = {
            name = "Sparkleshell Snapper",
        },
        [4144] = {
            name = "Sparkleshell Borer",
        },
        [4396] = {
            name = "Mudrock Tortoise",
        },
        [4397] = {
            name = "Mudrock Spikeshell",
        },
        [4398] = {
            name = "Mudrock Burrower",
        },
        [4399] = {
            name = "Mudrock Borer",
        },
        [4400] = {
            name = "Mudrock Snapjaw",
        },
        [4824] = {
            name = "Aku'mai Fisher",
        },
        [4825] = {
            name = "Aku'mai Snapjaw",
        },
        [4887] = {
            name = "Ghamoo-ra",
        },
        [4897] = {
            name = "Helenia Olden",
        },
        [5431] = {
            name = "Surf Glider",
        },
        [5432] = {
            name = "Giant Surf Glider",
        },
        [6352] = {
            name = "Coralshell Lurker",
        },
        [6369] = {
            name = "Coralshell Tortoise",
        },
        [7977] = {
            name = "Gammerita",
        },
        [8213] = {
            name = "Ironback",
        },
        [13599] = {
            name = "Stolid Snapjaw",
        },
        [13896] = {
            name = "Scalebeard",
        },
        [14123] = {
            name = "Steeljaw Snapper",
        },
        [14223] = {
            name = "Cranky Benj",
        },
    },
    Quest = {
        [837] = {
            name = "Encroachment",
            objectives = {
                [1] = {
                    [1] = { [1] = 3111, [3] = 0 },
                    [2] = { [1] = 3112, [3] = 0 },
                    [3] = {
                        [1] = 3113,
                        [3] = 0,
                    },
                    [4] = {
                        [1] = 3114,
                        [3] = 0,
                    },
                },
            },
            objectivesText = {
                [1] = "Kill 4 Razormane Quilboars, 4 Razormane Scouts, 4 Razormane Dustrunners and 4 Razormane Battleguards for Gar'Thok at Razor Hill.",
            },
            questLevel = 10,
            sourceItemId = 0,
            triggerEnd = nil,
            zoneOrSort = 14,
        },
        [844] = {
            name = "Plainstrider Menace",
            objectives = { [3] = { [1] = { [1] = 5087, [3] = 0 } } },
            objectivesText = {
                [1] = "Collect 7 Plainstrider Beaks and return them to Sergra Darkthorn in the Crossroads.",
            },
            questLevel = 12,
            sourceItemId = 0,
            triggerEnd = nil,
            zoneOrSort = 17,
        },
        [845] = {
            name = "The Zhevra",
            questLevel = 13,
        },
        [869] = {
            name = "Raptor Thieves",
            objectives = { [3] = { [1] = { [1] = 5062, [3] = 0 } } },
            objectivesText = { [1] = "Bring 12 Raptor Heads to Gazrog at the Crossroads." },
            questLevel = 13,
            sourceItemId = 0,
            startedBy = { [1] = { [1] = 3464 } },
            triggerEnd = nil,
            zoneOrSort = 17,
        },
        [881] = {
            name = "Echeyakee",
            questLevel = 16,
        },
        [903] = {
            name = "Prowlers of the Barrens",
            questLevel = 15,
        },
        [905] = {
            name = "The Angry Scytheclaws",
            questLevel = 17,
        },
        [1510] = {
            name = "News of Dogran",
            questLevel = 20,
        },
        [3261] = {
            name = "Jorn Skyseer",
            questLevel = 18,
        },
        [3281] = {
            name = "Stolen Silver",
            questLevel = 18,
        },
        [7321] = {
            name = "Soothing Turtle Bisque",
            objectives = { [3] = { [1] = { [1] = 3712, [3] = 0 }, [2] = { [1] = 3713, [3] = 0 } } },
            objectivesText = {
                [1] = "Bring 10 pieces of Turtle Meat and some Soothing Spices to Christoph Jeffcoat in Tarren Mill.",
            },
            questLevel = 31,
            sourceItemId = 0,
            triggerEnd = nil,
            zoneOrSort = -304,
        },
    },
}

ns.localized = {
    deDE = {
        Item = {
            [5087] = {
                name = "Ebenenschreiter-Schnabel",
            },
        },
        Quest = {
            [844] = {
                name = "Ebenenschreiter-Bedrohung",
                objectivesText = {
                    [1] = "Besorgt 7 Ebenenschreiterschnäbel und bringt sie Sergra Darkthorn in Crossroads.",
                },
            },
        },
    },
}
