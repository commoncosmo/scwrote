import { expect, test } from "bun:test";
import { renderMarkdown } from "../src/markdown";

test("blocks carry their source lines", () => {
  const html = renderMarkdown("# Title\n\nPara one\nstill one\n\n- a\n- b\n");
  expect(html).toContain('<h1 data-source-start="1" data-source-end="1">');
  expect(html).toContain('<p data-source-start="3" data-source-end="4">');
  expect(html).toContain('<li data-source-start="7" data-source-end="7">');
});
test("table rows carry lines", () => {
  const html = renderMarkdown("| a |\n|---|\n| 1 |\n| 2 |\n");
  expect(html).toContain('<tr data-source-start="4" data-source-end="4">');
});
test("mermaid fences become diagrams", () => {
  const html = renderMarkdown("```mermaid\ngraph TD; A-->B\n```\n");
  expect(html).toMatch(/<div class="mermaid" data-source-start="1" data-source-end="3">graph TD; A--&gt;B\n?<\/div>/);
});
test("raw HTML is passed through (the page's CSP keeps it static)", () => {
  expect(renderMarkdown("<details><summary>x</summary>y</details>")).toContain("<details>");
});
