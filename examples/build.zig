const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the rune dependency
    const rune_dep = b.dependency("rune", .{
        .target = target,
        .optimize = optimize,
    });

    // Server example
    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rune", .module = rune_dep.module("rune") },
            },
        }),
    });
    b.installArtifact(server_exe);

    // Client example
    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rune", .module = rune_dep.module("rune") },
            },
        }),
    });
    b.installArtifact(client_exe);

    // Run steps
    const run_server = b.step("run-server", "Run the server example");
    const server_run = b.addRunArtifact(server_exe);
    run_server.dependOn(&server_run.step);

    const run_client = b.step("run-client", "Run the client example");
    const client_run = b.addRunArtifact(client_exe);
    run_client.dependOn(&client_run.step);
}