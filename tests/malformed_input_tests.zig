const std = @import("std");
const opsmosaic = @import("opsmosaic");

const malformed_cases = [_]struct { format: opsmosaic.SourceFormat, input: []const u8 }{
    .{ .format = .syslog, .input = "<999999>bad" },
    .{ .format = .rfc5424, .input = "<34>1 missing-fields" },
    .{ .format = .jsonl, .input = "{\"message\": [}" },
    .{ .format = .csv, .input = "a,b\n\"unterminated,b" },
    .{ .format = .ini, .input = "[broken\nkey=value" },
    .{ .format = .access_log, .input = "not an access record" },
    .{ .format = .dns_zone, .input = "name IN A" },
    .{ .format = .env_file, .input = "1INVALID=value" },
    .{ .format = .manifest, .input = "root:\n   child: inconsistent" },
};

test "malformed external input never panics" {
    for (malformed_cases) |case| {
        _ = opsmosaic.parseRecord(case.input, case.format, .{}) catch continue;
    }
}

test "batch parser recovers after malformed records within limits" {
    var parsed = try opsmosaic.parseBatch(std.testing.allocator, "{\"message\":\"one\"}\nnot-json\n{\"message\":\"two\"}\n", null, .{ .format = .jsonl, .continue_after_error = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.stats.parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.stats.failed);
}

test "bounded stream reader rejects oversized lines" {
    const parsed = opsmosaic.parseBatch(std.testing.allocator, "1234567890\n", null, .{ .format = .jsonl, .stream_limits = .{ .max_line_bytes = 4, .max_input_bytes = 64 } });
    try std.testing.expectError(error.LineTooLong, parsed);
}
