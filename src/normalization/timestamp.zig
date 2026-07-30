const std = @import("std");
const record_mod = @import("../model/record.zig");

pub const TimestampError = error{
    InvalidTimestamp,
    OutOfRange,
    UnsupportedTimezone,
};

pub const ParsedTimestamp = struct {
    unix_ns: i128,
    offset_minutes: i16,
    precision_digits: u8,
};

pub fn normalizeRecord(record: *record_mod.Record) void {
    const text = record.timestamp_text orelse return;
    const parsed = parse(text) catch {
        record.warnings.append(.{
            .severity = .warning,
            .code = .malformed_timestamp,
            .line = record.source.line,
            .column = record.source.column,
            .field = "timestamp",
            .message = "timestamp could not be normalized",
            .suggestion = "use RFC3339 or ISO-8601 with an explicit timezone",
        });
        record.recovered = true;
        return;
    };
    record.timestamp_unix_ns = parsed.unix_ns;
}

pub fn parse(input_raw: []const u8) TimestampError!ParsedTimestamp {
    const input = std.mem.trim(u8, input_raw, " \t\r\n");
    if (input.len >= 20 and input[4] == '-' and input[7] == '-' and (input[10] == 'T' or input[10] == ' ')) {
        return parseIso8601(input);
    }
    if (input.len >= 20 and input[2] == '/' and input[6] == '/') {
        return parseAccessLogTimestamp(input);
    }
    if (input.len == 10 and input[4] == '-' and input[7] == '-') {
        return parseDateOnly(input);
    }
    return error.InvalidTimestamp;
}

fn parseIso8601(input: []const u8) TimestampError!ParsedTimestamp {
    const year = try digits(i32, input, 0, 4);
    const month = try digits(u8, input, 5, 2);
    const day = try digits(u8, input, 8, 2);
    const hour = try digits(u8, input, 11, 2);
    const minute = try digits(u8, input, 14, 2);
    const second = try digits(u8, input, 17, 2);
    try validateDateTime(year, month, day, hour, minute, second);
    var index: usize = 19;
    var nanoseconds: i128 = 0;
    var precision: u8 = 0;
    if (index < input.len and input[index] == '.') {
        index += 1;
        const start = index;
        while (index < input.len and std.ascii.isDigit(input[index])) : (index += 1) {
            if (precision < 9) {
                nanoseconds = nanoseconds * 10 + (input[index] - '0');
                precision += 1;
            }
        }
        if (index == start) return error.InvalidTimestamp;
        while (precision < 9) : (precision += 1) nanoseconds *= 10;
    }
    const offset = try parseOffset(input[index..]);
    const days_since_epoch = daysFromCivil(year, month, day);
    const local_seconds: i128 = @as(i128, days_since_epoch) * 86400 + @as(i128, hour) * 3600 + @as(i128, minute) * 60 + second;
    const utc_seconds = local_seconds - @as(i128, offset) * 60;
    return .{ .unix_ns = utc_seconds * std.time.ns_per_s + nanoseconds, .offset_minutes = offset, .precision_digits = precision };
}

fn parseAccessLogTimestamp(input: []const u8) TimestampError!ParsedTimestamp {
    if (input.len < 26 or input[2] != '/' or input[6] != '/' or input[11] != ':' or input[14] != ':' or input[17] != ':') return error.InvalidTimestamp;
    const day = try digits(u8, input, 0, 2);
    const month = monthNumber(input[3..6]) orelse return error.InvalidTimestamp;
    const year = try digits(i32, input, 7, 4);
    const hour = try digits(u8, input, 12, 2);
    const minute = try digits(u8, input, 15, 2);
    const second = try digits(u8, input, 18, 2);
    try validateDateTime(year, month, day, hour, minute, second);
    const offset = try parseOffset(std.mem.trim(u8, input[20..], " []"));
    const days_since_epoch = daysFromCivil(year, month, day);
    const local_seconds: i128 = @as(i128, days_since_epoch) * 86400 + @as(i128, hour) * 3600 + @as(i128, minute) * 60 + second;
    return .{ .unix_ns = (local_seconds - @as(i128, offset) * 60) * std.time.ns_per_s, .offset_minutes = offset, .precision_digits = 0 };
}

fn parseDateOnly(input: []const u8) TimestampError!ParsedTimestamp {
    const year = try digits(i32, input, 0, 4);
    const month = try digits(u8, input, 5, 2);
    const day = try digits(u8, input, 8, 2);
    try validateDateTime(year, month, day, 0, 0, 0);
    return .{ .unix_ns = @as(i128, daysFromCivil(year, month, day)) * 86400 * std.time.ns_per_s, .offset_minutes = 0, .precision_digits = 0 };
}

fn parseOffset(input: []const u8) TimestampError!i16 {
    if (std.mem.eql(u8, input, "Z") or std.mem.eql(u8, input, "z") or std.mem.eql(u8, input, "+00:00") or std.mem.eql(u8, input, "+0000")) return 0;
    if (input.len != 6 and input.len != 5) return error.UnsupportedTimezone;
    if (input[0] != '+' and input[0] != '-') return error.UnsupportedTimezone;
    const hour = try digits(i16, input, 1, 2);
    const minute_index: usize = if (input.len == 6) 4 else 3;
    if (input.len == 6 and input[3] != ':') return error.UnsupportedTimezone;
    const minute = try digits(i16, input, minute_index, 2);
    if (hour > 23 or minute > 59) return error.OutOfRange;
    const total = hour * 60 + minute;
    return if (input[0] == '-') -total else total;
}

fn digits(comptime T: type, input: []const u8, start: usize, len: usize) TimestampError!T {
    if (start + len > input.len) return error.InvalidTimestamp;
    return std.fmt.parseInt(T, input[start .. start + len], 10) catch error.InvalidTimestamp;
}

fn validateDateTime(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) TimestampError!void {
    if (year < 1 or year > 9999) return error.OutOfRange;
    if (month < 1 or month > 12) return error.OutOfRange;
    if (day < 1 or day > daysInMonth(year, month)) return error.OutOfRange;
    if (hour > 23 or minute > 59 or second > 60) return error.OutOfRange;
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

pub fn isLeapYear(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn daysFromCivil(year_input: i32, month_input: u8, day_input: u8) i64 {
    var year: i64 = year_input;
    const month: i64 = month_input;
    const day: i64 = day_input;
    year -= if (month <= 2) 1 else 0;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const adjusted_month = month + (if (month > 2) -3 else 9);
    const doy = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn monthNumber(input: []const u8) ?u8 {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (months, 1..) |month, index| if (std.ascii.eqlIgnoreCase(input, month)) return @intCast(index);
    return null;
}

pub fn compare(a: ?i128, b: ?i128) std.math.Order {
    if (a == null and b == null) return .eq;
    if (a == null) return .lt;
    if (b == null) return .gt;
    return std.math.order(a.?, b.?);
}

pub fn withinWindow(a: ?i128, b: ?i128, window_ns: i128) bool {
    if (a == null or b == null) return false;
    const delta = if (a.? >= b.?) a.? - b.? else b.? - a.?;
    return delta <= window_ns;
}

test "ISO timestamps normalize across offsets" {
    const a = try parse("2026-07-30T10:00:00+03:00");
    const b = try parse("2026-07-30T07:00:00Z");
    try std.testing.expectEqual(a.unix_ns, b.unix_ns);
}
