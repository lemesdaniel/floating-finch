# floating-finch — versão Zig

Porta da v1 Nim para **Zig 0.15.1 + [httpz](https://github.com/karlseguin/http.zig)**,
reusando o mesmo algoritmo IVF + bbox repair mas com:

- **Layout SoA per-cluster** no `index.bin` (versão 2 do formato — flag bit 0).
- **SIMD via `@Vector(8, i32)`** com 4 acumuladores i32 (4 dims cada) somando em i64 no final.
- **httpz multi-thread**, 3 workers (sweet spot empírico sob 0.40 CPU/container).

## Resultado k6 oficial (local, QEMU emulação amd64 no Mac ARM, 0.40 CPU)

| Variante | score | p99 | det |
|---|---|---|---|
| Custom server (close/req) | 3546 | 284 ms | 3000 |
| httpz, 1 worker | 5016 | 9.6 ms | 3000 |
| httpz, 2 workers | 5390 | 4.1 ms | 3000 |
| **httpz, 3 workers** | **5506** | **3.1 ms** | **3000** |
| httpz, 4 workers | 4803 | 15.7 ms | 3000 |

Para comparação: **Nim v1 = 5286 (p99 5.17ms)**. A versão Zig+httpz com 3 workers
**supera o Nim local** em ~220 pontos.

Detecção sempre 100% (0 FP, 0 FN, 0 erros HTTP) — algoritmo idêntico em ambas
versões.

## Build local (Mac ARM, host-native)

```bash
cd zig && zig build -Doptimize=ReleaseFast
INDEX_PATH=$PWD/../data/index_v2.bin ./zig-out/bin/floating_finch_zig
```

Requer `data/index_v2.bin` gerado pelo Python preproc:

```bash
python validation/build_index_only.py data/index_v2.bin   # default = SoA
```

## Build linux/amd64 (cross-compile do Mac)

```bash
cd zig && zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3
```

O binário em `zig-out/bin/floating_finch_zig` é linux x86_64. Reusado pelo Docker.

## Build Docker

```bash
docker buildx build --platform linux/amd64 -f docker/Dockerfile.zig -t floating-finch-zig:test --load .
```

(O Dockerfile assume que `zig-out/bin/floating_finch_zig` já existe — cross-compile
pelo host evita o bug do build runner Zig 0.15 sob emulação amd64 no Mac ARM.)

## Estrutura

```
zig/
├── build.zig
├── build.zig.zon       # dep httpz branch zig-0.15
└── src/
    ├── types.zig       # constantes (Dim, K, ApprovedThreshold, response strings)
    ├── ivf.zig         # mmap loader v2 SoA (zero-cópia)
    ├── search.zig      # KNN com @Vector + bbox repair
    ├── vectorize.zig   # parse JSON + 14 features (espelho de vectorize.nim)
    ├── quantize.zig    # f32 → i16 com sentinel -1 → -10000
    ├── datetime.zig    # parser ISO8601 UTC + epoch + weekday
    └── main.zig        # httpz Server + handlers
```
