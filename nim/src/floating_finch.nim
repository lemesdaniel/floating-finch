## Servidor HTTP (mummy) — entry point da v1.
##
## Endpoints:
##   GET  /ready        → 204 quando o índice está carregado
##   POST /fraud-score  → 200 application/json com {approved, fraud_score}
##
## Configuração via env:
##   INDEX_PATH         → caminho do index.bin (default ./index.bin)
##   UNIX_SOCKET_PATH   → se setado, escuta em UDS; senão em $BIND_HOST:$BIND_PORT
##   BIND_HOST          → default 0.0.0.0
##   BIND_PORT          → default 8080
##   IVF_NPROBE         → default 1
##   IVF_BBOX_REPAIR    → "true"/"1" para ativar (default true)
##   IVF_REPAIR_MIN     → default 2
##   IVF_REPAIR_MAX     → default 3

import std/[os, parseutils, strformat, strutils, times]

import mummy, mummy/routers

import types, ivf, quantize, vectorize, search


type AppState = ref object
  index: IvfIndex
  config: SearchConfig


proc envOr(name: string, default: string): string =
  let v = getEnv(name, default)
  if v.len == 0: default else: v


proc envInt(name: string, default: int): int =
  let v = getEnv(name)
  if v.len == 0: return default
  var x: int
  if parseInt(v, x) > 0: x else: default


proc envBool(name: string, default: bool): bool =
  let v = getEnv(name).toLowerAscii
  case v
  of "1", "true", "yes": true
  of "0", "false", "no": false
  else: default


proc loadConfig(): SearchConfig =
  ## Default calibrado em §6.10: nprobe=4, repair[1-4] dá 100% recall
  ## sobre 10k queries do dataset (vs ground truth brute-force fp32 exato).
  result.nprobe = envInt("IVF_NPROBE", 4)
  result.bboxRepair = envBool("IVF_BBOX_REPAIR", true)
  result.repairMin = envInt("IVF_REPAIR_MIN", 1)
  result.repairMax = envInt("IVF_REPAIR_MAX", 4)


proc envWorkers(): int =
  ## Mummy default = countProcessors() * 10. No Mac Mini 4-core sob 0.40 CPU
  ## isso vira 40 threads brigando por 0.4 core. Default explícito = 2.
  envInt("WORKER_THREADS", 2)


proc handleReady(req: Request) {.gcsafe.} =
  req.respond(204)


proc handleFraudScore(state: AppState, req: Request) {.gcsafe.} =
  ## Hot path. Retorna respostas pré-formatadas (zero-alocação no JSON).
  ## Em qualquer falha (parse, vectorize), responde {approved:true, fraud_score:0.0}
  ## — peso menor que HTTP 5xx no score_det da Rinha.
  var fc: uint8 = 0
  try:
    let p = parsePayload(req.body)
    let qF = vectorize(p)
    let qI = quantizeQuery(qF)
    fc = fraudCount(state.index, qF, qI, state.config)
  except CatchableError:
    fc = 0  # fallback silencioso

  let body = ResponseByFraudCount[fc.int]
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  req.respond(200, headers, body)


proc main() =
  let indexPath = envOr("INDEX_PATH", "./index.bin")
  echo &"loading index from {indexPath}"
  var state = AppState(
    index: loadIndex(indexPath),
    config: loadConfig(),
  )
  echo &"  n={state.index.nVectors}  k={state.index.nClusters}"
  echo &"  config: nprobe={state.config.nprobe}  bboxRepair={state.config.bboxRepair}  " &
       &"repair=[{state.config.repairMin}-{state.config.repairMax}]"
  echo "  warming up mmap pages…"
  let t0 = epochTime()
  warmup(state.index)
  echo &"  warmup done in {(epochTime() - t0) * 1000:.0f} ms"

  var router: Router
  router.get("/ready", handleReady)
  router.post("/fraud-score", proc(req: Request) {.gcsafe.} = handleFraudScore(state, req))

  let host = envOr("BIND_HOST", "0.0.0.0")
  let port = envInt("BIND_PORT", 8080)
  let workers = envWorkers()
  echo &"listening on {host}:{port}  workers={workers}"
  let server = newServer(router, workerThreads = workers)
  server.serve(Port(port), host)


when isMainModule:
  main()
