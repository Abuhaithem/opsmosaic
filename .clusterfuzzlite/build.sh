#!/usr/bin/env bash
set -euo pipefail

: "${SRC:?ClusterFuzzLite must set SRC}"
: "${OUT:?ClusterFuzzLite must set OUT}"
: "${CXX:?ClusterFuzzLite must set CXX}"
: "${LIB_FUZZING_ENGINE:?ClusterFuzzLite must set LIB_FUZZING_ENGINE}"

ZIG="${ZIG:-zig}"
PROJECT="$SRC"
TARGETS=(
  syslog_fuzzer
  jsonl_fuzzer
  config_fuzzer
  csv_fuzzer
  accesslog_fuzzer
)

mkdir -p "$OUT"
work_dir="${WORK:-/tmp}/opsmosaic-fuzz-build"
rm -rf "$work_dir"
mkdir -p "$work_dir"

for target in "${TARGETS[@]}"; do
  archive="$work_dir/lib${target}.a"
  "$ZIG" build-lib \
    -OReleaseSafe \
    -fPIC \
    -fno-stack-check \
    -femit-bin="$archive" \
    --dep opsmosaic \
    -Mroot="$PROJECT/fuzz/${target}.zig" \
    -Mopsmosaic="$PROJECT/src/root.zig"

  # CXX and LIB_FUZZING_ENGINE are supplied by the fuzzing environment so
  # sanitizer and libFuzzer runtime selection remains platform-controlled.
  "$CXX" ${CXXFLAGS:-} ${LIB_FUZZING_ENGINE} "$archive" -o "$OUT/$target"
  test -x "$OUT/$target"
done

for target in "${TARGETS[@]}"; do
  test -x "$OUT/$target"
done
