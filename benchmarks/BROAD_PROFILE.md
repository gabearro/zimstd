# Broader macOS profiling — 2026-09-09

This pass optimizes shared codec costs while preserving the encoder's exact
output. The baseline is the already-optimized code at the start of this pass,
not the original implementation. No compression levels, match choices,
checksums, or bounds checks were weakened to improve a score.

## Results

Five paired runs per file, randomized file and before/after order. The figures
below are equal-weight geometric means of per-file median speed ratios, not
an aggregate dominated by the largest file.

| Dataset | Role | Files | Encoding speedup | Decoding speedup |
| --- | --- | ---: | ---: | ---: |
| large | Final held-out check | 3 | 1.121× | 1.310× |
| canterbury | Tuning/validation | 11 | 1.098× | 1.350× |
| silesia | Validation (see methodology) | 12 | 1.082× | 1.281× |

All 26 corpus files produced **byte-for-byte identical compressed output**
before and after, checked by direct comparison and independently decoded with
zstd 1.5.7. Per-input SHA-256 hashes and encoded sizes are retained in each
results directory's `manifest.json`. Decoder measurements use independent
zstd level-3 frames, not just frames emitted by this encoder.

## Changes

* Skip the bit-reader refill function when enough cached bits remain.
* Expand the small bit writer as a Nim template, retaining its checked operations.
* For blocks shorter than 1 KiB, clear a 2 KiB presence bitmap instead of the
  64 KiB position table. Both insertion paths update the bitmap; the full hash
  and original match choices are preserved. Larger blocks clear the positions.
* Remove padding from constant encoder tables: 20,352 → 13,248 bytes.
* Borrow raw literals directly from compressed input; entropy/RLE literals
  still use the bounded reusable buffer.
* Reserve the first output-producing frame's declared content size after
  checking output/window limits. This avoids geometric output reallocations.
  Unknown-size frames and subsequent concatenated frames retain growth as needed.

These changes are independent of filenames or corpus contents. The short-block
path changes initialization work, not compression search quality.

## Full-file throughput

Rates are MiB/s. Each cell reports baseline → optimized, followed by speedup.
`Encoded %` is this Nim encoder's output/input ratio, unchanged between versions.

### large

| File | Encoded % | Encode MiB/s | Speedup | Decode MiB/s | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| E.coli | 57.79 | 98.2 → 113.7 | 1.16× | 140.4 → 193.9 | 1.38× |
| bible.txt | 51.33 | 101.4 → 114.0 | 1.12× | 139.2 → 179.0 | 1.29× |
| world192.txt | 48.19 | 110.6 → 119.7 | 1.08× | 161.3 → 203.9 | 1.26× |

### canterbury

| File | Encoded % | Encode MiB/s | Speedup | Decode MiB/s | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| alice29.txt | 59.21 | 100.3 → 110.5 | 1.10× | 106.1 → 137.0 | 1.29× |
| asyoulik.txt | 62.13 | 96.1 → 106.6 | 1.11× | 107.4 → 138.1 | 1.29× |
| cp.html | 47.09 | 177.2 → 192.8 | 1.09× | 144.8 → 201.6 | 1.39× |
| fields.c | 43.43 | 163.4 → 182.7 | 1.12× | 127.6 → 181.5 | 1.42× |
| grammar.lsp | 47.51 | 167.1 → 185.8 | 1.11× | 114.7 → 161.9 | 1.41× |
| kennedy.xls | 37.53 | 190.4 → 211.5 | 1.11× | 158.0 → 225.2 | 1.42× |
| lcet10.txt | 55.84 | 99.8 → 111.3 | 1.11× | 127.0 → 161.3 | 1.27× |
| plrabn12.txt | 66.54 | 87.0 → 97.0 | 1.12× | 106.2 → 136.3 | 1.28× |
| ptt5 | 15.42 | 338.9 → 349.7 | 1.03× | 355.6 → 456.1 | 1.28× |
| sum | 46.86 | 164.5 → 176.0 | 1.07× | 141.8 → 195.9 | 1.38× |
| xargs.1 | 60.04 | 149.0 → 165.4 | 1.11× | 100.0 → 142.4 | 1.42× |

### silesia

