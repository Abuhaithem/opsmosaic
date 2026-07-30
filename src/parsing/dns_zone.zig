const std = @import("std");
const record_mod = @import("../model/record.zig");
const common = @import("common.zig");

pub const ZoneState = struct {
    origin: ?[]const u8 = null,
    default_ttl: ?u32 = null,
};

pub fn parse(input_raw: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    var lines = std.mem.splitScalar(u8, input_raw, '\n');
    var state = ZoneState{};
    var line_number = context.line;
    var byte_offset = context.byte_offset;
    while (lines.next()) |line_raw| : ({
        line_number += 1;
        byte_offset += line_raw.len + 1;
    }) {
        if (try parseLine(line_raw, .{
            .path = context.path,
            .line = line_number,
            .byte_offset = byte_offset,
            .max_fields = context.max_fields,
            .max_depth = context.max_depth,
            .max_token_bytes = context.max_token_bytes,
            .recover = context.recover,
        }, &state)) |record| return record;
    }
    return error.EmptyInput;
}

pub fn parseLine(line_raw: []const u8, context: common.ParseContext, state: *ZoneState) common.ParseError!?record_mod.Record {
    const line = std.mem.trim(u8, common.stripComment(line_raw, ';'), " \t\r");
    if (line.len == 0) return null;
    if (std.mem.startsWith(u8, line, "$ORIGIN")) {
        const value = std.mem.trim(u8, line[7..], " \t");
        if (value.len == 0) return error.MissingField;
        state.origin = value;
        return null;
    }
    if (std.mem.startsWith(u8, line, "$TTL")) {
        state.default_ttl = try parseTtl(std.mem.trim(u8, line[4..], " \t"));
        return null;
    }
    return try parseRecordLine(line, context, state.origin, state.default_ttl);
}

pub fn parseRecordLine(line: []const u8, context: common.ParseContext, origin: ?[]const u8, default_ttl: ?u32) common.ParseError!record_mod.Record {
    var record = record_mod.Record.init(.dns_zone);
    common.applyContext(&record, context);
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    const owner = tokens.next() orelse return error.MissingField;
    var token = tokens.next() orelse return error.MissingField;
    var ttl = default_ttl;
    if (looksLikeTtl(token)) {
        ttl = parseTtl(token) catch return error.InvalidNumber;
        token = tokens.next() orelse return error.MissingField;
    }
    var class: []const u8 = "IN";
    if (isClass(token)) {
        class = token;
        token = tokens.next() orelse return error.MissingField;
    }
    const record_type = token;
    const rdata_start = locateRdata(line, record_type) orelse return error.MissingField;
    const rdata = std.mem.trim(u8, line[rdata_start..], " \t");
    if (!isSupportedType(record_type)) return error.UnsupportedFeature;
    record.host = owner;
    record.service = "dns";
    record.event_id = record_type;
    record.message = rdata;
    try common.addFieldRecovering(&record, "owner", .{ .text = owner }, context);
    try common.addFieldRecovering(&record, "class", .{ .text = class }, context);
    try common.addFieldRecovering(&record, "record_type", .{ .text = record_type }, context);
    try common.addFieldRecovering(&record, "rdata", .{ .text = rdata }, context);
    if (ttl) |value| try common.addFieldRecovering(&record, "ttl", .{ .integer = @intCast(value) }, context);
    if (origin) |value| try common.addFieldRecovering(&record, "origin", .{ .text = value }, context);
    applyTypeSpecificFields(&record, record_type, rdata, context);
    record.severity = .info;
    return record;
}

fn locateRdata(line: []const u8, record_type: []const u8) ?usize {
    const index = std.mem.indexOf(u8, line, record_type) orelse return null;
    var start = index + record_type.len;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    return start;
}

fn applyTypeSpecificFields(record: *record_mod.Record, record_type: []const u8, rdata: []const u8, context: common.ParseContext) void {
    if (std.ascii.eqlIgnoreCase(record_type, "A") or std.ascii.eqlIgnoreCase(record_type, "AAAA")) {
        record.network.destination_address = rdata;
    } else if (std.ascii.eqlIgnoreCase(record_type, "MX")) {
        var tokens = std.mem.tokenizeAny(u8, rdata, " \t");
        const preference = tokens.next() orelse return;
        const exchange = tokens.next() orelse return;
        const number = common.parseUnsigned(u16, preference) catch return;
        common.addFieldRecovering(record, "preference", .{ .integer = @intCast(number) }, context) catch {};
        common.addFieldRecovering(record, "exchange", .{ .text = exchange }, context) catch {};
    } else if (std.ascii.eqlIgnoreCase(record_type, "SRV")) {
        var tokens = std.mem.tokenizeAny(u8, rdata, " \t");
        const names = [_][]const u8{ "priority", "weight", "port", "target" };
        for (names) |name| {
            const value = tokens.next() orelse break;
            if (std.mem.eql(u8, name, "target")) {
                common.addFieldRecovering(record, name, .{ .text = value }, context) catch {};
            } else if (common.parseUnsigned(u16, value)) |number| {
                common.addFieldRecovering(record, name, .{ .integer = @intCast(number) }, context) catch {};
            } else |_| {}
        }
    } else if (std.ascii.eqlIgnoreCase(record_type, "TXT")) {
        common.addFieldRecovering(record, "text", .{ .text = common.unquote(rdata) }, context) catch {};
    }
}

pub fn parseTtl(input: []const u8) common.ParseError!u32 {
    if (input.len == 0) return error.InvalidNumber;
    var total: u64 = 0;
    var number: u64 = 0;
    var had_digit = false;
    for (input) |ch| {
        if (std.ascii.isDigit(ch)) {
            had_digit = true;
            number = std.math.mul(u64, number, 10) catch return error.InvalidNumber;
            number = std.math.add(u64, number, ch - '0') catch return error.InvalidNumber;
            continue;
        }
        if (!had_digit) return error.InvalidNumber;
        const multiplier: u64 = switch (std.ascii.toLower(ch)) {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86400,
            'w' => 604800,
            else => return error.InvalidNumber,
        };
        total = std.math.add(u64, total, std.math.mul(u64, number, multiplier) catch return error.InvalidNumber) catch return error.InvalidNumber;
        number = 0;
        had_digit = false;
    }
    total = std.math.add(u64, total, number) catch return error.InvalidNumber;
    if (total > std.math.maxInt(u32)) return error.InvalidNumber;
    return @intCast(total);
}

fn looksLikeTtl(input: []const u8) bool {
    _ = parseTtl(input) catch return false;
    return true;
}

fn isClass(input: []const u8) bool {
    return std.ascii.eqlIgnoreCase(input, "IN") or std.ascii.eqlIgnoreCase(input, "CH") or std.ascii.eqlIgnoreCase(input, "HS");
}

fn isSupportedType(input: []const u8) bool {
    const types = [_][]const u8{ "A", "AAAA", "CNAME", "MX", "NS", "PTR", "SOA", "SRV", "TXT", "CAA" };
    for (types) |candidate| { if (std.ascii.eqlIgnoreCase(input, candidate)) return true; }
    return false;
}

test "DNS parser handles directives and typed records" {
    const record = try parse("$ORIGIN example.test.\n$TTL 1h\napi 300 IN A 192.0.2.10\n", .{});
    try std.testing.expectEqualStrings("api", record.host.?);
    try std.testing.expectEqual(@as(i64, 300), record.getField("ttl").?.integer);
}
