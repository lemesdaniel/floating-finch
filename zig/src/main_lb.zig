//! Load balancer com SCM_RIGHTS fd-passing.
//!
//! Aceita conexões TCP em :9999 e entrega o fd aceito direto para uma das
//! APIs via sendmsg(SCM_RIGHTS) sobre UDS. O LB nunca toca os dados da
//! conexão — depois do handoff a API fala direto com o cliente. Custo por
//! conexão: accept + sendmsg + close (~3 syscalls).
//!
//! Envs:
//!   BIND_PORT          porta TCP (default 9999)
//!   API_SOCKETS        CSV de UDS paths (default /sockets/api1.sock,/sockets/api2.sock)
//!   LB_CONNS_PER_API   canais de controle por API (default 2 — um por worker)

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const std_options: std.Options = .{
    .log_level = .err,
    .logFn = silentLog,
};

fn silentLog(comptime _: std.log.Level, comptime _: @Type(.enum_literal), comptime _: []const u8, _: anytype) void {}

const SCM_RIGHTS: i32 = 0x01;

const Cmsghdr = extern struct {
    len: usize,
    level: i32,
    cmsg_type: i32,
};

const CmsgSpace = (@sizeOf(Cmsghdr) + @sizeOf(posix.fd_t) + 7) & ~@as(usize, 7);

fn sendFd(chan_fd: posix.fd_t, fd: posix.fd_t) !void {
    var data = [1]u8{0};
    var iov = [_]posix.iovec_const{.{ .base = &data, .len = 1 }};
    var cbuf: [CmsgSpace]u8 align(@alignOf(Cmsghdr)) = [_]u8{0} ** CmsgSpace;

    const hdr: *Cmsghdr = @ptrCast(&cbuf);
    hdr.len = @sizeOf(Cmsghdr) + @sizeOf(posix.fd_t);
    hdr.level = linux.SOL.SOCKET;
    hdr.cmsg_type = SCM_RIGHTS;
    const fd_dst: *align(1) posix.fd_t = @ptrCast(cbuf[@sizeOf(Cmsghdr)..].ptr);
    fd_dst.* = fd;

    const msg = posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cbuf,
        .controllen = CmsgSpace,
        .flags = 0,
    };
    const rc = linux.sendmsg(chan_fd, &msg, linux.MSG.NOSIGNAL);
    if (posix.errno(rc) != .SUCCESS) return error.SendFailed;
}

fn connectUdsRetry(path: []const u8, timeout_ms: u64) !posix.fd_t {
    var waited: u64 = 0;
    while (true) {
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return error.SocketFailed;
        var sun: posix.sockaddr.un = undefined;
        sun.family = posix.AF.UNIX;
        @memset(&sun.path, 0);
        if (path.len >= sun.path.len) return error.PathTooLong;
        @memcpy(sun.path[0..path.len], path);
        const sun_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + path.len + 1);
        if (posix.connect(fd, @ptrCast(&sun), sun_len)) {
            return fd;
        } else |_| {
            posix.close(fd);
            if (waited >= timeout_ms) return error.ConnectTimeout;
            std.Thread.sleep(50 * std.time.ns_per_ms);
            waited += 50;
        }
    }
}

fn envOr(name: []const u8, default: []const u8) []const u8 {
    return posix.getenv(name) orelse default;
}

fn envU32(name: []const u8, default: u32) u32 {
    const v = posix.getenv(name) orelse return default;
    return std.fmt.parseUnsigned(u32, v, 10) catch default;
}

const MaxChannels = 16;

pub fn main() !void {
    const port: u16 = @intCast(envU32("BIND_PORT", 9999));
    const sockets_csv = envOr("API_SOCKETS", "/sockets/api1.sock,/sockets/api2.sock");
    const conns_per_api: usize = @intCast(envU32("LB_CONNS_PER_API", 2));

    // TCP listener PRIMEIRO — aceita conexões no backlog enquanto APIs inicializam.
    const listener = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    const one: c_int = 1;
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one));
    var addr: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };
    try posix.bind(listener, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    try posix.listen(listener, 4096);

    // Conecta canais de controle às APIs (retry até 30s pra aguardar startup delas).
    var channels: [MaxChannels]posix.fd_t = undefined;
    var paths: [MaxChannels][]const u8 = undefined;
    var n_chan: usize = 0;

    var k: usize = 0;
    while (k < conns_per_api) : (k += 1) {
        var it = std.mem.splitScalar(u8, sockets_csv, ',');
        while (it.next()) |path| {
            if (path.len == 0) continue;
            if (n_chan >= MaxChannels) break;
            channels[n_chan] = try connectUdsRetry(path, 30_000);
            paths[n_chan] = path;
            n_chan += 1;
        }
    }
    if (n_chan == 0) return error.NoApiChannels;

    var rr: usize = 0;
    while (true) {
        const conn_fd = posix.accept(listener, null, null, posix.SOCK.CLOEXEC) catch continue;

        var attempts: usize = 0;
        var sent = false;
        while (attempts < n_chan) : (attempts += 1) {
            const ch_idx = rr % n_chan;
            rr += 1;
            if (sendFd(channels[ch_idx], conn_fd)) {
                sent = true;
                break;
            } else |_| {
                // Canal morto (API caiu/reiniciou): tenta reconectar uma vez.
                posix.close(channels[ch_idx]);
                if (connectUdsRetry(paths[ch_idx], 1_000)) |new_fd| {
                    channels[ch_idx] = new_fd;
                    if (sendFd(new_fd, conn_fd)) {
                        sent = true;
                        break;
                    } else |_| {}
                } else |_| {}
            }
        }
        // Handoff feito (ou todos os canais mortos): fecha cópia local.
        // O refcount do kernel mantém o fd vivo na API.
        posix.close(conn_fd);
        if (!sent) {
            // Sem API viva: nada a fazer além de dropar a conexão.
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
}
