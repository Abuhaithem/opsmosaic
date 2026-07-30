const std = @import("std");
const opsmosaic = @import("opsmosaic");

const record_mod = opsmosaic.model.record;
const Session = opsmosaic.workflow.session.Session;
const correlation = opsmosaic.processing.correlation;
const route_metrics = opsmosaic.processing.route_metrics;
const batch = opsmosaic.processing.batch;

// Defect: dedup-owned-record-double-free (src/workflow/session.zig)

test "ingested records own their storage independently of the parse batch" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();

    const input = try std.testing.allocator.dupe(u8, "{\"service\":\"api\",\"message\":\"alpha\"}\n{\"service\":\"web\",\"message\":\"beta\"}\n");
    defer std.testing.allocator.free(input);

    try session.ingestBytes(input, "events.jsonl", .{ .format = .jsonl });
    try std.testing.expectEqual(@as(usize, 2), session.recordCount());

    const view = try session.borrowedView(std.testing.allocator);
    defer std.testing.allocator.free(view);
    try std.testing.expectEqualStrings("alpha", view[0].message);
    try std.testing.expectEqualStrings("web", view[1].service.?);
}

test "deduplicated ingest keeps a single valid owned record" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();

    try session.ingestBytes(
        "{\"service\":\"api\",\"message\":\"same\"}\n{\"service\":\"api\",\"message\":\"same\"}\n",
        null,
        .{ .format = .jsonl, .deduplicate = true },
    );
    try std.testing.expectEqual(@as(usize, 1), session.recordCount());
    try std.testing.expectEqualStrings("same", session.records.items[0].record.message);
}

// Defect: correlation-stale-member-window (src/processing/correlation.zig)

fn timed(host: []const u8, service: []const u8, ns: i128) record_mod.Record {
    var record = record_mod.Record.init(.jsonl);
    record.host = host;
    record.service = service;
    record.timestamp_unix_ns = ns;
    return record;
}

test "correlation chains records transitively within the time window" {
    var records = [_]record_mod.Record{
        timed("edge-1", "gateway", 0),
        timed("edge-1", "gateway", 100),
        timed("edge-1", "gateway", 200),
    };
    const groups = correlation.group(&records, .{ .time_window_ns = 150, .required_score = 60 });
    try std.testing.expectEqual(@as(usize, 1), groups.count);
    try std.testing.expectEqual(@as(usize, 0), groups.ungrouped);
    try std.testing.expectEqual(@as(usize, 3), groups.slice()[0].count);
}

test "correlation leaves genuinely distant records ungrouped" {
    var records = [_]record_mod.Record{
        timed("edge-1", "gateway", 0),
        timed("edge-1", "gateway", 100),
        timed("edge-1", "gateway", 10_000),
    };
    const groups = correlation.group(&records, .{ .time_window_ns = 150, .required_score = 60 });
    try std.testing.expectEqual(@as(usize, 1), groups.count);
    try std.testing.expectEqual(@as(usize, 2), groups.slice()[0].count);
    try std.testing.expectEqual(@as(usize, 1), groups.ungrouped);
}

// Defect: route-key-normalization-desync (src/processing/route_metrics.zig)

fn httpRecord(method: []const u8, path: []const u8, status: u16) record_mod.Record {
    var record = record_mod.Record.init(.access_log);
    record.network.method = method;
    record.network.path = path;
    record.network.status = status;
    return record;
}

test "route metrics collapse query strings into one route entry" {
    var records = [_]record_mod.Record{
        httpRecord("GET", "/v1/orders?limit=10", 200),
        httpRecord("GET", "/v1/orders?page=2", 500),
        httpRecord("GET", "/v1/orders", 200),
    };
    const table = route_metrics.summarize(&records);
    try std.testing.expectEqual(@as(usize, 1), table.count);
    const orders = table.find("GET", "/v1/orders") orelse return error.RouteMissing;
    try std.testing.expectEqual(@as(usize, 3), orders.count);
    try std.testing.expectEqualStrings("/v1/orders", orders.path);
}

test "route metrics keep genuinely distinct routes separate" {
    var records = [_]record_mod.Record{
        httpRecord("GET", "/v1/orders", 200),
        httpRecord("GET", "/v1/payments", 200),
    };
    const table = route_metrics.summarize(&records);
    try std.testing.expectEqual(@as(usize, 2), table.count);
}

// Defect: getfield-status-shadows-field (src/model/record.zig)

test "getField surfaces stored status and bytes fields that are not HTTP metadata" {
    var record = record_mod.Record.init(.csv);
    try record.addField("status", .{ .text = "active" });
    try record.addField("bytes", .{ .text = "many" });
    try std.testing.expectEqualStrings("active", record.getField("status").?.text);
    try std.testing.expectEqualStrings("many", record.getField("bytes").?.text);
}

test "getField still surfaces HTTP network status and bytes" {
    var record = record_mod.Record.init(.access_log);
    record.network.status = 503;
    record.network.bytes = 2048;
    try std.testing.expectEqual(@as(i64, 503), record.getField("status").?.integer);
    try std.testing.expectEqual(@as(i64, 2048), record.getField("bytes").?.integer);
}

// Defect: dns-directive-state-not-threaded (src/parsing/dns_zone.zig)

test "DNS zone directives carry into subsequent records" {
    var parsed = try batch.parseInput(
        std.testing.allocator,
        "$ORIGIN example.test.\n$TTL 1h\napi IN A 192.0.2.10\n",
        "zone.example",
        .{ .format = .dns_zone },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.parsed);
    const record = &parsed.records.items[0].record;
    try std.testing.expectEqual(@as(i64, 3600), record.getField("ttl").?.integer);
    try std.testing.expectEqualStrings("example.test.", record.getField("origin").?.text);
}

test "DNS record still honors its own explicit TTL" {
    var parsed = try batch.parseInput(
        std.testing.allocator,
        "mail 300 IN A 192.0.2.11\n",
        "zone.example",
        .{ .format = .dns_zone },
    );
    defer parsed.deinit();
    const record = &parsed.records.items[0].record;
    try std.testing.expectEqual(@as(i64, 300), record.getField("ttl").?.integer);
}
