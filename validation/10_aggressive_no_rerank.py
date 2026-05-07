"""§6.10 — Sondar mais agressivo SEM rerank, ver se chega a 99.99%.

Se sim, evita o custo de adicionar f16 ao index (84 MB extras).
Avalia trade-off recall × n_dist (proxy para latência) sobre GT 10k.

Reusa o cache npz original (scale=10000, k-means único).
"""

from __future__ import annotations

import csv
from time import perf_counter

import numpy as np

from dataset import DATA_DIR, load_references

K = 5
APPROVED_THRESHOLD = 0.6
GT_PATH = DATA_DIR / "ground_truth_10000.csv"
INDEX_CACHE = DATA_DIR / "ivf_kmeans.npz"


def squared_distance_i16(refs: np.ndarray, q: np.ndarray) -> np.ndarray:
    diff = refs.astype(np.int32) - q.astype(np.int32)
    return np.einsum("ij,ij->i", diff, diff, dtype=np.int64)


def bbox_min_distance(bbox_min: np.ndarray, bbox_max: np.ndarray, q: np.ndarray) -> np.ndarray:
    q32 = q.astype(np.int32)
    below = np.maximum(bbox_min.astype(np.int32) - q32, 0)
    above = np.maximum(q32 - bbox_max.astype(np.int32), 0)
    delta = below + above
    return np.einsum("ij,ij->i", delta, delta, dtype=np.int64)


def quantize_i16(v: np.ndarray, scale: float = 10_000.0) -> np.ndarray:
    return np.where(
        v == -1.0, int(-scale),
        np.rint(np.clip(v, 0.0, 1.0) * scale).astype(np.int32),
    ).astype(np.int16)


def search(idx, q_f32, q_i16, exclude_orig_id, nprobe, repair_min, repair_max) -> tuple[bool, int]:
    centroids = idx["centroids"]
    cdist = np.einsum("ij,ij->i", centroids - q_f32, centroids - q_f32, dtype=np.float64)
    primary = np.argpartition(cdist, nprobe)[:nprobe]
    primary = primary[np.argsort(cdist[primary])]
    cand = np.concatenate(
        [np.arange(int(idx["offsets"][c]), int(idx["offsets"][c + 1])) for c in primary]
    )
    cand = cand[idx["orig_ids"][cand] != exclude_orig_id]
    n_dist = len(cand)
    if n_dist == 0:
        return True, 0
    dists = squared_distance_i16(idx["vectors"][cand], q_i16)
    if len(dists) <= K:
        top5 = cand
    else:
        top5_local = np.argpartition(dists, K)[:K]
        top5 = cand[top5_local]
    fraud_count = int(idx["labels"][top5].sum())

    if repair_min <= fraud_count <= repair_max:
        topk_dists = squared_distance_i16(idx["vectors"][top5], q_i16)
        threshold = int(np.sort(topk_dists)[-1])
        bb = bbox_min_distance(idx["bbox_min"], idx["bbox_max"], q_i16)
        bb[primary] = np.iinfo(np.int64).max
        extras = np.where(bb < threshold)[0]
        if len(extras) > 0:
            extra = np.concatenate(
                [np.arange(int(idx["offsets"][c]), int(idx["offsets"][c + 1])) for c in extras]
            )
            extra = extra[idx["orig_ids"][extra] != exclude_orig_id]
            if len(extra):
                extra_d = squared_distance_i16(idx["vectors"][extra], q_i16)
                close = extra_d < threshold
                if close.any():
                    comb = np.concatenate([top5, extra[close]])
                    comb_d = np.concatenate([topk_dists, extra_d[close]])
                    top5_new = np.argpartition(comb_d, K)[:K]
                    top5 = comb[top5_new]
                    fraud_count = int(idx["labels"][top5].sum())
                n_dist += len(extra)
    return (fraud_count / 5.0) < APPROVED_THRESHOLD, n_dist


def load_gt() -> tuple[np.ndarray, np.ndarray]:
    qi, ap = [], []
    with GT_PATH.open() as fh:
        for row in csv.DictReader(fh):
            qi.append(int(row["query_idx"]))
            ap.append(int(row["approved"]))
    return np.array(qi, dtype=np.int64), np.array(ap, dtype=bool)


def main() -> None:
    refs, _ = load_references()
    qi, gt_ap = load_gt()
    queries_f32 = refs[qi]
    queries_i16 = quantize_i16(queries_f32)
    idx = dict(np.load(INDEX_CACHE))

    configs = [
        # nprobe, repair_min, repair_max
        (1, 2, 3),
        (1, 1, 4),
        (2, 2, 3),
        (2, 1, 4),
        (2, 0, 5),
        (4, 2, 3),
        (4, 1, 4),
        (4, 0, 5),
        (8, 1, 4),
        (8, 0, 5),
    ]

    print()
    print(f"=== §6.10 — sondar agressivo sem rerank (GT 10k) ===")
    print(f"{'nprobe':>7}  {'repair':>10}  {'recall':>8}  {'erros':>6}  {'n_dist mean':>13}  {'n_dist p99':>11}  {'lat ms p99':>11}")
    for nprobe, rmin, rmax in configs:
        results, n_dists, times_ms = [], [], []
        for i in range(len(qi)):
            t0 = perf_counter()
            ap, nd = search(idx, queries_f32[i], queries_i16[i], int(qi[i]),
                            nprobe=nprobe, repair_min=rmin, repair_max=rmax)
            times_ms.append((perf_counter() - t0) * 1000)
            n_dists.append(nd)
            results.append(ap == gt_ap[i])
        recall = float(np.mean(results))
        wrong = int(len(results) - np.sum(results))
        print(
            f"{nprobe:>7}  [{rmin}-{rmax}]      {recall * 100:>7.2f}%  {wrong:>6}  "
            f"{np.mean(n_dists):>13,.0f}  {np.percentile(n_dists, 99):>11,.0f}  "
            f"{np.percentile(times_ms, 99):>10.2f}"
        )


if __name__ == "__main__":
    main()
