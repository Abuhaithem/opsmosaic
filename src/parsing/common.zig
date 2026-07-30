const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");
const diag_mod = @import("../diagnostics/diagnostic.zig");

pub const ParseError = error{
    EmptyInput,
    UnsupportedFormat,
    InvalidSyntax,
    InvalidTimestamp,
    InvalidNumber,
    MissingField,
    TooManyFields,
    TooManyTags,
    InputTooLarge,
    UnsupportedFeature,
};

pub const ParseContext = struct {
    path: ?[]const u8 = null,
    line: usize = 1,
    byte_offset: usize = 0,
    max_fields: usize = 64,
    max_depth: usize = 16,
    max_token_bytes: usize = 256 * 1024,
    recover: bool = true,
};

pub fn applyContext(record: *record_mod.Record, context: ParseContext) void {
    record.source.path = context.path;
    record.source.line = context.line;
    record.source.byte_offset = context.byte_offset;
}

pub fn trimLine(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

pub fn splitOnce(input: []const u8, delimiter: u8) ?struct { left: []const u8, right: []const u8 } {
    const index = std.mem.indexOfScalar(u8, input, delimiter) orelse return null;
    return .{ .left = input[0..index], .right = input[index + 1 ..] };
}

pub fn splitOnceText(input: []const u8, delimiter: []const u8) ?struct { left: []const u8, right: []const u8 } {
    const index = std.mem.indexOf(u8, input, delimiter) orelse return null;
    return .{ .left = input[0..index], .right = input[index + delimiter.len ..] };
}

pub fn stripComment(input: []const u8, marker: u8) []const u8 {
    var quoted: ?u8 = null;
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
        if (quoted) |quote| {
            if (ch == quote) quoted = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quoted = ch;
            continue;
        }
        if (ch == marker) return input[0..index];
    }
    return input;
}

pub fn stripTrailingComment(input: []const u8) []const u8 {
    const hash = stripComment(input, '#');
    return stripComment(hash, ';');
}

pub fn parseUnsigned(comptime T: type, input: []const u8) ParseError!T {
    return std.fmt.parseInt(T, trimLine(input), 10) catch error.InvalidNumber;
}

pub fn parseSigned(comptime T: type, input: []const u8) ParseError!T {
    return std.fmt.parseInt(T, trimLine(input), 10) catch error.InvalidNumber;
}

pub fn parseDecimal(input: []const u8) ParseError!f64 {
    return std.fmt.parseFloat(f64, trimLine(input)) catch error.InvalidNumber;
}

pub fn addFieldRecovering(record: *record_mod.Record, key: []const u8, value: record_mod.Value, context: ParseContext) ParseError!void {
    if (record.field_count >= context.max_fields) {
        record.warnings.append(.{
            .severity = .warning,
            .code = .recoverable_record,
            .line = context.line,
            .column = 1,
            .field = key,
            .message = "field limit reached; remaining fields were ignored",
        });
        record.recovered = true;
        if (!context.recover) return error.TooManyFields;
        return;
    }
    record.addField(key, value) catch return error.TooManyFields;
}

pub fn appendWarning(record: *record_mod.Record, context: ParseContext, code: diag_mod.Code, column: usize, field: ?[]const u8, message: []const u8) void {
    record.warnings.append(.{
        .severity = .warning,
        .code = code,
        .line = context.line,
        .column = column,
        .field = field,
        .message = message,
    });
    record.recovered = true;
}

pub fn unquote(input_raw: []const u8) []const u8 {
    const input = trimLine(input_raw);
    if (input.len < 2) return input;
    const first = input[0];
    const last = input[input.len - 1];
    if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) return input[1 .. input.len - 1];
    return input;
}

pub fn isLikelyTimestamp(input: []const u8) bool {
    if (input.len < 10) return false;
    if (input.len >= 20 and input[4] == '-' and input[7] == '-' and (input[10] == 'T' or input[10] == ' ')) return true;
    if (input.len >= 15 and std.ascii.isAlphabetic(input[0]) and std.ascii.isDigit(input[4])) return true;
    return false;
}

pub fn tokenCount(input: []const u8) usize {
    var iterator = std.mem.tokenizeAny(u8, input, " \t\r\n");
    var count: usize = 0;
    while (iterator.next() != null) count += 1;
    return count;
}

pub fn findUnquoted(input: []const u8, needle: u8) ?usize {
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
        if (ch == needle) return index;
    }
    return null;
}

pub fn validateKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 256) return false;
    for (key) |ch| {
        if (ch < 0x20 or ch == '=' or ch == ':' or ch == ',' or ch == '{' or ch == '}') return false;
    }
    return true;
}

pub fn lowerAsciiInto(input: []const u8, output: []u8) []const u8 {
    const n = @min(input.len, output.len);
    for (input[0..n], 0..) |ch, index| output[index] = std.ascii.toLower(ch);
    return output[0..n];
}

pub fn parseKeyValueToken(record: *record_mod.Record, token: []const u8, context: ParseContext) ParseError!bool {
    const pair = splitOnce(token, '=') orelse return false;
    const key = trimLine(pair.left);
    if (!validateKey(key)) return false;
    try addFieldRecovering(record, key, value_mod.parseScalar(pair.right), context);
    return true;
}

test "comment stripping respects quoted markers" {
    try std.testing.expectEqualStrings("key=\"a#b\" ", stripComment("key=\"a#b\" # comment", '#'));
}
