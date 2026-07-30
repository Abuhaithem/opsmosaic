const std = @import("std");
const record_mod = @import("../model/record.zig");

pub const StatusClasses = struct {
    informational: usize = 0,
    success: usize = 0,
    redirection: usize = 0,
    client_error: usize = 0,
    server_error: usize = 0,
    other: usize = 0,

    pub fn observe(self: *StatusClasses, status: ?u16) void {
        const value = status orelse {
            self.other += 1;
            return;
        };
        switch (value / 100) {
            1 => self.informational += 1,
            2 => self.success += 1,
            3 => self.redirection += 1,
            4 => self.client_error += 1,
            5 => self.server_error += 1,
            else => self.other += 1,
        }
    }

    pub fn total(self: StatusClasses) usize {
        return self.informational + self.success + self.redirection + self.client_error + self.server_error + self.other;
    }

    pub fn errorRate(self: StatusClasses) f64 {
        const count = self.total();
        if (count == 0) return 0;
        return @as(f64, @floatFromInt(self.client_error + self.server_error)) / @as(f64, @floatFromInt(count));
    }
};

pub const NumericDistribution = struct {
    count: usize = 0,
    missing: usize = 0,
    incompatible: usize = 0,
    sum: f64 = 0,
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    samples: [256]f64 = undefined,
    sample_count: usize = 0,
    samples_omitted: usize = 0,

    pub fn observeValue(self: *NumericDistribution, value: ?record_mod.Value) void {
        const candidate = value orelse {
            self.missing += 1;
            return;
        };
        const number: f64 = switch (candidate) {
            .integer => |integer| @floatFromInt(integer),
            .decimal => |decimal| decimal,
            else => {
                self.incompatible += 1;
                return;
            },
        };
        self.observeNumber(number);
    }

    pub fn observeNumber(self: *NumericDistribution, number: f64) void {
        if (!std.math.isFinite(number)) {
            self.incompatible += 1;
            return;
        }
        self.count += 1;
        self.sum += number;
        self.minimum = if (self.minimum) |current| @min(current, number) else number;
        self.maximum = if (self.maximum) |current| @max(current, number) else number;
        if (self.sample_count < self.samples.len) {
            self.samples[self.sample_count] = number;
            self.sample_count += 1;
        } else {
            self.samples_omitted += 1;
        }
    }

    pub fn average(self: NumericDistribution) ?f64 {
        if (self.count == 0) return null;
        return self.sum / @as(f64, @floatFromInt(self.count));
    }

    pub fn percentile(self: *const NumericDistribution, percentile_value: u8) ?f64 {
        if (self.sample_count == 0 or percentile_value > 100) return null;
        var ordered: [256]f64 = undefined;
        @memcpy(ordered[0..self.sample_count], self.samples[0..self.sample_count]);
        insertionSort(ordered[0..self.sample_count]);
        const numerator = @as(usize, percentile_value) * (self.sample_count - 1);
        const index = (numerator + 50) / 100;
        return ordered[index];
    }
};

pub const RouteMetric = struct {
    method: []const u8,
    path: []const u8,
    count: usize = 0,
    statuses: StatusClasses = .{},
    response_bytes: NumericDistribution = .{},
    latency_ms: NumericDistribution = .{},
    first_timestamp_ns: ?i128 = null,
    last_timestamp_ns: ?i128 = null,
    request_ids: usize = 0,
    trace_ids: usize = 0,
    recovered_records: usize = 0,

    pub fn observe(self: *RouteMetric, record: *const record_mod.Record) void {
        self.count += 1;
        self.statuses.observe(record.network.status);
        if (record.network.bytes) |bytes| self.response_bytes.observeNumber(@floatFromInt(bytes)) else self.response_bytes.missing += 1;
        self.latency_ms.observeValue(latencyValue(record));
        if (record.timestamp_unix_ns) |timestamp| {
            self.first_timestamp_ns = if (self.first_timestamp_ns) |current| @min(current, timestamp) else timestamp;
            self.last_timestamp_ns = if (self.last_timestamp_ns) |current| @max(current, timestamp) else timestamp;
        }
        if (record.request_id != null) self.request_ids += 1;
        if (record.trace_id != null) self.trace_ids += 1;
        if (record.recovered) self.recovered_records += 1;
    }

    pub fn requestIdCoverage(self: RouteMetric) f64 {
        if (self.count == 0) return 0;
        return @as(f64, @floatFromInt(self.request_ids)) / @as(f64, @floatFromInt(self.count));
    }

    pub fn traceIdCoverage(self: RouteMetric) f64 {
        if (self.count == 0) return 0;
        return @as(f64, @floatFromInt(self.trace_ids)) / @as(f64, @floatFromInt(self.count));
    }

    pub fn spanNs(self: RouteMetric) ?i128 {
        if (self.first_timestamp_ns == null or self.last_timestamp_ns == null) return null;
        return self.last_timestamp_ns.? - self.first_timestamp_ns.?;
    }
};

