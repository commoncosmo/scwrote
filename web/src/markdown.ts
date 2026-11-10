import MarkdownIt from "markdown-it";

const md = new MarkdownIt({ html: true, linkify: true, typographer: false });
type Token = ReturnType<typeof md.parse>[number];

/** Block tokens that render as a single element rather than an open/close pair. */
const SELF_CONTAINED = new Set(["hr", "fence", "code_block"]);

function sourceAttrs(token: Token): string {
  const [start, end] = token.map!;
  return ` data-source-start="${start + 1}" data-source-end="${end}"`;
}

// Copy each block token's source lines onto the element it renders.
md.core.ruler.push("source_lines", (state) => {
  for (const token of state.tokens) {
    if (!token.map || token.hidden) continue;
    if (token.nesting === 1 || SELF_CONTAINED.has(token.type)) {
      token.attrSet("data-source-start", String(token.map[0] + 1));
      token.attrSet("data-source-end", String(token.map[1]));
    }
  }
  return true;
});

// Fences: mermaid becomes a diagram placeholder; others keep <pre><code>.
md.renderer.rules.fence = (tokens, idx) => {
  const token = tokens[idx];
  const lang = token.info.trim().split(/\s+/)[0] ?? "";
  if (lang === "mermaid") {
    return `<div class="mermaid"${sourceAttrs(token)}>${md.utils.escapeHtml(token.content)}</div>\n`;
  }
  const cls = lang ? ` class="language-${md.utils.escapeHtml(lang)}"` : "";
  return `<pre${sourceAttrs(token)}><code${cls}>${md.utils.escapeHtml(token.content)}</code></pre>\n`;
};

/** Markdown to HTML; block elements carry data-source-start/end (1-based, inclusive). */
export function renderMarkdown(text: string): string {
  return md.render(text);
}
