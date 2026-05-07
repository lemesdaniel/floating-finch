"""§6.4 — IVF simples por partição categórica.

Avalia 3 estratégias contra o ground truth (§6.1):

1. **single bucket**: busca apenas na partição da query.
2. **multi-probe-1**: partição da query + flip do bit menos confiante (4 vizinhos).
3. **multi-probe-all**: partição + flip de cada um dos 4 bits (5 buckets).

Para cada uma, mede recall (concordância de approved) e nº médio
de distâncias avaliadas. Latência aproximada usando numpy int8.

Reusa quantize.py para int8.
"""

from __future__ import annotations

import csv
from time import perf_counter

import numpy as np
from tqdm import tqdm

from dataset import DATA_DIR, load_references
from quantize import quantize, squared_distance_int8

K = 5
APPROVED_THRESHOLD = 0.6
GT_PATH = DATA_DIR / "ground_truth.csv"


def compute_buckets(refs: np.ndarray) -> np.ndarray:
    has_last_tx = (refs[:, 5] != -1.0).astype(np.uint8)
    unknown_mer = (refs[:, 11] == 1.0).astype(np.uint8)
    is_online = (refs[:, 9] == 1.0).astype(np.uint8)
    card_present = (refs[:, 10] == 1.0).astype(np.uint8)
    return (has_last_tx | (unknown_mer << 1) | (is_online << 2) | (card_present << 3)).astype(np.uint8)


def load_ground_truth() -> tuple[np.ndarray, np.ndarray]:
    qi, ap = [], []
    with GT_PATH.open() as fh:
        for row in csv.DictReader(fh):
            qi.append(int(row["query_idx"]))
            ap.append(int(row["approved"]))
    return np.array(qi, dtype=np.int64), np.array(ap, dtype=bool)


def search_in_buckets(
    query_i8: np.ndarray,
    refs_i8: np.ndarray,
    labels: np.ndarray,
    bucket_indices: list[np.ndarray],
    exclude_idx: int,
) -> tuple[bool, int]:
    """Concatena os índices dos buckets, faz brute force int8 nesse subset, retorna (approved, n_dist)."""
    candidates = np.concatenate(bucket_indices)
    candidates = candidates[candidates != exclude_idx]
    subset = refs_i8[candidates]
    dist2 = squared_distance_int8(subset, query_i8)
    if len(dist2) <= K:
        top5_local = np.arange(len(dist2))
    else:
        top5_local = np.argpartition(dist2, K)[:K]
    top5 = candidates[top5_local]
    fraud_score = float(labels[top5].mean())
    return fraud_score < APPROVED_THRESHOLD, len(candidates)


def main() -> None:
    refs, labels = load_references()
    refs_i8 = quantize(refs)
    buckets = compute_buckets(refs)

    bucket_idx_lists: list[np.ndarray] = [np.where(buckets == b)[0] for b in range(16)]
    bucket_sizes = np.array([len(b) for b in bucket_idx_lists])
    nonzero_buckets = np.where(bucket_sizes > 0)[0]
    print(f"buckets não vazios: {nonzero_buckets.tolist()}  ({len(nonzero_buckets)} de 16)")

    qi_arr, gt_approved = load_ground_truth()
    queries_i8 = quantize(refs[qi_arr])

    strategies = {
        "single": lambda b: [bucket_idx_lists[b]],
        "probe1_haslast": lambda b: [bucket_idx_lists[b], bucket_idx_lists[b ^ 0b0001]],
        "probe1_unkmer": lambda b: [bucket_idx_lists[b], bucket_idx_lists[b ^ 0b0010]],
        "probe1_online": lambda b: [bucket_idx_lists[b], bucket_idx_lists[b ^ 0b0100]],
        "probe1_cardp": lambda b: [bucket_idx_lists[b], bucket_idx_lists[b ^ 0b1000]],
        "probe_all4": lambda b: [bucket_idx_lists[b]]
        + [bucket_idx_lists[b ^ (1 << k)] for k in range(4)],
    }

    print()
    print(f"{'estratégia':>16}  {'recall':>8}  {'n_dist mean':>13}  {'n_dist p99':>11}  {'lat_ms p99':>11}")

    for name, sel in strategies.items():
        recalls = np.empty(len(qi_arr), dtype=bool)
        n_dists = np.empty(len(qi_arr), dtype=np.int64)
        times_ms = np.empty(len(qi_arr), dtype=np.float64)
        for i, qi in enumerate(qi_arr):
            b = int(buckets[qi])
            bs = [x for x in sel(b) if len(x) > 0]
            if not bs:
                recalls[i] = False
                n_dists[i] = 0
                times_ms[i] = 0.0
                continue
            t0 = perf_counter()
            approved, nd = search_in_buckets(queries_i8[i], refs_i8, labels, bs, int(qi))
            times_ms[i] = (perf_counter() - t0) * 1000
            n_dists[i] = nd
            recalls[i] = approved == gt_approved[i]

        print(
            f"{name:>16}  {recalls.mean() * 100:>7.2f}%  "
            f"{n_dists.mean():>13,.0f}  {np.percentile(n_dists, 99):>11,.0f}  "
            f"{np.percentile(times_ms, 99):>10.2f}"
        )


if __name__ == "__main__":
    main()
