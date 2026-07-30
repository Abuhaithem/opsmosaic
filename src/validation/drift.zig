const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");
const query_eval = @import("../processing/query_eval.zig");

pub const KindMask = struct {
    bits: u8 = 0,

    pub fn observe(self: *KindMask, kind: value_mod.ValueKind) void {
        self.bits |= @as(u8, 1) << @intCast(@intFromEnum(kind));
    }

    pub fn contains(self: KindMask, kind: value_mod.ValueKind) bool {
        return (self.bits & (@as(u8, 1) << @intCast(@intFromEnum(kind)))) != 0;
    }

    pub fn overlaps(self: KindMask, other: KindMask) bool {
        return (self.bits & other.bits) != 0;
    }

    pub fn count(self: KindMask) usize {
        return @popCount(self.bits);
    }

    pub fn write(self: KindMask, writer: anytype) !void {
        var first = true;
        const kinds = [_]value_mod.ValueKind{ .text, .integer, .decimal, .boolean, .null_value };
        for (kinds) |kind| {
            if (!self.contains(kind)) continue;
            if (!first) try writer.writeByte('|');
            first = false;
            try writer.writeAll(@tagName(kind));
        }
        if (first) try writer.writeAll("none");
    }
};

pub const FieldShape = struct {
    key: []const u8,
    records_seen: usize = 0,
    values_seen: usize = 0,
    null_values: usize = 0,
    kinds: KindMask = .{},
    minimum_number: ?f64 = null,
    maximum_number: ?f64 = null,
    maximum_text_bytes: usize = 0,

    pub fn observe(self: *FieldShape, value: value_mod.Value) void {
        self.values_seen += 1;
        self.kinds.observe(value.kind());
        switch (value) {
            .null_value => self.null_values += 1,
            .text => |text| self.maximum_text_bytes = @max(self.maximum_text_bytes, text.len),
            .integer => |integer| self.observeNumber(@floatFromInt(integer)),
            .decimal => |decimal| self.observeNumber(decimal),
            .boolean => {},
        }
    }

    fn observeNumber(self: *FieldShape, number: f64) void {
        if (!std.math.isFinite(number)) return;
        self.minimum_number = if (self.minimum_number) |current| @min(current, number) else number;
        self.maximum_number = if (self.maximum_number) |current| @max(current, number) else number;
    }

    pub fn coverage(self: FieldShape, record_count: usize) f64 {
        if (record_count == 0) return 0;
        return @as(f64, @floatFromInt(self.records_seen)) / @as(f64, @floatFromInt(record_count));
    }

    pub fn nullRate(self: FieldShape) f64 {
        if (self.values_seen == 0) return 0;
        return @as(f64, @floatFromInt(self.null_values)) / @as(f64, @floatFromInt(self.values_seen));
    }
};

pub const Snapshot = struct {
    record_count: usize = 0,
    fields: [256]FieldShape = undefined,
    field_count: usize = 0,
    overflow_fields: usize = 0,

    pub fn observe(self: *Snapshot, record: *const record_mod.Record) void {
        self.record_count += 1;
        const core_names = [_][]const u8{
            "timestamp", "severity", "host", "service", "process_id", "event_id",
            "request_id", "trace_id", "message", "source_format", "source_address",
            "destination_address", "method", "path", "status", "bytes",
        };
        for (core_names) |name| { if (query_eval.fieldValue(record, name)) |value| self.observeField(name, value); }
        for (record.fieldSlice()) |field| self.observeField(field.key, field.value);
    }

    pub fn find(self: *const Snapshot, key: []const u8) ?*const FieldShape {
        for (self.fields[0..self.field_count]) |*field| { if (std.mem.eql(u8, field.key, key)) return field; }
        return null;
    }

    pub fn slice(self: *const Snapshot) []const FieldShape {
        return self.fields[0..self.field_count];
    }

    fn observeField(self: *Snapshot, key: []const u8, value: value_mod.Value) void {
        for (self.fields[0..self.field_count]) |*field| {
            if (!std.mem.eql(u8, field.key, key)) continue;
            if (field.records_seen < self.record_count) field.records_seen += 1;
            field.observe(value);
            return;
        }
        if (self.field_count >= self.fields.len) {
            self.overflow_fields += 1;
            return;
        }
        self.fields[self.field_count] = .{ .key = key, .records_seen = 1 };
        self.fields[self.field_count].observe(value);
        self.field_count += 1;
    }
};

