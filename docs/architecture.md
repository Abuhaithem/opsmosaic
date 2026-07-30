# Architecture

## Purpose and constraints

OpsMosaic turns heterogeneous infrastructure text into one normalized record model while remaining offline, deterministic, allocator-explicit, and bounded. The architecture avoids a plugin framework because the supported formats are known and each parser benefits from direct domain-specific code.

## Dependency direction

```text
model <--- diagnostics
  ^            ^
  |            |
input ---> parsing ---> normalization ---> validation
                      \                 /
                       ---> processing --
                              |
                         export/workflow
                              |
                             CLI
```

`src/root.zig` exposes the public library graph. Low-level modules never import `cli`. Parsing modules import the model, common cursor helpers, and diagnostics only. Export modules consume `Record`; they do not inspect raw input.

## Record ownership

`model.record.Record` is the parser-facing borrowed type. Its textual slices point into an input buffer or parser-owned scratch data. It uses bounded arrays for fields, tags, and diagnostics to avoid hidden allocation while examining one record.

`model.record.OwnedRecord` contains an `ArenaAllocator` and a cloned `Record`. `OwnedRecord.cloneFrom` duplicates every borrowed slice, including nested value text and diagnostic text that must survive the source buffer. `deinit` releases the arena in one explicit operation.

`workflow.session.Session` owns an `ArrayList(OwnedRecord)`. A session may ingest multiple files, clone their records, release each raw input, and still expose stable borrowed views over owned records. Session cleanup walks all records and source-name allocations.

## Input layer

`input.detector` combines file-extension hints and content evidence. It returns a format, confidence, and reason; it does not parse the full document.

`input.stream_reader` provides a bounded slice-line iterator. It records line number and byte offset and rejects a line before passing an oversized slice to a parser.

`input.line_cursor` is a non-allocating cursor for token and column tracking. `input.file_loader` bounds file and stdin reads.

## Parser layer

`parsing.dispatcher` maps explicit or detected formats to concrete parsers. Line-oriented and document-oriented distinctions are exposed to batch ingestion.

Parsers use `parsing.common.ParseContext` for source location and limits. Fatal conditions return a `ParseError`; recoverable issues append a structured diagnostic and set `Record.recovered`.

Format modules are intentionally independent:

- `syslog.zig` handles RFC3164-like and RFC5424 records, including structured data.
- `jsonl.zig` has a bounded JSON object scanner and typed scalar handling.
- `csv.zig` implements quote-aware rows and header mapping.
- `ini.zig` handles sections, key/value parsing, comments, and scalar coercion.
- `access_log.zig` tokenizes common/combined HTTP access records.
- `dns_zone.zig` parses directives and common resource-record structure.
- `env_file.zig` handles optional `export`, names, quoting, and sensitivity hints.
- `manifest.zig` implements only the documented indentation-based safe subset.

## Normalization

`normalization.pipeline` applies deterministic stages:

1. timestamp parsing into signed nanoseconds;
2. severity mapping into a ranked enum;
3. host/service/process/event attribution from known aliases;
4. field coercion where a source parser retained text;
5. tag extraction and deduplication;
6. network-field attribution.

Each stage reports whether it changed the record and appends diagnostics rather than hiding ambiguous conversions.

## Validation

`validation.schema` defines built-in constraints. `validation.rules` checks source format, required core values, kinds, ranges, allowed values, network values, identifier limits, and credential-like configuration names.

`validation.policy` compiles query expressions into bounded programs. A matching policy can add a note/warning/error, require or forbid a field, or add a tag. It does not execute code from input.

Findings are separate from parser diagnostics because a syntactically valid record can still violate an operational contract.

## Processing

Processing modules operate on normalized records:

- `duplicate` computes normalized fingerprints and verifies candidate equality.
- `correlation` scores deterministic evidence and creates bounded groups.
- `query_token`, `query_parser`, and `query_eval` implement the filter language.
- `aggregation` counts common dimensions and summarizes numeric/status values.
- `time_window` aligns deterministic buckets and optionally materializes gaps.
- `inventory` builds an asset catalog and reconciles observations.
- `field_stats` profiles coverage, kinds, ranges, lengths, and bounded distinct values.
- `projection` maps source fields to output columns.
- `redaction` applies explicit field-name plans before export.
- `sampling` selects reproducible subsets without randomness.
- `ordering` provides deterministic record ordering.
- `batch` connects streaming parsing and ownership.

Fixed arrays are used where explicit limits are operationally useful; allocator-aware maps/lists are used where input cardinality should remain configurable.

## Export and diagnostics

JSON and CSV exporters preserve deterministic core-field ordering, escape data, and support sensitive-field redaction. Text projection is intended for terminal inspection.

Diagnostics have a code, severity, line, column, and message. Summaries count recovery and codes. `diagnostics.health` computes a transparent local quality score from coverage, warning rate, and HTTP error context.

## Workflow and CLI

`workflow.session` handles ownership across inputs. `mixed_ingest` applies path routing and error policy. `reporting` assembles aggregate, diagnostic, validation, and quality views. `audit` records deterministic processing stages and identity hashes.

The CLI option parser uses fixed input storage and explicit enums. Command functions load a session, obtain a borrowed record view, call the public processing/export layers, and map outcomes to documented exit codes.

## Determinism

The implementation avoids wall-clock reads, random sampling, network calls, global mutable state, and iteration over unordered structures when output order matters. Hash seeds are fixed and used only for indexing, duplicate fingerprints, audit identities, or deterministic partitions.

## Extension approach

A new format should add one substantial parser, detection evidence, dispatcher routing, normalization aliases if required, positive/edge/malformed tests, examples, documentation, and a connected fuzz path. A generic plugin abstraction is deliberately absent until a real runtime need justifies its ownership and compatibility costs.

## Route metrics, drift, and configuration audit

`processing.route_metrics` groups normalized HTTP records by method and query-free path. It computes bounded status-class counts, byte and latency distributions, identifier coverage, timestamp spans, and deterministic text output. The aggregate CLI invokes this module whenever routed HTTP records are present.

`validation.drift` captures bounded field-shape snapshots and compares baseline and current data for additions, removals, incompatible kinds, coverage changes, null-rate growth, numeric-range expansion, and text-width growth. Findings are deterministically ordered and keep borrowed field names tied to the snapshot inputs.

`workflow.config_audit` checks INI, environment, and safe-manifest records together. It canonicalizes separator and case differences without allocation, validates required values and endpoint syntax, flags credential-like names, and detects conflicting values across files.
