import { describe, expect, test } from "bun:test";
import { parseInlineAtlas } from "./text.ts";

describe("inline atlases", () => {
  test("the game's markup, with the colon before the name (CreateAtlasMarkup)", () => {
    expect(parseInlineAtlas(":gamepad-xbox1-buttonx-normal:30:30:0:0", 12)).toEqual({
      name: "gamepad-xbox1-buttonx-normal",
      w: 30,
      h: 30,
    });
  });

  test("height, then width", () => {
    expect(parseInlineAtlas(":questlog-icon:16:24", 12)).toEqual({ name: "questlog-icon", w: 24, h: 16 });
  });

  test("no size: the line's height, square", () => {
    expect(parseInlineAtlas(":questlog-icon:0:0", 14)).toEqual({ name: "questlog-icon", w: 14, h: 14 });
    expect(parseInlineAtlas("questlog-icon", 14)).toEqual({ name: "questlog-icon", w: 14, h: 14 });
  });
});
