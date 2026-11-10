import { afterAll, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const out = mkdtempSync(join(tmpdir(), "scwrote-preview-"));
afterAll(() => rmSync(out, { recursive: true, force: true }));

test("build writes the page into the output folder", () => {
  const result = Bun.spawnSync([process.execPath, "run", "build.ts", out], { cwd: join(import.meta.dir, "..") });
  expect(result.stderr.toString()).toBe("");
  expect(result.exitCode).toBe(0);
  for (const name of ["index.html", "page.js", "page.css", "mermaid.min.js"]) {
    expect(existsSync(join(out, name))).toBe(true);
  }
  const html = readFileSync(join(out, "index.html"), "utf8");
  const scriptSrc = html.match(/script-src[^;"]*/)?.[0];
  expect(scriptSrc).toContain("script-src scwrote-app:");
  expect(scriptSrc).not.toContain("unsafe-inline");
  expect(scriptSrc).not.toContain("unsafe-eval");
});
