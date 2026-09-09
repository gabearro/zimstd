## Dictionary-free Zstandard decoder. Entropy algorithms adapted from Go
## internal/zstd, Copyright 2023 The Go Authors (BSD-3-Clause).
import common, xxhash
import std/streams

type Decoder = object
  huff: array[2048, uint16]
  huffLog: int
  tables: array[3, FseTable]
  reps: array[3, int]
  literals: string

proc readHuff(d: var Decoder, data: openArray[char], p: var int) =
  let header = int(readLe(data, p, 1))
  var weights: array[256, int]
  var count = 0
  if header < 128:
    let stop = p+header
    require(stop <= data.len, "truncated Huffman weights")
    var table = readFse(data.toOpenArray(0, stop-1), p, 255, 6)
    var r = initReverse(data, p, stop)
    var states = [r.take(data, table.log), r.take(data, table.log)]
    var turn = 0
    while true:
      let e = table.entries[states[turn]]
      if not r.fetch(data, int(e.bits)):
        require(count < 254, "too many Huffman weights")
        weights[count] = int(e.sym)
        weights[count+1] = int(table.entries[states[1-turn]].sym)
        count += 2
        break
      require(count < 255, "too many Huffman weights")
      weights[count] = int(e.sym)
      inc count
      states[turn] = int(e.base)+r.take(data, int(e.bits))
      turn = 1-turn
    p = stop
  else:
    count = header-127
    for i in countup(0, count-1, 2):
      let v = int(readLe(data, p, 1))
      weights[i] = v shr 4
      weights[i+1] = v and 15
  var ranks: array[13, int]
  var total = 0
  for i in 0..<count:
    let w = weights[i]
    require(w <= 11, "Huffman weight too large")
    inc ranks[w]
    if w > 0: total += 1 shl (w-1)
  require(total > 0, "empty Huffman tree")
  let log = floorLog(total)+1
  require(log <= 11, "Huffman tree too large")
  let rest = (1 shl log)-total
  require((rest and (rest-1)) == 0, "invalid Huffman weight sum")
  let last = floorLog(rest)+1
  weights[count] = last
  inc count
  inc ranks[last]
  require(ranks[1] >= 2 and (ranks[1] and 1) == 0, "invalid Huffman ranks")
  var next = 0
  for w in 1..log:
    let start = next
    next += ranks[w] shl (w-1)
    ranks[w] = start
  for sym in 0..<count:
    let w = weights[sym]
    if w > 0:
      let n = 1 shl (w-1)
      for i in ranks[w]..<ranks[w]+n:
        d.huff[i] = uint16((sym shl 8) or (log+1-w))
      ranks[w] += n
  d.huffLog = log

proc huffStream(d: var Decoder, data: openArray[char], start, stop, dest, size: int) =
  var r = initReverse(data, start, stop)
  let log = d.huffLog
  for i in dest..<dest+size:
    if r.count < log: discard r.fetch(data, log)
    # Zero padding is only for lookup; the selected code must fit real bits.
    let index = if r.count >= log: int((r.bits shr (r.count-log)) and mask(log))
                else: int((r.bits shl (log-r.count)) and mask(log))
    let entry = d.huff[index]
    let bits = int(entry and 255)
    require(bits > 0 and bits <= r.count, "truncated Huffman stream")
    r.count -= bits
    d.literals[i] = char(entry shr 8)
  require(r.finished, "extra Huffman bits")

