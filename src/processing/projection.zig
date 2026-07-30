const std = @import("std");
const record_mod = @import("../model/record.zig");
const eval = @import("query_eval.zig");

pub const Column = struct {
    source: []const u8,
    heading: []const u8,
    missing_text: []const u8 = "",
};

pub const Projection = struct {
    columns: [64]Column = undefined,
    count: usize = 0,

    pub fn append(self: *Projection, column: Column) error{TooManyColumns}!void {
        if (self.count >= self.columns.len) return error.TooManyColumns;
        if (column.source.len == 0 or column.heading.len == 0) return;
        self.columns[self.count] = column;
        self.count += 1;
    }

    pub fn slice(self: *const Projection) []const Column {
        return self.columns[0..self.count];
    }

    pub fn findHeading(self: *const Projection, heading: []const u8) ?usize {
        for (self.slice(), 0..) |column, index| {
            if (std.ascii.eqlIgnoreCase(column.heading, heading)) return index;
        }
        return null;
    }
};

pub fn parse(specification: []const u8) !Projection {
    var projection = Projection{};
    var iterator = std.mem.splitScalar(u8, specification, ',');
    while (iterator.next()) |item_raw| {
        const item = std.mem.trim(u8, item_raw, " \t\r\n");
        if (item.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, item, '=');
        if (separator) |at| {
            const heading = std.mem.trim(u8, item[0..at], " \t");
            const source = std.mem.trim(u8, item[at + 1 ..], " \t");
            if (heading.len == 0 or source.len == 0) return error.InvalidProjection;
            try projection.append(.{ .source = source, .heading = heading });
        } else {
            try projection.append(.{ .source = item, .heading = item });
        }
    }
    if (projection.count == 0) return error.EmptyProjection;
    return projection;
}

pub fn defaultOperational() Projection {
    var result = Projection{};
    result.append(.{ .source = "timestamp", .heading = "timestamp" }) catch unreachable;
    result.append(.{ .source = "severity", .heading = "severity" }) catch unreachable;
    result.append(.{ .source = "host", .heading = "host" }) catch unreachable;
    result.append(.{ .source = "service", .heading = "service" }) catch unreachable;
    result.append(.{ .source = "event_id", .heading = "event_id" }) catch unreachable;
    result.append(.{ .source = "message", .heading = "message" }) catch unreachable;
    return result;
}

pub const Row = struct {
    values: [64]?record_mod.Value = [_]?record_mod.Value{null} ** 64,
    count: usize = 0,

    pub fn get(self: *const Row, index: usize) ?record_mod.Value {
        if (index >= self.count) return null;
        return self.values[index];
    }
};

pub fn apply(record: *const record_mod.Record, projection: *const Projection) Row {
    var row = Row{ .count = projection.count };
    for (projection.slice(), 0..) |column, index| {
        row.values[index] = eval.fieldValue(record, column.source);
    }
    return row;
}

pub fn writeTextRow(record: *const record_mod.Record, projection: *const Projection, writer: anytype) !void {
    const row = apply(record, projection);
    for (projection.slice(), 0..) |column, index| {
        if (index != 0) try writer.writeAll(" | ");
        try writer.writeAll(column.heading);
        try writer.writeByte('=');
        if (row.get(index)) |value| {
            switch (value) {
                .text => |text| try writer.writeAll(text),
                .integer => |number| try writer.print("{d}", .{number}),
                .decimal => |number| try writer.print("{d}", .{number}),
                .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
                .null_value => try writer.writeAll("null"),
            }
        } else try writer.writeAll(column.missing_text);
    }
    try writer.writeByte('\n');
}

pub fn validate(projection: *const Projection) bool {
    if (projection.count == 0 or projection.count > projection.columns.len) return false;
    for (projection.slice(), 0..) |column, index| {
        if (column.source.len == 0 or column.heading.len == 0) return false;
        for (projection.slice()[0..index]) |prior| {
            if (std.ascii.eqlIgnoreCase(prior.heading, column.heading)) return false;
        }
    }
    return true;
}

test "projection aliases fields without changing records" {
    var record = record_mod.Record.init(.jsonl);
    record.service = "checkout";
    const projection = try parse("application=service,message");
    const row = apply(&record, &projection);
    try std.testing.expectEqualStrings("checkout", row.get(0).?.text);
    try std.testing.expect(validate(&projection));
}
