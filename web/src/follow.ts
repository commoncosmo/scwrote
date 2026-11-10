/** A rendered block's source range: 1-based, inclusive lines. */
export interface Block { start: number; end: number }

/**
 * Index of the block the cursor line belongs to: the innermost block containing
 * it, else the last block starting before it, else the first block.
 * Returns -1 when there are no blocks.
 */
export function blockForLine(blocks: Block[], line: number): number {
  if (blocks.length === 0) return -1;
  let inner = -1;
  let above = -1;
  blocks.forEach((b, i) => {
    if (b.start <= line && line <= b.end) {
      if (inner < 0 || b.end - b.start <= blocks[inner].end - blocks[inner].start) inner = i;
    } else if (b.start < line && (above < 0 || b.start >= blocks[above].start)) {
      above = i;
    }
  });
  if (inner >= 0) return inner;
  return above >= 0 ? above : 0;
}
