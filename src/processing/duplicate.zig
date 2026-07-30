const std = @import("std");
const record_mod = @import("../model/record.zig");
const timestamp = @import("../normalization/timestamp.zig");

pub const Options = struct {
    include_timestamp: bool = true,
    timestamp_tolerance_ns: i128 = 0,
    include_fields: bool = true,
    include_tags: bool = false,
    case_insensitive_message: bool = false,
};

pub const Match = struct {
    duplicate: bool,
    score: u8,
    reason: []const u8,
};

pub fn compare(a: *const record_mod.Record, b: *const record_mod.Record, options: Options) Match {
    var score: u16 = 0;
    var possible: u16 = 0;

    possible += 20;
    if (optionalTextEqual(a.host, b.host, true)) score += 20;
    possible += 20;
    if (optionalTextEqual(a.service, b.service, true)) score += 20;
    possible += 15;
    if (optionalTextEqual(a.event_id, b.event_id, false)) score += 15;
    possible += 25;
    if (textEqual(a.message, b.message, options.case_insensitive_message)) score += 25;

    if (options.include_timestamp) {
        possible += 10;
        if (a.timestamp_unix_ns != null and b.timestamp_unix_ns != null) {
            if (timestamp.withinWindow(a.timestamp_unix_ns, b.timestamp_unix_ns, options.timestamp_tolerance_ns)) score += 10;
        } else if (optionalTextEqual(a.timestamp_text, b.timestamp_text, false)) score += 10;
    }

    if (options.include_fields) {
        possible += 10;
        if (sameFields(a, b)) score += 10;
    }
    if (options.include_tags) {
        possible += 5;
        if (sameTags(a, b)) score += 5;
    }

    const percent: u8 = if (possible == 0) 0 else @intCast((score * 100) / possible);
    if (percent == 100) return .{ .duplicate = true, .score = percent, .reason = "normalized content matches" };
    if (percent >= 90 and a.event_id != null) return .{ .duplicate = true, .score = percent, .reason = "event identity and normalized content strongly match" };
    return .{ .duplicate = false, .score = percent, .reason = "normalized content differs" };
}

pub const Index = struct {
    allocator: std.mem.Allocator,
    buckets: std.AutoHashMap(u64, std.ArrayList(usize)),
    options: Options,

    pub fn init(allocator: std.mem.Allocator, options: Options) Index {
        return .{ .allocator = allocator, .buckets = std.AutoHashMap(u64, std.ArrayList(usize)).init(allocator), .options = options };
    }

    pub fn deinit(self: *Index) void {
        var iterator = self.buckets.valueIterator();
        while (iterator.next()) |list| list.deinit();
        self.buckets.deinit();
    }

    pub fn observe(self: *Index, records: []const record_mod.Record, index: usize) !?usize {
        const record = &records[index];
        const fingerprint = fingerprintRecord(record, self.options);
        if (self.buckets.getPtr(fingerprint)) |candidates| {
            for (candidates.items) |candidate| {
                if (compare(&records[candidate], record, self.options).duplicate) return candidate;
            }
            try candidates.append(index);
            return null;
        }
        var list = std.ArrayList(usize).init(self.allocator);
        errdefer list.deinit();
        try list.append(index);
        try self.buckets.put(fingerprint, list);
        return null;
    }
};

pub fn fingerprintRecord(record: *const record_mod.Record, options: Options) u64 {
    var hasher = std.hash.Wyhash.init(0x4455504c49434154);
    updateOptional(&hasher, record.host, true);
    updateOptional(&hasher, record.service, true);
    updateOptional(&hasher, record.event_id, false);
    if (options.case_insensitive_message) updateLower(&hasher, record.message) else hasher.update(record.message);
    if (options.include_timestamp and options.timestamp_tolerance_ns == 0) {
        if (record.timestamp_unix_ns) |value| hasher.update(std.mem.asBytes(&value)) else updateOptional(&hasher, record.timestamp_text, false);
    }
    if (options.include_fields) {
        for (record.fieldSlice()) |field| {
            hasher.update(field.key);
            const digest = field.value.hash();
            hasher.update(std.mem.asBytes(&digest));
        }
    }
    return hasher.final();
}

fn sameFields(a: *const record_mod.Record, b: *const record_mod.Record) bool {
    if (a.field_count != b.field_count) return false;
    for (a.fieldSlice()) |field| {
        const other = b.getField(field.key) orelse return false;
        if (!field.value.eql(other)) return false;
    }
    return true;
}

fn sameTags(a: *const record_mod.Record, b: *const record_mod.Record) bool {
    if (a.tag_count != b.tag_count) return false;
    for (a.tagSlice()) |tag| if (!b.hasTag(tag)) return false;
    return true;
}

fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8, insensitive: bool) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return textEqual(a.?, b.?, insensitive);
}

fn textEqual(a: []const u8, b: []const u8, insensitive: bool) bool {
    return if (insensitive) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn updateOptional(hasher: *std.hash.Wyhash, value: ?[]const u8, insensitive: bool) void {
    if (value) |text| {
        if (insensitive) updateLower(hasher, text) else hasher.update(text);
    } else hasher.update("-");
}

fn updateLower(hasher: *std.hash.Wyhash, input: []const u8) void {
    var buffer: [256]u8 = undefined;
    var offset: usize = 0;
    while (offset < input.len) {
        const count = @min(buffer.len, input.len - offset);
        for (input[offset .. offset + count], 0..) |ch, index| buffer[index] = std.ascii.toLower(ch);
        hasher.update(buffer[0..count]);
        offset += count;
    }
}

test "semantic duplicate comparison ignores format-specific storage" {
    var a = record_mod.Record.init(.jsonl);
    a.host = "EDGE-1";
    a.service = "api";
    a.message = "ready";
    var b = record_mod.Record.init(.syslog);
    b.host = "edge-1";
    b.service = "api";
    b.message = "ready";
    try std.testing.expect(compare(&a, &b, .{ .include_timestamp = false }).duplicate);
}
