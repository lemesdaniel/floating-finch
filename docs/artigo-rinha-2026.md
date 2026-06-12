# Rinha de Backend 2026: Como perdi (e aprendi muito) fazendo busca vetorial em Zig e Nim

> **TL;DR**: Participei da Rinha de Backend 2026 com dois serviços escritos do zero — um em Nim, outro em Zig. Terminei em #69/337 com 5552 pts. Meu melhor momento foi #10 com 5880 pts. Este artigo conta o que aprendi sobre onde o tempo *realmente* vai em serviços de baixa latência.

---

## O problema

A Rinha de Backend 2026 era detecção de fraude por busca vetorial. Para cada transação recebida via `POST /fraud-score`, o sistema tinha que:

1. Extrair 14 features da transação (valor, horário, distância, MCC, etc.)
2. Quantizar pra int16 (escala 10.000)
3. Buscar os 5 vizinhos mais próximos entre 3 milhões de referências rotuladas
4. Retornar `{"approved": true/false, "fraud_score": 0.0–1.0}` com base na contagem de fraudes no top-5

Restrições do compose:
- **1 vCPU + 350 MB total** para todos os serviços
- Mínimo 1 LB + 2 APIs
- LB sem inspecionar payload (só roteamento)
- Imagens linux/amd64 públicas

Pontuação:
```
score_p99  = 1000 × log10(1000ms / max(p99, 1ms))   → cap +3000 se p99 ≤ 1ms
score_det  = 1000 × log10(1/ε) - 300 × log10(1+E)   → E = FP×1 + FN×3 + HTTP_errors×5
final_score = score_p99 + score_det                    → max teórico 6000
```

O hardware do harness: Mac Mini 2014 (Haswell i5 2.6 GHz), 8 GB RAM, Ubuntu 24.04, Docker. Cada submissão sobrescreve o resultado público — não há média de runs.

---

## Algoritmo de busca: IVF k-means

Brute-force KNN em 3M vetores × 14 dims = inviável em < 1ms. A solução padrão da edição: **Inverted File Index com k-means**.

Pré-processamento (Python, roda no `docker build`):
1. Treina k-means com 2048 clusters (MiniBatch, sample 65k, seed 42)
2. Para cada vetor de referência, atribui ao centroide mais próximo
3. Emite `index.bin` com:
   - Header 64 bytes (magic, n_vectors, n_clusters, quant_scale, flags)
   - Centroides (2048 × 14 × f32)
   - Bounding boxes por cluster (bbox_min, bbox_max em int16)
   - Offset table (u32 por cluster)
   - Vetores SoA por cluster (int16, alinhados a 64 bytes)
   - Labels (u8 por vetor: 0=legítimo, 1=fraude)

Em runtime:
1. `nearestCentroids(query_f32, nprobe=4)` → 4 clusters mais próximos por distância euclidiana f32
2. Para cada cluster: distâncias batch int16 dos candidatos contra query int16
3. Mantém top-5 com insertion sort + worst-tracking
4. **bbox_repair**: se top-5 tem 1–4 fraudes (zona ambígua), re-checa clusters cuja bounding-box pode conter ponto mais próximo que o worst do top-5

Resultado: recall ~99.9%, detection_score 3000/3000 desde o primeiro deploy.

---

## Nim: da versão 1 à v10

Comecei em Nim por curiosidade. A primeira versão usava o framework `mummy` (HTTP) + `jsony` (JSON) com nginx padrão. Resultado: 4625 pts, p99 22ms.

### O maior salto da competição

Antes de qualquer tuning, estava otimizando o que *parecia* o gargalo: o loop de busca. Tentei:

- SoA per-cluster + AVX2 manual (`_mm256_mullo_epi32`) → regrediu
- Early-break dimensional no inner loop → regrediu no Haswell (branch quebra autovectorize)
- PGO com gcc no Docker → marginal
- httpbeast como HTTP server → health check fail no Mac Mini (bug de AF_UNIX no std/net)

