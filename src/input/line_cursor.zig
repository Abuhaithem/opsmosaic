const std = @import("std");

pub const CursorError = error{
    UnexpectedEnd,
    InvalidEscape,
    TokenTooLong,
    InvalidUtf8,
};

pub const LineCursor = struct {
    input: []const u8,
    index: usize = 0,

    pub fn init(input: []const u8) LineCursor {
        return .{ .input = input };
    }

    pub fn remaining(self: *const LineCursor) []const u8 {
        return self.input[self.index..];
    }

    pub fn atEnd(self: *const LineCursor) bool {
        return self.index >= self.input.len;
    }

    pub fn column(self: *const LineCursor) usize {
        return self.index + 1;
    }

    pub fn peek(self: *const LineCursor) ?u8 {
        if (self.atEnd()) return null;
        return self.input[self.index];
    }

    pub fn advance(self: *LineCursor) CursorError!u8 {
        if (self.atEnd()) return error.UnexpectedEnd;
        const ch = self.input[self.index];
        self.index += 1;
        return ch;
    }

    pub fn skipAsciiWhitespace(self: *LineCursor) void {
        while (self.peek()) |ch| {
            if (ch != ' ' and ch != '\t' and ch != '\r') break;
            self.index += 1;
        }
    }

    pub fn consume(self: *LineCursor, expected: u8) bool {
        if (self.peek() == expected) {
            self.index += 1;
            return true;
        }
        return false;
    }

    pub fn consumeText(self: *LineCursor, expected: []const u8) bool {
        if (!std.mem.startsWith(u8, self.remaining(), expected)) return false;
        self.index += expected.len;
        return true;
    }

    pub fn takeUntil(self: *LineCursor, delimiter: u8) []const u8 {
        const start = self.index;
        while (self.peek()) |ch| {
            if (ch == delimiter) break;
            self.index += 1;
        }
        return self.input[start..self.index];
    }

    pub fn takeWhile(self: *LineCursor, predicate: *const fn (u8) bool) []const u8 {
        const start = self.index;
        while (self.peek()) |ch| {
            if (!predicate(ch)) break;
            self.index += 1;
        }
        return self.input[start..self.index];
    }

    pub fn takeToken(self: *LineCursor) []const u8 {
        self.skipAsciiWhitespace();
        const start = self.index;
        while (self.peek()) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r') break;
            self.index += 1;
        }
        return self.input[start..self.index];
    }

    pub fn takeQuoted(self: *LineCursor, quote: u8, max_len: usize) CursorError![]const u8 {
        if (!self.consume(quote)) return error.UnexpectedEnd;
        const start = self.index;
        var escaped = false;
        while (self.peek()) |ch| {
            if (self.index - start > max_len) return error.TokenTooLong;
            self.index += 1;
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == quote) return self.input[start .. self.index - 1];
        }
        return error.UnexpectedEnd;
    }

    pub fn takeBracketed(self: *LineCursor, open: u8, close: u8, max_len: usize) CursorError![]const u8 {
        if (!self.consume(open)) return error.UnexpectedEnd;
        const start = self.index;
        var depth: usize = 1;
        var quoted = false;
        var escaped = false;
        while (self.peek()) |ch| {
            if (self.index - start > max_len) return error.TokenTooLong;
            self.index += 1;
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') {
                quoted = !quoted;
                continue;
            }
            if (quoted) continue;
            if (ch == open) depth += 1;
            if (ch == close) {
                depth -= 1;
                if (depth == 0) return self.input[start .. self.index - 1];
            }
        }
        return error.UnexpectedEnd;
    }

    pub fn positionOf(self: *const LineCursor, needle: []const u8) ?usize {
        const relative = std.mem.indexOf(u8, self.remaining(), needle) orelse return null;
        return self.index + relative;
    }

    pub fn rewind(self: *LineCursor, position: usize) void {
        self.index = @min(position, self.input.len);
    }
};

pub fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == '/';
}

pub fn isDecimalChar(ch: u8) bool {
    return std.ascii.isDigit(ch) or ch == '-' or ch == '+' or ch == '.';
}

test "line cursor handles escaped quoted text" {
    var cursor = LineCursor.init("\"edge \\\"one\\\"\" tail");
    try std.testing.expectEqualStrings("edge \\\"one\\\"", try cursor.takeQuoted('"', 128));
    cursor.skipAsciiWhitespace();
    try std.testing.expectEqualStrings("tail", cursor.takeToken());
}
