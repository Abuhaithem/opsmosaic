const std = @import("std");
const record_mod = @import("../model/record.zig");

pub const Strategy = union(enum) {
    first: usize,
    every: usize,
    severity_weighted: SeverityWeighted,
    hash_partition: HashPartition,
};

pub const SeverityWeighted = struct {
    limit: usize,
    minimum_severity: record_mod.Severity = .warning,
    include_lower_every: usize = 100,
};

pub const HashPartition = struct {
    numerator: u32,
    denominator: u32,
    seed: u64 = 0x53414d504c494e47,
};

pub const Result = struct {
    indices: [4096]usize = undefined,
    count: usize = 0,
    considered: usize = 0,
    omitted: usize = 0,

    pub fn slice(self: *const Result) []const usize {
        return self.indices[0..self.count];
    }

};

pub fn select(records: []const record_mod.Record, strategy: Strategy) !Result {
    return switch (strategy) {
        .first => |limit| selectFirst(records, limit),
        .every => |step| selectEvery(records, step),
        .severity_weighted => |options| selectSeverityWeighted(records, options),
        .hash_partition => |partition| selectHashPartition(records, partition),
    };
}

fn selectFirst(records: []const record_mod.Record, limit: usize) Result {
    var result = Result{ .considered = records.len };
    const count = @min(@min(limit, records.len), result.indices.len);
    for (result.indices[0..count], 0..) |*slot, index| slot.* = index;
    result.count = count;
    result.omitted = records.len - count;
    return result;
}

fn selectEvery(records: []const record_mod.Record, step: usize) !Result {
    if (step == 0) return error.InvalidSamplingStep;
    var result = Result{ .considered = records.len };
    var index: usize = 0;
    while (index < records.len) : (index += step) {
        if (result.count >= result.indices.len) continue;
        result.indices[result.count] = index;
        result.count += 1;
    }
    result.omitted = records.len - result.count;
    return result;
}

fn selectSeverityWeighted(records: []const record_mod.Record, options: SeverityWeighted) !Result {
    if (options.limit == 0) return Result{ .considered = records.len, .omitted = records.len };
    if (options.include_lower_every == 0) return error.InvalidSamplingStep;
    var result = Result{ .considered = records.len };
    for (records, 0..) |*record, index| {
        const high = record.severity.rank() >= options.minimum_severity.rank();
        const lower_slot = !high and index % options.include_lower_every == 0;
        if (!high and !lower_slot) continue;
        if (result.count >= @min(options.limit, result.indices.len)) continue;
        result.indices[result.count] = index;
        result.count += 1;
    }
    result.omitted = records.len - result.count;
    return result;
}

fn selectHashPartition(records: []const record_mod.Record, partition: HashPartition) !Result {
    if (partition.denominator == 0 or partition.numerator >= partition.denominator) return error.InvalidPartition;
    var result = Result{ .considered = records.len };
    for (records, 0..) |*record, index| {
        var hasher = std.hash.Wyhash.init(partition.seed);
        const identity = record.identityHash();
        hasher.update(std.mem.asBytes(&identity));
        const slot = hasher.final() % partition.denominator;
        if (slot != partition.numerator) continue;
        if (result.count >= result.indices.len) continue;
        result.indices[result.count] = index;
        result.count += 1;
    }
    result.omitted = records.len - result.count;
    return result;
}

pub fn copySelected(records: []const record_mod.Record, selection: *const Result, output: []record_mod.Record) usize {
    const count = @min(selection.count, output.len);
    for (selection.indices[0..count], 0..) |record_index, output_index| {
        if (record_index >= records.len) break;
        output[output_index] = records[record_index];
    }
    return count;
}

pub fn stablePartitionKey(record: *const record_mod.Record, field: ?[]const u8, seed: u64) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    if (field) |name| {
        if (record.getField(name)) |value| {
            const digest = value.hash();
            hasher.update(std.mem.asBytes(&digest));
            return hasher.final();
        }
    }
    const identity = record.identityHash();
    hasher.update(std.mem.asBytes(&identity));
    return hasher.final();
}

pub fn validate(selection: *const Result, records_len: usize) bool {
    if (selection.count > selection.indices.len) return false;
    var previous: ?usize = null;
    for (selection.slice()) |index| {
        if (index >= records_len) return false;
        if (previous) |prior| if (index <= prior) return false;
        previous = index;
    }
    return true;
}

test "hash partitions are deterministic and disjoint" {
    var records = [_]record_mod.Record{ record_mod.Record.init(.jsonl), record_mod.Record.init(.jsonl), record_mod.Record.init(.jsonl) };
    records[0].message = "a";
    records[1].message = "b";
    records[2].message = "c";
    const left = try select(&records, .{ .hash_partition = .{ .numerator = 0, .denominator = 2 } });
    const right = try select(&records, .{ .hash_partition = .{ .numerator = 1, .denominator = 2 } });
    try std.testing.expectEqual(records.len, left.count + right.count);
    try std.testing.expect(validate(&left, records.len));
    try std.testing.expect(validate(&right, records.len));
}
