#!/usr/bin/env bash
set -euo pipefail
find src -type f -name '*.zig' -print0 \
  | sort -z \
  | xargs -0 awk 'NF { meaningful += 1 } END { print meaningful }'
