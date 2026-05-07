"""Quantização int8 dos vetores de referência.

Esquema:
- valores no intervalo [0, 1] → [0, 127] linear.
- sentinel -1 (idx 5 e 6 quando last_transaction é null) → -127.

Em int8 (signed, -128..127), -127 fica suficientemente longe de [0, 127]
para preservar o agrupamento natural de "sem histórico" no KNN.

A distância no espaço quantizado é dot product de int8 com acumulador
int32, replicando o espírito da distância euclidiana ao quadrado:

    d² = Σ (a_i - b_i)²    (sobre 14 dims)

Como int8 sai do range int8 quando elevado ao quadrado (até 32258), o
acumulador precisa ser int32 — o numpy faz isso automaticamente quando
usamos `astype(np.int32)` no diff antes do square.
"""

from __future__ import annotations

import numpy as np

SCALE = 127.0
SENTINEL_FLOAT = -1.0
SENTINEL_INT8 = np.int8(-127)


def quantize(vectors_f32: np.ndarray) -> np.ndarray:
    """Recebe (N,14) float32 com valores [0,1] ou -1; devolve (N,14) int8."""
    if vectors_f32.dtype != np.float32:
        vectors_f32 = vectors_f32.astype(np.float32)
    out = np.empty_like(vectors_f32, dtype=np.int8)
    sentinel_mask = vectors_f32 == SENTINEL_FLOAT
    scaled = np.rint(np.clip(vectors_f32, 0.0, 1.0) * SCALE).astype(np.int8)
    out[:] = scaled
    out[sentinel_mask] = SENTINEL_INT8
    return out


def squared_distance_int8(refs_i8: np.ndarray, q_i8: np.ndarray) -> np.ndarray:
    """Distância euclidiana ao quadrado, todos para um. Acumulador int32.

    refs_i8: (N, 14) int8
    q_i8:    (14,)   int8
    """
    diff = refs_i8.astype(np.int16) - q_i8.astype(np.int16)
    return np.einsum("ij,ij->i", diff, diff, dtype=np.int32, casting="unsafe")
