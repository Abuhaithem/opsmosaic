const std = @import("std");
const record_mod = @import("../model/record.zig");
const common = @import("common.zig");
const cursor_mod = @import("../input/line_cursor.zig");

pub fn parse(input_raw: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    const input = common.trimLine(input_raw);
    if (input.len == 0) return error.EmptyInput;
    if (input[0] == '<') {
        const close = std.mem.indexOfScalar(u8, input, '>') orelse return error.InvalidSyntax;
        if (close + 1 < input.len and std.ascii.isDigit(input[close + 1])) return parseRfc5424(input, context);
        return parsePriorityPrefixedClassic(input, context);
    }
    return parseClassic(input, context);
}

pub fn parseRfc5424(input: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    var record = record_mod.Record.init(.rfc5424);
    common.applyContext(&record, context);
    var cursor = cursor_mod.LineCursor.init(input);
    if (!cursor.consume('<')) return error.InvalidSyntax;
    const priority_text = cursor.takeUntil('>');
    if (!cursor.consume('>')) return error.InvalidSyntax;
    const priority = common.parseUnsigned(u8, priority_text) catch return error.InvalidNumber;
    if (priority > 191) return error.InvalidNumber;
    applyPriority(&record, priority);

    const version = cursor.takeToken();
    if (version.len == 0) return error.MissingField;
    _ = common.parseUnsigned(u8, version) catch return error.InvalidNumber;
    const timestamp = cursor.takeToken();
    const host = cursor.takeToken();
    const app = cursor.takeToken();
    const procid = cursor.takeToken();
    const msgid = cursor.takeToken();
    if (timestamp.len == 0 or host.len == 0 or app.len == 0 or procid.len == 0 or msgid.len == 0) return error.MissingField;

    if (!std.mem.eql(u8, timestamp, "-")) record.timestamp_text = timestamp;
    if (!std.mem.eql(u8, host, "-")) record.host = host;
    if (!std.mem.eql(u8, app, "-")) record.service = app;
    if (!std.mem.eql(u8, procid, "-")) record.process_id = procid;
    if (!std.mem.eql(u8, msgid, "-")) record.event_id = msgid;

    cursor.skipAsciiWhitespace();
    if (cursor.peek() == '[') {
        try parseStructuredData(&record, &cursor, context);
    } else if (cursor.consume('-')) {
        cursor.skipAsciiWhitespace();
    } else {
        common.appendWarning(&record, context, .invalid_structure, cursor.column(), null, "structured-data marker is missing");
    }
    record.message = cursor.remaining();
    extractMessageFields(&record, context);
    return record;
}

fn parseStructuredData(record: *record_mod.Record, cursor: *cursor_mod.LineCursor, context: common.ParseContext) common.ParseError!void {
    var element_count: usize = 0;
    while (cursor.peek() == '[') {
        if (element_count >= 16) {
            common.appendWarning(record, context, .recoverable_record, cursor.column(), null, "structured-data element limit reached");
            return;
        }
        const body = cursor.takeBracketed('[', ']', context.max_token_bytes) catch return error.InvalidSyntax;
        try parseStructuredElement(record, body, context);
        element_count += 1;
        cursor.skipAsciiWhitespace();
    }
}

fn parseStructuredElement(record: *record_mod.Record, body: []const u8, context: common.ParseContext) common.ParseError!void {
    var cursor = cursor_mod.LineCursor.init(body);
    const sd_id = cursor.takeToken();
    if (sd_id.len == 0) return error.InvalidSyntax;
    try common.addFieldRecovering(record, "structured_id", .{ .text = sd_id }, context);
    while (!cursor.atEnd()) {
        cursor.skipAsciiWhitespace();
        if (cursor.atEnd()) break;
        const key_start = cursor.index;
        while (cursor.peek()) |ch| {
            if (ch == '=' or ch == ' ' or ch == '\t') break;
            cursor.index += 1;
        }
        const key = body[key_start..cursor.index];
        cursor.skipAsciiWhitespace();
        if (!cursor.consume('=')) {
            common.appendWarning(record, context, .invalid_structure, cursor.column(), key, "structured parameter is missing '='");
            break;
        }
        const value = cursor.takeQuoted('"', context.max_token_bytes) catch {
            common.appendWarning(record, context, .invalid_escape, cursor.column(), key, "structured parameter has invalid quoting");
            break;
        };
        try common.addFieldRecovering(record, key, .{ .text = value }, context);
    }
}

