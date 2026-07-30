const std = @import("std");
const record_mod = @import("../model/record.zig");

pub const Mode = enum { replace, remove, hash };

pub const Rule = struct {
    field_pattern: []const u8,
    mode: Mode = .replace,
    replacement: []const u8 = "<redacted>",
    case_insensitive: bool = true,
};

pub const Plan = struct {
    rules: [64]Rule = undefined,
    count: usize = 0,
    redact_message_patterns: bool = false,

    pub fn append(self: *Plan, rule: Rule) error{TooManyRules}!void {
        if (self.count >= self.rules.len) return error.TooManyRules;
        if (rule.field_pattern.len == 0) return;
        self.rules[self.count] = rule;
        self.count += 1;
    }

    pub fn slice(self: *const Plan) []const Rule {
        return self.rules[0..self.count];
    }
};

pub const Result = struct {
    fields_replaced: usize = 0,
    fields_removed: usize = 0,
    fields_hashed: usize = 0,
    core_values_replaced: usize = 0,
};

pub fn standardPlan() Plan {
    var plan = Plan{};
    plan.append(.{ .field_pattern = "*password*" }) catch {};
    plan.append(.{ .field_pattern = "*secret*" }) catch {};
    plan.append(.{ .field_pattern = "*token*" }) catch {};
    plan.append(.{ .field_pattern = "*credential*" }) catch {};
    plan.append(.{ .field_pattern = "authorization" }) catch {};
    plan.append(.{ .field_pattern = "cookie" }) catch {};
    plan.append(.{ .field_pattern = "set-cookie" }) catch {};
    plan.append(.{ .field_pattern = "private_key", .mode = .remove }) catch {};
    return plan;
}

pub fn apply(record: *record_mod.Record, plan: *const Plan, scratch: []u8) Result {
    var result = Result{};
    var index: usize = 0;
    while (index < record.field_count) {
        const field = &record.fields[index];
        const rule = matchingRule(plan, field.key) orelse {
            index += 1;
            continue;
        };
        switch (rule.mode) {
            .replace => {
                field.value = .{ .text = rule.replacement };
                result.fields_replaced += 1;
                index += 1;
            },
            .remove => {
                removeField(record, index);
                result.fields_removed += 1;
            },
            .hash => {
                const digest = field.value.hash();
                const rendered = std.fmt.bufPrint(scratch, "sha256-like:{x}", .{digest}) catch rule.replacement;
                field.value = .{ .text = rendered };
                result.fields_hashed += 1;
                index += 1;
            },
        }
    }
    if (plan.redact_message_patterns and containsCredentialAssignment(record.message)) {
        record.message = "<message redacted: credential-like assignment>";
        result.core_values_replaced += 1;
    }
    return result;
}

fn removeField(record: *record_mod.Record, index: usize) void {
    if (index >= record.field_count) return;
    var cursor = index;
    while (cursor + 1 < record.field_count) : (cursor += 1) record.fields[cursor] = record.fields[cursor + 1];
    record.field_count -= 1;
}

fn matchingRule(plan: *const Plan, field: []const u8) ?Rule {
    for (plan.slice()) |rule| { if (matches(rule.field_pattern, field, rule.case_insensitive)) return rule; }
    return null;
}

pub fn matches(pattern: []const u8, input: []const u8, insensitive: bool) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (i < input.len) {
        if (p < pattern.len and (pattern[p] == '?' or charEqual(pattern[p], input[i], insensitive))) {
            p += 1;
            i += 1;
            continue;
        }
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = i;
            continue;
        }
        if (star) |position| {
            p = position + 1;
            retry += 1;
            i = retry;
            continue;
        }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn charEqual(a: u8, b: u8, insensitive: bool) bool {
    return if (insensitive) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

fn containsCredentialAssignment(message: []const u8) bool {
    const needles = [_][]const u8{ "password=", "secret=", "token=", "authorization:" };
    for (needles) |needle| { if (containsIgnoreCase(message, needle)) return true; }
    return false;
}

fn containsIgnoreCase(input: []const u8, needle: []const u8) bool {
    if (input.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= input.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(input[index .. index + needle.len], needle)) return true;
    }
    return false;
}

pub fn validatePlan(plan: *const Plan) bool {
    if (plan.count > plan.rules.len) return false;
    for (plan.slice(), 0..) |rule, index| {
        if (rule.field_pattern.len == 0 or rule.field_pattern.len > 256) return false;
        if (rule.mode == .replace and rule.replacement.len == 0) return false;
        for (plan.slice()[0..index]) |prior| {
            if (std.ascii.eqlIgnoreCase(prior.field_pattern, rule.field_pattern) and prior.mode == rule.mode) return false;
        }
    }
    return true;
}

test "standard redaction removes keys and replaces secret values" {
    var record = record_mod.Record.init(.env_file);
    try record.addField("API_TOKEN", .{ .text = "abc" });
    try record.addField("private_key", .{ .text = "pem" });
    var scratch: [128]u8 = undefined;
    const plan = standardPlan();
    const result = apply(&record, &plan, &scratch);
    try std.testing.expectEqual(@as(usize, 1), result.fields_replaced);
    try std.testing.expectEqual(@as(usize, 1), result.fields_removed);
    try std.testing.expectEqualStrings("<redacted>", record.getField("API_TOKEN").?.text);
}
