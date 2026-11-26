// RFC-4180 CSV, read by header name: a port of `CSV.records` / `CSV.parse` (Sources/MPTCore/Bench/CSV.swift) that
// keeps only the wanted columns, in one pass (the Free plan's 10 ms CPU budget, spec §4.J).
//
// Same rules as the Swift parser: quotes undone ("" inside quotes is one "), CRLF / LF / lone CR end a record,
// blank lines are skipped, rows shorter than the header leave the missing cells out, extra cells are ignored.
// Here an empty or missing cell is `undefined` (the Swift callers treat "" and a missing key alike).

export type Columns = Record<string, (string | undefined)[]>;

export function parseColumns(text: string, wanted: string[]): Columns {
  // samples.csv almost never quotes anything (only a text cell with a comma or quote would be): then the runtime's
  // native split does the scanning, several times faster than the general loop on a cold isolate.
  return text.indexOf('"') === -1 && text.indexOf("\r") === -1 ? parseUnquoted(text, wanted) : parseGeneral(text, wanted);
}

/**
 * The same result as `parseGeneral` for text without any `"` or CR: each record is found with `indexOf` and only the
 * cells up to the last wanted column are visited; only wanted cells are copied.
 */
export function parseUnquoted(text: string, wanted: string[]): Columns {
  const out: Columns = {};
  for (const w of wanted) out[w] = [];
  const len = text.length;
  // Records end at LF only (the caller sends text with a CR to the general parser).
  const lineEnd = (from: number): [number, number] => {
    const i = text.indexOf("\n", from);
    return i === -1 ? [len, len] : [i, i + 1];
  };

  let pos = 0;
  let header: string[] | null = null;
  // Header index -> output column, and the last index needed.
  let pick: (string | undefined)[] = [];
  let last = -1;
  let rows = 0;
  while (pos < len) {
    const [end, next] = lineEnd(pos);
    if (end > pos) {
      if (header === null) {
        header = text.slice(pos, end).split(",");
        const want = new Set(wanted);
        const seen = new Set<string>();
        for (const h of header) {
          if (!want.has(h)) continue;
          // A repeated wanted name: the general parser's per-row "later present cell wins" applies.
          if (seen.has(h)) return parseGeneral(text, wanted);
          seen.add(h);
        }
        pick = header.map((h) => (want.has(h) ? h : undefined));
        for (let i = 0; i < pick.length; i++) if (pick[i] !== undefined) last = i;
      } else {
        let cell = 0;
        let start = pos;
        while (cell <= last && start <= end) {
          let comma = text.indexOf(",", start);
          if (comma === -1 || comma > end) comma = end;
          const name = pick[cell];
          if (name !== undefined) out[name][rows] = comma > start ? text.slice(start, comma) : undefined;
          cell += 1;
          start = comma + 1;
        }
        for (const w of wanted) if (out[w].length === rows) out[w].push(undefined);
        rows += 1;
      }
    }
    pos = next;
  }
  return out;
}

/** RFC-4180 with quotes: one pass, character by character. */
export function parseGeneral(text: string, wanted: string[]): Columns {
  const out: Columns = {};
  for (const w of wanted) out[w] = [];

  // Header index -> wanted column name (filled once the header record is read).
  let pick: (string | undefined)[] | null = null;
  let record: (string | undefined)[] = [];
  let cell = 0;
  let field = "";
  let inQuotes = false;
  let sawAny = false;
  let rows = 0;

  const pushField = () => {
    if (pick === null) record.push(field);
    else if (cell < pick.length && pick[cell] !== undefined) record[cell] = field;
    cell += 1;
    field = "";
  };
  const endRecord = () => {
    if (sawAny) {
      pushField();
      if (pick === null) {
        const header = record as string[];
        const want = new Set(wanted);
        pick = header.map((h) => (want.has(h) ? h : undefined));
      } else {
        // Cells past the row's end are missing; with a repeated header name the later present cell wins (as Swift).
        for (let k = 0; k < Math.min(pick.length, cell); k++) {
          const name = pick[k];
          if (name === undefined) continue;
          const v = record[k];
          out[name][rows] = v === undefined || v === "" ? undefined : v;
        }
        for (const w of wanted) if (out[w].length === rows) out[w].push(undefined);
        rows += 1;
      }
    }
    record = [];
    cell = 0;
    field = "";
    sawAny = false;
  };

  const len = text.length;
  let i = 0;
  while (i < len) {
    const c = text.charCodeAt(i);
    if (inQuotes) {
      if (c === 0x22) {
        if (i + 1 < len && text.charCodeAt(i + 1) === 0x22) {
          field += '"';
          i += 1;
        } else inQuotes = false;
      } else {
        // Copy the run of plain characters up to the next quote in one slice.
        const q = text.indexOf('"', i);
        const stop = q === -1 ? len : q;
        field += text.slice(i, stop);
        i = stop;
        continue;
      }
    } else if (c === 0x22) {
      inQuotes = true;
      sawAny = true;
    } else if (c === 0x2c) {
      pushField();
      sawAny = true;
    } else if (c === 0x0a) {
      endRecord();
    } else if (c === 0x0d) {
      if (!(i + 1 < len && text.charCodeAt(i + 1) === 0x0a)) endRecord();
    } else {
      // A run of ordinary characters: up to the next delimiter.
      let j = i + 1;
      while (j < len) {
        const d = text.charCodeAt(j);
        if (d === 0x22 || d === 0x2c || d === 0x0a || d === 0x0d) break;
        j += 1;
      }
      // Only wanted cells (and the header) are copied: the others are skipped without allocating.
      const p = pick as (string | undefined)[] | null;
      if (p === null || (cell < p.length && p[cell] !== undefined)) field += text.slice(i, j);
      sawAny = true;
      i = j;
      continue;
    }
    i += 1;
  }
  endRecord();
  return out;
}
