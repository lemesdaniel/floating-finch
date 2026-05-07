//! Carregamento do index.bin v2 (SoA per-cluster) via mmap.

const std = @import("std");
const types = @import("types.zig");

const HeaderSize: usize = 64;
const Align: usize = 64;
const Magic = [4]u8{ 'R', 'I', 'V', 'F' };

const Header = extern struct {
    magic: [4]u8,
    version: u32,
    n_vectors: u32,
    n_clusters: u32,
    dim: u32,
    quant_scale: f32,
    flags: u64,
    reserved: [32]u8,
};

pub const IvfIndex = struct {
    n_vectors: usize,
    n_clusters: usize,
    quant_scale: f32,

    centroids: [*]const f32,
    bbox_min: [*]const i16,
    bbox_max: [*]const i16,
    offsets: [*]const u32,
    labels: [*]const u8,
    vectors: [*]const i16,

    mmap_ptr: []align(std.heap.page_size_min) u8,

    pub fn deinit(self: *IvfIndex) void {
        std.posix.munmap(self.mmap_ptr);
    }
};

fn alignUp(x: usize, a: usize) usize {
    return (x + a - 1) & ~(a - 1);
}

pub fn loadIndex(path: []const u8) !IvfIndex {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    const stat = try file.stat();
    const size: usize = @intCast(stat.size);
    if (size < HeaderSize) return error.FileTooSmall;

    const mapped = try std.posix.mmap(
        null,
        size,
        std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );

    const header_ptr: *const Header = @ptrCast(@alignCast(mapped.ptr));
    if (!std.mem.eql(u8, &header_ptr.magic, &Magic)) return error.BadMagic;
    if (header_ptr.version != 2) return error.UnsupportedVersion;
    if (header_ptr.dim != types.Dim) return error.DimMismatch;
    if ((header_ptr.flags & 0x1) == 0) return error.SoAFlagMissing;

    const n_vec: usize = @intCast(header_ptr.n_vectors);
    const n_clu: usize = @intCast(header_ptr.n_clusters);

    var off: usize = HeaderSize;

    off = alignUp(off, Align);
    const c_off = off;
    off += n_clu * types.Dim * @sizeOf(f32);
    if (off > size) return error.BlockOverflow;

    off = alignUp(off, Align);
    const bmin_off = off;
    off += n_clu * types.Dim * @sizeOf(i16);
    if (off > size) return error.BlockOverflow;

    off = alignUp(off, Align);
    const bmax_off = off;
    off += n_clu * types.Dim * @sizeOf(i16);
    if (off > size) return error.BlockOverflow;

    off = alignUp(off, Align);
    const offs_off = off;
    off += (n_clu + 1) * @sizeOf(u32);
    if (off > size) return error.BlockOverflow;

    off = alignUp(off, Align);
    const lbl_off = off;
    off += n_vec * @sizeOf(u8);
    if (off > size) return error.BlockOverflow;

    off = alignUp(off, Align);
    const vec_off = off;
    off += n_vec * types.Dim * @sizeOf(i16);
    if (off > size) return error.BlockOverflow;

    return IvfIndex{
        .n_vectors = n_vec,
        .n_clusters = n_clu,
        .quant_scale = header_ptr.quant_scale,
        .centroids = @ptrCast(@alignCast(mapped.ptr + c_off)),
        .bbox_min = @ptrCast(@alignCast(mapped.ptr + bmin_off)),
        .bbox_max = @ptrCast(@alignCast(mapped.ptr + bmax_off)),
        .offsets = @ptrCast(@alignCast(mapped.ptr + offs_off)),
        .labels = mapped.ptr + lbl_off,
        .vectors = @ptrCast(@alignCast(mapped.ptr + vec_off)),
        .mmap_ptr = mapped,
    };
}
