const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis.module("vaxis") },
        },
    });

    const executable = b.addExecutable(.{
        .name = "cyclic-code-sim",
        .root_module = app_module,
    });
    b.installArtifact(executable);

    const run_artifact = b.addRunArtifact(executable);
    run_artifact.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_artifact.addArgs(args);
    const run_step = b.step("run", "Run the interactive shift-register simulator");
    run_step.dependOn(&run_artifact.step);

    const code_test_module = b.createModule(.{
        .root_source_file = b.path("src/code.zig"),
        .target = target,
        .optimize = optimize,
    });
    const code_tests = b.addTest(.{ .root_module = code_test_module });
    const run_code_tests = b.addRunArtifact(code_tests);

    const app_test_module = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis.module("vaxis") },
        },
    });
    const app_tests = b.addTest(.{ .root_module = app_test_module });
    const run_app_tests = b.addRunArtifact(app_tests);

    const test_step = b.step("test", "Run cyclic-code and shift-register tests");
    test_step.dependOn(&run_code_tests.step);
    test_step.dependOn(&run_app_tests.step);
}
