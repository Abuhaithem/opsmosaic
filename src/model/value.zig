const std = @import("std");

pub const ValueKind = enum {
    text,
    integer,
    decimal,
    boolean,
    null_value,
};

pub const Value = union(ValueKind) {
    text: []const u8,
    integer: i64,
    decimal: f64,
    boolean: bool,
    null_value: void,

    pub fn kind(self: Value) ValueKind {
        return std.meta.activeTag(self);
    }

    pub fn asText(self: Value) ?[]const u8 {
        return switch (self) {
            .text => |v| v,
            else => null,
        };
    }

    pub fn asInteger(self: Value) ?i64 {
        return switch (self) {
            .integer => |v| v,
            else => null,
        };
    }

    pub fn asDecimal(self: Value) ?f64 {
        return switch (self) {
            .decimal => |v| v,
            .integer => |v| @as(f64, @floatFromInt(v)),
            else => null,
        };
    }

    pub fn asBoolean(self: Value) ?bool {
        return switch (self) {
            .boolean => |v| v,
            else => null,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.kind() != b.kind()) return false;
        return switch (a) {
            .text => |v| std.mem.eql(u8, v, b.text),
            .integer => |v| v == b.integer,
            .decimal => |v| v == b.decimal,
            .boolean => |v| v == b.boolean,
            .null_value => true,
        };
    }

    pub fn lessThan(a: Value, b: Value) ?bool {
        return switch (a) {
            .integer => |v| switch (b) {
                .integer => |rhs| v < rhs,
                .decimal => |rhs| @as(f64, @floatFromInt(v)) < rhs,
                else => null,
            },
            .decimal => |v| switch (b) {
                .integer => |rhs| v < @as(f64, @floatFromInt(rhs)),
                .decimal => |rhs| v < rhs,
                else => null,
            },
            .text => |v| switch (b) {
                .text => |rhs| std.mem.lessThan(u8, v, rhs),
                else => null,
            },
            else => null,
        };
    }

    pub fn hash(self: Value) u64 {
        var hasher = std.hash.Wyhash.init(0x4f50534d4f534149);
        const tag_byte: u8 = @intFromEnum(self.kind());
        hasher.update(&[_]u8{tag_byte});
        switch (self) {
            .text => |v| hasher.update(v),
            .integer => |v| hasher.update(std.mem.asBytes(&v)),
            .decimal => |v| hasher.update(std.mem.asBytes(&v)),
            .boolean => |v| hasher.update(&[_]u8{@intFromBool(v)}),
            .null_value => {},
        }
        return hasher.final();
    }

    pub fn writeJson(self: Value, writer: anytype) !void {
        switch (self) {
            .text => |v| try writeJsonString(writer, v),
            .integer => |v| try writer.print("{d}", .{v}),
            .decimal => |v| try writer.print("{d}", .{v}),
            .boolean => |v| try writer.writeAll(if (v) "true" else "false"),
            .null_value => try writer.writeAll("null"),
        }
    }

    pub fn writeDisplay(self: Value, writer: anytype) !void {
        switch (self) {
            .text => |v| try writer.writeAll(v),
            .integer => |v| try writer.print("{d}", .{v}),
            .decimal => |v| try writer.print("{d}", .{v}),
            .boolean => |v| try writer.writeAll(if (v) "true" else "false"),
            .null_value => try writer.writeAll("null"),
        }
    }
};

pub fn writeJsonString(writer: anytype, input: []const u8) !void {
    try writer.writeByte('"');
    for (input) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f => try writer.print("\\u00{x:0>2}", .{ch}),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

pub fn parseScalar(input_raw: []const u8) Value {
    const input = std.mem.trim(u8, input_raw, " \t\r\n");
    if (input.len == 0) return .{ .text = input };
    if (std.ascii.eqlIgnoreCase(input, "null") or std.mem.eql(u8, input, "~")) {
        return .{ .null_value = {} };
    }
    if (std.ascii.eqlIgnoreCase(input, "true") or std.ascii.eqlIgnoreCase(input, "yes") or std.ascii.eqlIgnoreCase(input, "on")) {
        return .{ .boolean = true };
    }
    if (std.ascii.eqlIgnoreCase(input, "false") or std.ascii.eqlIgnoreCase(input, "no") or std.ascii.eqlIgnoreCase(input, "off")) {
        return .{ .boolean = false };
    }
    if (std.fmt.parseInt(i64, input, 10)) |v| {
        return .{ .integer = v };
    } else |_| {}
    if (std.fmt.parseFloat(f64, input)) |v| {
        return .{ .decimal = v };
    } else |_| {}
    return .{ .text = unquote(input) };
}

pub fn unquote(input: []const u8) []const u8 {
    if (input.len >= 2) {
        const first = input[0];
        const last = input[input.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return input[1 .. input.len - 1];
        }
    }
    return input;
}

pub fn truthy(value: Value) bool {
    return switch (value) {
        .text => |v| v.len != 0,
        .integer => |v| v != 0,
        .decimal => |v| v != 0.0,
        .boolean => |v| v,
        .null_value => false,
    };
}

pub fn contains(value: Value, needle: []const u8) bool {
    return switch (value) {
        .text => |v| std.mem.indexOf(u8, v, needle) != null,
        else => false,
    };
}

pub fn startsWith(value: Value, prefix: []const u8) bool {
    return switch (value) {
        .text => |v| std.mem.startsWith(u8, v, prefix),
        else => false,
    };
}

pub fn endsWith(value: Value, suffix: []const u8) bool {
    return switch (value) {
        .text => |v| std.mem.endsWith(u8, v, suffix),
        else => false,
    };
}

test "scalar coercion preserves useful types" {
    try std.testing.expectEqual(@as(i64, 42), parseScalar("42").integer);
    try std.testing.expect(parseScalar("true").boolean);
    try std.testing.expectEqualStrings("edge", parseScalar("\"edge\"").text);
}