proc readLiterals(d: var Decoder, data: openArray[char], p: var int): tuple[offset, size: int] =
  result.offset = -1
  let header = int(readLe(data, p, 1))
  let kind = header and 3
  let format = (header shr 2) and 3
  var size: int
  if kind < 2:
    case format
    of 0, 2: size = header shr 3
    of 1: size = (header shr 4) or (int(readLe(data, p, 1)) shl 4)
    else: size = (header shr 4) or (int(readLe(data, p, 2)) shl 4)
    require(size <= BlockSize, "too many literals")
    if kind == 0:
      require(size <= data.len-p, "truncated raw literals")
      result = (p, size)
      p += size
    else:
      d.literals.setLen(size)
      let v = char(readLe(data, p, 1))
      for i in 0..<size: d.literals[i] = v
    return
  let n = if format < 2: 2 else: format+1
  let packed = uint64(header) or (readLe(data, p, n) shl 8)
  let width = if format < 2: 10 elif format == 2: 14 else: 18
  size = int((packed shr 4) and mask(width))
  let compressed = int((packed shr (4+width)) and mask(width))
  require(size <= BlockSize and compressed <= data.len-p, "invalid literals size")
  let stop = p+compressed
  if kind == 2:
    d.readHuff(data.toOpenArray(0, stop-1), p)
  else: require(d.huffLog > 0, "missing Huffman tree")
  d.literals.setLen(size)
  if format == 0: d.huffStream(data, p, stop, 0, size)
  else:
    require(stop-p >= 6, "truncated Huffman jump table")
    var lengths: array[4, int]
    for i in 0..2: lengths[i] = int(readLe(data, p, 2))
    lengths[3] = stop-p-lengths[0]-lengths[1]-lengths[2]
    let part = (size+3) div 4
    require(part*3 <= size, "invalid four-stream size")
    for i in 0..3:
      require(lengths[i] > 0 and lengths[i] <= stop-p, "invalid Huffman stream size")
      let outputSize = if i < 3: part else: size-3*part
      d.huffStream(data, p, p+lengths[i], part*i, outputSize)
      p += lengths[i]
  p = stop

proc setTable(d: var Decoder, data: openArray[char], p: var int, kind, mode: int) =
  const maxSym = [35, 31, 52]
  case mode
  of 0:
    case kind
    of 0: d.tables[kind] = DefaultLl
    of 1: d.tables[kind] = DefaultOf
    else: d.tables[kind] = DefaultMl
  of 1:
    let sym = int(readLe(data, p, 1))
    require(sym <= maxSym[kind], "invalid RLE sequence symbol")
    d.tables[kind].entries[0] = FseEntry(sym: uint8(sym))
    d.tables[kind].log = 0
    d.tables[kind].valid = true
  of 2: d.tables[kind] = readFse(data, p, maxSym[kind], if kind == 1: 8 else: 9)
  else: require(d.tables[kind].valid, "missing repeated FSE table")

proc appendBytes(dst: var string, data: openArray[char], start, n, limit: int) {.inline.} =
  require(n >= 0 and n <= limit-dst.len, "decompressed size limit exceeded")
  if n > 0:
    let old = dst.len
    dst.setLen(old+n)
    copyMem(addr dst[old], unsafeAddr data[start], n)

proc execSequences(d: var Decoder, data, literals: openArray[char], pos: int,
                   dst: var string, frameStart, window, limit, blockLimit: int) =
  let blockStart = dst.len
  let stop = min(limit, dst.len+min(blockLimit, high(int)-dst.len))
  var p = pos
  var count = int(readLe(data, p, 1))
  if count == 0:
    require(p == data.len, "extra bytes after literals")
    dst.appendBytes(literals, 0, literals.len, stop)
    return
  if count == 255: count = int(readLe(data, p, 2))+0x7f00
  elif count >= 128: count = ((count-128) shl 8)+int(readLe(data, p, 1))
  let mode = int(readLe(data, p, 1))
  require((mode and 3) == 0, "reserved sequence mode bits")
  for kind in 0..2: d.setTable(data, p, kind, (mode shr (6-2*kind)) and 3)
  var r = initReverse(data, p, data.len)
  var states: array[3, int]
  for k in 0..2: states[k] = r.take(data, d.tables[k].log)
  var litPos = 0
  for sequence in 0..<count:
    let le = d.tables[0].entries[states[0]]
    let oe = d.tables[1].entries[states[1]]
    let me = d.tables[2].entries[states[2]]
    var offset = (1 shl int(oe.sym))+r.take(data, int(oe.sym))
    let match = MlBase[me.sym]+r.take(data, MlBits[me.sym])
    let literal = LlBase[le.sym]+r.take(data, LlBits[le.sym])
    if offset > 3:
      offset -= 3
      d.reps[2] = d.reps[1]
      d.reps[1] = d.reps[0]
      d.reps[0] = offset
    else:
      if literal == 0: inc offset
      case offset
      of 1: offset = d.reps[0]
      of 2:
        offset = d.reps[1]
        d.reps[1] = d.reps[0]
        d.reps[0] = offset
      else:
        offset = if offset == 3: d.reps[2] else: d.reps[0]-1
        d.reps[2] = d.reps[1]
        d.reps[1] = d.reps[0]
        d.reps[0] = offset
    if sequence+1 < count:
      states[0] = int(le.base)+r.take(data, int(le.bits))
      states[2] = int(me.base)+r.take(data, int(me.bits))
      states[1] = int(oe.base)+r.take(data, int(oe.bits))
    require(literal <= literals.len-litPos, "literal length overflow")
    dst.appendBytes(literals, litPos, literal, stop)
    litPos += literal
    require(offset > 0 and offset <= dst.len-frameStart and
      (offset <= window or offset <= dst.len-blockStart), "match offset outside window")
    require(match <= stop-dst.len, "match length overflow")
    let old = dst.len
    dst.setLen(old+match)
    # Non-overlapping doubling copies also handle offset=1 without byte loops.
    var copied = 0
    while copied < match:
      let n = min(match-copied, offset+copied)
      copyMem(addr dst[old+copied], addr dst[old-offset], n)
      copied += n
  dst.appendBytes(literals, litPos, literals.len-litPos, stop)
  require(r.finished, "extra sequence bits")

