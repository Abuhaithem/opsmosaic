# Query language

## Evaluation model

A query is lexed and parsed once into a fixed-size `Program`. Program nodes refer to slices in the original query text, so the query buffer must outlive evaluation. The evaluator receives normalized `Record` values.

Default limits:

- 4,096 bytes per token;
- 256 nodes;
- nesting depth 32 during parse;
- evaluation depth 64.

Limit violations are errors, not truncated expressions.

## Values

Literals:

```text
"quoted text"
'unquoted support depends on token syntax'
identifier
42
-7
3.1415
1.5e3
true
false
null
```

Identifiers without whitespace can be used as text values. Quote values containing spaces or operator characters.

Numeric comparisons coerce integer and decimal values to a common numeric representation. Text comparisons are bytewise unless `--case-insensitive` is set for equality/string operators. Severity text uses normalized severity rank for ordered comparisons.

## Fields

Core fields include:

```text
timestamp
timestamp_ns
severity
host
service
process_id
event_id
request_id
trace_id
message
source_format
source_address
destination_address
method
path
status
bytes
tag_count
warning_count
```

Additional normalized source fields are addressed by their exact key, including dotted JSON or structured-data names.

## Operators

Equality and inequality:

```text
service == gateway
status != 200
```

Ordering:

```text
status >= 500
duration_ms < 250
severity >= warning
```

Text operators:

```text
message contains timeout
service starts_with payments
path ends_with .json
```

Tag and presence operations:

```text
has(prod)
has("incident review")
missing(trace_id)
not missing(service)
```

## Logical precedence

Highest to lowest:

1. parentheses;
2. `not`;
3. comparison, `has`, or `missing` predicate;
4. `and`;
5. `or`.

Therefore:

```text
severity >= error or status >= 500 and has(prod)
```

means:

```text
severity >= error or (status >= 500 and has(prod))
```

Use parentheses when incident-review intent would otherwise be ambiguous.

## Missing fields

`missing(field)` is the clearest presence test. By default, a missing field may compare equal to `null` when evaluator option `missing_is_null` is enabled. Other comparisons against missing fields are false. Negating a false comparison is logically true, so prefer explicit `missing` checks when absence matters.

## Examples

Production warnings or above:

```text
severity >= warning and has(prod)
```

Server errors on payment paths:

```text
status >= 500 and status < 600 and path starts_with /v1/payments
```

Records without distributed tracing:

```text
missing(trace_id) and severity >= error
```

Gateway retries from an address prefix:

```text
service == gateway and message contains retry and source_address starts_with 192.0.2.
```

Events with either a request or trace identifier:

```text
not missing(request_id) or not missing(trace_id)
```

Exclude health probes:

```text
not (path == /health or path == /ready)
```

## Complexity and safety

The language has no functions that read files, inspect the environment, execute commands, allocate unbounded structures, use regular expressions, or access the network. Parsing is iterative/recursive only within explicit depth limits. Evaluation walks the bounded program tree for each record.
