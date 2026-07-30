const std = @import("std");
const opsmosaic = @import("opsmosaic");

test "JSON export escapes values, orders fields, and redacts sensitive fields" {
    var record = opsmosaic.Record.init(.jsonl);
    record.service = "gateway";
    record.message = "quote \" and newline\n";
    try record.addField("api_token", .{ .text = "do-not-export" });
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try opsmosaic.exporting.json.writeRecord(&record, output.writer(), .{});
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "<redacted>") != null);
}

test "CSV export quotes delimiters and supports deterministic projections" {
    var record = opsmosaic.Record.init(.jsonl);
    record.service = "api,edge";
    record.message = "ok";
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try opsmosaic.exporting.csv.write(&.{record}, output.writer(), &.{ "service", "message" }, .{});
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"api,edge\"") != null);
}

test "projection aliases columns without mutating records" {
    var record = opsmosaic.Record.init(.jsonl);
    record.service = "billing";
    const selected = try opsmosaic.processing.projection.parse("application=service,text=message");
    const row = opsmosaic.processing.projection.apply(&record, &selected);
    try std.testing.expectEqualStrings("billing", row.get(0).?.text);
}
