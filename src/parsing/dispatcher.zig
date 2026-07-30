const record_mod = @import("../model/record.zig");
const source_mod = @import("../model/source_info.zig");
const common = @import("common.zig");
const detector = @import("../input/detector.zig");
const syslog = @import("syslog.zig");
const jsonl = @import("jsonl.zig");
const csv = @import("csv.zig");
const ini = @import("ini.zig");
const access_log = @import("access_log.zig");
const dns_zone = @import("dns_zone.zig");
const env_file = @import("env_file.zig");
const manifest = @import("manifest.zig");

pub const DispatchResult = struct {
    format: source_mod.SourceFormat,
    confidence: u8,
    record: record_mod.Record,
};

pub fn parse(input: []const u8, requested: source_mod.SourceFormat, context: common.ParseContext) common.ParseError!DispatchResult {
    const decision = if (requested == .unknown) detector.detect(context.path, input) else detector.Detection{
        .format = requested,
        .confidence = 100,
        .reason = "explicit format",
    };
    if (decision.format == .unknown) return error.UnsupportedFormat;
    const record = switch (decision.format) {
        .syslog, .rfc5424 => try syslog.parse(input, context),
        .jsonl => try jsonl.parse(input, context),
        .csv => try csv.parse(input, context),
        .ini => try ini.parse(input, context),
        .access_log => try access_log.parse(input, context),
        .dns_zone => try dns_zone.parse(input, context),
        .env_file => try env_file.parse(input, context),
        .manifest => try manifest.parse(input, context),
        .unknown => return error.UnsupportedFormat,
    };
    return .{ .format = decision.format, .confidence = decision.confidence, .record = record };
}

pub fn isLineOriented(format: source_mod.SourceFormat) bool {
    return switch (format) {
        .syslog, .rfc5424, .jsonl, .access_log => true,
        else => false,
    };
}

pub fn parserName(format: source_mod.SourceFormat) []const u8 {
    return switch (format) {
        .syslog, .rfc5424 => "syslog parser",
        .jsonl => "JSON Lines parser",
        .csv => "CSV parser",
        .ini => "INI parser",
        .access_log => "HTTP access-log parser",
        .dns_zone => "DNS zone parser",
        .env_file => "environment-file parser",
        .manifest => "safe manifest parser",
        .unknown => "automatic detector",
    };
}

test "dispatcher reaches explicit parser" {
    const result = try parse("HOST=edge-1\nSERVICE=api\n", .env_file, .{});
    try @import("std").testing.expectEqual(source_mod.SourceFormat.env_file, result.format);
}
