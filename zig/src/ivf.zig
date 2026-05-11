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

pub const BlockSize: usize = 8;
pub const BlockStride: usize = BlockSize * types.Dim; // 112 i16 por bloco

pub const IvfIndex = struct {
    n_vectors: usize,
    n_clusters: usize,
    quant_scale: f32,
    version: u32,
    n_blocks: usize, // 0 quando v2 SoA

    centroids: [*]const f32,
    bbox_min: [*]const i16,
    bbox_max: [*]const i16,
    offsets: [*]const u32,
    block_offsets: ?[*]const u32, // null em v2
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
        .{ .TYPE = .SHARED, .POPULATE = true },
        file.handle,
        0,
    );

    // Padrão de acesso aleatório por cluster — instrui kernel a não fazer
    // read-ahead sequencial agressivo (que pollui cache).
    std.posix.madvise(mapped.ptr, size, std.posix.MADV.RANDOM) catch {};

    const header_ptr: *const Header = @ptrCast(@alignCast(mapped.ptr));
    if (!std.mem.eql(u8, &header_ptr.magic, &Magic)) return error.BadMagic;
    if (header_ptr.dim != types.Dim) return error.DimMismatch;

    const version = header_ptr.version;
    const flags = header_ptr.flags;
    const is_blocks = version == 3 and (flags & 0x4) != 0;
    const is_soa = version == 2 and (flags & 0x1) != 0;
    if (!is_blocks and !is_soa) return error.UnsupportedVersion;

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

    var block_offs_ptr: ?[*]const u32 = null;
    var n_blocks: usize = 0;
    if (is_blocks) {
        off = alignUp(off, Align);
        const block_offs_off = off;
        off += (n_clu + 1) * @sizeOf(u32);
        if (off > size) return error.BlockOverflow;
        block_offs_ptr = @ptrCast(@alignCast(mapped.ptr + block_offs_off));
        // total blocks = block_offsets[n_clu]
        n_blocks = @as(usize, block_offs_ptr.?[n_clu]);
    }

    off = alignUp(off, Align);
    const lbl_off = off;
    off += n_vec * @sizeOf(u8);
    if (off > size) return error.BlockOverflow;

    off = alignUp(off, Align);
    const vec_off = off;
    if (is_blocks) {
        off += n_blocks * BlockStride * @sizeOf(i16);
    } else {
        off += n_vec * types.Dim * @sizeOf(i16);
    }
    if (off > size) return error.BlockOverflow;

    return IvfIndex{
        .n_vectors = n_vec,
        .n_clusters = n_clu,
        .quant_scale = header_ptr.quant_scale,
        .version = version,
        .n_blocks = n_blocks,
        .centroids = @ptrCast(@alignCast(mapped.ptr + c_off)),
        .bbox_min = @ptrCast(@alignCast(mapped.ptr + bmin_off)),
        .bbox_max = @ptrCast(@alignCast(mapped.ptr + bmax_off)),
        .offsets = @ptrCast(@alignCast(mapped.ptr + offs_off)),
        .block_offsets = block_offs_ptr,
        .labels = mapped.ptr + lbl_off,
        .vectors = @ptrCast(@alignCast(mapped.ptr + vec_off)),
        .mmap_ptr = mapped,
    };
}
