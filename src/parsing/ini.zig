const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");
const common = @import("common.zig");

pub fn parse(input: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    var record = record_mod.Record.init(.ini);
    common.applyContext(&record, context);
    var section: []const u8 = "global";
    var lines = std.mem.splitScalar(u8, input, '\n');
    var line_number = context.line;
    var saw_assignment = false;
    while (lines.next()) |line_raw| : (line_number += 1) {
        const line = std.mem.trim(u8, common.stripTrailingComment(line_raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') {
                common.appendWarning(&record, .{ .line = line_number, .path = context.path, .recover = context.recover }, .invalid_structure, 1, null, "INI section header is not closed");
                if (!context.recover) return error.InvalidSyntax;
                continue;
            }
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (section.len == 0) return error.InvalidSyntax;
            if (record.service == null and !std.ascii.eqlIgnoreCase(section, "global")) record.service = section;
            continue;
        }
        const pair = splitAssignment(line) orelse {
            common.appendWarning(&record, .{ .line = line_number, .path = context.path, .recover = context.recover }, .invalid_structure, 1, null, "INI line does not contain '=' or ':'");
            if (!context.recover) return error.InvalidSyntax;
            continue;
        };
        const key = std.mem.trim(u8, pair.key, " \t");
        const value_raw = std.mem.trim(u8, pair.value, " \t");
        if (key.len == 0) return error.MissingField;
        saw_assignment = true;
        try addSectionField(&record, section, key, value_mod.parseScalar(value_raw), context, line_number);
        applyKnownSetting(&record, section, key, value_raw);
    }
    if (!saw_assignment) return error.MissingField;
    record.message = "service configuration";
    return record;
}

const Assignment = struct { key: []const u8, value: []const u8 };

fn splitAssignment(line: []const u8) ?Assignment {
    const equal = common.findUnquoted(line, '=');
    const colon = common.findUnquoted(line, ':');
    const index = if (equal == null) colon else if (colon == null) equal else @min(equal.?, colon.?);
    if (index) |i| return .{ .key = line[0..i], .value = line[i + 1 ..] };
    return null;
}

fn addSectionField(record: *record_mod.Record, section: []const u8, key: []const u8, value: record_mod.Value, context: common.ParseContext, line_number: usize) common.ParseError!void {
    if (record.field_count >= context.max_fields) {
        common.appendWarning(record, .{ .line = line_number, .path = context.path }, .recoverable_record, 1, key, "configuration field limit reached");
        return;
    }
    if (std.ascii.eqlIgnoreCase(section, "global")) {
        try common.addFieldRecovering(record, key, value, context);
        return;
    }
    var name_buffer: [256]u8 = undefined;
    const needed = section.len + 1 + key.len;
    if (needed > name_buffer.len) return error.InputTooLarge;
    @memcpy(name_buffer[0..section.len], section);
    name_buffer[section.len] = '.';
    @memcpy(name_buffer[section.len + 1 .. needed], key);
    // The combined key must outlive this stack frame, so retain the original key when a stable joined slice is unavailable.
    // Section identity is also stored as a field, allowing callers to reconstruct the qualified name deterministically.
    try common.addFieldRecovering(record, key, value, context);
    try common.addFieldRecovering(record, "section", .{ .text = section }, context);
}

fn applyKnownSetting(record: *record_mod.Record, section: []const u8, key: []const u8, value: []const u8) void {
    _ = section;
    if (std.ascii.eqlIgnoreCase(key, "host") or std.ascii.eqlIgnoreCase(key, "hostname")) record.host = common.unquote(value)
    else if (std.ascii.eqlIgnoreCase(key, "service") or std.ascii.eqlIgnoreCase(key, "name")) record.service = common.unquote(value)
    else if (std.ascii.eqlIgnoreCase(key, "environment")) record.addTag(common.unquote(value)) catch {}
    else if (std.ascii.eqlIgnoreCase(key, "enabled")) {
        const scalar = value_mod.parseScalar(value);
        if (scalar.asBoolean()) |enabled| if (!enabled) record.addTag("disabled") catch {};
    };
}

pub fn validateSectionName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == ' ')) return false;
    }
    return true;
}

pub fn countSections(input: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len >= 3 and line[0] == '[' and line[line.len - 1] == ']') count += 1;
    }
    return count;
}

pub fn hasDuplicateKey(input: []const u8, needle_section: []const u8, needle_key: []const u8) bool {
    var current = "global";
    var seen = false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, common.stripTrailingComment(line_raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            current = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }
        const pair = splitAssignment(line) orelse continue;
        const key = std.mem.trim(u8, pair.key, " \t");
        if (std.ascii.eqlIgnoreCase(current, needle_section) and std.ascii.eqlIgnoreCase(key, needle_key)) {
            if (seen) return true;
            seen = true;
        }
    }
    return false;
}

test "INI parser reads sections and typed settings" {
    const record = try parse("[api]\nhost=edge-1\nport=8443\nenabled=true\n", .{});
    try std.testing.expectEqualStrings("edge-1", record.host.?);
    try std.testing.expectEqual(@as(i64, 8443), record.getField("port").?.integer);
}
