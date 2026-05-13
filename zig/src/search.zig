//! Busca IVF top-K=5 sobre índice mmap'd v2 (SoA per-cluster).
//!
//! Cálculo SIMD via `@Vector(8, i32)`: processa 8 candidatos por iteração,
//! acumulando em 4 chunks de dims (cada chunk ≤ 4 dims, evita overflow i32).
//!
//! Pipeline:
//!   1. Distância query→centroides (f32) → escolhe nprobe.
//!   2. Para cada cluster sondado, distâncias batch para todos N candidatos.
//!   3. Atualiza top-5 com worst-tracking.
//!   4. (Opcional) bbox_repair: se N fraudes ∈ [repair_min, repair_max], sonda
//!      clusters cuja bbox pode conter ponto < threshold.

const std = @import("std");
const types = @import("types.zig");
const ivf = @import("ivf.zig");

/// Tamanho máximo de shortlist (capacity fixa em stack — evita alloc).
pub const MaxShortlist: usize = 64;

pub const SearchConfig = struct {
    /// Legacy: nprobe simples (usado quando fast_probe == 0).
    nprobe: u32 = 4,
    /// Two-stage probe: fast pass probes shortlist[0..fast_probe].
    /// Se 0, usa path legacy com nprobe + bbox_repair.
    fast_probe: u32 = 0,
    /// Rescue: probes adicionais shortlist[fast_probe..fast_probe+rescue_probe]
    /// quando o gating de reprobe dispara.
    rescue_probe: u32 = 20,
    /// Tamanho da shortlist ordenada por distância (≤ MaxShortlist).
    shortlist_size: u32 = 24,
    /// Janela ambígua (cardinal) que dispara reprobe — fallback se thresholds
    /// estiverem todos zero. Mantido pra compatibilidade.
    ambig_min: u32 = 1,
    ambig_max: u32 = 4,
    /// Per-class worst-distance threshold: se top5.worst_dist >= threshold[fc],
    /// dispara reprobe. Calibrado offline. Quando todos == 0, cai pra ambig window.
    extreme_thresholds: [6]i64 = .{ 0, 0, 0, 0, 0, 0 },
    /// Legacy bbox repair (usado só quando fast_probe == 0, ou como fallback final).
    bbox_repair: bool = true,
    repair_min: u32 = 1,
    repair_max: u32 = 4,
};

pub const Top5 = struct {
    distances: [types.K]i64 = [_]i64{std.math.maxInt(i64)} ** types.K,
    labels: [types.K]u8 = [_]u8{0} ** types.K,
    worst: usize = 0,

    pub fn refreshWorst(self: *Top5) void {
        var w: usize = 0;
        var i: usize = 1;
        while (i < types.K) : (i += 1) {
            if (self.distances[i] > self.distances[w]) w = i;
        }
        self.worst = w;
    }

    pub fn tryInsert(self: *Top5, dist: i64, label: u8) void {
        if (dist >= self.distances[self.worst]) return;
        self.distances[self.worst] = dist;
        self.labels[self.worst] = label;
        self.refreshWorst();
    }

    pub fn fraudCount(self: *const Top5) u8 {
        var n: u8 = 0;
        for (self.labels) |l| n += l;
        return n;
    }
};

fn squaredCentroidDistance(idx: *const ivf.IvfIndex, c: usize, q: types.QueryF32) f32 {
    const base = c * types.Dim;
    var s: f32 = 0;
    inline for (0..types.Dim) |d| {
        const diff = idx.centroids[base + d] - q[d];
        s += diff * diff;
    }
    return s;
}

fn bboxMinSqDistance(idx: *const ivf.IvfIndex, c: usize, q: types.QueryI16) i64 {
    const base = c * types.Dim;
    var s: i64 = 0;
    inline for (0..types.Dim) |d| {
        const qv: i32 = q[d];
        const lo: i32 = idx.bbox_min[base + d];
        const hi: i32 = idx.bbox_max[base + d];
        const delta: i32 = if (qv < lo) lo - qv else if (qv > hi) qv - hi else 0;
        s += @as(i64, delta) * @as(i64, delta);
    }
    return s;
}

