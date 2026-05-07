"""§6.7+ — Emite o arquivo binário index.bin a partir do cache npz.

Layout: ver nim/docs/INDEX_BIN_FORMAT.md.

Uso típico:
    uv run python validation/09_emit_index_bin.py data/index.bin

Em produção (Docker build), este script roda como preprocessor antes do runtime
Nim. Alternativa: portar k-means para Nim (mais código, sem ganho real porque
preprocess roda só no build).
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path
from time import perf_counter

import numpy as np

from dataset import DATA_DIR

INDEX_CACHE = DATA_DIR / "ivf_kmeans.npz"
DEFAULT_OUT = DATA_DIR / "index.bin"

MAGIC = b"RIVF"
VERSION = 1
DIM = 14
QUANT_SCALE = 10_000.0
HEADER_SIZE = 64
ALIGN = 64


def pad_to(stream, alignment: int) -> None:
    pos = stream.tell()
    rem = pos % alignment
    if rem:
        stream.write(b"\x00" * (alignment - rem))


def main() -> None:
    out_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    if not INDEX_CACHE.exists():
        raise SystemExit(f"falta {INDEX_CACHE}; rode validation/07_ivf_kmeans.py antes")

    z = np.load(INDEX_CACHE)
    centroids = np.ascontiguousarray(z["centroids"], dtype=np.float32)
    bbox_min = np.ascontiguousarray(z["bbox_min"], dtype=np.int16)
    bbox_max = np.ascontiguousarray(z["bbox_max"], dtype=np.int16)
    offsets = np.ascontiguousarray(z["offsets"], dtype=np.uint32)
    labels = np.ascontiguousarray(z["labels"], dtype=np.uint8)
    vectors = np.ascontiguousarray(z["vectors"], dtype=np.int16)

    n_clusters = len(centroids)
    n_vectors = len(vectors)
    assert centroids.shape == (n_clusters, DIM)
    assert bbox_min.shape == (n_clusters, DIM)
    assert bbox_max.shape == (n_clusters, DIM)
    assert offsets.shape == (n_clusters + 1,)
    assert labels.shape == (n_vectors,)
    assert vectors.shape == (n_vectors, DIM)

    print(f"emitindo {out_path}  (n={n_vectors:,}, k={n_clusters})")
    t0 = perf_counter()
    with out_path.open("wb") as fh:
        # header (64 bytes)
        fh.write(MAGIC)
        fh.write(struct.pack("<I", VERSION))
        fh.write(struct.pack("<I", n_vectors))
        fh.write(struct.pack("<I", n_clusters))
        fh.write(struct.pack("<I", DIM))
        fh.write(struct.pack("<f", QUANT_SCALE))
        fh.write(struct.pack("<Q", 0))  # flags
        fh.write(b"\x00" * (HEADER_SIZE - fh.tell()))
        assert fh.tell() == HEADER_SIZE

        for name, arr in [
            ("centroids", centroids),
            ("bbox_min", bbox_min),
            ("bbox_max", bbox_max),
            ("offsets", offsets),
            ("labels", labels),
            ("vectors", vectors),
        ]:
            pad_to(fh, ALIGN)
            block_offset = fh.tell()
            fh.write(arr.tobytes())
            print(f"  {name:>10}: offset {block_offset:>10,}  size {arr.nbytes:>11,} bytes  shape {arr.shape}")

    size = out_path.stat().st_size
    print(f"OK  {size:,} bytes ({size / 2**20:.1f} MB)  em {perf_counter() - t0:.1f}s")


if __name__ == "__main__":
    main()
