const std = @import("std");
const record_mod = @import("../model/record.zig");
const common = @import("common.zig");
const value_mod = @import("../model/value.zig");

pub fn parse(input_raw: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    const input = common.trimLine(input_raw);
    if (input.len < 2 or input[0] != '{' or input[input.len - 1] != '}') return error.InvalidSyntax;
    var record = record_mod.Record.init(.jsonl);
    common.applyContext(&record, context);
    var index: usize = 1;
    var members: usize = 0;
    while (true) {
        skipSpace(input, &index);
        if (index >= input.len - 1) break;
        if (members >= context.max_fields) {
            common.appendWarning(&record, context, .recoverable_record, index + 1, null, "JSON member limit reached");
            break;
        }
        const key = try parseString(input, &index, context.max_token_bytes);
        skipSpace(input, &index);
        if (index >= input.len or input[index] != ':') return error.InvalidSyntax;
        index += 1;
        skipSpace(input, &index);
        const parsed = try parseValue(input, &index, context, 0);
        applyKnownField(&record, key, parsed.value, context) catch return error.TooManyFields;
        members += 1;
        skipSpace(input, &index);
        if (index >= input.len - 1) break;
        if (input[index] != ',') return error.InvalidSyntax;
        index += 1;
    }
    if (record.message.len == 0) {
        if (record.getField("message")) |message| if (message.asText()) |text| record.message = text;
    }
    return record;
}

const ParsedValue = struct {
    value: record_mod.Value,
    composite: bool = false,
};

fn parseValue(input: []const u8, index: *usize, context: common.ParseContext, depth: usize) common.ParseError!ParsedValue {
    if (depth > context.max_depth) return error.UnsupportedFeature;
    if (index.* >= input.len) return error.InvalidSyntax;
    return switch (input[index.*]) {
        '"' => .{ .value = .{ .text = try parseString(input, index, context.max_token_bytes) } },
        '{' => try parseComposite(input, index, '{', '}', context, depth + 1),
        '[' => try parseComposite(input, index, '[', ']', context, depth + 1),
        else => parseBare(input, index),
    };
}

fn parseString(input: []const u8, index: *usize, max_len: usize) common.ParseError![]const u8 {
    if (index.* >= input.len or input[index.*] != '"') return error.InvalidSyntax;
    index.* += 1;
    const start = index.*;
    var escaped = false;
    while (index.* < input.len) : (index.* += 1) {
        if (index.* - start > max_len) return error.InputTooLarge;
        const ch = input[index.*];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '"') {
            const result = input[start..index.*];
            index.* += 1;
            return result;
        }
        if (ch < 0x20) return error.InvalidSyntax;
    }
    return error.InvalidSyntax;
}

fn parseComposite(input: []const u8, index: *usize, open: u8, close: u8, context: common.ParseContext, depth: usize) common.ParseError!ParsedValue {
    const start = index.*;
    var nesting: usize = 0;
    var quote = false;
    var escaped = false;
    while (index.* < input.len) : (index.* += 1) {
        if (index.* - start > context.max_token_bytes) return error.InputTooLarge;
        const ch = input[index.*];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\' and quote) {
            escaped = true;
            continue;
        }
        if (ch == '"') {
            quote = !quote;
            continue;
        }
        if (quote) continue;
        if (ch == open) nesting += 1;
        if (ch == close) {
            nesting -= 1;
            if (nesting == 0) {
                index.* += 1;
                if (depth > context.max_depth) return error.UnsupportedFeature;
                return .{ .value = .{ .text = input[start..index.*] }, .composite = true };
            }
        }
    }
    return error.InvalidSyntax;
}

fn parseBare(input: []const u8, index: *usize) ParsedValue {
    const start = index.*;
    while (index.* < input.len) : (index.* += 1) {
        const ch = input[index.*];
        if (ch == ',' or ch == '}' or ch == ']') break;
    }
    return .{ .value = value_mod.parseScalar(input[start..index.*]) };
}

