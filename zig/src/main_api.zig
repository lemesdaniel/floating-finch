//! API server que adota fds recebidos do LB via SCM_RIGHTS.
//!
//! Arquitetura: W workers, cada um com epoll próprio e canal de controle UDS
//! próprio — zero locks, cada conexão vive em exatamente um worker.
//!
//! O LB abre LB_CONNS_PER_API conexões no nosso UDS listener; o main thread
//! distribui cada control-conn aceita round-robin entre os workers. O worker
//! faz recvmsg(SCM_RIGHTS) no seu canal, seta TCP_NODELAY + O_NONBLOCK no fd
//! adotado e o registra no seu epoll como conexão HTTP normal (edge-triggered,
//! parser zero-alloc, respostas pré-formatadas).
//!
//! Envs:
//!   UDS_PATH        path do listener UDS (obrigatório)
//!   API_WORKERS     workers (default 2)
//!   INDEX_PATH      index.bin
//!   IVF_*           SearchConfig (igual main.zig)

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

// -------- Respostas pré-formatadas (globais, compartilhadas entre workers) --------

const ResponseReady = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n";
const ResponseBad = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const ResponseNotFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

var fraud_resp_storage: [6][512]u8 = undefined;
var FraudResponses: [6][]const u8 = undefined;

fn initFraudResponses() void {
    const tpl = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}";
    for (0..6) |i| {
        const body = types.ResponseByFraudCount[i];
        FraudResponses[i] = std.fmt.bufPrint(&fraud_resp_storage[i], tpl, .{ body.len, body }) catch unreachable;
    }
}

// -------- Config --------

const Config = struct {
    uds_path: []const u8,
    index_path: []const u8,
    workers: usize,
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
        .workers = @intCast(envU32("API_WORKERS", 2)),
        .search = .{
            .nprobe = envU32("IVF_NPROBE", 4),
            .bbox_repair = envBool("IVF_BBOX_REPAIR", true),
            .repair_min = envU32("IVF_REPAIR_MIN", 1),
            .repair_max = envU32("IVF_REPAIR_MAX", 4),
        },
    };
}

// -------- HTTP parser minimal (idêntico ao main_epoll.zig v9) --------

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

// -------- SCM_RIGHTS recv --------

const SCM_RIGHTS: i32 = 0x01;

const Cmsghdr = extern struct {
    len: usize,
    level: i32,
    cmsg_type: i32,
};

/// Recebe fds do canal de controle. Retorna quantos fds preencheu em `out`,
/// error.WouldBlock quando drenou, error.Closed se o LB fechou o canal.
fn recvFds(chan_fd: posix.fd_t, out: []posix.fd_t) !usize {
    var data: [64]u8 = undefined;
    var iov = [_]posix.iovec{.{ .base = &data, .len = data.len }};
    var cbuf: [512]u8 align(@alignOf(Cmsghdr)) = undefined;

    var msg = posix.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cbuf,
        .controllen = cbuf.len,
        .flags = 0,
    };
    const rc = linux.recvmsg(chan_fd, &msg, linux.MSG.CMSG_CLOEXEC);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .AGAIN => return error.WouldBlock,
        .INTR => return error.WouldBlock,
        else => return error.RecvFailed,
    }
    if (rc == 0) return error.Closed;

    var count: usize = 0;
    var off: usize = 0;
    const clen: usize = msg.controllen;
    while (off + @sizeOf(Cmsghdr) <= clen) {
        const hdr: *const Cmsghdr = @alignCast(@ptrCast(&cbuf[off]));
        if (hdr.len < @sizeOf(Cmsghdr)) break;
        if (hdr.level == linux.SOL.SOCKET and hdr.cmsg_type == SCM_RIGHTS) {
            const nfds = (hdr.len - @sizeOf(Cmsghdr)) / @sizeOf(posix.fd_t);
            const fds_ptr: [*]align(1) const posix.fd_t = @ptrCast(cbuf[off + @sizeOf(Cmsghdr) ..].ptr);
            var i: usize = 0;
            while (i < nfds) : (i += 1) {
                if (count < out.len) {
                    out[count] = fds_ptr[i];
                    count += 1;
                } else {
                    posix.close(fds_ptr[i]); // sem espaço: não vaza fd
                }
            }
        }
        const step = (hdr.len + 7) & ~@as(usize, 7);
        if (step == 0) break;
        off += step;
    }
    return count;
}

// -------- Conn state --------

const ReadBufSize: usize = 32 * 1024;
const WriteBufSize: usize = 256;

// Tag no epoll data.ptr: bit 0 = control conn (ponteiros são aligned ≥ 8).
const TagControl: usize = 1;

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

const ControlConn = struct {
    fd: posix.fd_t,
};

const Worker = struct {
    epfd: posix.fd_t,
    index: *const ivf.IvfIndex,
    cfg: search.SearchConfig,
    gpa: std.mem.Allocator,
};

