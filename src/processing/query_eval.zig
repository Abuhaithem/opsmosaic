const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");
const parser = @import("query_parser.zig");
const severity_mod = @import("../normalization/severity.zig");

pub const EvalError = error{
    InvalidNode,
    TooDeep,
};

pub const Options = struct {
    case_insensitive_text: bool = false,
    missing_is_null: bool = true,
    max_depth: usize = 64,
};

pub fn evaluate(program: *const parser.Program, record: *const record_mod.Record, options: Options) EvalError!bool {
    const root = program.root orelse return false;
    return evalNode(program, root, record, options, 0);
}

fn evalNode(program: *const parser.Program, index: u16, record: *const record_mod.Record, options: Options, depth: usize) EvalError!bool {
    if (depth > options.max_depth) return error.TooDeep;
    if (@as(usize, index) >= program.count) return error.InvalidNode;
    return switch (program.nodes[index]) {
        .predicate => |predicate| evaluatePredicate(record, predicate, options),
        .has_tag => |tag| record.hasTag(tag),
        .missing => |field| record.getField(field) == null,
        .logical_and => |node| (try evalNode(program, node.left, record, options, depth + 1)) and (try evalNode(program, node.right, record, options, depth + 1)),
        .logical_or => |node| (try evalNode(program, node.left, record, options, depth + 1)) or (try evalNode(program, node.right, record, options, depth + 1)),
        .logical_not => |child| !(try evalNode(program, child, record, options, depth + 1)),
    };
}

fn evaluatePredicate(record: *const record_mod.Record, predicate: parser.Predicate, options: Options) bool {
    const actual = fieldValue(record, predicate.field) orelse {
        return options.missing_is_null and predicate.value.kind() == .null_value and predicate.operator == .equal;
    };
    return switch (predicate.operator) {
        .equal => equalValues(actual, predicate.value, options),
        .not_equal => !equalValues(actual, predicate.value, options),
        .greater => compareValues(actual, predicate.value, .gt),
        .greater_equal => compareValues(actual, predicate.value, .gt) or compareValues(actual, predicate.value, .eq),
        .less => compareValues(actual, predicate.value, .lt),
        .less_equal => compareValues(actual, predicate.value, .lt) or compareValues(actual, predicate.value, .eq),
        .contains => containsValue(actual, predicate.value, options.case_insensitive_text),
        .starts_with => startsWithValue(actual, predicate.value, options.case_insensitive_text),
        .ends_with => endsWithValue(actual, predicate.value, options.case_insensitive_text),
    };
}

pub fn fieldValue(record: *const record_mod.Record, field: []const u8) ?record_mod.Value {
    if (std.mem.eql(u8, field, "format") or std.mem.eql(u8, field, "source_format")) return .{ .text = record.source.format.label() };
    if (std.mem.eql(u8, field, "tag_count")) return .{ .integer = @intCast(record.tag_count) };
    if (std.mem.eql(u8, field, "warning_count")) return .{ .integer = @intCast(record.warnings.count) };
    if (std.mem.eql(u8, field, "timestamp_ns")) if (record.timestamp_unix_ns) |value| {
        if (value >= std.math.minInt(i64) and value <= std.math.maxInt(i64)) return .{ .integer = @intCast(value) };
    };
    return record.getField(field);
}

fn equalValues(a: value_mod.Value, b: value_mod.Value, options: Options) bool {
    if (a.kind() == b.kind()) {
        if (a.kind() == .text and options.case_insensitive_text) return std.ascii.eqlIgnoreCase(a.text, b.text);
        return a.eql(b);
    }
    if (numeric(a) != null and numeric(b) != null) return numeric(a).? == numeric(b).?;
    if (a.asText()) |left| {
        if (b.asText()) |right| return if (options.case_insensitive_text) std.ascii.eqlIgnoreCase(left, right) else std.mem.eql(u8, left, right);
    }
    return false;
}

fn compareValues(a: value_mod.Value, b: value_mod.Value, wanted: std.math.Order) bool {
    if (numeric(a)) |left| if (numeric(b)) |right| return std.math.order(left, right) == wanted;
    if (a.asText()) |left| if (b.asText()) |right| {
        if (looksLikeSeverity(left) and looksLikeSeverity(right)) {
            return std.math.order(severity_mod.fromText(left).severity.rank(), severity_mod.fromText(right).severity.rank()) == wanted;
        }
        return std.mem.order(u8, left, right) == wanted;
    };
    return false;
}

fn containsValue(a: value_mod.Value, b: value_mod.Value, insensitive: bool) bool {
    const haystack = a.asText() orelse return false;
    const needle = b.asText() orelse return false;
    return if (insensitive) indexOfIgnoreCase(haystack, needle) != null else std.mem.indexOf(u8, haystack, needle) != null;
}

fn startsWithValue(a: value_mod.Value, b: value_mod.Value, insensitive: bool) bool {
    const text = a.asText() orelse return false;
    const prefix = b.asText() orelse return false;
    if (text.len < prefix.len) return false;
    return if (insensitive) std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix) else std.mem.startsWith(u8, text, prefix);
}

fn endsWithValue(a: value_mod.Value, b: value_mod.Value, insensitive: bool) bool {
    const text = a.asText() orelse return false;
    const suffix = b.asText() orelse return false;
    if (text.len < suffix.len) return false;
    return if (insensitive) std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix) else std.mem.endsWith(u8, text, suffix);
}

fn numeric(value: value_mod.Value) ?f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .decimal => |v| v,
        else => null,
    };
}

fn looksLikeSeverity(input: []const u8) bool {
    return severity_mod.fromText(input).severity != .unknown;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    return null;
}

pub fn filterIndices(program: *const parser.Program, records: []const record_mod.Record, options: Options, output: []usize) EvalError!usize {
    var count: usize = 0;
    for (records, 0..) |*record, index| {
        if (try evaluate(program, record, options)) {
            if (count >= output.len) break;
            output[count] = index;
            count += 1;
        }
    }
    return count;
}

test "query evaluator handles severity range and tags" {
    var record = record_mod.Record.init(.jsonl);
    record.severity = .error;
    try record.addTag("prod");
    const program = try parser.parse("severity >= warning and has(prod)", .{});
    try std.testing.expect(try evaluate(&program, &record, .{}));
}
