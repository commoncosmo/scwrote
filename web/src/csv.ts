/** A cell and where it starts in the source: 1-based line, 0-based character column. */
export interface Field { text: string; line: number; column: number }
/** Parsed rows (at most `maxRows`), the full row count, and a parse error if any. */
export interface Table { rows: Field[][]; totalRows: number; error?: string }

export const MAX_ROWS = 5000;

/**
 * RFC 4180 parsing: quotes, doubled quotes, and delimiters or newlines inside
 * quotes. `\r\n` is one newline and a trailing newline adds no row. Ragged rows
 * are kept. Rows past `maxRows` are counted in `totalRows` but not collected.
 * Columns count code points, matching nvim's character columns.
 */
export function parseDelimited(text: string, delimiter: "," | "\t", maxRows: number): Table {
  const rows: Field[][] = [];
  let totalRows = 0;
  let error: string | undefined;

  let row: Field[] = [];
  let value = "";
  let fieldLine = 1;
  let fieldColumn = 0;
  let inQuotes = false;
  let quoteLine = 0;
  let line = 1;
  let column = 0;
  let pending = false; // something has started on the current row

  const endField = () => {
    row.push({ text: value, line: fieldLine, column: fieldColumn });
    value = "";
  };
  const endRow = () => {
    endField();
    totalRows++;
    if (rows.length < maxRows) rows.push(row);
    row = [];
    pending = false;
  };

  const chars = Array.from(text);
  for (let i = 0; i < chars.length; i++) {
    const ch = chars[i];
    if (!pending) {
      fieldLine = line;
      fieldColumn = column;
      pending = true;
    }
    if (inQuotes) {
      if (ch === '"') {
        if (chars[i + 1] === '"') { value += '"'; i++; column += 2; continue; }
        inQuotes = false;
      } else {
        value += ch;
        if (ch === "\n") { line++; column = 0; continue; }
      }
      column++;
    } else if (ch === '"' && value === "") {
      inQuotes = true;
      quoteLine = line;
      column++;
    } else if (ch === delimiter) {
      endField();
      column++;
      fieldLine = line;
      fieldColumn = column;
    } else if (ch === "\n" || (ch === "\r" && chars[i + 1] === "\n")) {
      if (ch === "\r") i++;
      endRow();
      line++;
      column = 0;
    } else {
      value += ch;
      column++;
    }
  }

  if (inQuotes) error = `line ${quoteLine}: unclosed quote`;
  if (pending) endRow();
  return error === undefined ? { rows, totalRows } : { rows, totalRows, error };
}

/**
 * The cell containing a cursor position (1-based line, 0-based character
 * column): the last field starting at or before it. Null when there is no such
 * field, or the position lies past the collected rows of a truncated table.
 */
export function fieldAt(table: Table, line: number, column: number): { row: number; column: number } | null {
  let found: { row: number; column: number } | null = null;
  for (let r = 0; r < table.rows.length; r++) {
    for (let c = 0; c < table.rows[r].length; c++) {
      const f = table.rows[r][c];
      if (f.line < line || (f.line === line && f.column <= column)) found = { row: r, column: c };
      else return found;
    }
  }
  if (found && table.totalRows > table.rows.length) {
    const last = table.rows[found.row][found.column];
    if (line > last.line + (last.text.match(/\n/g)?.length ?? 0)) return null;
  }
  return found;
}
