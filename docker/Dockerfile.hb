# syntax=docker/dockerfile:1.7
# v8 httpbeast: troca mummy por httpbeast (epoll single/multi-thread, async).

# ---------- 1) preproc-python ----------
FROM --platform=linux/amd64 python:3.11-slim AS preproc

WORKDIR /work

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

ARG RINHA_DATA_REF=main
RUN mkdir -p data \
    && curl -fsSL \
       "https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/${RINHA_DATA_REF}/resources/references.json.gz" \
       -o data/references.json.gz

RUN pip install --no-cache-dir numpy scikit-learn ijson tqdm

COPY validation/dataset.py validation/build_index_only.py /work/validation/

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

RUN python validation/build_index_only.py /work/data/index.bin

# ---------- 2) nim-builder ----------
FROM --platform=linux/amd64 nimlang/nim:2.2.10 AS nim-builder

WORKDIR /work

COPY nim/floating_finch.nimble /work/
RUN nimble install -y mummy jsony httpbeast

COPY nim/src /work/src

RUN nim c \
    -d:release \
    -d:lto \
    --opt:speed \
    --threads:on \
    --mm:arc \
    --passC:"-O3 -mavx2 -mfma -fno-strict-aliasing -ffast-math" \
    --passL:"-O3" \
    -o:/work/floating_finch \
    src/floating_finch_hb.nim

# ---------- 3) runtime ----------
FROM --platform=linux/amd64 debian:bookworm-slim AS runtime

LABEL org.opencontainers.image.source="https://github.com/lemesdaniel/floating-finch"
LABEL org.opencontainers.image.description="Rinha 2026 — Nim httpbeast"
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /app

COPY --from=nim-builder /work/floating_finch /app/floating_finch
COPY --from=preproc /work/data/index.bin /app/data/index.bin

ENV INDEX_PATH=/app/data/index.bin
ENV BIND_HOST=0.0.0.0
ENV BIND_PORT=8080

EXPOSE 8080

ENTRYPOINT ["/app/floating_finch"]
