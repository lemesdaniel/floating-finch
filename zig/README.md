# floating-finch — versão Zig

Porta da v1 Nim para **Zig 0.14.1**, reusando o mesmo algoritmo IVF + bbox repair
mas com:

- **Layout SoA per-cluster** no `index.bin` (versão 2 do formato — flag bit 0).
- **SIMD via `@Vector(8, i32)`** com 4 acumuladores i32 (4 dims cada) somando em i64 no final.
- **HTTP server custom**: TCP + parser HTTP manual + arena allocator por request.
  Single-thread, `Connection: close` por request (proof-of-concept didático;
  para perf máxima exigiria epoll edge-triggered + multi-thread).

## Resultado k6 oficial (local, QEMU emulação amd64 no Mac ARM, 0.40 CPU)

| Métrica | Valor |
|---|---|
| `final_score` | **3546.39** |
| `detection_score` | **3000** (teto — 0 FP, 0 FN, 0 erros HTTP) |
| `p99` | 284 ms |
| `failure_rate` | 0% |

A perda em score vs. Nim (5286) é toda em p99 — não em detecção. Causa principal
é o servidor HTTP minimal sem keep-alive eficiente; em ambiente x86 nativo + epoll
seria razoável esperar p99 < 50ms.

## Build local (Mac ARM)

```bash
zig build -Doptimize=ReleaseFast
INDEX_PATH=$PWD/../data/index_v2.bin ./zig-out/bin/floating_finch_zig
```

Requer `data/index_v2.bin` gerado pelo Python preproc:

```bash
python validation/build_index_only.py data/index_v2.bin   # default = SoA
```

## Build Docker (linux/amd64)

```bash
docker buildx build --platform linux/amd64 -f docker/Dockerfile.zig -t floating-finch-zig:test --load .
```

## Estrutura

```
zig/
├── build.zig
└── src/
    ├── types.zig       # constantes (Dim, K, ApprovedThreshold, response strings)
    ├── ivf.zig         # mmap loader v2 SoA (zero-cópia)
    ├── search.zig      # KNN com @Vector + bbox repair
    ├── vectorize.zig   # parse JSON + 14 features (espelho de vectorize.nim)
    ├── quantize.zig    # f32 → i16 com sentinel -1 → -10000
    ├── datetime.zig    # parser ISO8601 UTC + epoch + weekday
    └── main.zig        # TCP server single-thread + HTTP parser
```
