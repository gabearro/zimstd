import std/[streams, os, strutils, random]
import zimstd
import zimstd/[common, xxhash]

# Forward-only source: deliberately no seek, peek, atEnd, or readAll support.
type ShortStream = ref object of StreamObj
  data: string
  pos, chunk: int
  broken: bool
proc shortRead(s: Stream, buffer: pointer, size: int): int =
  let input = ShortStream(s)
  if input.broken: raise newException(IOError, "read failed")
  doAssert size <= BlockSize
  result = min(size, min(input.chunk, input.data.len-input.pos))
  if result > 0: copyMem(buffer, addr input.data[input.pos], result)
  input.pos += result
proc source(data: string, chunk = 7): ShortStream =
  ShortStream(data: data, chunk: chunk, readDataImpl: shortRead)
proc packed(data: string, chunk: int, checksum = true): string =
  let output = newStringStream()
  compress(source(data, chunk), output, checksum)
  output.data
proc unpacked(data: string, chunk = 7, limit = 256*1024*1024,
              window = 128*1024*1024): string =
  let output = newStringStream()
  decompress(source(data, chunk), output, limit, window)
  output.data
proc rejects(data: string, limit = 256*1024*1024, window = 128*1024*1024) =
  var rejected = false
  try: discard unpacked(data, 1, limit, window)
  except ZstdError: rejected = true
  doAssert rejected

var rng = initRand(8878)
for size in [0,1,31,32,33,255,256,1023,1024,131071,131072,131073,800000]:
  var data = newString(size)
  for c in data.mitems: c = char(rng.rand(255))
  for chunk in [1,31,32,33,131072]:
    var hash = initXxh64()
    var pos = 0
    while pos < data.len:
      let stop = min(data.len, pos+chunk)
      hash.update(data.toOpenArray(pos, stop-1))
      pos = stop
    hash.update("")
    doAssert hash.digest == xxh64(data)
    hash.update("abc") # Finalization does not consume state.
    doAssert hash.digest == xxh64(data & "abc")
    let frame = packed(data, chunk)
    doAssert decompress(frame) == data
    doAssert unpacked(frame, chunk) == data
  doAssert unpacked(compress(data)) == data
  doAssert unpacked(packed(data, 13, false)) == data
for data in [repeat('z', 900000), repeat("repeated words\x00", 70000)]:
  doAssert unpacked(packed(data, 19), 11) == data
for path in walkFiles(currentSourcePath.parentDir / "vectors" / "*.zst"):
  let data = readFile(path)
  doAssert unpacked(data, 1) == readFile(path.changeFileExt("raw")), path

var skip: string
skip.putLe(0x184d2a50, 4)
skip.putLe(uint64(BlockSize+3), 4)
skip.add repeat('x', BlockSize+3)
doAssert unpacked(skip) == ""
doAssert unpacked(packed("a", 1) & skip & compress("b")) == "ab"
doAssert unpacked(packed("", 1), limit = 0) == ""
rejects("")
rejects("not a frame")
rejects(skip[0..^2])
let frame = packed(repeat("hello", 100), 7)
for n in 0..<frame.len: rejects(frame[0..<n])
rejects(frame & "x")
rejects(frame, 499)
rejects(frame, window = BlockSize-1)
rejects(frame & frame, 999)
rejects(frame, -1)
rejects(frame, window = -1)
doAssert unpacked(frame & frame, limit = 1000) == repeat("hello", 200)
var bad = frame
bad[^1] = char(ord(bad[^1]) xor 1)
rejects(bad)
rejects("\x28\xb5\x2f\xfd\xe0" & repeat('\xff', 8))
rejects("\x28\xb5\x2f\xfd\x00\xff")
rejects("\x28\xb5\x2f\xfd\x21\x01\x00\x01\x00\x00")
# Checksums fail after output has been delivered: callers must treat it as partial.
let partial = newStringStream()
try:
  decompress(source(bad), partial)
  doAssert false
except ZstdError: doAssert partial.data == repeat("hello", 100)

# Output must start before EOF, with bounded writes and no output accumulation.
type Sink = ref object of StreamObj
  input: ShortStream
  written, firstWriteAt: int
  broken: bool
proc sinkWrite(s: Stream, buffer: pointer, size: int) =
  let output = Sink(s)
  if output.broken: raise newException(IOError, "write failed")
  if output.written == 0: output.firstWriteAt = output.input.pos
  doAssert size <= BlockSize+3
  output.written += size
let large = repeat("abcdefgh", 1000000)
doAssert unpacked(compress(large) & compress("tail")) == large & "tail"
let input = source(large, 97)
let sink = Sink(input: input, writeDataImpl: sinkWrite)
compress(input, sink)
doAssert sink.written > 0 and sink.firstWriteAt < large.len
let decodeInput = source(packed(large, 131072), 17)
let decodeSink = Sink(input: decodeInput, writeDataImpl: sinkWrite)
decompress(decodeInput, decodeSink, maxOutput = large.len)
doAssert decodeSink.written == large.len
doAssert decodeSink.firstWriteAt < decodeInput.data.len
for encoding in [false, true]:
  let input = source(frame)
  input.broken = true
  try:
    if encoding: compress(input, newStringStream())
    else: decompress(input, newStringStream())
    doAssert false
  except IOError: discard
  let output = Sink(broken: true, writeDataImpl: sinkWrite)
  try:
    if encoding: compress(source("hello"), output)
    else: decompress(source(frame), output)
    doAssert false
  except IOError: discard
  let same = newStringStream(frame)
  try:
    if encoding: compress(same, same)
    else: decompress(same, same)
    doAssert false
  except ZstdError: discard

echo "streaming: short reads, vectors, checksums, limits, incremental output, and I/O errors passed"
