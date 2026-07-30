const std = @import("std");
const finding_mod = @import("finding.zig");

pub const Summary = struct {
    records: usize = 0,
    accepted: usize = 0,
    rejected: usize = 0,
    warnings: usize = 0,
    errors: usize = 0,
    dropped_findings: usize = 0,

    pub fn observe(self: *Summary, findings: *const finding_mod.FindingBuffer) void {
        self.records += 1;
        const errors = findings.errorCount();
        const warnings = findings.warningCount();
        self.errors += errors;
        self.warnings += warnings;
        self.dropped_findings += findings.dropped;
        if (errors == 0) self.accepted += 1 else self.rejected += 1;
    }

    pub fn acceptanceRate(self: Summary) f64 {
        if (self.records == 0) return 0;
        return @as(f64, @floatFromInt(self.accepted)) / @as(f64, @floatFromInt(self.records));
    }

    pub fn writeText(self: Summary, writer: anytype) !void {
        try writer.print("records={d} accepted={d} rejected={d} warnings={d} errors={d}", .{
            self.records, self.accepted, self.rejected, self.warnings, self.errors,
        });
        if (self.dropped_findings != 0) try writer.print(" dropped_findings={d}", .{self.dropped_findings});
    }

    pub fn writeJson(self: Summary, writer: anytype) !void {
        try writer.print("{{\"records\":{d},\"accepted\":{d},\"rejected\":{d},\"warnings\":{d},\"errors\":{d},\"acceptance_rate\":{d}}}", .{
            self.records, self.accepted, self.rejected, self.warnings, self.errors, self.acceptanceRate(),
        });
    }
};

pub fn writeFindingsText(findings: *const finding_mod.FindingBuffer, writer: anytype) !void {
    for (findings.slice()) |finding| {
        try finding.writeText(writer);
        try writer.writeByte('\n');
    }
    if (findings.dropped != 0) try writer.print("warning findings.truncated: {d} additional findings omitted\n", .{findings.dropped});
}

pub fn writeFindingsJson(findings: *const finding_mod.FindingBuffer, writer: anytype) !void {
    try writer.writeByte('[');
    for (findings.slice(), 0..) |finding, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"level\":");
        try writeString(writer, finding_mod.levelLabel(finding.level));
        try writer.writeAll(",\"rule\":");
        try writeString(writer, finding.rule);
        if (finding.field) |field| {
            try writer.writeAll(",\"field\":");
            try writeString(writer, field);
        }
        try writer.print(",\"line\":{d},\"message\":", .{finding.line});
        try writeString(writer, finding.message);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
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

test "validation summary tracks acceptance" {
    var findings = finding_mod.FindingBuffer{};
    var summary = Summary{};
    summary.observe(&findings);
    findings.append(.{ .level = .@"error", .rule = "x", .message = "x" });
    summary.observe(&findings);
    try std.testing.expectEqual(@as(usize, 1), summary.accepted);
    try std.testing.expectEqual(@as(usize, 1), summary.rejected);
}
