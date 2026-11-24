// The renderer page: draws one file's text into the document and talks to the
// app through `window.scwrote` (called in) and the `scwrote` message handler
// (posted out). Nothing here reaches the network; user content stays static.
import { fieldAt, MAX_ROWS, parseDelimited } from "./csv";
import { blockForLine } from "./follow";
import { renderMarkdown } from "./markdown";
import { buildJsonTree, buildYamlTree, pathToLine, startsOpen, type TreeNode } from "./tree";

type Kind = "markdown" | "csv" | "tsv" | "mermaid" | "svg" | "json" | "yaml";
/** 1-based line, 0-based character column. */
interface Cursor { line: number; column: number }
/** `path` is the file's, for telling a new file from the one on screen. */
interface RenderRequest { kind: Kind; path: string; text: string; baseURL: string; cursor: Cursor }
type Command = "lineDown" | "lineUp" | "halfPageDown" | "halfPageUp" | "top" | "bottom" | "open" | "close" | "toggle";
/** Colors are CSS colors (`#rrggbb`); `fontFamily` is one family name; `fontSize` is in CSS pixels. */
interface Theme {
  background: string; foreground: string; dim: string; selection: string;
  accent: string; warning: string; divider: string; fill: string; fontFamily: string; fontSize: number; isDark: boolean;
}
type Message = { type: "rendered"; note?: string } | { type: "error"; message: string };

/** The parts of mermaid's browser build (`mermaid.min.js`) this page uses. */
interface Mermaid {
  initialize(config: Record<string, unknown>): void;
  parse(text: string): Promise<unknown>;
  render(id: string, text: string): Promise<{ svg: string }>;
}

declare global {
  interface Window {
    scwrote: {
      render(req: RenderRequest): Promise<void>;
      follow(cursor: Cursor): void;
      command(name: Command): void;
      setTheme(theme: Theme): void;
    };
    mermaid?: Mermaid;
    webkit?: { messageHandlers?: { scwrote?: { postMessage(message: Message): void } } };
  }
}

/** What is on screen, and how it follows the cursor and handles keys. */
interface View {
  follow?(cursor: Cursor): void;
  /** True when the view handled the command itself; otherwise the page scrolls. */
  command?(name: Command): boolean;
  /** Called when the content changes size. */
  relayout?(): void;
  /** Called when the view is replaced (or never shown). */
  dispose?(): void;
}

/** New content, built off-screen, waiting to replace what is shown. */
interface Built {
  root: Node;
  view: View;
  note?: string;
  /** A partial failure: the content is still shown, and this is posted as an error. */
  error?: string;
}

const content = document.getElementById("content")!;
const cursorBar = document.getElementById("cursor-bar")!;
const base = document.querySelector("base")!;

let view: View = {};
/** Increases with every render; a render whose number is stale has been superseded. */
let generation = 0;
let lastRequest: RenderRequest | null = null;
let lastCursor: Cursor = { line: 1, column: 0 };
/** The file on screen: the last one rendered, or that failed on first show. */
let shownPath: string | null = null;
/** Open/closed state of the shown file's JSON/YAML nodes by node path, kept across its re-renders. */
let treeOpen = new Map<string, boolean>();

function post(message: Message): void {
  window.webkit?.messageHandlers?.scwrote?.postMessage(message);
}

/** One line for the header. Multi-line parser errors keep their first and last lines. */
function messageOf(error: unknown): string {
  const raw = error instanceof Error ? error.message
    : typeof error === "string" ? error
    : String((error as { message?: unknown } | null)?.message ?? error);
  const lines = raw.split("\n").map(l => l.trim()).filter(l => l !== "");
  if (lines.length === 0) return "render failed";
  const first = lines[0];
  return first.endsWith(":") && lines.length > 1 ? `${first} ${lines[lines.length - 1]}` : first;
}

function element<K extends keyof HTMLElementTagNameMap>(tag: K, className?: string, text?: string): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}

// MARK: Rendering

