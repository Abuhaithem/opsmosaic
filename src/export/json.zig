const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");

pub const Options = struct {
    pretty: bool = false,
    include_nulls: bool = false,
    include_fields: bool = true,
    include_tags: bool = true,
    include_warnings: bool = true,
    redact_sensitive: bool = true,
};

pub fn writeRecord(record: *const record_mod.Record, writer: anytype, options: Options) !void {
    var state = ObjectWriter(@TypeOf(writer)).init(writer, options.pretty);
    try state.begin();
    try state.fieldString("source_format", record.source.format.label());
    if (record.source.path) |path| try state.fieldString("source_path", path) else if (options.include_nulls) try state.fieldNull("source_path");
    try state.fieldInteger("source_line", @intCast(record.source.line));
    if (record.timestamp_text) |value| try state.fieldString("timestamp", value) else if (options.include_nulls) try state.fieldNull("timestamp");
    if (record.timestamp_unix_ns) |value| try state.fieldI128("timestamp_unix_ns", value) else if (options.include_nulls) try state.fieldNull("timestamp_unix_ns");
    try state.fieldString("severity", record.severity.label());
    if (record.host) |value| try state.fieldString("host", value) else if (options.include_nulls) try state.fieldNull("host");
    if (record.service) |value| try state.fieldString("service", value) else if (options.include_nulls) try state.fieldNull("service");
    if (record.process_id) |value| try state.fieldString("process_id", value) else if (options.include_nulls) try state.fieldNull("process_id");
    if (record.event_id) |value| try state.fieldString("event_id", value) else if (options.include_nulls) try state.fieldNull("event_id");
    if (record.request_id) |value| try state.fieldString("request_id", value) else if (options.include_nulls) try state.fieldNull("request_id");
    if (record.trace_id) |value| try state.fieldString("trace_id", value) else if (options.include_nulls) try state.fieldNull("trace_id");
    try state.fieldString("message", record.message);
    try writeNetwork(&state, record, options);
    if (options.include_fields) try writeFields(&state, record, options);
    if (options.include_tags) try writeTags(&state, record);
    if (options.include_warnings) try writeWarnings(&state, record);
    try state.end();
}

pub fn writeJsonLines(records: []const record_mod.Record, writer: anytype, options: Options) !void {
    for (records) |*record| {
        try writeRecord(record, writer, options);
        try writer.writeByte('\n');
    }
}

pub fn writeArray(records: []const record_mod.Record, writer: anytype, options: Options) !void {
    try writer.writeByte('[');
    if (options.pretty and records.len != 0) try writer.writeByte('\n');
    for (records, 0..) |*record, index| {
        if (index != 0) {
            try writer.writeByte(',');
            if (options.pretty) try writer.writeByte('\n');
        }
        if (options.pretty) try writer.writeAll("  ");
        try writeRecord(record, writer, .{
            .pretty = false,
            .include_nulls = options.include_nulls,
            .include_fields = options.include_fields,
            .include_tags = options.include_tags,
            .include_warnings = options.include_warnings,
            .redact_sensitive = options.redact_sensitive,
        });
    }
    if (options.pretty and records.len != 0) try writer.writeByte('\n');
    try writer.writeByte(']');
}

fn writeNetwork(state: anytype, record: *const record_mod.Record, options: Options) !void {
    if (record.network.source_address) |value| try state.fieldString("source_address", value) else if (options.include_nulls) try state.fieldNull("source_address");
    if (record.network.destination_address) |value| try state.fieldString("destination_address", value) else if (options.include_nulls) try state.fieldNull("destination_address");
    if (record.network.source_port) |value| try state.fieldInteger("source_port", value) else if (options.include_nulls) try state.fieldNull("source_port");
    if (record.network.destination_port) |value| try state.fieldInteger("destination_port", value) else if (options.include_nulls) try state.fieldNull("destination_port");
    if (record.network.protocol) |value| try state.fieldString("protocol", value) else if (options.include_nulls) try state.fieldNull("protocol");
    if (record.network.method) |value| try state.fieldString("method", value) else if (options.include_nulls) try state.fieldNull("method");
    if (record.network.path) |value| try state.fieldString("path", value) else if (options.include_nulls) try state.fieldNull("path");
    if (record.network.status) |value| try state.fieldInteger("status", value) else if (options.include_nulls) try state.fieldNull("status");
    if (record.network.bytes) |value| try state.fieldUnsigned("bytes", value) else if (options.include_nulls) try state.fieldNull("bytes");
}