fn nearestCentroids(
    idx: *const ivf.IvfIndex,
    q: types.QueryF32,
    nprobe: usize,
    out_buf: []usize,
) void {
    std.debug.assert(nprobe <= out_buf.len);
    std.debug.assert(nprobe <= MaxShortlist);
    var dists: [MaxShortlist]f32 = [_]f32{std.math.floatMax(f32)} ** MaxShortlist;
    for (0..nprobe) |i| out_buf[i] = std.math.maxInt(usize);

    var c: usize = 0;
    while (c < idx.n_clusters) : (c += 1) {
        const d = squaredCentroidDistance(idx, c, q);
        if (d < dists[nprobe - 1]) {
            var j: usize = nprobe - 1;
            while (j > 0 and dists[j - 1] > d) : (j -= 1) {
                dists[j] = dists[j - 1];
                out_buf[j] = out_buf[j - 1];
            }
            dists[j] = d;
            out_buf[j] = c;
        }
    }
}

const Chunk = struct { start: u32, end: u32 };
const DimChunks = [_]Chunk{
    .{ .start = 0, .end = 4 },
    .{ .start = 4, .end = 8 },
    .{ .start = 8, .end = 12 },
    .{ .start = 12, .end = 14 },
};

fn searchClusterSoA(idx: *const ivf.IvfIndex, c: usize, q: types.QueryI16, top: *Top5) void {
    const s: usize = idx.offsets[c];
    const e: usize = idx.offsets[c + 1];
    const n = e - s;
    if (n == 0) return;

    const block: [*]const i16 = idx.vectors + s * types.Dim;
    var q_f32: [types.Dim]f32 = undefined;
    inline for (0..types.Dim) |d| q_f32[d] = @floatFromInt(q[d]);

    var i: usize = 0;
    while (i + 8 <= n) : (i += 8) {
        var sum_lo: @Vector(8, f32) = @splat(0);
        inline for (0..8) |d| {
            const slice_ptr = block + d * n + i;
            const v_i16: @Vector(8, i16) = slice_ptr[0..8].*;
            const v_i32: @Vector(8, i32) = v_i16;
            const v_f32: @Vector(8, f32) = @floatFromInt(v_i32);
            const q_v: @Vector(8, f32) = @splat(q_f32[d]);
            const diff = v_f32 - q_v;
            sum_lo = @mulAdd(@Vector(8, f32), diff, diff, sum_lo);
        }
        const thr: f32 = @floatFromInt(top.distances[top.worst]);
        const thr_v: @Vector(8, f32) = @splat(thr);
        const lt_mask = sum_lo < thr_v;
        if (!@reduce(.Or, lt_mask)) continue;

        var sum_hi: @Vector(8, f32) = @splat(0);
        inline for (8..14) |d| {
            const slice_ptr = block + d * n + i;
            const v_i16: @Vector(8, i16) = slice_ptr[0..8].*;
            const v_i32: @Vector(8, i32) = v_i16;
            const v_f32: @Vector(8, f32) = @floatFromInt(v_i32);
            const q_v: @Vector(8, f32) = @splat(q_f32[d]);
            const diff = v_f32 - q_v;
            sum_hi = @mulAdd(@Vector(8, f32), diff, diff, sum_hi);
        }
        const total = sum_lo + sum_hi;
        const total_arr: [8]f32 = total;
        inline for (0..8) |j| {
            top.tryInsert(@intFromFloat(total_arr[j]), idx.labels[s + i + j]);
        }
    }

    while (i < n) : (i += 1) {
        var sum: i64 = 0;
        var d: usize = 0;
        while (d < types.Dim) : (d += 1) {
            const v: i32 = block[d * n + i];
            const qd: i32 = q[d];
            const diff = v - qd;
            sum += @as(i64, diff) * @as(i64, diff);
        }
        top.tryInsert(sum, idx.labels[s + i]);
    }
}