pub const ChangeCode = enum {
    field_added,
    field_removed,
    kind_changed,
    coverage_decreased,
    coverage_increased,
    null_rate_increased,
    numeric_range_expanded,
    text_width_expanded,
};

pub const Severity = enum { note, warning, @"error" };

pub const Finding = struct {
    severity: Severity,
    code: ChangeCode,
    field: []const u8,
    baseline_value: f64 = 0,
    current_value: f64 = 0,
    baseline_kinds: KindMask = .{},
    current_kinds: KindMask = .{},
};

pub const Options = struct {
    coverage_delta: f64 = 0.20,
    null_rate_delta: f64 = 0.20,
    numeric_expansion_ratio: f64 = 2.0,
    text_width_growth: usize = 256,
    added_field_severity: Severity = .note,
    removed_field_severity: Severity = .warning,
    incompatible_kind_severity: Severity = .@"error",
};

pub const Report = struct {
    findings: [256]Finding = undefined,
    count: usize = 0,
    overflow: usize = 0,

    pub fn append(self: *Report, finding: Finding) void {
        if (self.count >= self.findings.len) {
            self.overflow += 1;
            return;
        }
        self.findings[self.count] = finding;
        self.count += 1;
    }

    pub fn slice(self: *const Report) []const Finding {
        return self.findings[0..self.count];
    }

    pub fn errorCount(self: *const Report) usize {
        var result: usize = 0;
        for (self.slice()) |finding| if (finding.severity == .@"error") {
            result += 1;
        };
        return result;
    }

    pub fn warningCount(self: *const Report) usize {
        var result: usize = 0;
        for (self.slice()) |finding| if (finding.severity == .warning) {
            result += 1;
        };
        return result;
    }
};

pub fn capture(records: []const record_mod.Record) Snapshot {
    var snapshot = Snapshot{};
    for (records) |*record| snapshot.observe(record);
    return snapshot;
}

pub fn compare(baseline: *const Snapshot, current: *const Snapshot, options: Options) Report {
    var report = Report{};
    for (baseline.slice()) |*before| {
        const after = current.find(before.key) orelse {
            report.append(.{ .severity = options.removed_field_severity, .code = .field_removed, .field = before.key });
            continue;
        };
        compareField(&report, before, after, baseline.record_count, current.record_count, options);
    }
    for (current.slice()) |*after| {
        if (baseline.find(after.key) == null) report.append(.{ .severity = options.added_field_severity, .code = .field_added, .field = after.key });
    }
    sortFindings(report.findings[0..report.count]);
    return report;
}

fn compareField(report: *Report, before: *const FieldShape, after: *const FieldShape, baseline_records: usize, current_records: usize, options: Options) void {
    if (!before.kinds.overlaps(after.kinds)) report.append(.{
        .severity = options.incompatible_kind_severity,
        .code = .kind_changed,
        .field = before.key,
        .baseline_kinds = before.kinds,
        .current_kinds = after.kinds,
    });

    const baseline_coverage = before.coverage(baseline_records);
    const current_coverage = after.coverage(current_records);
    if (baseline_coverage - current_coverage >= options.coverage_delta) report.append(.{
        .severity = .warning,
        .code = .coverage_decreased,
        .field = before.key,
        .baseline_value = baseline_coverage,
        .current_value = current_coverage,
    }) else if (current_coverage - baseline_coverage >= options.coverage_delta) report.append(.{
        .severity = .note,
        .code = .coverage_increased,
        .field = before.key,
        .baseline_value = baseline_coverage,
        .current_value = current_coverage,
    });

    const baseline_null_rate = before.nullRate();
    const current_null_rate = after.nullRate();
    if (current_null_rate - baseline_null_rate >= options.null_rate_delta) report.append(.{
        .severity = .warning,
        .code = .null_rate_increased,
        .field = before.key,
        .baseline_value = baseline_null_rate,
        .current_value = current_null_rate,
    });

    if (rangeExpanded(before, after, options.numeric_expansion_ratio)) report.append(.{
        .severity = .note,
        .code = .numeric_range_expanded,
        .field = before.key,
        .baseline_value = numericSpan(before),
        .current_value = numericSpan(after),
    });

    if (after.maximum_text_bytes > before.maximum_text_bytes +| options.text_width_growth) report.append(.{
        .severity = .note,
        .code = .text_width_expanded,
        .field = before.key,
        .baseline_value = @floatFromInt(before.maximum_text_bytes),
        .current_value = @floatFromInt(after.maximum_text_bytes),
    });
}

