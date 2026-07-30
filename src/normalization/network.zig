const std = @import("std");
const record_mod = @import("../model/record.zig");

pub const AddressFamily = enum { unknown, ipv4, ipv6, hostname };

pub const AddressInfo = struct {
    family: AddressFamily,
    private: bool,
    loopback: bool,
    link_local: bool,
};

pub fn normalizeRecord(record: *record_mod.Record) void {
    if (record.network.source_address) |address| record.network.source_address = stripAddressDecorations(address);
    if (record.network.destination_address) |address| record.network.destination_address = stripAddressDecorations(address);
    if (record.network.method) |method| record.network.method = canonicalMethod(method);
    if (record.network.path) |path| record.network.path = canonicalPath(path);
    if (record.network.protocol) |protocol| record.network.protocol = canonicalProtocol(protocol);
}

pub fn classifyAddress(address_raw: []const u8) AddressInfo {
    const address = stripAddressDecorations(address_raw);
    if (std.mem.indexOfScalar(u8, address, ':') != null) {
        return .{
            .family = .ipv6,
            .private = std.mem.startsWith(u8, address, "fc") or std.mem.startsWith(u8, address, "fd"),
            .loopback = std.mem.eql(u8, address, "::1"),
            .link_local = std.mem.startsWith(u8, address, "fe80:"),
        };
    }
    if (looksIpv4(address)) {
        return .{
            .family = .ipv4,
            .private = isPrivateIpv4(address),
            .loopback = std.mem.startsWith(u8, address, "127."),
            .link_local = std.mem.startsWith(u8, address, "169.254."),
        };
    }
    if (address.len > 0) return .{ .family = .hostname, .private = false, .loopback = std.ascii.eqlIgnoreCase(address, "localhost"), .link_local = false };
    return .{ .family = .unknown, .private = false, .loopback = false, .link_local = false };
}

pub fn stripAddressDecorations(input_raw: []const u8) []const u8 {
    const input = std.mem.trim(u8, input_raw, " \t\r\n");
    if (input.len >= 2 and input[0] == '[') {
        if (std.mem.indexOfScalar(u8, input, ']')) |close| return input[1..close];
    }
    const first_colon = std.mem.indexOfScalar(u8, input, ':') orelse return input;
    if (std.mem.indexOfScalarPos(u8, input, first_colon + 1, ':') == null) {
        const port = input[first_colon + 1 ..];
        if (port.len > 0 and allDigits(port)) return input[0..first_colon];
    }
    return input;
}

fn canonicalMethod(input: []const u8) []const u8 {
    const methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE" };
    for (methods) |method| { if (std.ascii.eqlIgnoreCase(input, method)) return method; }
    return input;
}

fn canonicalPath(input: []const u8) []const u8 {
    if (input.len == 0) return "/";
    if (std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://")) {
        const scheme = std.mem.indexOf(u8, input, "://").? + 3;
        const slash = std.mem.indexOfScalarPos(u8, input, scheme, '/') orelse return "/";
        return input[slash..];
    }
    return input;
}

fn canonicalProtocol(input: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(input, "http/1.0")) return "HTTP/1.0";
    if (std.ascii.eqlIgnoreCase(input, "http/1.1")) return "HTTP/1.1";
    if (std.ascii.eqlIgnoreCase(input, "http/2") or std.ascii.eqlIgnoreCase(input, "h2")) return "HTTP/2";
    if (std.ascii.eqlIgnoreCase(input, "http/3") or std.ascii.eqlIgnoreCase(input, "h3")) return "HTTP/3";
    return input;
}

fn looksIpv4(input: []const u8) bool {
    var parts = std.mem.splitScalar(u8, input, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 3) return false;
        const value = std.fmt.parseInt(u8, part, 10) catch return false;
        _ = value;
        count += 1;
    }
    return count == 4;
}

fn isPrivateIpv4(input: []const u8) bool {
    if (std.mem.startsWith(u8, input, "10.") or std.mem.startsWith(u8, input, "192.168.") or std.mem.startsWith(u8, input, "127.") or std.mem.startsWith(u8, input, "169.254.")) return true;
    if (std.mem.startsWith(u8, input, "172.")) {
        const rest = input[4..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        const second = std.fmt.parseInt(u8, rest[0..dot], 10) catch return false;
        return second >= 16 and second <= 31;
    }
    return false;
}

fn allDigits(input: []const u8) bool {
    for (input) |ch| { if (!std.ascii.isDigit(ch)) return false; }
    return true;
}

test "address classification strips ports" {
    const info = classifyAddress("192.168.1.9:443");
    try std.testing.expectEqual(AddressFamily.ipv4, info.family);
    try std.testing.expect(info.private);
}
