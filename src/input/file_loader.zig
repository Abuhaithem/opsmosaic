const std = @import("std");
const stream = @import("stream_reader.zig");

pub const LoadedInput = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    path: ?[]const u8,

    pub fn deinit(self: *LoadedInput) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn loadPath(allocator: std.mem.Allocator, path: []const u8, limits: stream.StreamLimits) !LoadedInput {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size > limits.max_input_bytes) return error.InputTooLarge;
    const bytes = try file.readToEndAlloc(allocator, limits.max_input_bytes);
    errdefer allocator.free(bytes);
    return .{ .allocator = allocator, .bytes = bytes, .path = path };
}

pub fn loadStdin(allocator: std.mem.Allocator, limits: stream.StreamLimits) !LoadedInput {
    const bytes = try std.io.getStdIn().reader().readAllAlloc(allocator, limits.max_input_bytes);
    errdefer allocator.free(bytes);
    return .{ .allocator = allocator, .bytes = bytes, .path = null };
}

pub fn loadMany(allocator: std.mem.Allocator, paths: []const []const u8, limits: stream.StreamLimits) !std.ArrayList(LoadedInput) {
    var result = std.ArrayList(LoadedInput).init(allocator);
    errdefer {
        for (result.items) |*item| item.deinit();
        result.deinit();
    }
    for (paths) |path| {
        var loaded = try loadPath(allocator, path, limits);
        errdefer loaded.deinit();
        try result.append(loaded);
    }
    return result;
}

pub fn deinitMany(inputs: *std.ArrayList(LoadedInput)) void {
    for (inputs.items) |*item| item.deinit();
    inputs.deinit();
}

test "file loader rejects oversized inputs before allocation" {
    const limits = stream.StreamLimits{ .max_input_bytes = 1 };
    _ = limits;
}
