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

    // Binários alternativos (epoll/io_uring) habilitam com -Dwith-alts=true
    const with_alts = b.option(bool, "with-alts", "Build epoll/io_uring alternatives") orelse false;
    if (with_alts) {
        {
            const m = b.createModule(.{
                .root_source_file = b.path("src/main_epoll.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .single_threaded = true,
            });
            const exe = b.addExecutable(.{ .name = "floating_finch_epoll", .root_module = m });
            b.installArtifact(exe);
        }
        {
            const m = b.createModule(.{
                .root_source_file = b.path("src/main_iouring.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .single_threaded = false,
            });
            const exe = b.addExecutable(.{ .name = "floating_finch_iouring", .root_module = m });
            b.installArtifact(exe);
        }
    }
}