pub fn parseClassic(input: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    var record = record_mod.Record.init(.syslog);
    common.applyContext(&record, context);
    if (input.len < 16) return error.InvalidSyntax;
    record.timestamp_text = input[0..15];
    var rest = std.mem.trimLeft(u8, input[15..], " \t");
    const host_end = std.mem.indexOfAny(u8, rest, " \t") orelse return error.MissingField;
    record.host = rest[0..host_end];
    rest = std.mem.trimLeft(u8, rest[host_end..], " \t");
    const colon = std.mem.indexOfScalar(u8, rest, ':');
    if (colon) |index| {
        const program = rest[0..index];
        parseProgramIdentity(&record, program);
        record.message = std.mem.trimLeft(u8, rest[index + 1 ..], " ");
    } else {
        record.message = rest;
        common.appendWarning(&record, context, .recoverable_record, 16 + host_end, null, "classic syslog program delimiter is missing");
    }
    inferClassicSeverity(&record);
    extractMessageFields(&record, context);
    return record;
}

fn parsePriorityPrefixedClassic(input: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    const close = std.mem.indexOfScalar(u8, input, '>') orelse return error.InvalidSyntax;
    const priority = common.parseUnsigned(u8, input[1..close]) catch return error.InvalidNumber;
    var record = try parseClassic(std.mem.trimLeft(u8, input[close + 1 ..], " "), context);
    applyPriority(&record, priority);
    return record;
}

fn parseProgramIdentity(record: *record_mod.Record, input: []const u8) void {
    const open = std.mem.indexOfScalar(u8, input, '[');
    if (open) |open_index| {
        const close = std.mem.indexOfScalarPos(u8, input, open_index + 1, ']');
        if (close) |close_index| {
            record.service = input[0..open_index];
            record.process_id = input[open_index + 1 .. close_index];
            return;
        }
    }
    record.service = input;
}

fn applyPriority(record: *record_mod.Record, priority: u8) void {
    const severity_code = priority % 8;
    record.severity = switch (severity_code) {
        0 => .emergency,
        1 => .alert,
        2 => .critical,
        3 => .@"error",
        4 => .warning,
        5 => .notice,
        6 => .info,
        7 => .debug,
        else => .unknown,
    };
    record.addField("facility", .{ .integer = @intCast(priority / 8) }) catch {};
    record.addField("priority", .{ .integer = @intCast(priority) }) catch {};
}

fn inferClassicSeverity(record: *record_mod.Record) void {
    const message = record.message;
    if (containsIgnoreCase(message, "panic") or containsIgnoreCase(message, "fatal")) record.severity = .critical
    else if (containsIgnoreCase(message, "error") or containsIgnoreCase(message, "failed")) record.severity = .@"error"
    else if (containsIgnoreCase(message, "warn")) record.severity = .warning
    else if (containsIgnoreCase(message, "debug")) record.severity = .debug
    else record.severity = .info;
}

fn extractMessageFields(record: *record_mod.Record, context: common.ParseContext) void {
    var tokens = std.mem.tokenizeAny(u8, record.message, " \t");
    while (tokens.next()) |token| {
        if (std.mem.startsWith(u8, token, "trace_id=")) {
            record.trace_id = token[9..];
        } else if (std.mem.startsWith(u8, token, "request_id=")) {
            record.request_id = token[12..];
        } else if (std.mem.startsWith(u8, token, "event_id=")) {
            record.event_id = token[9..];
        } else {
            _ = common.parseKeyValueToken(record, token, context) catch false;
        }
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "RFC5424 parser extracts identity and structured fields" {
    const record = try parse("<34>1 2026-07-30T07:00:00Z edge-01 scheduler 41 DEPLOY [meta trace_id=\"abc\" region=\"afr-east\"] rollout ready", .{});
    try std.testing.expectEqualStrings("edge-01", record.host.?);
    try std.testing.expectEqualStrings("scheduler", record.service.?);
    try std.testing.expectEqualStrings("afr-east", record.getField("region").?.text);
}
