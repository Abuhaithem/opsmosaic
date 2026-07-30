const std = @import("std");
const record_mod = @import("../model/record.zig");
const aggregation = @import("../processing/aggregation.zig");

pub const Grade = enum {
    excellent,
    good,
    degraded,
    poor,

    pub fn label(self: Grade) []const u8 {
        return switch (self) {
            .excellent => "excellent",
            .good => "good",
            .degraded => "degraded",
            .poor => "poor",
        };
    }
};

pub const Health = struct {
    grade: Grade,
    score: u8,
    timestamp_coverage: f64,
    host_coverage: f64,
    service_coverage: f64,
    warning_rate: f64,
    error_status_rate: f64,

    pub fn label(self: Health) []const u8 {
        return switch (self.grade) {
            .excellent => "excellent",
            .good => "good",
            .degraded => "degraded",
            .poor => "poor",
        };
    }
};

pub fn assess(records: []const record_mod.Record) Health {
    if (records.len == 0) return .{ .grade = .poor, .score = 0, .timestamp_coverage = 0, .host_coverage = 0, .service_coverage = 0, .warning_rate = 0, .error_status_rate = 0 };
    var timestamps: usize = 0;
    var hosts: usize = 0;
    var services: usize = 0;
    var warned: usize = 0;
    for (records) |*record| {
        if (record.timestamp_unix_ns != null) timestamps += 1;
        if (record.host != null) hosts += 1;
        if (record.service != null) services += 1;
        if (record.warnings.count != 0) warned += 1;
    }
    const total = @as(f64, @floatFromInt(records.len));
    const timestamp_coverage = @as(f64, @floatFromInt(timestamps)) / total;
    const host_coverage = @as(f64, @floatFromInt(hosts)) / total;
    const service_coverage = @as(f64, @floatFromInt(services)) / total;
    const warning_rate = @as(f64, @floatFromInt(warned)) / total;
    const status_report = aggregation.summarize(records).status;
    const error_rate = status_report.errorRate();
    var score: f64 = 100;
    score -= (1 - timestamp_coverage) * 20;
    score -= (1 - host_coverage) * 15;
    score -= (1 - service_coverage) * 15;
    score -= warning_rate * 25;
    score -= @min(error_rate, 0.5) * 20;
    const bounded: u8 = @intFromFloat(@max(0, @min(100, score)));
    return .{
        .grade = if (bounded >= 90) .excellent else if (bounded >= 75) .good else if (bounded >= 50) .degraded else .poor,
        .score = bounded,
        .timestamp_coverage = timestamp_coverage,
        .host_coverage = host_coverage,
        .service_coverage = service_coverage,
        .warning_rate = warning_rate,
        .error_status_rate = error_rate,
    };
}

pub fn writeText(health: Health, writer: anytype) !void {
    try writer.print("health: {s} ({d}/100)\n", .{ health.label(), health.score });
    try writer.print("timestamp coverage: {d:.4}\n", .{health.timestamp_coverage});
    try writer.print("host coverage: {d:.4}\n", .{health.host_coverage});
    try writer.print("service coverage: {d:.4}\n", .{health.service_coverage});
    try writer.print("warning rate: {d:.4}\n", .{health.warning_rate});
    try writer.print("HTTP error rate: {d:.4}\n", .{health.error_status_rate});
}

test "empty inputs have poor diagnostic health" {
    const result = assess(&.{});
    try std.testing.expectEqual(Grade.poor, result.grade);
}