async function render(req: RenderRequest): Promise<void> {
  const current = ++generation;
  const isCurrent = () => current === generation;
  lastRequest = req;
  lastCursor = req.cursor;
  // Tree nodes opened in another file mean nothing in this one.
  const open = req.path === shownPath ? treeOpen : new Map<string, boolean>();
  try {
    const built = await build(req, open, isCurrent);
    if (!built) return;
    if (!isCurrent()) { built.view.dispose?.(); return; }
    show(req.kind, built);
    shownPath = req.path;
    treeOpen = open;
    // A follow that came in while this was building is newer than req.cursor.
    follow(lastCursor);
    post(built.error !== undefined ? { type: "error", message: built.error }
      : built.note !== undefined ? { type: "rendered", note: built.note } : { type: "rendered" });
  } catch (error) {
    if (!isCurrent()) return;
    // Broken input keeps the last good render, but only of the same file:
    // another file's content must not stand in under this one's name.
    if (req.path !== shownPath) {
      show(req.kind, { root: document.createDocumentFragment(), view: {} });
      shownPath = req.path;
      treeOpen = open;
    }
    post({ type: "error", message: messageOf(error) });
  }
}

/** Throws to keep what is shown; returns null when superseded. */
async function build(req: RenderRequest, open: Map<string, boolean>, isCurrent: () => boolean): Promise<Built | null> {
  switch (req.kind) {
    case "markdown": return buildMarkdown(req, isCurrent);
    case "csv": return buildTable(req.text, ",");
    case "tsv": return buildTable(req.text, "\t");
    case "mermaid": return buildMermaidFile(req.text, isCurrent);
    case "svg": return buildSVG(req.text);
    case "json": return buildTree(buildJsonTree(req.text), open);
    case "yaml": return buildTree(buildYamlTree(req.text), open);
    default: throw new Error(`cannot render ${String((req as { kind: unknown }).kind)}`);
  }
}

function show(kind: Kind, built: Built): void {
  view.dispose?.();
  view = built.view;
  cursorBar.hidden = true;
  document.body.dataset.kind = kind;
  content.replaceChildren(built.root);
}

function follow(cursor: Cursor): void {
  lastCursor = cursor;
  view.follow?.(cursor);
}

new ResizeObserver(() => view.relayout?.()).observe(content);

// MARK: Markdown

async function buildMarkdown(req: RenderRequest, isCurrent: () => boolean): Promise<Built | null> {
  base.href = req.baseURL;
  const root = element("article", "markdown");
  root.innerHTML = renderMarkdown(req.text);
  // Raw HTML stays static: a <meta http-equiv=refresh> would navigate away.
  root.querySelectorAll("meta").forEach(m => m.remove());

  let error: string | undefined;
  for (const diagram of root.querySelectorAll<HTMLElement>("div.mermaid")) {
    const source = diagram.textContent ?? "";
    try {
      const svg = await renderDiagram(source);
      if (!isCurrent()) return null;
      diagram.innerHTML = svg;
    } catch (e) {
      if (!isCurrent()) return null;
      error ??= `diagram at line ${diagram.dataset.sourceStart}: ${messageOf(e)}`;
      diagram.classList.add("failed");
      diagram.replaceChildren(element("pre", undefined, source));
    }
  }
  return { root, view: markdownView(root), error };
}

function markdownView(root: HTMLElement): View {
  const elements = Array.from(root.querySelectorAll<HTMLElement>("[data-source-start]"));
  const blocks = elements.map(el => ({ start: Number(el.dataset.sourceStart), end: Number(el.dataset.sourceEnd) }));
  let marked: HTMLElement | null = null;

  const placeBar = () => {
    if (!marked) { cursorBar.hidden = true; return; }
    const rect = marked.getBoundingClientRect();
    cursorBar.style.top = `${rect.top + window.scrollY}px`;
    cursorBar.style.height = `${rect.height}px`;
    cursorBar.hidden = false;
  };
  return {
    follow(cursor) {
      marked?.classList.remove("cursor-block");
      const index = blockForLine(blocks, cursor.line);
      marked = index >= 0 ? elements[index] : null;
      if (!marked) { placeBar(); return; }
      marked.classList.add("cursor-block");
      const rect = marked.getBoundingClientRect();
      const fits = rect.top >= 0 && rect.bottom <= window.innerHeight;
      const tallAndVisible = rect.height > window.innerHeight && rect.top < window.innerHeight && rect.bottom > 0;
      if (!fits && !tallAndVisible) marked.scrollIntoView({ block: "center" });
      placeBar();
    },
    relayout: placeBar,
  };
}

