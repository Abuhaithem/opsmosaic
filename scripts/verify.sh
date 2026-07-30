#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

zig version
zig build
zig build test
zig build example

if git ls-files | grep -E '(^|/)(\.zig-cache|zig-out)/' >/dev/null; then
  echo "build output is tracked by Git" >&2
  exit 1
fi

echo "verification complete"
