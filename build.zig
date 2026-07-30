const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opsmosaic_mod = b.addModule("opsmosaic", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "opsmosaic",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("opsmosaic", opsmosaic_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run OpsMosaic");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const integration_tests = b.addTest(.{
        .root_source_file = b.path("tests/all_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.root_module.addImport("opsmosaic", opsmosaic_mod);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    const example = b.addExecutable(.{
        .name = "opsmosaic-library-example",
        .root_source_file = b.path("examples/library_usage.zig"),
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("opsmosaic", opsmosaic_mod);
    const example_step = b.step("example", "Build the library usage example");
    example_step.dependOn(&b.addInstallArtifact(example, .{}).step);
}
