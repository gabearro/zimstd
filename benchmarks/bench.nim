import std/[monotimes, times, strutils, random, strformat, os]
import zimstd
var rng = initRand(8878)
var noise = newString(1024*1024)
for c in noise.mitems: c = char(rng.rand(255))
var text: string
for i in 0..<22000: text.add "record=" & $i & " status=ok common words and repeated values\n"
let rounds = if paramCount() > 0: parseInt(paramStr(1)) else: 200
let workload = if paramCount() > 1: paramStr(2) else: "all"
let phase = if paramCount() > 2: paramStr(3) else: "both"
doAssert rounds > 0 and phase in ["both", "encode", "decode"]
let vectors = currentSourcePath.parentDir.parentDir / "tests" / "vectors"
for pair in [("repeated", repeat("abcdefgh12345678", 65536)), ("records", text), ("random", noise),
             ("huffman", readFile(vectors / "huffman-9.raw")),
             ("binary", readFile(vectors / "binary-19.raw"))]:
  let (name, source) = pair
  if workload != "all" and name != workload: continue
  let beforeMemory = getOccupiedMem()
  let packed = case name
               of "huffman": readFile(vectors / "huffman-9.zst")
               of "binary": readFile(vectors / "binary-19.zst")
               else: compress(source)
  let retained = getOccupiedMem()-beforeMemory
  doAssert decompress(packed) == source
  var sink = 0
  let start = getMonoTime()
  if phase != "decode":
    for i in 0..<rounds: sink += compress(source).len
  let mid = getMonoTime()
  if phase != "encode":
    for i in 0..<rounds: sink += decompress(packed).len
  let stop = getMonoTime()
  let mib = float(source.len*rounds)/(1024*1024)
  let enc = if phase == "decode": 0.0 else: mib/(float((mid-start).inNanoseconds)/1e9)
  let dec = if phase == "encode": 0.0 else: mib/(float((stop-mid).inNanoseconds)/1e9)
  echo &"{name:8} {source.len:8} -> {packed.len:8} bytes  retained {retained:8}  encode {enc:8.1f} MiB/s  decode {dec:8.1f} MiB/s  [{sink}]"
