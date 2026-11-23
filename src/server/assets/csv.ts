// CSV as wago.tools writes its DB2 tables, read as Python's csv.DictReader reads them: a quoted field may hold
// commas, newlines and "" for a quote; text after a closing quote is kept; \n, \r\n and \r all end a record; blank
// lines are skipped; the first record names the columns.

const COMMA = 44;
const QUOTE = 34;
const LF = 10;
const CR = 13;

/** Every record of the text, as arrays of fields */
export const parseCsvRecords = (text: string): string[][] => {
  const records: string[][] = [];
  const length = text.length;
  let record: string[] = [];
  let position = 0;
  while (position < length) {
    // One field
    let field = "";
    if (text.charCodeAt(position) === QUOTE) {
      position++;
      while (position < length) {
        const closing = text.indexOf('"', position);
        if (closing < 0) {
          field += text.slice(position); // unterminated: the rest of the text, as Python's non-strict reader
          position = length;
          break;
        }
        field += text.slice(position, closing);
        if (text.charCodeAt(closing + 1) === QUOTE) {
          field += '"';
          position = closing + 2;
        } else {
          position = closing + 1;
          break;
        }
      }
    }
    // Unquoted text, or what follows a closing quote, up to the next comma or line end
    let end = position;
    while (end < length) {
      const code = text.charCodeAt(end);
      if (code === COMMA || code === LF || code === CR) break;
      end++;
    }
    field += text.slice(position, end);
    record.push(field);
    position = end;
    const code = text.charCodeAt(position);
    if (code === COMMA) {
      position++;
      if (position >= length) record.push(""); // a trailing comma ends with an empty field
      continue;
    }
    // End of the record
    if (code === CR && text.charCodeAt(position + 1) === LF) position += 2;
    else position++;
    if (!(record.length === 1 && record[0] === "")) records.push(record);
    record = [];
  }
  if (record.length > 0) records.push(record);
  return records;
};

/**
 * The records after the header as objects keyed by column name. A short record's missing columns are "" (the
 * Python's DictReader gave None; every caller treats both as empty); fields beyond the header are dropped.
 */
export const parseCsv = (text: string): Record<string, string>[] => {
  const records = parseCsvRecords(text.charCodeAt(0) === 0xfeff ? text.slice(1) : text);
  const header = records[0];
  if (!header) return [];
  const rows: Record<string, string>[] = new Array(records.length - 1);
  for (let r = 1; r < records.length; r++) {
    const record = records[r] ?? [];
    const row: Record<string, string> = {};
    for (let c = 0; c < header.length; c++) row[header[c] ?? ""] = record[c] ?? "";
    rows[r - 1] = row;
  }
  return rows;
};
