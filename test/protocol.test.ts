import { describe, expect, it } from "vitest";
import { LineDecoder, PROTOCOL_VERSION, encode } from "../extensions/protocol.ts";

describe("protocol", () => {
  it("LineDecoder handles split and multiple lines", () => {
    const d = new LineDecoder();
    expect(d.push('{"a":1}\n{"b"')).toEqual([{ a: 1 }]);
    expect(d.push(':2}\n{"c":3}\n')).toEqual([{ b: 2 }, { c: 3 }]);
    expect(d.push("")).toEqual([]);
  });
  it("encode adds trailing newline", () => {
    expect(encode({ a: 1 })).toBe('{"a":1}\n');
    expect(PROTOCOL_VERSION).toBe(2);
  });
});
