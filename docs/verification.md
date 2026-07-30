# Development and CI

## Local verification

Run the project checks from a clean checkout with Zig 0.13.0 and Git available:

```sh
scripts/verify.sh
```

The script performs:

1. `zig version`;
2. `zig build`;
3. `zig build test`;
4. `zig build example`;
5. check that `.zig-cache` and `zig-out` are not tracked by Git.

## Continuous integration

GitHub Actions runs the same checks on pushes and pull requests to `main` and `master`. See `.github/workflows/ci.yml`.

## Fuzzing

ClusterFuzzLite builds run in a fuzzing image that provides `SRC`, `OUT`, `CXX`, `CXXFLAGS`, and `LIB_FUZZING_ENGINE`:

```sh
.clusterfuzzlite/build.sh
```

The script compiles five Zig static archives containing `LLVMFuzzerTestOneInput` entry points, links the environment-provided fuzzing engine and sanitizers, writes binaries directly to `$OUT`, and checks executable bits.

## Repository hygiene

Do not commit generated Zig caches, installed binaries, fuzz work directories, or downloaded compilers.
