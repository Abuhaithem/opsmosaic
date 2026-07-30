const std = @import("std");
const opsmosaic = @import("opsmosaic");

test "aggregation covers severity, service, formats, tags, numeric fields, and HTTP classes" {
    var records = [_]opsmosaic.Record{ opsmosaic.Record.init(.access_log), opsmosaic.Record.init(.access_log), opsmosaic.Record.init(.jsonl) };
    records[0].service = "gateway";
    records[0].severity = .info;
    records[0].network.status = 200;
    try records[0].addTag("prod");
    try records[0].addField("duration_ms", .{ .decimal = 10.5 });
    records[1].service = "gateway";
    records[1].severity = .@"error";
    records[1].network.status = 503;
    try records[1].addTag("prod");
    try records[1].addField("duration_ms", .{ .integer = 20 });
    records[2].service = "worker";
    records[2].severity = .warning;
    const report = opsmosaic.processing.aggregation.summarize(&records);
    try std.testing.expectEqual(@as(usize, 3), report.record_count);
    try std.testing.expectEqual(@as(usize, 1), report.status.success);
    try std.testing.expectEqual(@as(usize, 1), report.status.server_error);
    const numeric = opsmosaic.processing.aggregation.numeric(&records, "duration_ms");
    try std.testing.expectEqual(@as(usize, 2), numeric.count);
    try std.testing.expectEqual(@as(f64, 30.5), numeric.sum);
}

test "time-window aggregation handles gaps and missing timestamps" {
    var records = [_]opsmosaic.Record{ opsmosaic.Record.init(.jsonl), opsmosaic.Record.init(.jsonl), opsmosaic.Record.init(.jsonl) };
    records[0].timestamp_unix_ns = 5;
    records[1].timestamp_unix_ns = 25;
    const series = try opsmosaic.processing.time_window.build(&records, .{ .width_ns = 10, .include_empty = true });
    try std.testing.expectEqual(@as(usize, 3), series.count);
    try std.testing.expectEqual(@as(usize, 1), series.missing_timestamp);
}

test "field profiling reports coverage and value kinds" {
    var records = [_]opsmosaic.Record{ opsmosaic.Record.init(.jsonl), opsmosaic.Record.init(.jsonl) };
    try records[0].addField("latency_ms", .{ .integer = 4 });
    try records[1].addField("latency_ms", .{ .decimal = 7.5 });
    const profile = opsmosaic.processing.field_stats.build(&records);
    try std.testing.expectEqual(@as(usize, 2), profile.find("latency_ms").?.present);
}
