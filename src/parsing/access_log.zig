const std = @import("std");
const record_mod = @import("../model/record.zig");
const common = @import("common.zig");
const cursor_mod = @import("../input/line_cursor.zig");

pub fn parse(input_raw: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    const input = common.trimLine(input_raw);
    if (input.len == 0) return error.EmptyInput;
    var record = record_mod.Record.init(.access_log);
    common.applyContext(&record, context);
    var cursor = cursor_mod.LineCursor.init(input);
    record.network.source_address = cursor.takeToken();
    const ident = cursor.takeToken();
    const user = cursor.takeToken();
    cursor.skipAsciiWhitespace();
    const timestamp = cursor.takeBracketed('[', ']', context.max_token_bytes) catch return error.InvalidSyntax;
    cursor.skipAsciiWhitespace();
    const request = cursor.takeQuoted('"', context.max_token_bytes) catch return error.InvalidSyntax;
    const status_text = cursor.takeToken();
    const bytes_text = cursor.takeToken();
    if (record.network.source_address.?.len == 0 or timestamp.len == 0 or request.len == 0 or status_text.len == 0) return error.MissingField;
    record.timestamp_text = timestamp;
    if (!std.mem.eql(u8, ident, "-")) try common.addFieldRecovering(&record, "ident", .{ .text = ident }, context);
    if (!std.mem.eql(u8, user, "-")) try common.addFieldRecovering(&record, "remote_user", .{ .text = user }, context);
    record.network.status = common.parseUnsigned(u16, status_text) catch return error.InvalidNumber;
    if (!std.mem.eql(u8, bytes_text, "-")) record.network.bytes = common.parseUnsigned(u64, bytes_text) catch blk: {
        common.appendWarning(&record, context, .invalid_number, cursor.column(), "bytes", "response byte count is not an integer");
        break :blk null;
    };
    parseRequest(&record, request, context);
    cursor.skipAsciiWhitespace();
    if (cursor.peek() == '"') {
        const referer = cursor.takeQuoted('"', context.max_token_bytes) catch "";
        if (!std.mem.eql(u8, referer, "-")) try common.addFieldRecovering(&record, "referer", .{ .text = referer }, context);
    }
    cursor.skipAsciiWhitespace();
    if (cursor.peek() == '"') {
        const agent = cursor.takeQuoted('"', context.max_token_bytes) catch "";
        if (!std.mem.eql(u8, agent, "-")) try common.addFieldRecovering(&record, "user_agent", .{ .text = agent }, context);
    }
    parseExtendedTokens(&record, cursor.remaining(), context);
    record.severity = severityForStatus(record.network.status.?);
    record.message = request;
    return record;
}

fn parseRequest(record: *record_mod.Record, request: []const u8, context: common.ParseContext) void {
    var tokens = std.mem.tokenizeScalar(u8, request, ' ');
    const method = tokens.next() orelse {
        common.appendWarning(record, context, .invalid_structure, 1, "request", "HTTP request line is empty");
        return;
    };
    const path = tokens.next() orelse {
        common.appendWarning(record, context, .missing_required_field, 1, "request", "HTTP request path is missing");
        return;
    };
    const protocol = tokens.next() orelse "";
    record.network.method = method;
    record.network.path = path;
    if (protocol.len != 0) record.network.protocol = protocol;
    if (tokens.next() != null) common.appendWarning(record, context, .invalid_structure, 1, "request", "HTTP request line has extra tokens");
}

fn parseExtendedTokens(record: *record_mod.Record, tail: []const u8, context: common.ParseContext) void {
    var tokens = std.mem.tokenizeAny(u8, tail, " \t");
    while (tokens.next()) |token| {
        if (std.mem.startsWith(u8, token, "request_id=")) {
            record.request_id = token[11..];
        } else if (std.mem.startsWith(u8, token, "trace_id=")) {
            record.trace_id = token[9..];
        } else if (std.mem.startsWith(u8, token, "service=")) {
            record.service = token[9..];
        } else if (std.mem.startsWith(u8, token, "host=")) {
            record.host = token[5..];
        } else {
            _ = common.parseKeyValueToken(record, token, context) catch false;
        }
    }
}

pub fn severityForStatus(status: u16) record_mod.Severity {
    return if (status >= 500) .@"error" else if (status >= 400) .warning else if (status >= 300) .notice else .info;
}

pub fn statusClass(status: u16) u8 {
    return @intCast(status / 100);
}

pub fn isCacheableStatus(status: u16) bool {
    return switch (status) {
        200, 203, 204, 206, 300, 301, 404, 405, 410, 414, 501 => true,
        else => false,
    };
}

pub fn isLikelyBotAgent(agent: []const u8) bool {
    const needles = [_][]const u8{ "bot", "crawler", "spider", "probe", "monitor", "healthcheck" };
    for (needles) |needle| {
        var index: usize = 0;
        while (index + needle.len <= agent.len) : (index += 1) {
            if (std.ascii.eqlIgnoreCase(agent[index .. index + needle.len], needle)) return true;
        }
    }
    return false;
}

pub fn requestExtension(path: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
    const clean = path[0..query];
    const slash = std.mem.lastIndexOfScalar(u8, clean, '/') orelse 0;
    const dot = std.mem.lastIndexOfScalar(u8, clean, '.') orelse return "";
    if (dot < slash) return "";
    return clean[dot + 1 ..];
}

test "combined access log parser extracts request and status" {
    const record = try parse("203.0.113.8 - ops [30/Jul/2026:07:00:00 +0000] \"GET /health HTTP/1.1\" 503 71 \"-\" \"site-monitor/1.0\" request_id=req-7", .{});
    try std.testing.expectEqualStrings("GET", record.network.method.?);
    try std.testing.expectEqual(@as(u16, 503), record.network.status.?);
    try std.testing.expectEqualStrings("req-7", record.request_id.?);
}
