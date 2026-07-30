const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");
const common = @import("common.zig");

pub const CsvDialect = struct {
    delimiter: u8 = ',',
    quote: u8 = '"',
    allow_backslash_escape: bool = false,
    trim_unquoted: bool = true,
    max_columns: usize = 64,
};

pub const Cell = struct {
    bytes: []const u8,
    quoted: bool,
};

pub const Row = struct {
    cells: [64]Cell = undefined,
    count: usize = 0,

    pub fn slice(self: *const Row) []const Cell {
        return self.cells[0..self.count];
    }
};

pub fn parse(input_raw: []const u8, context: common.ParseContext) common.ParseError!record_mod.Record {
    var lines = std.mem.splitScalar(u8, input_raw, '\n');
    const header_line = common.trimLine(lines.next() orelse return error.EmptyInput);
    const data_line = common.trimLine(lines.next() orelse return error.MissingField);
    return parseRows(header_line, data_line, context, .{});
}

pub fn parseRows(header_line: []const u8, data_line: []const u8, context: common.ParseContext, dialect: CsvDialect) common.ParseError!record_mod.Record {
    const header = try tokenizeRow(header_line, dialect);
    const data = try tokenizeRow(data_line, dialect);
    if (header.count == 0) return error.MissingField;
    var record = record_mod.Record.init(.csv);
    common.applyContext(&record, context);
    if (header.count != data.count) {
        common.appendWarning(&record, context, .invalid_structure, 1, null, "CSV row has a different column count than the header");
    }
    const count = @min(header.count, data.count);
    var index: usize = 0;
    while (index < count and index < context.max_fields) : (index += 1) {
        const key = std.mem.trim(u8, header.cells[index].bytes, " \t\r");
        const raw = if (data.cells[index].quoted or !dialect.trim_unquoted) data.cells[index].bytes else std.mem.trim(u8, data.cells[index].bytes, " \t\r");
        if (key.len == 0) {
            common.appendWarning(&record, context, .missing_required_field, index + 1, null, "CSV header contains an empty column name");
            continue;
        }
        try applyColumn(&record, key, value_mod.parseScalar(raw), context);
    }
    return record;
}

pub fn tokenizeRow(line: []const u8, dialect: CsvDialect) common.ParseError!Row {
    var row = Row{};
    var index: usize = 0;
    while (true) {
        if (row.count >= dialect.max_columns or row.count >= row.cells.len) return error.TooManyFields;
        const parsed = try parseCell(line, &index, dialect);
        row.cells[row.count] = parsed;
        row.count += 1;
        if (index >= line.len) break;
        if (line[index] != dialect.delimiter) return error.InvalidSyntax;
        index += 1;
        if (index == line.len) {
            if (row.count >= row.cells.len) return error.TooManyFields;
            row.cells[row.count] = .{ .bytes = "", .quoted = false };
            row.count += 1;
            break;
        }
    }
    return row;
}

fn parseCell(line: []const u8, index: *usize, dialect: CsvDialect) common.ParseError!Cell {
    if (index.* >= line.len) return .{ .bytes = "", .quoted = false };
    if (line[index.*] == dialect.quote) {
        index.* += 1;
        const start = index.*;
        while (index.* < line.len) {
            const ch = line[index.*];
            if (ch == dialect.quote) {
                if (index.* + 1 < line.len and line[index.* + 1] == dialect.quote) {
                    index.* += 2;
                    continue;
                }
                const result = line[start..index.*];
                index.* += 1;
                while (index.* < line.len and (line[index.*] == ' ' or line[index.*] == '\t')) index.* += 1;
                if (index.* < line.len and line[index.*] != dialect.delimiter) return error.InvalidSyntax;
                return .{ .bytes = result, .quoted = true };
            }
            if (ch == '\\' and dialect.allow_backslash_escape and index.* + 1 < line.len) index.* += 2 else index.* += 1;
        }
        return error.InvalidSyntax;
    }
    const start = index.*;
    while (index.* < line.len and line[index.*] != dialect.delimiter) index.* += 1;
    return .{ .bytes = line[start..index.*], .quoted = false };
}

fn applyColumn(record: *record_mod.Record, key: []const u8, value: record_mod.Value, context: common.ParseContext) common.ParseError!void {
    if (std.ascii.eqlIgnoreCase(key, "timestamp") or std.ascii.eqlIgnoreCase(key, "time")) {
        if (value.asText()) |v| record.timestamp_text = v else try common.addFieldRecovering(record, key, value, context);
    } else if (std.ascii.eqlIgnoreCase(key, "host") or std.ascii.eqlIgnoreCase(key, "hostname")) {
        if (value.asText()) |v| record.host = v else try common.addFieldRecovering(record, key, value, context);
    } else if (std.ascii.eqlIgnoreCase(key, "service") or std.ascii.eqlIgnoreCase(key, "component")) {
        if (value.asText()) |v| record.service = v else try common.addFieldRecovering(record, key, value, context);
    } else if (std.ascii.eqlIgnoreCase(key, "message") or std.ascii.eqlIgnoreCase(key, "description")) {
        if (value.asText()) |v| record.message = v else try common.addFieldRecovering(record, key, value, context);
    } else if (std.ascii.eqlIgnoreCase(key, "status") or std.ascii.eqlIgnoreCase(key, "status_code")) {
        if (value.asInteger()) |v| {
            if (v >= 0) record.network.status = @intCast(v) else try common.addFieldRecovering(record, key, value, context);
        } else try common.addFieldRecovering(record, key, value, context);
    } else {
        try common.addFieldRecovering(record, key, value, context);
    }
}

pub fn estimateDelimiter(line: []const u8) u8 {
    const candidates = [_]u8{ ',', '\t', ';', '|' };
    var best: u8 = ',';
    var best_count: usize = 0;
    for (candidates) |candidate| {
        var count: usize = 0;
        var quoted = false;
        for (line) |ch| {
            if (ch == '"') quoted = !quoted else if (!quoted and ch == candidate) count += 1;
        }
        if (count > best_count) {
            best = candidate;
            best_count = count;
        }
    }
    return best;
}

pub fn headerLooksOperational(row: *const Row) bool {
    const known = [_][]const u8{ "host", "service", "timestamp", "status", "message", "address", "region", "asset_id" };
    var matches: usize = 0;
    for (row.slice()) |cell| {
        const value = std.mem.trim(u8, cell.bytes, " \t\r");
        for (known) |candidate| if (std.ascii.eqlIgnoreCase(value, candidate)) {
            matches += 1;
            break;
        };
    }
    return matches >= 2;
}

test "CSV tokenizer preserves quoted commas" {
    const row = try tokenizeRow("edge-1,\"api, public\",503", .{});
    try std.testing.expectEqual(@as(usize, 3), row.count);
    try std.testing.expectEqualStrings("api, public", row.cells[1].bytes);
}
