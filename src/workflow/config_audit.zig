const std = @import("std");
const record_mod = @import("../model/record.zig");
const value_mod = @import("../model/value.zig");

pub const Requirement = struct {
    key: []const u8,
    expected_kind: ?value_mod.ValueKind = null,
    allow_null: bool = false,
    description: []const u8 = "",
};

pub const Requirements = struct {
    entries: [64]Requirement = undefined,
    count: usize = 0,

    pub fn append(self: *Requirements, requirement: Requirement) !void {
        if (self.count >= self.entries.len) return error.TooManyRequirements;
        if (requirement.key.len == 0) return error.InvalidRequirement;
        for (self.entries[0..self.count]) |existing| { if (canonicalEqual(existing.key, requirement.key)) return error.DuplicateRequirement; }
        self.entries[self.count] = requirement;
        self.count += 1;
    }

    pub fn slice(self: *const Requirements) []const Requirement {
        return self.entries[0..self.count];
    }
};

pub const FindingCode = enum {
    missing_required,
    incompatible_kind,
    conflicting_value,
    sensitive_name,
    empty_value,
    invalid_endpoint,
    non_config_record,
    duplicate_equivalent,
};

pub const Severity = enum { note, warning, @"error" };

pub const Finding = struct {
    severity: Severity,
    code: FindingCode,
    key: []const u8,
    source_a: ?[]const u8 = null,
    source_b: ?[]const u8 = null,
    message: []const u8,
};

pub const Report = struct {
    findings: [256]Finding = undefined,
    count: usize = 0,
    overflow: usize = 0,
    config_records: usize = 0,
    non_config_records: usize = 0,
    fields_examined: usize = 0,
    required_checked: usize = 0,

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
        var count: usize = 0;
        for (self.slice()) |finding| if (finding.severity == .@"error") {
            count += 1;
        };
        return count;
    }

    pub fn warningCount(self: *const Report) usize {
        var count: usize = 0;
        for (self.slice()) |finding| if (finding.severity == .warning) {
            count += 1;
        };
        return count;
    }
};

pub const Options = struct {
    warn_sensitive_names: bool = true,
    reject_empty_required: bool = true,
    inspect_endpoints: bool = true,
    report_equivalent_duplicates: bool = false,
    non_config_is_error: bool = false,
};

pub fn serviceRequirements() Requirements {
    var requirements = Requirements{};
    requirements.append(.{ .key = "service", .expected_kind = .text, .description = "logical service name" }) catch {};
    requirements.append(.{ .key = "environment", .expected_kind = .text, .description = "deployment environment" }) catch {};
    requirements.append(.{ .key = "host", .expected_kind = .text, .description = "service host identity" }) catch {};
    return requirements;
}

pub fn audit(records: []const record_mod.Record, requirements: *const Requirements, options: Options) Report {
    var report = Report{};
    for (records) |*record| {
        if (!isConfigFormat(record.source.format)) {
            report.non_config_records += 1;
            report.append(.{
                .severity = if (options.non_config_is_error) .@"error" else .note,
                .code = .non_config_record,
                .key = record.source.format.label(),
                .source_a = record.source.path,
                .message = "record is not an INI, environment, or manifest configuration",
            });
            continue;
        }
        report.config_records += 1;
        inspectFields(&report, record, options);
    }
    inspectRequirements(&report, records, requirements, options);
    inspectCrossRecordConflicts(&report, records, options);
    sortFindings(report.findings[0..report.count]);
    return report;
}

fn inspectFields(report: *Report, record: *const record_mod.Record, options: Options) void {
    for (record.fieldSlice()) |field| {
        report.fields_examined += 1;
        if (options.warn_sensitive_names and sensitiveName(field.key)) report.append(.{
            .severity = .warning,
            .code = .sensitive_name,
            .key = field.key,
            .source_a = record.source.path,
            .message = "configuration key appears to carry credential material",
        });
        if (isEmpty(field.value)) report.append(.{
            .severity = .note,
            .code = .empty_value,
            .key = field.key,
            .source_a = record.source.path,
            .message = "configuration value is empty or null",
        });
        if (options.inspect_endpoints and endpointLikeKey(field.key)) {
            if (field.value.asText()) |text| {
                if (!validEndpoint(text)) report.append(.{
                    .severity = .warning,
                    .code = .invalid_endpoint,
                    .key = field.key,
                    .source_a = record.source.path,
                    .message = "endpoint-like value does not match the supported offline syntax check",
                });
            }
        }
    }
}

