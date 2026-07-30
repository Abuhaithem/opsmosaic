const record_mod = @import("../model/record.zig");
const timestamp = @import("timestamp.zig");
const severity = @import("severity.zig");
const attribution = @import("attribution.zig");
const coercion = @import("coercion.zig");
const tags = @import("tags.zig");
const network = @import("network.zig");

pub const Options = struct {
    normalize_timestamp: bool = true,
    normalize_severity: bool = true,
    normalize_attribution: bool = true,
    coerce_fields: bool = true,
    derive_tags: bool = true,
    normalize_network: bool = true,
    coercion_policy: coercion.CoercionPolicy = .{},
};

pub const Report = struct {
    timestamp_present: bool = false,
    timestamp_normalized: bool = false,
    severity_result: severity.Result = .{ .severity = .unknown, .source = .default, .confidence = 0 },
    attribution_result: attribution.Attribution = .{},
    coercion_stats: coercion.CoercionStats = .{},
    tag_stats: tags.TagStats = .{},
    warning_count_before: usize = 0,
    warning_count_after: usize = 0,

    pub fn addedWarnings(self: Report) usize {
        return self.warning_count_after -| self.warning_count_before;
    }
};

pub fn normalize(record: *record_mod.Record, options: Options) Report {
    var report = Report{};
    report.warning_count_before = record.warnings.count;
    report.timestamp_present = record.timestamp_text != null;
    if (options.normalize_timestamp) {
        timestamp.normalizeRecord(record);
        report.timestamp_normalized = record.timestamp_unix_ns != null;
    }
    if (options.normalize_severity) report.severity_result = severity.normalizeRecord(record);
    if (options.normalize_attribution) report.attribution_result = attribution.normalizeRecord(record);
    if (options.coerce_fields) report.coercion_stats = coercion.normalizeRecord(record, options.coercion_policy);
    if (options.normalize_network) network.normalizeRecord(record);
    if (options.derive_tags) report.tag_stats = tags.normalizeRecord(record);
    report.warning_count_after = record.warnings.count;
    return report;
}

pub fn normalizeBatch(records: []record_mod.Record, options: Options) BatchReport {
    var result = BatchReport{};
    for (records) |*record| {
        const report = normalize(record, options);
        result.records += 1;
        if (report.timestamp_normalized) result.timestamps += 1;
        if (report.severity_result.severity != .unknown) result.severities += 1;
        if (record.host != null) result.hosts += 1;
        if (record.service != null) result.services += 1;
        result.coerced_values += report.coercion_stats.text_to_integer + report.coercion_stats.text_to_decimal + report.coercion_stats.text_to_boolean + report.coercion_stats.text_to_null;
        result.derived_tags += report.tag_stats.derived;
        result.warnings += report.addedWarnings();
    }
    return result;
}

pub const BatchReport = struct {
    records: usize = 0,
    timestamps: usize = 0,
    severities: usize = 0,
    hosts: usize = 0,
    services: usize = 0,
    coerced_values: usize = 0,
    derived_tags: usize = 0,
    warnings: usize = 0,

    pub fn timestampCoverage(self: BatchReport) f64 {
        if (self.records == 0) return 0;
        return @as(f64, @floatFromInt(self.timestamps)) / @as(f64, @floatFromInt(self.records));
    }

    pub fn serviceCoverage(self: BatchReport) f64 {
        if (self.records == 0) return 0;
        return @as(f64, @floatFromInt(self.services)) / @as(f64, @floatFromInt(self.records));
    }
};

test "normalization pipeline enriches parsed records" {
    var record = record_mod.Record.init(.jsonl);
    record.timestamp_text = "2026-07-30T07:00:00Z";
    record.message = "upstream timeout";
    record.network.status = 503;
    const report = normalize(&record, .{});
    try @import("std").testing.expect(report.timestamp_normalized);
    try @import("std").testing.expect(record.hasTag("http-5xx"));
}
