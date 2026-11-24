import { expect, test } from "bun:test";
import { defaultSettings, readProjectAddons, type StoredSettings } from "./settings.ts";

test("each project's addons are read back by its folder; anything malformed is left out", () => {
  const settings = {
    ...defaultSettings(),
    projectAddons: { "C:\\Work\\A": ["QuestieDB", "Spoken"], "C:\\Work\\B": "not a list", "C:\\Work\\C": [1, 2] },
  } as StoredSettings;
  expect(readProjectAddons(settings)).toEqual({ "C:\\Work\\A": ["QuestieDB", "Spoken"] });
  expect(readProjectAddons(defaultSettings() as StoredSettings)).toEqual({});
});
