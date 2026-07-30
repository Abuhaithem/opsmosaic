#!/usr/bin/env sh
set -eu
zig build run -- validate --format access-log --schema http-event examples/inputs/access.log
zig build run -- query --format jsonl --where 'severity >= warning and has(prod)' examples/inputs/service-events.jsonl
zig build run -- export --format jsonl --to csv --columns timestamp,severity,host,service,status,message examples/inputs/service-events.jsonl