fn searchClusterBlocks(idx: *const ivf.IvfIndex, c: usize, q: types.QueryI16, top: *Top5) void {
    const s: usize = idx.offsets[c];
    const e: usize = idx.offsets[c + 1];
    const n_valid = e - s;
    if (n_valid == 0) return;

    const block_offsets = idx.block_offsets orelse return;
    const bk_start: usize = block_offsets[c];
    const bk_end: usize = block_offsets[c + 1];
    const n_blocks = bk_end - bk_start;
    if (n_blocks == 0) return;

    var q_f32: [types.Dim]f32 = undefined;
    inline for (0..types.Dim) |d| q_f32[d] = @floatFromInt(q[d]);

    const prefetch_dist: usize = 2; // 2 blocks à frente cobre ~448B / ~7 cache lines

    var bk: usize = 0;
    while (bk < n_blocks) : (bk += 1) {
        const block_ptr = idx.vectors + (bk_start + bk) * ivf.BlockStride;

        // Prefetch do bloco bk+prefetch_dist (T0, read, data).
        if (bk + prefetch_dist < n_blocks) {
            const pf_ptr = idx.vectors + (bk_start + bk + prefetch_dist) * ivf.BlockStride;
            @prefetch(pf_ptr, .{ .rw = .read, .locality = 3, .cache = .data });
        }

        // dims 0..7 — FMA com acumulador f32×8
        var sum_lo: @Vector(8, f32) = @splat(0);
        inline for (0..8) |d| {
            const slot = block_ptr + d * ivf.BlockSize;
            const v_i16: @Vector(8, i16) = slot[0..8].*;
            const v_i32: @Vector(8, i32) = v_i16;
            const v_f32: @Vector(8, f32) = @floatFromInt(v_i32);
            const q_v: @Vector(8, f32) = @splat(q_f32[d]);
            const diff = v_f32 - q_v;
            sum_lo = @mulAdd(@Vector(8, f32), diff, diff, sum_lo);
        }

        // Partial threshold rejection
        const thr: f32 = @floatFromInt(top.distances[top.worst]);
        const lt_mask = sum_lo < @as(@Vector(8, f32), @splat(thr));
        if (!@reduce(.Or, lt_mask)) continue;

        // dims 8..13 (6 dims)
        var sum_hi: @Vector(8, f32) = @splat(0);
        inline for (8..14) |d| {
            const slot = block_ptr + d * ivf.BlockSize;
            const v_i16: @Vector(8, i16) = slot[0..8].*;
            const v_i32: @Vector(8, i32) = v_i16;
            const v_f32: @Vector(8, f32) = @floatFromInt(v_i32);
            const q_v: @Vector(8, f32) = @splat(q_f32[d]);
            const diff = v_f32 - q_v;
            sum_hi = @mulAdd(@Vector(8, f32), diff, diff, sum_hi);
        }

        const total = sum_lo + sum_hi;
        const total_arr: [8]f32 = total;
        const base_idx = bk * ivf.BlockSize;
        const lane_count = @min(@as(usize, ivf.BlockSize), n_valid - base_idx);
        var j: usize = 0;
        while (j < lane_count) : (j += 1) {
            top.tryInsert(@intFromFloat(total_arr[j]), idx.labels[s + base_idx + j]);
        }
    }
}

fn searchCluster(idx: *const ivf.IvfIndex, c: usize, q: types.QueryI16, top: *Top5) void {
    if (idx.version == 3) {
        searchClusterBlocks(idx, c, q, top);
    } else {
        searchClusterSoA(idx, c, q, top);
    }
}

pub fn fraudCount(
    idx: *const ivf.IvfIndex,
    qF: types.QueryF32,
    qI: types.QueryI16,
    cfg: SearchConfig,
) u8 {
    // Path novo two-stage: fast_probe > 0 ativa shortlist.
    if (cfg.fast_probe > 0) return fraudCountShortlist(idx, qF, qI, cfg);
    return fraudCountLegacy(idx, qF, qI, cfg);
}

