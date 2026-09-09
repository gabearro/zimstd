import std/[os, strutils, random, streams]
import zimstd
import zimstd/[xxhash, common]

doAssert xxh64("") == 0xef46db3751d8e999'u64
doAssert xxh64("a") == 0xd24ec4f1a98c6e5b'u64
doAssert xxh64("abc") == 0x44bc2cf5ad770999'u64
for source in ["", "a", "hello world", repeat('x', 300000), repeat("hello world\n", 11000)]:
  doAssert decompress(compress(source)) == source
  doAssert decompress(compress(source, false)) == source
var rng = initRand(1234)
for size in [31,32,255,256,4095,4096,65791,65792,131071,131072,131073,400000]:
  var source = newString(size)
  for c in source.mitems: c = char(rng.rand(255))
  doAssert decompress(compress(source)) == source
  for c in source.mitems: c = char(rng.rand(7)+65)
  doAssert decompress(compress(source)) == source
var vectorCount = 0
for path in walkFiles(currentSourcePath.parentDir / "vectors" / "*.zst"):
  inc vectorCount
  let expected = readFile(path.changeFileExt("raw"))
  doAssert decompress(readFile(path)) == expected, path
  echo "vector: ", path.extractFilename


doAssert vectorCount == 12, "missing reference vectors"

proc rejects(data: string, output = 256*1024*1024, window = 128*1024*1024) =
  var rejected = false
  try: discard decompress(data, output, window)
  except ZstdError: rejected = true
  doAssert rejected, "malformed input accepted"
  rejected = false
  try: decompress(newStringStream(data), newStringStream(), output, window)
  except ZstdError: rejected = true
  doAssert rejected, "malformed stream accepted"

proc frame(payload: string, size, kind: int): string =
  result.putLe(0xfd2fb528'u64, 4)
  result.add char(0x80)
  result.add char(56)
  result.putLe(uint64(size), 4)
  let stored = if kind == 1: size else: payload.len
  result.putLe(uint64((stored shl 3) or (kind shl 1) or 1), 3)
  result.add payload

# Hand-authored wire vectors independent of either encoder.
doAssert decompress("\x28\xb5\x2f\xfd\x20\x00\x01\x00\x00") == ""
doAssert decompress(frame("abc", 3, 0)) == "abc"
doAssert decompress(frame("z", 100, 1)) == repeat('z', 100)
doAssert decompress(frame("\x45\x06z\x00", 100, 2)) == repeat('z', 100) # RLE literals
let rawLiterals = "\x44\x06" & repeat('k', 100) & "\x00"
doAssert decompress(frame(rawLiterals, 100, 2)) == repeat('k', 100)
var skip: string
skip.putLe(0x184d2a5f, 4)
skip.putLe(3, 4)
skip.add "tag"
doAssert decompress(skip) == ""
doAssert decompress(skip & compress("a") & skip & compress("b")) == "ab"
rejects("")
rejects("not zstd")
rejects(skip[0..^2])
rejects(frame("", 0, 3))
rejects(frame("abc", 4, 0))
rejects(frame("abc", 2, 0))
rejects(frame("\x00\x01\xfc\x01", 100, 2)) # Missing repeat tables.
let small = compress(repeat("0123456789abcdef", 100))
for n in 0..<small.len: rejects(small[0..<n])
rejects(small & "x")
rejects(small, 1599)
rejects(small, 1600, 1599)
doAssert decompress(small, 1600, 1600) == repeat("0123456789abcdef", 100)
var bad = small
bad[^1] = char(ord(bad[^1]) xor 1)
rejects(bad)
bad = small
bad[4] = char(ord(bad[4]) or 8)
rejects(bad)
bad = "\x28\xb5\x2f\xfd\x21\x01\x00\x01\x00\x00" # Dictionary 1.
rejects(bad)
# Advertised sizes must not cause an allocation before limits are checked.
rejects("\x28\xb5\x2f\xfd\xe0" & repeat('\xff', 8))
rejects("\x28\xb5\x2f\xfd\x00\xff")

# Corruption need not always be detectable without checksums, but must never
# cause an IndexDefect/RangeDefect, hang, or exceed the configured output cap.
let seed = readFile(currentSourcePath.parentDir / "vectors" / "binary-19.zst")
const SeedWindow = 8*1024*1024
# Prove the seed reaches entropy decoding rather than failing its window limit.
doAssert decompress(seed, 200000, SeedWindow) ==
  readFile(currentSourcePath.parentDir / "vectors" / "binary-19.raw")
for trial in 0..<2000:
  var mutated = seed
  for edit in 0..rng.rand(3):
    let i = rng.rand(mutated.high)
    mutated[i] = char(rng.rand(255))
  try: discard decompress(mutated, 200000, SeedWindow)
  except ZstdError: discard
  try: decompress(newStringStream(mutated), newStringStream(), 200000, SeedWindow)
  except ZstdError: discard

echo "codec regressions and 2,000 corruption cases passed"

# Word loads and bulk reverse refills must agree with byte/bitwise oracles,
# including unaligned input and the last 0..3 bytes of a stream.
for offset in 0..15:
  var data = newString(24)
  for c in data.mitems: c = char(rng.rand(255))
  for width in 0..8:
    var expected = 0'u64
    for i in 0..<width: expected = expected or (uint64(ord(data[offset+i])) shl (8*i))
    var p = offset
    doAssert readLe(data, p, width) == expected
    doAssert p == offset+width
for size in 1..80:
  var data = newString(size+3)
  for c in data.mitems: c = char(rng.rand(255))
  data[^1] = char(1+rng.rand(254))
  var r = initReverse(data, 3, data.len)
  var left = (size-1)*8+floorLog(ord(data[^1]))
  doAssert r.take(data, 0) == 0
  while left > 0:
    let width = min(left, 1+rng.rand(30))
    left -= width
    var expected = 0
    for i in 0..<width:
      let bit = left+i
      expected = expected or (((ord(data[3+bit div 8]) shr (bit mod 8)) and 1) shl i)
    doAssert r.take(data, width) == expected
  doAssert r.finished
  var rejected = false
  try: discard r.take(data, 1)
  except ZstdError: rejected = true
  doAssert rejected

echo "unaligned word loads and bulk bit refills passed"

# Alternate sparse/dense hash-table initialization, including short final blocks.
for size in [3,4,63,64,127,255,256,511,512,1023,1024,1025,131072+63,131072+1023]:
  for alphabet in [3,15,255]:
    var source = newString(size)
    for c in source.mitems: c = char(rng.rand(alphabet))
    doAssert decompress(compress(source)) == source
# A raw literal block can borrow its input even after a Huffman-literal frame.
let huffFrame = readFile(currentSourcePath.parentDir / "vectors" / "huffman-9.zst")
let huffRaw = readFile(currentSourcePath.parentDir / "vectors" / "huffman-9.raw")
doAssert decompress(huffFrame & frame(rawLiterals, 100, 2)) == huffRaw & repeat('k', 100)
echo "sparse/dense block transitions and borrowed literals passed"
