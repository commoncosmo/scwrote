import { expect, test } from "bun:test";
import { buildJsonTree, buildYamlTree, pathToLine, startsOpen } from "../src/tree";

test("JSON nodes with lines", () => {
  const { root } = buildJsonTree('{\n  "a": [1,\n    2],\n  "b": "x"\n}');
  expect(root!.kind).toBe("object");
  expect(root!.children.map(c => c.key)).toEqual(["a", "b"]);
  const a = root!.children[0];
  expect([a.start, a.end, a.count]).toEqual([2, 3, 2]);
  expect(a.children[1]).toMatchObject({ path: "$.a[1]", key: "[1]", value: "2", start: 3 });
  expect(root!.children[1].value).toBe('"x"');
});
test("odd keys get bracket paths", () => {
  expect(buildJsonTree('{"a b": 1}').root!.children[0].path).toBe("$['a b']");
});
test("broken JSON reports a line", () => {
  expect(buildJsonTree('{\n "a": 1,\n').error).toMatch(/^line 3: /);
});
test("emptyTextIsNotAnError", () => {
  expect(buildJsonTree("")).toEqual({ root: null });
  expect(buildYamlTree("")).toEqual({ root: null });
});
test("YAML nodes with lines", () => {
  const { root } = buildYamlTree("a:\n  - 1\n  - 2\nb: x\n");
  expect(root!.children.map(c => [c.key, c.start])).toEqual([["a", 1], ["b", 4]]);
  expect(root!.children[0].children[1]).toMatchObject({ path: "$.a[1]", start: 3 });
});
test("broken YAML reports a line", () => {
  expect(buildYamlTree("a: [1,\nb: 2\n").error).toMatch(/^line \d+: /);
});
test("open by depth", () => {
  const { root } = buildJsonTree('{"a":{"b":{"c":1}}}');
  expect(startsOpen(root!, 0) && startsOpen(root!.children[0], 1)).toBe(true);
  expect(startsOpen(root!.children[0].children[0], 2)).toBe(false);
});
test("path to the cursor's node", () => {
  const { root } = buildJsonTree('{\n "a": {\n  "b": 1\n }\n}');
  expect(pathToLine(root!, 3)).toEqual(["$", "$.a", "$.a.b"]);
});
test("YAML empty values are null scalars", () => {
  const { root, error } = buildYamlTree("a:\nb: 1\n");
  expect(error).toBeUndefined();
  expect(root!.children[0]).toMatchObject({ key: "a", value: "null", start: 1 });
});
