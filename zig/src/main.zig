//! HTTP server usando httpz (multi-thread, keep-alive eficiente).
//!
//! Endpoints:
//!   GET  /ready        → 204 No Content
//!   POST /fraud-score  → 200 application/json (resposta pré-formatada)

const std = @import("std");
const httpz = @import("httpz");

const types = @import("types.zig");
const ivf = @import("ivf.zig");
const search = @import("search.zig");
const vectorize = @import("vectorize_fast.zig");
const quantize = @import("quantize.zig");

// Silencia logs do httpz e qualquer scope em hot path. std.log default escreve
// em stderr (syscall write) — overhead direto na latência sob carga.
pub const std_options: std.Options = .{
    .log_level = .err,
    .logFn = silentLog,
};

fn silentLog(
    comptime _: std.log.Level,
    comptime _: @Type(.enum_literal),
    comptime _: []const u8,
    _: anytype,
) void {}

const App = struct {
    index: *const ivf.IvfIndex,
    cfg: search.SearchConfig,
};

const Config = struct {
    bind_host: []const u8,
    bind_port: u16,
    uds_path: []const u8, // se não vazio, listen em UDS
    index_path: []const u8,
    search: search.SearchConfig,
};

fn envOr(name: []const u8, default: []const u8) []const u8 {
    return std.posix.getenv(name) orelse default;
}

fn envU32(name: []const u8, default: u32) u32 {
    const v = std.posix.getenv(name) orelse return default;
    return std.fmt.parseUnsigned(u32, v, 10) catch default;
}

fn envBool(name: []const u8, default: bool) bool {
    const v = std.posix.getenv(name) orelse return default;
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes"))
        return true;
    if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "no"))
        return false;
    return default;
}

fn loadConfig() Config {
    return Config{
        .bind_host = envOr("BIND_HOST", "0.0.0.0"),
        .bind_port = @intCast(envU32("BIND_PORT", 8080)),
        .uds_path = envOr("UDS_PATH", ""),
        .index_path = envOr("INDEX_PATH", "./index.bin"),
        .search = .{
            .nprobe = envU32("IVF_NPROBE", 4),
            .bbox_repair = envBool("IVF_BBOX_REPAIR", true),
            .repair_min = envU32("IVF_REPAIR_MIN", 1),
            .repair_max = envU32("IVF_REPAIR_MAX", 4),
        },
    };
}

fn handleReady(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 204;
}

fn handleFraud(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        return;
    };

    var fc: u8 = 0;
    if (vectorize.vectorizeBody(body, res.arena)) |qF| {
        const qI = quantize.quantizeQuery(qF);
        fc = search.fraudCount(app.index, qF, qI, app.cfg);
    } else |_| {
        fc = 0;
    }

    if (fc > 5) fc = 0;
    res.status = 200;
    res.content_type = .JSON;
    res.body = types.ResponseByFraudCount[fc];
}

pub fn main() !void {
    const cfg = loadConfig();
    const allocator = std.heap.c_allocator;

    std.log.info("loading index from {s}", .{cfg.index_path});
    var idx = try ivf.loadIndex(cfg.index_path);
    defer idx.deinit();
    std.log.info("  n={d}  k={d}", .{ idx.n_vectors, idx.n_clusters });
    std.log.info("  config: nprobe={d}  bboxRepair={any}  repair=[{d}-{d}]", .{
        cfg.search.nprobe, cfg.search.bbox_repair, cfg.search.repair_min, cfg.search.repair_max,
    });

    var app = App{ .index = &idx, .cfg = cfg.search };

    // Remove socket UDS pré-existente (de crash anterior) pra evitar EADDRINUSE
    if (cfg.uds_path.len > 0) {
        std.fs.deleteFileAbsolute(cfg.uds_path) catch {};
    }

    const AddrConfig = httpz.Config.AddressConfig;
    const addr_cfg: AddrConfig = if (cfg.uds_path.len > 0)
        .{ .unix = cfg.uds_path }
    else
        .{ .ip = .{ .host = cfg.bind_host, .port = cfg.bind_port } };

    var server = try httpz.Server(*App).init(allocator, .{
        .address = addr_cfg,
        .request = .{
            .max_body_size = 64 * 1024,
        },
        .thread_pool = .{
            // 3 workers = sweet spot empírico sob 0.40 CPU/container.
            // 1: p99 9.6ms / 2: p99 4.1ms / 3: p99 3.1ms / 4: p99 15.7ms (thrashing).
            .count = 3,
            .buffer_size = 64 * 1024,
        },
        .workers = .{
            .count = 1,
        },
    }, &app);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("/ready", handleReady, .{});
    router.post("/fraud-score", handleFraud, .{});

    if (cfg.uds_path.len > 0) {
        std.log.info("listening on unix:{s}", .{cfg.uds_path});
        // chmod 0666 pro nginx (rodando como nginx user) poder conectar
        // dispatcha em thread paralela porque server.listen() bloqueia
        const ChmodCtx = struct {
            fn run(path: []const u8) void {
                // espera socket ser criado
                var i: u32 = 0;
                while (i < 50) : (i += 1) {
                    std.fs.accessAbsolute(path, .{}) catch {
                        std.Thread.sleep(20 * std.time.ns_per_ms);
                        continue;
                    };
                    break;
                }
                var path_buf: [4096]u8 = undefined;
                if (path.len >= path_buf.len) return;
                @memcpy(path_buf[0..path.len], path);
                path_buf[path.len] = 0;
                const path_z: [*:0]const u8 = @ptrCast(&path_buf);
                _ = std.c.chmod(path_z, 0o666);
            }
        };
        _ = try std.Thread.spawn(.{}, ChmodCtx.run, .{cfg.uds_path});
    } else {
        std.log.info("listening on {s}:{d}", .{ cfg.bind_host, cfg.bind_port });
    }
    try server.listen();
}
