#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

zig version
zig build
zig build test
zig build example

physical_src_loc="$(find src -type f -name '*.zig' -print0 | xargs -0 cat | wc -l | tr -d ' ')"
meaningful_src_loc="$(scripts/count-src-loc.sh)"
if (( meaningful_src_loc < 8500 || physical_src_loc > 16000 )); then
  echo "source LOC outside required range: meaningful=$meaningful_src_loc physical=$physical_src_loc" >&2
  exit 1
fi

module_count="$(find src -type f -name '*.zig' | wc -l | tr -d ' ')"
if (( module_count < 25 )); then
  echo "too few source modules: $module_count" >&2
  exit 1
fi

commit_count="$(git rev-list --count HEAD)"
if (( commit_count < 60 || commit_count > 100 )); then
  echo "commit count outside required range: $commit_count" >&2
  exit 1
fi

test "$(git config --local user.name)" = "Abuhaithem"
test "$(git config --local user.email)" = "abuhaithemalthry@gmail.com"

if grep -R -n -E 'FUZZ_FAULTS|TEST_CRASH|BUG_TRIGGER|BENCHMARK_DEFECT|HIDDEN_PATH|FORCE_FAILURE' src fuzz tests; then
  echo "forbidden artificial defect marker found" >&2
  exit 1
fi

if grep -R -n -E '/Users/|/home/[A-Za-z0-9_-]+|[A-Za-z]:\\\\Users\\\\' --exclude-dir=.git --exclude=verify.sh .; then
  echo "machine-specific path found" >&2
  exit 1
fi

if git ls-files | grep -E '(^|/)(\.zig-cache|zig-out)/' >/dev/null; then
  echo "build output is tracked by Git" >&2
  exit 1
fi

echo "verification complete: meaningful_src_loc=$meaningful_src_loc physical_src_loc=$physical_src_loc modules=$module_count commits=$commit_count"
