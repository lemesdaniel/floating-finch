## Busca IVF top-K=5 sobre o índice mmap'd.
##
## Pipeline:
##   1. Calcula distância do query (float32) a todos os centroides → escolhe nprobe.
##   2. Para cada vetor nos clusters selecionados, calcula distância int32
##      (acumulador int64 para evitar overflow) ao query int16.
##   3. Mantém top-5 com insertion sort.
##   4. (Opcional) bbox_repair: se 2-3 fraudes nos top-5, sonda clusters cuja
##      bounding-box pode ter vetor mais próximo que o atual top-5.
##   5. Retorna fraud_count.
##
## Sem rerank fp32 nessa v1 (ver INDEX_BIN_FORMAT.md). Recall esperado ~99.9%.

import std/math

import types
import ivf

{.compile: "c_simd.c".}

proc floating_finch_dists_soa_avx2(vec_soa: ptr int16, n: int32,
                                   q: ptr int16, dists_out: ptr int64)
                                   {.importc, cdecl.}

const MaxClusterBuf = 16384
  ## Buffer thread-local para distâncias batch de um cluster. n=3M / k=2048
  ## média ~1465; outliers de até ~10× ainda cabem com folga.

var distsBuf {.threadvar.}: array[MaxClusterBuf, int64]

type
  SearchConfig* = object
    nprobe*: int
    bboxRepair*: bool
    repairMin*: int    ## inclusive
    repairMax*: int    ## inclusive

  Top5* = object
    distances*: array[K, int64]
    labels*: array[K, uint8]
    worst*: int

const DefaultConfig* = SearchConfig(
  nprobe: 1, bboxRepair: true, repairMin: 2, repairMax: 3
)


proc initTop5*(): Top5 =
  for i in 0 ..< K:
    result.distances[i] = high(int64)
    result.labels[i] = 0
  result.worst = 0


proc refreshWorst(top: var Top5) {.inline.} =
  var worst = 0
  for i in 1 ..< K:
    if top.distances[i] > top.distances[worst]:
      worst = i
  top.worst = worst


proc tryInsert(top: var Top5, dist: int64, label: uint8) {.inline.} =
  if dist >= top.distances[top.worst]:
    return
  top.distances[top.worst] = dist
  top.labels[top.worst] = label
  refreshWorst(top)


proc squaredDistanceI16(refRow: ptr UncheckedArray[int16], q: QueryI16): int64 {.inline.} =
  ## Distância euclidiana² entre 14-vec int16. Acumula em int64 (segura
  ## overflow: max diff = 20000, ²=4e8, ×14=5.6e9 — cabe em int64).
  var s: int64 = 0
  for d in 0 ..< Dim:
    let diff = int32(refRow[d]) - int32(q[d])
    s += int64(diff) * int64(diff)
  s


proc squaredDistanceCappedI16(refRow: ptr UncheckedArray[int16], q: QueryI16,
                              threshold: int64): int64 {.inline.} =
  ## Versão com early break: aborta soma assim que `s >= threshold`. Retorna
  ## o valor parcial (que >= threshold), suficiente para o tryInsert recusar.
  var s: int64 = 0
  for d in 0 ..< Dim:
    let diff = int32(refRow[d]) - int32(q[d])
    s += int64(diff) * int64(diff)
    if s >= threshold:
      return s
  s


proc squaredCentroidDistance(idx: IvfIndex, c: int, q: QueryF32): float32 {.inline.} =
  let base = c * Dim
  var s: float32 = 0
  for d in 0 ..< Dim:
    let diff = idx.centroids[base + d] - q[d]
    s += diff * diff
  s


proc bboxMinSqDistance(idx: IvfIndex, c: int, q: QueryI16): int64 {.inline.} =
  ## Menor distância² possível do query até qualquer ponto dentro da bbox c.
  ## 0 se query está dentro da bbox.
  let base = c * Dim
  var s: int64 = 0
  for d in 0 ..< Dim:
    let qv = int32(q[d])
    let lo = int32(idx.bboxMin[base + d])
    let hi = int32(idx.bboxMax[base + d])
    let delta =
      if qv < lo: lo - qv
      elif qv > hi: qv - hi
      else: 0
    s += int64(delta) * int64(delta)
  s


proc bboxBelowThreshold(idx: IvfIndex, c: int, q: QueryI16, threshold: int64): bool {.inline.} =
  ## Mesma semântica de `bboxMinSqDistance(c) < threshold`, mas com early break.
  ## Para clusters distantes (típico no repair scan), retorna falso após ~3-4 dims
  ## em vez de 14, reduzindo o custo total do repair em ~3-4×.
  let base = c * Dim
  var s: int64 = 0
  for d in 0 ..< Dim:
    let qv = int32(q[d])
    let lo = int32(idx.bboxMin[base + d])
    let hi = int32(idx.bboxMax[base + d])
    let delta =
      if qv < lo: lo - qv
      elif qv > hi: qv - hi
      else: 0
    s += int64(delta) * int64(delta)
    if s >= threshold:
      return false
  true


proc nearestCentroids(idx: IvfIndex, q: QueryF32, nprobe: int, out_buf: var openArray[int]) =
  ## Preenche out_buf com os `nprobe` centroides mais próximos do query.
  ## Insertion sort (nprobe é pequeno, geralmente 1-4).
  assert nprobe <= out_buf.len
  var dists: array[8, float32]
  assert nprobe <= dists.len
  for i in 0 ..< nprobe:
    dists[i] = high(float32)
    out_buf[i] = -1
  for c in 0 ..< idx.nClusters:
    let d = squaredCentroidDistance(idx, c, q)
    # insere em out_buf mantendo ordenado
    if d < dists[nprobe - 1]:
      var j = nprobe - 1
      while j > 0 and dists[j - 1] > d:
        dists[j] = dists[j - 1]
        out_buf[j] = out_buf[j - 1]
        dec j
      dists[j] = d
      out_buf[j] = c


proc searchCluster(idx: IvfIndex, c: int, q: QueryI16, top: var Top5) {.inline.} =
  let s = int(idx.offsets[c])
  let e = int(idx.offsets[c + 1])
  let n = e - s
  if n == 0: return
  assert n <= MaxClusterBuf, "cluster excede MaxClusterBuf"
  let blockPtr = addr idx.vectors[s * Dim]
  let qPtr = unsafeAddr q[0]
  floating_finch_dists_soa_avx2(blockPtr, int32(n), qPtr, addr distsBuf[0])
  for r in 0 ..< n:
    tryInsert(top, distsBuf[r], idx.labels[s + r])


proc fraudCount*(idx: IvfIndex, qF: QueryF32, qI: QueryI16, cfg: SearchConfig): uint8 =
  var top = initTop5()
  var probes: array[8, int]
  let nprobe = max(1, min(cfg.nprobe, probes.len))
  nearestCentroids(idx, qF, nprobe, probes)
  for i in 0 ..< nprobe:
    if probes[i] >= 0:
      searchCluster(idx, probes[i], qI, top)

  var fraud: int = 0
  for l in top.labels:
    fraud += int(l)

  if cfg.bboxRepair and fraud >= cfg.repairMin and fraud <= cfg.repairMax:
    let threshold = top.distances[top.worst]
    for c in 0 ..< idx.nClusters:
      var alreadyProbed = false
      for j in 0 ..< nprobe:
        if probes[j] == c:
          alreadyProbed = true
          break
      if alreadyProbed: continue
      if not bboxBelowThreshold(idx, c, qI, threshold): continue
      searchCluster(idx, c, qI, top)
    fraud = 0
    for l in top.labels:
      fraud += int(l)

  uint8(fraud)
