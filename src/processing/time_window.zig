const std = @import("std");
const record_mod = @import("../model/record.zig");

pub const Boundary = enum { inclusive, exclusive };

pub const Range = struct {
    start_ns: ?i128 = null,
    end_ns: ?i128 = null,
    start_boundary: Boundary = .inclusive,
    end_boundary: Boundary = .exclusive,

    pub fn contains(self: Range, timestamp: ?i128) bool {
        const value = timestamp orelse return false;
        if (self.start_ns) |start| {
            if (self.start_boundary == .inclusive) {
                if (value < start) return false;
            } else if (value <= start) return false;
        }
        if (self.end_ns) |end| {
            if (self.end_boundary == .inclusive) {
                if (value > end) return false;
            } else if (value >= end) return false;
        }
        return true;
    }

    pub fn validate(self: Range) bool {
        if (self.start_ns != null and self.end_ns != null and self.start_ns.? > self.end_ns.?) return false;
        return true;
    }

    pub fn width(self: Range) ?i128 {
        if (self.start_ns == null or self.end_ns == null) return null;
        return self.end_ns.? - self.start_ns.?;
    }
};

pub const Window = struct {
    start_ns: i128,
    end_ns: i128,
    count: usize = 0,
    warning_count: usize = 0,
    error_count: usize = 0,
    bytes: u128 = 0,

    pub fn observe(self: *Window, record: *const record_mod.Record) void {
        self.count += 1;
        self.warning_count += record.warnings.count;
        if (record.severity.rank() >= record_mod.Severity.@"error".rank()) self.error_count += 1;
        if (record.network.bytes) |value| self.bytes += value;
    }

    pub fn errorRate(self: Window) f64 {
        if (self.count == 0) return 0;
        return @as(f64, @floatFromInt(self.error_count)) / @as(f64, @floatFromInt(self.count));
    }
};

pub const Series = struct {
    windows: [1024]Window = undefined,
    count: usize = 0,
    missing_timestamp: usize = 0,
    out_of_range: usize = 0,
    overflow: usize = 0,

    pub fn slice(self: *const Series) []const Window {
        return self.windows[0..self.count];
    }
};

pub const Options = struct {
    width_ns: i128,
    origin_ns: i128 = 0,
    range: Range = .{},
    include_empty: bool = false,
    max_windows: usize = 1024,
};

pub fn build(records: []const record_mod.Record, options: Options) !Series {
    if (options.width_ns <= 0 or !options.range.validate()) return error.InvalidWindow;
    var result = Series{};
    for (records) |*record| {
        const timestamp = record.timestamp_unix_ns orelse {
            result.missing_timestamp += 1;
            continue;
        };
        if (!options.range.contains(timestamp) and (options.range.start_ns != null or options.range.end_ns != null)) {
            result.out_of_range += 1;
            continue;
        }
        const start = alignedStart(timestamp, options.origin_ns, options.width_ns);
        var target: ?*Window = null;
        for (result.windows[0..result.count]) |*window| {
            if (window.start_ns == start) {
                target = window;
                break;
            }
        }
        if (target == null) {
            if (result.count >= @min(options.max_windows, result.windows.len)) {
                result.overflow += 1;
                continue;
            }
            result.windows[result.count] = .{ .start_ns = start, .end_ns = start + options.width_ns };
            target = &result.windows[result.count];
            result.count += 1;
        }
        target.?.observe(record);
    }
    sortWindows(result.windows[0..result.count]);
    if (options.include_empty and result.count > 1) try fillGaps(&result, options.width_ns, options.max_windows);
    return result;
}

pub fn alignedStart(timestamp: i128, origin: i128, width: i128) i128 {
    return origin + @divFloor(timestamp - origin, width) * width;
}

fn sortWindows(windows: []Window) void {
    std.mem.sort(Window, windows, {}, struct {
        fn lessThan(_: void, left: Window, right: Window) bool {
            return left.start_ns < right.start_ns;
        }
    }.lessThan);
}

fn fillGaps(series: *Series, width: i128, max_windows: usize) !void {
    var rebuilt: [1024]Window = undefined;
    var count: usize = 0;
    var cursor = series.windows[0].start_ns;
    const end = series.windows[series.count - 1].start_ns;
    var source_index: usize = 0;
    while (cursor <= end) : (cursor += width) {
        if (count >= @min(max_windows, rebuilt.len)) return error.TooManyWindows;
        if (source_index < series.count and series.windows[source_index].start_ns == cursor) {
            rebuilt[count] = series.windows[source_index];
            source_index += 1;
        } else rebuilt[count] = .{ .start_ns = cursor, .end_ns = cursor + width };
        count += 1;
    }
    @memcpy(series.windows[0..count], rebuilt[0..count]);
    series.count = count;
}

pub fn select(records: []const record_mod.Record, range: Range, output: []usize) usize {
    var count: usize = 0;
    for (records, 0..) |*record, index| {
        if (!range.contains(record.timestamp_unix_ns)) continue;
        if (count >= output.len) break;
        output[count] = index;
        count += 1;
    }
    return count;
}

pub fn writeText(series: *const Series, writer: anytype) !void {
    for (series.slice()) |window| {
        try writer.print("start_ns={d} end_ns={d} count={d} errors={d} error_rate={d:.6} warnings={d} bytes={d}\n", .{
            window.start_ns, window.end_ns, window.count, window.error_count, window.errorRate(), window.warning_count, window.bytes,
        });
    }
    if (series.missing_timestamp != 0) try writer.print("missing_timestamp={d}\n", .{series.missing_timestamp});
    if (series.out_of_range != 0) try writer.print("out_of_range={d}\n", .{series.out_of_range});
    if (series.overflow != 0) try writer.print("overflow={d}\n", .{series.overflow});
}

test "time windows align negative and positive timestamps" {
    try std.testing.expectEqual(@as(i128, -10), alignedStart(-1, 0, 10));
    try std.testing.expectEqual(@as(i128, 10), alignedStart(19, 0, 10));
}

test "series optionally materializes empty windows" {
    var records = [_]record_mod.Record{ record_mod.Record.init(.jsonl), record_mod.Record.init(.jsonl) };
    records[0].timestamp_unix_ns = 5;
    records[1].timestamp_unix_ns = 25;
    const series = try build(&records, .{ .width_ns = 10, .include_empty = true });
    try std.testing.expectEqual(@as(usize, 3), series.count);
    try std.testing.expectEqual(@as(usize, 0), series.windows[1].count);
}
