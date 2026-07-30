const std = @import("std");

pub const Level = enum { information, warning, @"error" };

pub const Finding = struct {
    level: Level,
    rule: []const u8,
    field: ?[]const u8 = null,
    line: usize = 0,
    message: []const u8,
    expected: ?[]const u8 = null,
    actual: ?[]const u8 = null,

    pub fn blocksAcceptance(self: Finding) bool {
        return self.level == .@"error";
    }

    pub fn writeText(self: Finding, writer: anytype) !void {
        try writer.print("{s} {s}", .{ levelLabel(self.level), self.rule });
        if (self.line != 0) try writer.print(" line {d}", .{self.line});
        if (self.field) |field| try writer.print(" field {s}", .{field});
        try writer.print(": {s}", .{self.message});
        if (self.expected) |expected| try writer.print("; expected {s}", .{expected});
        if (self.actual) |actual| try writer.print("; actual {s}", .{actual});
    }
};

pub fn levelLabel(level: Level) []const u8 {
    return switch (level) {
        .information => "info",
        .warning => "warning",
        .@"error" => "error",
    };
}

pub const FindingBuffer = struct {
    entries: [128]Finding = undefined,
    count: usize = 0,
    dropped: usize = 0,

    pub fn append(self: *FindingBuffer, finding: Finding) void {
        if (self.count >= self.entries.len) {
            self.dropped += 1;
            return;
        }
        self.entries[self.count] = finding;
        self.count += 1;
    }

    pub fn slice(self: *const FindingBuffer) []const Finding {
        return self.entries[0..self.count];
    }

    pub fn errorCount(self: *const FindingBuffer) usize {
        var count: usize = 0;
        for (self.slice()) |finding| { if (finding.level == .@"error") count += 1; }
        return count;
    }

    pub fn warningCount(self: *const FindingBuffer) usize {
        var count: usize = 0;
        for (self.slice()) |finding| { if (finding.level == .warning) count += 1; }
        return count;
    }

    pub fn hasRule(self: *const FindingBuffer, rule: []const u8) bool {
        for (self.slice()) |finding| { if (std.mem.eql(u8, finding.rule, rule)) return true; }
        return false;
    }
};

test "finding buffer reports blocking errors" {
    var buffer = FindingBuffer{};
    buffer.append(.{ .level = .@"error", .rule = "required", .message = "missing" });
    try std.testing.expectEqual(@as(usize, 1), buffer.errorCount());
}
