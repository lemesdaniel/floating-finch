//! HTTP server custom Zig com io_uring + UDS.
//!
//! Substitui epoll por io_uring (Linux 5.19+). ACCEPT_MULTISHOT na listener,
//! RECV/SEND batched. user_data carrega ptr conn + tag de 3 bits.
//! IORING_SETUP_SINGLE_ISSUER + DEFER_TASKRUN pra reduzir wakeups.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const types = @import("types.zig");
const ivf = @import("ivf.zig");
const search = @import("search.zig");
const vectorize = @import("vectorize_fast.zig");
const quantize = @import("quantize.zig");

pub const std_options: std.Options = .{
    .log_level = .err,
    .logFn = silentLog,
};

fn silentLog(comptime _: std.log.Level, comptime _: @Type(.enum_literal), comptime _: []const u8, _: anytype) void {}

// -------- Respostas pré-formatadas --------

const ResponseReady = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n";
const ResponseBad = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const ResponseNotFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

var FraudResponses: [6][]const u8 = undefined;

fn initFraudResponses(buf: *[6][512]u8) void {
    const tpl = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}";
    for (0..6) |i| {
        const body = types.ResponseByFraudCount[i];
        const slice = std.fmt.bufPrint(&buf[i], tpl, .{ body.len, body }) catch unreachable;
        FraudResponses[i] = slice;
    }
}

// -------- Configuração --------

const Config = struct {
    uds_path: []const u8,
    index_path: []const u8,
    search: search.SearchConfig,
};

fn envOr(name: []const u8, default: []const u8) []const u8 {
    return posix.getenv(name) orelse default;
}
fn envU32(name: []const u8, default: u32) u32 {
    const v = posix.getenv(name) orelse return default;
    return std.fmt.parseUnsigned(u32, v, 10) catch default;
}
fn envBool(name: []const u8, default: bool) bool {
    const v = posix.getenv(name) orelse return default;
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes")) return true;
    if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "no")) return false;
    return default;
}