| File | Encoded % | Encode MiB/s | Speedup | Decode MiB/s | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| dickens | 62.89 | 88.4 → 98.3 | 1.11× | 114.4 → 144.5 | 1.26× |
| mozilla | 48.42 | 137.9 → 148.3 | 1.08× | 148.4 → 192.4 | 1.30× |
| mr | 54.60 | 129.4 → 143.3 | 1.11× | 138.8 → 180.9 | 1.30× |
| nci | 17.11 | 274.0 → 295.8 | 1.08× | 355.0 → 465.3 | 1.31× |
| ooffice | 65.51 | 103.9 → 110.2 | 1.06× | 108.6 → 136.6 | 1.26× |
| osdb | 48.88 | 151.4 → 160.4 | 1.06× | 173.5 → 227.2 | 1.31× |
| reymont | 51.11 | 100.5 → 112.5 | 1.12× | 139.6 → 177.7 | 1.27× |
| samba | 35.69 | 164.6 → 180.2 | 1.09× | 221.8 → 282.6 | 1.27× |
| sao | 87.46 | 111.6 → 118.5 | 1.06× | 106.7 → 136.5 | 1.28× |
| webster | 48.42 | 107.5 → 117.6 | 1.09× | 137.5 → 173.1 | 1.26× |
| x-ray | 94.46 | 143.3 → 147.4 | 1.03× | 98.3 → 126.4 | 1.29× |
| xml | 23.50 | 203.9 → 222.0 | 1.09× | 306.2 → 386.5 | 1.26× |

## Short-message latency

Contiguous chunks from three Silesia files: text (`dickens`), source/archive
(`samba`), and binary astronomical data (`sao`). Each chunk is a separate frame;
all chunks are checked for exact encoder equality. These inputs were not used
for tuning the short-block path. Both sides of its 1 KiB boundary are included.
Five paired runs; median nanoseconds per compression call, checksum enabled.

| Chunk bytes | File | Before ns/call | After ns/call | Speedup |
| ---: | --- | ---: | ---: | ---: |
| 64 | dickens | 1557 | 475 | 3.28× |
| 64 | samba | 1775 | 532 | 3.34× |
| 64 | sao | 1355 | 348 | 3.89× |
| 256 | dickens | 3076 | 1956 | 1.57× |
| 256 | samba | 3026 | 1761 | 1.72× |
| 256 | sao | 2402 | 1374 | 1.75× |
| 1023 | dickens | 9373 | 8105 | 1.16× |
| 1023 | samba | 7458 | 5998 | 1.24× |
| 1023 | sao | 7167 | 6242 | 1.15× |
| 1024 | dickens | 9350 | 8925 | 1.05× |
| 1024 | samba | 7405 | 7050 | 1.05× |
| 1024 | sao | 7118 | 7045 | 1.01× |

## Memory

Measured separately with `memory.nim`: one codec call, no warm-up, no reference
round trips or expected-output copies in the measured process. Three fresh
processes per mode/version/file, randomized ordering. `/usr/bin/time -l` peak
RSS includes input, output, runtime and allocator overhead; it is not scratch
space alone. The printed output hash consumes all bytes.

| File | Encode RSS MiB before → after | Decode RSS MiB before → after | Decode reduction |
| --- | ---: | ---: | ---: |
| E.coli | 18.00 → 17.95 | 21.19 → 7.66 | 63.9% |
| bible.txt | 12.33 → 12.33 | 17.27 → 6.88 | 60.2% |
| dickens | 39.05 → 39.06 | 43.52 → 15.11 | 65.3% |
| mozilla | 147.45 → 147.47 | 238.47 → 68.34 | 71.3% |
| mr | 34.80 → 34.78 | 42.70 → 14.89 | 65.1% |
| nci | 50.58 → 50.56 | 112.36 → 36.59 | 67.4% |
| ooffice | 22.12 → 22.14 | 23.36 → 10.86 | 53.5% |
| osdb | 26.14 → 26.16 | 38.52 → 14.86 | 61.4% |
| reymont | 18.14 → 18.09 | 31.36 → 10.12 | 67.7% |
| samba | 53.64 → 53.62 | 71.47 → 27.23 | 61.9% |
| sao | 34.94 → 34.94 | 37.45 → 14.16 | 62.2% |
| webster | 114.64 → 114.64 | 166.64 → 53.00 | 68.2% |
| world192.txt | 9.03 → 9.02 | 10.81 → 4.89 | 54.8% |
| x-ray | 37.39 → 37.39 | 34.19 → 15.88 | 53.6% |
| xml | 12.09 → 12.08 | 21.66 → 7.64 | 64.7% |

Encoder process RSS is essentially unchanged; the bitmap adds 2 KiB of stack
scratch while constant tables shrink by 7,104 bytes. Borrowing raw literals
avoids up to 128 KiB of literal allocation/copy on that path. The large decoding
RSS savings above come primarily from avoiding geometric output-buffer growth
and allocator retention. They apply to these known-size frames, not every
possible Zstandard stream. The throughput CSVs also retain RSS, but that RSS
includes validation/setup allocations and is not used for the memory claims.

