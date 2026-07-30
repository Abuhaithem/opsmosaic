const std = @import("std");
const record_mod = @import("../model/record.zig");
const finding_mod = @import("finding.zig");
const query_parser = @import("../processing/query_parser.zig");
const query_eval = @import("../processing/query_eval.zig");

pub const Action = enum { note, warn, reject, require_field, forbid_field, add_tag };

pub const Rule = struct {
    name: []const u8,
    description: []const u8,
    expression: []const u8,
    action: Action,
    argument: ?[]const u8 = null,
};

pub const CompiledRule = struct {
    definition: Rule,
    program: query_parser.Program,
};

pub const Policy = struct {
    rules: [64]CompiledRule = undefined,
    count: usize = 0,

    pub fn append(self: *Policy, rule: Rule) !void {
        if (self.count >= self.rules.len) return error.TooManyPolicyRules;
        if (rule.name.len == 0 or rule.expression.len == 0) return error.InvalidPolicyRule;
        if ((rule.action == .require_field or rule.action == .forbid_field or rule.action == .add_tag) and rule.argument == null) return error.MissingPolicyArgument;
        const program = try query_parser.parse(rule.expression, .{ .max_nodes = 128, .max_depth = 24, .max_token_bytes = 1024 });
        self.rules[self.count] = .{ .definition = rule, .program = program };
        self.count += 1;
    }

    pub fn slice(self: *const Policy) []const CompiledRule {
        return self.rules[0..self.count];
    }
};

pub const Result = struct {
    findings: finding_mod.FindingBuffer = .{},
    matched_rules: usize = 0,
    added_tags: usize = 0,
    evaluation_errors: usize = 0,
};

pub fn apply(policy: *const Policy, record: *record_mod.Record) Result {
    var result = Result{};
    for (policy.slice()) |*compiled| {
        const matched = query_eval.evaluate(&compiled.program, record, .{}) catch {
            result.evaluation_errors += 1;
            continue;
        };
        if (!matched) continue;
        result.matched_rules += 1;
        const rule = compiled.definition;
        switch (rule.action) {
            .note => appendFinding(&result.findings, .information, rule, record.source.line, rule.description),
            .warn => appendFinding(&result.findings, .warning, rule, record.source.line, rule.description),
            .reject => appendFinding(&result.findings, .@"error", rule, record.source.line, rule.description),
            .require_field => {
                const field = rule.argument.?;
                if (record.getField(field) == null) appendFieldFinding(&result.findings, .@"error", rule, field, record.source.line, "policy requires a missing field");
            },
            .forbid_field => {
                const field = rule.argument.?;
                if (record.getField(field) != null) appendFieldFinding(&result.findings, .@"error", rule, field, record.source.line, "policy forbids a present field");
            },
            .add_tag => {
                record.addTag(rule.argument.?) catch {
                    appendFinding(&result.findings, .warning, rule, record.source.line, "policy tag could not be added because the tag limit was reached");
                    continue;
                };
                result.added_tags += 1;
            },
        }
    }
    return result;
}

fn appendFinding(buffer: *finding_mod.FindingBuffer, level: finding_mod.Level, rule: Rule, line: usize, message: []const u8) void {
    buffer.append(.{ .level = level, .rule = rule.name, .line = line, .message = message });
}

fn appendFieldFinding(buffer: *finding_mod.FindingBuffer, level: finding_mod.Level, rule: Rule, field: []const u8, line: usize, message: []const u8) void {
    buffer.append(.{ .level = level, .rule = rule.name, .field = field, .line = line, .message = message });
}

pub fn operationalBaseline() !Policy {
    var policy = Policy{};
    try policy.append(.{
        .name = "prod.error-trace",
        .description = "production errors should include a trace identifier",
        .expression = "severity >= error and has(prod)",
        .action = .require_field,
        .argument = "trace_id",
    });
    try policy.append(.{
        .name = "http.server-error",
        .description = "HTTP server error observed",
        .expression = "status >= 500 and status < 600",
        .action = .warn,
    });
    try policy.append(.{
        .name = "recovered-input",
        .description = "record was recovered from malformed input",
        .expression = "warning_count > 0",
        .action = .add_tag,
        .argument = "recovered",
    });
    try policy.append(.{
        .name = "credential-field",
        .description = "raw secret-bearing fields are forbidden in normalized event exports",
        .expression = "source_format == env",
        .action = .forbid_field,
        .argument = "PASSWORD",
    });
    return policy;
}

pub const Coverage = struct {
    rules: usize = 0,
    matched: usize = 0,
    unmatched: usize = 0,
    evaluations: usize = 0,
    errors: usize = 0,
    by_rule: [64]usize = [_]usize{0} ** 64,
};

pub fn measure(policy: *const Policy, records: []const record_mod.Record) Coverage {
    var coverage = Coverage{ .rules = policy.count };
    for (records) |*record| {
        for (policy.slice(), 0..) |*compiled, index| {
            coverage.evaluations += 1;
            const matched = query_eval.evaluate(&compiled.program, record, .{}) catch {
                coverage.errors += 1;
                continue;
            };
            if (matched) {
                coverage.matched += 1;
                coverage.by_rule[index] += 1;
            } else coverage.unmatched += 1;
        }
    }
    return coverage;
}

test "policy can tag recovered records and reject missing trace IDs" {
    var policy = try operationalBaseline();
    var record = record_mod.Record.init(.jsonl);
    record.severity = .@"error";
    record.warnings.append(.{ .severity = .warning, .code = .invalid_number, .line = 1, .column = 1, .message = "recovered" });
    try record.addTag("prod");
    const result = apply(&policy, &record);
    try std.testing.expect(result.findings.errorCount() >= 1);
    try std.testing.expect(record.hasTag("recovered"));
}
