"""§6.9 v2 — Hipótese: aumentar escala do int16 (10k → 30k) sobe recall?

Fix vs v1: (1) usa o MESMO k-means (cache npz original) para todas as escalas;
re-quantiza apenas os vetores. (2) Exclui o próprio query_idx do dataset
(consistente com como o ground truth foi gerado).
"""

from __future__ import annotations

import csv
from time import perf_counter

import numpy as np

from dataset import DATA_DIR, load_references

K = 5
APPROVED_THRESHOLD = 0.6
GT_PATH = DATA_DIR / "ground_truth_10000.csv"
INDEX_CACHE = DATA_DIR / "ivf_kmeans.npz"  # built with scale=10000


def quantize_with_scale(v: np.ndarray, scale: float) -> np.ndarray:
    sentinel_v = -1.0
    return np.where(
        v == sentinel_v,
        int(-scale),
        np.rint(np.clip(v, 0.0, 1.0) * scale).astype(np.int32),
    ).astype(np.int16)


def squared_distance_i16(refs: np.ndarray, q: np.ndarray) -> np.ndarray:
    diff = refs.astype(np.int32) - q.astype(np.int32)
    return np.einsum("ij,ij->i", diff, diff, dtype=np.int64)


def bbox_min_distance(bbox_min: np.ndarray, bbox_max: np.ndarray, q: np.ndarray) -> np.ndarray:
    q32 = q.astype(np.int32)
    below = np.maximum(bbox_min.astype(np.int32) - q32, 0)
    above = np.maximum(q32 - bbox_max.astype(np.int32), 0)
    delta = below + above
    return np.einsum("ij,ij->i", delta, delta, dtype=np.int64)


def search(idx, q_f32, q_i16, exclude_orig_id, nprobe=2, repair=True, repair_min=2, repair_max=3) -> bool:
    centroids = idx["centroids"]
    cdist = np.einsum("ij,ij->i", centroids - q_f32, centroids - q_f32, dtype=np.float64)
    primary = np.argpartition(cdist, nprobe)[:nprobe]
    primary = primary[np.argsort(cdist[primary])]
    cand_lists = [np.arange(int(idx["offsets"][c]), int(idx["offsets"][c + 1])) for c in primary]
    cand = np.concatenate(cand_lists) if cand_lists else np.empty(0, dtype=np.int64)
    cand = cand[idx["orig_ids"][cand] != exclude_orig_id]
    if len(cand) == 0:
        return True
    dists = squared_distance_i16(idx["vectors"][cand], q_i16)
    if len(dists) <= K:
        top5 = cand
    else:
        top5_local = np.argpartition(dists, K)[:K]
        top5 = cand[top5_local]
    fraud_count = int(idx["labels"][top5].sum())

    if repair and repair_min <= fraud_count <= repair_max:
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
    return (fraud_count / 5.0) < APPROVED_THRESHOLD


def load_gt() -> tuple[np.ndarray, np.ndarray]:
    qi, ap = [], []
    with GT_PATH.open() as fh:
        for row in csv.DictReader(fh):
            qi.append(int(row["query_idx"]))
            ap.append(int(row["approved"]))
    return np.array(qi, dtype=np.int64), np.array(ap, dtype=bool)


def main() -> None:
    refs, _labels = load_references()
    qi, gt_ap = load_gt()
    queries_f32 = refs[qi]

    base = dict(np.load(INDEX_CACHE))
    centroids = base["centroids"]
    offsets = base["offsets"]
    labels = base["labels"]
    orig_ids = base["orig_ids"]

    refs_sorted = refs[orig_ids]

    print()
    print(f"=== §6.9 v2 — escala vs recall (config nprobe=2, bbox_repair[2-3]) ===")
    print(f"k-means único (treinado com scale=10000); vetores re-quantizados para cada escala")
    print(f"queries: {len(qi)}")
    print()
    print(f"{'scale':>8}  {'recall':>8}  {'erros':>6}")

    for scale in [10_000, 16_000, 20_000, 25_000, 30_000, 32_000]:
        vectors_i16 = quantize_with_scale(refs_sorted, scale)
        bbox_min = np.empty((len(centroids), 14), dtype=np.int16)
        bbox_max = np.empty((len(centroids), 14), dtype=np.int16)
        for c in range(len(centroids)):
            s, e = int(offsets[c]), int(offsets[c + 1])
            if e == s:
                bbox_min[c] = 0; bbox_max[c] = 0
            else:
                block = vectors_i16[s:e]
                bbox_min[c] = block.min(axis=0)
                bbox_max[c] = block.max(axis=0)

        idx = {
            "centroids": centroids, "offsets": offsets, "labels": labels,
            "orig_ids": orig_ids, "vectors": vectors_i16,
            "bbox_min": bbox_min, "bbox_max": bbox_max,
        }
        q_i16 = quantize_with_scale(queries_f32, scale)
        results = []
        for i in range(len(qi)):
            ap = search(idx, queries_f32[i], q_i16[i], int(qi[i]),
                        nprobe=2, repair=True, repair_min=2, repair_max=3)
            results.append(ap == gt_ap[i])
        recall = float(np.mean(results))
        wrong = int(len(results) - np.sum(results))
        print(f"{scale:>8,}  {recall * 100:>7.2f}%  {wrong:>6}")


if __name__ == "__main__":
    main()
