# OpsMosaic

[![CI](https://github.com/opsmosaic/opsmosaic/actions/workflows/ci.yml/badge.svg)](https://github.com/opsmosaic/opsmosaic/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

OpsMosaic is an offline Zig library and command-line workbench for operational data that arrives in incompatible text formats. It detects, parses, validates, normalizes, queries, correlates, aggregates, diagnoses, and exports infrastructure records without network access or third-party runtime dependencies.

The project is designed for investigations, migration checks, configuration reviews, incident preparation, and repeatable operational data-quality workflows.

## What OpsMosaic handles

OpsMosaic has first-party parsers for:

| Format | Typical inputs | Important normalized attributes |
|---|---|---|
| Syslog / RFC3164 | daemon and host logs | timestamp, severity, host, service, PID, message |
| RFC5424 | structured operational events | version, event ID, structured-data fields, message |
| JSON Lines | application and platform events | typed fields, tags, identifiers, network values |
| CSV | inventories and tabular observations | header-aware fields, typed scalar values |
| INI | service configuration | sections, keys, scalar values, comments |
| HTTP access logs | common and combined log records | client address, method, path, status, bytes |
| DNS zone-style records | offline zone review | owner, TTL, class, type, record data |
| Environment files | dotenv configuration | exported keys, quoting, typed values, sensitivity warnings |
| Safe manifest subset | small deployment manifests | nested mappings, lists, scalar values, tags |

The manifest parser intentionally implements a documented subset rather than full YAML. Anchors, aliases, tags, directives, flow collections, block scalars, and executable/custom types are rejected with diagnostics.

## Compiler and dependency policy

The repository targets and is intended to be verified with **Zig 0.13.0**.

OpsMosaic uses only the Zig standard library. `build.zig.zon` contains package metadata and declares no remote dependencies. A clean build does not fetch from the network.

## Build

```sh
zig version
# expected: 0.13.0

zig build
```

The executable is installed at:

```text
zig-out/bin/opsmosaic
```

Build the public-library example:

```sh
zig build example
```

## Tests

Run unit tests embedded in source modules plus the integration suites under `tests/`:

```sh
zig build test
```

The test graph covers format detection, streaming behavior, each parser, normalization, ownership, validation, policies, duplicate detection, correlation, query parsing and evaluation, aggregation, time windows, inventory reconciliation, field profiling, redaction, deterministic export, diagnostics, malformed input, and CLI workflows.

Tests use deterministic fixtures, do not require network access, and avoid wall-clock or host-specific paths.

## CLI overview

```text
opsmosaic <command> [options] [files...]
```

Commands:

- `detect` identifies input format and explains the decision.
- `inspect` prints concise normalized fields for human review.
- `normalize` emits normalized JSON Lines.
- `validate` applies a built-in schema and reports findings.
- `query` filters normalized records with bounded expressions.
- `aggregate` summarizes operational dimensions and numeric fields.
- `correlate` groups events using deterministic identifiers and time windows.
- `export` writes JSON, JSON Lines, CSV, or text projections.
- `diagnose` reports parse recovery, warnings, coverage, and quality.

Show built-in help:

```sh
zig build run -- help
```

Common options:

```text
-f, --format <auto|syslog|rfc5424|jsonl|csv|ini|access-log|dns-zone|env|manifest>
-o, --output <path>
--stdin
--strict
--deduplicate
--max-input-bytes <n>
--max-line-bytes <n>
```

When no file is supplied, record-oriented commands read standard input. A single `-` or `--stdin` also selects standard input. Mixing stdin and file paths is rejected to keep ownership and diagnostics unambiguous.

## Detection

Detect several files without parsing them as a single stream:

```sh
zig build run -- detect \
  examples/inputs/service-events.jsonl \
  examples/inputs/access.log \
  examples/inputs/service.ini \
  examples/inputs/example.zone
```

Output contains the path, chosen format, confidence, and a short evidence string. An explicit `--format` bypasses automatic selection for later commands.

## Inspection and normalization

Inspect selected normalized fields:

```sh
zig build run -- inspect --format jsonl \
  examples/inputs/service-events.jsonl
```

Choose and rename columns:

```sh
zig build run -- inspect --format jsonl \
  --columns 'time=timestamp,level=severity,application=service,text=message' \
  examples/inputs/service-events.jsonl
```

Normalize into JSON Lines:

```sh
zig build run -- normalize --format jsonl \
  examples/inputs/service-events.jsonl
```

Normalize from stdin:

```sh
cat examples/inputs/system.log \
  | zig build run -- normalize --stdin --format rfc5424
```

The normalization pipeline standardizes timestamps, severity labels, host and service attribution, scalar values, tags, network fields, and selected identifiers. Reapplying it is deterministic.

## Validation

Built-in schemas:

| Schema | Intended records |
|---|---|
| `service-event` | normalized syslog, RFC5424, or JSON Lines events |
| `http-event` | HTTP access observations |
| `inventory` | CSV infrastructure inventory rows |
| `deployment` | safe-subset deployment manifests |

Validate access records:

```sh
zig build run -- validate \
  --format access-log \
  --schema http-event \
  examples/inputs/access.log
```

Use `--strict` to stop on malformed records, require stronger timestamp normalization, and treat undeclared fields more conservatively.

Validation distinguishes:

- parser failures that prevent record construction;
- recoverable parser warnings attached to a record;
- schema findings with note, warning, or error level;
- deterministic policy findings from bounded queries.

Credential-like environment names receive warnings. JSON and CSV export redact common secret-bearing field names by default.

## Query language

Queries are parsed into a bounded expression program and evaluated only against normalized records.

Supported comparisons:

```text
field == value
field != value
field > value
field >= value
field < value
field <= value
field contains value
field starts_with value
field ends_with value
```

Supported logical operations:

```text
left and right
left or right
not expression
(expression)
has(tag)
missing(field)
```

Examples:

```sh
zig build run -- query --format jsonl \
  --where 'severity >= warning and has(prod)' \
  examples/inputs/service-events.jsonl
```

```sh
zig build run -- query --format access-log \
  --where 'status >= 500 and path starts_with /v1/' \
  examples/inputs/access.log
```

```sh
zig build run -- query --format jsonl \
  --case-insensitive \
  --where 'message contains TIMEOUT or missing(trace_id)' \
  examples/inputs/service-events.jsonl
```

The default query limits are 256 nodes, nesting depth 32, and 4,096 bytes per token. Missing fields compare equal to `null` only when that behavior is explicitly enabled by the evaluator.

See `docs/query_language.md` for precedence and value semantics.

## Aggregation

Summarize standard operational dimensions:

```sh
zig build run -- aggregate --format access-log \
  examples/inputs/access.log
```

The standard report includes:

- record count;
- count by severity;
- count by service;
- count by source format;
- count by tag;
- minimum and maximum normalized timestamps;
- HTTP status classes and error rate.

Summarize a numeric field:

```sh
zig build run -- aggregate --format jsonl \
  --field duration_ms \
  examples/inputs/service-events.jsonl
```

Create deterministic time buckets:

```sh
zig build run -- aggregate --format jsonl \
  --bucket-seconds 60 \
  examples/inputs/service-events.jsonl
```

Missing numeric fields are counted separately from incompatible values. Non-finite values are not added to numeric summaries. Distinct-value and field-profile structures use bounded storage and report overflow.

## Duplicate detection and correlation

Semantic duplicate detection compares normalized host, service, event ID, message, timestamp, fields, and optionally tags. It does not rely on raw byte equality, so equivalent records from different source formats can match.

Correlation uses deterministic evidence:

- trace ID;
- request ID;
- event ID;
- normalized host;
- normalized service;
- source address;
- time window;
- one optional configured field.

```sh
zig build run -- correlate \
  --window-seconds 300 \
  examples/inputs/service-events.jsonl \
  examples/inputs/system.log
```

A custom field can participate:

```sh
zig build run -- correlate \
  --correlation-field incident_id \
  --score 70 \
  --window-seconds 600 \
  events-a.jsonl events-b.jsonl
```

No statistical or machine-learning correlation is implied. The score is a documented weighted rule over available evidence.

## Export

JSON array:

```sh
zig build run -- export --format jsonl --to json --pretty \
  examples/inputs/service-events.jsonl
```

JSON Lines:

```sh
zig build run -- export --format rfc5424 --to jsonl \
  examples/inputs/system.log
```

CSV with deterministic columns:

```sh
zig build run -- export --format jsonl --to csv \
  --columns timestamp,severity,host,service,event_id,status,message \
  examples/inputs/service-events.jsonl
```

Write to a file:

```sh
zig build run -- export --format access-log --to csv \
  --output /tmp/opsmosaic-access.csv \
  examples/inputs/access.log
```

Exporters escape quotes, delimiters, control characters, and line breaks. Missing fields become empty CSV cells or omitted/null JSON values according to options. Stable top-level ordering is used for operational core fields, then source fields.

## Diagnostics

Diagnose a stream with malformed records:

```sh
zig build run -- diagnose --format jsonl \
  examples/inputs/malformed-mixed.log
```

JSON report form:

```sh
zig build run -- diagnose --report-format json --format jsonl \
  examples/inputs/malformed-mixed.log
```

The report includes:

- inputs and bytes processed;
- parsed and failed line counts;
- recovered records;
- note, warning, and error totals;
- warning codes;
- timestamp, host, and service coverage;
- HTTP error-rate context;
- a bounded quality grade.

Quality is a transparent heuristic for operational triage and prioritization during review.

## Library usage

The public entry module is `src/root.zig` and the package/module name is `opsmosaic`.

```zig
const std = @import("std");
const opsmosaic = @import("opsmosaic");

pub fn main() !void {
    const input =
        "{\"timestamp\":\"2026-07-30T07:15:00Z\","
        ++ "\"severity\":\"error\",\"service\":\"gateway\","
        ++ "\"message\":\"upstream timeout\",\"status\":504}";

    var parsed = try opsmosaic.parseRecord(input, .jsonl, .{});
    _ = opsmosaic.normalizeRecord(&parsed.record);

    try opsmosaic.exporting.json.writeRecord(
        &parsed.record,
        std.io.getStdOut().writer(),
        .{ .pretty = true },
    );
}
```

The complete example is `examples/library_usage.zig` and is compiled by:

```sh
zig build example
```

Allocator-aware multi-record workflows use `workflow.session.Session`. It clones borrowed parser output into `OwnedRecord` values and exposes explicit `deinit` cleanup.

## Architecture

The source tree is layered:

```text
input -> parsing -> model -> normalization -> validation
                                   |              |
                                   v              v
                              processing -> diagnostics -> export
                                   |
                                   v
                                workflow -> CLI
```

Important boundaries:

- Low-level parsers do not import CLI modules.
- Exporters accept normalized records; they never reparse raw input.
- CLI commands orchestrate public layers instead of duplicating parsing logic.
- `Record` is a borrowed representation for bounded parsing.
- `OwnedRecord` clones slices into an arena and exposes `deinit`.
- Query programs, diagnostics, findings, correlation groups, and many summaries use explicit fixed bounds.

See `docs/architecture.md`.

## Input limits and failure behavior

Default limits:

| Limit | Default |
|---|---:|
| bytes per input | 64 MiB |
| bytes per line | 1 MiB |
| structured fields per record | 64 |
| tags per record | 24 |
| parser diagnostics per record | 64 |
| query nodes | 256 |
| query nesting depth | 32 |
| query token bytes | 4,096 |
| correlation records considered | 4,096 |
| correlation groups | 128 |
| members per correlation group | 256 |

The CLI returns documented nonzero statuses:

| Code | Meaning |
|---:|---|
| 0 | success |
| 2 | usage or invalid option/query |
| 3 | input/read/parse failure with no usable result |
| 4 | validation or diagnostics reported operational errors |
| 5 | query completed with no matches |
| 70 | unexpected internal error |

Invalid external input is returned as an error or recorded as a recoverable diagnostic. Parser code does not intentionally panic on malformed input. `--strict` stops at the first record failure; the default line-oriented workflow continues and reports counts.

Malformed UTF-8 is accepted as raw bytes in fields where byte-preserving behavior is useful, but validation and JSON export escape control bytes. No Unicode normalization is claimed.

## Example workflows

Scripts under `examples/workflows/` demonstrate:

- mixed detection and normalization;
- service configuration validation;
- high-severity filtering;
- HTTP status aggregation;
- event correlation across JSON Lines and RFC5424;
- JSON/CSV export;
- malformed-input diagnostics.

## Fuzzing

Five libFuzzer-compatible Zig harnesses exercise the same parsers, normalizers, validation, profiling, aggregation, redaction, and exporters used by the library and CLI:

```text
fuzz/syslog_fuzzer.zig
fuzz/jsonl_fuzzer.zig
fuzz/config_fuzzer.zig
fuzz/csv_fuzzer.zig
fuzz/accesslog_fuzzer.zig
```

Each harness bounds input to 1 MiB and treats parser errors as expected outcomes. Seed directories contain raw operational examples, including valid and malformed-but-realistic records. `.clusterfuzzlite/build.sh` writes all final executables directly to `$OUT` using the platform-provided sanitizer and fuzzing runtime.

## Development

Run the project checks from a clean checkout with Zig 0.13.0:

```sh
scripts/verify.sh
```

The script builds the CLI, runs unit and integration tests, builds the library example, and verifies that build artifacts are not tracked by Git.

Continuous integration is defined in `.github/workflows/ci.yml`. See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and [CHANGELOG.md](CHANGELOG.md) for release history. See [docs/verification.md](docs/verification.md) for CI and fuzzing details.

## License

MIT. See `LICENSE`.