fn writeFields(state: anytype, record: *const record_mod.Record, options: Options) !void {
    try state.name("fields");
    try state.writer.writeByte('{');
    var first = true;
    for (record.fieldSlice()) |field| {
        if (!first) try state.writer.writeByte(',');
        first = false;
        if (state.pretty) try state.writer.writeByte(' ');
        try value_mod.writeJsonString(state.writer, field.key);
        try state.writer.writeByte(':');
        if (state.pretty) try state.writer.writeByte(' ');
        if (options.redact_sensitive and looksSensitive(field.key)) try value_mod.writeJsonString(state.writer, "<redacted>") else try field.value.writeJson(state.writer);
    }
    if (state.pretty and !first) try state.writer.writeByte(' ');
    try state.writer.writeByte('}');
}

fn writeTags(state: anytype, record: *const record_mod.Record) !void {
    try state.name("tags");
    try state.writer.writeByte('[');
    for (record.tagSlice(), 0..) |tag, index| {
        if (index != 0) try state.writer.writeByte(',');
        if (state.pretty) try state.writer.writeByte(' ');
        try value_mod.writeJsonString(state.writer, tag);
    }
    if (state.pretty and record.tag_count != 0) try state.writer.writeByte(' ');
    try state.writer.writeByte(']');
}

fn writeWarnings(state: anytype, record: *const record_mod.Record) !void {
    try state.name("warnings");
    try state.writer.writeByte('[');
    for (record.warnings.slice(), 0..) |warning, index| {
        if (index != 0) try state.writer.writeByte(',');
        try state.writer.writeAll("{\"code\":");
        try value_mod.writeJsonString(state.writer, warning.code.label());
        try state.writer.writeAll(",\"message\":");
        try value_mod.writeJsonString(state.writer, warning.message);
        try state.writer.print(",\"line\":{d},\"column\":{d}}}", .{ warning.line, warning.column });
    }
    try state.writer.writeByte(']');
}

fn ObjectWriter(comptime Writer: type) type {
    return struct {
        writer: Writer,
        pretty: bool,
        first: bool = true,

        const Self = @This();

        fn init(writer: Writer, pretty: bool) Self {
            return .{ .writer = writer, .pretty = pretty };
        }

        fn begin(self: *Self) !void {
            try self.writer.writeByte('{');
        }

        fn end(self: *Self) !void {
            if (self.pretty and !self.first) try self.writer.writeByte(' ');
            try self.writer.writeByte('}');
        }

        fn name(self: *Self, key: []const u8) !void {
            if (!self.first) try self.writer.writeByte(',');
            self.first = false;
            if (self.pretty) try self.writer.writeByte(' ');
            try value_mod.writeJsonString(self.writer, key);
            try self.writer.writeByte(':');
            if (self.pretty) try self.writer.writeByte(' ');
        }

        fn fieldString(self: *Self, key: []const u8, value: []const u8) !void {
            try self.name(key);
            try value_mod.writeJsonString(self.writer, value);
        }

        fn fieldInteger(self: *Self, key: []const u8, value: i64) !void {
            try self.name(key);
            try self.writer.print("{d}", .{value});
        }

        fn fieldUnsigned(self: *Self, key: []const u8, value: u64) !void {
            try self.name(key);
            try self.writer.print("{d}", .{value});
        }

        fn fieldI128(self: *Self, key: []const u8, value: i128) !void {
            try self.name(key);
            try self.writer.print("{d}", .{value});
        }

        fn fieldNull(self: *Self, key: []const u8) !void {
            try self.name(key);
            try self.writer.writeAll("null");
        }
    };
}

fn looksSensitive(key: []const u8) bool {
    const parts = [_][]const u8{ "password", "secret", "token", "private_key", "api_key", "credential" };
    for (parts) |part| if (indexOfIgnoreCase(key, part) != null) return true;
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (haystack.len < needle.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    return null;
}

test "JSON exporter escapes message content" {
    var record = record_mod.Record.init(.jsonl);
    record.message = "line\n\"quoted\"";
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    try writeRecord(&record, buffer.writer(), .{});
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\\n\\\"quoted\\\"") != null);
}
