import { describe, expect, it } from "vitest";
import codeview from "../extensions/codeview.ts";

describe("package smoke", () => {
	it("exports the extension default function", () => {
		expect(typeof codeview).toBe("function");
	});
});
