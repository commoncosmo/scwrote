import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "..", "page.css"), "utf8");

/** The declarations of the rule whose selector is exactly `selector`. */
function rule(selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return css.match(new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`))?.[1] ?? "";
}

// nvim's default colors make the divider the text color, so code drawn on
// the divider would be invisible: code blocks take their own fill.
test("code blocks take the fill, not the divider", () => {
  expect(rule(":root")).toMatch(/--fill:\s*#[0-9a-f]{6};/);
  for (const selector of [".markdown code", ".markdown pre"]) {
    expect(rule(selector)).toMatch(/background:\s*var\(--fill\)/);
  }
});
