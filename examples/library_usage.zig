const std = @import("std");
const opsmosaic = @import("opsmosaic");

pub fn main() !void {
    const input =
        "{\"timestamp\":\"2026-07-30T07:15:00Z\",\"severity\":\"error\",\"host\":\"edge-01\",\"service\":\"gateway\",\"message\":\"upstream timeout\",\"status\":504}";
    var parsed = try opsmosaic.parseRecord(input, .jsonl, .{ .path = "memory.jsonl" });
    _ = opsmosaic.normalizeRecord(&parsed.record);
    const findings = opsmosaic.validation.rules.validate(&parsed.record, opsmosaic.validation.schema.service_event, .{});
    const stdout = std.io.getStdOut().writer();
    try opsmosaic.exporting.json.writeRecord(&parsed.record, stdout, .{ .pretty = true });
    try stdout.print("\nvalidation errors: {d}\n", .{findings.errorCount()});
}

test "library example remains compilable and exercises public API" {
    var parsed = try opsmosaic.parseRecord("{\"message\":\"ready\"}", .jsonl, .{});
    _ = opsmosaic.normalizeRecord(&parsed.record);
    try std.testing.expectEqualStrings("ready", parsed.record.message);
}
