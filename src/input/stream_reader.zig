const std = @import("std");
const diag_mod = @import("../diagnostics/diagnostic.zig");

pub const StreamLimits = struct {
    max_line_bytes: usize = 1024 * 1024,
    max_input_bytes: usize = 64 * 1024 * 1024,
    max_records: usize = 1_000_000,
};

pub const Line = struct {
    bytes: []const u8,
    number: usize,
    byte_offset: usize,
    had_terminator: bool,
};

pub const SliceLineIterator = struct {
    input: []const u8,
    limits: StreamLimits,
    offset: usize = 0,
    line_number: usize = 1,
    records_seen: usize = 0,

    pub fn init(input: []const u8, limits: StreamLimits) error{InputTooLarge}!SliceLineIterator {
        if (input.len > limits.max_input_bytes) return error.InputTooLarge;
        return .{ .input = input, .limits = limits };
    }

    pub fn next(self: *SliceLineIterator) error{LineTooLong,TooManyRecords}!?Line {
        if (self.offset >= self.input.len) return null;
        if (self.records_seen >= self.limits.max_records) return error.TooManyRecords;
        const start = self.offset;
        const relative_end = std.mem.indexOfScalar(u8, self.input[start..], '\n');
        const end = if (relative_end) |value| start + value else self.input.len;
        var content_end = end;
        if (content_end > start and self.input[content_end - 1] == '\r') content_end -= 1;
        if (content_end - start > self.limits.max_line_bytes) return error.LineTooLong;
        const line = Line{
            .bytes = self.input[start..content_end],
            .number = self.line_number,
            .byte_offset = start,
            .had_terminator = relative_end != null,
        };
        self.offset = if (relative_end != null) end + 1 else end;
        self.line_number += 1;
        self.records_seen += 1;
        return line;
    }

    pub fn remainingBytes(self: *const SliceLineIterator) usize {
        return self.input.len - self.offset;
    }
};

pub const BufferedStreamReader = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    limits: StreamLimits,
    total_read: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limits: StreamLimits) BufferedStreamReader {
        return .{ .allocator = allocator, .buffer = std.ArrayList(u8).init(allocator), .limits = limits };
    }

    pub fn deinit(self: *BufferedStreamReader) void {
        self.buffer.deinit();
    }

    pub fn readAll(self: *BufferedStreamReader, reader: anytype) ![]const u8 {
        var chunk: [8192]u8 = undefined;
        while (true) {
            const count = try reader.read(&chunk);
            if (count == 0) break;
            if (self.total_read + count > self.limits.max_input_bytes) return error.InputTooLarge;
            try self.buffer.appendSlice(chunk[0..count]);
            self.total_read += count;
        }
        return self.buffer.items;
    }

    pub fn reset(self: *BufferedStreamReader) void {
        self.buffer.clearRetainingCapacity();
        self.total_read = 0;
    }
};

pub fn validateUtf8OrLocate(input: []const u8) ?usize {
    if (std.unicode.utf8ValidateSlice(input)) return null;
    var index: usize = 0;
    while (index < input.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(input[index]) catch return index;
        if (index + sequence_len > input.len) return index;
        _ = std.unicode.utf8Decode(input[index .. index + sequence_len]) catch return index;
        index += sequence_len;
    }
    return null;
}

pub fn appendStreamDiagnostic(buffer: *diag_mod.DiagnosticBuffer, err: anyerror, line: usize) void {
    const diagnostic: diag_mod.Diagnostic = if (err == error.LineTooLong)
        .{ .severity = .error, .code = .line_too_long, .line = line, .column = 1, .message = "input line exceeds configured limit" }
    else if (err == error.InputTooLarge)
        .{ .severity = .error, .code = .input_too_large, .line = line, .column = 1, .message = "input exceeds configured byte limit" }
    else
        .{ .severity = .error, .code = .invalid_structure, .line = line, .column = 1, .message = "stream reader could not continue" };
    buffer.append(diagnostic);
}

test "stream iterator tracks offsets and final unterminated line" {
    var it = try SliceLineIterator.init("one\r\ntwo", .{});
    const first = (try it.next()).?;
    const second = (try it.next()).?;
    try std.testing.expectEqualStrings("one", first.bytes);
    try std.testing.expect(first.had_terminator);
    try std.testing.expectEqual(@as(usize, 5), second.byte_offset);
    try std.testing.expect(!second.had_terminator);
}
