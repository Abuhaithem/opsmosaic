# Verification procedure

The repository includes `scripts/verify.sh`. Run it from a clean checkout with Zig 0.13.0 and Git available:

```sh
scripts/verify.sh
```

It performs:

1. `zig version`;
2. `zig build`;
3. `zig build test`;
4. `zig build example`;
5. meaningful nonblank and physical `src/**/*.zig` line-count range checks;
6. meaningful source-module count check;
7. Git commit-count check;
8. local Git identity check;
9. scan for artificial defect-control identifiers;
10. scan for common absolute machine-specific paths;
11. check that `.zig-cache` and `zig-out` are not tracked by Git.

ClusterFuzzLite harness verification is performed in a fuzzing build image that provides `SRC`, `OUT`, `CXX`, `CXXFLAGS`, and `LIB_FUZZING_ENGINE`:

```sh
.clusterfuzzlite/build.sh
```

The script compiles five Zig static archives containing real `LLVMFuzzerTestOneInput` entry points, links the environment-provided fuzzing engine and sanitizers, writes binaries directly to `$OUT`, and checks executable bits.

Do not commit generated Zig caches, installed binaries, fuzz work directories, or downloaded compilers.
