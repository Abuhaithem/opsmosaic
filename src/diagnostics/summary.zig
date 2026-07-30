const std = @import("std");
const record_mod = @import("../model/record.zig");
const diag_mod = @import("diagnostic.zig");

pub const Summary = struct {
    records: usize = 0,
    recovered_records: usize = 0,
    notes: usize = 0,
    warnings: usize = 0,
    errors: usize = 0,
    dropped: usize = 0,
    by_code: [18]usize = [_]usize{0} ** 18,

    pub fn observeRecord(self: *Summary, record: *const record_mod.Record) void {
        self.records += 1;
        if (record.recovered) self.recovered_records += 1;
        self.dropped += record.warnings.dropped;
        for (record.warnings.slice()) |diagnostic| self.observeDiagnostic(diagnostic);
    }

    pub fn observeDiagnostic(self: *Summary, diagnostic: diag_mod.Diagnostic) void {
        switch (diagnostic.severity) {
            .note => self.notes += 1,
            .warning => self.warnings += 1,
            .@"error" => self.errors += 1,
        }
        const index = codeIndex(diagnostic.code);
        if (index < self.by_code.len) self.by_code[index] += 1;
    }

    pub fn cleanRate(self: Summary) f64 {
        if (self.records == 0) return 0;
        return @as(f64, @floatFromInt(self.records - self.recovered_records)) / @as(f64, @floatFromInt(self.records));
    }

    pub fn writeText(self: Summary, writer: anytype) !void {
        try writer.print("records={d} recovered={d} notes={d} warnings={d} errors={d} clean_rate={d:.4}\n", .{
            self.records, self.recovered_records, self.notes, self.warnings, self.errors, self.cleanRate(),
        });
        for (self.by_code, 0..) |count, index| { if (count != 0) try writer.print("  {s}: {d}\n", .{ codeAt(index).label(), count }); }
        if (self.dropped != 0) try writer.print("  dropped: {d}\n", .{self.dropped});
    }
};

fn codeIndex(code: diag_mod.Code) usize {
    return @intFromEnum(code);
}

fn codeAt(index: usize) diag_mod.Code {
    return @enumFromInt(index);
}

test "diagnostic summary tracks recovered records" {
    var record = record_mod.Record.init(.jsonl);
    record.recovered = true;
    record.warnings.append(.{ .severity = .warning, .code = .invalid_number, .line = 1, .column = 1, .message = "bad" });
    var summary = Summary{};
    summary.observeRecord(&record);
    try std.testing.expectEqual(@as(usize, 1), summary.warnings);
}
