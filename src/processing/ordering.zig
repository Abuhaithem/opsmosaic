const std = @import("std");
const record_mod = @import("../model/record.zig");
const eval = @import("query_eval.zig");

pub const Direction = enum { ascending, descending };

pub const SortKey = struct {
    field: []const u8,
    direction: Direction = .ascending,
    missing_last: bool = true,
};

pub fn sort(records: []record_mod.Record, key: SortKey) void {
    std.mem.sort(record_mod.Record, records, key, lessThan);
}

fn lessThan(key: SortKey, left: record_mod.Record, right: record_mod.Record) bool {
    const a = eval.fieldValue(&left, key.field);
    const b = eval.fieldValue(&right, key.field);
    const order = compareOptional(a, b, key.missing_last);
    return switch (key.direction) {
        .ascending => order == .lt,
        .descending => order == .gt,
    };
}

fn compareOptional(a: ?record_mod.Value, b: ?record_mod.Value, missing_last: bool) std.math.Order {
    if (a == null and b == null) return .eq;
    if (a == null) return if (missing_last) .gt else .lt;
    if (b == null) return if (missing_last) .lt else .gt;
    return compareValues(a.?, b.?);
}

fn compareValues(a: record_mod.Value, b: record_mod.Value) std.math.Order {
    const an = numeric(a);
    const bn = numeric(b);
    if (an != null and bn != null) return std.math.order(an.?, bn.?);
    if (a.asText()) |left| if (b.asText()) |right| return std.mem.order(u8, left, right);
    return std.math.order(@intFromEnum(a.kind()), @intFromEnum(b.kind()));
}

fn numeric(value: record_mod.Value) ?f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .decimal => |v| v,
        else => null,
    };
}

pub fn stableIndices(records: []const record_mod.Record, key: SortKey, output: []usize) usize {
    const count = @min(records.len, output.len);
    for (output[0..count], 0..) |*slot, index| slot.* = index;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const current = output[i];
        var j = i;
        while (j > 0 and lessThan(key, records[current], records[output[j - 1]])) : (j -= 1) output[j] = output[j - 1];
        output[j] = current;
    }
    return count;
}

test "ordering places missing values last" {
    var records = [_]record_mod.Record{ record_mod.Record.init(.jsonl), record_mod.Record.init(.jsonl) };
    records[1].network.status = 200;
    sort(&records, .{ .field = "status" });
    try std.testing.expectEqual(@as(u16, 200), records[0].network.status.?);
}
