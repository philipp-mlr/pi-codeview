import { describe, expect, it } from "vitest";
import piNvim from "../extensions/pi-nvim.ts";

describe("package smoke", () => {
	it("exports the extension default function", () => {
		expect(typeof piNvim).toBe("function");
	});
});