fn loadConfig() Config {
    return .{
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

// -------- HTTP parser minimal --------

const HttpParseError = error{ Incomplete, BadRequest, TooLarge };

const HttpReq = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
    consumed: usize,
    keep_alive: bool,
};

fn asciiEqlIgn(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

const MaxBody: usize = 32 * 1024;

fn parseRequest(buf: []const u8) HttpParseError!HttpReq {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.Incomplete;
    const head = buf[0..head_end];
    const first_eol = std.mem.indexOfScalar(u8, head, '\n') orelse return error.BadRequest;
    const line1_raw = head[0..first_eol];
    const line1 = if (line1_raw.len > 0 and line1_raw[line1_raw.len - 1] == '\r')
        line1_raw[0 .. line1_raw.len - 1]
    else
        line1_raw;
    const sp1 = std.mem.indexOfScalar(u8, line1, ' ') orelse return error.BadRequest;
    const method = line1[0..sp1];
    const rest = line1[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadRequest;
    const path = rest[0..sp2];

    var cl: usize = 0;
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
        while (val_start < line.len and (line[val_start] == ' ' or line[val_start] == '\t')) val_start += 1;
        const value = line[val_start..];
        if (asciiEqlIgn(name, "content-length")) {
            cl = std.fmt.parseUnsigned(usize, value, 10) catch return error.BadRequest;
        } else if (asciiEqlIgn(name, "connection")) {
            if (asciiEqlIgn(value, "close")) keep_alive = false;
        }
        line_start = eol + 1;
    }

    if (cl > MaxBody) return error.TooLarge;
    const body_start = head_end + 4;
    const total = body_start + cl;
    if (total > buf.len) return error.Incomplete;
    return .{
        .method = method,
        .path = path,
        .body = if (cl > 0) buf[body_start..total] else "",
        .consumed = total,
        .keep_alive = keep_alive,
    };
}

// -------- Conn state --------

const ReadBufSize: usize = 32 * 1024;
const WriteBufSize: usize = 512;

const ConnState = struct {
    fd: posix.fd_t,
    read_buf: [ReadBufSize]u8 align(16) = undefined,
    read_have: usize = 0,
    write_buf: [WriteBufSize]u8 align(16) = undefined,
    write_len: usize = 0,
    write_pos: usize = 0,
    keep_alive: bool = true,
    closing: bool = false,
    json_arena: std.heap.ArenaAllocator,
};

// -------- user_data tagging --------
// ConnState alloc via c_allocator: ptr alinhado em 16 → 4 bits baixos livres.

const TAG_ACCEPT: u64 = 0;
const TAG_RECV: u64 = 1;
const TAG_SEND: u64 = 2;
const TAG_CLOSE: u64 = 3;
const TAG_MASK: u64 = 0x7;

inline fn tagged(conn: *ConnState, tag: u64) u64 {
    return @intFromPtr(conn) | tag;
}
inline fn untag(ud: u64) *ConnState {
    return @ptrFromInt(ud & ~TAG_MASK);
}

const App = struct {
    index: *const ivf.IvfIndex,
    cfg: search.SearchConfig,
    ring: *linux.IoUring,
    listener_fd: posix.fd_t,
    gpa: std.mem.Allocator,
};

// -------- Handler --------

fn handle(app: *App, conn: *ConnState, req: HttpReq) void {
    conn.keep_alive = req.keep_alive;
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/ready")) {
        @memcpy(conn.write_buf[0..ResponseReady.len], ResponseReady);
        conn.write_len = ResponseReady.len;
        conn.write_pos = 0;
        return;
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/fraud-score")) {
        _ = conn.json_arena.reset(.retain_capacity);
        var fc: u8 = 0;
        if (vectorize.vectorizeBody(req.body, conn.json_arena.allocator())) |qF| {
            const qI = quantize.quantizeQuery(qF);
            fc = search.fraudCount(app.index, qF, qI, app.cfg);
        } else |_| {
            fc = 0;
        }
        if (fc > 5) fc = 0;
        const resp = FraudResponses[fc];
        @memcpy(conn.write_buf[0..resp.len], resp);
        conn.write_len = resp.len;
        conn.write_pos = 0;
        return;
    }
    @memcpy(conn.write_buf[0..ResponseNotFound.len], ResponseNotFound);
    conn.write_len = ResponseNotFound.len;
    conn.write_pos = 0;
    conn.keep_alive = false;
}

// -------- Conn lifecycle --------

fn createConn(app: *App, fd: posix.fd_t) ?*ConnState {
    const conn = app.gpa.create(ConnState) catch return null;
    conn.* = .{
        .fd = fd,
        .read_have = 0,
        .write_len = 0,
        .write_pos = 0,
        .keep_alive = true,
        .closing = false,
        .json_arena = std.heap.ArenaAllocator.init(app.gpa),
    };
    return conn;
}

fn destroyConn(app: *App, conn: *ConnState) void {
    conn.json_arena.deinit();
    app.gpa.destroy(conn);
}

fn submitRecv(app: *App, conn: *ConnState) bool {
    const sqe = app.ring.get_sqe() catch return false;
    sqe.prep_recv(conn.fd, conn.read_buf[conn.read_have..], 0);
    sqe.user_data = tagged(conn, TAG_RECV);
    return true;
}

fn submitSend(app: *App, conn: *ConnState) bool {
    const sqe = app.ring.get_sqe() catch return false;
    sqe.prep_send(conn.fd, conn.write_buf[conn.write_pos..conn.write_len], linux.MSG.NOSIGNAL);
    sqe.user_data = tagged(conn, TAG_SEND);
    return true;
}

fn submitClose(app: *App, conn: *ConnState) void {
    conn.closing = true;
    const sqe = app.ring.get_sqe() catch {
        // Fallback síncrono se SQ cheia
        posix.close(conn.fd);
        destroyConn(app, conn);
        return;
    };
    sqe.prep_close(conn.fd);
    sqe.user_data = tagged(conn, TAG_CLOSE);
}

fn submitAcceptMultishot(app: *App) !void {
    _ = try app.ring.accept_multishot(TAG_ACCEPT, app.listener_fd, null, null, 0);
}

// -------- Processamento por evento --------

// Parseia e despacha 1 request; se OK, submete SEND. Se body incompleto, re-arma RECV.
// Retorna true se conexão deve continuar.
fn parseAndDispatch(app: *App, conn: *ConnState) bool {
    const req = parseRequest(conn.read_buf[0..conn.read_have]) catch |e| switch (e) {
        error.Incomplete => return submitRecv(app, conn),
        error.BadRequest, error.TooLarge => {
            @memcpy(conn.write_buf[0..ResponseBad.len], ResponseBad);
            conn.write_len = ResponseBad.len;
            conn.write_pos = 0;
            conn.keep_alive = false;
            return submitSend(app, conn);
        },
    };
    handle(app, conn, req);
    const remaining = conn.read_have - req.consumed;
    if (remaining > 0) {
        std.mem.copyForwards(u8, conn.read_buf[0..remaining], conn.read_buf[req.consumed..conn.read_have]);
    }
    conn.read_have = remaining;
    return submitSend(app, conn);
}

fn processRecv(app: *App, conn: *ConnState, res: i32) bool {
    if (res <= 0) return false;
    conn.read_have += @intCast(res);
    return parseAndDispatch(app, conn);
}

fn processSend(app: *App, conn: *ConnState, res: i32) bool {
    if (res <= 0) return false;
    conn.write_pos += @intCast(res);
    if (conn.write_pos < conn.write_len) {
        return submitSend(app, conn);
    }
    conn.write_len = 0;
    conn.write_pos = 0;
    if (!conn.keep_alive) return false;
    if (conn.read_have > 0) {
        return parseAndDispatch(app, conn);
    }
    return submitRecv(app, conn);
}

// -------- Loop --------

fn serve(app: *App) !void {
    try submitAcceptMultishot(app);
    var cqes: [256]linux.io_uring_cqe = undefined;

    while (true) {
        _ = app.ring.submit_and_wait(1) catch |e| switch (e) {
            error.SignalInterrupt => continue,
            else => return e,
        };
        const n = app.ring.copy_cqes(&cqes, 0) catch |e| switch (e) {
            error.SignalInterrupt => continue,
            else => return e,
        };
        for (cqes[0..n]) |cqe| {
            const tag = cqe.user_data & TAG_MASK;
            switch (tag) {
                TAG_ACCEPT => {
                    if (cqe.res >= 0) {
                        const fd: posix.fd_t = @intCast(cqe.res);
                        if (createConn(app, fd)) |conn| {
                            if (!submitRecv(app, conn)) {
                                posix.close(fd);
                                destroyConn(app, conn);
                            }
                        } else {
                            posix.close(fd);
                        }
                    }
                    // Multishot expirou (F_MORE off) → re-arm
                    if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
                        try submitAcceptMultishot(app);
                    }
                },
                TAG_RECV => {
                    const conn = untag(cqe.user_data);
                    if (conn.closing) continue;
                    const keep = processRecv(app, conn, cqe.res);
                    if (!keep) submitClose(app, conn);
                },
                TAG_SEND => {
                    const conn = untag(cqe.user_data);
                    if (conn.closing) continue;
                    const keep = processSend(app, conn, cqe.res);
                    if (!keep) submitClose(app, conn);
                },
                TAG_CLOSE => {
                    const conn = untag(cqe.user_data);
                    destroyConn(app, conn);
                },
                else => {},
            }
        }
    }
}

