const std = @import("std");
const opsmosaic = @import("opsmosaic");

test "built-in service schema reports missing normalized core fields" {
    var record = opsmosaic.Record.init(.jsonl);
    record.message = "started";
    const findings = opsmosaic.validation.rules.validate(&record, opsmosaic.validation.schema.service_event, .{ .require_normalized_timestamp = true });
    try std.testing.expect(findings.errorCount() >= 3);
}

test "HTTP schema accepts a complete access record" {
    var parsed = try opsmosaic.parseRecord("192.0.2.2 - - [30/Jul/2026:07:00:00 +0000] \"GET /ready HTTP/1.1\" 200 21", .access_log, .{});
    _ = opsmosaic.normalizeRecord(&parsed.record);
    const findings = opsmosaic.validation.rules.validate(&parsed.record, opsmosaic.validation.schema.http_event, .{});
    try std.testing.expectEqual(@as(usize, 0), findings.errorCount());
}

test "policy evaluation adds tags and creates explicit findings" {
    var policy = try opsmosaic.validation.policy.operationalBaseline();
    var record = opsmosaic.Record.init(.jsonl);
    record.severity = .@"error";
    record.warnings.append(.{ .severity = .warning, .code = .invalid_number, .line = 1, .column = 1, .message = "recovered" });
    try record.addTag("prod");
    const result = opsmosaic.validation.policy.apply(&policy, &record);
    try std.testing.expect(result.findings.errorCount() != 0);
    try std.testing.expect(record.hasTag("recovered"));
}

test "redaction plan removes or replaces sensitive operational fields" {
    var record = opsmosaic.Record.init(.env_file);
    try record.addField("API_TOKEN", .{ .text = "secret-value" });
    try record.addField("private_key", .{ .text = "key-data" });
    var scratch: [128]u8 = undefined;
    const plan = opsmosaic.processing.redaction.standardPlan();
    const result = opsmosaic.processing.redaction.apply(&record, &plan, &scratch);
    try std.testing.expectEqual(@as(usize, 1), result.fields_replaced);
    try std.testing.expectEqual(@as(usize, 1), result.fields_removed);
}
