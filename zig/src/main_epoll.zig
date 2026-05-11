//! HTTP server custom Zig com epoll edge-triggered + UDS.
//!
//! Substitui httpz pra eliminar overhead de framework: zero alloc no hot path,
//! single-thread non-blocking, conn-state em pointer guardado no epoll_event.

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

// Cache estática: 6 responses prontas (status+headers+body) por fraud_count
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
    bind_host: []const u8,
    bind_port: u16,
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
const WriteBufSize: usize = 256;

const ConnState = struct {
    fd: posix.fd_t,
    read_buf: [ReadBufSize]u8 = undefined,
    read_have: usize = 0,
    write_buf: [WriteBufSize]u8 = undefined,
    write_len: usize = 0,
    write_pos: usize = 0,
    keep_alive: bool = true,
    json_arena: std.heap.ArenaAllocator,
};

const App = struct {
    index: *const ivf.IvfIndex,
    cfg: search.SearchConfig,
    epoll_fd: posix.fd_t,
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

// -------- Loop --------

fn epollAdd(epfd: posix.fd_t, fd: posix.fd_t, ptr: ?*ConnState, events: u32) !void {
    var ev: linux.epoll_event = .{
        .events = events,
        .data = .{ .ptr = if (ptr) |p| @intFromPtr(p) else 0 },
    };
    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev);
}

fn epollMod(epfd: posix.fd_t, fd: posix.fd_t, ptr: *ConnState, events: u32) !void {
    var ev: linux.epoll_event = .{
        .events = events,
        .data = .{ .ptr = @intFromPtr(ptr) },
    };
    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &ev);
}

const EPOLLIN: u32 = linux.EPOLL.IN;
const EPOLLOUT: u32 = linux.EPOLL.OUT;
const EPOLLET: u32 = linux.EPOLL.ET;
const EPOLLHUP: u32 = linux.EPOLL.HUP;
const EPOLLRDHUP: u32 = linux.EPOLL.RDHUP;
const EPOLLERR: u32 = linux.EPOLL.ERR;

fn setNonBlock(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | @as(usize, @intCast(@as(c_int, 0o4000)))); // O_NONBLOCK
}

fn acceptAll(app: *App) void {
    while (true) {
        const conn_fd = posix.accept(app.listener_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return,
        };
        const conn = app.gpa.create(ConnState) catch {
            posix.close(conn_fd);
            return;
        };
        conn.* = .{
            .fd = conn_fd,
            .read_have = 0,
            .write_len = 0,
            .write_pos = 0,
            .keep_alive = true,
            .json_arena = std.heap.ArenaAllocator.init(app.gpa),
        };
        epollAdd(app.epoll_fd, conn_fd, conn, EPOLLIN | EPOLLET | EPOLLRDHUP) catch {
            conn.json_arena.deinit();
            app.gpa.destroy(conn);
            posix.close(conn_fd);
            continue;
        };
    }
}

fn closeConn(app: *App, conn: *ConnState) void {
    _ = posix.epoll_ctl(app.epoll_fd, linux.EPOLL.CTL_DEL, conn.fd, null) catch {};
    posix.close(conn.fd);
    conn.json_arena.deinit();
    app.gpa.destroy(conn);
}

fn handleRead(app: *App, conn: *ConnState) bool {
    while (true) {
        if (conn.read_have >= conn.read_buf.len) return false; // overflow
        const n = posix.read(conn.fd, conn.read_buf[conn.read_have..]) catch |e| switch (e) {
            error.WouldBlock => break,
            else => return false,
        };
        if (n == 0) return false;
        conn.read_have += n;
    }
    // Tenta processar requests no buffer
    while (true) {
        const req = parseRequest(conn.read_buf[0..conn.read_have]) catch |e| switch (e) {
            error.Incomplete => return true,
            error.BadRequest, error.TooLarge => {
                @memcpy(conn.write_buf[0..ResponseBad.len], ResponseBad);
                conn.write_len = ResponseBad.len;
                conn.write_pos = 0;
                conn.keep_alive = false;
                return tryFlush(app, conn);
            },
        };
        handle(app, conn, req);
        const remaining = conn.read_have - req.consumed;
        if (remaining > 0) {
            std.mem.copyForwards(u8, conn.read_buf[0..remaining], conn.read_buf[req.consumed..conn.read_have]);
        }
        conn.read_have = remaining;
        if (!tryFlush(app, conn)) return false;
        if (!conn.keep_alive) return false;
        if (conn.read_have == 0) return true;
    }
}

fn tryFlush(app: *App, conn: *ConnState) bool {
    while (conn.write_pos < conn.write_len) {
        const n = posix.write(conn.fd, conn.write_buf[conn.write_pos..conn.write_len]) catch |e| switch (e) {
            error.WouldBlock => {
                epollMod(app.epoll_fd, conn.fd, conn, EPOLLIN | EPOLLOUT | EPOLLET | EPOLLRDHUP) catch return false;
                return true;
            },
            else => return false,
        };
        if (n == 0) return false;
        conn.write_pos += n;
    }
    conn.write_len = 0;
    conn.write_pos = 0;
    return true;
}

fn handleWrite(app: *App, conn: *ConnState) bool {
    if (!tryFlush(app, conn)) return false;
    if (conn.write_len == 0) {
        epollMod(app.epoll_fd, conn.fd, conn, EPOLLIN | EPOLLET | EPOLLRDHUP) catch return false;
    }
    return true;
}

fn serve(app: *App) !void {
    var events: [128]linux.epoll_event = undefined;
    while (true) {
        const n = posix.epoll_wait(app.epoll_fd, &events, -1);
        for (events[0..n]) |ev| {
            if (ev.data.ptr == 0) {
                acceptAll(app);
                continue;
            }
            const conn: *ConnState = @ptrFromInt(ev.data.ptr);
            if (ev.events & (EPOLLHUP | EPOLLERR | EPOLLRDHUP) != 0) {
                closeConn(app, conn);
                continue;
            }
            var keep: bool = true;
            if (ev.events & EPOLLIN != 0) {
                keep = handleRead(app, conn);
            }
            if (keep and ev.events & EPOLLOUT != 0) {
                keep = handleWrite(app, conn);
            }
            if (!keep) closeConn(app, conn);
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

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
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

    const epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
    var ev: linux.epoll_event = .{ .events = EPOLLIN, .data = .{ .ptr = 0 } };
    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &ev);

    var app = App{
        .index = &idx,
        .cfg = cfg.search,
        .epoll_fd = epfd,
        .listener_fd = listener_fd,
        .gpa = gpa,
    };

    try serve(&app);
}
