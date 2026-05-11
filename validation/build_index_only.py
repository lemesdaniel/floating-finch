"""Pipeline de build do index.bin (sem bench/GT — para uso no Dockerfile).

Encadeia: load_references → k-means + IVF cache → emit binary.
Reusa as constantes/parâmetros calibrados em §6.7 e §6.10.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path
from time import perf_counter

import numpy as np
from sklearn.cluster import MiniBatchKMeans

from dataset import DATA_DIR, load_references

DIM = 14
QUANT_SCALE = 10_000.0
CLUSTERS = 2048
TRAIN_SAMPLE = 65_536
ITERATIONS = 6
SEED = 42

INDEX_CACHE = DATA_DIR / "ivf_kmeans.npz"
HEADER_SIZE = 64
ALIGN = 64
MAGIC = b"RIVF"


def quantize_i16(vectors_f32: np.ndarray) -> np.ndarray:
    return np.where(
        vectors_f32 == -1.0, int(-QUANT_SCALE),
        np.rint(np.clip(vectors_f32, 0.0, 1.0) * QUANT_SCALE).astype(np.int32),
    ).astype(np.int16)


def build_ivf(refs: np.ndarray, labels: np.ndarray) -> dict:
    if INDEX_CACHE.exists():
        print(f"[ivf] reusing cache {INDEX_CACHE}")
        return dict(np.load(INDEX_CACHE))

    print(f"[ivf] training k-means: n={len(refs):,} k={CLUSTERS} sample={TRAIN_SAMPLE} iters={ITERATIONS}")
    rng = np.random.default_rng(SEED)
    train_idx = rng.choice(len(refs), size=TRAIN_SAMPLE, replace=False)
    t0 = perf_counter()
    km = MiniBatchKMeans(
        n_clusters=CLUSTERS, init="k-means++", n_init=1,
        max_iter=ITERATIONS, batch_size=4096, random_state=SEED,
    ).fit(refs[train_idx])
    print(f"[ivf] kmeans fit em {perf_counter() - t0:.1f}s; assigning all…")
    cluster_id = km.predict(refs).astype(np.int32)
    sort_order = np.argsort(cluster_id, kind="stable")
    cluster_sorted = cluster_id[sort_order]
    refs_i16 = quantize_i16(refs)
    vectors = refs_i16[sort_order]
    labels_sorted = labels[sort_order]
    orig_ids = sort_order.astype(np.int64)
    counts = np.bincount(cluster_sorted, minlength=CLUSTERS)
    offsets = np.zeros(CLUSTERS + 1, dtype=np.int64)
    np.cumsum(counts, out=offsets[1:])
    bbox_min = np.empty((CLUSTERS, DIM), dtype=np.int16)
    bbox_max = np.empty((CLUSTERS, DIM), dtype=np.int16)
    for c in range(CLUSTERS):
        s, e = offsets[c], offsets[c + 1]
        if e == s:
            bbox_min[c] = 0; bbox_max[c] = 0
        else:
            block = vectors[s:e]
            bbox_min[c] = block.min(axis=0)
            bbox_max[c] = block.max(axis=0)
    z = {
        "centroids": km.cluster_centers_.astype(np.float32),
        "bbox_min": bbox_min, "bbox_max": bbox_max,
        "offsets": offsets, "vectors": vectors,
        "labels": labels_sorted, "orig_ids": orig_ids,
    }
    np.savez(INDEX_CACHE, **z)
    return z


FLAG_SOA = 0x1
FLAG_BLOCKS = 0x4

BLOCK_SIZE = 8


def to_block_layout(vectors_aos: np.ndarray, offsets: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Per cluster: blocos de 8 vetores × Dim dims, com padding i16::MAX.

    Layout dentro do bloco (dim-major):
        dim0[8 lanes] dim1[8 lanes] ... dim13[8 lanes]  (14 × 8 = 112 i16/bloco)

    Retorna (block_offsets, vectors_blocks).
    """
    n_clusters = len(offsets) - 1
    block_offsets = np.zeros(n_clusters + 1, dtype=np.uint32)
    blocks_list = []
    pad_val = np.iinfo(np.int16).max  # 32767
    for c in range(n_clusters):
        s, e = int(offsets[c]), int(offsets[c + 1])
        n_valid = e - s
        n_blocks = (n_valid + BLOCK_SIZE - 1) // BLOCK_SIZE
        block_offsets[c + 1] = block_offsets[c] + n_blocks
        if n_valid == 0:
            continue
        padded_n = n_blocks * BLOCK_SIZE
        padded = np.full((padded_n, DIM), pad_val, dtype=np.int16)
        padded[:n_valid] = vectors_aos[s:e]
        # (n_blocks, BLOCK_SIZE, DIM) → (n_blocks, DIM, BLOCK_SIZE) → ravel
        blocks = padded.reshape(n_blocks, BLOCK_SIZE, DIM).transpose(0, 2, 1)
        blocks_list.append(blocks.ravel())
    vectors_blocks = (
        np.concatenate(blocks_list)
        if blocks_list
        else np.array([], dtype=np.int16)
    )
    return block_offsets, vectors_blocks


