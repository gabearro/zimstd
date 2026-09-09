Stored reference vectors, with byte-for-byte `.raw` expected output. Tests do
not regenerate their oracle using this implementation.

* `1890a371.gettysburg.txt-100x.zst`, `f2a8e35c.helloworld-11000x.zst`, and
  `fcf30b99.zero-dictionary-ids.zst` come from Go's `src/internal/zstd/testdata`
  (Copyright 2023 The Go Authors, BSD-3-Clause, repository root LICENSE).
  https://go.googlesource.com/go/+/refs/heads/master/src/internal/zstd/testdata/
  Their filename prefixes are the first eight hexadecimal SHA-256 digits of
  the expected output. Expected bytes were independently extracted by zstd 1.5.7.
* `binary-*`, `huffman-*`, and `multiblock-*` were generated using zstd 1.5.7 at
  levels 1, 9, and 19, with content checksums enabled. Their expected byte files
  are the original inputs. `../generate_vectors.py` reproduces these fixtures.
  These exercise entropy-coded literals and sequences, small-alphabet binary
  data, and history across multiple blocks. The level-19 binary case also
  guards against incorrectly overwriting repeat-offset history.
* Hand-authored empty/raw/RLE/literal/skippable/malformed frames are embedded in
  `../test_zimstd.nim`, along with deterministic random and boundary regressions.

The optional interoperability test produces additional inputs independently of
these fixtures and compares against the reference CLI at levels 1, 3, 9, 19.
