const std = @import("std");
const record_mod = @import("../model/record.zig");
const aggregation = @import("../processing/aggregation.zig");
const diagnostics = @import("../diagnostics/summary.zig");
const health = @import("../diagnostics/health.zig");
const validation_report = @import("../validation/report.zig");

pub const Report = struct {
    ingestion_inputs: usize = 0,
    ingestion_bytes: usize = 0,
    ingestion_failures: usize = 0,
    aggregate: aggregation.Report = .{},
    diagnostic: diagnostics.Summary = .{},
    quality: health.Health,
    validation: validation_report.Summary = .{},

    pub fn hasOperationalErrors(self: Report) bool {
        return self.ingestion_failures != 0 or self.diagnostic.errors != 0 or self.validation.errors != 0;
    }
};

pub fn build(records: []const record_mod.Record) Report {
    var diagnostic = diagnostics.Summary{};
    for (records) |*record| diagnostic.observeRecord(record);
    return .{
        .aggregate = aggregation.summarize(records),
        .diagnostic = diagnostic,
        .quality = health.assess(records),
    };
}

pub fn writeText(report: Report, writer: anytype) !void {
    try writer.writeAll("OpsMosaic operational report\n");
    try writer.print("inputs: {d}\n", .{report.ingestion_inputs});
    try writer.print("bytes: {d}\n", .{report.ingestion_bytes});
    try writer.print("ingestion failures: {d}\n", .{report.ingestion_failures});
    try writer.print("records: {d}\n", .{report.aggregate.record_count});
    try writer.writeAll("quality ");
    try health.writeText(report.quality, writer);
    try writer.writeAll("diagnostics ");
    try report.diagnostic.writeText(writer);
    try writer.writeAll("validation ");
    try report.validation.writeText(writer);
    try writer.writeByte('\n');
    try writeCountTable("severity", &report.aggregate.by_severity, writer);
    try writeCountTable("service", &report.aggregate.by_service, writer);
    try writeCountTable("format", &report.aggregate.by_format, writer);
    try writeCountTable("tag", &report.aggregate.by_tag, writer);
    try writer.print("http statuses: 1xx={d} 2xx={d} 3xx={d} 4xx={d} 5xx={d} other={d}\n", .{
        report.aggregate.status.informational,
        report.aggregate.status.success,
        report.aggregate.status.redirection,
        report.aggregate.status.client_error,
        report.aggregate.status.server_error,
        report.aggregate.status.other,
    });
}

pub fn writeJson(report: Report, writer: anytype) !void {
    try writer.print("{{\"inputs\":{d},\"bytes\":{d},\"ingestion_failures\":{d},\"records\":{d}", .{
        report.ingestion_inputs, report.ingestion_bytes, report.ingestion_failures, report.aggregate.record_count,
    });
    try writer.print(",\"quality\":{{\"grade\":\"{s}\",\"score\":{d}}}", .{ report.quality.grade.label(), report.quality.score });
    try writer.print(",\"diagnostics\":{{\"notes\":{d},\"warnings\":{d},\"errors\":{d}}}", .{
        report.diagnostic.notes, report.diagnostic.warnings, report.diagnostic.errors,
    });
    try writer.print(",\"validation\":{{\"accepted\":{d},\"rejected\":{d},\"warnings\":{d},\"errors\":{d}}}", .{
        report.validation.accepted, report.validation.rejected, report.validation.warnings, report.validation.errors,
    });
    try writer.writeAll(",\"by_severity\":");
    try writeCountTableJson(&report.aggregate.by_severity, writer);
    try writer.writeAll(",\"by_service\":");
    try writeCountTableJson(&report.aggregate.by_service, writer);
    try writer.writeAll(",\"by_format\":");
    try writeCountTableJson(&report.aggregate.by_format, writer);
    try writer.print(",\"http\":{{\"success\":{d},\"client_error\":{d},\"server_error\":{d},\"error_rate\":{d}}}", .{
        report.aggregate.status.success,
        report.aggregate.status.client_error,
        report.aggregate.status.server_error,
        report.aggregate.status.errorRate(),
    });
    try writer.writeByte('}');
}

fn writeCountTable(label: []const u8, table: *const aggregation.CountTable, writer: anytype) !void {
    try writer.print("{s}:\n", .{label});
    if (table.count == 0) {
        try writer.writeAll("  <none>\n");
        return;
    }
    for (table.slice()) |entry| try writer.print("  {s}: {d}\n", .{ entry.key, entry.count });
    if (table.overflow != 0) try writer.print("  <overflow>: {d}\n", .{table.overflow});
}

fn writeCountTableJson(table: *const aggregation.CountTable, writer: anytype) !void {
    try writer.writeByte('{');
    for (table.slice(), 0..) |entry, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJsonString(writer, entry.key);
        try writer.print(":{d}", .{entry.count});
    }
    if (table.overflow != 0) {
        if (table.count != 0) try writer.writeByte(',');
        try writer.print("\"<overflow>\":{d}", .{table.overflow});
    }
    try writer.writeByte('}');
}

fn writeJsonString(writer: anytype, input: []const u8) !void {
    try writer.writeByte('"');
    for (input) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}

test "report summarizes normalized input" {
    var records = [_]record_mod.Record{record_mod.Record.init(.access_log)};
    records[0].network.status = 503;
    const report = build(&records);
    try std.testing.expectEqual(@as(usize, 1), report.aggregate.status.server_error);
    try std.testing.expect(report.hasOperationalErrors() == false);
}