pub const Table = struct {
    entries: [256]RouteMetric = undefined,
    count: usize = 0,
    overflow_records: usize = 0,
    records_without_route: usize = 0,

    pub fn observe(self: *Table, record: *const record_mod.Record) void {
        const raw_path = record.network.path orelse {
            self.records_without_route += 1;
            return;
        };
        const method = record.network.method orelse "<unknown>";
        const path = routePath(raw_path);
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.method, method) and std.mem.eql(u8, entry.path, path)) {
                entry.observe(record);
                return;
            }
        }
        if (self.count >= self.entries.len) {
            self.overflow_records += 1;
            return;
        }
        self.entries[self.count] = .{ .method = method, .path = path };
        self.entries[self.count].observe(record);
        self.count += 1;
    }

    pub fn slice(self: *const Table) []const RouteMetric {
        return self.entries[0..self.count];
    }

    pub fn find(self: *const Table, method: []const u8, path: []const u8) ?*const RouteMetric {
        for (self.slice()) |*entry| {
            if (std.mem.eql(u8, entry.method, method) and std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    pub fn totalRoutedRecords(self: *const Table) usize {
        var total: usize = self.overflow_records;
        for (self.slice()) |entry| total += entry.count;
        return total;
    }

    pub fn busiest(self: *const Table) ?*const RouteMetric {
        if (self.count == 0) return null;
        var best: *const RouteMetric = &self.entries[0];
        for (self.entries[1..self.count]) |*entry| if (entry.count > best.count) {
            best = entry;
        };
        return best;
    }

    pub fn highestErrorRate(self: *const Table, minimum_requests: usize) ?*const RouteMetric {
        var best: ?*const RouteMetric = null;
        for (self.slice()) |*entry| {
            if (entry.count < minimum_requests) continue;
            if (best == null or entry.statuses.errorRate() > best.?.statuses.errorRate()) best = entry;
        }
        return best;
    }
};

pub fn summarize(records: []const record_mod.Record) Table {
    var table = Table{};
    for (records) |*record| table.observe(record);
    return table;
}

pub fn writeText(table: *const Table, writer: anytype) !void {
    for (table.slice()) |*entry| {
        try writer.print("route[{s} {s}].count={d}", .{ entry.method, entry.path, entry.count });
        try writer.print(" error_rate={d:.6}", .{entry.statuses.errorRate()});
        if (entry.latency_ms.average()) |average| try writer.print(" latency_avg_ms={d:.3}", .{average});
        if (entry.latency_ms.percentile(95)) |p95| try writer.print(" latency_p95_ms={d:.3}", .{p95});
        if (entry.response_bytes.average()) |average_bytes| try writer.print(" bytes_avg={d:.1}", .{average_bytes});
        try writer.print(" request_id_coverage={d:.3} trace_id_coverage={d:.3}", .{ entry.requestIdCoverage(), entry.traceIdCoverage() });
        if (entry.recovered_records != 0) try writer.print(" recovered={d}", .{entry.recovered_records});
        try writer.writeByte('\n');
    }
    if (table.records_without_route != 0) try writer.print("route[<missing>].count={d}\n", .{table.records_without_route});
    if (table.overflow_records != 0) try writer.print("route[<overflow>].count={d}\n", .{table.overflow_records});
}

pub fn routePath(input: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, input, '?');
    const fragment = std.mem.indexOfScalar(u8, input, '#');
    const end = if (query == null) fragment orelse input.len else if (fragment == null) query.? else @min(query.?, fragment.?);
    return input[0..end];
}

pub fn isOperationalRoute(record: *const record_mod.Record) bool {
    const path = record.network.path orelse return false;
    if (path.len == 0 or path[0] != '/') return false;
    if (std.mem.startsWith(u8, path, "/health") or std.mem.startsWith(u8, path, "/ready")) return false;
    return true;
}

pub fn coverage(table: *const Table, total_records: usize) f64 {
    if (total_records == 0) return 0;
    return @as(f64, @floatFromInt(table.totalRoutedRecords())) / @as(f64, @floatFromInt(total_records));
}

fn latencyValue(record: *const record_mod.Record) ?record_mod.Value {
    const names = [_][]const u8{ "duration_ms", "latency_ms", "elapsed_ms", "request_time_ms" };
    for (names) |name| { if (record.getField(name)) |value| return value; }
    return null;
}

fn insertionSort(values: []f64) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const candidate = values[index];
        var position = index;
        while (position > 0 and values[position - 1] > candidate) : (position -= 1) values[position] = values[position - 1];
        values[position] = candidate;
    }
}

test "route metrics aggregate status latency and identifiers" {
    var records = [_]record_mod.Record{ record_mod.Record.init(.access_log), record_mod.Record.init(.access_log), record_mod.Record.init(.access_log) };
    records[0].network.method = "GET";
    records[0].network.path = "/v1/orders?limit=10";
    records[0].network.status = 200;
    records[0].network.bytes = 100;
    records[0].request_id = "req-1";
    try records[0].addField("duration_ms", .{ .integer = 10 });
    records[1].network.method = "GET";
    records[1].network.path = "/v1/orders";
    records[1].network.status = 503;
    records[1].network.bytes = 300;
    records[1].trace_id = "tr-2";
    try records[1].addField("duration_ms", .{ .decimal = 30.0 });
    records[2].network.method = "GET";
    records[2].network.path = "/health";
    records[2].network.status = 200;

    const table = summarize(&records);
    const orders = table.find("GET", "/v1/orders").?;
    try std.testing.expectEqual(@as(usize, 2), orders.count);
    try std.testing.expectEqual(@as(f64, 0.5), orders.statuses.errorRate());
    try std.testing.expectEqual(@as(f64, 20.0), orders.latency_ms.average().?);
    try std.testing.expectEqual(@as(f64, 30.0), orders.latency_ms.percentile(95).?);
    try std.testing.expectEqualStrings("/v1/orders", routePath("/v1/orders?limit=10#top"));
    try std.testing.expect(!isOperationalRoute(&records[2]));
}

test "route report is deterministic" {
    var record = record_mod.Record.init(.access_log);
    record.network.method = "POST";
    record.network.path = "/v1/payments";
    record.network.status = 201;
    var table = Table{};
    table.observe(&record);
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try writeText(&table, output.writer());
    try std.testing.expect(std.mem.indexOf(u8, output.items, "route[POST /v1/payments].count=1") != null);
}
