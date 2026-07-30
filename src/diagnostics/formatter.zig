const std = @import("std");
const diag_mod = @import("diagnostic.zig");

pub const Style = enum { plain, compact, json };

pub const Formatter = struct {
    style: Style = .plain,
    include_suggestions: bool = true,
    include_source_excerpt: bool = true,
    max_excerpt_bytes: usize = 160,

    pub fn write(self: Formatter, diagnostic: diag_mod.Diagnostic, source_line: ?[]const u8, writer: anytype) !void {
        switch (self.style) {
            .plain => try self.writePlain(diagnostic, source_line, writer),
            .compact => try self.writeCompact(diagnostic, writer),
            .json => try self.writeJson(diagnostic, writer),
        }
    }

    fn writePlain(self: Formatter, diagnostic: diag_mod.Diagnostic, source_line: ?[]const u8, writer: anytype) !void {
        try diagnostic.writeText(writer);
        try writer.writeByte('\n');
        if (self.include_source_excerpt) if (source_line) |line| {
            const excerpt = line[0..@min(line.len, self.max_excerpt_bytes)];
            try writer.print("  {s}\n  ", .{excerpt});
            var column: usize = 1;
            while (column < diagnostic.column and column <= excerpt.len) : (column += 1) try writer.writeByte(if (excerpt[column - 1] == '\t') '\t' else ' ');
            try writer.writeAll("^\n");
        };
        if (self.include_suggestions) if (diagnostic.suggestion) |suggestion| try writer.print("  help: {s}\n", .{suggestion});
    }

    fn writeCompact(_: Formatter, diagnostic: diag_mod.Diagnostic, writer: anytype) !void {
        try writer.print("{s}:{d}:{d}:{s}:{s}:{s}\n", .{
            diagnostic.code.label(), diagnostic.line, diagnostic.column, diagnostic.severity.label(), diagnostic.field orelse "-", diagnostic.message,
        });
    }

    fn writeJson(_: Formatter, diagnostic: diag_mod.Diagnostic, writer: anytype) !void {
        try writer.writeAll("{\"severity\":");
        try writeString(writer, diagnostic.severity.label());
        try writer.writeAll(",\"code\":");
        try writeString(writer, diagnostic.code.label());
        try writer.print(",\"line\":{d},\"column\":{d},\"message\":", .{ diagnostic.line, diagnostic.column });
        try writeString(writer, diagnostic.message);
        if (diagnostic.field) |field| {
            try writer.writeAll(",\"field\":");
            try writeString(writer, field);
        }
        if (diagnostic.suggestion) |suggestion| {
            try writer.writeAll(",\"suggestion\":");
            try writeString(writer, suggestion);
        }
        try writer.writeAll("}\n");
    }
};

fn writeString(writer: anytype, input: []const u8) !void {
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

test "compact diagnostics include stable code" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    try (Formatter{ .style = .compact }).write(.{ .severity = .warning, .code = .invalid_number, .line = 2, .column = 4, .message = "bad" }, null, buffer.writer());
    try std.testing.expect(std.mem.startsWith(u8, buffer.items, "SL1302:2:4"));
}
