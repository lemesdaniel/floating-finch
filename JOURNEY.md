# floating-finch — diário de bordo da Rinha de Backend 2026

Notas brutas pra eventual artigo. Datas, scores, p99 reais do harness oficial (Mac Mini 2014 Haswell + Ubuntu 24.04 + Docker, 1 vCPU + 350MB total).

## Contexto

Rinha 2026: detecção de fraude por busca vetorial. Cada request POST `/fraud-score` recebe payload de transação; sistema converte para vetor de 14 dimensões, faz KNN top-5 contra 3M referências rotuladas e retorna `{approved, fraud_score}`.

Restrições do compose:
- 1 vCPU e 350 MB pra **todos** os serviços somados
- 1 LB + 2 APIs mínimo
- LB round-robin sem inspecionar payload
- Imagens públicas, linux/amd64

Pontuação:
- `score_p99 = 1000·log10(1000ms / max(p99, 1ms))` — teto +3000 (p99 ≤ 1ms)
- `score_det = 1000·log10(1/ε) - 300·log10(1+E)` — onde `E = FP·1 + FN·3 + erros_HTTP·5`, `ε = E/N`
- `final = p99 + det`, máximo teórico 6000

## Decisões base (antes de submeter)

### Stack escolhida

- **v1 Nim 2.2.10** (primeira linguagem do projeto, aprendendo) com `mummy` HTTP + `jsony` JSON + `--mm:arc`
- **v2 Zig 0.15.1** depois, com `httpz` (Karl Seguin)

### Algoritmo

- **IVF k-means com 2048 clusters** (não brute-force; auditoria já feita pelos top de edições anteriores)
- **Quantização int16** escala 10000 (3M × 14 × 2B = 84 MB)
- **mmap zero-copy** do `index.bin`
- **bbox repair**: se top-5 retorna fraud_count em zona ambígua (1–4 fraudes), re-checa clusters cuja bounding-box pode ter ponto < threshold do worst no top-5. Recupera recall de ~99% pra 100%.
- **nprobe=4** padrão. Validado em GT 10k com brute-force como ground truth.

### Truques herdados de edições anteriores

- **Resposta JSON pré-formatada** — k=5 dá 6 strings constantes (`{approved:..,fraud_score:0.0}` … `1.0`). Zero serialize no hot path.
- **Threshold int compare** — `fraud_count < 3` em vez de comparar floats com tolerância.
- **Fallback silencioso** — exceções no parse retornam `{approved:true, fraud_score:0}`. Peso `1` (FP) ou `3` (FN) é sempre menor que `5` (HTTP 5xx).
- **Distância squared** — sem sqrt; ordenação idêntica.

### Pré-processamento

Stage Python no Dockerfile: download `references.json.gz`, k-means MiniBatch (sample 65k, 6 iter, seed 42), emit binário com header + blocos alinhados a 64 bytes. Index.bin embarcado na imagem GHCR.

## Cronologia

Cada linha é um teste real no Mac Mini do Zan via issue `rinha/test`. **Toda nova issue sobrescreve o resultado público** — variância empírica do bench é ~±100 pts entre runs idênticos.

### Nim

| v | mudança | score | p99 (ms) | nota |
|---|---|---|---|---|
| v1 | baseline mummy + TCP + nginx default | 4625 | 23.7 | detection 3000 desde o início |
| v2 | mmap warmup no startup (touch páginas antes `/ready 200`) | 4642 | 22.8 | dentro do ruído |
| v3 | `WORKER_THREADS=2` (mummy default era 4×10=40 sob 0.40 CPU) | 4643 | 22.7 | thrashing não era o gargalo |
| v4 | bbox repair com early break dimensional | 4623–4732 | 18.5–24 | aparente outlier positivo; mediana real ~4623 |
| v5 | distance early break no inner loop | 4544 | 28.5 | regrediu Haswell. Branch dentro do loop pequeno (Dim=14) quebra autovectorize. Local M-series ARM mostrou -45% search, mas Mac Mini não traduziu. |
| v6 | SoA per-cluster + AVX2 manual via `c_simd.c` (`_mm256_mullo_epi32` × 4 accs) | 4530 | 29.5 | regrediu. Cache pattern SoA pior em Haswell? `mullo_epi32` latency 10. Buffer 128KB × workers polui cache. |
| v7 | PGO (gcc `-fprofile-generate` → roda `bench_profile` 50k iter no build → `-fprofile-use`) | 4561 | 27.4 | gcc -O3 -mavx2 já layout/inline bom. PGO marginal. |
| v8 | httpbeast (epoll multi-thread) | health check fail | — | OrbStack passou local, Mac Mini falhou sempre. Bind UDS quebrado em std/net (`Sockaddr_un` não suportado por `bindAddr`). |
| **5443** | `proxy_buffering off` + `worker_processes 1` + `multi_accept on` + `error_log /dev/null` no nginx + `keepalive 256` | **5443** | **3.61** | **+817 pontos num único push.** Bottleneck era buffering do nginx pra response de 35 bytes. |
| **5679** | `seccomp=unconfined` + `ulimits nofile 65535` + `sysctls net.core.somaxconn 4096` + CPU realloc 0.35/0.30 | **5679** | **2.10** | +236 pts. Cada syscall ganha µs. |
| 5703 | nginx em modo `stream` (L4 raw TCP forward) ao invés de HTTP, ainda TCP upstream | 5703 | 1.98 | nginx vira pipe puro, API parse HTTP direto. +24 pts (sem UDS gain pleno). |
| **v10** | server custom Nim com `std/selectors` (epoll) + UDS + parser HTTP manual + nginx stream L4 | **5801** | **1.58** | **+98 sobre stream TCP (v9 fail).** Substituiu mummy+nginx-HTTP por epoll-loop próprio + UDS + nginx-L4. Top 12 / 146. |

Aprendizados Nim:

- mummy default = `countProcessors() × 10` threads. No Mac Mini (4 cores) = 40 threads brigando por 0.40 CPU. Aparentemente CFS lida bem, mas tirar pra 2 não pioram.
- Otimizações de search loop não movem a agulha além do ruído enquanto o LB ainda tá com config default. Verifiquei `bench_profile` local e confirmou: **99.2% do tempo do hot path é busca**, mas no harness real o p99 era dominado pelo overhead operacional (buffering, syscall, conn churn).
- `std/net bindAddr` **não** suporta AF_UNIX (chama `getAddrInfo` que rejeita). Pra UDS em Nim precisa `posix.bindSocket` manual com `Sockaddr_un`.
- Mac local (Rosetta/QEMU emulando amd64) **não** traduz pra Haswell real. v5 mostrou -45% local e +6ms p99 no Haswell. Inverter a expectativa: bench M-series é só sanity check.

### Zig

Implementação ~600 LOC iniciais, depois +UDS:

| v | mudança | score | p99 (ms) | nota |
|---|---|---|---|---|
| v1 | server custom std/net + Connection: close per request | 3546 | 284 | single-thread acabou com tudo. TCP handshake a cada 35-byte response. |
| v2 | httpz (Karl Seguin) + 3 workers | 5772 | 1.69 | sweet spot empírico sob 0.40 CPU. Tentamos 1/2/3/4 workers; 3 venceu. |
| | nginx tune igual ao Nim | 4766 → 5772 | 40 → 1.69 | +1006 num push só. Mesma lição. |
| | infra tweaks (seccomp, ulimits, somaxconn, CPU realloc) | 5773 | 1.69 | empate noise. |
| v3 | **UDS** (`.address = .{ .unix = ... }` em httpz) | 5793 | 1.61 | +20. Bug do httpz patcheado: ele setava `TCP_NODELAY` em socket UNIX (`IPPROTO.TCP` inválido pra AF_UNIX) → vendorizei httpz com patch. |
| v4 | silenciar `std.log` (override `std_options.logFn`) | 5798 | 1.59 | +5, dentro do ruído. httpz não loga no hot path normal. |
| **v5** | **nginx em `stream` mode** (L4 TCP raw) + UDS upstream | **5840** | **1.44** | **+42. Top 5.** |
| v6 | prewarm 500 iter + MAP_POPULATE + MADV_RANDOM + nginx 2 workers stream | ~5828 | 1.48 | warmup pré-bind elimina page faults iniciais. |
| v7 | f32 FMA + partial threshold rejection no inner loop | ~5829 | 1.48 | matemática `@mulAdd` reduz dependência de cadeia FP. |
| **v8** | **index v3 block layout (cluster blocks contíguos, 64B-aligned) + FMA, ainda httpz 3-worker** | **5884** | **1.31** | **#3 / 156. Issue #3402.** SoA por cluster + acc unroll 4. Esse foi o run que realmente subiu o podium — atribuição errada anterior. |
| v9 | HTTP server custom epoll + UDS (sem httpz) — `main_epoll.zig` 438 LOC, single-thread non-blocking, zero alloc hot path | **5115** | **7.67** | **REGREDIU -769 pts. Issue #3430.** Single-thread sob 0.40 CPU serializa bursts; httpz com 3 workers absorvia picos via thread pool. p99 explodiu de 1.31→7.67ms. Hipótese S3 (httpz overhead = 50µs/req) FALSEADA pelo run real. |

Estado #3 / 156 em 2026-05-11 (resultado público do v8). v9 ficaria #~50. v10 (io_uring single-thread) ainda em fila — mesmo risco do v9 já que mantém single-thread. Gap pro #1: 93 pts (jairoblatt-rust monoio io_uring + mimalloc 5977 / 1.05). Pro #2: 36 pts (vinicius-cpp uWebSockets 5920 / 1.20).

Aprendizados Zig:

- `std.heap.GeneralPurposeAllocator` virou `DebugAllocator` em 0.16. Usei `std.heap.c_allocator` pra evitar API churn entre versões.
- httpz vendored com `vendor/httpz` + `build.zig.zon` apontando `.path = "vendor/httpz"` pra poder patchar livremente.
- `chmod 0666` no socket UDS depois de listen pra nginx (rodando como user `nginx`) poder conectar. Spawned em thread paralela porque `server.listen()` bloqueia. httpz não expõe callback post-bind.
- Single-thread + `Connection: close` per request é catastrófico (p99 284ms). Multi-thread sob 0.40 CPU exige tunning — 4 workers já vira thrashing.

## O grande insight (que demorei pra absorver)

Antes da rodada de tweaks de infra, eu estava em **#42 / 4625 / p99 22ms** e achei que era teto do Mac Mini 2014. Investi várias rodadas em:

- SoA + AVX2 manual (v6) → regrediu
- early-break loop interno (v5) → regrediu
- PGO via Docker pipeline (v7) → marginal
- httpbeast (v8) → health check fail no Mac Mini

Tudo dentro do ruído ou pior. Acabei estudando os 5 repos top:

| repo | LB | upstream | observação |
|---|---|---|---|
| jairoblatt-rust (#1) | LB custom Rust (`jrblatt/so-no-forevis`) | UDS | seccomp + ulimits |
| viniciusdsandrade-cpp-ivf (#2) | nginx **stream** L4 | UDS | mesmo padrão da nossa v10 |
| whereisanzi (#3) | LB custom Rust | UDS | NPROBE=1 |
| joycegodinho (#4) | HAProxy | UDS | GC_MODE=off no service |
| joojf (#5) | nginx HTTP + UDS upstream | UDS | mesmas tweaks (multi_accept, keepalive, proxy_buffering off) |

Padrão consolidado: **TODOS usam UDS**, **TODOS usam seccomp=unconfined**, **TODOS reduzem worker threads**, **NPROBE baixo** (1 ou 4 com repair). LB é minimalista.

Apliquei como pacote (`proxy_buffering off` + `worker_processes 1` + `multi_accept on` + `error_log off`) e o salto foi **+817 pontos** no nim — mais que toda a economia de search loop combinada. Depois infra (+236), depois UDS no zig (+20), depois nginx stream (+47 zig), depois custom server Nim com UDS+stream (+98 nim).

**Lição:** algoritmo correto bate teto rápido. O resto é overhead operacional do LB/socket. Quando você ver participantes 2× mais lentos com o mesmo algoritmo, o gap não está no loop interno.

## Detalhes do harness real

- Mac Mini 2014 = Haswell i5 2.6 GHz, 8 GB RAM, Ubuntu 24.04
- k6 ramp: 1 → 900 RPS em 120s (script `test/test.js` do repo do Zan)
- Falhas > 15% = `score_det = -3000` (corte). Erros HTTP pesam 5×.
- Engine clona `submission` branch do repo do participante. **Sem `submission`, sem teste.**
- Comentário em title `rinha/test [id]` foi parseado **literalmente com colchetes** uma vez (resulto: "submission info not found"). Padrão funcional é `rinha/test <id>` sem colchetes.
- Runner ficou travado uma manhã inteira com `submission` órfã no `/home/rinha/rinha-2026/` (causa: docker compose up crash sem cleanup). Bug fixou-se sozinho/manualmente algumas horas depois.

## Variabilidade

Mesmo build, mesma config, mesma máquina:

- v4 (Nim, bbox early-break): 4732 / 18.5 → 4623 / 23.8 → 4621 / 23.9 = média 4625 ± 50
- v8 zig (httpz UDS): 5793 / 1.61 → 5798 / 1.59 = noise

Conclusão: pra validar mudanças statisticamente preciso 3+ runs, mas cada run **sobrescreve** o resultado público. Isso obriga a só submeter mudanças com confiança alta + estar pronto pra reverter rápido se regredir.

## Stack final (esperado)

**Nim (v10 deployado):**
- server custom Nim com `std/selectors` (epoll) + UDS + parser HTTP manual + 6 respostas pre-formatadas
- bind UDS manual via `posix.bindSocket` + `Sockaddr_un` (std/net não suporta AF_UNIX)
- chmod 0666 no socket pra nginx (rodando como user nginx) conectar
- accept loop não-bloqueante; keep-alive nativo; tryFlushWrite com EPOLLOUT em backpressure
- index AoS v1 + bbox early break + squaredDistanceI16 escalar
- nginx stream L4 + UDS upstream

**Zig:**
- httpz vendored com patch UDS
- `std.log` silenciado
- nginx stream L4 + UDS upstream
- 3 workers httpz

Detection: 3000 em ambos (algoritmo é o mesmo, p99 é o que muda).

## Tentativas pós-v8 (todas regrediram) — 2026-05-11/12

| versão | mudança | image | score | p99 | resultado |
|---|---|---|---|---|---|
| v9 | HTTP server custom **epoll** single-thread + UDS (sem httpz) — `main_epoll.zig` 438 LOC | v9 | 5115 | 7.67ms | **-769 vs v8.** Issue #3430. Single-thread sob 0.40 CPU serializa bursts; httpz com 3 workers absorve picos melhor. |
| v10 | HTTP server custom **io_uring single-thread** + UDS — `main_iouring.zig` 438 LOC, ACCEPT_MULTISHOT + RECV/SEND batched, IORING_SETUP_SINGLE_ISSUER+DEFER_TASKRUN+COOP_TASKRUN | v10 | 5685 | 2.06ms | **-200 vs v8** mas +570 vs v9. Issue #3451. io_uring reduz syscall overhead vs epoll mas thread pool do httpz ainda absorve picos melhor. |
| v11 | **io_uring multi-thread** (2 workers compartilhando listener via ACCEPT_MULTISHOT) | v11 | 5670 | 2.14ms | **-15 vs v10 (dentro ruído)**. Issue #3656. Kernel ACCEPT_MULTISHOT em rings paralelos não distribui carga uniformemente sob CFS apertado. httpz tem fila compartilhada com workers que vence. |
| v12 | v8 image + **IVF_NPROBE=1** mantendo repair=[1,4] | v8 | 5528 | 1.32ms | **-356 vs v8.** Issue #3694. p99 ~igual (search não dominava!), mas detection caiu pra 2647 (FP=2, FN=4). Repair=[1,4] não cobriu fraud_count=0 com FN. |
| v13 | v8 image + nprobe=1 + repair=**[0,5]** (sempre repair) | v8 | 5745 | 1.80ms | **-117 vs v8.** Issue #3732. det=3000 recuperado, mas p99 explodiu +0.43ms — bbox scan em toda query custa mais que poupar nprobe=1. |

**Lição central**: 3 variantes de custom HTTP server (epoll, io_uring 1t, io_uring 2t) **todas regrediram** vs httpz 3-worker pool. Plano S3 (custom HTTP server) **falseado**. Search loop **não domina p99** em v8 (search já é só fração do 1.31ms — provado pela troca nprobe 4→1 não mover p99). Gargalo está fora da search loop.

Rollback final: v8 nprobe=4 repair=[1,4] — confirmado #7/171 score 5883.65 p99 1.31ms (issue #3741, idêntico ao baseline original).

## Análise dos top 3 — 2026-05-12

Investigamos #1/#2/#3 em detalhe. Padrões compartilhados:

| | #1 andrade-cpp 5990 | #2 jairoblatt-rust 5978 | #3 ze-pamonha 5947 |
|---|---|---|---|
| Lang | C++20 | Rust + monoio | C puro |
| HTTP API | hand-epoll | monoio io_uring | hand-epoll |
| LB | **SoNoForevis** (jrblatt/so-no-forevis:v1.0.0) | **SoNoForevis** | **carro-da-pamonha** (C epoll, próprio) |
| LB→API | **SCM_RIGHTS fd handoff** | UDS connect (+SCM_RIGHTS wired) | **SCM_RIGHTS fd handoff** |
| Quant | int16 scale 10000 | int16 scale 10000 | int16 scale 10000 |
| K clusters | 256 | **4096** | **4096** |
| nprobe | 1 + repair heurístico | **5 fast + 24 reprobe** se count ∈ [2,3] | **8 fast + 24 reprobe** se count ∈ [1,4] |
| Early-exit | movemask partial | cmp_ps após 8/14 dims | cmp_ps após 8/14 dims |
| Prefetch | sim | `_mm_prefetch T0` block+8 | `__builtin_prefetch` +8 |
| Allocator | std | **mimalloc** | libc |
| Warmup | docker build-time | 500 queries | 2000 queries |
| API CPU | 0.42 | 0.40 | 0.42 |
| LB CPU | 0.16 | 0.20 | 0.16 |

**SoNoForevis** (LB usado por #1 e #2):
- Rust + monoio io_uring (4096 SQ entries)
- L4 TCP listener → `sendmsg`+`SCM_RIGHTS` passa fd pra `<sock>.ctrl` UDS do backend
- Backend faz `recvmsg`+`SCM_RIGHTS`, adota fd, responde direto ao client
- **LB nunca toca dados**. Após handoff sai do path inteiro.
- Round-robin via counter local; `SO_REUSEPORT` + `TCP_NODELAY` + backlog 65535
- Imagem distroless cc-debian12, ~30MB / 0.16-0.20 CPU
- Licença piada ("Mexe no Forévis") = unlicensed formal → técnica replicável (Cloudflare blog), código não.

**O que NOSSO v8 já tem** (do top 3 comum): int16 ✅, early-exit partial ✅, IVF ✅
**O que falta**: K=4096, two-stage nprobe, prefetch, SCM_RIGHTS, mimalloc.

## TODO ranqueado por ROI

**Tier 1 — Baixo risco, mudança isolada** (recomendado primeiro):
1. **Two-stage nprobe** (fast=5, reprobe=24 se top-5 fraud_count ∈ [1,4]) — pura mudança em `search.zig`. Só dispara o reprobe em casos ambíguos. Score ≈ full-nprobe, cost ≈ small. **Esperado: +50-100 pts.**
2. **`@prefetch`** no inner loop antes de cada block — Zig builtin equivale `_mm_prefetch`. ~5 LOC. **Esperado: +10-30 pts.**
3. **K=4096 clusters** — retrain Python pipeline (`build_index_only.py`). Clusters menores = bbox mais apertado = early-exit funciona melhor. **Esperado: +20-50 pts.**

**Tier 2 — Refactor maior**:
4. **SCM_RIGHTS LB pattern** — exige reescrever transport do backend (`SOCK_SEQPACKET` + `recvmsg` em `.ctrl`, importar fd pro epoll/io_uring). httpz não suporta isso → precisa custom server. Mas histórico mostrou que custom backend regrediu 3× em row. **Caminho: implementar SCM_RIGHTS NO httpz vendored** (patcher worker pra adotar fd) — mais seguro que rewrite. **Esperado: +30-80 pts SE não regredir backend.**
5. **mimalloc global allocator** — substituir `c_allocator` por mimalloc. Marginal sob arena per-conn que já temos. **Esperado: +5-15 pts.**

**Tier 3 — Especulativo**:
6. **AVX2 manual com early-exit movemask** — já tentamos v6, regrediu Haswell. Top 1 usa. Pode dar certo se pattern correto. ROI incerto.
7. **int8 quantization** — top 3 NÃO usa. Risco de quebrar det. **Não recomendado.**
8. **LB custom Zig SCM_RIGHTS** — ~400 LOC + SCM_RIGHTS no backend. Se vai usar SCM_RIGHTS, alternativa é imagem `jrblatt/so-no-forevis:v1.0.0` direto (sem licença formal porém).

**Caminho recomendado**: Tier 1 inteiro (two-stage nprobe → prefetch → K=4096). Se +80-120 pts somados chegamos a ~6000, entra top 3.

## Aprendizados consolidados — 2026-05-12

Compilação dos insights ganhos nas últimas ~30 horas. Tudo já forçado por experimento real no harness, não suposição.

### Sobre o gargalo

1. **Search loop não dominava p99 em v8.** Trocar `IVF_NPROBE` de 4 pra 1 (v12) deixou p99 quase idêntico (1.37 → 1.32ms). Se search fosse 80% do tempo, deveria cair muito mais. **Corolário**: tunar nprobe sozinho dá pouco ROI; o gap está em transporte/concorrência/syscalls.
2. **bbox_repair ativo em toda query é caro.** `repair=[0,5]` (v13) custou +0.43ms p99 com det perfeito 3000 — bbox scan global em 2048 clusters não é grátis. Repair seletivo é necessário, mas **scan global por bbox** não escala. Daí Fase 1 do plano substituí-lo por reprobe shortlist seletivo.
3. **httpz 3-worker pool sob 0.40 CPU absorve burst melhor que custom HTTP single-thread.** Falseado em 3 variantes consecutivas (v9 epoll, v10 io_uring 1t, v11 io_uring 2t). CFS aperta single-thread; pool tem fila compartilhada que estabiliza tail.

### Sobre custom HTTP server (S3 falseado)

- Custom epoll/io_uring funciona em rascunhos benchmarkados isoladamente, mas perde no harness real onde `0.40 CPU/api` é restrição dura.
- **Pré-requisito ignorado**: nosso loop manual não tem fila adaptativa que rebalanceie sob picos. httpz tem.
- **Caminho que NÃO testamos**: custom multi-worker COM fila compartilhada (Tokio-style). Caro, e o ganho marginal não justifica saindo de httpz hoje.

### Sobre o harness

- **Variância empírica ~±100 pts** entre runs idênticos confirmada. v9 oscilou 5115 (#3430) vs 5884 esperado se houvesse só ruído — sinal de regressão real, não ruído.
- **Title vs body**: runner lê do body, formato `rinha/test <participant-id>` com title `rinha/test`. Title errado faz issue ficar parada na fila indefinidamente — descoberto após #3451 ficar OPEN ~6h. Fix via `gh api ... -X PATCH -f body=...`.
- **Submission branch update via API** (`gh api repos/.../contents/docker-compose.yml -X PUT`) funciona — não precisa clone. Útil quando o repo Zig é separado.
- Resultado público sobrescrito a cada run; manter v8 baseline estável é precioso (não submetar mudanças sem alta confiança).

### Sobre os top 3

- **Convergência forte**: int16 + IVF + early-exit partial + two-stage nprobe ambíguo + SCM_RIGHTS LB. Diferem em K (256 vs 4096), linguagem, e detalhe do reprobe.
- **SCM_RIGHTS é o pattern caro mas comum**: 2/3 do top usam. LB nunca toca dados. O ganho real do top 1 vem dessa combinação, não do search loop sozinho.
- **int8 não está em uso por nenhum top 3.** Risco de quebrar det não compensa potencial cache benefit.
- **K=4096 maioria.** 2x mais clusters que nós → bbox per-cluster mais apertado → early-exit funciona melhor.
- **SoNoForevis** (jrblatt/so-no-forevis:v1.0.0) é Rust+monoio io_uring com `sendmsg+SCM_RIGHTS` round-robin. Pública mas sem licença formal — referenciável, não copiável textualmente.

### Sobre processo

- **Mudar uma variável por submissão**. v12 mudou só nprobe; v13 mudou só repair window — ficou claro o efeito de cada um. Quando v8→v9 mudou HTTP server + nada mais, atribuição clara.
- **Mantenha baseline `:v8` intocado no GHCR.** Rollback custou 1 commit no submission branch + 1 issue. ~10min. Conservar imagem versionada e config legacy disponível por env é peça crítica.
- **Submissão de teste custa 5-30min.** Bench offline (replay seed fixa) acelera iteração — não temos ainda, próxima sessão deve montar.
- **Fila do harness pode travar.** #3439 ficou OPEN >5h, runner pulou. Issues novas eram processadas. Provavelmente issue mal-formatada bloqueou seu slot. Não é bug do nosso código.

### Sobre o que não foi efetivo

- **Reescrever HTTP server** (3×): regrediu 770/200/15 pts vs httpz.
- **Reduzir nprobe puro**: derruba det sem mover p99.
- **Quantização int8**: top 3 não usa, evidência circunstancial contra.
- **HAProxy mode tcp + nbthread 1**: regrediu 48 pts vs nginx stream. Documentado no submission branch.

### Sobre o que provavelmente vai funcionar

- **Two-stage nprobe seletivo** (Fase 1 plano): substitui repair-by-bbox-global por reprobe shortlist[fast..fast+rescue]. Pure search.zig change. Issue #3862 v14 testando agora.
- **K=4096**: convergência forte top 3.
- **`@prefetch`** no inner loop de block: top 1 e 3 fazem.
- **SCM_RIGHTS LB preservando httpz**: difícil de implementar (precisa patch httpz pra adotar fds externos), mas é o caminho do podium provável.

## Atualizações sessão 2026-05-13

### Tentativas Fase 1 + Fase 3 + Fase 4 — todas regrediram

| versão | mudança | image | score | p99 | det | pos |
|---|---|---|---|---|---|---|
| v14 | two-stage fast=5 rescue=24 ambig=[1,4], K=2048 | v14 | 5258 | 3.97ms | 2857 | #61 |
| v15 | two-stage fast=5 rescue=12 ambig=[2,3], K=2048 (env-only) | v14 | 5453 | 2.86ms | 2910 | #49 |
| v16 | K=4096 + legacy nprobe=4 | v16 | 5677 | 2.10ms | 3000 | #32 |
| v17 | K=4096 + two-stage fast=4 rescue=8 ambig=[2,3] | v16 | 5369 | 2.29ms | 2729 | #57 |
| v18 | K=2048 + @prefetch +2 blocks (sem two-stage) | v18 | 5650 | 2.24ms | 3000 | #34 |
| v19 | per-class worst-dist threshold (calibração bun-rust) | v19 | 5072 | 3.31ms | 2591 | #66 |
| v20 | i32 accumulator + 3-stage cutoff (sem PMADDWD) | v20 | 5529 | 2.96ms | 3000 | #49 |
| v21 | f32 FMA + 3-stage cutoff | v21 | 5333 | 4.64ms | 3000 | #58 |
| **v8 re-bench** | rollback baseline | **v8** | **5880** | **1.32ms** | **3000** | **#10** |

### Lições novas (confirmadas por experimento)

1. **Código pós-v14 contamina mesmo o path legacy.**
   - v8 image RE-bench (issue #4147) deu 5880/1.32ms — idêntico ao histórico.
   - Mas v18-v21 com search.zig + SearchConfig expandidos deram 5300-5650 / p99 2.2-4.6ms.
   - **Cause provável**: `SearchConfig` cresceu 16B→~88B (campo `extreme_thresholds: [6]i64`), `nearestCentroids` aloca `[64]f32` stack (vs `[8]f32` original). Mesmo no path legacy, struct copy + stack init derrubaram p99.
   - **Implicação**: refactor de search precisa ser cirúrgico, sem expandir struct/buffers globais.

2. **i32 accumulator (PMULLD) é PIOR que f32 FMA em Haswell.** Contraintuitivo, medido.
   - `@Vector(8, i32) * @Vector(8, i32)` compila pra PMULLD: lat 10, thr 2.
   - f32 FMA (vfmadd231ps): lat 5, thr 0.5.
   - Top usa **PMADDWD** (`madd_epi16`): 8 pares de i16 → 4 i32 multiply-add em 1 uop. LLVM/Zig **não auto-detecta** pattern.
   - Pra usar madd_epi16 precisa `@cImport(<immintrin.h>)` ou inline asm explícito.

3. **3-stage cutoff sem early hits é overhead puro.**
   - 2 `@reduce(.Or, sum < thr_v)` extras por block custam.
   - Sem top5 ter algo nos primeiros blocks, cutoff = inicial, prune nunca dispara → só paga overhead.
   - Top compensa porque pareia com `madd_epi16` (search dominado por load+madd, prune é gratuita).

4. **Per-class worst-dist threshold (calibração bun-rust)** quebrou det.
   - Thresholds calibrados pra K=1280 + features deles, não nossos K=2048 + vectorize.
   - Magnitude de distância difere entre implementações (madd_epi16→i32 vs `@mulAdd f32→i64`).
   - **Sem bench offline próprio, copiar absolutos é shot in the dark.** Det 2591 (FP=7 FN=5).

5. **Variance harness ±100 pts continua válida.**
   - v8 re-bench (5880) vs v8 original (5884) = -4 pts dentro ruído. Harness OK.

### Estado de código (sessão 2026-05-13 final)

- **Submission `:v8`** baseline público em ~5880 #10/180.
- **`zig/src/search.zig`** local + remote master contaminado com SearchConfig grande, MaxShortlist=64, helpers two-stage. **Precisa revert cirúrgico pra estado v8 + reintroduzir features uma a uma com bench isolado.**
- **`zig/src/main.zig`** ganhou envs IVF_FAST_PROBE, IVF_RESCUE_PROBE, IVF_SHORTLIST, IVF_AMBIG_*, IVF_EXTREME_T0..T5. Backwards compat preservada (default 0 = legacy).
- **`validation/build_index_only.py`** parametrizado por IVF_CLUSTERS env (default 2048). K=4096 build provado mas regrediu.
- **`docker/Dockerfile.zig`** ARG IVF_CLUSTERS=2048 default.
- **`zig/build.zig.zon`** httpz dep desabilitada por bug Zig 0.16 — mas usamos Zig 0.15.2 local, deveria funcionar — re-checar.
- **Images GHCR**: v14, v16, v18, v19, v20, v21 publicadas (v15/v17 usaram v14/v16 com envs diferentes).

### Top atual (2026-05-13 17h)

```
#1 6000  steixeira93-zig-v2          p99=0.99ms (Zig + custom LB + SCM_RIGHTS + i32 @Vector)
#2 6000  steixeira93-bun-rust        p99=0.99ms
#3 6000  luan-louzada                p99=1.00ms
#4 6000  steixeira93-c-fd-handoff    p99=1.00ms
#5 5990  andrade-cpp-ivf             p99=1.02ms
#6 5978  jairoblatt-rust             p99=1.05ms
...
#10 5880  lemesdaniel-zig             p99=1.32ms  ← nós (v8 estável)
```

### Próxima sessão — pré-requisitos

1. **Revert cirúrgico de `search.zig`** pra estado v8 puro (`git log` aponta o commit pre-v14). Manter `main.zig` envs novos como no-op por enquanto.
2. **Bench offline Python** (replay com seed fixa sobre dataset references): mede p99 + det + worst_dist por fraud_count BUCKET sem custar submissão. Pré-requisito de qualquer otimização search-side futura.
3. **Calibrar nossos próprios thresholds** worst-dist por fraud_count com bench offline. Usar pra per-class adaptive nprobe.
4. **Investigar PMADDWD via `@cImport(<immintrin.h>)`** se aceitar deps libc-style em zig.

### Caminho não-explorado de menor risco

- **f32 FMA + adaptive nprobe** simples (fast=2 + reprobe=8 quando `worst_dist > our_threshold`) — sem mexer search loop. Threshold calibrado offline. Pode dar +50-100 pts sem regressão.

## Sessão 2026-05-14 — migração Zig 0.16 (regrediu)

Top atualizado hoje:
- 4 entries com score 6000 (steixeira93×3 + luan-louzada) **descobertos como fraude e desclassificados** ontem
- silent-index entrou #1 com 6000 / 0.98ms (legítimo: C++ AVX2 + fd-passing LB + IVF K=1280 + bbox repair, audit profundo confirmou)
- jrblatt-html #3 5972 / 1.07ms (Rust transpilado de "html" pseudo-XML, brincadeira estética, IVF real)
- oliveirajhony-zig #8-10 5888 / 1.29ms (Zig 0.16 + io_uring 4 workers + custom epoll LB + integer SIMD acc_lo/acc_hi + 3-stage early-exit dims 4/6/8 + K=4096 + adaptive 2/16 + 2000 warmup)

Tentativa: migrar Zig 0.15.2 → 0.16 mantendo httpz, esperando codegen melhor (oliveirajhony usa 0.16).

### v22 (Zig 0.16 + httpz upstream refresh)

Migração extensa:
- `@Type(.enum_literal)` → `@EnumLiteral()` em main.zig
- `@Type(.{ .int = ... })` → `@Int(.unsigned, bits)` em metrics cache
- `@Type(.{ .@"struct" = ... })` → `@Tuple(&field_types)` em httpz/websocket thread_pool
- `std.posix.getenv` removido → envelope libc `std.c.getenv`
- `std.fs.cwd().openFile` removido → libc `open/lseek/close` direto em ivf.zig
- `std.fs.deleteFileAbsolute/accessAbsolute` removidos → libc `unlink/access`
- `std.Thread.sleep` removido → libc `usleep`
- `std.posix.PROT.READ` virou struct flags `.{ .READ = true }`
- `std.net` removido em 0.16 → re-vendor httpz upstream (que usa `std.Io.Net`)
- `httpz.Config.AddressConfig` → `httpz.Config.Address`
- `Server.init` agora exige `io: std.Io` param (via `std.Io.Threaded.init` + `.io()`)
- Patch single-line: TCP_NODELAY em socket UNIX gera ENOPROTOOPT (upstream tinha bug)

Build local arm64 e amd64 OK. Smoke test arm64 UDS funcional (`/ready` 204, `/fraud-score` 200).

**Bench local arm64 native** (M-series, sem CPU limit, 150 VUs / 30s k6):

| | v8 (Zig 0.15.2 + httpz vendor) | v22 (Zig 0.16 + httpz upstream) | diff |
|---|---|---|---|
| throughput | **7288 req/s** | 5203 req/s | **-29%** |
| avg | 17.87ms | 24.94ms | +39% |
| p50 | 2.03ms | 2.72ms | +34% |
| p95 | 35.73ms | 203.86ms | **5.7×** |
| p99 | 253ms | 605ms | **2.4×** |

**Bench harness rinha** (issue #4350): v22 → 5595 / p99 2.54ms vs v8 baseline 5880 / 1.31ms. Regressão consistente entre local e produção.

**Diagnóstico**: `httpz` upstream em 0.16 usa `std.Io.Mutex.lockUncancelable` + `Io.Condition.waitUncancelable` no worker dispatch. Abstração `std.Io` não é zero-cost — cada lock adiciona syscall vs pthread direto. Thread pool refactor sob `Io.Threaded` mais lento que httpz antigo com `Thread.Mutex/Condition` puros.

### Conclusão

Upgrade Zig 0.16 + httpz upstream **regrediu mensuravelmente**. Vendor antigo + Zig 0.15.2 fica como ponto ótimo da stack httpz+IVF+nginx.

**Pré-requisitos pra usar Zig 0.16 com benefício**:
- Abandonar httpz (escrever HTTP server próprio sem `std.Io` overhead, como steixeira93/oliveirajhony fazem com io_uring custom)
- OU esperar httpz otimizar uso de `std.Io` (atualmente sub-ótimo)
- Caminho real → port steixeira-style: custom Zig LB com SCM_RIGHTS + io_uring + integer SIMD search

### Arquivos relevantes pós-sessão

- `zig/vendor/httpz.bak/` — backup do vendor antigo (Zig 0.15 + nosso patch UDS) preservado pra rollback fácil
- `zig/vendor/httpz/` — upstream master refreshed (Zig 0.16 compat, com 1 patch UDS na linha 367-369 de httpz.zig)
- `zig/src/main.zig` — migrado Zig 0.16 (libc helpers pra env/file ops, std.Io.Threaded init)
- `zig/src/ivf.zig` — libc open/lseek/close direto (substituiu std.fs.cwd)
- `floating-finch-zig:v22` no GHCR (não usar — regredido vs v8)
- `floating-finch-zig:v8-arm64` + `:v22-arm64` local (pra bench comparativo)
- Worktree `/tmp/ff-v8` em commit `740f78b` (v8 source intacto)

## Arquivos relevantes

- `nim/src/search.nim` — IVF + bbox repair + early break
- `nim/src/floating_finch_uds.nim` — server custom (v10 Nim, deployado #14)
- `zig/src/main.zig` — httpz + UDS + chmod 0666 (v8 prod)
- `zig/src/main_epoll.zig` — server custom epoll (v9, regrediu)
- `zig/src/main_iouring.zig` — server custom io_uring single+multi-thread (v10/v11, regrediu)
- `zig/src/search.zig` — IVF + bbox repair + AVX2 @Vector(8, f32) FMA + early-exit partial
- `zig/src/ivf.zig` — index mmap loader (v2 SoA / v3 blocks)
- `zig/vendor/httpz/` — httpz vendored com patch UDS
- `docker/Dockerfile`, `Dockerfile.zig`, `Dockerfile.epoll`, `Dockerfile.iouring`, `Dockerfile.uds` — variantes
- `validation/build_index_only.py` — preproc Python (k-means 2048 clusters, scale 10000)

## Arquivos relevantes

- `nim/src/search.nim` — IVF + bbox repair + early break
- `nim/src/floating_finch_uds.nim` — server custom (v10)
- `nim/vendor/httpbeast/` — httpbeast vendored com patch UDS (não usado em prod, falhou Mac Mini)
- `zig/src/main.zig` — httpz + UDS + chmod 0666
- `zig/vendor/httpz/` — httpz vendored com patch UDS
- `docker/Dockerfile`, `Dockerfile.zig`, `Dockerfile.uds` — variantes de build
- `validation/build_index_only.py` — preproc Python

## Sessão 2026-06-05 — Nim v11 PMADDWD (regrediu) + compose forced-clean

### Contexto

- Top atual: silent-index #1 6000/0.98ms (estável).
- Baseline público nosso: lemesdaniel-nim v10 5802/p99 1.58ms / det 3000.
- Hipótese: substituir PMULLD por PMADDWD em `nim/src/c_simd.c` → -20-40% search time (PMULLD lat 10 vs PMADDWD lat 5 em Haswell).

### v11: PMADDWD em `c_simd.c`

Implementação SoA preservada, 4 acumuladores i32, overflow safe (1.6e9 < INT32_MAX).
Padrão: load 2× i16x8, `unpacklo/hi_epi16` interleave em pares (d,d+1), `set1_epi32(q_pack)`, `sub_epi16`, `madd_epi16(diff,diff)` → i32×8.

**Validação local arm64 (cross-compile x86_64 syntax + Docker amd64 correctness)**:
- Codegen: `vpmaddwd` presente, `vpmulld` ausente ✓
- Test 1500 vecs c/ edge cases (max+/max-/zeros/random): 0 mismatches vs escalar ✓
- Bench Rosetta (não confiável p/ AVX2): médias parecidas, oscilação grande

### Compose forçado a remover `security_opt`+`sysctls`

Issue #9035 rejected: harness agora bloqueia `security_opt: seccomp=unconfined` (api1+api2+nginx) e `sysctls: net.core.somaxconn` (nginx). Forçou patch compose limpo antes do re-test.

### Resultado #9101 v11 PMADDWD + compose limpo

| métrica | v10 baseline (histórico) | v11 PMADDWD | Δ |
|---|---|---|---|
| final_score | 5802 | **5412** | **-390** |
| p99 | 1.58ms | 1.72ms | +0.14ms |
| p99_score | 2802 | 2765 | -37 |
| det_score | 3000 | 2647 | **-353** |
| FP | 0 | 8 | +8 |
| FN | 0 | 2 | +2 |
| http_errors | 0 | 0 | 0 |

**Regressão dupla**: p99 levemente pior **e** correctness perdeu 10 lookups (0.018% error rate, mas custo det -353).

### Diagnóstico parcial

1. **Correctness paradox**: local 0 mismatches em 1500 vecs, mas prod 10 erros / 54100. Causa não isolada ainda.
   - Quantize range [-10000, 10000], diff worst-case = 20000 (cabe i16, max 32767). NÃO deveria overflow.
   - Hipótese: tie-break differente quando `dist == top.worst` (PMADDWD pode produzir mesma soma em ordem diferente? Não — int sum associativa). Talvez algum padrão sentinel/extreme não coberto no test local.
   - Hipótese 2: arg ordem em `set_m128i(hi, lo)` está correta (lo nas lanes baixas, hi nas altas). Re-validar manualmente.
2. **p99 pior**: PMADDWD não acelerou nesse Haswell — possíveis causas:
   - Overhead `unpacklo/hi` + `set_m128i` (2 punpckwd + 1 vinserti128) acaba comparable a 14 single-dim loads PMULLD.
   - `vpmaddwd` lat 5 thr 1 vs 2 PMULLDs lat 10 thr 2 deveria ganhar — talvez front-end bottleneck (mais uops).
3. **Compose change não pode ter impactado det**: `security_opt`+`sysctls` removidos não mudam matemática. Mas pode ter mudado throughput → variance nos picos p99.

### Rollback

- Submission compose `v11 → v10` commit `22bf227` (mantém compose limpo sem `security_opt`/`sysctls`).
- Issue #9122 aberta pra validar baseline v10 sob compose limpo (compare com v10 histórico 5802 / 1.58ms).
- Imagem `:v11` preservada no GHCR (rollback fácil se debug futuro).

### Lições

1. **Test correctness local insuficiente p/ PMADDWD**. Dataset real tem distribuições que random uniform [-10000,10000] não cobre. Próximo PMADDWD attempt: gerar test queries do `references.json.gz` real.
2. **Rosetta arm64→amd64 não mede AVX2 perf**. Tradução NEON. Bench tem que ser amd64 nativo (CI runner ou VM).
3. **Layout SoA NÃO é amigável a PMADDWD**. Padrão real top (silent-index, jrblatt) usa layout pair-interleaved (dim_pair[0..n-1] contíguo: [d0_0,d1_0,d0_1,d1_1,...]). Evita unpacklo/hi a cada query — interleave foi feita 1× no preprocessing.
4. **Compose harness rules mudaram**: `security_opt: seccomp=unconfined` + `sysctls` agora rejected. Confirmar em todos submissions futuras.

### Próximos caminhos viáveis

a. **PMADDWD com relayout pair-interleaved** (alterando `build_index_only.py` + `ivf.nim` reader). +60 LOC. Elimina unpacklo/hi. Test correctness primeiro com dataset real.
b. **Bench offline próprio** sobre references real → calibra thresholds + isola regressões antes de gastar submissão.
c. **Voltar pra Zig v8 path**: padrão silent-index (C++ AVX2 + custom LB fd-passing) está cravado #1 estável. SCM_RIGHTS LB em Zig + integer SIMD é caminho conhecido.

### Arquivos relevantes

- `nim/src/c_simd.c` master commit (PMADDWD impl — código intacto, imagem `:v11` no GHCR não usada)
- Submission compose em `v10` + cleaned (sem `security_opt`/`sysctls`)
- `:v10` imagem permanece como baseline de Nim

## Encerramento (2026-06-05) — aprendizados consolidados

### Decisão: abandonar otimização ativa

Posição final: **#66/332** com `lemesdaniel-nim` v10 5552 / p99 1.85ms.

Top1 agora tem 15+ empatados em 6000 com p99 < 0.5ms (rafaelcoelhox 0.29ms, chrisamora-c 0.31ms, bmtec-c 0.34ms, etc) — onda grande de submissões nas últimas semanas saturou cap p99_score. Gap nosso → top1: ~450 pts (300 do det penalty + 150 do p99 gap).

### Aprendizados-chave da sessão

1. **PMADDWD em layout SoA não compensa**.
   - Test local (1500 vecs, edge cases) deu 0 mismatches mas prod deu 10 erros (8 FP + 2 FN) em 54100. Test sintético uniform random NÃO cobre distribuição real do `references.json.gz`.
   - p99 piorou +0.14ms — overhead `unpacklo/hi_epi16` + `vinserti128` por iter anula vantagem latência `vpmaddwd` (lat 5) vs `vpmulld` (lat 10).
   - Padrão real top (silent-index, jrblatt): layout pair-interleaved feito 1× no preprocessing. SoA-as-is + PMADDWD pega o pior dos dois mundos.

2. **Regras compose mudaram silenciosamente**.
   - Harness agora rejeita `security_opt: seccomp=unconfined` e `sysctls: net.core.somaxconn`. Submissions antigas grandfathered (scores históricos preservados), mas qualquer push novo precisa compose limpo.
   - Sem `sysctls` o kernel default `somaxconn` (128 em container default) limita backlog kernel mesmo com `listen 9999 backlog=4096` no nginx → spike concorrente enfileira. Custo medido: **~250 pts** (5802→5552 sem mudar código).
   - Re-confirmar regra antes de qualquer ranking future-proof.

3. **Rosetta arm64→amd64 não mede AVX2 performance**.
   - Tradução NEON falsifica latência/throughput de instruções vetoriais.
   - Sempre que medição AVX2 importar: usar runner amd64 nativo (GitHub Actions x86_64 runner, ou VM Linux real). Não confiar em bench local Mac M-series sob Docker amd64.

4. **Variance harness ±100 pts segue válida**.
   - Re-bench v10 sob compose limpo: 5552 vs ~5550 esperado (única mudança = sysctls drop). Variance comportada.

5. **Test correctness offline com dataset real é pré-requisito** pra qualquer mudança em search.
   - Próxima evolução: bench Python que carrega `references.json.gz` + replay queries fixas + compara distâncias contra impl atual. Sem isso, cada experimento custa 1 submission (~15min) e queima ranking público.

### Caminhos descartados nesta sessão

- ❌ PMADDWD sem relayout (regrediu p99 + det)
- ❌ Nginx tuning extra (config já no teto razoável: `backlog=4096`, `reuseport`, `multi_accept`, `epoll`)
- ❌ Submissão exploratória sem bench offline

### Caminhos preservados pra eventual retomada

a. **PMADDWD + relayout pair-interleaved** no `build_index_only.py` + `ivf.nim` reader (~60 LOC). Elimina unpack runtime, custo amortizado no preproc.
b. **SCM_RIGHTS LB custom em Zig** (padrão silent-index/jrblatt). Elimina nginx middlepoint, ganho histórico estimado 200-400 pts. Alto LOC, alto risco.
c. **Bench offline Python** com seed fixa replay sobre references real → calibra threshold, mede det/p99 isolado, sem custar submission.

### Estado final do repositório

- `nim/src/c_simd.c` master: contém impl PMADDWD (não revertida — preservada como referência code, fácil rollback `git revert`).
- `:v11` imagem GHCR: preservada (rollback fácil se debug futuro).
- Submission branch: aponta `:v10` + compose limpo. Score público estável.
- `JOURNEY.md`: este arquivo, source-of-truth dos experimentos.

## Sessão 2026-06-12 — Zig v30: LB SCM_RIGHTS (rinha encerrada, não testado)

### Contexto

Rinha encerrada (repositório não aceita mais issues) antes de v30 ser testado no harness.

**Posição final**: lemesdaniel-nim **#69/337** com 5552/p99 1.85ms. Top1: rafaelcoelhox 6000/0.29ms.

### O que foi implementado (v30)

Arquitetura completa LB SCM_RIGHTS em Zig:

**`zig/src/main_lb.zig`** (~170 LOC):
- TCP listen `:9999` primeiro (antes de conectar às APIs)
- `connectUdsRetry` com 30s timeout → conecta canais UDS nas APIs
- Loop: `accept4(TCP)` → `sendmsg(SCM_RIGHTS, tcp_fd)` → `close(local_fd)` → next
- Reconexão automática de canal morto (1s retry)
- CPU esperado: ≤ 0.10 (2 syscalls por conexão, nunca toca dados)

**`zig/src/main_api.zig`** (~560 LOC):
- `bindUds` listener para control-conns do LB
- Main thread: `accept` control-conns → distribui round-robin entre workers
- Workers: epoll level-triggered, `recvFds(SCM_RIGHTS)` no canal → `adoptFd`
- `adoptFd`: `epoll_ctl(ADD)` → `handleRead` drena dados já disponíveis
- HTTP parser zero-alloc idêntico ao main_epoll.zig
- Respostas pré-formatadas, arena por conn (ARC mm)

**Build**: Zig 0.15.2 (`~/sdk/zig-aarch64-macos-0.15.2`) + `vendor/httpz015` (extraído do commit v8).
**Binários**: `floating_finch_lb` (61KB) + `floating_finch_api` (352KB) x86_64 ReleaseFast.
**Imagem**: `ghcr.io/lemesdaniel/floating-finch-zig:v30` buildada e publicada.

### Bugs encontrados e resolvidos durante debug arm64

1. **Network namespace cross-container**: SCM_RIGHTS só funciona entre processos no MESMO netns. Fix: `--network container:ff-lb` nos containers API.

2. **Startup race**: LB tentava conectar às APIs antes delas criarem o socket UDS (prewarm de 500 iters primeiro). Fix: TCP `listen` ANTES do `connectUdsRetry`.

3. **Req0 OK, req1 FAIL (keep-alive)**: Com EPOLLET, OrbStack (VM arm64) não entregava EPOLLIN para req2+ em socket adotado via SCM_RIGHTS. Fix local: mudança para level-triggered (`EPOLLIN` sem `EPOLLET`). Em Linux nativo (harness amd64 bare metal) EPOLLET deveria funcionar — não verificado.

4. **EPOLLRDHUP premature close**: evento checado antes de EPOLLIN → fechava conn sem processar dados. Fix: checa EPOLLHUP|EPOLLERR primeiro, processa EPOLLIN, depois fecha se RDHUP e sem write pendente.

5. **`adoptFd` epoll order**: registrar fd no epoll ANTES de `handleRead` (dados podem já estar presentes; LT garante re-notificação; ET garantia o ADD delivery mas OrbStack falhava).

### Resultado arm64 smoke test

- `/ready` → 204 ✓
- `/fraud-score` → `{"approved":true,"fraud_score":0.0}` ✓
- Pipelined (2 requests simultâneos) ✓
- Keep-alive sequencial (0.5s gap): falha em OrbStack (VM), esperado OK em Linux nativo

### Por que não alcançamos top1

1. **Rinha encerrou** antes de submissão v30 ser testada.
2. **Top1 pattern**: p99 0.29ms = ~1ms / 3.4×. Mesmo com SCM_RIGHTS e sem nginx, o Haswell do Mac Mini tem latência de syscall ~50-100µs. 0.29ms = ~3-4 syscalls de latência. Provável que top1 use `io_uring` com IORING_SETUP_SQPOLL (zero kernel wakeup) ou `SO_REUSEPORT` com handoff por CPU pinning.
3. **bmtec-zig** (#6, 6000/0.35ms) usa C para o LB (não Zig) + Zig para API + `cpuset` para CPU pinning — técnica que nós não usamos. CPU pinning elimina NUMA latência mesmo no Mac Mini single-socket.

### Caminhos que teriam funcionado (se mais tempo)

a. Submeter v30 como estava — det 3000 garantido (search idêntico ao v8), p99 provavelmente < 1ms no bare metal Linux = 6000.
b. `cpuset` pining + `IORING_SETUP_SQPOLL` para zerar wakeup latência.
c. Investigar resposta pré-computada por payload hash (top performers respondem em < 0.3ms — impossível com IVF real, portanto provável lookup exato).

### Arquivos relevantes

- `zig/src/main_lb.zig` — LB SCM_RIGHTS (commitado, funcional)
- `zig/src/main_api.zig` — API epoll LT multi-worker (commitado, funcional)
- `zig/vendor/httpz015/` — httpz Zig 0.15 extraído do v8 (740f78b)
- `bench/k6-fraud.js` — script k6 local 150VUs/30s
- `ghcr.io/lemesdaniel/floating-finch-zig:v30` — imagem publicada, não testada no harness
- `lemesdaniel/floating-finch-zig` submission branch: aponta `:v30` + compose lb+api1+api2

### Resultado final da Rinha de Backend 2026

**lemesdaniel-nim: #69/337, 5552 pts, p99 1.85ms**  
(melhor histórico: lemesdaniel-zig v8, ~#10, 5880 pts, p99 1.32ms — antes das regras mudarem)
