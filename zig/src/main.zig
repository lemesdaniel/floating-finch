//! Servidor HTTP single-thread, Connection: close por request.
//!
//! Modelo simples (proof-of-concept didático):
//!   - 1 thread, accept blocking
//!   - Cada conn processa 1 request, responde com Connection: close, fecha
//!   - Nginx mantém pool no lado dele; criar TCP nova é o overhead aceito
//!     em troca de evitar o deadlock do read blocking single-thread.
//!
//! Para maior performance seria necessário epoll edge-triggered ou multi-
//! threading com SO_REUSEPORT — fora do escopo desta v2 Zig de aprendizado.
//!
//! Endpoints:
//!   GET  /ready        → 204 No Content
//!   POST /fraud-score  → 200 application/json (resposta pré-formatada)

const std = @import("std");
const types = @import("types.zig");
const ivf = @import("ivf.zig");
const search = @import("search.zig");
const vectorize = @import("vectorize.zig");
const quantize = @import("quantize.zig");

const ResponseReady = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const ResponseNotFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const ResponseBadRequest = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const ResponseTooLarge = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

const FraudHeaderTpl = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n";

const MaxBody: usize = 64 * 1024;
const ReadBufSize: usize = 96 * 1024;

const Config = struct {
    bind_host: []const u8,
    bind_port: u16,
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
        .index_path = envOr("INDEX_PATH", "./index.bin"),
        .search = .{
            .nprobe = envU32("IVF_NPROBE", 4),
            .bbox_repair = envBool("IVF_BBOX_REPAIR", true),
            .repair_min = envU32("IVF_REPAIR_MIN", 1),
            .repair_max = envU32("IVF_REPAIR_MAX", 4),
        },
    };
}

const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
    keep_alive: bool,
};

const HttpParseError = error{ Incomplete, BadRequest, TooLarge };

fn asciiEqlIgn(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn parseRequest(buf: []const u8) !struct { req: HttpRequest, consumed: usize } {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.Incomplete;
    const head = buf[0..head_end];

    const first_eol = std.mem.indexOfScalar(u8, head, '\n') orelse return error.BadRequest;
    const first_line_raw = head[0..first_eol];
    const first_line = if (first_line_raw.len > 0 and first_line_raw[first_line_raw.len - 1] == '\r')
        first_line_raw[0 .. first_line_raw.len - 1]
    else
        first_line_raw;

    const sp1 = std.mem.indexOfScalar(u8, first_line, ' ') orelse return error.BadRequest;
    const method = first_line[0..sp1];
    const rest = first_line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadRequest;
    const path = rest[0..sp2];

    var content_length: usize = 0;
    var keep_alive: bool = true;
    var line_start: usize = first_eol + 1;
    while (line_start < head.len) {
        const eol = std.mem.indexOfScalarPos(u8, head, line_start, '\n') orelse head.len;
        const line_raw = head[line_start..eol];
        const line = if (line_raw.len > 0 and line_raw[line_raw.len - 1] == '\r')
            line_raw[0 .. line_raw.len - 1]
        else
            line_raw;
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            line_start = eol + 1;
            continue;
        };
        const name = line[0..colon];
        var val_start: usize = colon + 1;
        while (val_start < line.len and (line[val_start] == ' ' or line[val_start] == '\t'))
            val_start += 1;
        const value = line[val_start..];

        if (asciiEqlIgn(name, "content-length")) {
            content_length = std.fmt.parseUnsigned(usize, value, 10) catch return error.BadRequest;
        } else if (asciiEqlIgn(name, "connection")) {
            if (asciiEqlIgn(value, "close")) keep_alive = false;
        }

        line_start = eol + 1;
    }

    if (content_length > MaxBody) return error.TooLarge;

    const body_start = head_end + 4;
    const total = body_start + content_length;
    if (total > buf.len) return error.Incomplete;

    return .{
        .req = .{
            .method = method,
            .path = path,
            .body = buf[body_start..total],
            .keep_alive = keep_alive,
        },
        .consumed = total,
    };
}

const HandlerCtx = struct {
    index: *const ivf.IvfIndex,
    cfg: search.SearchConfig,
    arena: *std.heap.ArenaAllocator,
};

fn handle(ctx: *HandlerCtx, req: HttpRequest, stream: std.net.Stream) !void {
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/ready")) {
        try stream.writeAll(ResponseReady);
        return;
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/fraud-score")) {
        _ = ctx.arena.reset(.retain_capacity);
        const alloc = ctx.arena.allocator();

        var fc: u8 = 0;
        if (vectorize.vectorizeBody(req.body, alloc)) |qF| {
            const qI = quantize.quantizeQuery(qF);
            fc = search.fraudCount(ctx.index, qF, qI, ctx.cfg);
        } else |_| {
            fc = 0;
        }

        if (fc > 5) fc = 0;
        const body = types.ResponseByFraudCount[fc];
        var hdr_buf: [128]u8 = undefined;
        const hdr = try std.fmt.bufPrint(&hdr_buf, FraudHeaderTpl, .{body.len});
        try stream.writeAll(hdr);
        try stream.writeAll(body);
        return;
    }
    try stream.writeAll(ResponseNotFound);
}

fn serve(listener: *std.net.Server, ctx: *HandlerCtx) !void {
    var read_buf: [ReadBufSize]u8 = undefined;
    while (true) {
        var conn = listener.accept() catch |e| {
            std.log.warn("accept failed: {s}", .{@errorName(e)});
            continue;
        };
        defer conn.stream.close();

        var have: usize = 0;
        while (true) {
            const ok = parseRequest(read_buf[0..have]) catch |e| switch (e) {
                error.Incomplete => null,
                error.BadRequest => {
                    _ = conn.stream.writeAll(ResponseBadRequest) catch {};
                    break;
                },
                error.TooLarge => {
                    _ = conn.stream.writeAll(ResponseTooLarge) catch {};
                    break;
                },
            };
            if (ok) |parsed| {
                handle(ctx, parsed.req, conn.stream) catch {};
                break;
            }
            if (have >= read_buf.len) {
                _ = conn.stream.writeAll(ResponseTooLarge) catch {};
                break;
            }
            const n = conn.stream.read(read_buf[have..]) catch break;
            if (n == 0) break;
            have += n;
        }
    }
}

pub fn main() !void {
    const cfg = loadConfig();
    const gpa = std.heap.c_allocator;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    std.log.info("loading index from {s}", .{cfg.index_path});
    var idx = try ivf.loadIndex(cfg.index_path);
    defer idx.deinit();
    std.log.info("  n={d}  k={d}", .{ idx.n_vectors, idx.n_clusters });
    std.log.info("  config: nprobe={d}  bboxRepair={any}  repair=[{d}-{d}]", .{
        cfg.search.nprobe, cfg.search.bbox_repair, cfg.search.repair_min, cfg.search.repair_max,
    });

    const addr = try std.net.Address.parseIp(cfg.bind_host, cfg.bind_port);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    std.log.info("listening on {s}:{d}  (single-threaded, conn close per request)", .{
        cfg.bind_host, cfg.bind_port,
    });

    var ctx = HandlerCtx{
        .index = &idx,
        .cfg = cfg.search,
        .arena = &arena,
    };
    try serve(&listener, &ctx);
}