fn fraudCountLegacy(
    idx: *const ivf.IvfIndex,
    qF: types.QueryF32,
    qI: types.QueryI16,
    cfg: SearchConfig,
) u8 {
    var top = Top5{};
    var probes_buf: [8]usize = undefined;
    const nprobe = @min(@max(cfg.nprobe, 1), 8);
    const probes = probes_buf[0..nprobe];
    nearestCentroids(idx, qF, nprobe, probes);

    for (probes) |c| {
        if (c != std.math.maxInt(usize)) searchCluster(idx, c, qI, &top);
    }

    var fraud = top.fraudCount();

    if (cfg.bbox_repair and fraud >= cfg.repair_min and fraud <= cfg.repair_max) {
        const threshold = top.distances[top.worst];
        var c: usize = 0;
        while (c < idx.n_clusters) : (c += 1) {
            var probed = false;
            for (probes) |p| {
                if (p == c) {
                    probed = true;
                    break;
                }
            }
            if (probed) continue;
            if (bboxMinSqDistance(idx, c, qI) >= threshold) continue;
            searchCluster(idx, c, qI, &top);
        }
        fraud = top.fraudCount();
    }

    return fraud;
}

fn fraudCountShortlist(
    idx: *const ivf.IvfIndex,
    qF: types.QueryF32,
    qI: types.QueryI16,
    cfg: SearchConfig,
) u8 {
    const fast: usize = @min(@max(@as(usize, cfg.fast_probe), 1), MaxShortlist);
    const rescue: usize = @min(@as(usize, cfg.rescue_probe), MaxShortlist - fast);
    var shortlist_size: usize = @max(@as(usize, cfg.shortlist_size), fast + rescue);
    shortlist_size = @min(shortlist_size, MaxShortlist);

    var shortlist_buf: [MaxShortlist]usize = undefined;
    const shortlist = shortlist_buf[0..shortlist_size];
    nearestCentroids(idx, qF, shortlist_size, shortlist);

    var top = Top5{};

    // Fast pass: probe shortlist[0..fast].
    for (shortlist[0..fast]) |c| {
        if (c != std.math.maxInt(usize)) searchCluster(idx, c, qI, &top);
    }

    var fraud = top.fraudCount();

    // Reprobe seletivo: shortlist[fast..fast+rescue].
    // Gating principal: per-class worst-distance threshold (calibrado offline).
    // Fallback: janela ambígua cardinal (ambig_min..ambig_max).
    if (rescue > 0) {
        const worst_dist = top.distances[top.worst];
        const has_thr = blk: {
            inline for (cfg.extreme_thresholds) |t| if (t != 0) break :blk true;
            break :blk false;
        };
        const should_reprobe = if (has_thr)
            worst_dist >= cfg.extreme_thresholds[fraud]
        else
            (fraud >= cfg.ambig_min and fraud <= cfg.ambig_max);

        if (should_reprobe) {
            for (shortlist[fast .. fast + rescue]) |c| {
                if (c != std.math.maxInt(usize)) searchCluster(idx, c, qI, &top);
            }
            fraud = top.fraudCount();
        }
    }

    // Fallback bbox repair opcional, após reprobe seletivo.
    if (cfg.bbox_repair and fraud >= cfg.repair_min and fraud <= cfg.repair_max) {
        const threshold = top.distances[top.worst];
        const probed = shortlist[0 .. fast + rescue];
        var c: usize = 0;
        while (c < idx.n_clusters) : (c += 1) {
            var already = false;
            for (probed) |p| {
                if (p == c) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            if (bboxMinSqDistance(idx, c, qI) >= threshold) continue;
            searchCluster(idx, c, qI, &top);
        }
        fraud = top.fraudCount();
    }

    return fraud;
}
