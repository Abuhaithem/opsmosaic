const std = @import("std");
const record_mod = @import("../model/record.zig");

pub const MappingSource = enum {
    explicit,
    syslog_priority,
    http_status,
    message_keyword,
    default,
};

pub const Result = struct {
    severity: record_mod.Severity,
    source: MappingSource,
    confidence: u8,
};

pub fn normalizeRecord(record: *record_mod.Record) Result {
    if (record.severity != .unknown) return .{ .severity = record.severity, .source = .explicit, .confidence = 100 };
    if (record.getField("severity")) |value| {
        if (value.asText()) |text| {
            const result = fromText(text);
            if (result.severity != .unknown) {
                record.severity = result.severity;
                return result;
            }
        }
    }
    if (record.getField("level")) |value| {
        if (value.asText()) |text| {
            const result = fromText(text);
            if (result.severity != .unknown) {
                record.severity = result.severity;
                return result;
            }
        }
    }
    if (record.network.status) |status| {
        const result = fromHttpStatus(status);
        record.severity = result.severity;
        return result;
    }
    const result = fromMessage(record.message);
    record.severity = result.severity;
    return result;
}

pub fn fromText(input_raw: []const u8) Result {
    const input = std.mem.trim(u8, input_raw, " \t\r\n");
    const severity: record_mod.Severity = if (anyEqual(input, &.{ "trace", "verbose", "finest" })) .trace
    else if (anyEqual(input, &.{ "debug", "dbg", "fine", "finer" })) .debug
    else if (anyEqual(input, &.{ "info", "information", "informational", "normal", "ok" })) .info
    else if (anyEqual(input, &.{ "notice", "audit", "success" })) .notice
    else if (anyEqual(input, &.{ "warn", "warning", "degraded", "slow" })) .warning
    else if (anyEqual(input, &.{ "err", "error", "failure", "failed" })) .@"error"
    else if (anyEqual(input, &.{ "crit", "critical", "fatal", "panic" })) .critical
    else if (anyEqual(input, &.{ "alert", "page" })) .alert
    else if (anyEqual(input, &.{ "emerg", "emergency", "unavailable" })) .emergency
    else .unknown;
    return .{ .severity = severity, .source = .explicit, .confidence = if (severity == .unknown) 0 else 100 };
}

pub fn fromHttpStatus(status: u16) Result {
    if (status >= 500) return .{ .severity = .@"error", .source = .http_status, .confidence = 95 };
    if (status == 429) return .{ .severity = .warning, .source = .http_status, .confidence = 95 };
    if (status >= 400) return .{ .severity = .warning, .source = .http_status, .confidence = 90 };
    if (status >= 300) return .{ .severity = .notice, .source = .http_status, .confidence = 85 };
    if (status >= 200) return .{ .severity = .info, .source = .http_status, .confidence = 90 };
    if (status >= 100) return .{ .severity = .debug, .source = .http_status, .confidence = 80 };
    return .{ .severity = .unknown, .source = .http_status, .confidence = 0 };
}

pub fn fromSyslogCode(code: u8) Result {
    const severity: record_mod.Severity = switch (code) {
        0 => .emergency,
        1 => .alert,
        2 => .critical,
        3 => .@"error",
        4 => .warning,
        5 => .notice,
        6 => .info,
        7 => .debug,
        else => .unknown,
    };
    return .{ .severity = severity, .source = .syslog_priority, .confidence = if (severity == .unknown) 0 else 100 };
}

pub fn fromMessage(message: []const u8) Result {
    const groups = [_]struct { severity: record_mod.Severity, confidence: u8, needles: []const []const u8 }{
        .{ .severity = .emergency, .confidence = 85, .needles = &.{ "service unavailable", "total outage", "data loss imminent" } },
        .{ .severity = .critical, .confidence = 82, .needles = &.{ "panic", "fatal", "corruption", "out of memory" } },
        .{ .severity = .@"error", .confidence = 78, .needles = &.{ "error", "failed", "refused", "timeout" } },
        .{ .severity = .warning, .confidence = 72, .needles = &.{ "warn", "degraded", "retry", "slow" } },
        .{ .severity = .debug, .confidence = 65, .needles = &.{ "debug", "trace", "diagnostic" } },
    };
    for (groups) |group| {
        for (group.needles) |needle| { if (containsIgnoreCase(message, needle)) return .{ .severity = group.severity, .source = .message_keyword, .confidence = group.confidence }; }
    }
    return .{ .severity = .info, .source = .default, .confidence = 40 };
}

pub fn atLeast(value: record_mod.Severity, minimum: record_mod.Severity) bool {
    if (value == .unknown) return false;
    return value.rank() >= minimum.rank();
}

pub fn between(value: record_mod.Severity, low: record_mod.Severity, high: record_mod.Severity) bool {
    if (value == .unknown) return false;
    return value.rank() >= low.rank() and value.rank() <= high.rank();
}

fn anyEqual(input: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| { if (std.ascii.eqlIgnoreCase(input, candidate)) return true; }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "HTTP severity mapping distinguishes client and server errors" {
    try std.testing.expectEqual(record_mod.Severity.warning, fromHttpStatus(404).severity);
    try std.testing.expectEqual(record_mod.Severity.@"error", fromHttpStatus(503).severity);
}
