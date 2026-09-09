## File-based benchmark; accepts arbitrary corpora without codec special cases.
## Usage: corpus INPUT REFERENCE.zst ROUNDS PHASE [CHUNK_BYTES] [DUMP_PATH]
## PHASE is encode, decode, or both; CHUNK_BYTES only changes encode call size.
import std/[os, strutils, monotimes, times, strformat]
import zimstd
import zimstd/xxhash

doAssert paramCount() in 4..6, "corpus INPUT REFERENCE.zst ROUNDS PHASE [CHUNK_BYTES] [DUMP_PATH]"
let data = readFile(paramStr(1))
let reference = readFile(paramStr(2))
let rounds = parseInt(paramStr(3))
let phase = paramStr(4)
let chunk = if paramCount() >= 5: parseInt(paramStr(5)) else: max(1, data.len)
doAssert rounds > 0 and chunk > 0 and phase in ["encode", "decode", "both"]
doAssert decompress(reference) == data
var dump: File
if paramCount() == 6: dump = open(paramStr(6), fmWrite)
var encodedSize = 0
var fingerprint = 0'u64
var calls = 0
for p in countup(0, data.high, chunk):
  let stop = min(data.len, p+chunk)
  let encoded = compress(data.toOpenArray(p, stop-1))
  doAssert decompress(encoded) == data[p..<stop]
  if dump != nil: dump.write(encoded)
  encodedSize += encoded.len
  fingerprint = fingerprint xor xxh64(encoded)
  inc calls
if dump != nil: dump.close()
var sink = 0
let start = getMonoTime()
if phase != "decode":
  for iteration in 0..<rounds:
    for p in countup(0, data.high, chunk):
      sink += compress(data.toOpenArray(p, min(data.len, p+chunk)-1)).len
let middle = getMonoTime()
if phase != "encode":
  for iteration in 0..<rounds: sink += decompress(reference).len
let stop = getMonoTime()
let encNs = float((middle-start).inNanoseconds)
let decNs = float((stop-middle).inNanoseconds)
let mib = float(data.len*rounds)/(1024*1024)
let enc = if phase == "decode": 0.0 else: mib*1e9/encNs
let dec = if phase == "encode": 0.0 else: mib*1e9/decNs
let latency = if phase == "decode": 0.0 else: encNs/float(rounds*max(1,calls))
echo &"{data.len},{reference.len},{encodedSize},{chunk},{rounds},{enc:.3f},{dec:.3f},{latency:.1f},{fingerprint},{sink}"
