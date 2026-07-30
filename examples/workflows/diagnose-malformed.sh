#!/usr/bin/env sh
set -eu
zig build run -- diagnose --format jsonl examples/inputs/malformed-mixed.log
