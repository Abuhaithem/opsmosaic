const opsmosaic = @import("opsmosaic");

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.C) c_int {
    if (size > 1024 * 1024) return 0;
    const input = data[0..size];
    var parsed = opsmosaic.parseRecord(input, .access_log, .{}) catch return 0;
    _ = opsmosaic.normalizeRecord(&parsed.record);
    const findings = opsmosaic.validation.rules.validate(&parsed.record, opsmosaic.validation.schema.http_event, .{});
    _ = findings.count;
    const report = opsmosaic.processing.aggregation.summarize(&.{parsed.record});
    _ = report.status.errorRate();
    return 0;
}
