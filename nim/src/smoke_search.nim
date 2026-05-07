## Smoke test do pipeline IVF: carrega index.bin, executa K queries e
## imprime fraud_count + tempo médio. Usa vetores do exemplo da doc oficial.

import std/[os, monotimes, strformat, times]

import types, ivf, quantize, search

const
  ## Vetor 1 do example-references.json — label "legit".
  ExampleLegit: QueryF32 = [
    0.01'f32, 0.0833'f32, 0.05'f32, 0.8261'f32, 0.1667'f32,
    -1.0'f32, -1.0'f32, 0.0432'f32, 0.25'f32, 0.0'f32,
    1.0'f32, 0.0'f32, 0.2'f32, 0.0416'f32,
  ]
  ## Vetor 2 (próximo do espaço, deve ficar próximo do anterior).
  ExampleLegit2: QueryF32 = [
    0.0109'f32, 0.1667'f32, 0.05'f32, 0.3913'f32, 0.6667'f32,
    0.3007'f32, 0.0139'f32, 0.0154'f32, 0.2'f32, 0.0'f32,
    1.0'f32, 0.0'f32, 0.15'f32, 0.0282'f32,
  ]


proc main() =
  if paramCount() < 1:
    quit "uso: smoke_search <index.bin>"
  var idx = loadIndex(paramStr(1))
  defer: closeIndex(idx)
  echo &"loaded n={idx.nVectors} k={idx.nClusters}"

  let queries = [ExampleLegit, ExampleLegit2]
  let configs = @[
    SearchConfig(nprobe: 1, bboxRepair: false, repairMin: 2, repairMax: 3),
    SearchConfig(nprobe: 1, bboxRepair: true,  repairMin: 2, repairMax: 3),
    SearchConfig(nprobe: 2, bboxRepair: true,  repairMin: 1, repairMax: 4),
  ]

  for cfg in configs:
    echo &"--- nprobe={cfg.nprobe} repair={cfg.bboxRepair} [{cfg.repairMin}-{cfg.repairMax}] ---"
    for i, q in queries:
      let qI = quantizeQuery(q)
      # warmup
      discard fraudCount(idx, q, qI, cfg)
      # bench
      const Iters = 200
      let t0 = getMonoTime()
      var fc: uint8 = 0
      for _ in 0 ..< Iters:
        fc = fraudCount(idx, q, qI, cfg)
      let dt = (getMonoTime() - t0).inMicroseconds.float / Iters.float
      echo &"  query {i+1}: fraud_count={fc}/5  approved={fc < ApprovedThreshold.uint8}  avg={dt:.1f} µs"

main()
