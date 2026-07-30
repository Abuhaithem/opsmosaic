const std = @import("std");
const record_mod = @import("../model/record.zig");
const timestamp = @import("../normalization/timestamp.zig");
const attribution = @import("../normalization/attribution.zig");

pub const Field = enum {
    trace_id,
    request_id,
    event_id,
    host,
    service,
    source_address,
};

pub const Options = struct {
    time_window_ns: i128 = 5 * std.time.ns_per_min,
    required_score: u8 = 60,
    fields: []const Field = &.{ .trace_id, .request_id, .event_id, .host, .service, .source_address },
    configured_field: ?[]const u8 = null,
};

pub const Evidence = struct {
    trace_id: bool = false,
    request_id: bool = false,
    event_id: bool = false,
    host: bool = false,
    service: bool = false,
    source_address: bool = false,
    configured_field: bool = false,
    time_window: bool = false,
};

pub const Match = struct {
    correlated: bool,
    score: u8,
    evidence: Evidence,
};

pub fn compare(a: *const record_mod.Record, b: *const record_mod.Record, options: Options) Match {
    var evidence = Evidence{};
    var score: u16 = 0;
    var available: u16 = 0;
    for (options.fields) |field| switch (field) {
        .trace_id => observeOptional(a.trace_id, b.trace_id, 100, &available, &score, &evidence.trace_id),
        .request_id => observeOptional(a.request_id, b.request_id, 90, &available, &score, &evidence.request_id),
        .event_id => observeOptional(a.event_id, b.event_id, 45, &available, &score, &evidence.event_id),
        .host => observeHost(a.host, b.host, 25, &available, &score, &evidence.host),
        .service => observeService(a.service, b.service, 25, &available, &score, &evidence.service),
        .source_address => observeOptional(a.network.source_address, b.network.source_address, 35, &available, &score, &evidence.source_address),
    };
    if (options.configured_field) |name| {
        const left = a.getField(name);
        const right = b.getField(name);
        if (left != null and right != null) {
            available += 60;
            if (left.?.eql(right.?)) {
                score += 60;
                evidence.configured_field = true;
            }
        }
    }
    if (a.timestamp_unix_ns != null and b.timestamp_unix_ns != null) {
        available += 20;
        if (timestamp.withinWindow(a.timestamp_unix_ns, b.timestamp_unix_ns, options.time_window_ns)) {
            score += 20;
            evidence.time_window = true;
        }
    }
    const normalized: u8 = if (available == 0) 0 else @intCast((score * 100) / available);
    const strong_identity = evidence.trace_id or evidence.request_id or evidence.configured_field;
    const correlated = normalized >= options.required_score and (strong_identity or evidence.time_window);
    return .{ .correlated = correlated, .score = normalized, .evidence = evidence };
}

pub const Group = struct {
    members: [256]usize = undefined,
    count: usize = 0,

    pub fn append(self: *Group, index: usize) bool {
        if (self.count >= self.members.len) return false;
        self.members[self.count] = index;
        self.count += 1;
        return true;
    }

    pub fn slice(self: *const Group) []const usize {
        return self.members[0..self.count];
    }
};

pub const GroupSet = struct {
    groups: [128]Group = undefined,
    count: usize = 0,
    ungrouped: usize = 0,
    truncated: usize = 0,

    pub fn slice(self: *const GroupSet) []const Group {
        return self.groups[0..self.count];
    }
};

pub fn group(records: []const record_mod.Record, options: Options) GroupSet {
    var result = GroupSet{};
    var assigned: [4096]bool = [_]bool{false} ** 4096;
    const limit = @min(records.len, assigned.len);
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (assigned[index]) continue;
        if (result.count >= result.groups.len) {
            result.truncated += limit - index;
            break;
        }
        var current = Group{};
        _ = current.append(index);
        assigned[index] = true;
        var candidate = index + 1;
        while (candidate < limit) : (candidate += 1) {
            if (assigned[candidate]) continue;
            var matches_group = false;
            for (current.slice()) |member| {
                if (compare(&records[member], &records[candidate], options).correlated) {
                    matches_group = true;
                    break;
                }
            }
            if (matches_group) {
                if (current.append(candidate)) assigned[candidate] = true else result.truncated += 1;
            }
        }
        if (current.count > 1) {
            result.groups[result.count] = current;
            result.count += 1;
        } else result.ungrouped += 1;
    }
    if (records.len > limit) result.truncated += records.len - limit;
    return result;
}

fn observeOptional(a: ?[]const u8, b: ?[]const u8, weight: u16, available: *u16, score: *u16, matched: *bool) void {
    if (a == null or b == null) return;
    available.* += weight;
    if (std.mem.eql(u8, a.?, b.?)) {
        score.* += weight;
        matched.* = true;
    }
}

fn observeHost(a: ?[]const u8, b: ?[]const u8, weight: u16, available: *u16, score: *u16, matched: *bool) void {
    if (a == null or b == null) return;
    available.* += weight;
    if (attribution.sameHost(a.?, b.?)) {
        score.* += weight;
        matched.* = true;
    }
}

fn observeService(a: ?[]const u8, b: ?[]const u8, weight: u16, available: *u16, score: *u16, matched: *bool) void {
    if (a == null or b == null) return;
    available.* += weight;
    if (attribution.sameService(a.?, b.?)) {
        score.* += weight;
        matched.* = true;
    }
}

test "request identifiers correlate records across services" {
    var a = record_mod.Record.init(.access_log);
    a.request_id = "req-1";
    a.timestamp_unix_ns = 100;
    var b = record_mod.Record.init(.jsonl);
    b.request_id = "req-1";
    b.timestamp_unix_ns = 120;
    try std.testing.expect(compare(&a, &b, .{ .time_window_ns = 100 }).correlated);
}