pub fn writeText(report: *const Report, writer: anytype) !void {
    for (report.slice()) |finding| {
        try writer.print("{s} {s} field={s}", .{ @tagName(finding.severity), @tagName(finding.code), finding.field });
        if (finding.code == .kind_changed) {
            try writer.writeAll(" baseline_kinds=");
            try finding.baseline_kinds.write(writer);
            try writer.writeAll(" current_kinds=");
            try finding.current_kinds.write(writer);
        } else if (finding.baseline_value != 0 or finding.current_value != 0) {
            try writer.print(" baseline={d:.4} current={d:.4}", .{ finding.baseline_value, finding.current_value });
        }
        try writer.writeByte('\n');
    }
    if (report.overflow != 0) try writer.print("warning drift_findings_overflow count={d}\n", .{report.overflow});
}

fn rangeExpanded(before: *const FieldShape, after: *const FieldShape, ratio: f64) bool {
    if (ratio <= 1.0) return false;
    const before_span = numericSpan(before);
    const after_span = numericSpan(after);
    if (before_span <= 0) return after_span > 0;
    return after_span > before_span * ratio;
}

fn numericSpan(field: *const FieldShape) f64 {
    if (field.minimum_number == null or field.maximum_number == null) return 0;
    return field.maximum_number.? - field.minimum_number.?;
}

fn sortFindings(findings: []Finding) void {
    var index: usize = 1;
    while (index < findings.len) : (index += 1) {
        const candidate = findings[index];
        var position = index;
        while (position > 0 and findingLess(candidate, findings[position - 1])) : (position -= 1) findings[position] = findings[position - 1];
        findings[position] = candidate;
    }
}

fn findingLess(left: Finding, right: Finding) bool {
    const field_order = std.mem.order(u8, left.field, right.field);
    if (field_order != .eq) return field_order == .lt;
    return @intFromEnum(left.code) < @intFromEnum(right.code);
}

test "drift report finds removed fields and incompatible kinds" {
    var baseline_records = [_]record_mod.Record{ record_mod.Record.init(.jsonl), record_mod.Record.init(.jsonl) };
    try baseline_records[0].addField("latency_ms", .{ .integer = 10 });
    try baseline_records[0].addField("region", .{ .text = "east" });
    try baseline_records[1].addField("latency_ms", .{ .integer = 20 });
    try baseline_records[1].addField("region", .{ .text = "west" });

    var current_records = [_]record_mod.Record{ record_mod.Record.init(.jsonl), record_mod.Record.init(.jsonl) };
    try current_records[0].addField("latency_ms", .{ .text = "slow" });
    try current_records[1].addField("new_field", .{ .boolean = true });

    const baseline = capture(&baseline_records);
    const current = capture(&current_records);
    const report = compare(&baseline, &current, .{});
    try std.testing.expect(report.errorCount() >= 1);
    try std.testing.expect(report.warningCount() >= 1);
}

test "drift report writer emits deterministic field order" {
    var report = Report{};
    report.append(.{ .severity = .warning, .code = .field_removed, .field = "zeta" });
    report.append(.{ .severity = .note, .code = .field_added, .field = "alpha" });
    sortFindings(report.findings[0..report.count]);
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try writeText(&report, output.writer());
    try std.testing.expect(std.mem.startsWith(u8, output.items, "note field_added field=alpha"));
}
