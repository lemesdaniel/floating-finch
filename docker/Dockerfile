# syntax=docker/dockerfile:1.7
# ---------- 1) preproc-python ----------
# Treina o IVF k-means e gera index.bin a partir do references.json.gz.
# Roda só no build; runtime não tem Python.
FROM --platform=linux/amd64 python:3.11-slim AS preproc

WORKDIR /work

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

# usa a mesma SHA do dataset que o organizador usa (consistência)
ARG RINHA_DATA_REF=main
RUN mkdir -p data \
    && curl -fsSL \
       "https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/${RINHA_DATA_REF}/resources/references.json.gz" \
       -o data/references.json.gz

# instala libs mínimas (numpy + scikit-learn + ijson + tqdm)
RUN pip install --no-cache-dir numpy scikit-learn ijson tqdm

COPY validation/dataset.py validation/build_index_only.py /work/validation/

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# pipeline: load refs → k-means → emit index.bin (v2 SoA per-cluster)
RUN python validation/build_index_only.py /work/data/index.bin

# ---------- 2) nim-builder ----------
# Compila o binário da API em Nim com AVX2 + FMA (linux/amd64).
FROM --platform=linux/amd64 nimlang/nim:2.2.10 AS nim-builder

WORKDIR /work

COPY nim/floating_finch.nimble /work/
RUN nimble install -y mummy jsony

COPY nim/src /work/src

# release com AVX2/FMA, ARC mm, link-time optimization
RUN nim c \
        -d:release \
        -d:lto \
        --opt:speed \
        --mm:arc \
        --passC:"-O3 -mavx2 -mfma -fno-strict-aliasing -ffast-math" \
        --passL:"-O3" \
        -o:/work/floating_finch \
        src/floating_finch.nim

# ---------- 3) runtime ----------
FROM --platform=linux/amd64 debian:bookworm-slim AS runtime

LABEL org.opencontainers.image.source="https://github.com/lemesdaniel/floating-finch"
LABEL org.opencontainers.image.description="Rinha de Backend 2026 — fraud detection via vector search (Nim + IVF k-means)"
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /app

COPY --from=nim-builder /work/floating_finch /app/floating_finch
COPY --from=preproc /work/data/index.bin /app/data/index.bin

ENV INDEX_PATH=/app/data/index.bin
ENV BIND_HOST=0.0.0.0
ENV BIND_PORT=8080

EXPOSE 8080

ENTRYPOINT ["/app/floating_finch"]
