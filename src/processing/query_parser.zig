const std = @import("std");
const token_mod = @import("query_token.zig");
const value_mod = @import("../model/value.zig");

pub const Operator = enum {
    equal,
    not_equal,
    greater,
    greater_equal,
    less,
    less_equal,
    contains,
    starts_with,
    ends_with,
};

pub const Predicate = struct {
    field: []const u8,
    operator: Operator,
    value: value_mod.Value,
};

pub const Node = union(enum) {
    predicate: Predicate,
    has_tag: []const u8,
    missing: []const u8,
    logical_and: struct { left: u16, right: u16 },
    logical_or: struct { left: u16, right: u16 },
    logical_not: u16,
};

pub const Program = struct {
    nodes: [256]Node = undefined,
    count: usize = 0,
    root: ?u16 = null,
    max_depth_seen: usize = 0,

    pub fn append(self: *Program, node: Node) ParseError!u16 {
        if (self.count >= self.nodes.len) return error.TooComplex;
        const index: u16 = @intCast(self.count);
        self.nodes[self.count] = node;
        self.count += 1;
        return index;
    }

    pub fn node(self: *const Program, index: u16) Node {
        return self.nodes[index];
    }
};

pub const Limits = struct {
    max_nodes: usize = 256,
    max_depth: usize = 32,
    max_token_bytes: usize = 4096,
};

pub const ParseError = error{
    InvalidCharacter,
    UnterminatedString,
    TokenTooLong,
    UnexpectedToken,
    MissingOperand,
    InvalidNumber,
    TooDeep,
    TooComplex,
};

pub fn parse(input: []const u8, limits: Limits) ParseError!Program {
    var parser = Parser.init(input, limits);
    var program = Program{};
    const root = try parser.parseOr(&program, 0);
    if (parser.current.kind != .end) return error.UnexpectedToken;
    program.root = root;
    return program;
}

const Parser = struct {
    lexer: token_mod.Lexer,
    current: token_mod.Token,
    limits: Limits,

    fn init(input: []const u8, limits: Limits) Parser {
        var lexer = token_mod.Lexer.init(input);
        lexer.max_token_bytes = limits.max_token_bytes;
        const current = lexer.next() catch .{ .kind = .end, .lexeme = "", .offset = 0 };
        return .{ .lexer = lexer, .current = current, .limits = limits };
    }

    fn advance(self: *Parser) ParseError!void {
        self.current = self.lexer.next() catch |err| return switch (err) {
            error.InvalidCharacter => error.InvalidCharacter,
            error.UnterminatedString => error.UnterminatedString,
            error.TokenTooLong => error.TokenTooLong,
            error.TooManyTokens => error.TooComplex,
        };
    }

    fn parseOr(self: *Parser, program: *Program, depth: usize) ParseError!u16 {
        try self.checkDepth(program, depth);
        var left = try self.parseAnd(program, depth + 1);
        while (self.current.kind == .or_kw) {
            try self.advance();
            const right = try self.parseAnd(program, depth + 1);
            left = try self.append(program, .{ .logical_or = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parseAnd(self: *Parser, program: *Program, depth: usize) ParseError!u16 {
        try self.checkDepth(program, depth);
        var left = try self.parseUnary(program, depth + 1);
        while (self.current.kind == .and_kw) {
            try self.advance();
            const right = try self.parseUnary(program, depth + 1);
            left = try self.append(program, .{ .logical_and = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parseUnary(self: *Parser, program: *Program, depth: usize) ParseError!u16 {
        try self.checkDepth(program, depth);
        if (self.current.kind == .not_kw) {
            try self.advance();
            return self.append(program, .{ .logical_not = try self.parseUnary(program, depth + 1) });
        }
        if (self.current.kind == .left_paren) {
            try self.advance();
            const inner = try self.parseOr(program, depth + 1);
            if (self.current.kind != .right_paren) return error.UnexpectedToken;
            try self.advance();
            return inner;
        }
        if (self.current.kind == .has) return self.parseHas(program);
        if (self.current.kind == .missing) return self.parseMissing(program);
        return self.parsePredicate(program);
    }

    fn parseHas(self: *Parser, program: *Program) ParseError!u16 {
        try self.advance();
        const parenthesized = self.current.kind == .left_paren;
        if (parenthesized) try self.advance();
        if (self.current.kind != .identifier and self.current.kind != .string) return error.MissingOperand;
        const tag = self.current.lexeme;
        try self.advance();
        if (parenthesized) {
            if (self.current.kind != .right_paren) return error.UnexpectedToken;
            try self.advance();
        }
        return self.append(program, .{ .has_tag = tag });
    }

    fn parseMissing(self: *Parser, program: *Program) ParseError!u16 {
        try self.advance();
        const parenthesized = self.current.kind == .left_paren;
        if (parenthesized) try self.advance();
        if (self.current.kind != .identifier and self.current.kind != .string) return error.MissingOperand;
        const field = self.current.lexeme;
        try self.advance();
        if (parenthesized) {
            if (self.current.kind != .right_paren) return error.UnexpectedToken;
            try self.advance();
        }
        return self.append(program, .{ .missing = field });
    }

    fn parsePredicate(self: *Parser, program: *Program) ParseError!u16 {
        if (self.current.kind != .identifier) return error.MissingOperand;
        const field = self.current.lexeme;
        try self.advance();
        const operator = operatorFromKind(self.current.kind) orelse return error.UnexpectedToken;
        try self.advance();
        const value = try self.parseLiteral();
        return self.append(program, .{ .predicate = .{ .field = field, .operator = operator, .value = value } });
    }

    fn parseLiteral(self: *Parser) ParseError!value_mod.Value {
        const token = self.current;
        const value: value_mod.Value = switch (token.kind) {
            .string, .identifier => .{ .text = token.lexeme },
            .boolean => .{ .boolean = std.ascii.eqlIgnoreCase(token.lexeme, "true") },
            .null_value => .{ .null_value = {} },
            .number => parseNumber(token.lexeme) catch return error.InvalidNumber,
            else => return error.MissingOperand,
        };
        try self.advance();
        return value;
    }

    fn append(self: *Parser, program: *Program, node: Node) ParseError!u16 {
        if (program.count >= self.limits.max_nodes) return error.TooComplex;
        return program.append(node);
    }

    fn checkDepth(self: *Parser, program: *Program, depth: usize) ParseError!void {
        if (depth > self.limits.max_depth) return error.TooDeep;
        program.max_depth_seen = @max(program.max_depth_seen, depth);
    }
};

fn operatorFromKind(kind: token_mod.Kind) ?Operator {
    return switch (kind) {
        .equal => .equal,
        .not_equal => .not_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .less => .less,
        .less_equal => .less_equal,
        .contains => .contains,
        .starts_with => .starts_with,
        .ends_with => .ends_with,
        else => null,
    };
}

fn parseNumber(input: []const u8) !value_mod.Value {
    if (std.mem.indexOfAny(u8, input, ".eE") != null) return .{ .decimal = try std.fmt.parseFloat(f64, input) };
    return .{ .integer = try std.fmt.parseInt(i64, input, 10) };
}

test "query parser applies and before or" {
    const program = try parse("severity == error or service == api and status >= 500", .{});
    try std.testing.expect(program.count >= 5);
    try std.testing.expect(program.root != null);
}
