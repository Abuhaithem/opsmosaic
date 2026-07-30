const std = @import("std");
const opsmosaic = @import("opsmosaic");

pub fn main() !void {
    var general_purpose = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose.deinit();
    const exit_code = try opsmosaic.cli.dispatcher.runProcess(general_purpose.allocator());
    if (exit_code != 0) std.process.exit(exit_code);
}
