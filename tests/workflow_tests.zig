const std = @import("std");
const opsmosaic = @import("opsmosaic");

test "session ingests multiple normalized records and owns their memory" {
    var session = opsmosaic.workflow.session.Session.init(std.testing.allocator);
    defer session.deinit();
    try session.ingestBytes("{\"service\":\"api\",\"message\":\"ready\"}\n{\"service\":\"worker\",\"message\":\"started\"}\n", "events.jsonl", .{ .format = .jsonl });
    try std.testing.expectEqual(@as(usize, 2), session.recordCount());
    try std.testing.expectEqual(@as(usize, 1), session.sourceSlice().len);
}

test "semantic duplicate detection and correlation operate on normalized content" {
    var records = [_]opsmosaic.Record{ opsmosaic.Record.init(.jsonl), opsmosaic.Record.init(.syslog) };
    records[0].host = "edge-1";
    records[0].service = "api";
    records[0].request_id = "req-7";
    records[0].message = "retry";
    records[0].timestamp_unix_ns = 100;
    records[1] = records[0];
    records[1].source.format = .syslog;
    try std.testing.expect(opsmosaic.processing.duplicate.compare(&records[0], &records[1], .{}).duplicate);
    try std.testing.expect(opsmosaic.processing.correlation.compare(&records[0], &records[1], .{ .time_window_ns = 10 }).correlated);
}

test "inventory workflow reconciles CSV assets with event observations" {
    var records = [_]opsmosaic.Record{ opsmosaic.Record.init(.csv), opsmosaic.Record.init(.jsonl) };
    try records[0].addField("asset_id", .{ .text = "edge-01" });
    try records[0].addField("hostname", .{ .text = "edge-a" });
    try records[0].addField("region", .{ .text = "east" });
    records[1].host = "EDGE-A";
    const catalog = opsmosaic.processing.inventory.build(&records);
    const result = opsmosaic.processing.inventory.reconcile(&records, &catalog);
    try std.testing.expectEqual(@as(usize, 1), result.matched_by_host);
}

test "audit workflow records stages with monotonic sequence numbers" {
    var records = [_]opsmosaic.Record{opsmosaic.Record.init(.jsonl)};
    records[0].message = "ready";
    const result = opsmosaic.workflow.audit.run(&records, .{});
    try std.testing.expect(opsmosaic.workflow.audit.verifySequence(&result.trail));
    try std.testing.expect(result.trail.countStage(.parsed) == 1);
}
