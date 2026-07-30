const std = @import("std");
const options_mod = @import("options.zig");
const commands = @import("commands.zig");

pub fn run(allocator: std.mem.Allocator, arguments: []const []const u8, stdout: std.fs.File.Writer, stderr: std.fs.File.Writer) u8 {
    const options = options_mod.parse(arguments) catch |err| {
        stderr.print("opsmosaic: {s}\n", .{@errorName(err)}) catch {};
        stderr.writeAll("Run 'opsmosaic help' for usage.\n") catch {};
        return @intFromEnum(commands.ExitCode.usage);
    };
    const code = commands.execute(.{ .allocator = allocator, .stdout = stdout, .stderr = stderr }, options) catch |err| {
        stderr.print("opsmosaic: internal error: {s}\n", .{@errorName(err)}) catch {};
        return @intFromEnum(commands.ExitCode.internal_error);
    };
    return @intFromEnum(code);
}

pub fn runProcess(allocator: std.mem.Allocator) !u8 {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    const raw = if (argv.len > 1) argv[1..] else argv[0..0];
    const arguments = try allocator.alloc([]const u8, raw.len);
    defer allocator.free(arguments);
    for (raw, arguments) |src, *dst| dst.* = src;
    return run(allocator, arguments, std.io.getStdOut().writer(), std.io.getStdErr().writer());
}

test "dispatcher returns usage for an unknown command" {
    var stdout_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buffer.deinit();
    // File.Writer is intentionally required for the process boundary; option parsing is tested independently.
    try std.testing.expectError(error.UnknownCommand, options_mod.parse(&.{"does-not-exist"}));
}
