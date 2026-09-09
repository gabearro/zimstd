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
let smaller = compress("some data", level = 9)
let faster = compress("some data", level = -5)
```

`compress` emits one Zstandard frame with a content checksum by default.
Incompressible input can grow by the frame and block headers plus the optional
four-byte checksum.

### Compression levels

Both compression APIs accept `level`, using Zstandard 1.5.7's numeric range:
**−131072 through 22**, with **3 as the default** and **0 as an alias for 3**.
The exported constants are `MinCompressionLevel`, `DefaultCompressionLevel`, and
`MaxCompressionLevel`. Out-of-range values raise `ZstdError` before input is read
or output is written.

| Level | ZimSTD behavior |
| --- | --- |
| Negative | Fast mode: larger negative magnitude skips more match searches |
| 1–2 | Fast greedy matching with more aggressive skipping |
| 3 (or 0) | Default greedy matching; preserves the original encoder's output |
| 4–5 | Search multiple previous matches using hash chains |
| 6–22 | Increasing search depth plus one-byte lazy matching |

Higher levels spend more CPU searching for useful matches. Levels above 3 add
up to 512 KiB of match-chain scratch; memory remains bounded per block. The
encoded size need not decrease at every level or on every input.

**These are ZimSTD tuning presets, not a reproduction of libzstd's presets.**
The numeric range and default follow the
[Zstandard API](https://github.com/facebook/zstd/blob/v1.5.7/lib/zstd.h), but
ZimSTD retains its 128 KiB block-local encoder and predefined entropy tables.
It does not implement libzstd's high-level optimal parsers or larger match
windows, so equal level numbers do not imply equal ratio, speed, or memory use.
Levels 20–22 are accepted directly; `--ultra` is a reference CLI option, not a
separate flag in this API. Decoding needs no level argument.

Use the named argument to preserve the existing positional checksum argument:
`compress(data, level = 9)` or `compress(input, output, level = 9)`.

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

- `compress(input, output, checksum = true, level = 3)` emits one frame with an unknown
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

The encoder uses block-local greedy or lazy LZ77 with predefined FSE tables, RLE sequence
tables for single matches, and raw/RLE block fallbacks. It favors speed and small
working memory over compression ratio; it does not aim to match libzstd's ratio.

**Not implemented:** external dictionaries, adaptive encoder entropy coding,
optimal parsing, or cross-block encoder matches.

## Throughput

Measured on an **Apple M3 Max (macOS, ARM64)** with **Nim 2.2.6**, release/ORC,
compression level 3, checksums enabled, and bounds/range/overflow checks retained. Values are medians
of **five runs, 200 iterations per workload per run**, measured September 9, 2026.

| Workload | Input bytes | Encode (MiB/s) | Decode (MiB/s) |
| --- | ---: | ---: | ---: |
| Repeated 16-byte pattern | 1,048,576 | 2,429 | 5,720 |
| Generated record text | 1,220,890 | 826 | 956 |
| Uniform random bytes | 1,048,576 | 2,410 | 5,712 |
| Weighted printable bytes | 90,000 | 2,453 | 181 |
| Random bytes from a 16-value alphabet | 140,000 | 117 | 215 |

Throughput counts **uncompressed bytes** (1 MiB = 1,048,576 bytes). These are
single-threaded, in-memory calls, including output allocation, with no disk I/O.
They do not measure the streaming API or compare ZimSTD against libzstd.

The first three rows decode ZimSTD's own output. The weighted-printable and
16-value binary rows decode stored reference frames produced by zstd 1.5.7 at
levels 9 and 19, respectively; encoding always uses ZimSTD. This exercises entropy
decoding that the current encoder does not itself emit. Uniform random input
mostly uses raw blocks, so its high decode rate does not represent compressed
entropy-coded data. These small synthetic workloads fit in cache; performance
on larger files and other machines will vary.

Reproduce with the checked-in [benchmark](benchmarks/bench.nim):

```sh
nim c -d:release --mm:orc --path:src benchmarks/bench.nim
for run in 1 2 3 4 5; do ./benchmarks/bench 200; done
# Compare a different level (rounds, workload, phase, level):
./benchmarks/bench 200 all both 9
```

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
[comparison driver](benchmarks/compare.py). Run `python3 benchmarks/compare.py --help`
for options.

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
