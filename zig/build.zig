const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    // Binário httpz-based
    {
        const m = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .single_threaded = false,
        });
        m.addImport("httpz", httpz.module("httpz"));
        const exe = b.addExecutable(.{
            .name = "floating_finch_zig",
            .root_module = m,
        });
        b.installArtifact(exe);
    }

    // Binário epoll custom
    {
        const m = b.createModule(.{
            .root_source_file = b.path("src/main_epoll.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .single_threaded = true,
        });
        const exe = b.addExecutable(.{
            .name = "floating_finch_epoll",
            .root_module = m,
        });
        b.installArtifact(exe);
    }
}
