## Pure Nim Zstandard. No C libraries, subprocesses, or runtime dependencies.
## Binary data uses strings/openArray[char], or incremental std/streams I/O.
when sizeof(int) != 8:
  {.error: "ZimSTD requires a 64-bit Nim target".}
import zimstd/[common, encode, decode]
export ZstdError, compress, decompress
export MinCompressionLevel, DefaultCompressionLevel, MaxCompressionLevel
