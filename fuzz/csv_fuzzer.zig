const std = @import("std");
const opsmosaic = @import("opsmosaic");

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.C) c_int {
    if (size > 1024 * 1024) return 0;
    const input = data[0..size];
    var parsed = opsmosaic.parseRecord(input, .csv, .{}) catch return 0;
    _ = opsmosaic.normalizeRecord(&parsed.record);
    const profile = opsmosaic.processing.field_stats.build(&.{parsed.record});
    _ = profile.count;
    var output: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&output);
    opsmosaic.exporting.csv.write(&.{parsed.record}, stream.writer(), opsmosaic.exporting.csv.default_columns[0..], .{}) catch {};
    return 0;
}
