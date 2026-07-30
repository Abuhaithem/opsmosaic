const std = @import("std");
const record_mod = @import("../model/record.zig");

pub const CoercionPolicy = struct {
    booleans: bool = true,
    integers: bool = true,
    decimals: bool = true,
    nulls: bool = true,
    preserve_leading_zero_numbers: bool = true,
    max_numeric_bytes: usize = 64,
};

pub const CoercionStats = struct {
    text_to_integer: usize = 0,
    text_to_decimal: usize = 0,
    text_to_boolean: usize = 0,
    text_to_null: usize = 0,
    unchanged: usize = 0,
};

pub fn normalizeRecord(record: *record_mod.Record, policy: CoercionPolicy) CoercionStats {
    var stats = CoercionStats{};
    for (record.fields[0..record.field_count]) |*field| {
        field.value = coerce(field.key, field.value, policy, &stats);
    }
    return stats;
}

pub fn coerce(key: []const u8, value: record_mod.Value, policy: CoercionPolicy, stats: *CoercionStats) record_mod.Value {
    const text = value.asText() orelse {
        stats.unchanged += 1;
        return value;
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > policy.max_numeric_bytes) {
        stats.unchanged += 1;
        return value;
    }
    if (policy.nulls and isNullWord(trimmed)) {
        stats.text_to_null += 1;
        return .{ .null_value = {} };
    }
    if (policy.booleans) {
        if (parseBoolean(trimmed)) |boolean| {
            stats.text_to_boolean += 1;
            return .{ .boolean = boolean };
        }
    }
    if (policy.integers and shouldCoerceNumber(key, trimmed, policy)) {
        if (std.fmt.parseInt(i64, trimmed, 10)) |integer| {
            stats.text_to_integer += 1;
            return .{ .integer = integer };
        } else |_| {}
    }
    if (policy.decimals and shouldCoerceNumber(key, trimmed, policy)) {
        if (std.fmt.parseFloat(f64, trimmed)) |decimal| {
            if (std.math.isFinite(decimal)) {
                stats.text_to_decimal += 1;
                return .{ .decimal = decimal };
            }
        } else |_| {}
    }
    stats.unchanged += 1;
    return value;
}

fn shouldCoerceNumber(key: []const u8, input: []const u8, policy: CoercionPolicy) bool {
    if (isIdentifierField(key)) return false;
    if (policy.preserve_leading_zero_numbers and hasSignificantLeadingZero(input)) return false;
    return looksNumeric(input);
}

fn isIdentifierField(key: []const u8) bool {
    const identifiers = [_][]const u8{ "id", "event_id", "request_id", "trace_id", "process_id", "postal_code", "zip", "version", "host", "address" };
    for (identifiers) |candidate| if (std.ascii.eqlIgnoreCase(key, candidate) or endsWithIgnoreCase(key, candidate)) return true;
    return false;
}

fn hasSignificantLeadingZero(input: []const u8) bool {
    var value = input;
    if (value.len > 0 and (value[0] == '+' or value[0] == '-')) value = value[1..];
    if (value.len < 2 or value[0] != '0') return false;
    return value[1] != '.' and value[1] != 'e' and value[1] != 'E';
}

fn looksNumeric(input: []const u8) bool {
    var digits: usize = 0;
    var dots: usize = 0;
    var exponents: usize = 0;
    for (input, 0..) |ch, index| {
        if (std.ascii.isDigit(ch)) digits += 1
        else if (ch == '.') dots += 1
        else if (ch == 'e' or ch == 'E') exponents += 1
        else if ((ch == '+' or ch == '-') and (index == 0 or input[index - 1] == 'e' or input[index - 1] == 'E')) {}
        else return false;
    }
    return digits > 0 and dots <= 1 and exponents <= 1;
}

fn parseBoolean(input: []const u8) ?bool {
    if (anyEqual(input, &.{ "true", "yes", "on", "enabled" })) return true;
    if (anyEqual(input, &.{ "false", "no", "off", "disabled" })) return false;
    return null;
}

fn isNullWord(input: []const u8) bool {
    return anyEqual(input, &.{ "null", "nil", "none", "n/a", "~" });
}

fn anyEqual(input: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| if (std.ascii.eqlIgnoreCase(input, candidate)) return true;
    return false;
}

fn endsWithIgnoreCase(input: []const u8, suffix: []const u8) bool {
    if (input.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(input[input.len - suffix.len ..], suffix);
}

pub fn numericValue(value: record_mod.Value) ?f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .decimal => |v| v,
        else => null,
    };
}

pub fn losslessInteger(value: record_mod.Value) ?i64 {
    return switch (value) {
        .integer => |v| v,
        .decimal => |v| if (std.math.isFinite(v) and @floor(v) == v and v >= std.math.minInt(i64) and v <= std.math.maxInt(i64)) @intFromFloat(v) else null,
        else => null,
    };
}

test "coercion preserves identifier-like leading zeros" {
    var stats = CoercionStats{};
    const value = coerce("asset_id", .{ .text = "0017" }, .{}, &stats);
    try std.testing.expectEqualStrings("0017", value.text);
}
