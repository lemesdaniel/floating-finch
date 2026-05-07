"""§6.7 — Protótipo IVF k-means inspirado no top-3 (vinicius cpp-ivf).

Objetivos:
1. Treinar k-means com 2048 centroides (sample 64k, 6 iterações).
2. Quantizar refs em int16 com kQuantScale=10000.
3. Para cada query: achar centroide mais próximo (nprobe=1), buscar top-5 no cluster.
4. Implementar bbox_repair: se top-5 tem 2-3 fraudes (ambíguo), checar bbox
   dos clusters vizinhos e recalcular se algum estiver mais perto.
5. Medir recall vs ground truth, n_dist médio, distribuição de cluster sizes.

Cache do índice em data/ivf_kmeans.npz para iterações rápidas.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
from time import perf_counter

import numpy as np
from sklearn.cluster import MiniBatchKMeans
from tqdm import tqdm

from dataset import DATA_DIR, load_references

K = 5
APPROVED_THRESHOLD = 0.6
CLUSTERS = 2048
TRAIN_SAMPLE = 65_536
ITERATIONS = 6
QUANT_SCALE = 10_000.0
SEED = 42

GT_PATH = DATA_DIR / "ground_truth.csv"
INDEX_CACHE = DATA_DIR / "ivf_kmeans.npz"


@dataclass
class IvfIndex:
    centroids: np.ndarray   # (clusters, 14) float32
    bbox_min: np.ndarray    # (clusters, 14) int16
    bbox_max: np.ndarray    # (clusters, 14) int16
    offsets: np.ndarray     # (clusters+1,) int64 — onde cada cluster começa em vectors
    vectors: np.ndarray     # (n_padded, 14) int16 — ordenados por cluster
    labels: np.ndarray      # (n_padded,) uint8
    orig_ids: np.ndarray    # (n_padded,) int64 — id original

    @property
    def n_clusters(self) -> int:
        return len(self.centroids)


def quantize_i16(vectors: np.ndarray) -> np.ndarray:
    """Float [0,1] (com -1 sentinel) → int16. -1 vira -10000 (longe natural)."""
    out = np.rint(vectors * QUANT_SCALE).astype(np.int16)
    return out


def squared_distance_i16(refs_i16: np.ndarray, q_i16: np.ndarray) -> np.ndarray:
    diff = refs_i16.astype(np.int32) - q_i16.astype(np.int32)
    return np.einsum("ij,ij->i", diff, diff, dtype=np.int64)


def bbox_min_distance(bbox_min: np.ndarray, bbox_max: np.ndarray, q: np.ndarray) -> np.ndarray:
    """Distância mínima do query até a bounding box (int16). 0 se está dentro."""
    q32 = q.astype(np.int32)
    below = np.maximum(bbox_min.astype(np.int32) - q32, 0)
    above = np.maximum(q32 - bbox_max.astype(np.int32), 0)
    delta = below + above
    return np.einsum("ij,ij->i", delta, delta, dtype=np.int64)


def build_index(refs: np.ndarray, labels: np.ndarray) -> IvfIndex:
    if INDEX_CACHE.exists():
        t0 = perf_counter()
        z = np.load(INDEX_CACHE)
        idx = IvfIndex(
            centroids=z["centroids"], bbox_min=z["bbox_min"], bbox_max=z["bbox_max"],
            offsets=z["offsets"], vectors=z["vectors"], labels=z["labels"], orig_ids=z["orig_ids"],
        )
        print(f"loaded ivf index from cache in {perf_counter() - t0:.2f}s")
        return idx

    print(f"treinando MiniBatchKMeans (n={len(refs):,}, k={CLUSTERS}, sample={TRAIN_SAMPLE}, iters={ITERATIONS})")
    rng = np.random.default_rng(SEED)
    train_idx = rng.choice(len(refs), size=TRAIN_SAMPLE, replace=False)
    train = refs[train_idx]

    t0 = perf_counter()
    km = MiniBatchKMeans(
        n_clusters=CLUSTERS, init="k-means++", n_init=1, max_iter=ITERATIONS,
        batch_size=4096, random_state=SEED,
    )
    km.fit(train)
    print(f"k-means fit em {perf_counter() - t0:.1f}s; assigning all 3M…")

    t0 = perf_counter()
    cluster_id = km.predict(refs).astype(np.int32)
    print(f"assignments em {perf_counter() - t0:.1f}s")

    sort_order = np.argsort(cluster_id, kind="stable")
    cluster_sorted = cluster_id[sort_order]
    refs_i16 = quantize_i16(refs)
    vectors_sorted = refs_i16[sort_order]
    labels_sorted = labels[sort_order]
    orig_ids = sort_order.astype(np.int64)

    counts = np.bincount(cluster_sorted, minlength=CLUSTERS)
    offsets = np.zeros(CLUSTERS + 1, dtype=np.int64)
    np.cumsum(counts, out=offsets[1:])

    bbox_min = np.empty((CLUSTERS, 14), dtype=np.int16)
    bbox_max = np.empty((CLUSTERS, 14), dtype=np.int16)
    for c in range(CLUSTERS):
        s, e = offsets[c], offsets[c + 1]
        if e == s:
            bbox_min[c] = 0
            bbox_max[c] = 0
        else:
            block = vectors_sorted[s:e]
            bbox_min[c] = block.min(axis=0)
            bbox_max[c] = block.max(axis=0)

    idx = IvfIndex(
        centroids=km.cluster_centers_.astype(np.float32),
        bbox_min=bbox_min, bbox_max=bbox_max,
        offsets=offsets, vectors=vectors_sorted, labels=labels_sorted, orig_ids=orig_ids,
    )

    np.savez(
        INDEX_CACHE,
        centroids=idx.centroids, bbox_min=idx.bbox_min, bbox_max=idx.bbox_max,
        offsets=idx.offsets, vectors=idx.vectors, labels=idx.labels, orig_ids=idx.orig_ids,
    )
    sizes = np.diff(offsets)
    print(f"clusters: min={sizes.min()}  median={int(np.median(sizes))}  max={sizes.max()}  mean={sizes.mean():.0f}")
    print(f"footprint estimado: vectors={idx.vectors.nbytes / 2**20:.1f} MB  bbox+centroids+offsets={(idx.bbox_min.nbytes + idx.bbox_max.nbytes + idx.centroids.nbytes + idx.offsets.nbytes) / 1024:.1f} KB")
    return idx


def search(
    idx: IvfIndex, query_f32: np.ndarray, query_i16: np.ndarray,
    nprobe: int = 1, bbox_repair: bool = True,
    repair_min_frauds: int = 2, repair_max_frauds: int = 3,
    exclude_orig_id: int = -1,
) -> tuple[bool, int, int]:
    """Retorna (approved, n_distances_computed, n_clusters_probed)."""
    cdist = np.einsum("ij,ij->i", idx.centroids - query_f32, idx.centroids - query_f32, dtype=np.float64)
    primary_clusters = np.argpartition(cdist, nprobe)[:nprobe]
    primary_clusters = primary_clusters[np.argsort(cdist[primary_clusters])]

    candidates = []
    for c in primary_clusters:
        s, e = int(idx.offsets[c]), int(idx.offsets[c + 1])
        candidates.append(np.arange(s, e))
    cand = np.concatenate(candidates) if candidates else np.empty(0, dtype=np.int64)

    if exclude_orig_id >= 0:
        cand = cand[idx.orig_ids[cand] != exclude_orig_id]

    n_dist = len(cand)
    n_probed = nprobe

    if n_dist == 0:
        return True, 0, n_probed

    dists = squared_distance_i16(idx.vectors[cand], query_i16)
    if len(dists) <= K:
        top5 = cand
    else:
        top5_local = np.argpartition(dists, K)[:K]
        top5 = cand[top5_local]
    top5_dists = squared_distance_i16(idx.vectors[top5], query_i16)
    sort_order = np.argsort(top5_dists, kind="stable")
    top5 = top5[sort_order]
    top5_dists = top5_dists[sort_order]
    fraud_count = int(idx.labels[top5].sum())

    if bbox_repair and repair_min_frauds <= fraud_count <= repair_max_frauds:
        threshold = top5_dists[-1]
        bbox_dists = bbox_min_distance(idx.bbox_min, idx.bbox_max, query_i16)
        bbox_dists[primary_clusters] = np.iinfo(np.int64).max
        candidate_clusters = np.where(bbox_dists < threshold)[0]
        if len(candidate_clusters) > 0:
            cand_extra = []
            for c in candidate_clusters:
                s, e = int(idx.offsets[c]), int(idx.offsets[c + 1])
                cand_extra.append(np.arange(s, e))
            extra = np.concatenate(cand_extra) if cand_extra else np.empty(0, dtype=np.int64)
            if exclude_orig_id >= 0:
                extra = extra[idx.orig_ids[extra] != exclude_orig_id]
            if len(extra):
                extra_dists = squared_distance_i16(idx.vectors[extra], query_i16)
                better = extra_dists < threshold
                if better.any():
                    combined_idx = np.concatenate([top5, extra[better]])
                    combined_dists = np.concatenate([top5_dists, extra_dists[better]])
                    new_top5_local = np.argpartition(combined_dists, K)[:K]
                    top5 = combined_idx[new_top5_local]
                    fraud_count = int(idx.labels[top5].sum())
                n_dist += len(extra)
                n_probed += len(candidate_clusters)

    fraud_score = fraud_count / 5.0
    approved = fraud_score < APPROVED_THRESHOLD
    return approved, n_dist, n_probed


def load_ground_truth() -> tuple[np.ndarray, np.ndarray]:
    qi, ap = [], []
    with GT_PATH.open() as fh:
        for row in csv.DictReader(fh):
            qi.append(int(row["query_idx"]))
            ap.append(int(row["approved"]))
    return np.array(qi, dtype=np.int64), np.array(ap, dtype=bool)


def main() -> None:
    refs, labels = load_references()
    idx = build_index(refs, labels)

    qi_arr, gt_approved = load_ground_truth()
    queries_f32 = refs[qi_arr]
    queries_i16 = quantize_i16(queries_f32)

    configs = [
        ("nprobe=1, no_repair",       1, False, 2, 3),
        ("nprobe=1, repair[2-3]",     1, True,  2, 3),
        ("nprobe=1, repair[1-4]",     1, True,  1, 4),
        ("nprobe=2, no_repair",       2, False, 2, 3),
        ("nprobe=2, repair[2-3]",     2, True,  2, 3),
        ("nprobe=4, no_repair",       4, False, 2, 3),
    ]

    print()
    print(f"{'config':<26}  {'recall':>8}  {'n_dist mean':>13}  {'n_dist p99':>11}  {'n_probed mean':>13}  {'lat ms p99':>11}")
    for name, nprobe, repair, mn, mx in configs:
        results = []
        n_dists = []
        n_probed = []
        times_ms = []
        for i, qi in enumerate(qi_arr):
            t0 = perf_counter()
            ap, nd, npr = search(
                idx, queries_f32[i], queries_i16[i],
                nprobe=nprobe, bbox_repair=repair,
                repair_min_frauds=mn, repair_max_frauds=mx,
                exclude_orig_id=int(qi),
            )
            times_ms.append((perf_counter() - t0) * 1000)
            results.append(ap == gt_approved[i])
            n_dists.append(nd)
            n_probed.append(npr)
        recall = np.mean(results)
        print(
            f"{name:<26}  {recall * 100:>7.2f}%  "
            f"{np.mean(n_dists):>13,.0f}  {np.percentile(n_dists, 99):>11,.0f}  "
            f"{np.mean(n_probed):>13.1f}  {np.percentile(times_ms, 99):>10.2f}"
        )


if __name__ == "__main__":
    main()
