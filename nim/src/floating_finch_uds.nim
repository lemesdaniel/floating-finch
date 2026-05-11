## HTTP server custom Nim com UDS via std/selectors (epoll/kqueue).
##
## Single-thread, non-blocking, keep-alive. Liga em UDS (mode 0666) se
## UDS_PATH setado; senão TCP (BIND_PORT).
##
## Parser HTTP minimal: GET /ready, POST /fraud-score.

import std/[os, parseutils, posix, selectors, strformat, strutils, tables, times]

import types, ivf, quantize, vectorize, search

const
  ReadBufSize = 64 * 1024
  MaxBody = 32 * 1024
  ResponseReady = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
  ResponseBadRequest = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  ResponseNotFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  ResponseTooLarge = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  # Resposta /fraud-score pré-formatada por fc (0..5). Connection: close não é
  # mandatório; vamos usar keep-alive default (HTTP/1.1).
  FraudHeaderTpl = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $1\r\n\r\n"

# Cache das 6 respostas completas (header + body), uma alocação na inicialização
var FraudResponses {.threadvar.}: array[6, string]

proc buildFraudResponses() =
  for i in 0 ..< 6:
    let body = ResponseByFraudCount[i]
    FraudResponses[i] = FraudHeaderTpl % $body.len & body

type
  ConnState = ref object
    fd: cint
    buf: string  # buffer de leitura
    write_buf: string  # buffer de saída pendente
    write_pos: int

  AppState = object
    index: IvfIndex
    config: SearchConfig
    selector: Selector[ConnState]
    listener_fd: cint

var app {.global.}: ptr AppState = nil


proc envOr(name, default: string): string =
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


proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL, 0)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)


proc bindUds(path: string): cint =
  let sh = socket(AF_UNIX, SOCK_STREAM, 0)
  let fd = sh.cint
  if fd < 0:
    raiseOSError(osLastError(), "socket UDS")
  discard unlink(path.cstring)
  var sun: Sockaddr_un
  sun.sun_family = cast[TSa_Family](AF_UNIX)
  if path.len >= sun.sun_path.len:
    raise newException(ValueError, "UDS path too long: " & path)
  for i, c in path:
    sun.sun_path[i] = c
  sun.sun_path[path.len] = '\0'
  let sunSize = SockLen(sizeof(sun))
  if bindSocket(SocketHandle(fd), cast[ptr SockAddr](addr sun), sunSize) < 0:
    raiseOSError(osLastError(), "bind UDS " & path)
  if listen(SocketHandle(fd), 4096) < 0:
    raiseOSError(osLastError(), "listen UDS")
  discard chmod(path.cstring, 0o666.Mode)
  setNonBlocking(fd)
  fd


proc bindTcp(host: string, port: int): cint =
  let sh = socket(AF_INET, SOCK_STREAM, 0)
  let fd = sh.cint
  if fd < 0: raiseOSError(osLastError(), "socket TCP")
  var yes: cint = 1
  discard setsockopt(SocketHandle(fd), SOL_SOCKET, SO_REUSEADDR, addr yes, SockLen(sizeof(yes)))
  var addrIn: Sockaddr_in
  addrIn.sin_family = cast[TSa_Family](AF_INET)
  addrIn.sin_port = htons(port.uint16)
  addrIn.sin_addr.s_addr = htonl(INADDR_ANY)
  let s = SockLen(sizeof(addrIn))
  if bindSocket(SocketHandle(fd), cast[ptr SockAddr](addr addrIn), s) < 0:
    raiseOSError(osLastError(), "bind TCP " & $port)
  if listen(SocketHandle(fd), 4096) < 0:
    raiseOSError(osLastError(), "listen TCP")
  setNonBlocking(fd)
  fd


proc closeConn(state: var AppState, conn: ConnState) =
  state.selector.unregister(conn.fd)
  discard close(conn.fd)
  conn.buf.setLen(0)
  conn.write_buf.setLen(0)