proc compressedBlock(d: var Decoder, data: openArray[char], dst: var string,
                     frameStart, window, limit, blockLimit: int) =
  var p = 0
  let raw = d.readLiterals(data, p)
  if raw.offset >= 0:
    d.execSequences(data, data.toOpenArray(raw.offset, raw.offset+raw.size-1), p,
                    dst, frameStart, window, limit, blockLimit)
  else:
    d.execSequences(data, d.literals, p, dst, frameStart, window, limit, blockLimit)

type FrameHeader = object
  window, size: int
  hasSize, checksum: bool

proc readHeader(data: openArray[char], p: var int, remaining, maxWindow: int): FrameHeader =
  let header = int(readLe(data, p, 1))
  require((header and 8) == 0, "reserved frame header bit")
  let single = (header and 32) != 0
  var window: uint64
  if not single:
    let wd = int(readLe(data, p, 1))
    let base = 1'u64 shl (10+(wd shr 3))
    window = base+(base shr 3)*uint64(wd and 7)
  const dictBytes = [0,1,2,4]
  let dictionary = readLe(data, p, dictBytes[header and 3])
  require(dictionary == 0, "external dictionaries are not supported")
  let flag = header shr 6
  let sizeBytes = if flag == 0: ord(single) else: 1 shl flag
  var size = readLe(data, p, sizeBytes)
  if sizeBytes == 2: size += 256
  if single: window = size
  require(window <= uint64(maxWindow), "window limit exceeded")
  result.window = int(window)
  result.hasSize = sizeBytes != 0
  result.checksum = (header and 4) != 0
  if result.hasSize:
    require(size <= uint64(remaining), "decompressed size limit exceeded")
    result.size = int(size)

proc reset(d: var Decoder) =
  d.huffLog = 0
  for table in d.tables.mitems: table.valid = false
  d.reps = [1,4,8]

proc payloadSize(bh, window: int): int =
  let n = bh shr 3
  require(n <= min(BlockSize, window), "block exceeds window or 128 KiB")
  let kind = (bh shr 1) and 3
  require(kind != 3, "reserved block type")
  if kind == 1: 1 else: n

proc decodeBlock(d: var Decoder, data: openArray[char], p: var int, bh: int,
                 dst: var string, frameStart, window, limit: int) =
  let stored = payloadSize(bh, window)
  require(stored <= data.len-p, "truncated block")
  let n = bh shr 3
  case (bh shr 1) and 3
  of 0: dst.appendBytes(data, p, n, limit)
  of 1:
    let v = data[p]
    require(n <= limit-dst.len, "decompressed size limit exceeded")
    let old = dst.len
    dst.setLen(old+n)
    for i in old..<dst.len: dst[i] = v
  of 2:
    d.compressedBlock(data.toOpenArray(p, p+n-1), dst, frameStart, window, limit,
                      min(BlockSize, window))
  else: fail("reserved block type")
  p += stored

