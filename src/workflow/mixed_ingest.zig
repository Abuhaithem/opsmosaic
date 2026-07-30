const std = @import("std");
const source_mod = @import("../model/source_info.zig");
const detector = @import("../input/detector.zig");
const stream = @import("../input/stream_reader.zig");
const session_mod = @import("session.zig");

pub const Route = struct {
    pattern: []const u8,
    format: source_mod.SourceFormat,
};

pub const Plan = struct {
    routes: [32]Route = undefined,
    route_count: usize = 0,
    default_format: source_mod.SourceFormat = .unknown,
    deduplicate: bool = true,
    continue_after_error: bool = true,
    stream_limits: stream.StreamLimits = .{},

    pub fn addRoute(self: *Plan, route: Route) error{TooManyRoutes}!void {
        if (self.route_count >= self.routes.len) return error.TooManyRoutes;
        if (route.pattern.len == 0 or route.format == .unknown) return;
        self.routes[self.route_count] = route;
        self.route_count += 1;
    }

    pub fn formatFor(self: *const Plan, path: []const u8, prefix: []const u8) source_mod.SourceFormat {
        for (self.routes[0..self.route_count]) |route| {
            if (globMatches(route.pattern, path)) return route.format;
        }
        if (self.default_format != .unknown) return self.default_format;
        return detector.detect(path, prefix).format;
    }
};

pub const Input = struct {
    path: []const u8,
    format: source_mod.SourceFormat = .unknown,
};

pub const Outcome = struct {
    attempted: usize = 0,
    completed: usize = 0,
    failed: usize = 0,
    records_added: usize = 0,
    duplicates_removed: usize = 0,
};

pub fn execute(session: *session_mod.Session, inputs: []const Input, plan: Plan, error_writer: anytype) !Outcome {
    var outcome = Outcome{};
    for (inputs) |input| {
        outcome.attempted += 1;
        const before = session.recordCount();
        const format = if (input.format != .unknown) input.format else plan.formatFor(input.path, input.path);
        session.ingestPath(input.path, .{
            .format = format,
            .stream_limits = plan.stream_limits,
            .continue_after_error = plan.continue_after_error,
            .deduplicate = false,
        }) catch |err| {
            outcome.failed += 1;
            try error_writer.print("opsmosaic: {s}: {s}\n", .{ input.path, @errorName(err) });
            if (!plan.continue_after_error) return err;
            continue;
        };
        outcome.completed += 1;
        outcome.records_added += session.recordCount() - before;
    }
    if (plan.deduplicate) outcome.duplicates_removed = session.removeDuplicates();
    return outcome;
}

pub fn parseRoute(input: []const u8) !Route {
    const equals = std.mem.indexOfScalar(u8, input, '=') orelse return error.InvalidRoute;
    const pattern = std.mem.trim(u8, input[0..equals], " \t");
    const format_text = std.mem.trim(u8, input[equals + 1 ..], " \t");
    const format = source_mod.SourceFormat.fromLabel(format_text) orelse return error.InvalidFormat;
    if (pattern.len == 0 or format == .unknown) return error.InvalidRoute;
    return .{ .pattern = pattern, .format = format };
}

pub fn globMatches(pattern: []const u8, input: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (i < input.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == input[i])) {
            p += 1;
            i += 1;
            continue;
        }
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = i;
            continue;
        }
        if (star) |position| {
            p = position + 1;
            retry += 1;
            i = retry;
            continue;
        }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

test "mixed ingest routes extensions and explicit globs" {
    var plan = Plan{};
    try plan.addRoute(.{ .pattern = "*.audit", .format = .jsonl });
    try std.testing.expectEqual(source_mod.SourceFormat.jsonl, plan.formatFor("west.audit", ""));
    try std.testing.expect(globMatches("edge-??.log", "edge-01.log"));
}
