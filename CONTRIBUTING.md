# Contributing to OpsMosaic

Thank you for your interest in contributing. OpsMosaic is an offline operational data workbench written in Zig. This document describes how to set up a development environment, run checks locally, and submit changes.

## Development setup

1. Install [Zig 0.13.0](https://ziglang.org/download/).
2. Clone the repository and build from the root:

```sh
zig build
```

3. Run the full test suite:

```sh
zig build test
```

4. Build the library usage example:

```sh
zig build example
```

The CLI binary is installed to `zig-out/bin/opsmosaic`. Use `zig build run -- <command>` during development.

## Project layout

```text
src/          library and CLI implementation
tests/        integration tests
examples/     fixtures, schemas, and workflow scripts
docs/         architecture and format documentation
fuzz/         libFuzzer harnesses and seed corpora
scripts/      local verification helpers
```

Low-level parsers do not import CLI modules. Exporters consume normalized records and never reparse raw input. See `docs/architecture.md` for dependency boundaries and ownership rules.

## Making changes

1. Create a focused branch from `main`.
2. Keep changes scoped to the behavior you are adding or fixing.
3. Add or update tests when behavior changes.
4. Update user-facing documentation when CLI options, schemas, or supported formats change.
5. Run `scripts/verify.sh` before opening a pull request.

## Coding conventions

- Match the surrounding module style, naming, and allocator patterns.
- Prefer explicit bounds and deterministic output over hidden allocation or global state.
- Parser code must not panic on malformed external input.
- Use structured diagnostics for recoverable parser issues.
- Keep public API changes in `src/root.zig` intentional and documented.

## Tests

Unit tests live alongside source modules. Integration coverage is under `tests/`. Tests use deterministic fixtures and do not require network access.

```sh
zig build test
```

When adding a parser or format, include positive, edge, and malformed cases. Add representative examples under `examples/inputs/` when they help demonstrate real usage.

## Fuzzing

Five libFuzzer-compatible harnesses exercise parsers, normalization, validation, and exporters:

```text
fuzz/syslog_fuzzer.zig
fuzz/jsonl_fuzzer.zig
fuzz/config_fuzzer.zig
fuzz/csv_fuzzer.zig
fuzz/accesslog_fuzzer.zig
```

ClusterFuzzLite metadata is under `.clusterfuzzlite/`. Seed corpora contain realistic operational records, including malformed-but-plausible inputs.

## Pull requests

- Describe the problem, the approach, and any trade-offs.
- Note user-visible CLI or schema changes.
- Link related issues when applicable.
- Ensure CI passes before requesting review.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
