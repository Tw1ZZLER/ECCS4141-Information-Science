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
        .name = "linear-code-sim",
        .root_module = app_module,
    });
    b.installArtifact(executable);

    const run_artifact = b.addRunArtifact(executable);
    run_artifact.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_artifact.addArgs(args);
    const run_step = b.step("run", "Run the interactive simulator");
    run_step.dependOn(&run_artifact.step);
}
