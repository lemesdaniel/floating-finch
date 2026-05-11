# syntax=docker/dockerfile:1.7
#
# v2 Zig — usa binário cross-compilado pelo host (zig é cross-compiler, evita
# bug do build runner sob emulação amd64 em Mac ARM).
#
# Antes de buildar este Dockerfile, gere o binário linux/amd64:
#
#   cd zig
#   zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3

# ---------- 1) preproc-python ----------
FROM --platform=linux/amd64 python:3.11-slim AS preproc

WORKDIR /work

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG RINHA_DATA_REF=main
RUN mkdir -p data \
    && curl -fsSL \
       "https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/${RINHA_DATA_REF}/resources/references.json.gz" \
       -o data/references.json.gz

RUN pip install --no-cache-dir numpy scikit-learn ijson tqdm

COPY validation/dataset.py validation/build_index_only.py /work/validation/

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

# emite index.bin v2 SoA (default)
RUN python validation/build_index_only.py --blocks /work/data/index.bin

# ---------- 2) runtime ----------
FROM --platform=linux/amd64 debian:bookworm-slim AS runtime

LABEL org.opencontainers.image.source="https://github.com/lemesdaniel/floating-finch-zig"
LABEL org.opencontainers.image.description="Rinha de Backend 2026 — fraud detection (Zig + httpz + IVF SoA)"
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /app

COPY zig/zig-out/bin/floating_finch_zig /app/floating_finch_zig
COPY --from=preproc /work/data/index.bin /app/data/index.bin

ENV INDEX_PATH=/app/data/index.bin
ENV BIND_HOST=0.0.0.0
ENV BIND_PORT=8080

EXPOSE 8080

ENTRYPOINT ["/app/floating_finch_zig"]
