# ZimSTD

**Zstandard compression and decompression in pure Nim.**

ZimSTD combines Nim and Zstandard in a small codec with in-memory and streaming
APIs. It produces standard Zstandard frames and decodes dictionary-free frames from other encoders.
The library depends only on Nim's standard library—no libzstd bindings, embedded
C, or runtime subprocesses.

```nim
import zimstd

let original = "hello hello hello"
let packed = compress(original)
doAssert decompress(packed) == original
```

## Installation

Requires **Nim 2.0+** and a **64-bit target**. From this checkout:

```sh
nimble install
```

Then import `zimstd` in your program and compile normally:

```sh
nim c -d:release your_program.nim
```

To use the source directly without installing, run from the project directory:

```sh
nim c -d:release --path:src your_program.nim
```

## Usage

The in-memory overloads accept `openArray[char]` and return a `string`. Strings carry
binary data, including zero bytes; array slices can be passed without copying.

### Compress

```nim
let packed = compress("some data")
let withoutChecksum = compress("some data", checksum = false)
```

`compress` emits one Zstandard frame with a content checksum by default.
Incompressible input can grow by the frame and block headers plus the optional
four-byte checksum. Compression levels are not exposed.

### Decompress with limits

```nim
try:
  let restored = decompress(packed,
    maxOutput = 16 * 1024 * 1024,
    maxWindow = 8 * 1024 * 1024)
  doAssert restored == "some data"
except ZstdError as error:
  echo "Cannot decode: ", error.msg
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `maxOutput` | 256 MiB | Maximum total decoded bytes, across all concatenated frames |
| `maxWindow` | 128 MiB | Maximum declared frame window |

Malformed input, exceeded limits, unsupported dictionaries, and checksum
mismatches raise `ZstdError`. Checksums are always verified when present.
Empty compressed input is an error; a valid empty frame or a skippable frame
returns an empty string.

These are decoding limits, not a total process memory budget. Input and output
coexist in memory, and buffer capacity and codec scratch space add overhead.

### Stream files without loading them into memory

The `Stream` overloads read and write incrementally using Nim's `std/streams`:

```nim
import std/streams
import zimstd

proc compressFile(source, destination: string) =
  let input = newFileStream(source, fmRead)
  if input == nil: raise newException(IOError, "Cannot open input")
  defer: input.close()
  let output = newFileStream(destination, fmWrite)
  if output == nil: raise newException(IOError, "Cannot open output")
  defer: output.close()
  compress(input, output)

proc decompressFile(source, destination: string) =
  let input = newFileStream(source, fmRead)
  if input == nil: raise newException(IOError, "Cannot open input")
  defer: input.close()
  let output = newFileStream(destination, fmWrite)
  if output == nil: raise newException(IOError, "Cannot open output")
  defer: output.close()
  decompress(input, output, maxOutput = 1024 * 1024 * 1024)
```

Use distinct source and destination files. The caller owns both streams; the
codec does not close or flush them. Read/write failures propagate to the caller.

- `compress(input, output, checksum = true)` emits one frame with an unknown
  content size and a 128 KiB window. It buffers up to 128 KiB of input plus codec
  scratch, and finishes the frame at EOF. Its frame bytes differ from the
  in-memory encoder's known-size frame.
- `decompress(input, output, maxOutput = 256 MiB, maxWindow = 128 MiB)` retains
  rolling match history and entropy tables across blocks. Working memory is
  O(window + block size), independent of total decoded size. Output is written
  one block at a time; limits also apply to concatenated frames.
- Forward-only blocking streams are supported. Short reads are retried; a
  zero-byte read means EOF. These are synchronous calls, not nonblocking
  feed/poll APIs, and encoding may wait for a full block or EOF before writing
  compressed data.

**On failure, the destination may contain partial, unverified output.** Frame
checksums are checked after its blocks have been written. If output must only
become visible after successful validation, write to a temporary file and rename
it after decoding and closing succeed.

## Format support and scope

The decoder supports:

- Raw, RLE, and compressed blocks.
- Raw, RLE, Huffman, and treeless literals.
- All four sequence coding modes, repeat offsets, and cross-block matches.
- Optional content sizes and checksums.
- Concatenated frames and skippable frames.

The encoder uses block-local greedy LZ77 with predefined FSE tables, RLE sequence
tables for single matches, and raw/RLE block fallbacks. It favors speed and small
working memory over compression ratio; it does not aim to match libzstd's ratio.

**Not implemented:** external dictionaries, compression levels, adaptive encoder
entropy coding, or cross-block encoder matches.

## Performance

See the [profiling report](benchmarks/BROAD_PROFILE.md) for historical in-memory
measurements, methodology, and reproduction commands. Those results predate the
streaming API; they are not a comparison with libzstd. Benchmark your own inputs
with `nimble bench` or the corpus tools below.

## Development

```sh
nimble test       # Vectors, corruption/limits, short reads, and streaming I/O
nimble interop    # In-memory and streaming cases against the reference zstd CLI
nimble bench     # Synthetic in-memory throughput and size measurements
```

Only `nimble interop` requires the reference `zstd` CLI. Tests retain bounds,
range, and overflow checks, including in release builds; `-d:danger` is not needed.
See [test vector provenance](tests/vectors/README.md).

For corpus benchmarks, use [corpus.nim](benchmarks/corpus.nim) and the
[comparison driver](benchmarks/compare.py), following the profiling report.

If Nimble fails while scanning an unrelated installed package, use a clean
package directory:

```sh
nimble --nimbleDir:/tmp/zimstd-nimble test
```

Or run the regression suite directly:

```sh
nim c -r --path:src tests/test_zimstd.nim
```

## License and acknowledgments

ZimSTD is licensed under [BSD-3-Clause](LICENSE). The entropy decoder follows
[RFC 8878](https://www.rfc-editor.org/rfc/rfc8878) and adapts algorithms from
Go's BSD-licensed `internal/zstd`; attribution is included in the license file.
