## Configurable block-local LZ77 with a 64 KiB hash table and predefined FSE codes.
import common, xxhash
import std/[endians, streams]

type
  Sequence = object
    literal, match, offset: uint32
  BitWriter = object
    bytes: string
    bits: uint64
    count: int

template write(w: var BitWriter, value, n: int) =
  w.bits = w.bits or ((uint64(value) and mask(n)) shl w.count)
  w.count += n
  if w.count >= 32:
    let old = w.bytes.len
    w.bytes.setLen(old+4)
    var word = uint32(w.bits and 0xffffffff'u64)
    littleEndian32(addr w.bytes[old], addr word)
    w.bits = w.bits shr 32
    w.count -= 32

proc finish(w: var BitWriter) =
  w.write(1, 1)
  w.bytes.putLe(w.bits, (w.count+7) shr 3)

proc inverse[Symbols, States: static int](table: FseTable): array[Symbols, array[States, uint16]] =
  for i in 0..<1 shl table.log:
    let e = table.entries[i]
    for next in int(e.base)..<int(e.base)+(1 shl int(e.bits)):
      result[e.sym][next] = uint16(i or (int(e.bits) shl 6))
const
  EncodeLl = inverse[36, 64](DefaultLl)
  EncodeOf = inverse[29, 32](DefaultOf)
  EncodeMl = inverse[53, 64](DefaultMl)

proc symbol(value: int, bases: openArray[int]): int {.inline.} =
  # Tiny length tables; binary search avoids scans for long matches.
  if value < bases[16]: return value-bases[0]
  var lo = 0
  var hi = bases.len
  while lo+1 < hi:
    let mid = (lo+hi) shr 1
    if bases[mid] <= value: lo = mid
    else: hi = mid
  lo

proc transition(w: var BitWriter, state: var int, entry: uint16) {.inline.} =
  w.write(state, int(entry shr 6))
  state = int(entry and 63)

proc encodeSequences(dst: var string, sequences: seq[Sequence]) =
  var w = BitWriter(bytes: move(dst))
  let n = sequences.len
  if n < 128: w.bytes.add char(n)
  elif n < 0x7f00:
    w.bytes.add char((n shr 8)+128)
    w.bytes.add char(n and 255)
  else:
    w.bytes.add char(255)
    w.bytes.putLe(uint64(n-0x7f00), 2)
  if n == 0:
    dst = move(w.bytes)
    return
  if n == 1:
    let s = sequences[0]
    let lc = symbol(int(s.literal), LlBase)
    let mc = symbol(int(s.match), MlBase)
    let off = int(s.offset)+3
    let oc = floorLog(off)
    w.bytes.add char(0x54) # One sequence needs only RLE symbols, no FSE states.
    w.bytes.add char(lc)
    w.bytes.add char(oc)
    w.bytes.add char(mc)
    w.write(int(s.literal)-LlBase[lc], LlBits[lc])
    w.write(int(s.match)-MlBase[mc], MlBits[mc])
    w.write(off-(1 shl oc), oc)
    w.finish()
    dst = move(w.bytes)
    return
  w.bytes.add char(0) # All three FSE tables use the predefined distribution.
  var ls, os, ms: int
  for i in countdown(n-1, 0):
    let s = sequences[i]
    let ll = int(s.literal)
    let ml = int(s.match)
    let off = int(s.offset)+3
    let lc = symbol(ll, LlBase)
    let mc = symbol(ml, MlBase)
    let oc = floorLog(off)
    if i == n-1:
      ls = int(EncodeLl[lc][0] and 63)
      os = int(EncodeOf[oc][0] and 63)
      ms = int(EncodeMl[mc][0] and 63)
    else:
      w.transition(os, EncodeOf[oc][os])
      w.transition(ms, EncodeMl[mc][ms])
      w.transition(ls, EncodeLl[lc][ls])
    w.write(ll-LlBase[lc], LlBits[lc])
    w.write(ml-MlBase[mc], MlBits[mc])
    w.write(off-(1 shl oc), oc)
  w.write(ms, 6)
  w.write(os, 5)
  w.write(ls, 6)
  w.finish()
  dst = move(w.bytes)

proc word(data: openArray[char], p: int): uint32 {.inline.} =
  copyMem(addr result, unsafeAddr data[p], 4)
proc hash(v: uint32): int {.inline.} = int((v*2654435761'u32) shr 18)

proc literalsHeader(dst: var string, size: int) =
  if size < 32: dst.add char(size shl 3)
  elif size < 4096: dst.putLe(uint64((size shl 4) or 4), 2)
  else: dst.putLe(uint64((size shl 4) or 12), 3)

proc addBlock(dst: var string, data: openArray[char], kind, last: int) =
  let old = dst.len
  dst.setLen(old+3+data.len)
  let header = (data.len shl 3) or (kind shl 1) or last
  for i in 0..2: dst[old+i] = char((header shr (8*i)) and 255)
  if data.len > 0: copyMem(addr dst[old+3], unsafeAddr data[0], data.len)

const
  MinCompressionLevel* = -131072
  DefaultCompressionLevel* = 3
  MaxCompressionLevel* = 22

proc compressionLevel(level: int): int =
  require(level >= MinCompressionLevel and level <= MaxCompressionLevel,
          "compression level must be between -131072 and 22")
  if level == 0: DefaultCompressionLevel else: level

proc matchLength(data: openArray[char], p, prev: int): int {.inline.} =
  result = 4 # Caller checked the first four bytes.
  while p+result+8 <= data.len:
    var a, b: uint64
    copyMem(addr a, unsafeAddr data[p+result], 8)
    copyMem(addr b, unsafeAddr data[prev+result], 8)
    if a != b: break
    result += 8
  while p+result < data.len and data[p+result] == data[prev+result]: inc result

type EncodeScratch = object
  chain: seq[uint32]
  sequences: seq[Sequence]
  literals: string

proc bestMatch(scratch: EncodeScratch, data: openArray[char], p, head, depth: int): tuple[pos, length: int] =
  var candidate = head
  var attempts = 0
  let value = word(data, p)
  while candidate >= 0 and attempts < depth:
    if word(data, candidate) == value:
      let length = matchLength(data, p, candidate)
      if length > result.length:
        result = (candidate, length)
        if p+length == data.len: break
    candidate = int(scratch.chain[candidate])-1
    inc attempts

proc encodeBlock(scratch: var EncodeScratch, data: openArray[char],
                 result: var string, last, level: int, deep: static bool) =
  # Loads use initialized presence bits or a full position-table clear below.
  var table {.noinit.}: array[16384, uint32]
  var seen {.noinit.}: array[256, uint64]
  const start = 0
  let stop = data.len
  let size = stop
  when deep:
    # ponytail: bounded hash chains, not libzstd's optimal parser; add optimal
    # parsing/adaptive entropy if matching libzstd's high-level ratios is needed.
    const depths = [2,3,4,6,8,12,16,24,32,48,64,96,128,192,256,384,512,768,1024]
    let depth = depths[level-4]
    scratch.chain.setLen(size)
  else:
    let acceleration = if level < 0: -level else: 1
    let skipShift = if level < 0: 4 elif level == 1: 5 elif level == 2: 6 else: 7
  var run = size > 0
  for i in start+1..<stop:
    if data[i] != data[start]:
      run = false
      break
  if run:
    result.putLe(uint64((size shl 3) or 2 or last), 3)
    result.add data[start]
  else:
    # Preserve the full hash and match choices for short messages, while
    # clearing 2 KiB of presence bits instead of 64 KiB of positions.
    let sparse = not deep and size < 1024
    if sparse: zeroMem(addr seen[0], sizeof(seen))
    else: zeroMem(addr table[0], sizeof(table))
    template replaceSlot(h, position: int): uint32 =
      block:
        let index = h
        var previous = 0'u32
        if sparse:
          let bit = 1'u64 shl (index and 63)
          if (seen[index shr 6] and bit) != 0: previous = table[index]
          seen[index shr 6] = seen[index shr 6] or bit
        else: previous = table[index]
        table[index] = uint32(position)
        when deep: scratch.chain[position-1] = previous
        previous
    scratch.sequences.setLen(0)
    scratch.literals.setLen(0)
    var anchor = start
    var p = start
    var misses = 0
    while p+4 <= stop:
      let v = word(data, p)
      let h = hash(v)
      var prev = start+int(replaceSlot(h, p-start+1))-1
      var length = 0
      when deep:
        let best = scratch.bestMatch(data, p, prev, depth)
        prev = best.pos
        length = best.length
        if level >= 6 and length >= 4 and p+4 < stop:
          let next = scratch.bestMatch(data, p+1, int(table[hash(word(data, p+1))])-1, depth)
          if next.length > length+1:
            inc p
            continue
      else:
        if prev >= start and word(data, prev) == v:
          length = matchLength(data, p, prev)
      if length >= 4:
        let old = scratch.literals.len
        scratch.literals.setLen(old+p-anchor)
        if p > anchor: copyMem(addr scratch.literals[old], unsafeAddr data[anchor], p-anchor)
        scratch.sequences.add Sequence(literal: uint32(p-anchor), match: uint32(length), offset: uint32(p-prev))
        when deep:
          for position in p+1..min(p+length-1, stop-4):
            discard replaceSlot(hash(word(data, position)), position+1)
        p += length
        anchor = p
        misses = 0
        when not deep:
          if p >= start+2 and p+2 <= stop: discard replaceSlot(hash(word(data, p-2)), p-start-1)
      else:
        inc misses
        when deep: inc p
        else: p += acceleration+(misses shr skipShift)
    var encoded: string
    if scratch.sequences.len > 0:
      let old = scratch.literals.len
      scratch.literals.setLen(old+stop-anchor)
      if stop > anchor: copyMem(addr scratch.literals[old], unsafeAddr data[anchor], stop-anchor)
      encoded.literalsHeader(scratch.literals.len)
      encoded.add scratch.literals
      encoded.encodeSequences(scratch.sequences)
    if scratch.sequences.len > 0 and encoded.len < size:
      result.addBlock(encoded, 2, last)
    else:
      result.addBlock(data.toOpenArray(start, stop-1), 0, last)

proc encodeBlock(scratch: var EncodeScratch, data: openArray[char],
                 output: var string, last, level: int) =
  if level > 3: scratch.encodeBlock(data, output, last, level, true)
  else: scratch.encodeBlock(data, output, last, level, false)

proc compress*(data: openArray[char], checksum = true, level = DefaultCompressionLevel): string =
  ## Produce standard Zstandard frames. Memory is bounded by one 128 KiB
  ## block plus match scratch and the returned string; input is never copied.
  ## Levels -131072..22 control effort; 0 selects the default (3).
  ## Levels above 3 use up to 512 KiB of additional match-chain scratch.
  let selectedLevel = compressionLevel(level)
  result = newStringOfCap(min(data.len, 256)+32)
  result.putLe(0xfd2fb528'u64, 4)
  let check = if checksum: 4 else: 0
  if data.len < 256:
    result.add char(32 or check)
    result.putLe(uint64(data.len), 1)
  elif data.len < 65792:
    result.add char(96 or check)
    result.putLe(uint64(data.len-256), 2)
  elif uint64(data.len) <= 0xffffffff'u64:
    # Explicit 128 KiB window even for large inputs.
    result.add char(128 or check)
    result.add char(56)
    result.putLe(uint64(data.len), 4)
  else:
    result.add char(192 or check)
    result.add char(56)
    result.putLe(uint64(data.len), 8)
  var scratch: EncodeScratch
  var start = 0
  while true:
    let stop = start+min(data.len-start, BlockSize)
    scratch.encodeBlock(data.toOpenArray(start, stop-1), result, ord(stop == data.len), selectedLevel)
    if stop == data.len: break
    start = stop
  if checksum: result.putLe(xxh64(data) and 0xffffffff'u64, 4)

proc compress*(input, output: Stream, checksum = true, level = DefaultCompressionLevel) =
  ## Encode one unknown-content-size frame, buffering at most one input block.
  ## Levels -131072..22 control effort; 0 selects the default (3).
  ## Streams are neither closed nor flushed. I/O errors propagate to the caller.
  require(input != nil and output != nil and input != output, "distinct non-nil streams required")
  let selectedLevel = compressionLevel(level)
  var header: string
  header.putLe(0xfd2fb528'u64, 4)
  header.add char(if checksum: 4 else: 0)
  header.add char(56) # 128 KiB window; content size is unknown.
  output.write(header)
  var scratch: EncodeScratch
  var hash = initXxh64()
  while true:
    let data = input.readChunk(BlockSize)
    if data.len == 0: break
    var encoded: string
    scratch.encodeBlock(data, encoded, 0, selectedLevel)
    if checksum: hash.update(data)
    output.write(encoded)
  var trailer: string
  trailer.putLe(1, 3) # Empty final raw block, including for empty input.
  if checksum: trailer.putLe(hash.digest and 0xffffffff'u64, 4)
  output.write(trailer)
