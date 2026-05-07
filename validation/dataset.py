"""Carregamento (e cache) do dataset oficial de referência.

A primeira chamada faz streaming do `references.json.gz` (~284 MB descomprimido,
3 milhões de itens) e materializa dois arrays numpy: vetores f32 (3M, 14) e
labels uint8 (0=legit, 1=fraud). O resultado vai para `data/references.npz`,
de onde as próximas chamadas leem em <1s.
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path
from time import perf_counter

import ijson
import numpy as np
from tqdm import tqdm

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
GZ_PATH = DATA_DIR / "references.json.gz"
CACHE_PATH = DATA_DIR / "references.npz"
EXPECTED_COUNT = 3_000_000
DIM = 14

LABEL_FRAUD = np.uint8(1)
LABEL_LEGIT = np.uint8(0)


def _build_cache() -> tuple[np.ndarray, np.ndarray]:
    vectors = np.empty((EXPECTED_COUNT, DIM), dtype=np.float32)
    labels = np.empty(EXPECTED_COUNT, dtype=np.uint8)

    with gzip.open(GZ_PATH, "rb") as fh:
        items = ijson.items(fh, "item")
        bar = tqdm(total=EXPECTED_COUNT, desc="parsing references", unit="vec")
        idx = 0
        for item in items:
            v = item["vector"]
            if len(v) != DIM:
                raise ValueError(f"linha {idx} com {len(v)} dims (esperado {DIM})")
            vectors[idx, :] = v
            labels[idx] = LABEL_FRAUD if item["label"] == "fraud" else LABEL_LEGIT
            idx += 1
            if idx % 10_000 == 0:
                bar.update(10_000)
        bar.update(idx % 10_000)
        bar.close()

    if idx != EXPECTED_COUNT:
        vectors = vectors[:idx]
        labels = labels[:idx]
        print(f"[aviso] esperava {EXPECTED_COUNT} vetores, encontrou {idx}")

    np.savez(CACHE_PATH, vectors=vectors, labels=labels)
    return vectors, labels


def load_references() -> tuple[np.ndarray, np.ndarray]:
    """Retorna (vectors[N,14] float32, labels[N] uint8). Usa cache npz se houver."""
    if CACHE_PATH.exists():
        t0 = perf_counter()
        with np.load(CACHE_PATH) as z:
            vectors = z["vectors"]
            labels = z["labels"]
        print(f"loaded {len(vectors):,} refs from cache in {perf_counter() - t0:.2f}s")
        return vectors, labels

    print(f"cache ausente; construindo de {GZ_PATH.name}")
    t0 = perf_counter()
    vectors, labels = _build_cache()
    print(f"built cache in {perf_counter() - t0:.1f}s; saved to {CACHE_PATH}")
    return vectors, labels


def load_normalization() -> dict[str, float]:
    return json.loads((DATA_DIR / "normalization.json").read_text())


def load_mcc_risk() -> dict[str, float]:
    return json.loads((DATA_DIR / "mcc_risk.json").read_text())


if __name__ == "__main__":
    v, l = load_references()
    print(f"shape vetores: {v.shape}  dtype={v.dtype}  RSS aprox: {v.nbytes / 2**20:.1f} MB")
    print(f"labels: fraud={int(l.sum()):,}  legit={int((l == 0).sum()):,}")
    print(f"primeiras 2 linhas:\n{v[:2]}")