fn skipSpace(input: []const u8, index: *usize) void {
    while (index.* < input.len and (input[index.*] == ' ' or input[index.*] == '\t' or input[index.*] == '\r' or input[index.*] == '\n')) index.* += 1;
}

fn applyKnownField(record: *record_mod.Record, key: []const u8, value: record_mod.Value, context: common.ParseContext) common.ParseError!void {
    if (std.mem.eql(u8, key, "timestamp") or std.mem.eql(u8, key, "time") or std.mem.eql(u8, key, "@timestamp")) {
        if (value.asText()) |text| record.timestamp_text = text else try common.addFieldRecovering(record, key, value, context);
    } else if (std.mem.eql(u8, key, "host") or std.mem.eql(u8, key, "hostname")) {
        if (value.asText()) |text| record.host = text else try common.addFieldRecovering(record, key, value, context);
    } else if (std.mem.eql(u8, key, "service") or std.mem.eql(u8, key, "app")) {
        if (value.asText()) |text| record.service = text else try common.addFieldRecovering(record, key, value, context);
    } else if (std.mem.eql(u8, key, "message") or std.mem.eql(u8, key, "msg")) {
        if (value.asText()) |text| record.message = text else try common.addFieldRecovering(record, key, value, context);
    } else if (std.mem.eql(u8, key, "severity") or std.mem.eql(u8, key, "level")) {
        if (value.asText()) |text| record.severity = severityFromText(text) else try common.addFieldRecovering(record, key, value, context);
    } else if (std.mem.eql(u8, key, "event_id")) {
        if (value.asText()) |text| record.event_id = text else try common.addFieldRecovering(record, key, value, context);
    } else if (std.mem.eql(u8, key, "request_id")) {
        if (value.asText()) |text| record.request_id = text else try common.addFieldRecovering(record, key, value, context);
    } else if (std.mem.eql(u8, key, "trace_id")) {
        if (value.asText()) |text| record.trace_id = text else try common.addFieldRecovering(record, key, value, context);
    } else if (std.mem.eql(u8, key, "source_address") or std.mem.eql(u8, key, "client_ip")) {
        if (value.asText()) |text| record.network.source_address = text else try common.addFieldRecovering(record, key, value, context);
    } else if (std.mem.eql(u8, key, "status")) {
        if (value.asInteger()) |number| {
            if (number >= 0 and number <= 999) record.network.status = @intCast(number) else try common.addFieldRecovering(record, key, value, context);
        } else try common.addFieldRecovering(record, key, value, context);
    } else {
        try common.addFieldRecovering(record, key, value, context);
    }
}

fn severityFromText(input: []const u8) record_mod.Severity {
    if (std.ascii.eqlIgnoreCase(input, "trace")) return .trace;
    if (std.ascii.eqlIgnoreCase(input, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(input, "info") or std.ascii.eqlIgnoreCase(input, "information")) return .info;
    if (std.ascii.eqlIgnoreCase(input, "notice")) return .notice;
    if (std.ascii.eqlIgnoreCase(input, "warn") or std.ascii.eqlIgnoreCase(input, "warning")) return .warning;
    if (std.ascii.eqlIgnoreCase(input, "error") or std.ascii.eqlIgnoreCase(input, "err")) return .error;
    if (std.ascii.eqlIgnoreCase(input, "critical") or std.ascii.eqlIgnoreCase(input, "fatal")) return .critical;
    if (std.ascii.eqlIgnoreCase(input, "alert")) return .alert;
    if (std.ascii.eqlIgnoreCase(input, "emergency")) return .emergency;
    return .unknown;
}

test "JSON Lines parser maps common operational fields" {
    const record = try parse("{\"timestamp\":\"2026-07-30T07:00:00Z\",\"host\":\"api-1\",\"level\":\"warn\",\"status\":503,\"message\":\"upstream slow\"}", .{});
    try std.testing.expectEqual(record_mod.Severity.warning, record.severity);
    try std.testing.expectEqual(@as(u16, 503), record.network.status.?);
}
