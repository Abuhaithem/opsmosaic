const std = @import("std");

pub const Severity = enum {
    note,
    warning,
    error,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .note => "note",
            .warning => "warning",
            .error => "error",
        };
    }
};

pub const Code = enum {
    unsupported_format,
    input_too_large,
    line_too_long,
    invalid_utf8,
    malformed_timestamp,
    malformed_priority,
    missing_required_field,
    duplicate_field,
    invalid_escape,
    invalid_number,
    invalid_boolean,
    invalid_structure,
    unsupported_manifest_feature,
    query_too_deep,
    query_too_complex,
    schema_mismatch,
    output_failure,
    recoverable_record,

    pub fn label(self: Code) []const u8 {
        return switch (self) {
            .unsupported_format => "SL1001",
            .input_too_large => "SL1002",
            .line_too_long => "SL1003",
            .invalid_utf8 => "SL1004",
            .malformed_timestamp => "SL1101",
            .malformed_priority => "SL1102",
            .missing_required_field => "SL1201",
            .duplicate_field => "SL1202",
            .invalid_escape => "SL1301",
            .invalid_number => "SL1302",
            .invalid_boolean => "SL1303",
            .invalid_structure => "SL1304",
            .unsupported_manifest_feature => "SL1401",
            .query_too_deep => "SL1501",
            .query_too_complex => "SL1502",
            .schema_mismatch => "SL1601",
            .output_failure => "SL1701",
            .recoverable_record => "SL1801",
        };
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    line: usize,
    column: usize,
    field: ?[]const u8 = null,
    message: []const u8,
    suggestion: ?[]const u8 = null,

    pub fn isFatal(self: Diagnostic) bool {
        return self.severity == .error;
    }

    pub fn writeText(self: Diagnostic, writer: anytype) !void {
        try writer.print("{s} {s} at {d}:{d}: {s}", .{
            self.severity.label(), self.code.label(), self.line, self.column, self.message,
        });
        if (self.field) |field| try writer.print(" [field={s}]", .{field});
        if (self.suggestion) |suggestion| try writer.print("; {s}", .{suggestion});
    }
};

pub const DiagnosticBuffer = struct {
    entries: [64]Diagnostic = undefined,
    count: usize = 0,
    dropped: usize = 0,

    pub fn clear(self: *DiagnosticBuffer) void {
        self.count = 0;
        self.dropped = 0;
    }

    pub fn append(self: *DiagnosticBuffer, diagnostic: Diagnostic) void {
        if (self.count == self.entries.len) {
            self.dropped += 1;
            return;
        }
        self.entries[self.count] = diagnostic;
        self.count += 1;
    }

    pub fn slice(self: *const DiagnosticBuffer) []const Diagnostic {
        return self.entries[0..self.count];
    }

    pub fn errorCount(self: *const DiagnosticBuffer) usize {
        var total: usize = 0;
        for (self.slice()) |entry| if (entry.severity == .error) total += 1;
        return total;
    }

    pub fn warningCount(self: *const DiagnosticBuffer) usize {
        var total: usize = 0;
        for (self.slice()) |entry| if (entry.severity == .warning) total += 1;
        return total;
    }

    pub fn hasCode(self: *const DiagnosticBuffer, code: Code) bool {
        for (self.slice()) |entry| if (entry.code == code) return true;
        return false;
    }
};

test "diagnostic buffer remains bounded" {
    var buffer = DiagnosticBuffer{};
    var index: usize = 0;
    while (index < 70) : (index += 1) {
        buffer.append(.{ .severity = .warning, .code = .recoverable_record, .line = 1, .column = 1, .message = "recovered" });
    }
    try std.testing.expectEqual(@as(usize, 64), buffer.count);
    try std.testing.expectEqual(@as(usize, 6), buffer.dropped);
}