proc decompress*(data: openArray[char], maxOutput = 256*1024*1024,
                 maxWindow = 128*1024*1024): string =
  ## Decode concatenated/skippable frames. Checksums are verified. Limits apply
  ## before allocating output; dictionary frames raise ZstdError.
  require(maxOutput >= 0 and maxWindow >= 0, "negative resource limit")
  require(data.len > 0, "empty input is not a Zstandard frame")
  var p = 0
  var d: Decoder
  while p < data.len:
    let magic = readLe(data, p, 4)
    if (magic and 0xfffffff0'u64) == 0x184d2a50'u64:
      let n = readLe(data, p, 4)
      require(n <= uint64(data.len-p), "truncated skippable frame")
      p += int(n)
      continue
    require(magic == 0xfd2fb528'u64, "invalid Zstandard magic")
    let header = readHeader(data, p, maxOutput-result.len, maxWindow)
    let frameStart = result.len
    let limit = if header.hasSize: frameStart+header.size else: maxOutput
    if frameStart == 0 and header.hasSize and header.size > 0:
      result = newStringOfCap(header.size)
    d.reset()
    while true:
      let bh = int(readLe(data, p, 3))
      d.decodeBlock(data, p, bh, result, frameStart, header.window, limit)
      if (bh and 1) != 0: break
    if header.hasSize: require(result.len-frameStart == header.size, "frame content size mismatch")
    if header.checksum:
      let checksum = readLe(data, p, 4)
      require((xxh64(result.toOpenArray(frameStart, result.len-1)) and 0xffffffff'u64) == checksum,
              "content checksum mismatch")

proc readNumber(input: Stream, n: int): uint64 =
  let data = input.readChunk(n, exact = true)
  var p = 0
  readLe(data, p, n)

proc decompress*(input, output: Stream, maxOutput = 256*1024*1024,
                 maxWindow = 128*1024*1024) =
  ## Decode incrementally with O(window + block size) working memory.
  ## Output may already be written when a checksum, format, or I/O error occurs.
  ## Streams are neither closed nor flushed. Zero-byte reads mean EOF.
  require(input != nil and output != nil and input != output, "distinct non-nil streams required")
  require(maxOutput >= 0 and maxWindow >= 0, "negative resource limit")
  var total = 0
  var seenFrame = false
  var d: Decoder
  var history: string
  while true:
    let magicBytes = input.readChunk(4)
    if magicBytes.len == 0:
      require(seenFrame, "empty input is not a Zstandard frame")
      return
    var p = 0
    let magic = readLe(magicBytes, p, 4)
    seenFrame = true
    if (magic and 0xfffffff0'u64) == 0x184d2a50'u64:
      var left = input.readNumber(4)
      while left > 0:
        let n = int(min(left, uint64(BlockSize)))
        discard input.readChunk(n, exact = true)
        left -= uint64(n)
      continue
    require(magic == 0xfd2fb528'u64, "invalid Zstandard magic")
    var bytes = input.readChunk(1, exact = true)
    let descriptor = ord(bytes[0])
    let single = (descriptor and 32) != 0
    let flag = descriptor shr 6
    const dictBytes = [0,1,2,4]
    let extra = ord(not single)+dictBytes[descriptor and 3]+
      (if flag == 0: ord(single) else: 1 shl flag)
    bytes.add input.readChunk(extra, exact = true)
    p = 0
    let header = readHeader(bytes, p, maxOutput-total, maxWindow)
    d.reset()
    history.setLen(0)
    var hash = initXxh64()
    var frameBytes = 0
    while true:
      let bh = int(input.readNumber(3))
      let payload = input.readChunk(payloadSize(bh, header.window), exact = true)
      let old = history.len
      let remaining = if header.hasSize: header.size-frameBytes else: maxOutput-total
      let limit = old+min(remaining, min(BlockSize, high(int)-old))
      p = 0
      d.decodeBlock(payload, p, bh, history, 0, header.window, limit)
      let count = history.len-old
      if header.checksum: hash.update(history.toOpenArray(old, history.len-1))
      if count > 0: output.writeData(addr history[old], count)
      frameBytes += count
      total += count
      if (bh and 1) != 0: break
      # Compact in window-sized batches, so copying is amortized linear.
      # Keep all history legal for the next block, including small windows.
      if history.len-header.window >= max(header.window, BlockSize):
        if header.window > 0:
          moveMem(addr history[0], addr history[history.len-header.window], header.window)
        history.setLen(header.window)
    if header.hasSize: require(frameBytes == header.size, "frame content size mismatch")
    if header.checksum:
      require((hash.digest and 0xffffffff'u64) == input.readNumber(4), "content checksum mismatch")
