"""§6.8 — IVF k-means + rerank fp32.

Estratégia:
1. IVF k-means (cache de §6.7) com nprobe=1 + bbox_repair[2-3].
2. Para os candidatos (cluster + repair), busca top-K *aproximado* em int16.
3. **Rerank**: pega top-K candidatos (K=20, mais que K=5), recalcula distância
   euclidiana em **float32 exato** usando refs originais, escolhe top-5 final.

Hipótese: o erro residual de 0.1% (que sobra após repair) vem da quantização
int16 — empates de distância próximos onde 1 ULP de int16 muda a ordem do top-5.
Rerank em fp32 puro deveria eliminar essa fonte de erro.

Compara recall vs ground truth (brute-force fp32 exato).
"""

from __future__ import annotations

import csv
from time import perf_counter

import numpy as np
from sklearn.cluster import MiniBatchKMeans  # noqa: F401  — só pra reusar se índice não cacheado

from dataset import DATA_DIR, load_references

import sys

K = 5
APPROVED_THRESHOLD = 0.6
QUANT_SCALE = 10_000.0
GT_FILE = sys.argv[1] if len(sys.argv) > 1 else "ground_truth.csv"
GT_PATH = DATA_DIR / GT_FILE
INDEX_CACHE = DATA_DIR / "ivf_kmeans.npz"


def load_index() -> dict:
    z = dict(np.load(INDEX_CACHE))
    print(f"loaded ivf index from cache")
    return z


def squared_distance_i16(refs_i16: np.ndarray, q_i16: np.ndarray) -> np.ndarray:
    diff = refs_i16.astype(np.int32) - q_i16.astype(np.int32)
    return np.einsum("ij,ij->i", diff, diff, dtype=np.int64)


def squared_distance_f32(refs_f32: np.ndarray, q_f32: np.ndarray) -> np.ndarray:
    diff = refs_f32 - q_f32
    return np.einsum("ij,ij->i", diff, diff, dtype=np.float64)


def bbox_min_distance(bbox_min: np.ndarray, bbox_max: np.ndarray, q: np.ndarray) -> np.ndarray:
    q32 = q.astype(np.int32)
    below = np.maximum(bbox_min.astype(np.int32) - q32, 0)
    above = np.maximum(q32 - bbox_max.astype(np.int32), 0)
    delta = below + above
    return np.einsum("ij,ij->i", delta, delta, dtype=np.int64)


def search_with_rerank(
    idx: dict,
    refs_f32_orig: np.ndarray,
    query_f32: np.ndarray,
    query_i16: np.ndarray,
    rerank_k: int,
    nprobe: int = 1,
    bbox_repair: bool = True,
    repair_min: int = 2,
    repair_max: int = 3,
    exclude_orig_id: int = -1,
) -> tuple[bool, int]:
    centroids = idx["centroids"]
    offsets = idx["offsets"]
    vectors_i16 = idx["vectors"]
    labels = idx["labels"]
    orig_ids = idx["orig_ids"]
    bbox_min = idx["bbox_min"]
    bbox_max = idx["bbox_max"]

    cdist = np.einsum("ij,ij->i", centroids - query_f32, centroids - query_f32, dtype=np.float64)
    primary = np.argpartition(cdist, nprobe)[:nprobe]
    primary = primary[np.argsort(cdist[primary])]

    candidates = [np.arange(int(offsets[c]), int(offsets[c + 1])) for c in primary]
    cand = np.concatenate(candidates) if candidates else np.empty(0, dtype=np.int64)
    if exclude_orig_id >= 0:
        cand = cand[orig_ids[cand] != exclude_orig_id]

    if len(cand) == 0:
        return True, 0

    dists_i16 = squared_distance_i16(vectors_i16[cand], query_i16)

    take = min(rerank_k, len(cand))
    topk_local = np.argpartition(dists_i16, take - 1)[:take]
    topk = cand[topk_local]
    n_dist = len(cand)

    if bbox_repair:
        topk_dists_i16 = dists_i16[topk_local]
        topk_dists_i16_sorted = np.sort(topk_dists_i16)
        threshold_i16 = int(topk_dists_i16_sorted[K - 1]) if take >= K else int(topk_dists_i16_sorted[-1])

        topk_for_count = topk_local[np.argsort(dists_i16[topk_local])[:K]]
        topk_for_count_global = cand[topk_for_count]
        fraud_count_initial = int(labels[topk_for_count_global].sum())

        if repair_min <= fraud_count_initial <= repair_max:
            bbox_dists = bbox_min_distance(bbox_min, bbox_max, query_i16)
            bbox_dists[primary] = np.iinfo(np.int64).max
            extra_clusters = np.where(bbox_dists < threshold_i16)[0]
            if len(extra_clusters) > 0:
                extras = [np.arange(int(offsets[c]), int(offsets[c + 1])) for c in extra_clusters]
                extra = np.concatenate(extras) if extras else np.empty(0, dtype=np.int64)
                if exclude_orig_id >= 0:
                    extra = extra[orig_ids[extra] != exclude_orig_id]
                if len(extra):
                    extra_dists = squared_distance_i16(vectors_i16[extra], query_i16)
                    closer = extra_dists < threshold_i16
                    if closer.any():
                        topk = np.concatenate([topk, extra[closer]])
                        n_dist += len(extra)
                    else:
                        n_dist += len(extra)

    rerank_refs = refs_f32_orig[orig_ids[topk]]
    rerank_dists = squared_distance_f32(rerank_refs, query_f32)
    if len(rerank_dists) <= K:
        final_top5 = topk
    else:
        final_top5_local = np.argpartition(rerank_dists, K)[:K]
        final_top5 = topk[final_top5_local]
    fraud_count = int(labels[final_top5].sum())

    fraud_score = fraud_count / 5.0
    return fraud_score < APPROVED_THRESHOLD, n_dist


