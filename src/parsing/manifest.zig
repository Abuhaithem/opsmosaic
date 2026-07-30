const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");
const common = @import("common.zig");

pub const ManifestLimits = struct {
    max_depth: usize = 12,
    max_items: usize = 256,
    max_key_bytes: usize = 128,
};

pub fn parse(input: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    return parseWithLimits(input, context, .{ .max_depth = context.max_depth, .max_items = context.max_fields, .max_key_bytes = 128 });
}

pub fn parseWithLimits(input: []const u8, context: common.ParseContext, limits: ManifestLimits) common.ParseError!record_mod.Record {
    var record = record_mod.Record.init(.manifest);
    common.applyContext(&record, context);
    var indent_stack: [16]usize = [_]usize{0} ** 16;
    var key_stack: [16][]const u8 = undefined;
    var depth: usize = 0;
    var items: usize = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var line_number = context.line;
    while (lines.next()) |line_raw| : (line_number += 1) {
        const no_comment = common.stripComment(line_raw, '#');
        const line = std.mem.trimRight(u8, no_comment, " \t\r");
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, '\t') != null) return error.UnsupportedFeature;
        if (containsUnsupportedFeature(trimmed)) {
            common.appendWarning(&record, .{ .line = line_number, .path = context.path }, .unsupported_manifest_feature, 1, null, "aliases, anchors, tags, flow collections, and block scalars are unsupported");
            if (!context.recover) return error.UnsupportedFeature;
            continue;
        }
        const indent = line.len - trimmed.len;
        while (depth > 0 and indent <= indent_stack[depth - 1]) depth -= 1;
        if (depth > limits.max_depth or depth >= key_stack.len) return error.UnsupportedFeature;
        if (std.mem.startsWith(u8, trimmed, "- ")) {
            try parseListItem(&record, trimmed[2..], context, line_number, depth, key_stack[0..depth]);
            items += 1;
            if (items >= limits.max_items) break;
            continue;
        }
        const colon = common.findUnquoted(trimmed, ':') orelse {
            common.appendWarning(&record, .{ .line = line_number, .path = context.path }, .invalid_structure, 1, null, "manifest mapping is missing ':'");
            if (!context.recover) return error.InvalidSyntax;
            continue;
        };
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value_text = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (key.len == 0 or key.len > limits.max_key_bytes) return error.InvalidSyntax;
        if (value_text.len == 0) {
            if (depth >= limits.max_depth) return error.UnsupportedFeature;
            key_stack[depth] = key;
            indent_stack[depth] = indent;
            depth += 1;
            applyContainerIdentity(&record, key, depth);
            continue;
        }
        try addManifestField(&record, key, value_mod.parseScalar(value_text), context, line_number, key_stack[0..depth]);
        applyKnownField(&record, key, common.unquote(value_text));
        items += 1;
        if (items >= limits.max_items) {
            common.appendWarning(&record, context, .recoverable_record, 1, null, "manifest item limit reached");
            break;
        }
    }
    if (items == 0 and record.field_count == 0) return error.MissingField;
    record.message = "deployment manifest";
    return record;
}

fn parseListItem(record: *record_mod.Record, input: []const u8, context: common.ParseContext, line_number: usize, depth: usize, parents: []const []const u8) common.ParseError!void {
    _ = depth;
    const colon = common.findUnquoted(input, ':');
    if (colon) |index| {
        const key = std.mem.trim(u8, input[0..index], " \t");
        const value = std.mem.trim(u8, input[index + 1 ..], " \t");
        if (key.len == 0) return error.InvalidSyntax;
        try addManifestField(record, key, value_mod.parseScalar(value), context, line_number, parents);
        applyKnownField(record, key, common.unquote(value));
    } else {
        const value = value_mod.parseScalar(input);
        try common.addFieldRecovering(record, "list_item", value, context);
        if (value.asText()) |text| record.addTag(text) catch {};
    }
}

fn addManifestField(record: *record_mod.Record, key: []const u8, value: record_mod.Value, context: common.ParseContext, line_number: usize, parents: []const []const u8) common.ParseError!void {
    _ = parents;
    var local = context;
    local.line = line_number;
    try common.addFieldRecovering(record, key, value, local);
}

fn applyContainerIdentity(record: *record_mod.Record, key: []const u8, depth: usize) void {
    if (depth == 1 and (std.ascii.eqlIgnoreCase(key, "service") or std.ascii.eqlIgnoreCase(key, "application"))) {
        record.addTag("service-manifest") catch {};
    }
}

fn applyKnownField(record: *record_mod.Record, key: []const u8, value: []const u8) void {
    if (std.ascii.eqlIgnoreCase(key, "name") and record.service == null) record.service = value
    else if (std.ascii.eqlIgnoreCase(key, "host") or std.ascii.eqlIgnoreCase(key, "node")) record.host = value
    else if (std.ascii.eqlIgnoreCase(key, "environment") or std.ascii.eqlIgnoreCase(key, "stage")) record.addTag(value) catch {}
    else if (std.ascii.eqlIgnoreCase(key, "trace_id")) record.trace_id = value
    else if (std.ascii.eqlIgnoreCase(key, "request_id")) record.request_id = value;
}

fn containsUnsupportedFeature(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "...")) return true;
    if (std.mem.indexOf(u8, line, " &") != null or std.mem.indexOf(u8, line, " *") != null) return true;
    if (std.mem.indexOf(u8, line, "!!") != null) return true;
    if (std.mem.indexOfScalar(u8, line, '{') != null or std.mem.indexOfScalar(u8, line, '}') != null) return true;
    if (std.mem.indexOfScalar(u8, line, '[') != null or std.mem.indexOfScalar(u8, line, ']') != null) return true;
    if (std.mem.endsWith(u8, line, "|") or std.mem.endsWith(u8, line, ">")) return true;
    return false;
}

pub fn indentationWidth(line: []const u8) common.ParseError!usize {
    var width: usize = 0;
    for (line) |ch| {
        if (ch == ' ') width += 1 else if (ch == '\t') return error.UnsupportedFeature else break;
    }
    return width;
}

pub fn scalarLooksQuoted(input: []const u8) bool {
    const value = std.mem.trim(u8, input, " \t");
    return value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''));
}

pub fn mappingCount(input: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, common.stripComment(line_raw, '#'), " \t\r");
        if (line.len == 0) continue;
        const candidate = if (std.mem.startsWith(u8, line, "- ")) line[2..] else line;
        if (common.findUnquoted(candidate, ':') != null) count += 1;
    }
    return count;
}

test "manifest parser handles a safe nested subset" {
    const record = try parse("service:\n  name: edge-api\n  environment: prod\n  replicas: 3\n", .{});
    try std.testing.expectEqualStrings("edge-api", record.service.?);
    try std.testing.expectEqual(@as(i64, 3), record.getField("replicas").?.integer);
}
