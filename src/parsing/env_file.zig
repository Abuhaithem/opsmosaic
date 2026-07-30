const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");
const common = @import("common.zig");

pub fn parse(input: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    var record = record_mod.Record.init(.env_file);
    common.applyContext(&record, context);
    var lines = std.mem.splitScalar(u8, input, '\n');
    var line_number = context.line;
    var assignments: usize = 0;
    while (lines.next()) |line_raw| : (line_number += 1) {
        var line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimLeft(u8, line[7..], " \t");
        const pair = common.splitOnce(line, '=') orelse {
            common.appendWarning(&record, .{ .line = line_number, .path = context.path, .recover = context.recover }, .invalid_structure, 1, null, "environment assignment is missing '='");
            if (!context.recover) return error.InvalidSyntax;
            continue;
        };
        const key = std.mem.trim(u8, pair.left, " \t");
        if (!validName(key)) {
            common.appendWarning(&record, .{ .line = line_number, .path = context.path, .recover = context.recover }, .invalid_structure, 1, key, "environment variable name is invalid");
            if (!context.recover) return error.InvalidSyntax;
            continue;
        }
        const value_text = stripInlineComment(std.mem.trimLeft(u8, pair.right, " \t"));
        const value = value_mod.parseScalar(value_text);
        try common.addFieldRecovering(&record, key, value, context);
        applyKnownVariable(&record, key, value_text);
        assignments += 1;
    }
    if (assignments == 0) return error.MissingField;
    record.message = "environment configuration";
    return record;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |ch| { if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false; }
    return true;
}

fn stripInlineComment(input: []const u8) []const u8 {
    var quote: ?u8 = null;
    var escaped = false;
    for (input, 0..) |ch, index| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#' and index > 0 and std.ascii.isWhitespace(input[index - 1])) return std.mem.trimRight(u8, input[0..index], " \t");
    }
    return input;
}

fn applyKnownVariable(record: *record_mod.Record, key: []const u8, value: []const u8) void {
    const clean = common.unquote(value);
    if (std.ascii.eqlIgnoreCase(key, "HOST") or std.ascii.eqlIgnoreCase(key, "HOSTNAME") or std.ascii.eqlIgnoreCase(key, "NODE_NAME")) record.host = clean
    else if (std.ascii.eqlIgnoreCase(key, "SERVICE") or std.ascii.eqlIgnoreCase(key, "SERVICE_NAME") or std.ascii.eqlIgnoreCase(key, "APP_NAME")) record.service = clean
    else if (std.ascii.eqlIgnoreCase(key, "ENVIRONMENT") or std.ascii.eqlIgnoreCase(key, "STAGE")) record.addTag(clean) catch {}
    else if (std.ascii.eqlIgnoreCase(key, "TRACE_ID")) record.trace_id = clean
    else if (std.ascii.eqlIgnoreCase(key, "REQUEST_ID")) record.request_id = clean;
}

pub fn referencesVariable(value: []const u8) bool {
    var index: usize = 0;
    while (index + 1 < value.len) : (index += 1) {
        if (value[index] == '$' and (value[index + 1] == '{' or std.ascii.isAlphabetic(value[index + 1]) or value[index + 1] == '_')) return true;
    }
    return false;
}

pub fn looksSensitiveName(name: []const u8) bool {
    const suffixes = [_][]const u8{ "PASSWORD", "PASS", "TOKEN", "SECRET", "PRIVATE_KEY", "API_KEY", "CREDENTIAL" };
    for (suffixes) |suffix| {
        if (std.ascii.eqlIgnoreCase(name, suffix) or endsWithIgnoreCase(name, suffix)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(input: []const u8, suffix: []const u8) bool {
    if (input.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(input[input.len - suffix.len ..], suffix);
}

pub fn countAssignments(input: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line_raw| {
        var line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimLeft(u8, line[7..], " \t");
        const pair = common.splitOnce(line, '=') orelse continue;
        if (validName(std.mem.trim(u8, pair.left, " \t"))) count += 1;
    }
    return count;
}

test "environment parser accepts export and quoted values" {
    const record = try parse("export SERVICE_NAME=edge-api\nPORT=8443\nSTAGE=\"prod\"\n", .{});
    try std.testing.expectEqualStrings("edge-api", record.service.?);
    try std.testing.expect(record.hasTag("prod"));
}
