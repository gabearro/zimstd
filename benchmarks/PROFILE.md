# macOS profiling and optimization — 2026-09-09

Implemented bounded 32/64-bit little-endian reads, 32-bit reverse-bitstream
refills, 32-bit encoder bitstream flushes, direct short-length code lookup,
and sequence writing into the existing block buffer. Incompressible blocks
no longer allocate/copy a redundant literal buffer. Output starts with a small
capacity; block headers and payloads grow it together to avoid a second
allocation caused by a header crossing capacity.

Full Xcode is **not installed** on this host. Both `xcrun xctrace` and
`/usr/bin/xctrace` failed: the active developer directory is
`/Library/Developer/CommandLineTools`. No Instruments trace was captured.
Instead, these results use Apple's macOS `sample` stack profiler and
`/usr/bin/time -l`, with native symbols generated using the installed Xcode
Command Line Tools. No machine settings were changed.

## Method

Apple M3 Max, arm64, Nim 2.2.6, ORC, checksums enabled. Both versions were built
with identical `-d:release --debugger:native --lineDir:on` flags. Bounds,
overflow, and range checks remain enabled. Five alternating baseline/optimized
process pairs, 200 compression and decompression iterations per workload;
medians below. Timed runs were separate from profiling. Data setup and the
initial correctness check are outside the timed loops. Profile sessions lasted
five seconds with a requested 1 ms sampling interval.

The same expanded benchmark harness was used for both versions. `huffman` and
`binary` decode the stored reference zstd level-9/19 vectors; their encode
measurements use the original data with the Nim encoder. The displayed packed
size for these two cases describes the reference input to the decoder, not the
Nim encoder output. Other workloads decode the Nim encoder's output. Performance
is workload-dependent; these measurements do not establish a universal maximum.

## Throughput (MiB/s)

| Workload | Encode before | Encode after | Speedup | Decode before | Decode after | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| repeated | 898.7 | 2402.0 | 2.67× | 955.9 | 4034.4 | 4.22× |
| records | 428.1 | 718.6 | 1.68× | 501.1 | 722.1 | 1.44× |
| random | 824.7 | 2469.9 | 2.99× | 966.7 | 4239.0 | 4.39× |
| huffman | 811.9 | 2506.4 | 3.09× | 128.1 | 144.1 | 1.12× |
| binary | 78.5 | 108.9 | 1.39× | 145.4 | 154.3 | 1.06× |

## Memory

Retained allocator bytes immediately after compression (`getOccupiedMem`
delta, including output capacity/alignment, excluding freed temporary buffers):

| Workload | Before | After |
| --- | ---: | ---: |
| repeated | 135,168 | 304 |
| records | 135,168 | 163,840 |
| random | 1,343,488 | 1,343,488 |

The 238-byte repeated-data result retains 304 rather than 135,168 allocator
bytes (99.8% less). Record-output capacity increases by 28 KiB due to geometric
string growth; random-output capacity is unchanged. Overall benchmark median
peak RSS is 22.33 → 22.25 MiB, essentially unchanged.
RSS includes runtime, all benchmark inputs, outputs, and allocator caches;
it is not an isolated per-call scratch measurement. The implementation removes
two intermediate sequence/bitstream result buffers and avoids the eager
128 KiB literal allocation, without adding persistent state or dependencies.

## Profiles and retained changes

The baseline random encoder's top-of-stack samples were dominated by `readLe`
(2,853 samples). That bytewise helper disappears from the optimized hot-stack
summary; checksum mixing and match finding now dominate. The records profile
also identified sequence bit writing as a hotspot, motivating word-sized
flushes. Huffman decoding remains the main entropy-decoding hotspot. A tested
four-stream interleaving rewrite reduced throughput and was reverted.

Sample counts are statistical observations, not exact wall-clock percentages;
separate processes do different amounts of work in the same sample interval.
The initial baseline encoding profiles used `both` with 100,000 iterations;
sampling occurred in the encoding loop (apart from setup samples). Optimized
profiles explicitly used `encode`. The Huffman profiles both used `decode`.

Raw profiles: [records before](results/before-records.sample.txt) /
[after](results/after-records.sample.txt),
[random before](results/before-random.sample.txt) /
[after](results/after-random.sample.txt),
[Huffman before](results/before-huffman.sample.txt) /
[after](results/after-huffman.sample.txt).
Five paired timing/RSS logs and the [library patch](results/optimization.patch)
are retained in `results/`.

## Reproduce

```sh
nim c -d:release --debugger:native --lineDir:on --path:src benchmarks/bench.nim
/usr/bin/time -l benchmarks/bench 200
# In one terminal; choose records, random, huffman, binary, or repeated:
benchmarks/bench 100000 records encode
# In another terminal, using that benchmark's PID:
sample <PID> 5 1 -mayDie -file records.sample.txt
```

Use `decode` to isolate decoding; `both` is the default. Benchmark outputs are
consumed through a printed accumulator. The built-in regression suite includes
unaligned word-load and bulk-refill checks against byte/bitwise oracles.

## Validation

Passed [debug regressions](results/test-debug.txt) and
[release regressions](results/test-release.txt): 12 stored reference vectors,
2,000 corruption cases, size-limit/truncation cases, and the new unaligned-load
and reverse-refill checks. All [126 reference interoperability cases](results/interop.txt)
and [Nimble package validation](results/package-check.txt) also passed.
