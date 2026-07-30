const std = @import("std");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;

pub const Field = struct {
    key: []const u8,
    value: Value,

    pub fn eql(self: Field, other: Field) bool {
        return std.mem.eql(u8, self.key, other.key) and self.value.eql(other.value);
    }

    pub fn normalizedKey(self: Field, buffer: []u8) []const u8 {
        return normalizeKey(self.key, buffer);
    }
};

pub fn normalizeKey(input: []const u8, buffer: []u8) []const u8 {
    var out_len: usize = 0;
    var previous_separator = false;
    for (input) |ch| {
        if (out_len >= buffer.len) break;
        if (std.ascii.isAlphanumeric(ch)) {
            buffer[out_len] = std.ascii.toLower(ch);
            out_len += 1;
            previous_separator = false;
        } else if (!previous_separator and out_len != 0) {
            buffer[out_len] = '_';
            out_len += 1;
            previous_separator = true;
        }
    }
    while (out_len > 0 and buffer[out_len - 1] == '_') out_len -= 1;
    return buffer[0..out_len];
}

pub fn isReservedKey(key: []const u8) bool {
    const reserved = [_][]const u8{
        "timestamp", "severity", "host", "service", "message",
        "event_id", "trace_id", "request_id", "source_address",
    };
    for (reserved) |candidate| {
        if (std.mem.eql(u8, key, candidate)) return true;
    }
    return false;
}

pub fn compareByKey(_: void, left: Field, right: Field) bool {
    return std.mem.lessThan(u8, left.key, right.key);
}

pub fn find(fields: []const Field, key: []const u8) ?Value {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key)) return field.value;
    }
    return null;
}

pub fn findCaseInsensitive(fields: []const Field, key: []const u8) ?Value {
    for (fields) |field| {
        if (std.ascii.eqlIgnoreCase(field.key, key)) return field.value;
    }
    return null;
}

pub fn countKind(fields: []const Field, kind: value_mod.ValueKind) usize {
    var count: usize = 0;
    for (fields) |field| {
        if (field.value.kind() == kind) count += 1;
    }
    return count;
}

pub fn uniqueKeyCount(fields: []const Field) usize {
    var count: usize = 0;
    for (fields, 0..) |field, index| {
        var duplicate = false;
        for (fields[0..index]) |prior| {
            if (std.mem.eql(u8, prior.key, field.key)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) count += 1;
    }
    return count;
}

test "field keys normalize for cross-format queries" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("http_status_code", normalizeKey("HTTP Status-Code", &buffer));
}