// -------- Handler --------

fn handle(w: *Worker, conn: *ConnState, req: HttpReq) void {
    conn.keep_alive = req.keep_alive;
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/fraud-score")) {
        _ = conn.json_arena.reset(.retain_capacity);
        var fc: u8 = 0;
        if (vectorize.vectorizeBody(req.body, conn.json_arena.allocator())) |qF| {
            const qI = quantize.quantizeQuery(qF);
            fc = search.fraudCount(w.index, qF, qI, w.cfg);
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
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/ready")) {
        @memcpy(conn.write_buf[0..ResponseReady.len], ResponseReady);
        conn.write_len = ResponseReady.len;
        conn.write_pos = 0;
        return;
    }
    @memcpy(conn.write_buf[0..ResponseNotFound.len], ResponseNotFound);
    conn.write_len = ResponseNotFound.len;
    conn.write_pos = 0;
    conn.keep_alive = false;
}

// -------- epoll helpers --------

const EPOLLIN: u32 = linux.EPOLL.IN;
const EPOLLOUT: u32 = linux.EPOLL.OUT;
const EPOLLET: u32 = linux.EPOLL.ET;
const EPOLLHUP: u32 = linux.EPOLL.HUP;
const EPOLLRDHUP: u32 = linux.EPOLL.RDHUP;
const EPOLLERR: u32 = linux.EPOLL.ERR;

fn epollAddPtr(epfd: posix.fd_t, fd: posix.fd_t, data_ptr: usize, events: u32) !void {
    var ev: linux.epoll_event = .{ .events = events, .data = .{ .ptr = data_ptr } };
    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev);
}

fn epollMod(epfd: posix.fd_t, fd: posix.fd_t, conn: *ConnState, events: u32) !void {
    var ev: linux.epoll_event = .{ .events = events, .data = .{ .ptr = @intFromPtr(conn) } };
    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &ev);
}

fn setNonBlock(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return;
    _ = posix.fcntl(fd, posix.F.SETFL, flags | @as(usize, 0o4000)) catch {};
}

fn setNoDelay(fd: posix.fd_t) void {
    const one: c_int = 1;
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
}

// -------- Conn lifecycle --------

fn adoptFd(w: *Worker, fd: posix.fd_t) void {
    setNonBlock(fd);
    setNoDelay(fd);
    const conn = w.gpa.create(ConnState) catch {
        posix.close(fd);
        return;
    };
    conn.* = .{
        .fd = fd,
        .read_have = 0,
        .write_len = 0,
        .write_pos = 0,
        .keep_alive = true,
        .json_arena = std.heap.ArenaAllocator.init(w.gpa),
    };
    // Dados podem já estar disponíveis quando o fd é adotado. Com EPOLLET, o
    // kernel só notifica na transição "sem dados"→"tem dados". Se dados chegaram
    // antes do epoll_ctl_add, precisamos drenar agora; depois o epoll notifica
    // novas chegadas.
    //
    // tryFlush dentro de handleRead pode chamar epollMod (EPOLLOUT) se o buffer
    // TCP estiver cheio — nesse caso o fd já está no epoll e não fazemos ADD.
        // Level-triggered: simples, sem risco de missed-edge em fd adotado via SCM_RIGHTS.
    epollAddPtr(w.epfd, fd, @intFromPtr(conn), EPOLLIN | EPOLLRDHUP) catch {
        conn.json_arena.deinit();
        w.gpa.destroy(conn);
        posix.close(fd);
        return;
    };
    // Drena dados já disponíveis.
    if (!handleRead(w, conn)) {
        closeConn(w, conn);
    }
}

fn drainControl(w: *Worker, ctrl: *ControlConn) void {
    var fds: [32]posix.fd_t = undefined;
    while (true) {
        const n = recvFds(ctrl.fd, &fds) catch |e| switch (e) {
            error.WouldBlock => return,
            else => {
                // LB fechou/morreu: remove canal; conexões existentes seguem vivas.
                _ = posix.epoll_ctl(w.epfd, linux.EPOLL.CTL_DEL, ctrl.fd, null) catch {};
                posix.close(ctrl.fd);
                w.gpa.destroy(ctrl);
                return;
            },
        };
        for (fds[0..n]) |fd| adoptFd(w, fd);
    }
}

fn closeConn(w: *Worker, conn: *ConnState) void {
    _ = posix.epoll_ctl(w.epfd, linux.EPOLL.CTL_DEL, conn.fd, null) catch {};
    posix.close(conn.fd);
    conn.json_arena.deinit();
    w.gpa.destroy(conn);
}