def load_ground_truth() -> tuple[np.ndarray, np.ndarray]:
    qi, ap = [], []
    with GT_PATH.open() as fh:
        for row in csv.DictReader(fh):
            qi.append(int(row["query_idx"]))
            ap.append(int(row["approved"]))
    return np.array(qi, dtype=np.int64), np.array(ap, dtype=bool)


def quantize_i16(v: np.ndarray) -> np.ndarray:
    return np.rint(v * QUANT_SCALE).astype(np.int16)


def main() -> None:
    refs, _ = load_references()
    idx = load_index()

    qi_arr, gt_approved = load_ground_truth()
    queries_f32 = refs[qi_arr]
    queries_i16 = quantize_i16(queries_f32)

    configs = [
        # rerank_k, nprobe, repair, repair_min, repair_max
        ("rerank_k=10, nprobe=1, no_repair",    10, 1, False, 2, 3),
        ("rerank_k=20, nprobe=1, no_repair",    20, 1, False, 2, 3),
        ("rerank_k=20, nprobe=1, repair[2-3]",  20, 1, True,  2, 3),
        ("rerank_k=20, nprobe=2, repair[2-3]",  20, 2, True,  2, 3),
        ("rerank_k=50, nprobe=1, repair[2-3]",  50, 1, True,  2, 3),
        ("rerank_k=20, nprobe=1, repair[1-4]",  20, 1, True,  1, 4),
        ("rerank_k=100, nprobe=1, repair[2-3]", 100, 1, True, 2, 3),
        ("rerank_k=100, nprobe=2, repair[1-4]", 100, 2, True, 1, 4),
    ]

    print()
    print(f"{'config':<40}  {'recall':>8}  {'n_dist mean':>13}  {'lat ms p99':>11}")
    for name, rk, npr, rep, mn, mx in configs:
        results = []
        n_dists = []
        times_ms = []
        for i, qi in enumerate(qi_arr):
            t0 = perf_counter()
            ap, nd = search_with_rerank(
                idx, refs,
                queries_f32[i], queries_i16[i],
                rerank_k=rk, nprobe=npr, bbox_repair=rep,
                repair_min=mn, repair_max=mx,
                exclude_orig_id=int(qi),
            )
            times_ms.append((perf_counter() - t0) * 1000)
            results.append(ap == gt_approved[i])
            n_dists.append(nd)
        recall = np.mean(results)
        print(
            f"{name:<40}  {recall * 100:>7.2f}%  "
            f"{np.mean(n_dists):>13,.0f}  {np.percentile(times_ms, 99):>10.2f}"
        )


if __name__ == "__main__":
    main()
