const std = @import("std");
const record_mod = @import("../model/record.zig");
const duplicate = @import("../processing/duplicate.zig");
const correlation = @import("../processing/correlation.zig");
const aggregation = @import("../processing/aggregation.zig");
const policy_mod = @import("../validation/policy.zig");

pub const Stage = enum {
    detected,
    parsed,
    normalized,
    validated,
    deduplicated,
    correlated,
    exported,
};

pub const Entry = struct {
    sequence: u64,
    stage: Stage,
    source: []const u8,
    line: usize,
    record_hash: u64,
    detail: []const u8,
};

pub const Trail = struct {
    entries: [4096]Entry = undefined,
    count: usize = 0,
    dropped: usize = 0,
    next_sequence: u64 = 1,

    pub fn append(self: *Trail, stage: Stage, record: *const record_mod.Record, detail: []const u8) void {
        if (self.count >= self.entries.len) {
            self.dropped += 1;
            return;
        }
        self.entries[self.count] = .{
            .sequence = self.next_sequence,
            .stage = stage,
            .source = record.source.displayName(),
            .line = record.source.line,
            .record_hash = record.identityHash(),
            .detail = detail,
        };
        self.count += 1;
        self.next_sequence += 1;
    }

    pub fn slice(self: *const Trail) []const Entry {
        return self.entries[0..self.count];
    }

    pub fn countStage(self: *const Trail, stage: Stage) usize {
        var result: usize = 0;
        for (self.slice()) |entry| { if (entry.stage == stage) result += 1; }
        return result;
    }
};

pub const AuditResult = struct {
    trail: Trail = .{},
    duplicate_pairs: usize = 0,
    correlation_groups: usize = 0,
    policy_matches: usize = 0,
    policy_errors: usize = 0,
    aggregate: aggregation.Report = .{},
};

pub const Options = struct {
    duplicate_options: duplicate.Options = .{},
    correlation_options: correlation.Options = .{},
    policy: ?*const policy_mod.Policy = null,
};

pub fn run(records: []record_mod.Record, options: Options) AuditResult {
    var result = AuditResult{};
    for (records) |*record| {
        result.trail.append(.detected, record, record.source.format.label());
        result.trail.append(.parsed, record, if (record.recovered) "recovered" else "clean");
        result.trail.append(.normalized, record, record.severity.label());
        if (options.policy) |policy| {
            const policy_result = policy_mod.apply(policy, record);
            result.policy_matches += policy_result.matched_rules;
            result.policy_errors += policy_result.findings.errorCount();
            result.trail.append(.validated, record, if (policy_result.findings.errorCount() == 0) "accepted" else "rejected");
        }
    }
    var left: usize = 0;
    while (left < records.len) : (left += 1) {
        var right = left + 1;
        while (right < records.len) : (right += 1) {
            const match = duplicate.compare(&records[left], &records[right], options.duplicate_options);
            if (match.duplicate) {
                result.duplicate_pairs += 1;
                result.trail.append(.deduplicated, &records[right], match.reason);
            }
        }
    }
    const groups = correlation.group(records, options.correlation_options);
    result.correlation_groups = groups.count;
    for (groups.slice()) |group| {
        for (group.slice()) |index| result.trail.append(.correlated, &records[index], "deterministic correlation group");
    }
    result.aggregate = aggregation.summarize(records);
    return result;
}

pub fn writeText(result: *const AuditResult, writer: anytype) !void {
    try writer.print("entries={d} dropped={d} duplicate_pairs={d} correlation_groups={d} policy_matches={d} policy_errors={d}\n", .{
        result.trail.count,
        result.trail.dropped,
        result.duplicate_pairs,
        result.correlation_groups,
        result.policy_matches,
        result.policy_errors,
    });
    for (result.trail.slice()) |entry| {
        try writer.print("{d}\t{s}\t{s}:{d}\t{x}\t{s}\n", .{
            entry.sequence,
            @tagName(entry.stage),
            entry.source,
            entry.line,
            entry.record_hash,
            entry.detail,
        });
    }
}

pub fn writeJson(result: *const AuditResult, writer: anytype) !void {
    try writer.print("{{\"duplicate_pairs\":{d},\"correlation_groups\":{d},\"policy_matches\":{d},\"policy_errors\":{d},\"entries\":[", .{
        result.duplicate_pairs, result.correlation_groups, result.policy_matches, result.policy_errors,
    });
    for (result.trail.slice(), 0..) |entry, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{{\"sequence\":{d},\"stage\":\"{s}\",\"source\":", .{ entry.sequence, @tagName(entry.stage) });
        try writeString(writer, entry.source);
        try writer.print(",\"line\":{d},\"record_hash\":\"{x}\",\"detail\":", .{ entry.line, entry.record_hash });
        try writeString(writer, entry.detail);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn writeString(writer: anytype, input: []const u8) !void {
    try writer.writeByte('"');
    for (input) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}

pub fn verifySequence(trail: *const Trail) bool {
    var expected: u64 = 1;
    for (trail.slice()) |entry| {
        if (entry.sequence != expected) return false;
        expected += 1;
    }
    return true;
}

test "audit trail records deterministic processing stages" {
    var records = [_]record_mod.Record{ record_mod.Record.init(.jsonl), record_mod.Record.init(.jsonl) };
    records[0].message = "ready";
    records[1].message = "ready";
    const result = run(&records, .{ .duplicate_options = .{ .include_timestamp = false } });
    try std.testing.expectEqual(@as(usize, 1), result.duplicate_pairs);
    try std.testing.expect(verifySequence(&result.trail));
}
