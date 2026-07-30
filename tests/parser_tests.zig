const std = @import("std");
const opsmosaic = @import("opsmosaic");

fn expectFormat(format: opsmosaic.SourceFormat, input: []const u8, expected_message: []const u8) !void {
    var parsed = try opsmosaic.parseRecord(input, format, .{ .path = "fixture" });
    _ = opsmosaic.normalizeRecord(&parsed.record);
    try std.testing.expectEqual(format, parsed.record.source.format);
    if (expected_message.len != 0) try std.testing.expect(std.mem.indexOf(u8, parsed.record.message, expected_message) != null);
}

test "file type detection recognizes every supported family" {
    try std.testing.expectEqual(opsmosaic.SourceFormat.jsonl, opsmosaic.detect("events.jsonl", "{\"message\":\"ok\"}").format);
    try std.testing.expectEqual(opsmosaic.SourceFormat.csv, opsmosaic.detect("inventory.csv", "asset_id,region\na1,east").format);
    try std.testing.expectEqual(opsmosaic.SourceFormat.ini, opsmosaic.detect("service.ini", "[server]\nport=8080").format);
    try std.testing.expectEqual(opsmosaic.SourceFormat.env_file, opsmosaic.detect("service.env", "PORT=8080").format);
    try std.testing.expectEqual(opsmosaic.SourceFormat.dns_zone, opsmosaic.detect("example.zone", "$ORIGIN example.test.\n@ IN A 192.0.2.10").format);
    try std.testing.expectEqual(opsmosaic.SourceFormat.manifest, opsmosaic.detect("deploy.yaml", "service:\n  name: api").format);
}

test "syslog and RFC5424 parsers expose operational fields" {
    try expectFormat(.syslog, "<34>Oct 11 22:14:15 edge-1 sshd[442]: accepted key", "accepted key");
    var parsed = try opsmosaic.parseRecord("<165>1 2026-07-30T07:12:00Z edge-1 payments 812 EVT-7 [trace@32473 id=\"abc\" region=\"east\"] retry scheduled", .rfc5424, .{});
    _ = opsmosaic.normalizeRecord(&parsed.record);
    try std.testing.expectEqualStrings("payments", parsed.record.service.?);
    try std.testing.expectEqualStrings("EVT-7", parsed.record.event_id.?);
    try std.testing.expectEqualStrings("abc", parsed.record.getField("trace.id").?.text);
}

test "JSON Lines and CSV parsers preserve typed values" {
    var json = try opsmosaic.parseRecord("{\"timestamp\":\"2026-07-30T07:00:00Z\",\"service\":\"api\",\"status\":503,\"healthy\":false,\"message\":\"upstream unavailable\"}", .jsonl, .{});
    _ = opsmosaic.normalizeRecord(&json.record);
    try std.testing.expectEqual(@as(u16, 503), json.record.network.status.?);
    try std.testing.expectEqual(false, json.record.getField("healthy").?.boolean);

    var csv = try opsmosaic.parseRecord("asset_id,region,capacity,state\nedge-01,east,32.5,active", .csv, .{});
    _ = opsmosaic.normalizeRecord(&csv.record);
    try std.testing.expectEqualStrings("edge-01", csv.record.getField("asset_id").?.text);
    try std.testing.expectEqual(@as(f64, 32.5), csv.record.getField("capacity").?.decimal);
}

test "configuration parsers handle INI, dotenv, and safe manifest subset" {
    try expectFormat(.ini, "[server]\nhost=edge-1\nport=8080\n", "");
    var env = try opsmosaic.parseRecord("SERVICE=gateway\nPORT=8080\nENABLED=true\n", .env_file, .{});
    _ = opsmosaic.normalizeRecord(&env.record);
    try std.testing.expectEqual(@as(i64, 8080), env.record.getField("PORT").?.integer);

    var manifest = try opsmosaic.parseRecord("service:\n  name: gateway\n  replicas: 3\n  tags:\n    - edge\n    - prod\n", .manifest, .{});
    _ = opsmosaic.normalizeRecord(&manifest.record);
    try std.testing.expectEqualStrings("gateway", manifest.record.service.?);
    try std.testing.expect(manifest.record.hasTag("prod"));
}

test "access and DNS parsers expose normalized network data" {
    var access = try opsmosaic.parseRecord("192.0.2.8 - - [30/Jul/2026:07:13:44 +0000] \"GET /health HTTP/1.1\" 503 129 \"-\" \"probe/2.0\"", .access_log, .{});
    _ = opsmosaic.normalizeRecord(&access.record);
    try std.testing.expectEqualStrings("GET", access.record.network.method.?);
    try std.testing.expectEqual(@as(u16, 503), access.record.network.status.?);

    var dns = try opsmosaic.parseRecord("api 300 IN A 192.0.2.20", .dns_zone, .{});
    _ = opsmosaic.normalizeRecord(&dns.record);
    try std.testing.expectEqualStrings("A", dns.record.getField("dns.type").?.text);
}