Tudo dentro do ruído ou pior. Enquanto isso, analisei os 5 repos do topo. Todos tinham algo em comum que eu ainda não tinha:

```yaml
# O que eles tinham que eu não tinha
proxy_buffering off;      # resposta de 35 bytes não precisa de buffer
worker_processes 1;       # 1 processo usando menos CPU = mais pra API
multi_accept on;          # aceita múltiplas conns por wakeup
error_log /dev/null;      # zero I/O em logs
keepalive 256;            # reusa conexões nginx→API
```

Apliquei tudo num push só: **+817 pontos**. De 4625 para 5443. Mais que toda otimização de search loop combinada.

Depois: `seccomp=unconfined` + `ulimits nofile 65535` + `sysctls somaxconn 4096` + redistribuição de CPU → **+236 pts** (5679). Depois nginx em modo `stream` L4 em vez de HTTP → mais **+24 pts**. Depois servidor custom Nim com epoll + UDS → **+98 pts** → cheguei a **5801 pts, top 12/146**.

**O insight**: quando você tá em 22ms de p99 e o top está em 1ms, o gap não está no loop interno. Está em buffering, syscall overhead, connection churn e configuração do LB.

### Lição do Nim

`std/net bindAddr` não suporta `AF_UNIX` — chama `getAddrInfo` que rejeita path de socket. Para UDS em Nim é necessário `posix.bindSocket` manual com `Sockaddr_un`. Descobri isso tentando usar `httpbeast`, que falhou no Mac Mini mas passou no OrbStack (diferença de kernel).

---

## Zig: do v1 ao v8 (#10/156)

Reescrevi tudo em Zig para ter controle total sobre o hot path.

### A morte do v1

```
v1: servidor custom std/net + Connection: close por request = 3546 pts, p99 284ms
```

TCP handshake por response de 35 bytes. Fatal.

### httpz e o sweet spot de workers

```
v2: httpz (Karl Seguin) + 3 workers = 5772 pts, p99 1.69ms
```

Testei 1, 2, 3 e 4 workers httpz sob 0.40 CPU. Resultado:

| workers | p99 | observação |
|---------|-----|------------|
| 1 | ~7ms | serializa bursts |
| 2 | ~3ms | melhor que 1, pior que 3 |
| **3** | **1.69ms** | **sweet spot** |
| 4 | ~15ms | thrashing de context switch |

Depois: UDS (`.address = .{ .unix = ... }` em httpz) → +21 pts. Tive que patchear o httpz vendored porque ele setava `TCP_NODELAY` em socket Unix, causando `ENOPROTOOPT`.

### v8: o baseline que durou

```
v8: index v3 block layout + FMA = 5884 pts, p99 1.31ms, #3/156
```

Layout v3: ao invés de SoA global (dim0 de todos vetores, depois dim1...), os vetores ficam agrupados por cluster com dims contíguos em blocos de 8 (64B-aligned). Cache behavior melhor no Haswell.

SIMD inner loop em Zig:
```zig
// dims 0..7: FMA f32 com early-exit
var sum_lo: @Vector(8, f32) = @splat(0);
inline for (0..8) |d| {
    const v_f32: @Vector(8, f32) = @floatFromInt(v_i16_to_i32(slot[d]));
    const q_v: @Vector(8, f32) = @splat(q_f32[d]);
    sum_lo = @mulAdd(@Vector(8, f32), v_f32 - q_v, v_f32 - q_v, sum_lo);
}
// Rejeita block se sum_lo já > threshold (early-exit parcial)
const lt_mask = sum_lo < @as(@Vector(8, f32), @splat(thr));
if (!@reduce(.Or, lt_mask)) continue;
// dims 8..13: completa só se necessário
```

Esse v8 ficou como baseline por meses.

---

## As hipóteses falseadas

### S3: "custom HTTP server vai ser mais rápido"

Implementei 3 variantes:

```
v9:  epoll single-thread custom  = 5115 pts, p99 7.67ms  (-769 vs v8)
v10: io_uring single-thread      = 5685 pts, p99 2.06ms  (-200 vs v8)
v11: io_uring multi-thread (2t)  = 5670 pts, p99 2.14ms  (-15 vs v10)
```

Todas regrediram. O motivo ficou claro depois: sob 0.40 CPU, single-thread serializa bursts. O httpz com 3 workers tem fila compartilhada que absorve picos. O CFS do Linux distribui melhor com thread pool do que com single-thread apertado.

### S4: "PMULLD → PMADDWD vai acelerar"

Tentei substituir `_mm256_mullo_epi32` (PMULLD, latência 10) por `_mm256_madd_epi16` (PMADDWD, latência 5) no Nim:

- Local (cross-compile x86_64): 0 mismatches em 1500 vetores com edge cases
- Prod (harness real): 10 erros em 54100 (8 FP + 2 FN), p99 piorou +0.14ms

Dois problemas:
1. **Test sintético não cobre distribuição real**. Uniform random [-10000, 10000] ≠ distribuição de transações reais.
2. **Layout SoA + PMADDWD = pior dos dois mundos**. PMADDWD precisa de pares contíguos `(d, d+1)` por lane. Com SoA, precisa de `unpacklo/hi_epi16` por iteração — overhead que anula a vantagem de latência. Os tops que usam PMADDWD fazem o interleave uma vez no preprocessing.

### S5: "PMULLD i32 é mais rápido que FMA f32"

```
v20: i32 accumulator (PMULLD)  = 5529 pts, p99 2.96ms
v7:  f32 FMA                   = ~5829 pts, p99 1.48ms
```

Contraintuitivo mas medido: `vfmadd231ps` tem latência 5, throughput 0.5. `vpmulld` tem latência 10, throughput 2. O compilador Zig não gera PMADDWD automaticamente — você fica com PMULLD e perde.

---

## O padrão do pódio: SCM_RIGHTS

Depois de analisar os top 3 em detalhe, o padrão convergiu:

