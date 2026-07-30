# Changelog

All notable changes to OpsMosaic are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Query, aggregation, correlation, and export workflows for normalized operational records.
- Built-in schemas for service events, HTTP access records, inventories, and deployment manifests.
- Diagnostics and health reporting for parse recovery and data-quality review.
- libFuzzer harnesses with ClusterFuzzLite integration.

## [0.1.0] - 2026-07-30

### Added
- Initial public release of the OpsMosaic library and CLI.
- First-party parsers for syslog, RFC5424, JSON Lines, CSV, INI, HTTP access logs, DNS zone records, environment files, and a safe deployment-manifest subset.
- Normalization pipeline for timestamps, severity, attribution, tags, and network fields.
- Validation, policy evaluation, duplicate detection, and deterministic export formats.
- Example fixtures, workflow scripts, and architecture documentation.

[Unreleased]: https://github.com/opsmosaic/opsmosaic/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/opsmosaic/opsmosaic/releases/tag/v0.1.0