## Methodology and limitations

Apple M3 Max, arm64, Nim 2.2.6, ORC, checksums enabled, identical
`-d:release --debugger:native --lineDir:on` builds. See
[tool versions](results/broad/environment.txt). Native profiling used macOS
`sample`, five seconds at a requested 1 ms interval; Instruments/xctrace remains
unavailable because only Xcode Command Line Tools are installed.

The [Canterbury corpus](https://corpus.canterbury.ac.nz/descriptions/) supplied
11 tuning files. [Silesia](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia)
was initially held out. Its first frozen pass verified speed improvements, but
separate one-call memory measurements then exposed geometric output growth.
After fixing that general allocation issue, Silesia was treated as validation
data. The three Canterbury Large files were held out until the final freeze;
no library changes followed their results. First-freeze results are preserved
under `results/broad/freeze1/`, and the final
[source hashes](results/broad/frozen-code.json) still match the library.

The harness accepts arbitrary files. It reads inputs and verifies correctness
outside timed loops, then consumes returned output lengths in a printed sink.
Each full-file run processes at least about 32 MiB (minimum two iterations).
Five paired process runs randomize version and file order with fixed seeds.
No profiler, compilation or other task-owned CPU work runs during final timing
measurements. Final message measurements were rerun after all compilation.
Uncontrolled OS activity, caches, compiler and architecture can affect results;
these observations do not establish a universal optimum.

Profiles and raw data are under [results/broad](results/broad/). For example,
[small-message before](results/broad/before-small-encode.sample.txt) showed
2,499 top-of-stack `__bzero` samples; the
[after profile](results/broad/after-small-encode.sample.txt) no longer has that
64 KiB clearing bottleneck. The
[text decoder profiles](results/broad/after-text-decode.sample.txt) show fewer
refill calls on the shared cached-bit path. Sample counts are not exact time
percentages and different processes do different amounts of work.

## Validation

Passed [debug](results/broad/test-debug.txt) and
[release](results/broad/test-release.txt) regressions: 12 stored reference
vectors, malformed/truncated/limit cases, 2,000 corruption cases, byte/bitwise
oracles, and sparse/dense initialization boundaries. The corruption test's
window limit was corrected: it previously rejected its 8 MiB-window seed
before entropy decoding. It now first asserts the seed decodes successfully
under that limit before applying mutations.

All [126 CLI interoperability cases](results/broad/interop.txt) pass, as do the
26 public corpus files and all short-message configurations checked by the
comparison driver. Encoder outputs are directly compared byte-for-byte and
reference-decoded; compressed size was not traded away for speed.

## Reproduce

The [baseline sources](results/broad/before-src.tar.gz),
[library diff](results/broad/optimization.patch), inputs' SHA-256 manifests and
raw per-run CSVs are preserved. Corpora are kept outside the package; obtain the
archives from the official links above (Canterbury `cantrbry.tar.gz` and
`large.tar.gz`; Silesia `silesia.zip`). Extract only their regular data files
into separate directories. The comparison driver creates level-3 reference
frames using the local zstd CLI when missing.

```sh
mkdir -p /tmp/zstd-before
tar -xzf benchmarks/results/broad/before-src.tar.gz -C /tmp/zstd-before
sed 's/import zimstd/import zstd/g' benchmarks/corpus.nim > /tmp/zstd-before/corpus.nim
nim c -d:release --debugger:native --lineDir:on --path:/tmp/zstd-before/src -o:/tmp/zstd-before/corpus /tmp/zstd-before/corpus.nim
nim c -d:release --debugger:native --lineDir:on --path:src benchmarks/corpus.nim
python3 benchmarks/compare.py /tmp/zstd-before/corpus benchmarks/corpus /path/to/corpus /tmp/comparison
# Add --chunk 64 (or 256, 1023, 1024) for per-message encoding.

nim c -d:release --debugger:native --lineDir:on --path:src benchmarks/memory.nim
/usr/bin/time -l benchmarks/memory decode /path/to/file.zst
/usr/bin/time -l benchmarks/memory encode /path/to/file

# In one terminal:
benchmarks/corpus /path/to/file /path/to/file.zst 1000000 decode
# In another, using the PID of that benchmark:
sample <PID> 5 1 -mayDie -file decoder.sample.txt
```

`nimble bench` remains a small synthetic smoke benchmark. Use the file-based
harness and independent corpora for performance decisions.
