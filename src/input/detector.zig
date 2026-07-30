const std = @import("std");
const source_mod = @import("../model/source_info.zig");

pub const Detection = struct {
    format: source_mod.SourceFormat,
    confidence: u8,
    reason: []const u8,
};

pub fn detect(path: ?[]const u8, sample_raw: []const u8) Detection {
    const sample = trimBomAndSpace(sample_raw);
    if (sample.len == 0) return .{ .format = .unknown, .confidence = 0, .reason = "empty input" };

    const content = detectFromContent(sample);
    if (content.confidence >= 80) return content;

    if (path) |p| {
        const hint = source_mod.extensionHint(p);
        if (hint != .unknown) {
            return .{ .format = hint, .confidence = @max(content.confidence, 70), .reason = "file extension and content hint" };
        }
        if (std.mem.endsWith(u8, p, "access.log")) return .{ .format = .access_log, .confidence = 75, .reason = "conventional access-log path" };
        if (std.mem.endsWith(u8, p, "syslog") or std.mem.endsWith(u8, p, "messages")) return .{ .format = .syslog, .confidence = 75, .reason = "conventional syslog path" };
    }

    return content;
}

pub fn detectFromContent(sample: []const u8) Detection {
    if (looksLikeRfc5424(sample)) return .{ .format = .rfc5424, .confidence = 98, .reason = "RFC5424 priority and version prefix" };
    if (looksLikeJsonLine(sample)) return .{ .format = .jsonl, .confidence = 96, .reason = "top-level JSON object per line" };
    if (looksLikeAccessLog(sample)) return .{ .format = .access_log, .confidence = 92, .reason = "combined HTTP access-log fields" };
    if (looksLikeClassicSyslog(sample)) return .{ .format = .syslog, .confidence = 88, .reason = "classic syslog timestamp and host" };
    if (looksLikeDnsZone(sample)) return .{ .format = .dns_zone, .confidence = 86, .reason = "DNS record class and type" };
    if (looksLikeIni(sample)) return .{ .format = .ini, .confidence = 84, .reason = "INI section and assignment syntax" };
    if (looksLikeEnv(sample)) return .{ .format = .env_file, .confidence = 82, .reason = "environment variable assignments" };
    if (looksLikeManifest(sample)) return .{ .format = .manifest, .confidence = 78, .reason = "indented deployment mapping" };
    if (looksLikeCsv(sample)) return .{ .format = .csv, .confidence = 72, .reason = "consistent comma-delimited columns" };
    return .{ .format = .unknown, .confidence = 20, .reason = "no distinctive syntax" };
}

fn trimBomAndSpace(input: []const u8) []const u8 {
    var result = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.startsWith(u8, result, "\xef\xbb\xbf")) result = result[3..];
    return result;
}

fn firstMeaningfulLine(input: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        return line;
    }
    return "";
}

fn looksLikeRfc5424(input: []const u8) bool {
    const line = firstMeaningfulLine(input);
    if (line.len < 5 or line[0] != '<') return false;
    const close = std.mem.indexOfScalar(u8, line, '>') orelse return false;
    if (close < 2 or close > 4 or close + 2 >= line.len) return false;
    _ = std.fmt.parseInt(u8, line[1..close], 10) catch return false;
    return std.ascii.isDigit(line[close + 1]) and line[close + 2] == ' ';
}

fn looksLikeJsonLine(input: []const u8) bool {
    const line = firstMeaningfulLine(input);
    if (line.len < 2 or line[0] != '{' or line[line.len - 1] != '}') return false;
    return std.mem.indexOfScalar(u8, line, ':') != null;
}

fn looksLikeAccessLog(input: []const u8) bool {
    const line = firstMeaningfulLine(input);
    return std.mem.indexOf(u8, line, " HTTP/") != null and
        std.mem.indexOf(u8, line, "] \"") != null and
        countByte(line, '"') >= 4;
}

fn looksLikeClassicSyslog(input: []const u8) bool {
    const line = firstMeaningfulLine(input);
    if (line.len < 16) return false;
    const month = line[0..3];
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (months) |candidate| if (std.mem.eql(u8, month, candidate)) return line[3] == ' ';
    return false;
}

fn looksLikeDnsZone(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;
        if (std.mem.startsWith(u8, line, "$ORIGIN") or std.mem.startsWith(u8, line, "$TTL")) return true;
        if (std.mem.indexOf(u8, line, " IN A ") != null or std.mem.indexOf(u8, line, " IN AAAA ") != null or std.mem.indexOf(u8, line, " IN CNAME ") != null) return true;
    }
    return false;
}

fn looksLikeIni(input: []const u8) bool {
    const line = firstMeaningfulLine(input);
    return line.len >= 3 and line[0] == '[' and line[line.len - 1] == ']';
}

fn looksLikeEnv(input: []const u8) bool {
    const line = firstMeaningfulLine(input);
    const equal = std.mem.indexOfScalar(u8, line, '=') orelse return false;
    if (equal == 0) return false;
    for (line[0..equal]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

fn looksLikeManifest(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var mappings: usize = 0;
    var indented: usize = 0;
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, " \t\r");
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, trimmed, ':') != null) mappings += 1;
        if (line.len > trimmed.len) indented += 1;
    }
    return mappings >= 2 and indented >= 1;
}

fn looksLikeCsv(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    const first = lines.next() orelse return false;
    const second = lines.next() orelse return false;
    const a = countByte(first, ',');
    const b = countByte(second, ',');
    return a >= 1 and a == b;
}

fn countByte(input: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (input) |ch| if (ch == needle) count += 1;
    return count;
}

test "content detection prioritizes distinctive formats" {
    try std.testing.expectEqual(source_mod.SourceFormat.rfc5424, detect(null, "<34>1 2026-07-30T10:00:00Z edge app 7 ID47 - ready").format);
    try std.testing.expectEqual(source_mod.SourceFormat.env_file, detect(null, "EDGE_PORT=8443\nMODE=active").format);
}
