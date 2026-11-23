// What a scenario file says about how it is played, on lines of their own at the start of a line:
//   --@locale deDE                               the game's tables in another language
//   --@login race=Human,class=WARRIOR            a character of its own (unless the runner was given one)
//   --@addons QuestieDB, MyAddon, ...            the addons it plays with (instead of the project's "load")
//   --@shards 4                                  split in parts that play side by side (its forShard(list))
//   --@interface light                           the simulator's own stand-in interface, not the game's whole one
//                                                (both kinds must work: an addon may be tried in either)
// A directive given twice: the last one counts.
import { readFileSync } from "node:fs";

export type ScenarioDirectives = {
  locale: string | null;
  login: string | null;
  addons: string[] | null;
  shards: number;
  /** "whole": the game's own interface (the settings' blizzardAddons); "light": the simulator's stand-ins */
  interface: "whole" | "light" | null;
};

export const readDirectives = (path: string): ScenarioDirectives => {
  const directives: ScenarioDirectives = {
    locale: null,
    login: null,
    addons: null,
    shards: 1,
    interface: null,
  };
  const text = readFileSync(path, "utf8").replace(/^﻿/, "");
  for (const line of text.split(/\r?\n/)) {
    if (!line.startsWith("--@")) continue;
    const value = (prefix: string): string | null =>
      line.startsWith(prefix) ? line.slice(prefix.length).trim() : null;
    const locale = value("--@locale ");
    if (locale !== null) directives.locale = locale;
    const login = value("--@login ");
    if (login !== null) directives.login = login;
    const addons = value("--@addons ");
    if (addons !== null) {
      directives.addons = addons
        .split(",")
        .map((name) => name.trim())
        .filter((name) => name !== "");
    }
    const shards = value("--@shards ");
    if (shards !== null) directives.shards = Math.max(1, Number.parseInt(shards, 10) || 1);
    const kind = value("--@interface ");
    if (kind === "light" || kind === "whole") directives.interface = kind;
  }
  return directives;
};
