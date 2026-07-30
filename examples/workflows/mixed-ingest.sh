#!/usr/bin/env sh
set -eu
zig build run -- detect examples/inputs/service-events.jsonl examples/inputs/access.log
zig build run -- normalize --format jsonl examples/inputs/service-events.jsonl
zig build run -- correlate --window-seconds 300 examples/inputs/service-events.jsonl examples/inputs/system.log
