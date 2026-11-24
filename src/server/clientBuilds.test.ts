import { describe, expect, test } from "bun:test";
import { compareBuilds, readPatchVersions } from "./clientBuilds.ts";

describe("compareBuilds", () => {
  test("orders by each number in turn, not as text", () => {
    expect(compareBuilds("1.60.1.71091", "1.60.1.71037")).toBeGreaterThan(0);
    expect(compareBuilds("1.60.1.9999", "1.60.1.71037")).toBeLessThan(0);
    expect(compareBuilds("1.60.1.71037", "1.60.1.71037")).toBe(0);
    expect(["1.60.1.70938", "1.60.1.71091", "1.60.1.71037"].sort((a, b) => compareBuilds(b, a))).toEqual([
      "1.60.1.71091",
      "1.60.1.71037",
      "1.60.1.70938",
    ]);
  });
});

describe("readPatchVersions", () => {
  test("reads each region's build from Blizzard's table", () => {
    const text = [
      "Region!STRING:0|BuildConfig!HEX:16|CDNConfig!HEX:16|KeyRing!HEX:16|BuildId!DEC:4|VersionsName!String:0|ProductConfig!HEX:16",
      "## seqn = 4156561",
      "us|3cd5|651a||71091|1.60.1.71091|0d21",
      "eu|0aca|651a||71037|1.60.1.71037|0d21",
      "",
    ].join("\n");
    expect(readPatchVersions(text)).toEqual([
      { region: "us", build: "1.60.1.71091" },
      { region: "eu", build: "1.60.1.71037" },
    ]);
  });

  test("an answer without the columns gives none", () => {
    expect(readPatchVersions("<html>maintenance</html>")).toEqual([]);
  });
});
