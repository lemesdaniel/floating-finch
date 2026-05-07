"""§6.2 — Brute-force com vetores quantizados em int8.

Carrega o ground truth, quantiza refs e queries, roda brute-force KNN K=5
no espaço int8 e compara `approved` com o ground truth para medir recall.

Recall esperado: alto (~99%+) já que a quantização é fina (127 níveis em [0,1])
e o sentinel -1 fica isolado em -127.

Cronometra a busca em si (sem parse JSON, sem normalização) para ter um
piso de latência atingível em Python+numpy single-thread.
"""

from __future__ import annotations

import csv
from pathlib import Path
from time import perf_counter

import numpy as np
from tqdm import tqdm

from dataset import DATA_DIR, load_references
from quantize import quantize, squared_distance_int8

K = 5
APPROVED_THRESHOLD = 0.6
GT_PATH = DATA_DIR / "ground_truth.csv"


def load_ground_truth() -> tuple[np.ndarray, np.ndarray]:
    query_idx = []
    gt_approved = []
    with GT_PATH.open() as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            query_idx.append(int(row["query_idx"]))
            gt_approved.append(int(row["approved"]))
    return np.array(query_idx, dtype=np.int64), np.array(gt_approved, dtype=bool)


def main() -> None:
    refs, labels = load_references()
    query_idx, gt_approved = load_ground_truth()
    print(f"loaded ground truth: {len(query_idx):,} queries")

    t0 = perf_counter()
    refs_i8 = quantize(refs)
    print(f"quantized refs to int8 in {perf_counter() - t0:.2f}s   (RSS: {refs_i8.nbytes / 2**20:.1f} MB)")

    queries_i8 = quantize(refs[query_idx])

    times_ms: list[float] = []
    pred_approved = np.empty(len(query_idx), dtype=bool)

    for i, qi in enumerate(tqdm(query_idx, desc="brute-force int8 KNN", unit="query")):
        q = queries_i8[i]
        t0 = perf_counter()
        dist2 = squared_distance_int8(refs_i8, q)
        dist2[qi] = np.iinfo(np.int32).max
        top5_unsorted = np.argpartition(dist2, K)[:K]
        top5 = top5_unsorted[np.argsort(dist2[top5_unsorted])]
        fraud_score = float(labels[top5].mean())
        approved = fraud_score < APPROVED_THRESHOLD
        elapsed_ms = (perf_counter() - t0) * 1000
        times_ms.append(elapsed_ms)
        pred_approved[i] = approved

    arr = np.array(times_ms)
    matches = pred_approved == gt_approved
    recall = matches.mean()
    disagreements = np.where(~matches)[0]

    print()
    print(f"=== resultados §6.2 — brute-force int8 ===")
    print(f"queries: {len(query_idx):,}")
    print(f"concordância com ground truth (approved): {recall * 100:.2f}%  ({matches.sum()}/{len(matches)})")
    print(f"discordâncias: {len(disagreements)}")
    if len(disagreements) > 0 and len(disagreements) <= 20:
        print(f"  índices das primeiras 20: {disagreements[:20].tolist()}")
    print()
    print(f"latência por query (numpy int8/int16, 1 thread):")
    print(f"  mean: {arr.mean():.2f} ms")
    print(f"  p50 : {np.percentile(arr, 50):.2f} ms")
    print(f"  p99 : {np.percentile(arr, 99):.2f} ms")
    print(f"  max : {arr.max():.2f} ms")


if __name__ == "__main__":
    main()
