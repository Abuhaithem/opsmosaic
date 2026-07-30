test {
    _ = @import("parser_tests.zig");
    _ = @import("normalization_tests.zig");
    _ = @import("validation_tests.zig");
    _ = @import("query_tests.zig");
    _ = @import("aggregation_tests.zig");
    _ = @import("export_tests.zig");
    _ = @import("workflow_tests.zig");
    _ = @import("malformed_input_tests.zig");
    _ = @import("cli_integration_tests.zig");
    _ = @import("regression_tests.zig");
}
