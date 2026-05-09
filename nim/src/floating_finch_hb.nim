## Variante com httpbeast (epoll single/multi-thread, async).
##
## Mesma config env do floating_finch.nim. Usa httpbeast pra evitar overhead
## do mummy multi-thread sob 0.40 CPU.

import std/[options, os, parseutils, strformat, strutils, times, asyncdispatch, httpcore]

import httpbeast

import types, ivf, quantize, vectorize, search


type AppState = object
  index: IvfIndex
  config: SearchConfig

var sharedState {.global.}: ptr AppState = nil


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
  result.nprobe = envInt("IVF_NPROBE", 4)
  result.bboxRepair = envBool("IVF_BBOX_REPAIR", true)
  result.repairMin = envInt("IVF_REPAIR_MIN", 1)
  result.repairMax = envInt("IVF_REPAIR_MAX", 4)


proc onRequest(req: Request): Future[void] {.gcsafe.} =
  let st = sharedState
  let m = req.httpMethod
  let path = req.path

  if m == some(HttpGet) and path == some("/ready"):
    req.send(Http204)
    return

  if m == some(HttpPost) and path == some("/fraud-score"):
    let body = req.body.get("")
    var fc: uint8 = 0
    try:
      let p = parsePayload(body)
      let qF = vectorize(p)
      let qI = quantizeQuery(qF)
      fc = fraudCount(st.index, qF, qI, st.config)
    except CatchableError:
      fc = 0
    req.send(Http200, ResponseByFraudCount[fc.int], "Content-Type: application/json")
    return

  req.send(Http404)


proc main() =
  let indexPath = envOr("INDEX_PATH", "./index.bin")
  echo &"loading index from {indexPath}"
  let stRef = create(AppState)
  stRef[].index = loadIndex(indexPath)
  stRef[].config = loadConfig()
  sharedState = stRef
  echo &"  n={sharedState.index.nVectors}  k={sharedState.index.nClusters}"
  echo &"  config: nprobe={sharedState.config.nprobe}  repair=[{sharedState.config.repairMin}-{sharedState.config.repairMax}]"
  echo "  warming up mmap pages…"
  let t0 = epochTime()
  warmup(sharedState.index)
  echo &"  warmup done in {(epochTime() - t0) * 1000:.0f} ms"

  let host = envOr("BIND_HOST", "0.0.0.0")
  let port = envInt("BIND_PORT", 8080)
  let workers = envInt("WORKER_THREADS", 1)
  echo &"listening on {host}:{port} (httpbeast workers={workers})"

  let settings = initSettings(
    port = Port(port),
    bindAddr = host,
    numThreads = workers,
  )
  run(onRequest, settings)


when isMainModule:
  main()