let diagramCount = 0;

/** Renders mermaid source to SVG markup off-screen. */
async function renderDiagram(source: string): Promise<string> {
  const mermaid = window.mermaid;
  if (!mermaid) throw new Error("mermaid did not load");
  const id = `scwrote-diagram-${++diagramCount}`;
  try {
    return (await mermaid.render(id, source)).svg;
  } finally {
    // A failed render can leave its scratch element (or an error diagram) behind.
    document.getElementById(id)?.remove();
    document.getElementById(`d${id}`)?.remove();
  }
}

/** Same-page links scroll; with <base> at the file's folder they would otherwise navigate. */
document.addEventListener("click", event => {
  const link = (event.target as Element | null)?.closest?.("a[href]");
  const href = link?.getAttribute("href");
  if (!href?.startsWith("#")) return;
  event.preventDefault();
  let id = href.slice(1);
  try { id = decodeURIComponent(id); } catch { /* keep it as written */ }
  const target = id === "" ? content
    : document.getElementById(id) ?? document.getElementsByName(id)[0] ?? headingWithSlug(id);
  target?.scrollIntoView({ block: "start" });
});

/** GitHub-style heading anchors ("#see-also"), since headings carry no ids. */
function headingWithSlug(slug: string): HTMLElement | undefined {
  const wanted = slug.toLowerCase();
  const toSlug = (text: string) => text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s/g, "-");
  return Array.from(content.querySelectorAll<HTMLElement>("h1, h2, h3, h4, h5, h6"))
    .find(h => toSlug(h.textContent ?? "") === wanted);
}

// MARK: Mermaid and SVG files

async function buildMermaidFile(text: string, isCurrent: () => boolean): Promise<Built | null> {
  const root = element("div", "diagram");
  if (text.trim() !== "") {
    const mermaid = window.mermaid;
    if (!mermaid) throw new Error("mermaid did not load");
    await mermaid.parse(text);
    if (!isCurrent()) return null;
    root.innerHTML = await renderDiagram(text);
  }
  return { root, view: {} };
}

/** Shown through <img>, so scripts inside the SVG never run. */
async function buildSVG(text: string): Promise<Built> {
  const root = element("div", "image");
  if (text.trim() === "") return { root, view: {} };
  const url = URL.createObjectURL(new Blob([text], { type: "image/svg+xml" }));
  const img = element("img");
  img.alt = "";
  try {
    await new Promise<void>((resolve, reject) => {
      img.onload = () => resolve();
      img.onerror = () => reject(new Error("not a valid SVG image"));
      img.src = url;
    });
  } catch (error) {
    URL.revokeObjectURL(url);
    throw error;
  }
  root.append(img);
  return { root, view: { dispose: () => URL.revokeObjectURL(url) } };
}

// MARK: CSV and TSV

function buildTable(text: string, delimiter: "," | "\t"): Built {
  const table = parseDelimited(text, delimiter, MAX_ROWS);
  if (table.error !== undefined) throw new Error(table.error);

  const root = element("table", "records");
  const head = element("thead");
  const body = element("tbody");
  const rows = table.rows.map((fields, index) => {
    const tr = element("tr");
    tr.dataset.row = String(index);
    for (const field of fields) tr.append(element(index === 0 ? "th" : "td", undefined, field.text));
    (index === 0 ? head : body).append(tr);
    return tr;
  });
  root.append(head, body);

  const note = table.totalRows > table.rows.length
    ? `showing ${table.rows.length.toLocaleString("en-US")} of ${table.totalRows.toLocaleString("en-US")} rows`
    : undefined;

  let markedRow: HTMLElement | null = null;
  let markedCell: HTMLElement | null = null;
  const view: View = {
    follow(cursor) {
      markedRow?.classList.remove("cursor-row");
      markedCell?.classList.remove("cursor-cell");
      markedRow = markedCell = null;
      const at = fieldAt(table, cursor.line, cursor.column);
      if (!at) return;
      markedRow = rows[at.row];
      markedCell = markedRow.children[at.column] as HTMLElement | undefined ?? null;
      markedRow.classList.add("cursor-row");
      markedCell?.classList.add("cursor-cell");
      // Keep the sticky header from covering the row scrolled to.
      document.documentElement.style.scrollPaddingTop = `${head.offsetHeight}px`;
      (markedCell ?? markedRow).scrollIntoView({ block: "nearest", inline: "nearest" });
    },
    dispose() { document.documentElement.style.scrollPaddingTop = ""; },
  };
  return { root, view, note };
}

