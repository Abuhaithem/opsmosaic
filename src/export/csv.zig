const std = @import("std");
const record_mod = @import("../model/record.zig");
const eval = @import("../processing/query_eval.zig");

pub const Options = struct {
    delimiter: u8 = ',',
    line_ending: []const u8 = "\n",
    include_header: bool = true,
    missing_text: []const u8 = "",
    redact_sensitive: bool = true,
};

pub const default_columns = [_][]const u8{
    "timestamp", "severity", "host", "service", "event_id", "request_id", "trace_id",
    "source_address", "method", "path", "status", "bytes", "message", "source_format",
};

pub fn write(records: []const record_mod.Record, writer: anytype, columns: []const []const u8, options: Options) !void {
    if (options.include_header) {
        for (columns, 0..) |column, index| {
            if (index != 0) try writer.writeByte(options.delimiter);
            try writeCell(writer, column, options.delimiter);
        }
        try writer.writeAll(options.line_ending);
    }
    for (records) |*record| {
        try writeRecord(record, writer, columns, options);
        try writer.writeAll(options.line_ending);
    }
}

pub fn writeRecord(record: *const record_mod.Record, writer: anytype, columns: []const []const u8, options: Options) !void {
    for (columns, 0..) |column, index| {
        if (index != 0) try writer.writeByte(options.delimiter);
        if (options.redact_sensitive and looksSensitive(column)) {
            try writeCell(writer, "<redacted>", options.delimiter);
            continue;
        }
        const value = eval.fieldValue(record, column) orelse {
            try writeCell(writer, options.missing_text, options.delimiter);
            continue;
        };
        try writeValue(writer, value, options.delimiter);
    }
}

fn writeValue(writer: anytype, value: record_mod.Value, delimiter: u8) !void {
    switch (value) {
        .text => |text| try writeCell(writer, text, delimiter),
        .integer => |number| try writer.print("{d}", .{number}),
        .decimal => |number| try writer.print("{d}", .{number}),
        .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .null_value => {},
    }
}

pub fn writeCell(writer: anytype, input: []const u8, delimiter: u8) !void {
    const needs_quotes = std.mem.indexOfScalar(u8, input, delimiter) != null or
        std.mem.indexOfScalar(u8, input, '"') != null or
        std.mem.indexOfScalar(u8, input, '\n') != null or
        std.mem.indexOfScalar(u8, input, '\r') != null or
        (input.len > 0 and (std.ascii.isWhitespace(input[0]) or std.ascii.isWhitespace(input[input.len - 1])));
    if (!needs_quotes) {
        try writer.writeAll(input);
        return;
    }
    try writer.writeByte('"');
    for (input) |ch| {
        if (ch == '"') try writer.writeAll("\"\"") else try writer.writeByte(ch);
    }
    try writer.writeByte('"');
}

pub fn parseColumns(input: []const u8, output: [][]const u8) usize {
    var iterator = std.mem.splitScalar(u8, input, ',');
    var count: usize = 0;
    while (iterator.next()) |column_raw| {
        if (count >= output.len) break;
        const column = std.mem.trim(u8, column_raw, " \t\r\n");
        if (column.len == 0) continue;
        output[count] = column;
        count += 1;
    }
    return count;
}

pub fn validateColumns(columns: []const []const u8) bool {
    if (columns.len == 0) return false;
    for (columns, 0..) |column, index| {
        if (column.len == 0 or column.len > 256) return false;
        for (columns[0..index]) |prior| if (std.mem.eql(u8, column, prior)) return false;
    }
    return true;
}

fn looksSensitive(key: []const u8) bool {
    const needles = [_][]const u8{ "password", "secret", "token", "private_key", "api_key", "credential" };
    for (needles) |needle| if (containsIgnoreCase(key, needle)) return true;
    return false;
}

fn containsIgnoreCase(input: []const u8, needle: []const u8) bool {
    if (input.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= input.len) : (index += 1) if (std.ascii.eqlIgnoreCase(input[index .. index + needle.len], needle)) return true;
    return false;
}

test "CSV exporter quotes delimiters and quotes" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    try writeCell(buffer.writer(), "a,\"b\"", ',');
    try std.testing.expectEqualStrings("\"a,\"\"b\"\"\"", buffer.items);
}