fn inspectRequirements(report: *Report, records: []const record_mod.Record, requirements: *const Requirements, options: Options) void {
    for (requirements.slice()) |requirement| {
        report.required_checked += 1;
        var found = false;
        for (records) |*record| {
            if (!isConfigFormat(record.source.format)) continue;
            const value = findCanonical(record, requirement.key) orelse continue;
            found = true;
            if (requirement.expected_kind) |expected| {
                if (!kindCompatible(value, expected)) report.append(.{
                    .severity = .@"error",
                    .code = .incompatible_kind,
                    .key = requirement.key,
                    .source_a = record.source.path,
                    .message = "required configuration value has an incompatible scalar kind",
                });
            }
            if (!requirement.allow_null and value.kind() == .null_value) report.append(.{
                .severity = .@"error",
                .code = .incompatible_kind,
                .key = requirement.key,
                .source_a = record.source.path,
                .message = "required configuration value is null",
            });
            if (options.reject_empty_required and isEmpty(value)) report.append(.{
                .severity = .@"error",
                .code = .empty_value,
                .key = requirement.key,
                .source_a = record.source.path,
                .message = "required configuration value is empty",
            });
        }
        if (!found) report.append(.{
            .severity = .@"error",
            .code = .missing_required,
            .key = requirement.key,
            .message = requirement.description,
        });
    }
}

fn inspectCrossRecordConflicts(report: *Report, records: []const record_mod.Record, options: Options) void {
    var left_record_index: usize = 0;
    while (left_record_index < records.len) : (left_record_index += 1) {
        const left_record = &records[left_record_index];
        if (!isConfigFormat(left_record.source.format)) continue;
        for (left_record.fieldSlice()) |left_field| {
            var right_record_index = left_record_index + 1;
            while (right_record_index < records.len) : (right_record_index += 1) {
                const right_record = &records[right_record_index];
                if (!isConfigFormat(right_record.source.format)) continue;
                const right_value = findCanonical(right_record, left_field.key) orelse continue;
                if (valuesEquivalent(left_field.value, right_value)) {
                    if (options.report_equivalent_duplicates) report.append(.{
                        .severity = .note,
                        .code = .duplicate_equivalent,
                        .key = left_field.key,
                        .source_a = left_record.source.path,
                        .source_b = right_record.source.path,
                        .message = "equivalent configuration values are repeated across sources",
                    });
                } else report.append(.{
                    .severity = .@"error",
                    .code = .conflicting_value,
                    .key = left_field.key,
                    .source_a = left_record.source.path,
                    .source_b = right_record.source.path,
                    .message = "canonical configuration key has conflicting values across sources",
                });
            }
        }
    }
}

pub fn writeText(report: *const Report, writer: anytype) !void {
    try writer.print("config_records={d} non_config_records={d} fields_examined={d} required_checked={d}\n", .{
        report.config_records,
        report.non_config_records,
        report.fields_examined,
        report.required_checked,
    });
    for (report.slice()) |finding| {
        try writer.print("{s} {s} key={s}", .{ @tagName(finding.severity), @tagName(finding.code), finding.key });
        if (finding.source_a) |source| try writer.print(" source={s}", .{source});
        if (finding.source_b) |source| try writer.print(" compared_with={s}", .{source});
        if (finding.message.len != 0) try writer.print(" message={s}", .{finding.message});
        try writer.writeByte('\n');
    }
    if (report.overflow != 0) try writer.print("warning finding_overflow count={d}\n", .{report.overflow});
}

pub fn canonicalEqual(left: []const u8, right: []const u8) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (true) {
        skipSeparators(left, &left_index);
        skipSeparators(right, &right_index);
        if (left_index >= left.len or right_index >= right.len) return left_index >= left.len and right_index >= right.len;
        if (std.ascii.toLower(left[left_index]) != std.ascii.toLower(right[right_index])) return false;
        left_index += 1;
        right_index += 1;
    }
}

pub fn findCanonical(record: *const record_mod.Record, key: []const u8) ?value_mod.Value {
    if (coreValue(record, key)) |value| return value;
    for (record.fieldSlice()) |field| { if (canonicalEqual(field.key, key)) return field.value; }
    return null;
}

pub fn validEndpoint(input_raw: []const u8) bool {
    const input = std.mem.trim(u8, input_raw, " \t\r\n");
    if (input.len == 0 or std.mem.indexOfAny(u8, input, " \t\r\n") != null) return false;
    if (std.mem.indexOf(u8, input, "://")) |scheme_end| {
        if (scheme_end == 0 or scheme_end + 3 >= input.len) return false;
        for (input[0..scheme_end]) |character| { if (!(std.ascii.isAlphanumeric(character) or character == '+' or character == '-' or character == '.')) return false; }
        return hostPortValid(input[scheme_end + 3 ..]);
    }
    return hostPortValid(input);
}

fn coreValue(record: *const record_mod.Record, key: []const u8) ?value_mod.Value {
    if (canonicalEqual(key, "service")) if (record.service) |value| return .{ .text = value };
    if (canonicalEqual(key, "host")) if (record.host) |value| return .{ .text = value };
    if (canonicalEqual(key, "environment")) {
        if (record.getField("environment")) |value| return value;
        if (record.getField("env")) |value| return value;
    }
    return null;
}

