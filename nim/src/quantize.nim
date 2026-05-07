## Quantização float32 → int16 do query vector.
##
## Esquema (idêntico ao gerador Python em validation/quantize.py):
##   int16 = round(clamp(float, 0, 1) * 10_000)
##   sentinel float -1 → int16 -10_000

import std/math

import types

const
  SentinelFloat* = -1.0'f32
  SentinelInt16* = int16(-10_000)


proc quantizeQuery*(q: QueryF32): QueryI16 {.inline.} =
  for i in 0 ..< Dim:
    let v = q[i]
    if v == SentinelFloat:
      result[i] = SentinelInt16
    else:
      let clamped = clamp(v, 0.0'f32, 1.0'f32)
      result[i] = int16(round(clamped * QuantScale))
