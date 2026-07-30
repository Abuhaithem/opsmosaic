const std = @import("std");
const record_mod = @import("../model/record.zig");
const parser = @import("../parsing/dispatcher.zig");
const source_mod = @import("../model/source_info.zig");
const stream = @import("../input/stream_reader.zig");
const normalization = @import("../normalization/pipeline.zig");
const csv = @import("../parsing/csv.zig");
const dns_zone = @import("../parsing/dns_zone.zig");

pub const BatchOptions = struct {
    format: source_mod.SourceFormat = .unknown,
    stream_limits: stream.StreamLimits = .{},
    normalization_options: normalization.Options = .{},
    skip_empty: bool = true,
    continue_after_error: bool = true,
};

pub const BatchStats = struct {
    lines_seen: usize = 0,
    parsed: usize = 0,
    failed: usize = 0,
    empty: usize = 0,
    recovered: usize = 0,
    warnings: usize = 0,
};

pub const ParsedBatch = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(record_mod.OwnedRecord),
    stats: BatchStats = .{},

    pub fn init(allocator: std.mem.Allocator) ParsedBatch {
        return .{ .allocator = allocator, .records = std.ArrayList(record_mod.OwnedRecord).init(allocator) };
    }

    pub fn deinit(self: *ParsedBatch) void {
        for (self.records.items) |*record| record.deinit();
        self.records.deinit();
    }
};

pub fn parseInput(allocator: std.mem.Allocator, input: []const u8, path: ?[]const u8, options: BatchOptions) !ParsedBatch {
    var result = ParsedBatch.init(allocator);
    errdefer result.deinit();
    const detection = @import("../input/detector.zig").detect(path, input);
    const format = if (options.format == .unknown) detection.format else options.format;
    if (format == .csv) {
        try parseCsvDocument(&result, input, path, options);
        return result;
    }
    if (format == .dns_zone) {
        try parseDnsDocument(&result, input, path, options);
        return result;
    }
    if (!parser.isLineOriented(format)) {
        const parsed = try parser.parse(input, format, .{ .path = path });
        var record = parsed.record;
        _ = normalization.normalize(&record, options.normalization_options);
        try observeRecord(&result, &record);
        result.stats.lines_seen = countPhysicalLines(input);
        return result;
    }

    var iterator = try stream.SliceLineIterator.init(input, options.stream_limits);
    while (try iterator.next()) |line| {
        result.stats.lines_seen += 1;
        if (options.skip_empty and std.mem.trim(u8, line.bytes, " \t\r").len == 0) {
            result.stats.empty += 1;
            continue;
        }
        const parsed = parser.parse(line.bytes, format, .{ .path = path, .line = line.number, .byte_offset = line.byte_offset }) catch |err| {
            result.stats.failed += 1;
            if (!options.continue_after_error) return err;
            continue;
        };
        var record = parsed.record;
        _ = normalization.normalize(&record, options.normalization_options);
        try observeRecord(&result, &record);
    }
    return result;
}

fn parseCsvDocument(result: *ParsedBatch, input: []const u8, path: ?[]const u8, options: BatchOptions) !void {
    var iterator = try stream.SliceLineIterator.init(input, options.stream_limits);
    var header: ?stream.Line = null;
    while (try iterator.next()) |line| {
        result.stats.lines_seen += 1;
        if (std.mem.trim(u8, line.bytes, " \t\r").len == 0) {
            result.stats.empty += 1;
            continue;
        }
        header = line;
        break;
    }
    const header_line = header orelse return error.EmptyInput;
    const delimiter = csv.estimateDelimiter(header_line.bytes);
    while (try iterator.next()) |line| {
        result.stats.lines_seen += 1;
        if (options.skip_empty and std.mem.trim(u8, line.bytes, " \t\r").len == 0) {
            result.stats.empty += 1;
            continue;
        }
        var record = csv.parseRows(header_line.bytes, line.bytes, .{
            .path = path,
            .line = line.number,
            .byte_offset = line.byte_offset,
        }, .{ .delimiter = delimiter }) catch |err| {
            result.stats.failed += 1;
            if (!options.continue_after_error) return err;
            continue;
        };
        _ = normalization.normalize(&record, options.normalization_options);
        try observeRecord(result, &record);
    }
    if (result.stats.parsed == 0 and result.stats.failed == 0) return error.MissingField;
}

fn parseDnsDocument(result: *ParsedBatch, input: []const u8, path: ?[]const u8, options: BatchOptions) !void {
    var iterator = try stream.SliceLineIterator.init(input, options.stream_limits);
    var state = dns_zone.ZoneState{};
    while (try iterator.next()) |line| {
        result.stats.lines_seen += 1;
        const maybe_record = dns_zone.parseLine(line.bytes, .{
            .path = path,
            .line = line.number,
            .byte_offset = line.byte_offset,
        }, &state) catch |err| {
            result.stats.failed += 1;
            if (!options.continue_after_error) return err;
            continue;
        };
        if (maybe_record) |parsed_record| {
            var record = parsed_record;
            _ = normalization.normalize(&record, options.normalization_options);
            try observeRecord(result, &record);
        } else if (std.mem.trim(u8, line.bytes, " \t\r").len == 0) {
            result.stats.empty += 1;
        }
    }
}

fn countPhysicalLines(input: []const u8) usize {
    if (input.len == 0) return 0;
    var count: usize = 1;
    for (input) |byte| { if (byte == '\n') count += 1; }
    if (input[input.len - 1] == '\n') count -= 1;
    return count;
}

fn observeRecord(result: *ParsedBatch, record: *const record_mod.Record) !void {
    try appendOwned(result, record);
    result.stats.parsed += 1;
    result.stats.warnings += record.warnings.count;
    if (record.recovered) result.stats.recovered += 1;
}

fn appendOwned(result: *ParsedBatch, record: *const record_mod.Record) !void {
    var owned = try record_mod.OwnedRecord.cloneFrom(result.allocator, record);
    errdefer owned.deinit();
    try result.records.append(owned);
}

pub fn borrowedView(batch: *const ParsedBatch, allocator: std.mem.Allocator) ![]record_mod.Record {
    const result = try allocator.alloc(record_mod.Record, batch.records.items.len);
    for (batch.records.items, 0..) |owned, index| result[index] = owned.record;
    return result;
}

test "batch parser recovers after malformed JSON line" {
    var batch_result = try parseInput(std.testing.allocator, "{\"message\":\"ok\"}\nnot-json\n{\"message\":\"again\"}\n", null, .{ .format = .jsonl });
    defer batch_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), batch_result.stats.parsed);
    try std.testing.expectEqual(@as(usize, 1), batch_result.stats.failed);
}

test "batch parser emits every CSV data row" {
    var batch_result = try parseInput(std.testing.allocator, "host,service,status\nedge-1,api,200\nedge-2,api,503\n", "inventory.csv", .{ .format = .csv });
    defer batch_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), batch_result.stats.parsed);
    try std.testing.expectEqualStrings("edge-2", batch_result.records.items[1].record.host.?);
}

test "batch parser carries DNS directives across records" {
    var batch_result = try parseInput(std.testing.allocator, "$ORIGIN example.test.\n$TTL 1h\napi IN A 192.0.2.10\nmail 300 IN A 192.0.2.11\n", "example.zone", .{ .format = .dns_zone });
    defer batch_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), batch_result.stats.parsed);
    try std.testing.expectEqual(@as(i64, 3600), batch_result.records.items[0].record.getField("ttl").?.integer);
}