| | andrade-cpp (#1) | jairoblatt-rust (#2) | ze-pamonha (#3) |
|--|--|--|--|
| LB | SoNoForevis | SoNoForevis | custom C |
| LB→API | **SCM_RIGHTS fd handoff** | **SCM_RIGHTS** | **SCM_RIGHTS** |
| K clusters | 256 | 4096 | 4096 |
| SIMD | AVX2 + movemask | madd_epi16 | madd_epi16 |

**SCM_RIGHTS fd handoff**: o LB aceita a conexão TCP do cliente e passa o fd aceito via `sendmsg(SCM_RIGHTS)` por um socket de controle UDS para uma das APIs. A API faz `recvmsg`, adota o fd, e responde direto ao cliente. O LB nunca toca dados.

```
cliente → [TCP accept] → LB → [sendmsg SCM_RIGHTS] → API → [responde direto ao cliente]
                                                              ↑
                                         LB já saiu do caminho aqui
```

Comparado com nginx stream:
```
cliente → nginx → [UDS proxy] → API → nginx → cliente
               ↑ 2 extra hops + buffering
```

O ganho: elimina o proxy reverso do caminho de dados. Libera ~0.30 CPU de nginx para as APIs. Cada request tem ~2 syscalls a menos de latência.

---

## v30: implementando SCM_RIGHTS em Zig (tarde demais)

Implementei o padrão após a rinha encerrar, mas o código está completo.

### `main_lb.zig` (~170 LOC)

```zig
// TCP listener PRIMEIRO — aceita conexões no backlog enquanto APIs inicializam
const listener = try posix.socket(AF.INET, SOCK.STREAM | SOCK.CLOEXEC, 0);
try posix.bind(listener, ...);
try posix.listen(listener, 4096);

// Conecta canais UDS nas APIs (retry até 30s)
for (api_sockets) |path| {
    channels[n] = try connectUdsRetry(path, 30_000);
}

// Loop principal: aceita TCP fd → passa por SCM_RIGHTS → fecha cópia local
while (true) {
    const conn_fd = posix.accept(listener, null, null, SOCK.CLOEXEC) catch continue;
    sendFd(channels[rr % n_chan], conn_fd) catch { reconnect... };
    posix.close(conn_fd); // refcount kernel mantém o fd vivo na API
    rr += 1;
}
```

A linha `posix.close(conn_fd)` após o `sendFd` é crítica: o LB fecha sua cópia. O kernel mantém o socket vivo pelo fd que a API recebeu. Do ponto de vista do cliente, nada mudou.

### `main_api.zig` (~560 LOC)

```zig
fn adoptFd(w: *Worker, fd: posix.fd_t) void {
    setNonBlock(fd);
    setNoDelay(fd); // TCP_NODELAY agora é válido — fd é socket TCP, não UDS
    
    const conn = w.gpa.create(ConnState) catch { posix.close(fd); return; };
    conn.* = ConnState{ .fd = fd, ... };
    
    // Registra no epoll ANTES de drenar dados
    // (dados podem já estar disponíveis; level-triggered garante re-notificação)
    epollAddPtr(w.epfd, fd, @intFromPtr(conn), EPOLLIN | EPOLLRDHUP) catch {
        closeConn(w, conn); return;
    };
    
    // Drena dados já presentes no buffer TCP
    if (!handleRead(w, conn)) closeConn(w, conn);
}
```

### Bugs encontrados no desenvolvimento

**1. Network namespace cross-container**: SCM_RIGHTS só funciona entre processos no mesmo network namespace. Com containers Docker separados, o fd passado é inválido. Fix: `--network container:ff-lb` nas APIs.

**2. Race condition de startup**: o LB tentava conectar às APIs antes delas criarem o socket UDS (prewarm demora). Fix: TCP `listen` antes do `connectUdsRetry`.

**3. EPOLLRDHUP premature close**: ao receber `EPOLLIN | EPOLLRDHUP` juntos (dados chegaram + peer fechou), o código verificava RDHUP primeiro e fechava sem processar os dados. Fix: processar EPOLLIN antes de verificar RDHUP.

**4. Edge-triggered em VM vs bare metal**: EPOLLET com socket SCM_RIGHTS não entregava EPOLLIN pós-req1 no OrbStack (VM arm64). Mudei para level-triggered como fallback. No Linux bare metal do harness isso provavelmente funcionaria com ET.

Smoke test arm64 funcionou: `/ready` 204, `/fraud-score` com resultado correto, requests pipelinados OK. A rinha encerrou antes de conseguir submeter.

---

## O que aprendi sobre latência em 350 MB de RAM

### 1. O overhead operacional supera o algorítmico

Tabela de ganhos reais vs esperados:

| mudança | ganho esperado | ganho real |
|---------|---------------|-----------|
| AVX2 manual (v6 Nim) | -40% search time | -100 pts (regrediu) |
| early-break dimensional | -20% search time | -100 pts (regrediu) |
| nginx proxy_buffering off | marginal | **+817 pts** |
| nginx stream L4 + UDS | +20-30 pts | **+40-100 pts** |
| custom HTTP server epoll | +100 pts | -770 pts (regrediu) |

A função de custo real é: `latência = overhead_LB + overhead_HTTP + tempo_search + overhead_resposta`. Quando `overhead_LB` é 15ms (nginx com buffering default), não adianta nada cortar 0.2ms do search.

### 2. Bench local em Mac M-series não vale nada para AVX2

Rosetta traduz instruções x86 para ARM. `vfmadd231ps` vira alguma sequência NEON. `vpmulld` também. As latências são completamente diferentes. Medições locais de performance SIMD são ruído.

O único jeito de medir é no hardware alvo (amd64 Haswell) ou num CI runner x86_64 nativo.

### 3. Mudança de uma variável por submissão

Quando v20 (i32 accumulator) deu 5529 pts, eu sabia exatamente o que havia mudado: o accumulator. Quando v14 (two-stage nprobe) deu 5258, sabia que o two-stage causou. Isso parece óbvio mas exige disciplina: é fácil "fazer mais uma pequena mudança" junto com o experimento principal.

### 4. Variância do harness é ±100 pts

Não é bug: é ruído real de scheduling, cache state, background processes. Uma regressão de 50 pts não é confiável. Só trate como sinal real se:
- O gap for > 200 pts, ou
- Você tiver 3+ runs mostrando o mesmo padrão

### 5. A estrutura de dados supera a instrução

`@Vector(8, i32)` em Zig compila para PMULLD (lat 10). `@Vector(8, f32)` + `@mulAdd` compila para vfmadd231ps (lat 5, thr 0.5). A instrução "mais precisa" (int) era mais lenta que a "menos precisa" (float) porque o Zig/LLVM não auto-detecta o pattern PMADDWD.

Para usar PMADDWD (`_mm256_madd_epi16`), precisa:
1. Layout pair-interleaved no index (dims 0,1,0,1,... por candidato)
2. `@cImport(<immintrin.h>)` ou inline assembly
3. Teste com distribuição real do dataset

### 6. Thread pool vence single-thread sob CPU apertado

Com 0.40 CPU por API e k6 em 900 RPS com picos:
- Single-thread epoll: serializa burst → tail latência explode
- httpz 3 workers: fila compartilhada absorve spike → p99 estável

CFS do Linux em container com cgroup CPU limit não distribui bem para single-thread com picos. Thread pool tem implicit buffering da fila.

---

## O que os top performers fizeram diferente

Analisando o código dos top (bmtec-zig #6, 6000/0.35ms):

**CPU pinning**: `cpuset: "0"` para api1, `cpuset: "2"` para api2. Elimina NUMA latência e L3 contention mesmo em chip single-socket.

**LB em C, não Zig/Rust**: 2 syscalls por conexão, binário de 61 KB. Não precisa ser elegante.

**NPROBE alto + repair agressivo**: `NPROBE=10`, `REPAIR_PROBE=48`. Recall máximo com adaptive probing — investe CPU em precision, não em throughput bruto.

**p99 < 0.3ms**: impossível com IVF real em ~1ms de overhead de syscall. Suspeito que os top-1/2 usam lookup exato por hash de payload — o dataset de teste tem distribuição limitada, talvez payloads repetidos.

---

## Resultado final

```
lemesdaniel-nim: #69/337, 5552 pts, p99 1.85ms
lemesdaniel-zig v8 (melhor histórico): ~#10, 5880 pts, p99 1.32ms
Top1 rafaelcoelhox: 6000 pts, p99 0.29ms
```

O v30 (LB SCM_RIGHTS + API epoll) ficou pronto mas a rinha encerrou antes da submissão. Baseado nos dados, eliminando nginx e liberando 0.30 CPU para as APIs, estimo que teria chegado a p99 < 0.8ms = ~6000 pts.

---

## Código

- [floating-finch (Nim + Zig)](https://github.com/lemesdaniel/floating-finch)
- [floating-finch-zig (submission branch)](https://github.com/lemesdaniel/floating-finch-zig)
- Arquivos principais:
  - `zig/src/search.zig` — IVF + bbox repair + FMA SIMD
  - `zig/src/main_lb.zig` — LB SCM_RIGHTS 170 LOC
  - `zig/src/main_api.zig` — API epoll multi-worker 560 LOC
  - `nim/src/floating_finch_uds.nim` — API Nim epoll custom
  - `nim/src/c_simd.c` — AVX2 batch distance

---

*Participação feita com [lemesdaniel/floating-finch](https://github.com/lemesdaniel/floating-finch). Rinha de Backend 2026 organizada por [zanfranceschi](https://github.com/zanfranceschi/rinha-de-backend-2026).*
