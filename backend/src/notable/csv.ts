/**
 * A small RFC 4180 CSV parser (no dependency: the backend's only CSV is the
 * plane-alert-db file, see mapping.ts).
 *
 * Handles what that file can contain: quoted fields, commas and line breaks
 * inside quotes, a doubled quote (`""`) as a literal quote, CRLF or LF line
 * ends, a leading UTF-8 byte-order mark, and a missing final newline. Blank
 * lines are skipped. It never throws: an unterminated quote runs to the end of
 * the input and yields whatever was read, so a truncated download produces
 * fewer rows (which the refresh's size check then rejects), not an exception.
 */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;
  // True once the current field has seen any character or an opening quote,
  // so `a,""` keeps its empty second field and a blank line yields no row.
  let fieldStarted = false;

  const endField = () => {
    row.push(field);
    field = "";
    fieldStarted = false;
  };
  const endRow = () => {
    if (row.length > 0 || fieldStarted) {
      endField();
      rows.push(row);
    }
    row = [];
  };

  let i = text.charCodeAt(0) === 0xfeff ? 1 : 0;
  for (; i < text.length; i++) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field += ch;
      }
      continue;
    }
    if (ch === '"' && field === "") {
      inQuotes = true;
      fieldStarted = true;
    } else if (ch === ",") {
      endField();
      // A trailing comma still opens one more (empty) field on this row.
      fieldStarted = true;
    } else if (ch === "\n") {
      endRow();
    } else if (ch === "\r") {
      if (text[i + 1] === "\n") i++;
      endRow();
    } else {
      field += ch;
      fieldStarted = true;
    }
  }
  endRow();
  return rows;
}
