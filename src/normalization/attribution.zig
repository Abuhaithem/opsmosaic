const std = @import("std");
const record_mod = @import("../model/record.zig");

pub const Attribution = struct {
    host_confidence: u8 = 0,
    service_confidence: u8 = 0,
    host_source: ?[]const u8 = null,
    service_source: ?[]const u8 = null,
};

pub fn normalizeRecord(record: *record_mod.Record) Attribution {
    var result = Attribution{};
    if (record.host != null) {
        result.host_confidence = 100;
        result.host_source = "parser";
    } else if (findText(record, &.{ "hostname", "node", "node_name", "instance", "machine", "server" })) |found| {
        record.host = found.value;
        result.host_confidence = found.confidence;
        result.host_source = found.key;
    } else if (record.network.destination_address) |address| {
        record.host = address;
        result.host_confidence = 45;
        result.host_source = "destination_address";
    }

    if (record.service != null) {
        result.service_confidence = 100;
        result.service_source = "parser";
    } else if (findText(record, &.{ "service_name", "app", "application", "component", "unit", "program", "container" })) |found| {
        record.service = found.value;
        result.service_confidence = found.confidence;
        result.service_source = found.key;
    } else if (record.network.path) |path| {
        if (serviceFromPath(path)) |service| {
            record.service = service;
            result.service_confidence = 40;
            result.service_source = "request_path";
        }
    }
    return result;
}

const FoundText = struct { key: []const u8, value: []const u8, confidence: u8 };

fn findText(record: *const record_mod.Record, keys: []const []const u8) ?FoundText {
    for (keys, 0..) |key, index| {
        if (record.getField(key)) |value| {
            if (value.asText()) |text| {
                if (validIdentity(text)) {
                    const penalty: usize = @min(index * 5, 40);
                    return .{ .key = key, .value = text, .confidence = @intCast(90 - penalty) };
                }
            }
        }
    }
    return null;
}

pub fn validIdentity(input: []const u8) bool {
    if (input.len == 0 or input.len > 253) return false;
    if (std.mem.eql(u8, input, "-") or std.ascii.eqlIgnoreCase(input, "unknown") or std.ascii.eqlIgnoreCase(input, "localhost")) return false;
    for (input) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_' or ch == ':' or ch == '/')) return false;
    }
    return true;
}

fn serviceFromPath(path_raw: []const u8) ?[]const u8 {
    var path = path_raw;
    if (std.mem.indexOfScalar(u8, path, '?')) |index| path = path[0..index];
    path = std.mem.trim(u8, path, "/");
    if (path.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const first = path[0..slash];
    if (std.ascii.eqlIgnoreCase(first, "api") and slash < path.len) {
        const rest = path[slash + 1 ..];
        const next = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        return rest[0..next];
    }
    if (std.ascii.eqlIgnoreCase(first, "health") or std.ascii.eqlIgnoreCase(first, "metrics")) return null;
    return first;
}

pub fn canonicalHost(input_raw: []const u8, buffer: []u8) []const u8 {
    var input = std.mem.trim(u8, input_raw, " \t\r\n.");
    if (std.mem.indexOfScalar(u8, input, ':')) |colon| {
        const has_multiple_colons = std.mem.indexOfScalarPos(u8, input, colon + 1, ':') != null;
        if (!has_multiple_colons) input = input[0..colon];
    }
    const length = @min(input.len, buffer.len);
    for (input[0..length], 0..) |ch, index| buffer[index] = std.ascii.toLower(ch);
    return buffer[0..length];
}

pub fn sameHost(a: []const u8, b: []const u8) bool {
    var left: [256]u8 = undefined;
    var right: [256]u8 = undefined;
    return std.mem.eql(u8, canonicalHost(a, &left), canonicalHost(b, &right));
}

pub fn sameService(a: []const u8, b: []const u8) bool {
    return normalizeServiceEqual(a, b);
}

fn normalizeServiceEqual(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and (a[ai] == '-' or a[ai] == '_' or a[ai] == '.')) ai += 1;
        while (bi < b.len and (b[bi] == '-' or b[bi] == '_' or b[bi] == '.')) bi += 1;
        if (ai == a.len or bi == b.len) return ai == a.len and bi == b.len;
        if (std.ascii.toLower(a[ai]) != std.ascii.toLower(b[bi])) return false;
        ai += 1;
        bi += 1;
    }
}

test "service names compare across common separators" {
    try std.testing.expect(sameService("edge-api", "edge_api"));
}
