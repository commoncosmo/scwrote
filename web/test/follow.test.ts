import { expect, test } from "bun:test";
import { blockForLine } from "../src/follow";

test("innermost block containing the line", () => {
  expect(blockForLine([{ start: 1, end: 10 }, { start: 3, end: 4 }], 4)).toBe(1);
});
test("between blocks picks the one above", () => {
  expect(blockForLine([{ start: 1, end: 1 }, { start: 5, end: 6 }], 3)).toBe(0);
});
test("before the first block picks the first", () => {
  expect(blockForLine([{ start: 3, end: 4 }], 1)).toBe(0);
});
test("no blocks", () => { expect(blockForLine([], 1)).toBe(-1); });
