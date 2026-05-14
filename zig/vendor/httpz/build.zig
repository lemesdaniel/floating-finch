const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_opts = .{ .target = target, .optimize = optimize };
    const metrics_module = b.dependency("metrics", dep_opts).module("metrics");
    const websocket_module = b.dependency("websocket", dep_opts).module("websocket");

    const enable_tsan = b.option(bool, "tsan", "Enable ThreadSanitizer");

    const httpz_module = b.addModule("httpz", .{
        .link_libc = true,
        .root_source_file = b.path("src/httpz.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = enable_tsan,
        .imports = &.{
            .{ .name = "metrics", .module = metrics_module },
            .{ .name = "websocket", .module = websocket_module },
        },
    });
    {
        const options = b.addOptions();
        options.addOption(bool, "httpz_blocking", false);
        httpz_module.addOptions("build", options);
    }

    // Skipping tests + examples — consumers only need the httpz module above.
}
