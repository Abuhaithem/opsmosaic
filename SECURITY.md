# Security policy

## Supported versions

| Version | Supported |
| --- | --- |
| 0.1.x | yes |

## Reporting a vulnerability

If you discover a security issue in OpsMosaic, please report it responsibly.

1. Do not open a public GitHub issue for undisclosed vulnerabilities.
2. Email the maintainers with a description of the issue, affected commands or modules, and steps to reproduce.
3. Include any relevant input samples or crash output.

We aim to acknowledge reports within a few business days and will coordinate disclosure once a fix is available.

## Scope

OpsMosaic is an offline tool. Reports are in scope when they demonstrate:

- memory corruption or undefined behavior on untrusted input;
- unexpected panics on malformed external input;
- unsafe export or redaction behavior that leaks sensitive field values;
- path handling issues that bypass documented input limits.

Reports about unsupported formats, parser limitations documented in `docs/data_formats.md`, or expected rejection of malformed YAML features outside the safe manifest subset are generally out of scope unless they demonstrate a broader safety issue.
