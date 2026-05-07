"""§6.6 — Simulador de score_det a partir de uma matriz de confusão hipotética.

Usa as fórmulas oficiais (docs/br/AVALIACAO.md):

    E = 1·FP + 3·FN + 5·Err
    ε = E / N
    falhas = FP + FN + Err
    taxa_falhas = falhas / N

    se taxa_falhas > 15%: score_det = -3000
    senão: score_det = 1000·log10(1/max(ε, 0.001)) - 300·log10(1+E)

E para latência:
    se p99 > 2000ms: score_p99 = -3000
    senão: score_p99 = 1000·log10(1000ms / max(p99, 1ms))
    teto: +3000 (p99 ≤ 1ms)

Uso: estimar score_final esperado de cada abordagem, dado:
- recall em relação ao brute-force exato (ground truth)
- composição de FP/FN/TP/TN do ground truth
- latência p99 estimada para a stack final (Nim+SIMD)
"""

from __future__ import annotations

import csv
import math
from dataclasses import dataclass

from dataset import DATA_DIR

GT_PATH = DATA_DIR / "ground_truth.csv"


@dataclass
class Confusion:
    tp: int
    tn: int
    fp: int
    fn: int

    @property
    def n(self) -> int:
        return self.tp + self.tn + self.fp + self.fn


def score_det(c: Confusion, http_err: int = 0) -> float:
    n = c.n + http_err
    e = 1 * c.fp + 3 * c.fn + 5 * http_err
    fail_rate = (c.fp + c.fn + http_err) / n
    if fail_rate > 0.15:
        return -3000.0
    eps = e / n
    return 1000 * math.log10(1 / max(eps, 0.001)) - 300 * math.log10(1 + e)


def score_p99(p99_ms: float) -> float:
    if p99_ms > 2000:
        return -3000.0
    return min(1000 * math.log10(1000 / max(p99_ms, 1.0)), 3000.0)


def load_ground_truth() -> list[dict]:
    rows: list[dict] = []
    with GT_PATH.open() as fh:
        for row in csv.DictReader(fh):
            rows.append(
                {
                    "query_label": int(row["query_label"]),
                    "approved": bool(int(row["approved"])),
                }
            )
    return rows


def confusion_from_gt(gt: list[dict]) -> Confusion:
    tp = sum(1 for r in gt if r["query_label"] == 1 and not r["approved"])
    tn = sum(1 for r in gt if r["query_label"] == 0 and r["approved"])
    fp = sum(1 for r in gt if r["query_label"] == 0 and not r["approved"])
    fn = sum(1 for r in gt if r["query_label"] == 1 and r["approved"])
    return Confusion(tp=tp, tn=tn, fp=fp, fn=fn)


def degrade_recall(gt: Confusion, recall: float) -> Confusion:
    """Aproxima a confusion matrix se a abordagem tiver `recall` de concordância
    com o ground truth (decisões que mudam ficam ~uniforme entre as outras classes).
    """
    n = gt.n
    n_wrong = round(n * (1 - recall))
    if n_wrong == 0:
        return gt
    tp_lost = round(n_wrong * gt.tp / n)
    tn_lost = round(n_wrong * gt.tn / n)
    fp_extra = tp_lost
    fn_extra = tn_lost
    return Confusion(
        tp=gt.tp - tp_lost,
        tn=gt.tn - tn_lost,
        fp=gt.fp + fp_extra,
        fn=gt.fn + fn_extra,
    )


def estimate_score_det_harness(recall_vs_bruteforce: float, n_total: int = 54_100) -> float:
    """Estima score_det dado o recall da nossa solução vs brute-force exato.

    O harness oficial mede APROVED da nossa solução vs APROVED do brute-force
    exato (que é o gabarito por construção do test-data). Se nossas decisões
    coincidirem 100%, FP=FN=0 e score_det=3000.

    Quando há discordância, ela vira FP ou FN. Modelagem 50/50 (aproximação;
    em distribuição balanceada do dataset isso é razoável).
    """
    n_wrong = round(n_total * (1 - recall_vs_bruteforce))
    if n_wrong == 0:
        return 3000.0
    fp = n_wrong // 2
    fn = n_wrong - fp
    e = 1 * fp + 3 * fn
    fail_rate = (fp + fn) / n_total
    if fail_rate > 0.15:
        return -3000.0
    eps = e / n_total
    return 1000 * math.log10(1 / max(eps, 0.001)) - 300 * math.log10(1 + e)


def main() -> None:
    print(f"=== sensibilidade do score_det ao recall vs brute-force (harness 54.100 queries) ===")
    print(f"{'recall':>9}  {'erros':>6}  {'FP':>4}  {'FN':>4}  {'score_det':>10}")
    for recall in [1.0000, 0.9999, 0.9995, 0.999, 0.998, 0.995, 0.990, 0.980, 0.95]:
        n_wrong = round(54100 * (1 - recall))
        fp = n_wrong // 2
        fn = n_wrong - fp
        s = estimate_score_det_harness(recall)
        print(f"{recall:>9.4f}  {n_wrong:>6}  {fp:>4}  {fn:>4}  {s:>10.0f}")

    print()
    print(f"=== sensibilidade do score_p99 a latência ===")
    print(f"{'p99 (ms)':>10}  {'score_p99':>10}")
    for p99 in [0.5, 1.0, 2.0, 5.0, 10.0, 50.0, 100.0, 500.0, 1000.0, 2000.0]:
        print(f"{p99:>10.1f}  {score_p99(p99):>10.0f}")

    print()
    print(f"=== combinações realistas (recall medido + latência estimada Nim) ===")
    scenarios = [
        # nome,                                          recall, p99 ms (Nim+SIMD est.)
        ("brute-force int8 + Nim SIMD",                  0.998,  3.0),
        ("IVF kmeans nprobe=1 (§6.7)",                   0.997,  0.20),
        ("IVF kmeans nprobe=1+repair[2-3] (§6.7)",       0.999,  0.40),
        ("IVF kmeans + rerank k=20 + repair[2-3] (§6.8)",0.999,  0.50),
        ("IVF kmeans + rerank k=100 + nprobe=2 + repair[1-4] (§6.8) ⭐", 1.000, 0.80),
        ("(referência) vinicius cpp-ivf top-3",          1.000,  1.29),
        ("(referência) thiagorigonatti #1",              1.000,  1.00),
    ]
    print(f"{'cenário':>62}  {'recall':>8}  {'p99 ms':>7}  {'sc_det':>7}  {'sc_p99':>7}  {'TOTAL':>7}")
    for name, recall, p99 in scenarios:
        d = estimate_score_det_harness(recall)
        p = score_p99(p99)
        t = d + p
        print(f"{name:>62}  {recall:>8.4f}  {p99:>7.2f}  {d:>7.0f}  {p:>7.0f}  {t:>7.0f}")


if __name__ == "__main__":
    main()
