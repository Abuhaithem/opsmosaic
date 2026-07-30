const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");

pub const KindCounts = struct {
    text: usize = 0,
    integer: usize = 0,
    decimal: usize = 0,
    boolean: usize = 0,
    null_value: usize = 0,

    pub fn observe(self: *KindCounts, kind: value_mod.ValueKind) void {
        switch (kind) {
            .text => self.text += 1,
            .integer => self.integer += 1,
            .decimal => self.decimal += 1,
            .boolean => self.boolean += 1,
            .null_value => self.null_value += 1,
        }
    }

    pub fn total(self: KindCounts) usize {
        return self.text + self.integer + self.decimal + self.boolean + self.null_value;
    }

    pub fn dominant(self: KindCounts) ?value_mod.ValueKind {
        if (self.total() == 0) return null;
        var best: value_mod.ValueKind = .text;
        var count = self.text;
        const candidates = [_]struct { kind: value_mod.ValueKind, count: usize }{
            .{ .kind = .integer, .count = self.integer },
            .{ .kind = .decimal, .count = self.decimal },
            .{ .kind = .boolean, .count = self.boolean },
            .{ .kind = .null_value, .count = self.null_value },
        };
        for (candidates) |candidate| if (candidate.count > count) {
            best = candidate.kind;
            count = candidate.count;
        };
        return best;
    }
};

pub const FieldSummary = struct {
    name: []const u8,
    present: usize = 0,
    kinds: KindCounts = .{},
    minimum_text_length: ?usize = null,
    maximum_text_length: ?usize = null,
    numeric_minimum: ?f64 = null,
    numeric_maximum: ?f64 = null,
    numeric_sum: f64 = 0,
    numeric_count: usize = 0,
    distinct_hashes: [128]u64 = undefined,
    distinct_count: usize = 0,
    distinct_overflow: usize = 0,

    pub fn observe(self: *FieldSummary, value: value_mod.Value) void {
        self.present += 1;
        self.kinds.observe(value.kind());
        switch (value) {
            .text => |text| {
                self.minimum_text_length = if (self.minimum_text_length) |current| @min(current, text.len) else text.len;
                self.maximum_text_length = if (self.maximum_text_length) |current| @max(current, text.len) else text.len;
            },
            .integer => |number| self.observeNumber(@floatFromInt(number)),
            .decimal => |number| self.observeNumber(number),
            else => {},
        }
        self.observeDistinct(value.hash());
    }

    pub fn missing(self: FieldSummary, records: usize) usize {
        return records -| self.present;
    }

    pub fn coverage(self: FieldSummary, records: usize) f64 {
        if (records == 0) return 0;
        return @as(f64, @floatFromInt(self.present)) / @as(f64, @floatFromInt(records));
    }

    pub fn numericAverage(self: FieldSummary) ?f64 {
        if (self.numeric_count == 0) return null;
        return self.numeric_sum / @as(f64, @floatFromInt(self.numeric_count));
    }

    fn observeNumber(self: *FieldSummary, number: f64) void {
        if (!std.math.isFinite(number)) return;
        self.numeric_minimum = if (self.numeric_minimum) |current| @min(current, number) else number;
        self.numeric_maximum = if (self.numeric_maximum) |current| @max(current, number) else number;
        self.numeric_sum += number;
        self.numeric_count += 1;
    }

    fn observeDistinct(self: *FieldSummary, hash: u64) void {
        for (self.distinct_hashes[0..self.distinct_count]) |candidate| if (candidate == hash) return;
        if (self.distinct_count >= self.distinct_hashes.len) {
            self.distinct_overflow += 1;
            return;
        }
        self.distinct_hashes[self.distinct_count] = hash;
        self.distinct_count += 1;
    }
};

pub const Profile = struct {
    fields: [512]FieldSummary = undefined,
    count: usize = 0,
    records: usize = 0,
    overflow_fields: usize = 0,

    pub fn slice(self: *const Profile) []const FieldSummary {
        return self.fields[0..self.count];
    }

    pub fn find(self: *const Profile, name: []const u8) ?FieldSummary {
        for (self.slice()) |summary| if (std.mem.eql(u8, summary.name, name)) return summary;
        return null;
    }
};

