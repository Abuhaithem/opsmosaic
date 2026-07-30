const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");
const eval = @import("query_eval.zig");

pub const NumericSummary = struct {
    count: usize = 0,
    missing: usize = 0,
    incompatible: usize = 0,
    sum: f64 = 0,
    minimum: ?f64 = null,
    maximum: ?f64 = null,

    pub fn observe(self: *NumericSummary, value: ?value_mod.Value) void {
        if (value == null) {
            self.missing += 1;
            return;
        }
        const number: f64 = switch (value.?) {
            .integer => |v| @floatFromInt(v),
            .decimal => |v| v,
            else => {
                self.incompatible += 1;
                return;
            },
        };
        if (!std.math.isFinite(number)) {
            self.incompatible += 1;
            return;
        }
        self.count += 1;
        self.sum += number;
        self.minimum = if (self.minimum) |current| @min(current, number) else number;
        self.maximum = if (self.maximum) |current| @max(current, number) else number;
    }

    pub fn average(self: NumericSummary) ?f64 {
        if (self.count == 0) return null;
        return self.sum / @as(f64, @floatFromInt(self.count));
    }
};

pub const CountEntry = struct {
    key: []const u8,
    count: usize,
};

pub const CountTable = struct {
    entries: [256]CountEntry = undefined,
    count: usize = 0,
    overflow: usize = 0,

    pub fn observe(self: *CountTable, key: []const u8) void {
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                entry.count += 1;
                return;
            }
        }
        if (self.count >= self.entries.len) {
            self.overflow += 1;
            return;
        }
        self.entries[self.count] = .{ .key = key, .count = 1 };
        self.count += 1;
    }

    pub fn slice(self: *const CountTable) []const CountEntry {
        return self.entries[0..self.count];
    }

    pub fn total(self: *const CountTable) usize {
        var result: usize = self.overflow;
        for (self.slice()) |entry| result += entry.count;
        return result;
    }

    pub fn largest(self: *const CountTable) ?CountEntry {
        if (self.count == 0) return null;
        var best = self.entries[0];
        for (self.entries[1..self.count]) |entry| if (entry.count > best.count) best = entry;
        return best;
    }
};

pub const TimeRange = struct {
    minimum_ns: ?i128 = null,
    maximum_ns: ?i128 = null,
    missing: usize = 0,

    pub fn observe(self: *TimeRange, timestamp: ?i128) void {
        if (timestamp) |value| {
            self.minimum_ns = if (self.minimum_ns) |current| @min(current, value) else value;
            self.maximum_ns = if (self.maximum_ns) |current| @max(current, value) else value;
        } else self.missing += 1;
    }

    pub fn spanNs(self: TimeRange) ?i128 {
        if (self.minimum_ns == null or self.maximum_ns == null) return null;
        return self.maximum_ns.? - self.minimum_ns.?;
    }
};

pub const StatusSummary = struct {
    total: usize = 0,
    informational: usize = 0,
    success: usize = 0,
    redirection: usize = 0,
    client_error: usize = 0,
    server_error: usize = 0,
    other: usize = 0,

    pub fn observe(self: *StatusSummary, status: ?u16) void {
        self.total += 1;
        const value = status orelse {
            self.other += 1;
            return;
        };
        switch (value / 100) {
            1 => self.informational += 1,
            2 => self.success += 1,
            3 => self.redirection += 1,
            4 => self.client_error += 1,
            5 => self.server_error += 1,
            else => self.other += 1,
        }
    }

    pub fn errorRate(self: StatusSummary) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.client_error + self.server_error)) / @as(f64, @floatFromInt(self.total));
    }

    pub fn serverErrorRate(self: StatusSummary) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.server_error)) / @as(f64, @floatFromInt(self.total));
    }
};

pub const Report = struct {
    record_count: usize = 0,
    by_severity: CountTable = .{},
    by_service: CountTable = .{},
    by_format: CountTable = .{},
    by_tag: CountTable = .{},
    timestamps: TimeRange = .{},
    status: StatusSummary = .{},
};

pub fn summarize(records: []const record_mod.Record) Report {
    var report = Report{};
    for (records) |*record| {
        report.record_count += 1;
        report.by_severity.observe(record.severity.label());
        report.by_service.observe(record.service orelse "<missing>");
        report.by_format.observe(record.source.format.label());
        for (record.tagSlice()) |tag| report.by_tag.observe(tag);
        report.timestamps.observe(record.timestamp_unix_ns);
        report.status.observe(record.network.status);
    }
    return report;
}

pub fn numeric(records: []const record_mod.Record, field: []const u8) NumericSummary {
    var summary = NumericSummary{};
    for (records) |*record| summary.observe(eval.fieldValue(record, field));
    return summary;
}

pub fn distinctCount(records: []const record_mod.Record, field: []const u8) usize {
    var hashes: [1024]u64 = undefined;
    var count: usize = 0;
    for (records) |*record| {
        const value = eval.fieldValue(record, field) orelse continue;
        const hash = value.hash();
        var seen = false;
        for (hashes[0..count]) |candidate| if (candidate == hash) {
            seen = true;
            break;
        };
        if (!seen and count < hashes.len) {
            hashes[count] = hash;
            count += 1;
        }
    }
    return count;
}

pub const Bucket = struct {
    start_ns: i128,
    count: usize,
};

pub const TimeBuckets = struct {
    buckets: [512]Bucket = undefined,
    count: usize = 0,
    missing: usize = 0,
    overflow: usize = 0,

    pub fn observe(self: *TimeBuckets, timestamp: ?i128, width_ns: i128) void {
        const value = timestamp orelse {
            self.missing += 1;
            return;
        };
        if (width_ns <= 0) return;
        const start = @divFloor(value, width_ns) * width_ns;
        for (self.buckets[0..self.count]) |*bucket| if (bucket.start_ns == start) {
            bucket.count += 1;
            return;
        };
        if (self.count >= self.buckets.len) {
            self.overflow += 1;
            return;
        }
        self.buckets[self.count] = .{ .start_ns = start, .count = 1 };
        self.count += 1;
    }
};

pub fn timeBuckets(records: []const record_mod.Record, width_ns: i128) TimeBuckets {
    var result = TimeBuckets{};
    for (records) |*record| result.observe(record.timestamp_unix_ns, width_ns);
    return result;
}

test "aggregation computes HTTP error rate" {
    var records = [_]record_mod.Record{ record_mod.Record.init(.access_log), record_mod.Record.init(.access_log) };
    records[0].network.status = 200;
    records[1].network.status = 503;
    const report = summarize(&records);
    try std.testing.expectEqual(@as(f64, 0.5), report.status.errorRate());
}
