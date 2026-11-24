// WoW: Forever (client 1.60, game type Camelot): the classic classes, races and colours, as its tables and
// RAID_CLASS_COLORS give them
import type { Flavour } from "./types.ts";

export const FOREVER: Flavour = {
  id: "forever",
  clientName: "WoW: Forever",
  shortName: "Forever",
  maxLevel: 60,
  classes: [
    { file: "WARRIOR", name: "Warrior", color: "#C69B6D" },
    { file: "PALADIN", name: "Paladin", color: "#F48CBA" },
    { file: "HUNTER", name: "Hunter", color: "#AAD372" },
    { file: "ROGUE", name: "Rogue", color: "#FFF468" },
    { file: "PRIEST", name: "Priest", color: "#FFFFFF" },
    { file: "SHAMAN", name: "Shaman", color: "#0070DD" },
    { file: "MAGE", name: "Mage", color: "#3FC7EB" },
    { file: "WARLOCK", name: "Warlock", color: "#8788EE" },
    { file: "DRUID", name: "Druid", color: "#FF7C0A" },
  ],
  races: [
    { file: "Human", name: "Human", faction: "Alliance" },
    { file: "Dwarf", name: "Dwarf", faction: "Alliance" },
    { file: "NightElf", name: "Night Elf", faction: "Alliance" },
    { file: "Gnome", name: "Gnome", faction: "Alliance" },
    { file: "Orc", name: "Orc", faction: "Horde" },
    { file: "Scourge", name: "Undead", faction: "Horde" },
    { file: "Tauren", name: "Tauren", faction: "Horde" },
    { file: "Troll", name: "Troll", faction: "Horde" },
  ],
  factions: {
    Alliance: { name: "Alliance", color: "#4A7DFF" },
    Horde: { name: "Horde", color: "#E0352B" },
    Neutral: { name: "Neutral", color: "#B5A36A" },
  },
  qualities: [
    { name: "Poor", color: "#9D9D9D" },
    { name: "Common", color: "#FFFFFF" },
    { name: "Uncommon", color: "#1EFF00" },
    { name: "Rare", color: "#0070DD" },
    { name: "Epic", color: "#A335EE" },
    { name: "Legendary", color: "#FF8000" },
    { name: "Artifact", color: "#E6CC80" },
    { name: "Heirloom", color: "#00CCFF" },
  ],
  colors: {
    money: { gold: "#F2CF4A", silver: "#C7CDD4", copper: "#C9773D" },
  },
  instanceTypes: [
    { id: "party", name: "Dungeon" },
    { id: "raid", name: "Raid" },
    { id: "pvp", name: "Battleground" },
  ],
};
