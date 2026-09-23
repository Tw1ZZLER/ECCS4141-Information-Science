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
        .name = "gf256-sim",
        .root_module = app_module,
    });
    b.installArtifact(executable);

    const run_artifact = b.addRunArtifact(executable);
    run_artifact.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_artifact.addArgs(args);
    const run_step = b.step("run", "Run the interactive GF(256) explorer");
    run_step.dependOn(&run_artifact.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/gf256.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);

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

    const test_step = b.step("test", "Run GF(256) arithmetic tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_app_tests.step);
}
