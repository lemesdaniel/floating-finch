# Formato binário do `index.bin`

Arquivo gerado pelo `preprocess` (Nim) a partir de `references.json.gz`,
consumido pelo runtime (`floating_finch`) via `mmap` ou leitura direta.

## Layout (little-endian)

| offset | tamanho | tipo | conteúdo |
|---|---|---|---|
| 0 | 4 | char[4] | magic `RIVF` |
| 4 | 4 | uint32 | version (= 1) |
| 8 | 4 | uint32 | n_vectors (= 3.000.000) |
| 12 | 4 | uint32 | n_clusters (= 2048) |
| 16 | 4 | uint32 | dim (= 14) |
| 20 | 4 | float32 | quant_scale (= 10000.0) |
| 24 | 8 | uint64 | flags (reservado, zero por enquanto) |
| 32 | 32 | byte[32] | reserved (zero) |
| 64 | n_clusters × 14 × 4 | float32[][] | centroids (k-means) |
| ... | n_clusters × 14 × 2 | int16[][] | bbox_min |
| ... | n_clusters × 14 × 2 | int16[][] | bbox_max |
| ... | (n_clusters + 1) × 4 | uint32[] | offsets (cumulative) |
| ... | n_vectors × 1 | uint8[] | labels (0=legit, 1=fraud) |
| ... | n_vectors × 14 × 2 | int16[][] | vectors (quantizados, ordenados por cluster) |

Cada bloco começa em offset alinhado a **64 bytes** (cache line). Zeros de
padding entre blocos onde necessário.

## Tamanho estimado (n=3M, k=2048, dim=14)

| Bloco | Bytes |
|---|---|
| header | 64 |
| centroids | 114.688 |
| bbox_min | 57.344 |
| bbox_max | 57.344 |
| offsets | 8.196 |
| labels | 3.000.000 |
| vectors | 84.000.000 |
| **TOTAL** | **~87 MB** |

## Decisão sobre rerank fp32 (v1 vs v2)

**v1 — sem rerank**: usar apenas `vectors` int16. Recall medido ~99.9%.
Score esperado ~5089 (top 21).

**v2 — com rerank fp32**: precisa dos vetores originais em float32 (+168 MB)
ou half-precision (+84 MB). Não cabe em 165 MB por API. Caminhos:
- mmap compartilhado entre as duas APIs (precisa validar cgroup accounting).
- Serviço dedicado `vector-svc` com 1 instância segurando 168 MB.

A v1 entrega rapidamente; a v2 evolui para 100% recall (score ~6000) se a
infra permitir.

## Convenções de quantização

```
int16_value = round(clamp(float_value, 0, 1) * 10000)
sentinel float -1 → int16 -10000  (longe de [0, 10000])
```

A quantização é **lossy mas determinística**. O erro residual em busca pura
int16 é ~0.1% das decisões — corrigível só com rerank fp32 (v2).
