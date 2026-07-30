const opsmosaic = @import("opsmosaic");

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.C) c_int {
    if (size > 1024 * 1024) return 0;
    const input = data[0..size];
    exercise(input, .ini);
    exercise(input, .env_file);
    exercise(input, .manifest);
    return 0;
}

fn exercise(input: []const u8, format: opsmosaic.SourceFormat) void {
    var parsed = opsmosaic.parseRecord(input, format, .{}) catch return;
    _ = opsmosaic.normalizeRecord(&parsed.record);
    const plan = opsmosaic.processing.redaction.standardPlan();
    var scratch: [128]u8 = undefined;
    _ = opsmosaic.processing.redaction.apply(&parsed.record, &plan, &scratch);
}
