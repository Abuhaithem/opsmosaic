const std = @import("std");
const opsmosaic = @import("opsmosaic");

fn run(args: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = args,
        .max_output_bytes = 1024 * 1024,
    });
}

fn deinitResult(result: *std.process.Child.RunResult) void {
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .Exited => |code| code,
        else => null,
    };
}

test "CLI detection command identifies example JSON Lines" {
    var result = try run(&.{ "zig-out/bin/opsmosaic", "detect", "examples/inputs/service-events.jsonl" });
    defer deinitResult(&result);
    try std.testing.expectEqual(@as(u8, 0), exitCode(result.term).?);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "jsonl") != null);
}

test "CLI normalize, query, aggregate, validation, export, and diagnose workflows execute" {
    const cases = [_][]const []const u8{
        &.{ "zig-out/bin/opsmosaic", "normalize", "--format", "jsonl", "examples/inputs/service-events.jsonl" },
        &.{ "zig-out/bin/opsmosaic", "query", "--format", "jsonl", "--where", "severity >= warning", "examples/inputs/service-events.jsonl" },
        &.{ "zig-out/bin/opsmosaic", "aggregate", "--format", "access-log", "examples/inputs/access.log" },
        &.{ "zig-out/bin/opsmosaic", "validate", "--format", "access-log", "--schema", "http-event", "examples/inputs/access.log" },
        &.{ "zig-out/bin/opsmosaic", "export", "--format", "jsonl", "--to", "csv", "examples/inputs/service-events.jsonl" },
        &.{ "zig-out/bin/opsmosaic", "diagnose", "--format", "jsonl", "examples/inputs/service-events.jsonl" },
    };
    for (cases) |argv| {
        var result = try run(argv);
        defer deinitResult(&result);
        try std.testing.expect(exitCode(result.term).? == 0 or exitCode(result.term).? == 4);
        try std.testing.expect(result.stdout.len != 0);
    }
}

test "CLI returns documented nonzero code for an invalid command" {
    var result = try run(&.{ "zig-out/bin/opsmosaic", "unknown-command" });
    defer deinitResult(&result);
    try std.testing.expectEqual(@as(u8, 2), exitCode(result.term).?);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "UnknownCommand") != null);
}

test "CLI option parser covers stdin and multiple input behavior" {
    const stdin_options = try opsmosaic.cli.options.parse(&.{ "inspect", "--stdin", "--format", "syslog" });
    try std.testing.expect(stdin_options.explicit_stdin);
    const multi = try opsmosaic.cli.options.parse(&.{ "correlate", "a.jsonl", "b.log" });
    try std.testing.expectEqual(@as(usize, 2), multi.input_count);
}
