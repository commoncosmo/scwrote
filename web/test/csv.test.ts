import { expect, test } from "bun:test";
import { MAX_ROWS, fieldAt, parseDelimited } from "../src/csv";

test("splits rows and fields with positions", () => {
  const t = parseDelimited("a,b\nc,d\n", ",", MAX_ROWS);
  expect(t.rows.map(r => r.map(f => f.text))).toEqual([["a", "b"], ["c", "d"]]);
  expect(t.rows[1][1]).toEqual({ text: "d", line: 2, column: 2 });
});
test("quoted fields hold commas, quotes and newlines", () => {
  const t = parseDelimited('x,"a,""b""\nc"\ny,z', ",", MAX_ROWS);
  expect(t.rows[0][1].text).toBe('a,"b"\nc');
  expect(t.rows[1][0]).toEqual({ text: "y", line: 3, column: 0 });
});
test("tabs for TSV", () => {
  expect(parseDelimited("a\tb", "\t", MAX_ROWS).rows[0].length).toBe(2);
});
test("emptyTextHasNoRows", () => {
  expect(parseDelimited("", ",", MAX_ROWS)).toEqual({ rows: [], totalRows: 0 });
});
test("capsRowsAndReportsTotal", () => {
  const text = Array.from({ length: 12 }, (_, i) => `r${i}`).join("\n");
  const t = parseDelimited(text, ",", 5);
  expect(t.rows.length).toBe(5);
  expect(t.totalRows).toBe(12);
});
test("an unclosed quote is an error on its line", () => {
  expect(parseDelimited('a\n"b,c', ",", MAX_ROWS).error).toBe("line 2: unclosed quote");
});
test("CRLF line endings do not add rows or stray characters", () => {
  const t = parseDelimited("a,b\r\nc,d\r\n", ",", MAX_ROWS);
  expect(t.rows.map(r => r.map(f => f.text))).toEqual([["a", "b"], ["c", "d"]]);
});
test("ragged rows are kept", () => {
  const t = parseDelimited("a,b,c\nd", ",", MAX_ROWS);
  expect(t.rows.map(r => r.length)).toEqual([3, 1]);
});
test("fieldAtCountsCharacters", () => {
  const t = parseDelimited("é,b\nc,d", ",", MAX_ROWS);
  expect(fieldAt(t, 1, 2)).toEqual({ row: 0, column: 1 });
  expect(fieldAt(t, 2, 0)).toEqual({ row: 1, column: 0 });
});
test("fieldAt counts astral characters as one", () => {
  const t = parseDelimited("😀,b", ",", MAX_ROWS);
  expect(t.rows[0][1].column).toBe(2);
  expect(fieldAt(t, 1, 2)).toEqual({ row: 0, column: 1 });
});
test("fieldAt inside a multi-line quoted field finds its row", () => {
  const t = parseDelimited('x,"a\nb"\ny,z', ",", MAX_ROWS);
  expect(fieldAt(t, 2, 0)).toEqual({ row: 0, column: 1 });
});
test("fieldAt with no rows is null", () => {
  expect(fieldAt(parseDelimited("", ",", MAX_ROWS), 1, 0)).toBeNull();
});
test("fieldAt past the capped rows is null", () => {
  const t = parseDelimited("a\nb\nc\nd", ",", 2);
  expect(fieldAt(t, 2, 0)).toEqual({ row: 1, column: 0 });
  expect(fieldAt(t, 4, 0)).toBeNull();
});
