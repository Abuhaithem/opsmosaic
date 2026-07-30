const std = @import("std");
const record_mod = @import("../model/record.zig");

pub const TagStats = struct {
    derived: usize = 0,
    duplicates: usize = 0,
    truncated: usize = 0,
};

pub fn normalizeRecord(record: *record_mod.Record) TagStats {
    var stats = TagStats{};
    deriveFormatTag(record, &stats);
    deriveSeverityTag(record, &stats);
    deriveStatusTag(record, &stats);
    deriveEnvironmentTags(record, &stats);
    deriveNetworkTags(record, &stats);
    deriveMessageTags(record, &stats);
    return stats;
}

fn append(record: *record_mod.Record, stats: *TagStats, tag: []const u8) void {
    if (tag.len == 0) return;
    if (record.hasTag(tag)) {
        stats.duplicates += 1;
        return;
    }
    record.addTag(tag) catch {
        stats.truncated += 1;
        return;
    };
    stats.derived += 1;
}

fn deriveFormatTag(record: *record_mod.Record, stats: *TagStats) void {
    append(record, stats, record.source.format.label());
    if (record.source.format == .ini or record.source.format == .env_file or record.source.format == .manifest) append(record, stats, "configuration");
    if (record.source.format == .access_log) append(record, stats, "http");
    if (record.source.format == .dns_zone) append(record, stats, "dns");
}

fn deriveSeverityTag(record: *record_mod.Record, stats: *TagStats) void {
    append(record, stats, record.severity.label());
    if (record.severity.rank() >= record_mod.Severity.error.rank()) append(record, stats, "needs-attention")
    else if (record.severity == .warning) append(record, stats, "degraded");
}

fn deriveStatusTag(record: *record_mod.Record, stats: *TagStats) void {
    const status = record.network.status orelse return;
    append(record, stats, switch (status / 100) {
        1 => "http-1xx",
        2 => "http-2xx",
        3 => "http-3xx",
        4 => "http-4xx",
        5 => "http-5xx",
        else => "http-other",
    });
    if (status == 429) append(record, stats, "rate-limited");
    if (status == 401 or status == 403) append(record, stats, "authorization");
}

fn deriveEnvironmentTags(record: *record_mod.Record, stats: *TagStats) void {
    const keys = [_][]const u8{ "environment", "env", "stage", "tier", "region", "zone" };
    for (keys) |key| {
        if (record.getField(key)) |value| if (value.asText()) |text| {
            if (safeTag(text)) append(record, stats, text);
        };
    }
}

fn deriveNetworkTags(record: *record_mod.Record, stats: *TagStats) void {
    if (record.network.source_address) |address| {
        if (isPrivateAddress(address)) append(record, stats, "private-source") else append(record, stats, "external-source");
    }
    if (record.network.protocol) |protocol| {
        if (std.mem.startsWith(u8, protocol, "HTTP/2")) append(record, stats, "http2")
        else if (std.mem.startsWith(u8, protocol, "HTTP/3")) append(record, stats, "http3");
    }
}

fn deriveMessageTags(record: *record_mod.Record, stats: *TagStats) void {
    const rules = [_]struct { needle: []const u8, tag: []const u8 }{
        .{ .needle = "timeout", .tag = "timeout" },
        .{ .needle = "retry", .tag = "retry" },
        .{ .needle = "certificate", .tag = "tls" },
        .{ .needle = "database", .tag = "database" },
        .{ .needle = "upstream", .tag = "upstream" },
        .{ .needle = "deploy", .tag = "deployment" },
        .{ .needle = "health", .tag = "health-check" },
    };
    for (rules) |rule| if (containsIgnoreCase(record.message, rule.needle)) append(record, stats, rule.tag);
}

pub fn safeTag(input: []const u8) bool {
    if (input.len == 0 or input.len > 64) return false;
    for (input) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '/')) return false;
    return true;
}

pub fn isPrivateAddress(address: []const u8) bool {
    if (std.mem.startsWith(u8, address, "10.")) return true;
    if (std.mem.startsWith(u8, address, "192.168.")) return true;
    if (std.mem.startsWith(u8, address, "127.")) return true;
    if (std.mem.startsWith(u8, address, "169.254.")) return true;
    if (std.mem.startsWith(u8, address, "fc") or std.mem.startsWith(u8, address, "fd") or std.mem.eql(u8, address, "::1")) return true;
    if (std.mem.startsWith(u8, address, "172.")) {
        const rest = address[4..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        const second = std.fmt.parseInt(u8, rest[0..dot], 10) catch return false;
        return second >= 16 and second <= 31;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    return false;
}

test "tags derive HTTP status class and severity" {
    var record = record_mod.Record.init(.access_log);
    record.network.status = 503;
    record.severity = .error;
    _ = normalizeRecord(&record);
    try std.testing.expect(record.hasTag("http-5xx"));
    try std.testing.expect(record.hasTag("needs-attention"));
}