fn hostPortValid(input: []const u8) bool {
    if (input.len == 0) return false;
    const path_index = std.mem.indexOfScalar(u8, input, '/') orelse input.len;
    const authority = input[0..path_index];
    if (authority.len == 0) return false;
    if (authority[0] == '[') {
        const closing = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        if (closing <= 1) return false;
        if (closing + 1 == authority.len) return true;
        return authority[closing + 1] == ':' and validPort(authority[closing + 2 ..]);
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |index| authority[0..index] else authority;
    if (host.len == 0) return false;
    for (host) |character| { if (!(std.ascii.isAlphanumeric(character) or character == '.' or character == '-' or character == '_')) return false; }
    if (colon) |index| return validPort(authority[index + 1 ..]);
    return true;
}

fn validPort(input: []const u8) bool {
    if (input.len == 0 or input.len > 5) return false;
    const port = std.fmt.parseInt(u16, input, 10) catch return false;
    return port != 0;
}

fn valuesEquivalent(left: value_mod.Value, right: value_mod.Value) bool {
    if (left.eql(right)) return true;
    if (left.asDecimal()) |left_number| if (right.asDecimal()) |right_number| return left_number == right_number;
    if (left.asText()) |left_text| if (right.asText()) |right_text| return std.mem.eql(u8, std.mem.trim(u8, left_text, " \t\r\n"), std.mem.trim(u8, right_text, " \t\r\n"));
    return false;
}

fn kindCompatible(value: value_mod.Value, expected: value_mod.ValueKind) bool {
    if (value.kind() == expected) return true;
    return expected == .decimal and value.kind() == .integer;
}

fn isEmpty(value: value_mod.Value) bool {
    return switch (value) {
        .text => |text| std.mem.trim(u8, text, " \t\r\n").len == 0,
        .null_value => true,
        else => false,
    };
}

fn sensitiveName(key: []const u8) bool {
    const patterns = [_][]const u8{ "password", "secret", "token", "credential", "privatekey", "apikey" };
    for (patterns) |pattern| { if (canonicalContains(key, pattern)) return true; }
    return false;
}

fn endpointLikeKey(key: []const u8) bool {
    const suffixes = [_][]const u8{ "url", "uri", "endpoint", "host", "address" };
    for (suffixes) |suffix| { if (canonicalEndsWith(key, suffix)) return true; }
    return false;
}

fn canonicalContains(input: []const u8, needle: []const u8) bool {
    var compact: [256]u8 = undefined;
    const length = compactCanonical(input, &compact);
    if (length == compact.len and input.len > compact.len) return false;
    return std.mem.indexOf(u8, compact[0..length], needle) != null;
}

fn canonicalEndsWith(input: []const u8, suffix: []const u8) bool {
    var compact: [256]u8 = undefined;
    const length = compactCanonical(input, &compact);
    if (length < suffix.len) return false;
    return std.mem.eql(u8, compact[length - suffix.len .. length], suffix);
}

fn compactCanonical(input: []const u8, output: []u8) usize {
    var count: usize = 0;
    for (input) |character| {
        if (separator(character)) continue;
        if (count >= output.len) return output.len;
        output[count] = std.ascii.toLower(character);
        count += 1;
    }
    return count;
}

fn skipSeparators(input: []const u8, index: *usize) void {
    while (index.* < input.len and separator(input[index.*])) index.* += 1;
}

fn separator(character: u8) bool {
    return character == '_' or character == '-' or character == '.' or character == ' ';
}

fn isConfigFormat(format: record_mod.SourceFormat) bool {
    return format == .ini or format == .env_file or format == .manifest;
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
    const key_order = std.mem.order(u8, left.key, right.key);
    if (key_order != .eq) return key_order == .lt;
    return @intFromEnum(left.code) < @intFromEnum(right.code);
}

test "configuration audit detects cross-format conflicts" {
    var ini = record_mod.Record.init(.ini);
    ini.source.path = "service.ini";
    ini.service = "checkout";
    ini.host = "checkout.internal";
    try ini.addField("environment", .{ .text = "prod" });
    try ini.addField("database-url", .{ .text = "postgres://db.internal:5432/app" });

    var env = record_mod.Record.init(.env_file);
    env.source.path = "service.env";
    env.service = "checkout";
    env.host = "checkout.internal";
    try env.addField("ENVIRONMENT", .{ .text = "staging" });
    try env.addField("API_TOKEN", .{ .text = "example" });

    const requirements = serviceRequirements();
    const report = audit(&.{ ini, env }, &requirements, .{});
    try std.testing.expect(report.errorCount() >= 1);
    try std.testing.expect(report.warningCount() >= 1);
}

test "canonical key and endpoint checks are bounded" {
    try std.testing.expect(canonicalEqual("DATABASE_URL", "database-url"));
    try std.testing.expect(validEndpoint("https://api.internal:8443/v1"));
    try std.testing.expect(validEndpoint("[2001:db8::1]:443"));
    try std.testing.expect(!validEndpoint("https:// bad.example"));
}
