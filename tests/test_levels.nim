import std/[streams, strutils, random, os]
import zimstd

var levels = @[MinCompressionLevel, MinCompressionLevel+1, -10, -2, -1, 0]
for level in 1..MaxCompressionLevel: levels.add level
var rng = initRand(123)
var records: string
for i in 0..<3000:
  records.add "record=" & $rng.rand(100) & " hello repeated message type=" & $rng.rand(20) & " some longer words status=ok\n"
var noise = newString(131073)
for c in noise.mitems: c = char(rng.rand(255))
let binary = readFile(currentSourcePath.parentDir / "vectors" / "binary-19.raw")
for level in levels:
  for data in ["", "a", "abcd", repeat('x', 131073), repeat("ab", 512),
               records, noise, binary]:
    for checksum in [false, true]:
      let encoded = compress(data, checksum, level)
      doAssert decompress(encoded) == data, $level
      let output = newStringStream()
      compress(newStringStream(data), output, checksum, level)
      doAssert decompress(output.data) == data, "stream encoding " & $level
      let decoded = newStringStream()
      decompress(newStringStream(output.data), decoded)
      doAssert decoded.data == data
  for size in [3,7,31,32,255,256,1023,1024,1025]:
    let data = noise[0..<size]
    doAssert decompress(compress(data, level = level)) == data

# Compatibility and actual effort changes, rather than a level argument that
# accepts every number but always runs the same encoder.
doAssert DefaultCompressionLevel == 3
doAssert compress(records) == compress(records, level = 3)
doAssert compress(records, level = 0) == compress(records)
doAssert compress(records, false) == compress(records, checksum = false, level = 0)
doAssert compress(records, level = 22).len < compress(records, level = 9).len
doAssert compress(records, level = 9).len < compress(records, level = 3).len
doAssert compress(records, level = MinCompressionLevel).len > compress(records).len
let defaultStream = newStringStream()
let zeroStream = newStringStream()
compress(newStringStream(records), defaultStream)
compress(newStringStream(records), zeroStream, level = 0)
doAssert defaultStream.data == zeroStream.data

# Reject invalid levels before touching either stream, including int extremes.
for level in [low(int), MinCompressionLevel-1, MaxCompressionLevel+1, high(int)]:
  for data in ["", "hello"]:
    var rejected = false
    try: discard compress(data, level = level)
    except ZstdError: rejected = true
    doAssert rejected
    let input = newStringStream(data)
    let output = newStringStream()
    rejected = false
    try: compress(input, output, level = level)
    except ZstdError: rejected = true
    doAssert rejected and input.getPosition() == 0 and output.data.len == 0

echo "compression levels: range, aliases, effort, block boundaries, and both APIs passed"
