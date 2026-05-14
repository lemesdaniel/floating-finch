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
    comptime _: @EnumLiteral(),
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

fn envRaw(name: []const u8) ?[]const u8 {
    var name_buf: [128]u8 = undefined;
    if (name.len >= name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const name_z: [*:0]const u8 = @ptrCast(&name_buf);
    const v = std.c.getenv(name_z) orelse return null;
    return std.mem.span(v);
}

fn envOr(name: []const u8, default: []const u8) []const u8 {
    return envRaw(name) orelse default;
}

fn envU32(name: []const u8, default: u32) u32 {
    const v = envRaw(name) orelse return default;
    return std.fmt.parseUnsigned(u32, v, 10) catch default;
}

fn envBool(name: []const u8, default: bool) bool {
    const v = envRaw(name) orelse return default;
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

/// Pre-warm aquece caches/predictor. Gera queries pseudo-aleatórias e roda
/// fraudCount. Resultado é descartado.
fn prewarmSearch(idx: *const ivf.IvfIndex, cfg: search.SearchConfig, iters: usize) void {
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var qF: types.QueryF32 = undefined;
        var qI: types.QueryI16 = undefined;
        inline for (0..types.Dim) |d| {
            const v = random.float(f32);
            qF[d] = v;
            qI[d] = @intFromFloat(v * types.QuantScale);
        }
        // Sentinel ocasional nos campos 5,6 pra exercitar code path
        if (i % 4 == 0) {
            qF[5] = -1.0;
            qF[6] = -1.0;
            qI[5] = -10000;
            qI[6] = -10000;
        }
        const _fc = search.fraudCount(idx, qF, qI, cfg);
        std.mem.doNotOptimizeAway(_fc);
    }
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

    // Zig 0.16: I/O abstraction obrigatório via std.Io.Threaded.
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.log.info("loading index from {s}", .{cfg.index_path});
    var idx = try ivf.loadIndex(cfg.index_path);
    defer idx.deinit();
    std.log.info("  n={d}  k={d}", .{ idx.n_vectors, idx.n_clusters });
    std.log.info("  config: nprobe={d}  bboxRepair={any}  repair=[{d}-{d}]", .{
        cfg.search.nprobe, cfg.search.bbox_repair, cfg.search.repair_min, cfg.search.repair_max,
    });

    // Pre-warm: aquece I-cache, decoded-uop cache, branch predictor + força page
    // faults no mmap ANTES do harness começar. ~500 iters cobre todas as paths.
    prewarmSearch(&idx, cfg.search, 500);

    var app = App{ .index = &idx, .cfg = cfg.search };

    // Remove socket UDS pré-existente (de crash anterior) pra evitar EADDRINUSE.
    // Zig 0.16 removeu std.fs.deleteFileAbsolute — usa libc unlink direto.
    if (cfg.uds_path.len > 0) {
        var path_buf: [4096]u8 = undefined;
        if (cfg.uds_path.len < path_buf.len) {
            @memcpy(path_buf[0..cfg.uds_path.len], cfg.uds_path);
            path_buf[cfg.uds_path.len] = 0;
            const path_z: [*:0]const u8 = @ptrCast(&path_buf);
            _ = std.c.unlink(path_z);
        }
    }

    const addr: httpz.Config.Address = if (cfg.uds_path.len > 0)
        .{ .unix = cfg.uds_path }
    else
        .{ .ip = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = cfg.bind_port } } };

    var server = try httpz.Server(*App).init(io, allocator, .{
        .address = addr,
        .request = .{
            .max_body_size = 64 * 1024,
        },
        .thread_pool = .{
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
            extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
            extern "c" fn usleep(usec: c_uint) c_int;
            fn run(path: []const u8) void {
                var path_buf: [4096]u8 = undefined;
                if (path.len >= path_buf.len) return;
                @memcpy(path_buf[0..path.len], path);
                path_buf[path.len] = 0;
                const path_z: [*:0]const u8 = @ptrCast(&path_buf);
                // espera socket ser criado
                var i: u32 = 0;
                while (i < 50) : (i += 1) {
                    if (access(path_z, 0) == 0) break;
                    _ = usleep(20_000); // 20ms
                }
                _ = std.c.chmod(path_z, 0o666);
            }
        };
        _ = try std.Thread.spawn(.{}, ChmodCtx.run, .{cfg.uds_path});
    } else {
        std.log.info("listening on {s}:{d}", .{ cfg.bind_host, cfg.bind_port });
    }
    try server.listen();
}
