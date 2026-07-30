const std = @import("std");
const record_mod = @import("../model/record.zig");
const schema_mod = @import("schema.zig");
const finding_mod = @import("finding.zig");
const env_parser = @import("../parsing/env_file.zig");

pub const Options = struct {
    unknown_fields_are_errors: bool = false,
    recommended_fields_are_warnings: bool = true,
    reject_sensitive_configuration: bool = false,
    require_normalized_timestamp: bool = false,
};

pub fn validate(record: *const record_mod.Record, schema: schema_mod.Schema, options: Options) finding_mod.FindingBuffer {
    var findings = finding_mod.FindingBuffer{};
    validateFormat(record, schema, &findings);
    validateCore(record, schema, options, &findings);
    validateFields(record, schema, options, &findings);
    validateNetwork(record, &findings);
    validateIdentifiers(record, &findings);
    validateConfiguration(record, options, &findings);
    return findings;
}

fn validateFormat(record: *const record_mod.Record, schema: schema_mod.Schema, findings: *finding_mod.FindingBuffer) void {
    if (!schema.acceptsFormat(record.source.format)) findings.append(.{
        .level = .@"error",
        .rule = "schema.format",
        .line = record.source.line,
        .message = "record format is not accepted by the selected schema",
        .expected = schema.name,
        .actual = record.source.format.label(),
    });
}

fn validateCore(record: *const record_mod.Record, schema: schema_mod.Schema, options: Options, findings: *finding_mod.FindingBuffer) void {
    if (schema.require_timestamp and record.timestamp_text == null) appendMissing(findings, record, "timestamp");
    if (schema.require_host and record.host == null) appendMissing(findings, record, "host");
    if (schema.require_service and record.service == null) appendMissing(findings, record, "service");
    if (schema.require_message and record.message.len == 0) appendMissing(findings, record, "message");
    if (options.require_normalized_timestamp and record.timestamp_text != null and record.timestamp_unix_ns == null) findings.append(.{
        .level = .@"error",
        .rule = "timestamp.normalized",
        .field = "timestamp",
        .line = record.source.line,
        .message = "timestamp exists but normalization failed",
    });
    if (!record.validateInternal()) findings.append(.{
        .level = .@"error",
        .rule = "record.internal",
        .line = record.source.line,
        .message = "record counters exceed fixed storage bounds",
    });
}

fn appendMissing(findings: *finding_mod.FindingBuffer, record: *const record_mod.Record, field: []const u8) void {
    findings.append(.{
        .level = .@"error",
        .rule = "field.required",
        .field = field,
        .line = record.source.line,
        .message = "required field is absent",
    });
}

fn validateFields(record: *const record_mod.Record, schema: schema_mod.Schema, options: Options, findings: *finding_mod.FindingBuffer) void {
    for (schema.fields) |constraint| {
        const value = record.getField(constraint.name);
        if (value == null) {
            if (constraint.requirement == .required) appendMissing(findings, record, constraint.name)
            else if (constraint.requirement == .recommended and options.recommended_fields_are_warnings) findings.append(.{
                .level = .warning,
                .rule = "field.recommended",
                .field = constraint.name,
                .line = record.source.line,
                .message = "recommended field is absent",
            });
            continue;
        }
        if (!constraint.validatesKind(value.?)) findings.append(.{
            .level = .@"error",
            .rule = "field.type",
            .field = constraint.name,
            .line = record.source.line,
            .message = "field has an incompatible value kind",
        });
        if (!constraint.validatesRange(value.?)) findings.append(.{
            .level = .@"error",
            .rule = "field.range",
            .field = constraint.name,
            .line = record.source.line,
            .message = "field is outside the permitted range or length",
        });
        if (!constraint.validatesAllowed(value.?)) findings.append(.{
            .level = .@"error",
            .rule = "field.allowed",
            .field = constraint.name,
            .line = record.source.line,
            .message = "field value is not in the allowed set",
        });
    }
    if (!schema.allow_unknown_fields) {
        for (record.fieldSlice()) |field| if (schema.findConstraint(field.key) == null) findings.append(.{
            .level = if (options.unknown_fields_are_errors) .@"error" else .warning,
            .rule = "field.unknown",
            .field = field.key,
            .line = record.source.line,
            .message = "field is not declared by the schema",
        });
    }
}

fn validateNetwork(record: *const record_mod.Record, findings: *finding_mod.FindingBuffer) void {
    if (record.network.status) |status| if (status < 100 or status > 599) findings.append(.{
        .level = .warning,
        .rule = "http.status",
        .field = "status",
        .line = record.source.line,
        .message = "HTTP-like status lies outside the standard range",
    });
    if (record.network.source_port) |port| if (port == 0) findings.append(.{
        .level = .warning,
        .rule = "network.source_port",
        .field = "source_port",
        .line = record.source.line,
        .message = "source port zero is unusual for an observed connection",
    });
    if (record.network.destination_port) |port| if (port == 0) findings.append(.{
        .level = .warning,
        .rule = "network.destination_port",
        .field = "destination_port",
        .line = record.source.line,
        .message = "destination port zero is unusual for an observed connection",
    });
}

fn validateIdentifiers(record: *const record_mod.Record, findings: *finding_mod.FindingBuffer) void {
    const values = [_]struct { name: []const u8, value: ?[]const u8 }{
        .{ .name = "event_id", .value = record.event_id },
        .{ .name = "request_id", .value = record.request_id },
        .{ .name = "trace_id", .value = record.trace_id },
    };
    for (values) |entry| if (entry.value) |value| {
        if (value.len > 256) findings.append(.{ .level = .@"error", .rule = "identifier.length", .field = entry.name, .line = record.source.line, .message = "identifier exceeds 256 bytes" });
        if (containsControl(value)) findings.append(.{ .level = .@"error", .rule = "identifier.control", .field = entry.name, .line = record.source.line, .message = "identifier contains control bytes" });
    };
}

fn validateConfiguration(record: *const record_mod.Record, options: Options, findings: *finding_mod.FindingBuffer) void {
    if (record.source.format != .env_file) return;
    for (record.fieldSlice()) |field| if (env_parser.looksSensitiveName(field.key)) findings.append(.{
        .level = if (options.reject_sensitive_configuration) .@"error" else .warning,
        .rule = "configuration.sensitive-name",
        .field = field.key,
        .line = record.source.line,
        .message = "configuration contains a credential-like variable name; exported reports should redact its value",
    });
}

fn containsControl(input: []const u8) bool {
    for (input) |ch| { if (ch < 0x20 or ch == 0x7f) return true; }
    return false;
}

test "validation reports missing required core fields" {
    const record = record_mod.Record.init(.jsonl);
    const findings = validate(&record, schema_mod.service_event, .{});
    try std.testing.expect(findings.errorCount() >= 3);
}
