## Internal wire primitives and entropy tables. Pure Nim; no foreign codec.
## FSE/Huffman decoding follows Go internal/zstd (BSD-3-Clause, see LICENSE).
import std/[bitops, endians, streams]

type
  ZstdError* = object of CatchableError
  FseEntry* = object
    base*: uint16
    sym*, bits*: uint8
  FseTable* = object
    entries*: array[512, FseEntry]
    log*: int
    valid*: bool
  ReverseBits* = object
    pos*, start*, count*: int
    bits*: uint64

const BlockSize* = 128 * 1024

proc fail*(message: string) {.noinline, noreturn.} =
  raise newException(ZstdError, message)

template require*(condition: bool, message: string) =
  if not condition: fail(message)

proc floorLog*(x: int): int {.inline.} = 63 - countLeadingZeroBits(uint64(x))
proc mask*(n: int): uint64 {.inline.} = (1'u64 shl n) - 1

proc readLe*(data: openArray[char], pos: var int, n: int): uint64 {.inline.} =
  require(pos >= 0 and n >= 0 and n <= data.len - pos, "truncated input")
  case n
  of 8: littleEndian64(addr result, unsafeAddr data[pos])
  of 4:
    var v: uint32
    littleEndian32(addr v, unsafeAddr data[pos])
    result = uint64(v)
  else:
    for i in 0..<n: result = result or (uint64(ord(data[pos+i])) shl (8*i))
  pos += n

proc putLe*(dst: var string, x: uint64, n: int) {.inline.} =
  for i in 0..<n: dst.add char((x shr (8*i)) and 255)

proc initReverse*(data: openArray[char], start, stop: int): ReverseBits =
  require(start >= 0 and stop > start and stop <= data.len, "empty bitstream")
  let last = ord(data[stop-1])
  require(last != 0, "missing bitstream end marker")
  result = ReverseBits(pos: stop-1, start: start, count: floorLog(last), bits: uint64(last))

## Templates keep these checked hot paths inline even when the C compiler
## declines to inline the equivalent procedures.
## FSE take() benefits from the direct load; Huffman fetch() is faster through
## readLe on the measured ARM64 builds.
template fetch*(r: var ReverseBits, data: openArray[char], n: int,
                direct: static bool = false): bool =
  block:
    let needed = n
    # Callers request at most 31 bits; a 32-bit refill fits the 64-bit cache.
    if r.count < needed and r.pos-r.start >= 4:
      when direct:
        var word: uint32
        littleEndian32(addr word, unsafeAddr data[r.pos-4])
        r.bits = (r.bits shl 32) or uint64(word)
      else:
        var p = r.pos-4
        r.bits = (r.bits shl 32) or readLe(data, p, 4)
      r.pos -= 4
      r.count += 32
    while r.count < needed and r.pos > r.start:
      dec r.pos
      r.bits = (r.bits shl 8) or uint64(ord(data[r.pos]))
      r.count += 8
    r.count >= needed

template take*(r: var ReverseBits, data: openArray[char], n: int): int =
  block:
    let width = n
    if r.count < width: require(r.fetch(data, width, true), "truncated bitstream")
    r.count -= width
    int((r.bits shr r.count) and mask(width))

proc finished*(r: ReverseBits): bool {.inline.} = r.pos == r.start and r.count == 0

proc buildFse*(norm: openArray[int], log: int): FseTable =
  result.log = log
  result.valid = true
  let size = 1 shl log
  var high = size-1
  var next: array[256, int]
  var total = 0
  for sym, n in norm:
    require(n >= -1, "invalid FSE count")
    total += abs(n)
    if n == -1:
      require(high >= 0, "FSE count overflow")
      result.entries[high].sym = uint8(sym)
      dec high
      next[sym] = 1
    else: next[sym] = n
  require(total == size, "invalid FSE total")
  var pos = 0
  let step = (size shr 1) + (size shr 3) + 3
  for sym, n in norm:
    for j in 0..<n:
      result.entries[pos].sym = uint8(sym)
      pos = (pos+step) and (size-1)
      while pos > high: pos = (pos+step) and (size-1)
  require(pos == 0, "invalid FSE spread")
  for i in 0..<size:
    let sym = int(result.entries[i].sym)
    let state = next[sym]
    inc next[sym]
    require(state > 0, "invalid FSE state")
    let nb = log-floorLog(state)
    result.entries[i].bits = uint8(nb)
    result.entries[i].base = uint16((state shl nb)-size)

proc forward(data: openArray[char], bit: int, n: int): int {.inline.} =
  require(bit >= 0 and n <= data.len*8-bit, "truncated FSE table")
  var p = bit shr 3
  let count = (n+(bit and 7)+7) shr 3
  let v = readLe(data, p, count)
  int((v shr (bit and 7)) and mask(n))

proc readFse*(data: openArray[char], pos: var int, maxSym, maxLog: int): FseTable =
  var bit = pos*8
  let log = forward(data, bit, 4)+5
  bit += 4
  require(log <= maxLog, "FSE accuracy log too large")
  var remaining = (1 shl log)+1
  var threshold = 1 shl log
  var needed = log+1
  var sym = 0
  var prevZero = false
  var norm: array[256, int]
  while remaining > 1 and sym <= maxSym:
    if prevZero:
      var skip: int
      while true:
        skip = forward(data, bit, 2)
        bit += 2
        sym += skip
        require(sym <= maxSym, "FSE zero run overflow")
        if skip != 3: break
      prevZero = false
      continue
    let small = (2*threshold-1)-remaining
    var count = forward(data, bit, needed-1)
    if count < small: bit += needed-1
    else:
      count = forward(data, bit, needed)
      bit += needed
      if count >= threshold: count -= small
    dec count
    remaining -= abs(count)
    require(remaining >= 1, "FSE probability overflow")
    norm[sym] = count
    inc sym
    prevZero = count == 0
    while remaining < threshold:
      dec needed
      threshold = threshold shr 1
  require(remaining == 1, "incomplete FSE table")
  pos = (bit+7) shr 3
  result = buildFse(norm.toOpenArray(0, maxSym), log)

const
  LlBase* = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,18,20,22,24,28,32,40,48,64,128,256,512,1024,2048,4096,8192,16384,32768,65536]
  LlBits* = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,3,3,4,6,7,8,9,10,11,12,13,14,15,16]
  MlBase* = [3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,37,39,41,43,47,51,59,67,83,99,131,259,515,1027,2051,4099,8195,16387,32771,65539]
  MlBits* = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,3,3,4,4,5,7,8,9,10,11,12,13,14,15,16]
  DefaultLl* = buildFse([4,3,2,2,2,2,2,2,2,2,2,2,2,1,1,1,2,2,2,2,2,2,2,2,2,3,2,1,1,1,1,1,-1,-1,-1,-1], 6)
  DefaultOf* = buildFse([1,1,1,1,1,1,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1], 5)
  DefaultMl* = buildFse([1,4,3,2,2,2,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1,-1,-1], 6)

proc readChunk*(input: Stream, size: int, exact = false): string =
  ## Blocking streams may return short reads; only zero means EOF.
  result = newString(size)
  var count = 0
  while count < size:
    let n = input.readData(addr result[count], size-count)
    if n == 0: break
    if n < 0 or n > size-count:
      raise newException(IOError, "invalid stream read count")
    count += n
  require(not exact or count == size, "truncated input")
  result.setLen(count)