fn handleRead(w: *Worker, conn: *ConnState) bool {
    while (true) {
        if (conn.read_have >= conn.read_buf.len) return false;
        const n = posix.read(conn.fd, conn.read_buf[conn.read_have..]) catch |e| switch (e) {
            error.WouldBlock => break,
            else => return false,
        };
        if (n == 0) return false;
        conn.read_have += n;
    }
    while (true) {
        const req = parseRequest(conn.read_buf[0..conn.read_have]) catch |e| switch (e) {
            error.Incomplete => return true,
            error.BadRequest, error.TooLarge => {
                @memcpy(conn.write_buf[0..ResponseBad.len], ResponseBad);
                conn.write_len = ResponseBad.len;
                conn.write_pos = 0;
                conn.keep_alive = false;
                return tryFlush(w, conn);
            },
        };
        handle(w, conn, req);
        const remaining = conn.read_have - req.consumed;
        if (remaining > 0) {
            std.mem.copyForwards(u8, conn.read_buf[0..remaining], conn.read_buf[req.consumed..conn.read_have]);
        }
        conn.read_have = remaining;
        if (!tryFlush(w, conn)) return false;
        if (!conn.keep_alive) return false;
        if (conn.read_have == 0) return true;
    }
}

fn tryFlush(w: *Worker, conn: *ConnState) bool {
    while (conn.write_pos < conn.write_len) {
        const n = posix.write(conn.fd, conn.write_buf[conn.write_pos..conn.write_len]) catch |e| switch (e) {
            error.WouldBlock => {
                epollMod(w.epfd, conn.fd, conn, EPOLLIN | EPOLLOUT | EPOLLRDHUP) catch return false;
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

fn handleWrite(w: *Worker, conn: *ConnState) bool {
    if (!tryFlush(w, conn)) return false;
    if (conn.write_len == 0) {
        epollMod(w.epfd, conn.fd, conn, EPOLLIN | EPOLLRDHUP) catch return false;
    }
    return true;
}

fn workerLoop(w: *Worker) void {
    var events: [128]linux.epoll_event = undefined;
    while (true) {
        const n = posix.epoll_wait(w.epfd, &events, -1);
        for (events[0..n]) |ev| {
            if (ev.data.ptr & TagControl != 0) {
                const ctrl: *ControlConn = @ptrFromInt(ev.data.ptr & ~TagControl);
                drainControl(w, ctrl);
                continue;
            }
            const conn: *ConnState = @ptrFromInt(ev.data.ptr);
            // Hard errors: close immediately.
            if (ev.events & (EPOLLHUP | EPOLLERR) != 0) {
                closeConn(w, conn);
                continue;
            }
            // EPOLLRDHUP: peer closed their write end. Still drain any buffered
            // data before closing — this fires together with EPOLLIN when the
            // peer sends data and then closes (e.g. HTTP/1.0 short request).
            var keep: bool = true;
            if (ev.events & EPOLLIN != 0) keep = handleRead(w, conn);
            if (keep and ev.events & EPOLLOUT != 0) keep = handleWrite(w, conn);
            // Close after draining if peer half-closed and nothing left to write.
            if (keep and ev.events & EPOLLRDHUP != 0 and conn.write_len == 0) keep = false;
            if (!keep) closeConn(w, conn);
        }
    }
}

// -------- Pre-warm + UDS bind --------

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
    try posix.listen(fd, 64);
    _ = std.c.chmod(path_z, 0o666);
    return fd;
}

pub fn main() !void {
    const cfg = loadConfig();
    const gpa = std.heap.c_allocator;

    initFraudResponses();

    var idx = try ivf.loadIndex(cfg.index_path);
    defer idx.deinit();

    prewarmSearch(&idx, cfg.search, 500);

    if (cfg.uds_path.len == 0) return error.UdsRequired;
    const listener_fd = try bindUds(cfg.uds_path);

    const n_workers = @max(cfg.workers, 1);
    var workers: [8]Worker = undefined;
    var w: usize = 0;
    while (w < n_workers and w < workers.len) : (w += 1) {
        workers[w] = .{
            .epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC),
            .index = &idx,
            .cfg = cfg.search,
            .gpa = gpa,
        };
        _ = try std.Thread.spawn(.{}, workerLoop, .{&workers[w]});
    }
    const n_spawned = w;

    // Main thread: aceita control-conns do LB e distribui round-robin.
    var rr: usize = 0;
    while (true) {
        const ctrl_fd = posix.accept(listener_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch |e| switch (e) {
            error.WouldBlock => {
                // accept bloqueante seria ideal; listener é blocking? Criado sem
                // NONBLOCK, então accept bloqueia — este branch não dispara.
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => continue,
        };
        const target = &workers[rr % n_spawned];
        rr += 1;
        const ctrl = gpa.create(ControlConn) catch {
            posix.close(ctrl_fd);
            continue;
        };
        ctrl.* = .{ .fd = ctrl_fd };
        epollAddPtr(target.epfd, ctrl_fd, @intFromPtr(ctrl) | TagControl, EPOLLIN | EPOLLET) catch {
            gpa.destroy(ctrl);
            posix.close(ctrl_fd);
        };
    }
}