# Parser HTTP minimal. Retorna (method, path, body) ou indica incompleto.
type ParseResult = enum
  prIncomplete, prDone, prBadRequest, prTooLarge

proc parseRequest(buf: string, mthd, path, body: var string, consumed: var int,
                  keepAlive: var bool): ParseResult =
  keepAlive = true
  let headEnd = buf.find("\r\n\r\n")
  if headEnd < 0: return prIncomplete
  let head = buf[0 ..< headEnd]
  let firstEol = head.find('\n')
  if firstEol < 0: return prBadRequest
  let line1 = if firstEol > 0 and head[firstEol - 1] == '\r': head[0 ..< firstEol - 1] else: head[0 ..< firstEol]
  let sp1 = line1.find(' ')
  if sp1 < 0: return prBadRequest
  mthd = line1[0 ..< sp1]
  let rest = line1[sp1 + 1 .. ^1]
  let sp2 = rest.find(' ')
  if sp2 < 0: return prBadRequest
  path = rest[0 ..< sp2]
  var contentLength = 0
  var lineStart = firstEol + 1
  while lineStart < head.len:
    var eol = head.find('\n', lineStart)
    if eol < 0: eol = head.len
    let lineRaw = head[lineStart ..< eol]
    let line = if lineRaw.len > 0 and lineRaw[^1] == '\r': lineRaw[0 ..< lineRaw.high] else: lineRaw
    if line.len == 0: break
    let colon = line.find(':')
    if colon > 0:
      let name = line[0 ..< colon]
      var valStart = colon + 1
      while valStart < line.len and (line[valStart] == ' ' or line[valStart] == '\t'):
        inc valStart
      let value = line[valStart .. ^1]
      if cmpIgnoreCase(name, "content-length") == 0:
        if parseInt(value, contentLength) <= 0: return prBadRequest
      elif cmpIgnoreCase(name, "connection") == 0:
        if cmpIgnoreCase(value, "close") == 0: keepAlive = false
    lineStart = eol + 1
  if contentLength > MaxBody: return prTooLarge
  let bodyStart = headEnd + 4
  let total = bodyStart + contentLength
  if total > buf.len: return prIncomplete
  body = if contentLength > 0: buf[bodyStart ..< total] else: ""
  consumed = total
  return prDone


proc handle(state: AppState, conn: ConnState, mthd, path, body: string) =
  if mthd == "GET" and path == "/ready":
    conn.write_buf.add(ResponseReady)
    return
  if mthd == "POST" and path == "/fraud-score":
    var fc: uint8 = 0
    try:
      let p = parsePayload(body)
      let qF = vectorize(p)
      let qI = quantizeQuery(qF)
      fc = fraudCount(state.index, qF, qI, state.config)
    except CatchableError:
      fc = 0
    if fc.int > 5: fc = 0
    conn.write_buf.add(FraudResponses[fc.int])
    return
  conn.write_buf.add(ResponseNotFound)


proc tryFlushWrite(state: var AppState, conn: ConnState): bool =
  ## Tenta escrever todo o write_buf não-bloqueante. Retorna true se conn deve
  ## continuar aberta.
  while conn.write_pos < conn.write_buf.len:
    let n = posix.write(conn.fd, addr conn.write_buf[conn.write_pos],
                        (conn.write_buf.len - conn.write_pos).int)
    if n > 0:
      conn.write_pos += n
    elif n < 0:
      let err = osLastError().int32
      if err == EAGAIN or err == EWOULDBLOCK:
        # registrar pra EPOLLOUT
        state.selector.updateHandle(conn.fd, {Event.Read, Event.Write})
        return true
      return false
    else:
      return false
  conn.write_buf.setLen(0)
  conn.write_pos = 0
  state.selector.updateHandle(conn.fd, {Event.Read})
  return true


