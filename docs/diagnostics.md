# Diagnostics and reports

## Parser diagnostics

A parser diagnostic records:

- severity: note, warning, or error;
- stable code;
- line and column;
- concise message;
- optional field context where the parser can provide it.

Diagnostics are attached to a `Record` when parsing can recover. Fatal parse failures use an error union because no reliable record exists.

Representative conditions include invalid number, invalid timestamp, missing field, extra field, unknown escape, unsupported syntax, truncated value, invalid UTF-8 context, input limit, nesting limit, duplicate field, and ambiguous format.

The per-record diagnostic buffer is bounded. Additional diagnostics increment a dropped counter, which appears in summaries.

## Validation findings

Validation findings are separate from parser diagnostics and contain:

- level;
- rule name;
- optional field;
- source line;
- expected/actual context where applicable;
- message.

A record can parse cleanly and still fail a schema. Conversely, a recovered record may satisfy the selected schema but retain parser warnings.

## Diagnose command

```sh
opsmosaic diagnose [--report-format text|json] [--format ...] <inputs...>
```

The command runs normal ingestion and builds a report from usable records. Text output is intended for terminal review; JSON output is intended for deterministic local automation.

Fields include:

- input count and byte count;
- failed line count;
- normalized record count;
- recovered record count;
- parser note/warning/error totals;
- count by diagnostic code;
- validation summary when supplied by a workflow;
- count by severity, service, format, and tag;
- HTTP status-class summary;
- quality grade and component coverage.

## Health score

The health score begins at 100 and subtracts bounded penalties for:

- missing normalized timestamps;
- missing host attribution;
- missing service attribution;
- recovered/warned records;
- elevated HTTP client/server error rate.

Grades:

- `excellent`: 90–100;
- `good`: 75–89;
- `degraded`: 50–74;
- `poor`: below 50.

This score is an explainable local triage heuristic. It is not a service-level objective, benchmark, production reliability claim, or substitute for domain-specific validation.

## Error output and data output

CLI diagnostics and usage errors go to standard error. Requested normalized/query/export data goes to standard output or `--output`. This separation allows:

```sh
opsmosaic query ... > selected.jsonl 2> query-diagnostics.log
```

Write failures propagate as errors. OpsMosaic does not silently fall back to a different destination.

## Exit codes

- 0: requested operation completed;
- 2: invalid command, option, format, schema, query, or projection;
- 3: input could not be read/parsed into a usable result;
- 4: validation or diagnostic operation found operational errors;
- 5: query completed with zero matches;
- 70: unexpected internal error.

Line-oriented ingestion normally continues after a bad line and reports failure counts. `--strict` stops on the first failure.

## Redaction

JSON and CSV exporters recognize common sensitive field names and replace values with `<redacted>` by default. The redaction module supports explicit replace, remove, or deterministic hash modes for workflow-controlled plans.

Redaction is field-name based and conservative; it cannot guarantee discovery of secrets embedded in arbitrary message text. `redact_message_patterns` is an optional bounded check for obvious credential assignments. Operators should still review intended export columns.

## Operational audit trail

`workflow.audit` records monotonic entries for detected, parsed, normalized, validated, deduplicated, correlated, and exported stages. Entries contain source location, a deterministic normalized identity hash, and a short detail. The trail is bounded and reports dropped entries.

The hash supports local comparison; it is not a cryptographic integrity signature.