def transpose_clusters_soa(vectors_aos: np.ndarray, offsets: np.ndarray) -> np.ndarray:
    """Per cluster: (N, Dim) → (Dim, N), concatenado em ordem dim-major.

    Acesso: vectors[offsets[c]*Dim + d*N + i] = AoS[offsets[c]+i, d].
    """
    out = np.empty_like(vectors_aos.ravel())
    for c in range(len(offsets) - 1):
        s = int(offsets[c]); e = int(offsets[c + 1])
        n = e - s
        if n == 0:
            continue
        block = vectors_aos[s:e]
        soa = np.ascontiguousarray(block.T)
        base = s * DIM
        out[base:base + n * DIM] = soa.ravel()
    return out.astype(np.int16, copy=False)


def emit_binary(z: dict, out_path: Path, soa: bool = True, blocks: bool = False) -> None:
    centroids = np.ascontiguousarray(z["centroids"], dtype=np.float32)
    bbox_min = np.ascontiguousarray(z["bbox_min"], dtype=np.int16)
    bbox_max = np.ascontiguousarray(z["bbox_max"], dtype=np.int16)
    offsets = np.ascontiguousarray(z["offsets"], dtype=np.uint32)
    labels = np.ascontiguousarray(z["labels"], dtype=np.uint8)
    vectors_aos = np.ascontiguousarray(z["vectors"], dtype=np.int16).reshape(-1, DIM)
    n_clusters = len(centroids)
    n_vectors = len(vectors_aos)
    block_offsets: np.ndarray | None = None

    if blocks:
        print(f"[emit] {out_path}  n={n_vectors:,}  k={n_clusters}  layout=BLOCKS dim-major (BLOCK_SIZE=8)")
        t0 = perf_counter()
        block_offsets, vectors = to_block_layout(vectors_aos, offsets)
        block_offsets = block_offsets.astype(np.uint32, copy=False)
        total_blocks = int(block_offsets[-1])
        print(f"[emit] block layout em {perf_counter() - t0:.1f}s  total_blocks={total_blocks:,}")
        version = 3
        flags = FLAG_BLOCKS
    elif soa:
        print(f"[emit] {out_path}  n={n_vectors:,}  k={n_clusters}  layout=SoA per-cluster")
        print("[emit] transposing clusters to SoA…")
        t0 = perf_counter()
        vectors = transpose_clusters_soa(vectors_aos, offsets)
        print(f"[emit] transpose em {perf_counter() - t0:.1f}s")
        version = 2
        flags = FLAG_SOA
    else:
        print(f"[emit] {out_path}  n={n_vectors:,}  k={n_clusters}  layout=AoS")
        vectors = vectors_aos.ravel()
        version = 1
        flags = 0

    with out_path.open("wb") as fh:
        fh.write(MAGIC)
        fh.write(struct.pack("<I", version))
        fh.write(struct.pack("<I", n_vectors))
        fh.write(struct.pack("<I", n_clusters))
        fh.write(struct.pack("<I", DIM))
        fh.write(struct.pack("<f", QUANT_SCALE))
        fh.write(struct.pack("<Q", flags))
        fh.write(b"\x00" * (HEADER_SIZE - fh.tell()))

        # Ordem dos blocos no arquivo. v3 inclui block_offsets entre offsets e labels.
        if block_offsets is not None:
            seq = (centroids, bbox_min, bbox_max, offsets, block_offsets, labels, vectors)
        else:
            seq = (centroids, bbox_min, bbox_max, offsets, labels, vectors)
        for arr in seq:
            pos = fh.tell()
            rem = pos % ALIGN
            if rem:
                fh.write(b"\x00" * (ALIGN - rem))
            fh.write(arr.tobytes())
    sz = out_path.stat().st_size
    print(f"[emit] OK {sz:,} bytes ({sz / 2**20:.1f} MB)")


def main() -> None:
    args = sys.argv[1:]
    soa = True
    blocks = False
    if "--aos" in args:
        soa = False
        args = [a for a in args if a != "--aos"]
    if "--blocks" in args:
        blocks = True
        soa = False
        args = [a for a in args if a != "--blocks"]
    out_path = Path(args[0]) if args else (DATA_DIR / "index.bin")
    refs, labels = load_references()
    z = build_ivf(refs, labels)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    emit_binary(z, out_path, soa=soa, blocks=blocks)


if __name__ == "__main__":
    main()
