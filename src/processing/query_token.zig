const std = @import("std");

pub const Kind = enum {
    identifier,
    string,
    number,
    boolean,
    null_value,
    equal,
    not_equal,
    greater,
    greater_equal,
    less,
    less_equal,
    contains,
    starts_with,
    ends_with,
    has,
    missing,
    and_kw,
    or_kw,
    not_kw,
    left_paren,
    right_paren,
    comma,
    end,
};

pub const Token = struct {
    kind: Kind,
    lexeme: []const u8,
    offset: usize,
};

pub const LexError = error{
    InvalidCharacter,
    UnterminatedString,
    TokenTooLong,
    TooManyTokens,
};

pub const Lexer = struct {
    input: []const u8,
    index: usize = 0,
    max_token_bytes: usize = 4096,

    pub fn init(input: []const u8) Lexer {
        return .{ .input = input };
    }

    pub fn next(self: *Lexer) LexError!Token {
        self.skipSpace();
        const start = self.index;
        if (self.index >= self.input.len) return .{ .kind = .end, .lexeme = "", .offset = self.index };
        const ch = self.input[self.index];
        switch (ch) {
            '(' => return self.single(.left_paren),
            ')' => return self.single(.right_paren),
            ',' => return self.single(.comma),
            '=' => {
                self.index += 1;
                if (self.index < self.input.len and self.input[self.index] == '=') self.index += 1;
                return .{ .kind = .equal, .lexeme = self.input[start..self.index], .offset = start };
            },
            '!' => {
                self.index += 1;
                if (self.index >= self.input.len or self.input[self.index] != '=') return error.InvalidCharacter;
                self.index += 1;
                return .{ .kind = .not_equal, .lexeme = self.input[start..self.index], .offset = start };
            },
            '>' => {
                self.index += 1;
                if (self.index < self.input.len and self.input[self.index] == '=') {
                    self.index += 1;
                    return .{ .kind = .greater_equal, .lexeme = self.input[start..self.index], .offset = start };
                }
                return .{ .kind = .greater, .lexeme = self.input[start..self.index], .offset = start };
            },
            '<' => {
                self.index += 1;
                if (self.index < self.input.len and self.input[self.index] == '=') {
                    self.index += 1;
                    return .{ .kind = .less_equal, .lexeme = self.input[start..self.index], .offset = start };
                }
                return .{ .kind = .less, .lexeme = self.input[start..self.index], .offset = start };
            },
            '"', '\'' => return self.stringToken(ch),
            else => {},
        }
        if (std.ascii.isDigit(ch) or ((ch == '-' or ch == '+') and self.index + 1 < self.input.len and std.ascii.isDigit(self.input[self.index + 1]))) return self.numberToken();
        if (isIdentifierStart(ch)) return self.identifierToken();
        return error.InvalidCharacter;
    }

    fn single(self: *Lexer, kind: Kind) Token {
        const start = self.index;
        self.index += 1;
        return .{ .kind = kind, .lexeme = self.input[start..self.index], .offset = start };
    }

    fn stringToken(self: *Lexer, quote: u8) LexError!Token {
        const token_start = self.index;
        self.index += 1;
        const content_start = self.index;
        var escaped = false;
        while (self.index < self.input.len) : (self.index += 1) {
            if (self.index - content_start > self.max_token_bytes) return error.TokenTooLong;
            const ch = self.input[self.index];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == quote) {
                const content = self.input[content_start..self.index];
                self.index += 1;
                return .{ .kind = .string, .lexeme = content, .offset = token_start };
            }
        }
        return error.UnterminatedString;
    }

    fn numberToken(self: *Lexer) LexError!Token {
        const start = self.index;
        self.index += 1;
        while (self.index < self.input.len) : (self.index += 1) {
            const ch = self.input[self.index];
            if (!(std.ascii.isDigit(ch) or ch == '.' or ch == 'e' or ch == 'E' or ch == '+' or ch == '-')) break;
            if (self.index - start > self.max_token_bytes) return error.TokenTooLong;
        }
        return .{ .kind = .number, .lexeme = self.input[start..self.index], .offset = start };
    }

    fn identifierToken(self: *Lexer) LexError!Token {
        const start = self.index;
        self.index += 1;
        while (self.index < self.input.len and isIdentifierContinue(self.input[self.index])) : (self.index += 1) {
            if (self.index - start > self.max_token_bytes) return error.TokenTooLong;
        }
        const lexeme = self.input[start..self.index];
        return .{ .kind = keywordKind(lexeme), .lexeme = lexeme, .offset = start };
    }

    fn skipSpace(self: *Lexer) void {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) self.index += 1;
    }
};

fn keywordKind(input: []const u8) Kind {
    if (std.ascii.eqlIgnoreCase(input, "and")) return .and_kw;
    if (std.ascii.eqlIgnoreCase(input, "or")) return .or_kw;
    if (std.ascii.eqlIgnoreCase(input, "not")) return .not_kw;
    if (std.ascii.eqlIgnoreCase(input, "contains")) return .contains;
    if (std.ascii.eqlIgnoreCase(input, "starts_with") or std.ascii.eqlIgnoreCase(input, "startswith")) return .starts_with;
    if (std.ascii.eqlIgnoreCase(input, "ends_with") or std.ascii.eqlIgnoreCase(input, "endswith")) return .ends_with;
    if (std.ascii.eqlIgnoreCase(input, "has")) return .has;
    if (std.ascii.eqlIgnoreCase(input, "missing")) return .missing;
    if (std.ascii.eqlIgnoreCase(input, "true") or std.ascii.eqlIgnoreCase(input, "false")) return .boolean;
    if (std.ascii.eqlIgnoreCase(input, "null")) return .null_value;
    return .identifier;
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '@';
}

fn isIdentifierContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '-' or ch == '@';
}

test "query lexer recognizes logical and comparison operators" {
    var lexer = Lexer.init("severity >= warning and service == 'api'");
    try std.testing.expectEqual(Kind.identifier, (try lexer.next()).kind);
    try std.testing.expectEqual(Kind.greater_equal, (try lexer.next()).kind);
    try std.testing.expectEqual(Kind.identifier, (try lexer.next()).kind);
}