// MARK: JSON and YAML

function buildTree(result: { root: TreeNode | null; error?: string }, open: Map<string, boolean>): Built {
  if (result.error !== undefined) throw new Error(result.error);
  const tree = new TreeView(result.root, open);
  return { root: tree.element, view: tree };
}

/** Nested rows with disclosure triangles; children are built when first opened. */
class TreeView implements View {
  readonly element = element("div", "tree");
  private readonly nodes = new Map<string, { node: TreeNode; depth: number; el: HTMLElement }>();
  private selected: string | null = null;

  /** `open` holds which nodes are open, by path; the view keeps it up to date. */
  constructor(private readonly root: TreeNode | null, private readonly open: Map<string, boolean>) {
    if (root) this.element.append(this.build(root, 0));
    this.element.addEventListener("click", event => {
      const path = (event.target as Element).closest(".row")?.parentElement?.dataset.path;
      if (path === undefined) return;
      this.select(path);
      this.setOpen(path, !this.open.get(path));
    });
  }

  follow(cursor: Cursor): void {
    if (!this.root) return;
    const paths = pathToLine(this.root, cursor.line);
    for (const path of paths.slice(0, -1)) this.setOpen(path, true);
    this.select(paths[paths.length - 1]);
  }

  command(name: Command): boolean {
    const rows = this.visiblePaths();
    if (rows.length === 0) return true;
    const index = this.selected === null ? -1 : rows.indexOf(this.selected);
    const moveTo = (i: number) => this.select(rows[Math.max(0, Math.min(rows.length - 1, i))]);
    switch (name) {
      case "lineDown": moveTo(index + 1); break;
      case "lineUp": moveTo(index < 0 ? 0 : index - 1); break;
      case "halfPageDown": moveTo(index + this.halfPageRows()); break;
      case "halfPageUp": moveTo(index - this.halfPageRows()); break;
      case "top": moveTo(0); break;
      case "bottom": moveTo(rows.length - 1); break;
      case "open": if (this.selected !== null) this.setOpen(this.selected, true); break;
      case "close": if (this.selected !== null) this.setOpen(this.selected, false); break;
      case "toggle": if (this.selected !== null) this.setOpen(this.selected, !this.open.get(this.selected)); break;
    }
    return true;
  }

  private build(node: TreeNode, depth: number): HTMLElement {
    const el = element("div", node.kind === "scalar" ? "node" : "node container");
    el.dataset.path = node.path;
    const row = element("div", "row");
    row.append(element("span", "twisty"));
    if (node.key !== null) row.append(element("span", "key", node.key));
    if (node.kind === "scalar") {
      const value = node.value ?? "";
      row.append(element("span", value.startsWith('"') ? "value string" : "value", value));
    } else {
      const [open, close] = node.kind === "object" ? ["{", "}"] : ["[", "]"];
      row.append(element("span", "summary", `${open}${node.count ?? 0}${close}`));
    }
    el.append(row);
    this.nodes.set(node.path, { node, depth, el });
    if (node.kind !== "scalar") {
      const open = this.open.get(node.path) ?? startsOpen(node, depth);
      this.setOpen(node.path, open);
    }
    return el;
  }