proc processConn(state: var AppState, conn: ConnState): bool =
  ## Lê requests do socket. Retorna false se conn deve fechar.
  var rdBuf: array[ReadBufSize, char]
  while true:
    let n = posix.read(conn.fd, addr rdBuf[0], rdBuf.len.int)
    if n > 0:
      let prevLen = conn.buf.len
      conn.buf.setLen(prevLen + n.int)
      copyMem(addr conn.buf[prevLen], addr rdBuf[0], n.int)
    elif n == 0:
      return false
    else:
      let err = osLastError().int32
      if err == EAGAIN or err == EWOULDBLOCK: break
      return false
  while true:
    var mthd, path, body: string
    var consumed = 0
    var keepAlive = true
    case parseRequest(conn.buf, mthd, path, body, consumed, keepAlive)
    of prIncomplete: break
    of prBadRequest:
      conn.write_buf.add(ResponseBadRequest)
      return tryFlushWrite(state, conn) and false
    of prTooLarge:
      conn.write_buf.add(ResponseTooLarge)
      return tryFlushWrite(state, conn) and false
    of prDone:
      handle(state, conn, mthd, path, body)
      if consumed < conn.buf.len:
        conn.buf = conn.buf[consumed .. ^1]
      else:
        conn.buf.setLen(0)
      if not keepAlive:
        discard tryFlushWrite(state, conn)
        return false
  return tryFlushWrite(state, conn)


proc serveLoop(state: var AppState) =
  var events: array[1024, ReadyKey]
  while true:
    let n = state.selector.selectInto(-1, events)
    for i in 0 ..< n:
      let ev = events[i]
      if ev.fd.cint == state.listener_fd:
        while true:
          var addrBuf: SockAddr_storage
          var addrLen: SockLen = SockLen(sizeof(addrBuf))
          let client = posix.accept(SocketHandle(state.listener_fd),
                                    cast[ptr SockAddr](addr addrBuf), addr addrLen)
          if client.cint < 0:
            let err = osLastError().int32
            if err == EAGAIN or err == EWOULDBLOCK: break
            break
          setNonBlocking(client.cint)
          let conn = ConnState(fd: client.cint, buf: "", write_buf: "", write_pos: 0)
          state.selector.registerHandle(client.cint, {Event.Read}, conn)
      else:
        let conn = state.selector.getData(ev.fd.cint)
        if conn == nil: continue
        if not processConn(state, conn):
          closeConn(state, conn)


proc loadConfig(): SearchConfig =
  result.nprobe = envInt("IVF_NPROBE", 4)
  result.bboxRepair = envBool("IVF_BBOX_REPAIR", true)
  result.repairMin = envInt("IVF_REPAIR_MIN", 1)
  result.repairMax = envInt("IVF_REPAIR_MAX", 4)


proc main() =
  let indexPath = envOr("INDEX_PATH", "./index.bin")
  let udsPath = envOr("UDS_PATH", "")
  let bindHost = envOr("BIND_HOST", "0.0.0.0")
  let bindPort = envInt("BIND_PORT", 8080)

  echo &"loading index from {indexPath}"
  let stRef = create(AppState)
  stRef[].index = loadIndex(indexPath)
  stRef[].config = loadConfig()
  app = stRef
  echo &"  n={app.index.nVectors}  k={app.index.nClusters}"
  echo &"  config: nprobe={app.config.nprobe}  repair=[{app.config.repairMin}-{app.config.repairMax}]"

  buildFraudResponses()

  app.selector = newSelector[ConnState]()
  app.listener_fd =
    if udsPath.len > 0:
      echo &"listening on unix:{udsPath}"
      bindUds(udsPath)
    else:
      echo &"listening on {bindHost}:{bindPort}"
      bindTcp(bindHost, bindPort)

  # Registra listener no selector com sentinela (nil)
  app.selector.registerHandle(app.listener_fd, {Event.Read}, ConnState(fd: app.listener_fd))

  serveLoop(app[])


when isMainModule:
  main()
