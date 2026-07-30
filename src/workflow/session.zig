const std = @import("std");
const record_mod = @import("../model/record.zig");
const source_mod = @import("../model/source_info.zig");
const stream = @import("../input/stream_reader.zig");
const file_loader = @import("../input/file_loader.zig");
const batch_mod = @import("../processing/batch.zig");
const duplicate = @import("../processing/duplicate.zig");

pub const InputStats = struct {
    inputs: usize = 0,
    bytes: usize = 0,
    lines_seen: usize = 0,
    parsed: usize = 0,
    failed: usize = 0,
    empty: usize = 0,
    recovered: usize = 0,
    warnings: usize = 0,

    pub fn merge(self: *InputStats, bytes: usize, batch: batch_mod.BatchStats) void {
        self.inputs += 1;
        self.bytes += bytes;
        self.lines_seen += batch.lines_seen;
        self.parsed += batch.parsed;
        self.failed += batch.failed;
        self.empty += batch.empty;
        self.recovered += batch.recovered;
        self.warnings += batch.warnings;
    }

    pub fn successRate(self: InputStats) f64 {
        const attempted = self.parsed + self.failed;
        if (attempted == 0) return 0;
        return @as(f64, @floatFromInt(self.parsed)) / @as(f64, @floatFromInt(attempted));
    }
};

pub const IngestOptions = struct {
    format: source_mod.SourceFormat = .unknown,
    stream_limits: stream.StreamLimits = .{},
    continue_after_error: bool = true,
    skip_empty: bool = true,
    deduplicate: bool = false,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(record_mod.OwnedRecord),
    stats: InputStats = .{},
    sources: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .allocator = allocator,
            .records = std.ArrayList(record_mod.OwnedRecord).init(allocator),
            .sources = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Session) void {
        for (self.records.items) |*record| record.deinit();
        self.records.deinit();
        for (self.sources.items) |source| self.allocator.free(source);
        self.sources.deinit();
        self.* = undefined;
    }

    pub fn ingestBytes(self: *Session, input: []const u8, path: ?[]const u8, options: IngestOptions) !void {
        var parsed = try batch_mod.parseInput(self.allocator, input, path, .{
            .format = options.format,
            .stream_limits = options.stream_limits,
            .continue_after_error = options.continue_after_error,
            .skip_empty = options.skip_empty,
        });
        defer parsed.deinit();
        self.stats.merge(input.len, parsed.stats);
        if (path) |name| try self.rememberSource(name);
        for (parsed.records.items) |*candidate| {
            if (options.deduplicate and self.containsSemantic(&candidate.record)) continue;
            try self.adopt(candidate);
        }
    }

    fn adopt(self: *Session, candidate: *record_mod.OwnedRecord) !void {
        try self.records.append(candidate.*);
    }

    pub fn ingestPath(self: *Session, path: []const u8, options: IngestOptions) !void {
        var input = try file_loader.loadPath(self.allocator, path, options.stream_limits);
        defer input.deinit();
        try self.ingestBytes(input.bytes, path, options);
    }

    pub fn ingestStdin(self: *Session, options: IngestOptions) !void {
        var input = try file_loader.loadStdin(self.allocator, options.stream_limits);
        defer input.deinit();
        try self.ingestBytes(input.bytes, null, options);
    }

    pub fn recordCount(self: *const Session) usize {
        return self.records.items.len;
    }

    pub fn borrowedView(self: *const Session, allocator: std.mem.Allocator) ![]record_mod.Record {
        const result = try allocator.alloc(record_mod.Record, self.records.items.len);
        for (self.records.items, 0..) |owned, index| result[index] = owned.record;
        return result;
    }

    pub fn sourceSlice(self: *const Session) []const []u8 {
        return self.sources.items;
    }

    pub fn removeDuplicates(self: *Session) usize {
        if (self.records.items.len < 2) return 0;
        var removed: usize = 0;
        var index: usize = 0;
        while (index < self.records.items.len) : (index += 1) {
            var candidate = index + 1;
            while (candidate < self.records.items.len) {
                if (duplicate.equivalent(&self.records.items[index].record, &self.records.items[candidate].record, .{})) {
                    var discarded = self.records.orderedRemove(candidate);
                    discarded.deinit();
                    removed += 1;
                } else candidate += 1;
            }
        }
        return removed;
    }

    fn containsSemantic(self: *const Session, candidate: *const record_mod.Record) bool {
        for (self.records.items) |*existing| {
            if (duplicate.equivalent(&existing.record, candidate, .{})) return true;
        }
        return false;
    }

    fn rememberSource(self: *Session, name: []const u8) !void {
        for (self.sources.items) |existing| { if (std.mem.eql(u8, existing, name)) return; }
        const copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(copy);
        try self.sources.append(copy);
    }
};

test "session owns records after the source buffer is released" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    const input = try std.testing.allocator.dupe(u8, "{\"service\":\"gateway\",\"message\":\"ready\"}\n");
    try session.ingestBytes(input, "gateway.jsonl", .{ .format = .jsonl });
    std.testing.allocator.free(input);
    try std.testing.expectEqualStrings("gateway", session.records.items[0].record.service.?);
}

test "session can remove semantic duplicates" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    try session.ingestBytes("{\"service\":\"api\",\"message\":\"same\"}\n{\"service\":\"api\",\"message\":\"same\"}\n", null, .{ .format = .jsonl });
    try std.testing.expectEqual(@as(usize, 1), session.removeDuplicates());
}
