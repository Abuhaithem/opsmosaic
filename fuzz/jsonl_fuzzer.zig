const std = @import("std");
const opsmosaic = @import("opsmosaic");

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.C) c_int {
    if (size > 1024 * 1024) return 0;
    const input = data[0..size];
    var parsed = opsmosaic.parseRecord(input, .jsonl, .{}) catch return 0;
    _ = opsmosaic.normalizeRecord(&parsed.record);
    var output: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&output);
    opsmosaic.exporting.json.writeRecord(&parsed.record, stream.writer(), .{}) catch {};
    return 0;
}