pub fn build(records: []const record_mod.Record) Profile {
    var profile = Profile{ .records = records.len };
    for (records) |*record| {
        observeCore(&profile, "severity", .{ .text = record.severity.label() });
        if (record.host) |value| observeCore(&profile, "host", .{ .text = value });
        if (record.service) |value| observeCore(&profile, "service", .{ .text = value });
        if (record.event_id) |value| observeCore(&profile, "event_id", .{ .text = value });
        if (record.request_id) |value| observeCore(&profile, "request_id", .{ .text = value });
        if (record.trace_id) |value| observeCore(&profile, "trace_id", .{ .text = value });
        if (record.timestamp_unix_ns) |value| {
            if (value >= std.math.minInt(i64) and value <= std.math.maxInt(i64)) observeCore(&profile, "timestamp_ns", .{ .integer = @intCast(value) });
        }
        for (record.fieldSlice()) |field| observeCore(&profile, field.key, field.value);
    }
    return profile;
}

fn observeCore(profile: *Profile, name: []const u8, value: value_mod.Value) void {
    for (profile.fields[0..profile.count]) |*summary| {
        if (std.mem.eql(u8, summary.name, name)) {
            summary.observe(value);
            return;
        }
    }
    if (profile.count >= profile.fields.len) {
        profile.overflow_fields += 1;
        return;
    }
    profile.fields[profile.count] = .{ .name = name };
    profile.fields[profile.count].observe(value);
    profile.count += 1;
}

pub fn writeText(profile: *const Profile, writer: anytype) !void {
    try writer.print("records={d} fields={d} overflow_fields={d}\n", .{ profile.records, profile.count, profile.overflow_fields });
    for (profile.slice()) |summary| {
        try writer.print("field={s} present={d} missing={d} coverage={d:.6} dominant={s} distinct={d}", .{
            summary.name,
            summary.present,
            summary.missing(profile.records),
            summary.coverage(profile.records),
            if (summary.kinds.dominant()) |kind| @tagName(kind) else "none",
            summary.distinct_count,
        });
        if (summary.minimum_text_length) |minimum| try writer.print(" min_len={d}", .{minimum});
        if (summary.maximum_text_length) |maximum| try writer.print(" max_len={d}", .{maximum});
        if (summary.numeric_minimum) |minimum| try writer.print(" min={d}", .{minimum});
        if (summary.numeric_maximum) |maximum| try writer.print(" max={d}", .{maximum});
        if (summary.numericAverage()) |average| try writer.print(" avg={d}", .{average});
        if (summary.distinct_overflow != 0) try writer.print(" distinct_overflow={d}", .{summary.distinct_overflow});
        try writer.writeByte('\n');
    }
}

pub fn compatibleKinds(profile: *const Profile, field: []const u8, allowed: []const value_mod.ValueKind) bool {
    const summary = profile.find(field) orelse return true;
    const observed = [_]struct { kind: value_mod.ValueKind, count: usize }{
        .{ .kind = .text, .count = summary.kinds.text },
        .{ .kind = .integer, .count = summary.kinds.integer },
        .{ .kind = .decimal, .count = summary.kinds.decimal },
        .{ .kind = .boolean, .count = summary.kinds.boolean },
        .{ .kind = .null_value, .count = summary.kinds.null_value },
    };
    for (observed) |entry| {
        if (entry.count == 0) continue;
        var accepted = false;
        for (allowed) |kind| if (kind == entry.kind) {
            accepted = true;
            break;
        };
        if (!accepted) return false;
    }
    return true;
}

test "field profile measures coverage and mixed kinds" {
    var records = [_]record_mod.Record{ record_mod.Record.init(.jsonl), record_mod.Record.init(.jsonl) };
    try records[0].addField("duration_ms", .{ .integer = 10 });
    try records[1].addField("duration_ms", .{ .decimal = 12.5 });
    const profile = build(&records);
    const summary = profile.find("duration_ms").?;
    try std.testing.expectEqual(@as(usize, 2), summary.present);
    try std.testing.expect(compatibleKinds(&profile, "duration_ms", &.{ .integer, .decimal }));
}
