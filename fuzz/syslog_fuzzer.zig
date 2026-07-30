const opsmosaic = @import("opsmosaic");

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.C) c_int {
    if (size > 1024 * 1024) return 0;
    const input = data[0..size];
    var parsed = opsmosaic.parseRecord(input, .syslog, .{ .max_token_bytes = 256 * 1024, .max_fields = 64, .max_depth = 16, .recover = true }) catch {
        _ = opsmosaic.parseRecord(input, .rfc5424, .{}) catch return 0;
        return 0;
    };
    _ = opsmosaic.normalizeRecord(&parsed.record);
    _ = parsed.record.identityHash();
    return 0;
}
