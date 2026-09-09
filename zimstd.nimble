version = "0.1.0"
author = "ZimSTD contributors"
description = "ZimSTD: pure Nim Zstandard compression and decompression"
license = "BSD-3-Clause"
srcDir = "src"
requires "nim >= 2.0.0"
task test, "Run regression vectors and codec tests":
  exec "nim c -r --path:src tests/test_zimstd.nim"
  exec "nim c -r --path:src tests/test_streaming.nim"
task interop, "Test against the reference zstd CLI":
  exec "nim c -d:release -r --path:src tests/interop.nim"
task bench, "Run in-memory benchmarks":
  exec "nim c -d:release -r --path:src benchmarks/bench.nim"
