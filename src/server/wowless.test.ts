import { describe, expect, test } from "bun:test";
import { formatPythonFloat, keepEmpty, parseScalar, parseYaml, toPythonJson } from "./wowless.ts";

describe("YAML reader", () => {
  test("mappings, lists and the empty values wowless uses", () => {
    const yaml = [
      "# a comment",
      "C_Test:",
      "  GetThing:",
      "    inputs:",
      "    - name: id",
      "      type: number",
      "    - name: 'quoted: key'",
      "    outputs:",
      "      - one",
      "      - 2",
      "    stub:",
      "  C_StoreSecure:",
      "'10': ten",
      "2: two",
      "list:",
      "  -",
      "    - nested",
      '  - "esc\\taped\\x41\\u00e9"',
    ].join("\r\n");
    const value = keepEmpty(parseYaml(yaml));
    expect(toPythonJson(value)).toBe(
      '{"C_Test":{"GetThing":{"inputs":[{"name":"id","type":"number"},{"name":"quoted: key"}],' +
        '"outputs":["one",2],"stubnil":true},"C_StoreSecure":true},"10":"ten","2":"two",' +
        '"list":[["nested"],"esc\\tapedAé"]}',
    );
  });

  test("scalars", () => {
    expect(parseScalar("~")).toBeNull();
    expect(parseScalar("'it''s'")).toBe("it's");
    expect(parseScalar("true")).toBe(true);
    expect(parseScalar("-12")).toBe(-12);
    expect(parseScalar("12345678901234567890")).toBe(12345678901234567890n);
    expect(toPythonJson(parseScalar("1.0"))).toBe("1.0");
    expect(parseScalar("1.2.3")).toBe("1.2.3");
  });

  test("a line it does not understand is an error", () => {
    expect(() => parseYaml("a: 1\n: nope")).toThrow();
  });
});

test("floats print as Python's repr", () => {
  const cases: [number, string][] = [
    [1, "1.0"],
    [0.5, "0.5"],
    [-0, "-0.0"],
    [1e16, "1e+16"],
    [1234567890123456.0, "1234567890123456.0"],
    [0.0001, "0.0001"],
    [0.00001, "1e-05"],
    [1.5e-7, "1.5e-07"],
    [7e74, "7e+74"],
    [0.1 + 0.2, "0.30000000000000004"],
    [123.456, "123.456"],
    [Number.POSITIVE_INFINITY, "Infinity"],
  ];
  for (const [value, expected] of cases) expect(formatPythonFloat(value)).toBe(expected);
});
