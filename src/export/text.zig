const std = @import("std");
const record_mod = @import("../model/record.zig");
const aggregation = @import("../processing/aggregation.zig");

pub const InspectOptions = struct {
    include_fields: bool = true,
    include_tags: bool = true,
    include_warnings: bool = true,
};

pub fn writeRecord(record: *const record_mod.Record, writer: anytype, options: InspectOptions) !void {
    try writer.print("format: {s}\n", .{record.source.format.label()});
    try writer.print("origin: {s}:{d}\n", .{ record.source.displayName(), record.source.line });
    try writeOptional(writer, "timestamp", record.timestamp_text);
    try writer.print("severity: {s}\n", .{record.severity.label()});
    try writeOptional(writer, "host", record.host);
    try writeOptional(writer, "service", record.service);
    try writeOptional(writer, "process_id", record.process_id);
    try writeOptional(writer, "event_id", record.event_id);
    try writeOptional(writer, "request_id", record.request_id);
    try writeOptional(writer, "trace_id", record.trace_id);
    try writer.print("message: {s}\n", .{record.message});
    if (record.network.source_address) |value| try writer.print("source_address: {s}\n", .{value});
    if (record.network.destination_address) |value| try writer.print("destination_address: {s}\n", .{value});
    if (record.network.method) |value| try writer.print("method: {s}\n", .{value});
    if (record.network.path) |value| try writer.print("path: {s}\n", .{value});
    if (record.network.status) |value| try writer.print("status: {d}\n", .{value});
    if (record.network.bytes) |value| try writer.print("bytes: {d}\n", .{value});
    if (options.include_fields and record.field_count != 0) {
        try writer.writeAll("fields:\n");
        for (record.fieldSlice()) |field| {
            try writer.print("  {s}: ", .{field.key});
            try field.value.writeDisplay(writer);
            try writer.writeByte('\n');
        }
    }
    if (options.include_tags and record.tag_count != 0) {
        try writer.writeAll("tags:");
        for (record.tagSlice()) |tag| try writer.print(" {s}", .{tag});
        try writer.writeByte('\n');
    }
    if (options.include_warnings and record.warnings.count != 0) {
        try writer.writeAll("warnings:\n");
        for (record.warnings.slice()) |warning| {
            try writer.writeAll("  ");
            try warning.writeText(writer);
            try writer.writeByte('\n');
        }
    }
}

pub fn writeAggregation(report: *const aggregation.Report, writer: anytype) !void {
    try writer.print("records: {d}\n", .{report.record_count});
    try writer.writeAll("by severity:\n");
    try writeCountTable(&report.by_severity, writer);
    try writer.writeAll("by service:\n");
    try writeCountTable(&report.by_service, writer);
    try writer.writeAll("by source format:\n");
    try writeCountTable(&report.by_format, writer);
    try writer.print("http error rate: {d:.4}\n", .{report.status.errorRate()});
    if (report.timestamps.minimum_ns) |minimum| try writer.print("minimum timestamp ns: {d}\n", .{minimum});
    if (report.timestamps.maximum_ns) |maximum| try writer.print("maximum timestamp ns: {d}\n", .{maximum});
}

fn writeCountTable(table: *const aggregation.CountTable, writer: anytype) !void {
    for (table.slice()) |entry| try writer.print("  {s}: {d}\n", .{ entry.key, entry.count });
    if (table.overflow != 0) try writer.print("  <overflow>: {d}\n", .{table.overflow});
}

fn writeOptional(writer: anytype, label: []const u8, value: ?[]const u8) !void {
    if (value) |text| try writer.print("{s}: {s}\n", .{ label, text }) else try writer.print("{s}: <missing>\n", .{label});
}

test "text inspector includes normalized fields" {
    var record = record_mod.Record.init(.jsonl);
    record.host = "edge-1";
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    try writeRecord(&record, buffer.writer(), .{});
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "host: edge-1") != null);
}
