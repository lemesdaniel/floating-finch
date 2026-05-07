# Package
version       = "0.1.0"
author        = "Daniel Lemes"
description   = "Rinha de Backend 2026 — fraud detection IVF (v1 Nim)"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]

bin           = @["floating_finch", "preprocess"]

# Dependencies
requires "nim >= 2.2.0"
requires "mummy >= 0.4.7"
requires "jsony >= 1.1.5"

# Build profiles
task release, "compile API release":
  exec "nim c -d:release -d:lto --opt:speed --passC:\"-O3 -mavx2 -mfma -fno-strict-aliasing\" --passL:\"-O3\" --mm:arc -o:bin/floating_finch src/floating_finch.nim"

task preprocess, "compile preprocessor release":
  exec "nim c -d:release -d:lto --opt:speed --passC:\"-O3 -mavx2 -mfma\" --mm:arc -o:bin/preprocess src/preprocess.nim"

task all, "build everything":
  exec "nimble release"
  exec "nimble preprocess"
