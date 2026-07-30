const std = @import("std");

pub const version = "0.1.0";
pub const tested_zig_version = "0.13.0";

pub const model = struct {
    pub const value = @import("model/value.zig");
    pub const field = @import("model/field.zig");
    pub const source_info = @import("model/source_info.zig");
    pub const record = @import("model/record.zig");
};

pub const input = struct {
    pub const detector = @import("input/detector.zig");
    pub const stream_reader = @import("input/stream_reader.zig");
    pub const line_cursor = @import("input/line_cursor.zig");
    pub const file_loader = @import("input/file_loader.zig");
};

pub const parsing = struct {
    pub const common = @import("parsing/common.zig");
    pub const syslog = @import("parsing/syslog.zig");
    pub const jsonl = @import("parsing/jsonl.zig");
    pub const csv = @import("parsing/csv.zig");
    pub const ini = @import("parsing/ini.zig");
    pub const access_log = @import("parsing/access_log.zig");
    pub const dns_zone = @import("parsing/dns_zone.zig");
    pub const env_file = @import("parsing/env_file.zig");
    pub const manifest = @import("parsing/manifest.zig");
    pub const dispatcher = @import("parsing/dispatcher.zig");
};

pub const normalization = struct {
    pub const timestamp = @import("normalization/timestamp.zig");
    pub const severity = @import("normalization/severity.zig");
    pub const coercion = @import("normalization/coercion.zig");
    pub const attribution = @import("normalization/attribution.zig");
    pub const tags = @import("normalization/tags.zig");
    pub const network = @import("normalization/network.zig");
    pub const pipeline = @import("normalization/pipeline.zig");
};

pub const validation = struct {
    pub const schema = @import("validation/schema.zig");
    pub const finding = @import("validation/finding.zig");
    pub const rules = @import("validation/rules.zig");
    pub const report = @import("validation/report.zig");
    pub const policy = @import("validation/policy.zig");
    pub const drift = @import("validation/drift.zig");
};

pub const processing = struct {
    pub const duplicate = @import("processing/duplicate.zig");
    pub const correlation = @import("processing/correlation.zig");
    pub const query_token = @import("processing/query_token.zig");
    pub const query_parser = @import("processing/query_parser.zig");
    pub const query_eval = @import("processing/query_eval.zig");
    pub const aggregation = @import("processing/aggregation.zig");
    pub const ordering = @import("processing/ordering.zig");
    pub const batch = @import("processing/batch.zig");
    pub const projection = @import("processing/projection.zig");
    pub const time_window = @import("processing/time_window.zig");
    pub const inventory = @import("processing/inventory.zig");
    pub const redaction = @import("processing/redaction.zig");
    pub const field_stats = @import("processing/field_stats.zig");
    pub const sampling = @import("processing/sampling.zig");
    pub const route_metrics = @import("processing/route_metrics.zig");
};

pub const exporting = struct {
    pub const json = @import("export/json.zig");
    pub const csv = @import("export/csv.zig");
    pub const text = @import("export/text.zig");
};

pub const diagnostics = struct {
    pub const diagnostic = @import("diagnostics/diagnostic.zig");
    pub const formatter = @import("diagnostics/formatter.zig");
    pub const summary = @import("diagnostics/summary.zig");
    pub const health = @import("diagnostics/health.zig");
};

pub const workflow = struct {
    pub const session = @import("workflow/session.zig");
    pub const mixed_ingest = @import("workflow/mixed_ingest.zig");
    pub const reporting = @import("workflow/reporting.zig");
    pub const audit = @import("workflow/audit.zig");
    pub const config_audit = @import("workflow/config_audit.zig");
};

pub const cli = struct {
    pub const options = @import("cli/options.zig");
    pub const commands = @import("cli/commands.zig");
    pub const dispatcher = @import("cli/dispatcher.zig");
};

pub const SourceFormat = model.source_info.SourceFormat;
pub const Record = model.record.Record;
pub const OwnedRecord = model.record.OwnedRecord;
pub const ParseContext = parsing.common.ParseContext;
pub const ParseError = parsing.common.ParseError;

pub fn detect(path: ?[]const u8, input_bytes: []const u8) input.detector.Detection {
    return input.detector.detect(path, input_bytes);
}

pub fn parseRecord(input_bytes: []const u8, format: SourceFormat, context: ParseContext) ParseError!parsing.dispatcher.DispatchResult {
    return parsing.dispatcher.parse(input_bytes, format, context);
}

pub fn normalizeRecord(record: *Record) normalization.pipeline.Result {
    return normalization.pipeline.normalize(record, .{});
}

pub fn parseBatch(allocator: std.mem.Allocator, input_bytes: []const u8, path: ?[]const u8, options: processing.batch.BatchOptions) !processing.batch.ParsedBatch {
    return processing.batch.parseInput(allocator, input_bytes, path, options);
}

test "public API detects, parses, and normalizes an event" {
    const input_bytes = "{\"timestamp\":\"2026-07-30T07:00:00Z\",\"severity\":\"warn\",\"service\":\"edge\",\"message\":\"retry\"}";
    const decision = detect("event.jsonl", input_bytes);
    try std.testing.expectEqual(SourceFormat.jsonl, decision.format);
    var parsed = try parseRecord(input_bytes, .jsonl, .{ .path = "event.jsonl" });
    _ = normalizeRecord(&parsed.record);
    try std.testing.expectEqual(model.record.Severity.warning, parsed.record.severity);
}
