/**
 * drizzle's DrizzleQueryError message is "Failed query: <sql>\nparams: <values>",
 * and for a catch insert those values include observer_lat / observer_lon. The
 * query text is useful when reading an error; the values are not worth the
 * leak. Used by the Sentry scrubber (instrument.ts) and the 5xx log line
 * (errorHandler.ts). Pure, so app.ts can use it without loading Sentry.
 */

const SQL_PARAMS_RE = /\nparams: [\s\S]*$/;

export function stripSqlParams(text: string): string {
  return text.replace(SQL_PARAMS_RE, "\nparams: [redacted]");
}
