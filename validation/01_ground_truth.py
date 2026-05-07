"""§6.1 — Brute-force exato como ground truth.

Sorteia 1.000 índices do dataset, trata cada um como query (excluindo
o próprio índice), calcula KNN com K=5 por distância euclidiana, deriva
fraud_score e approved. Salva CSV em data/ground_truth.csv.

A premissa é: queries reais (em produção) virão do payload, mas para
calibrar abordagens (IVF, HNSW, quantização) precisamos de um conjunto
fixo de queries com a resposta CORRETA conhecida.

Convenção de labels:
- positive = fraude (1)
- approved = fraud_score < 0.6
"""

from __future__ import annotations

import csv
from pathlib import Path
from time import perf_counter

import numpy as np
from tqdm import tqdm

from dataset import DATA_DIR, load_references

import sys

K = 5
N_QUERIES = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000
APPROVED_THRESHOLD = 0.6
SEED = 42
OUT_PATH = DATA_DIR / (f"ground_truth_{N_QUERIES}.csv" if N_QUERIES != 1000 else "ground_truth.csv")


def main() -> None:
    refs, labels = load_references()
    n = len(refs)

    rng = np.random.default_rng(SEED)
    query_idx = rng.choice(n, size=N_QUERIES, replace=False)

    rows: list[tuple] = []
    times_ms: list[float] = []

    for qi in tqdm(query_idx, desc="brute-force KNN", unit="query"):
        q = refs[qi]
        t0 = perf_counter()
        diff = refs - q
        dist2 = np.einsum("ij,ij->i", diff, diff)
        dist2[qi] = np.inf
        top5_unsorted = np.argpartition(dist2, K)[:K]
        order = np.argsort(dist2[top5_unsorted])
        top5 = top5_unsorted[order]
        top5_labels = labels[top5]
        fraud_score = float(top5_labels.mean())
        approved = fraud_score < APPROVED_THRESHOLD
        elapsed_ms = (perf_counter() - t0) * 1000
        times_ms.append(elapsed_ms)
        rows.append(
            (
                int(qi),
                int(labels[qi]),
                ";".join(str(int(t)) for t in top5),
                ";".join(str(int(l)) for l in top5_labels),
                f"{fraud_score:.4f}",
                int(approved),
                f"{elapsed_ms:.3f}",
            )
        )

    with OUT_PATH.open("w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            ["query_idx", "query_label", "top5_idx", "top5_labels", "fraud_score", "approved", "elapsed_ms"]
        )
        writer.writerows(rows)

    arr = np.array(times_ms)
    approved_arr = np.array([r[5] for r in rows], dtype=bool)
    qlabels_arr = np.array([r[1] for r in rows], dtype=np.uint8)

    print()
    print(f"=== resultados ===")
    print(f"queries: {len(rows):,}")
    print(f"approved=True : {int(approved_arr.sum()):>5}  ({approved_arr.mean() * 100:.1f}%)")
    print(f"approved=False: {int((~approved_arr).sum()):>5}  ({(~approved_arr).mean() * 100:.1f}%)")
    print(f"latência por query (numpy f32, 1 thread):")
    print(f"  mean: {arr.mean():.2f} ms")
    print(f"  p50 : {np.percentile(arr, 50):.2f} ms")
    print(f"  p99 : {np.percentile(arr, 99):.2f} ms")
    print(f"  max : {arr.max():.2f} ms")
    print()
    print(f"sanidade — distribuição de query_label vs approved:")
    print(f"  query_label=fraud (1) e approved=True : {int(((qlabels_arr == 1) & approved_arr).sum()):>4}  (FN se ground truth)")
    print(f"  query_label=fraud (1) e approved=False: {int(((qlabels_arr == 1) & ~approved_arr).sum()):>4}  (TP)")
    print(f"  query_label=legit(0) e approved=True : {int(((qlabels_arr == 0) & approved_arr).sum()):>4}  (TN)")
    print(f"  query_label=legit(0) e approved=False: {int(((qlabels_arr == 0) & ~approved_arr).sum()):>4}  (FP)")
    print()
    print(f"salvo em {OUT_PATH}")


if __name__ == "__main__":
    main()