  private setOpen(path: string, open: boolean): void {
    const entry = this.nodes.get(path);
    if (!entry || entry.node.kind === "scalar") return;
    this.open.set(path, open);
    entry.el.classList.toggle("open", open);
    if (open && !entry.el.querySelector(":scope > .children")) {
      const children = element("div", "children");
      for (const child of entry.node.children) children.append(this.build(child, entry.depth + 1));
      entry.el.append(children);
    }
  }

  private select(path: string): void {
    if (this.selected !== null) this.nodes.get(this.selected)?.el.classList.remove("selected");
    const entry = this.nodes.get(path);
    this.selected = entry ? path : null;
    if (!entry) return;
    entry.el.classList.add("selected");
    entry.el.firstElementChild!.scrollIntoView({ block: "nearest" });
  }

  /** Paths of the rows not hidden inside a closed node, top to bottom. */
  private visiblePaths(): string[] {
    const paths: string[] = [];
    const walk = (node: TreeNode) => {
      paths.push(node.path);
      if (node.kind !== "scalar" && this.open.get(node.path)) node.children.forEach(walk);
    };
    if (this.root) walk(this.root);
    return paths;
  }

  private halfPageRows(): number {
    const rowHeight = (this.element.querySelector(".row") as HTMLElement | null)?.offsetHeight || 1;
    return Math.max(1, Math.floor(window.innerHeight / 2 / rowHeight));
  }
}

// MARK: Keys

function command(name: Command): void {
  if (view.command?.(name)) return;
  const line = 1.5 * parseFloat(getComputedStyle(content).fontSize);
  const halfPage = window.innerHeight / 2;
  switch (name) {
    case "lineDown": window.scrollBy({ top: line }); break;
    case "lineUp": window.scrollBy({ top: -line }); break;
    case "halfPageDown": window.scrollBy({ top: halfPage }); break;
    case "halfPageUp": window.scrollBy({ top: -halfPage }); break;
    case "top": window.scrollTo({ top: 0 }); break;
    case "bottom": window.scrollTo({ top: document.documentElement.scrollHeight }); break;
    case "open": case "close": case "toggle": break;
  }
}

// MARK: Theme

let theme: Theme | null = null;

/** A CSS font-family value for one family name, with monospace fallbacks. */
function fontFamily(name: string): string {
  return `"${name.replace(/["\\]/g, "\\$&")}", ui-monospace, monospace`;
}

function configureMermaid(): void {
  window.mermaid?.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: "base",
    ...(theme && {
      fontFamily: fontFamily(theme.fontFamily),
      themeVariables: {
        darkMode: theme.isDark,
        background: theme.background,
        mainBkg: theme.selection,
        primaryColor: theme.selection,
        primaryTextColor: theme.foreground,
        primaryBorderColor: theme.accent,
        nodeBorder: theme.accent,
        secondaryColor: theme.fill,
        secondaryTextColor: theme.foreground,
        tertiaryColor: theme.background,
        lineColor: theme.dim,
        textColor: theme.foreground,
        noteBkgColor: theme.fill,
        noteTextColor: theme.foreground,
        fontFamily: fontFamily(theme.fontFamily),
        fontSize: `${theme.fontSize}px`,
      },
    }),
  });
}

function setTheme(next: Theme): void {
  theme = next;
  const style = document.documentElement.style;
  const vars: [string, string][] = [
    ["--bg", next.background], ["--fg", next.foreground], ["--dim", next.dim],
    ["--selection", next.selection], ["--accent", next.accent], ["--warning", next.warning],
    ["--divider", next.divider], ["--fill", next.fill],
    ["--font", fontFamily(next.fontFamily)], ["--font-size", `${next.fontSize}px`],
  ];
  for (const [name, value] of vars) style.setProperty(name, value);
  style.colorScheme = next.isDark ? "dark" : "light";
  configureMermaid();
  // Diagrams bake their colors into the SVG; draw them again in the new ones.
  const hasDiagrams = lastRequest?.kind === "mermaid" || content.querySelector(".mermaid") !== null;
  if (lastRequest && hasDiagrams) void render({ ...lastRequest, cursor: lastCursor });
}

configureMermaid();
window.scwrote = { render, follow, command, setTheme };
