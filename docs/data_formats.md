# Supported data formats

## Common parser contract

All parsers return a normalized-record precursor through `parsing.dispatcher`. Source line, column, byte offset, requested limits, and optional path travel in `ParseContext`.

A parser must distinguish:

- fatal syntax or resource errors that prevent a meaningful record;
- recoverable omissions or invalid optional fields;
- raw source values retained for normalization;
- normalized core attributes promoted by the parser when unambiguous.

Per-record bounds are 64 fields, 24 tags, and 64 parser diagnostics. The default line limit is 1 MiB and default input limit is 64 MiB.

## Syslog and RFC5424

RFC3164-like input:

```text
<34>Jul 30 07:00:02 edge-01 sshd[442]: accepted public key
```

The parser extracts priority, timestamp text, host, service, optional PID, and message. Facility and severity are derived from priority when valid.

RFC5424 input:

```text
<165>1 2026-07-30T07:01:14Z edge-01 gateway 812 GW-RETRY [trace@32473 id="tr-88" request="req-119"] retry scheduled
```

Supported structured data includes multiple elements, parameter names, quoted values, and RFC-style escaping. Parameters are flattened into fields using a stable element/parameter name. Nil values (`-`) are accepted for optional header fields.

Malformed priority, incomplete headers, unclosed structured data, excessive fields, or oversized values produce errors or recovery diagnostics.

## JSON Lines

One JSON object is one operational record. Supported values are strings, integers, finite floating-point numbers, booleans, null, arrays of scalar tags, and bounded nested objects flattened with dotted field names.

Core aliases such as `timestamp`, `severity`, `host`, `service`, `event_id`, `request_id`, `trace_id`, `message`, `status`, `bytes`, and common network names are promoted during parsing or normalization.

Top-level non-object values, unterminated strings, invalid escapes, non-finite numeric text, excessive nesting, excessive fields, and trailing non-whitespace are rejected. Duplicate object names are handled deterministically and diagnosed.

## CSV inventory

CSV parsing is quote-aware and supports doubled quotes, empty cells, CRLF, and typed scalar coercion. A document parser uses the first row as the header and emits a record for each data row in batch workflows.

Header names must be non-empty after trimming. Rows with missing cells receive null/empty behavior according to parser options. Extra cells are diagnosed rather than silently mapped to invented columns.

OpsMosaic does not infer locale-specific decimal separators or spreadsheet formulas. Cell contents are data only.

## INI

Supported syntax:

```ini
[server]
host = edge-01.example
port = 8443
```

Sections, key/value lines, blank lines, semicolon comments, hash comments, quoted scalar values, integers, decimals, booleans, and null-like values are supported. Section context is retained in field naming/metadata where appropriate.

Unclosed section names, empty keys, invalid lines, and limit violations produce diagnostics. Continuation syntax and interpolation are not implemented.

## HTTP access logs

Common and combined log shapes are supported:

```text
192.0.2.1 - - [30/Jul/2026:07:00:00 +0000] "GET /health HTTP/1.1" 200 32
```

```text
198.51.100.8 - user [30/Jul/2026:07:01:14 +0000] "POST /v1/payments HTTP/1.1" 502 184 "https://console.example" "client/7.1"
```

The parser extracts source address, timestamp text, method, path, protocol, status, bytes, referrer, user agent, and message. `-` is accepted for missing byte counts and optional identity fields.

Quoted-token recovery is bounded. Invalid status or byte values are diagnosed and do not cause unchecked integer conversion.

## DNS zone-style records

Supported directives include `$ORIGIN` and `$TTL`. Resource records follow the practical sequence:

```text
owner [ttl] [class] type rdata...
```

Common types such as A, AAAA, CNAME, NS, MX, TXT, SRV, PTR, CAA, and SOA are retained as structured fields. Owner, TTL, class, type, and remaining record data are preserved.

This is an offline review parser, not an authoritative DNS server. It does not perform name resolution, zone transfer, DNSSEC validation, or network lookups. Parenthesized multi-line SOA input is bounded and represented according to documented recovery behavior.

## Environment files

Supported forms:

```text
NAME=value
export NAME="quoted value"
EMPTY=
```

Names use a conservative shell-compatible identifier subset. Single/double quotes and scalar coercion are supported. Shell command substitution, arithmetic expansion, process substitution, and executing sourced files are never performed.

Names containing password, secret, token, private-key, API-key, or credential terms receive sensitivity warnings. Exporters redact matching field names by default.

## Safe manifest subset

Supported:

- indentation-based mappings;
- nested mappings;
- dash-prefixed lists;
- strings and quoted strings;
- signed integers and finite decimals;
- booleans;
- null-like values;
- comments;
- bounded depth and field count.

Example:

```yaml
service:
  name: gateway
  replicas: 3
  tags:
    - edge
    - prod
```

Explicitly unsupported and rejected:

- anchors and aliases (`&name`, `*name`);
- custom tags (`!type`);
- directives (`%YAML`);
- document merge keys;
- flow mappings and lists (`{}`, `[]`);
- block literals/folded scalars (`|`, `>`);
- multiple documents;
- implicit date/timestamp typing;
- arbitrary object construction.

The parser does not claim YAML conformance.

## Invalid bytes and UTF-8

Parsers are byte-oriented unless a syntax rule requires ASCII classification. They do not panic on invalid UTF-8. JSON export escapes control bytes. OpsMosaic does not normalize Unicode, infer encodings, or repair arbitrary binary input.
