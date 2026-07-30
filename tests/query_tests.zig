const std = @import("std");
const opsmosaic = @import("opsmosaic");

test "query language supports comparisons, string operators, tags, missing, and logic" {
    var record = opsmosaic.Record.init(.jsonl);
    record.severity = .critical;
    record.service = "payments-api";
    record.message = "database connection exhausted";
    record.network.status = 503;
    try record.addTag("prod");
    const expressions = [_][]const u8{
        "severity >= error",
        "service starts_with payments",
        "message contains connection",
        "status >= 500 and status < 600",
        "has(prod) and not missing(service)",
        "missing(trace_id) or trace_id == abc",
    };
    for (expressions) |expression| {
        const program = try opsmosaic.processing.query_parser.parse(expression, .{});
        try std.testing.expect(try opsmosaic.processing.query_eval.evaluate(&program, &record, .{}));
    }
}

test "query parser rejects excessive nesting" {
    const expression = "not not not not not not not not service == api";
    try std.testing.expectError(error.TooDeep, opsmosaic.processing.query_parser.parse(expression, .{ .max_depth = 4 }));
}

test "stable ordering and deterministic sampling preserve reproducibility" {
    var records = [_]opsmosaic.Record{ opsmosaic.Record.init(.jsonl), opsmosaic.Record.init(.jsonl), opsmosaic.Record.init(.jsonl) };
    records[0].network.status = 503;
    records[1].network.status = 200;
    records[2].network.status = 404;
    opsmosaic.processing.ordering.sort(&records, .{ .field = "status" });
    try std.testing.expectEqual(@as(u16, 200), records[0].network.status.?);
    const selected = try opsmosaic.processing.sampling.select(&records, .{ .every = 2 });
    try std.testing.expectEqual(@as(usize, 2), selected.count);
}
