## Mini-bench timing por etapa do hot path. Lê payloads JSONL via stdin,
## roda cada query N vezes, reporta tempo médio por etapa.
##
## Uso:
##   ./bench_profile <index.bin> <payloads.jsonl> [iterations=10000]

import std/[monotimes, os, strformat, strutils, times]

import types, ivf, quantize, vectorize, search

proc main() =
  if paramCount() < 2:
    quit "uso: bench_profile <index.bin> <payloads.jsonl> [iters=10000]"
  let indexPath = paramStr(1)
  let payloadsPath = paramStr(2)
  let iters = if paramCount() >= 3: parseInt(paramStr(3)) else: 10_000

  echo &"loading index from {indexPath}"
  var idx = loadIndex(indexPath)
  defer: closeIndex(idx)
  echo &"  n={idx.nVectors}  k={idx.nClusters}"

  warmup(idx)
  echo "warmup done"

  let cfg = SearchConfig(nprobe: 4, bboxRepair: true, repairMin: 1, repairMax: 4)

  # Carrega payloads
  let lines = readFile(payloadsPath).splitLines()
  var payloads: seq[string] = @[]
  for l in lines:
    if l.len > 0: payloads.add(l)
  echo &"loaded {payloads.len} payloads, running {iters} iterations cycling through them"

  # Buckets de tempo (ns) por etapa
  var
    totParse: int64 = 0
    totVectorize: int64 = 0
    totQuantize: int64 = 0
    totSearch: int64 = 0
    totalNs: int64 = 0
    sumFc: int = 0  # impede dead-code elimination

  let tStart = getMonoTime()
  for it in 0 ..< iters:
    let body = payloads[it mod payloads.len]

    let t0 = getMonoTime()
    let p = parsePayload(body)
    let t1 = getMonoTime()
    let qF = vectorize(p)
    let t2 = getMonoTime()
    let qI = quantizeQuery(qF)
    let t3 = getMonoTime()
    let fc = fraudCount(idx, qF, qI, cfg)
    let t4 = getMonoTime()

    totParse += inNanoseconds(t1 - t0)
    totVectorize += inNanoseconds(t2 - t1)
    totQuantize += inNanoseconds(t3 - t2)
    totSearch += inNanoseconds(t4 - t3)
    sumFc += fc.int
  let tEnd = getMonoTime()
  totalNs = inNanoseconds(tEnd - tStart)

  echo &"\nsumFc (sink): {sumFc}"
  echo &"\n=== {iters} iterações ==="
  echo &"  total wall: {totalNs.float / 1e9:.3f} s ({iters.float / (totalNs.float / 1e9):.0f} req/s)"
  echo &"  parse:     {totParse.float / iters.float / 1000:.2f} µs/req  ({100.0 * totParse.float / totalNs.float:.1f}%)"
  echo &"  vectorize: {totVectorize.float / iters.float / 1000:.2f} µs/req  ({100.0 * totVectorize.float / totalNs.float:.1f}%)"
  echo &"  quantize:  {totQuantize.float / iters.float / 1000:.2f} µs/req  ({100.0 * totQuantize.float / totalNs.float:.1f}%)"
  echo &"  search:    {totSearch.float / iters.float / 1000:.2f} µs/req  ({100.0 * totSearch.float / totalNs.float:.1f}%)"

when isMainModule:
  main()
