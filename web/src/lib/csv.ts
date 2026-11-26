// RFC-4180 CSV, read by header name: a port of `CSV.records` / `CSV.parse` (Sources/MPTCore/Bench/CSV.swift) that
// keeps only the wanted columns, in one pass (the Free plan's 10 ms CPU budget, spec §4.J).
//
// Same rules as the Swift parser: quotes undone ("" inside quotes is one "), CRLF / LF / lone CR end a record,
// blank lines are skipped, rows shorter than the header leave the missing cells out, extra cells are ignored.
// Here an empty or missing cell is `undefined` (the Swift callers treat "" and a missing key alike).

export type Columns = Record<string, (string | undefined)[]>;

export function parseColumns(text: string, wanted: string[]): Columns {
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
      field += text.slice(i, j);
      sawAny = true;
      i = j;
      continue;
    }
    i += 1;
  }
  endRecord();
  return out;
}
