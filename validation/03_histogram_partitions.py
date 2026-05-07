"""§6.3 — Histograma das 16 partições categóricas.

Particionamento proposto na §3 do plano (chave de 4 bits):
- bit 0: tem_last_tx       (idx 5 != -1)
- bit 1: unknown_merchant  (idx 11 == 1)
- bit 2: is_online         (idx 9 == 1)
- bit 3: card_present      (idx 10 == 1)

Pergunta: a distribuição é razoavelmente balanceada?
Critério da §6: max/min < 10×. Se passar, IVF simples por essas
features é viável. Se quebrar, precisa repartição (quantis em outras
dims, hash, ou abandonar IVF).
"""

from __future__ import annotations

import numpy as np

from dataset import load_references


def main() -> None:
    refs, labels = load_references()
    n = len(refs)

    has_last_tx = (refs[:, 5] != -1.0).astype(np.uint8)
    unknown_mer = (refs[:, 11] == 1.0).astype(np.uint8)
    is_online = (refs[:, 9] == 1.0).astype(np.uint8)
    card_present = (refs[:, 10] == 1.0).astype(np.uint8)

    bucket = (has_last_tx << 0) | (unknown_mer << 1) | (is_online << 2) | (card_present << 3)

    counts = np.zeros(16, dtype=np.int64)
    fraud_counts = np.zeros(16, dtype=np.int64)
    for b in range(16):
        mask = bucket == b
        counts[b] = mask.sum()
        fraud_counts[b] = labels[mask].sum()

    print(f"=== §6.3 — distribuição em 16 partições ===")
    print(f"total: {n:,} vetores  ({int(labels.sum()):,} fraud / {int((labels == 0).sum()):,} legit)")
    print()
    print(f"{'bucket':>6}  {'card_p':>6}  {'online':>6}  {'unkmer':>6}  {'haslast':>7}  {'count':>10}  {'%':>6}  {'fraud%':>7}")
    for b in range(16):
        c = counts[b]
        pct = c / n * 100
        f = fraud_counts[b]
        f_pct = (f / c * 100) if c > 0 else 0.0
        bits = (
            int(b >> 3 & 1),
            int(b >> 2 & 1),
            int(b >> 1 & 1),
            int(b & 1),
        )
        print(f"{b:>6}  {bits[0]:>6}  {bits[1]:>6}  {bits[2]:>6}  {bits[3]:>7}  {c:>10,}  {pct:>5.2f}%  {f_pct:>6.2f}%")

    nonzero = counts[counts > 0]
    print()
    print(f"min: {nonzero.min():,}   max: {counts.max():,}   max/min: {counts.max() / nonzero.min():.1f}×")
    print(f"vazias: {int((counts == 0).sum())} de 16")
    print(f"top-1 partição contém {counts.max() / n * 100:.1f}% dos vetores")
    print(f"top-2 partições contêm {np.sort(counts)[-2:].sum() / n * 100:.1f}% dos vetores")
    print(f"top-4 partições contêm {np.sort(counts)[-4:].sum() / n * 100:.1f}% dos vetores")

    print()
    if counts.max() / nonzero.min() > 10:
        print(f"⚠️ ASSIMETRIA > 10× — IVF simples sofrerá: a partição maior vira o gargalo.")
        print(f"   Considere: quantis adicionais, hash partitioning, ou rever divisão.")
    else:
        print(f"✅ Assimetria dentro do tolerável (<10×) — IVF por estas 4 features é viável.")


if __name__ == "__main__":
    main()