// -------- Pre-warm + bind --------

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
        if (i % 4 == 0) {
            qF[5] = -1.0;
            qF[6] = -1.0;
            qI[5] = -10000;
            qI[6] = -10000;
        }
        const fc = search.fraudCount(idx, qF, qI, cfg);
        std.mem.doNotOptimizeAway(fc);
    }
}

fn bindUds(path: []const u8) !posix.fd_t {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    _ = std.c.unlink(path_z);

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    var sun: posix.sockaddr.un = undefined;
    sun.family = posix.AF.UNIX;
    @memset(&sun.path, 0);
    @memcpy(sun.path[0..path.len], path);
    sun.path[path.len] = 0;
    const sun_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + path.len + 1);
    try posix.bind(fd, @ptrCast(&sun), sun_len);
    try posix.listen(fd, 4096);
    _ = std.c.chmod(path_z, 0o666);
    return fd;
}

fn initRing() !linux.IoUring {
    // Tenta flags otimizadas (kernel 6.1+); cai pra default em kernels mais antigos.
    const optimized = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN | linux.IORING_SETUP_COOP_TASKRUN;
    if (linux.IoUring.init(1024, optimized)) |r| {
        return r;
    } else |_| {}
    if (linux.IoUring.init(1024, linux.IORING_SETUP_COOP_TASKRUN)) |r| {
        return r;
    } else |_| {}
    return try linux.IoUring.init(1024, 0);
}

pub fn main() !void {
    const cfg = loadConfig();
    const gpa = std.heap.c_allocator;

    var resp_buf: [6][512]u8 = undefined;
    initFraudResponses(&resp_buf);

    var idx = try ivf.loadIndex(cfg.index_path);
    defer idx.deinit();

    prewarmSearch(&idx, cfg.search, 500);

    if (cfg.uds_path.len == 0) return error.UdsRequired;
    const listener_fd = try bindUds(cfg.uds_path);

    var ring = try initRing();
    defer ring.deinit();

    var app = App{
        .index = &idx,
        .cfg = cfg.search,
        .ring = &ring,
        .listener_fd = listener_fd,
        .gpa = gpa,
    };

    try serve(&app);
}
