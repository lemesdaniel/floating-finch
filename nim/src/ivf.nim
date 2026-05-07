## Carregamento do index.bin via mmap.
##
## Layout: ver nim/docs/INDEX_BIN_FORMAT.md.
## Foco em zero-cópia: cada bloco é um `ptr UncheckedArray[T]` apontando
## para a região mmap'd, sem alocação adicional.

import std/[memfiles, os, strformat]

import types

const
  MagicExpected* = ['R', 'I', 'V', 'F']
  HeaderSize* = 64
  Align* = 64

type
  IvfHeader* {.packed.} = object
    magic*: array[4, char]
    version*: uint32
    nVectors*: uint32
    nClusters*: uint32
    dim*: uint32
    quantScale*: float32
    flags*: uint64
    reserved*: array[32, byte]

  IvfIndex* = object
    file*: MemFile
    nVectors*: int
    nClusters*: int
    quantScale*: float32

    centroids*: ptr UncheckedArray[float32]   ## n_clusters × dim, row-major
    bboxMin*: ptr UncheckedArray[int16]       ## n_clusters × dim
    bboxMax*: ptr UncheckedArray[int16]       ## n_clusters × dim
    offsets*: ptr UncheckedArray[uint32]      ## n_clusters + 1
    labels*: ptr UncheckedArray[uint8]        ## n_vectors
    vectors*: ptr UncheckedArray[int16]       ## n_vectors × dim, row-major


proc alignUp(x, a: int): int {.inline.} =
  (x + a - 1) and not (a - 1)


proc loadIndex*(path: string): IvfIndex =
  ## Abre `path` via mmap, valida cabeçalho e popula ponteiros para cada bloco.
  result.file = memfiles.open(path, mode = fmRead, mappedSize = -1)
  let base = cast[ptr UncheckedArray[byte]](result.file.mem)
  let total = result.file.size
  if total < HeaderSize:
    raise newException(IOError, &"{path}: arquivo menor que o header ({total} < {HeaderSize})")

  let header = cast[ptr IvfHeader](addr base[0])
  if header.magic != MagicExpected:
    raise newException(IOError, &"{path}: magic inesperado")
  if header.version != 1:
    raise newException(IOError, &"{path}: versão {header.version} não suportada")
  if header.dim != Dim.uint32:
    raise newException(IOError, &"{path}: dim={header.dim} != {Dim}")

  result.nVectors = int(header.nVectors)
  result.nClusters = int(header.nClusters)
  result.quantScale = header.quantScale

  var off = HeaderSize

  proc advance(off: var int, blockSize: int, total: int, path: string): int =
    off = alignUp(off, Align)
    let cur = off
    off = cur + blockSize
    if off > total:
      raise newException(IOError, &"{path}: bloco em {cur} estoura o arquivo ({off} > {total})")
    cur

  let cOff = advance(off, result.nClusters * Dim * sizeof(float32), total, path)
  result.centroids = cast[ptr UncheckedArray[float32]](addr base[cOff])

  let bMinOff = advance(off, result.nClusters * Dim * sizeof(int16), total, path)
  result.bboxMin = cast[ptr UncheckedArray[int16]](addr base[bMinOff])

  let bMaxOff = advance(off, result.nClusters * Dim * sizeof(int16), total, path)
  result.bboxMax = cast[ptr UncheckedArray[int16]](addr base[bMaxOff])

  let oOff = advance(off, (result.nClusters + 1) * sizeof(uint32), total, path)
  result.offsets = cast[ptr UncheckedArray[uint32]](addr base[oOff])

  let lOff = advance(off, result.nVectors * sizeof(uint8), total, path)
  result.labels = cast[ptr UncheckedArray[uint8]](addr base[lOff])

  let vOff = advance(off, result.nVectors * Dim * sizeof(int16), total, path)
  result.vectors = cast[ptr UncheckedArray[int16]](addr base[vOff])


proc closeIndex*(index: var IvfIndex) =
  if index.file.mem != nil:
    index.file.close()


when isMainModule:
  proc smoke() =
    if paramCount() < 1:
      quit "uso: ivf <index.bin>"
    var idx = loadIndex(paramStr(1))
    defer: closeIndex(idx)
    echo &"ok  n={idx.nVectors}  k={idx.nClusters}  scale={idx.quantScale}"
    echo &"centroids[0..4]: ", @[idx.centroids[0], idx.centroids[1], idx.centroids[2], idx.centroids[3]]
    echo &"labels[0..9]:    ", @[
      idx.labels[0], idx.labels[1], idx.labels[2], idx.labels[3], idx.labels[4],
      idx.labels[5], idx.labels[6], idx.labels[7], idx.labels[8], idx.labels[9],
    ]
    let lastOffset = int(idx.offsets[idx.nClusters])
    echo &"sum(cluster_sizes) = {lastOffset}  (esperado {idx.nVectors})"

  smoke()
