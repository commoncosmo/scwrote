import { parseTree, printParseErrorCode, type Node as JsonNode, type ParseError } from "jsonc-parser";
import { isAlias, isMap, isScalar, isSeq, parseAllDocuments } from "yaml";

export interface TreeNode {
  /** Stable id: "$", "$.a", "$.a[2]", "$['odd key']". */
  path: string;
  /** Property name or "[i]"; null for the root. */
  key: string | null;
  kind: "object" | "array" | "scalar";
  /** Scalars: display text (strings quoted, as in JSON). */
  value?: string;
  /** Objects/arrays: number of children. */
  count?: number;
  /** 1-based source lines, inclusive. */
  start: number;
  end: number;
  children: TreeNode[];
}

/** `error` reads like "line 3: unexpected end"; `root` is null on error or empty input. */
export interface TreeResult { root: TreeNode | null; error?: string }

/** Root is depth 0; depths 0 and 1 start open. */
export const AUTO_OPEN_DEPTH = 2;

export function startsOpen(node: TreeNode, depth: number): boolean {
  return node.kind !== "scalar" && depth < AUTO_OPEN_DEPTH;
}

/** Paths from the root to the deepest node whose lines contain `line`. */
export function pathToLine(root: TreeNode, line: number): string[] {
  const paths = [root.path];
  let node = root;
  for (;;) {
    const next = node.children.find(c => c.start <= line && line <= c.end);
    if (!next) return paths;
    paths.push(next.path);
    node = next;
  }
}

/** Maps character offsets to 1-based line numbers. */
function lineFinder(text: string): (offset: number) => number {
  const starts = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === "\n") starts.push(i + 1);
  return (offset) => {
    let lo = 0;
    let hi = starts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) lo = mid; else hi = mid - 1;
    }
    return lo + 1;
  };
}

function childPath(parent: string, key: string, isIndex: boolean): string {
  if (isIndex) return `${parent}${key}`;
  if (/^[A-Za-z_$][\w$]*$/.test(key)) return `${parent}.${key}`;
  return `${parent}['${key.replace(/\\/g, "\\\\").replace(/'/g, "\\'")}']`;
}

export function buildJsonTree(text: string): TreeResult {
  if (text.trim() === "") return { root: null };
  const lineAt = lineFinder(text);
  const errors: ParseError[] = [];
  const tree = parseTree(text, errors, { allowTrailingComma: true });
  if (errors.length > 0) {
    const e = errors[0];
    return { root: null, error: `line ${lineAt(e.offset)}: ${printParseErrorCode(e.error)}` };
  }
  if (!tree) return { root: null };

  const lastChar = (n: JsonNode) => Math.max(n.offset, n.offset + n.length - 1);
  const convert = (node: JsonNode, path: string, key: string | null, start: number, end: number): TreeNode => {
    const base = { path, key, start, end };
    if (node.type === "object") {
      const children = (node.children ?? []).map(prop => {
        const [keyNode, valueNode] = prop.children!;
        const name = String(keyNode.value);
        return convert(valueNode, childPath(path, name, false), name,
          lineAt(prop.offset), lineAt(lastChar(prop)));
      });
      return { ...base, kind: "object", count: children.length, children };
    }
    if (node.type === "array") {
      const children = (node.children ?? []).map((item, i) =>
        convert(item, childPath(path, `[${i}]`, true), `[${i}]`, lineAt(item.offset), lineAt(lastChar(item))));
      return { ...base, kind: "array", count: children.length, children };
    }
    const display = node.type === "string" ? JSON.stringify(node.value) : text.slice(node.offset, node.offset + node.length);
    return { ...base, kind: "scalar", value: display, children: [] };
  };
  return { root: convert(tree, "$", null, lineAt(tree.offset), lineAt(lastChar(tree))) };
}

export function buildYamlTree(text: string): TreeResult {
  if (text.trim() === "") return { root: null };
  const lineAt = lineFinder(text);
  const doc = parseAllDocuments(text)[0];
  if (doc.errors.length > 0) {
    const e = doc.errors[0];
    return { root: null, error: `line ${lineAt(e.pos[0])}: ${e.message.split("\n")[0]}` };
  }
  if (!doc.contents) return { root: null };

  /** Last line of a range, ignoring trailing whitespace the parser folds in. */
  const endLine = (end: number, start: number) => {
    let e = end;
    while (e > start && /\s/.test(text[e - 1])) e--;
    return lineAt(Math.max(start, e - 1));
  };
  const rangeOf = (n: { range?: [number, number, number] | null } | null): [number, number] =>
    n?.range ? [n.range[0], n.range[1]] : [0, 0];

  const convert = (node: unknown, path: string, key: string | null, from?: number): TreeNode => {
    const [s, e] = rangeOf(node as { range?: [number, number, number] | null });
    const start = lineAt(from ?? s);
    const end = Math.max(start, endLine(e, s));
    const base = { path, key, start, end };
    if (isMap(node)) {
      const children = node.items.map(pair => {
        const name = isScalar(pair.key) ? String(pair.key.value) : String(pair.key);
        const [ks] = rangeOf(pair.key as { range?: [number, number, number] | null });
        return convert(pair.value, childPath(path, name, false), name, ks);
      });
      return { ...base, kind: "object", count: children.length, children };
    }
    if (isSeq(node)) {
      const children = node.items.map((item, i) =>
        convert(item, childPath(path, `[${i}]`, true), `[${i}]`));
      return { ...base, kind: "array", count: children.length, children };
    }
    if (isAlias(node)) return { ...base, kind: "scalar", value: `*${node.source}`, children: [] };
    if (isScalar(node)) {
      const v = node.value;
      const display = typeof v === "string" ? JSON.stringify(v) : v === null ? "null" : String(v);
      return { ...base, kind: "scalar", value: display, children: [] };
    }
    // An empty value (`key:`) has no node: show it as null on its own line.
    return { ...base, kind: "scalar", value: "null", children: [] };
  };
  return { root: convert(doc.contents, "$", null) };
}
