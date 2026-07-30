const std = @import("std");
const opsmosaic = @import("opsmosaic");

test "timestamp, severity, attribution, coercion, tags, and network normalization compose" {
    var record = opsmosaic.Record.init(.jsonl);
    record.timestamp_text = "2026-07-30T07:00:00Z";
    try record.addField("level", .{ .text = "ERR" });
    try record.addField("hostname", .{ .text = "EDGE-01.EXAMPLE" });
    try record.addField("application", .{ .text = "gateway.service" });
    try record.addField("tags", .{ .text = "prod,edge,api" });
    try record.addField("status", .{ .text = "502" });
    try record.addField("source_ip", .{ .text = "192.0.2.44" });
    const result = opsmosaic.normalization.pipeline.normalize(&record, .{});
    try std.testing.expect(result.changed);
    try std.testing.expect(record.timestamp_unix_ns != null);
    try std.testing.expectEqual(opsmosaic.model.record.Severity.@"error", record.severity);
    try std.testing.expectEqualStrings("EDGE-01.EXAMPLE", record.host.?);
    try std.testing.expectEqualStrings("gateway.service", record.service.?);
}

test "owned records survive source buffer release and deinitialize cleanly" {
    var source = opsmosaic.Record.init(.jsonl);
    const text = try std.testing.allocator.dupe(u8, "transient");
    source.message = text;
    var owned = try opsmosaic.OwnedRecord.cloneFrom(std.testing.allocator, &source);
    std.testing.allocator.free(text);
    defer owned.deinit();
    try std.testing.expectEqualStrings("transient", owned.record.message);
}

test "normalization remains deterministic across repeated application" {
    var record = opsmosaic.Record.init(.syslog);
    record.host = "EDGE-1.EXAMPLE.";
    record.service = "payments.service";
    record.severity = .warning;
    _ = opsmosaic.normalization.pipeline.normalize(&record, .{});
    const first_hash = record.identityHash();
    _ = opsmosaic.normalization.pipeline.normalize(&record, .{});
    try std.testing.expectEqual(first_hash, record.identityHash());
}
