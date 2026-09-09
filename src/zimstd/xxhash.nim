## xxHash64, seed zero, used by Zstandard content checksums.
import common
const
  P1 = 11400714785074694791'u64
  P2 = 14029467366897019727'u64
  P3 = 1609587929392839161'u64
  P4 = 9650029242287828579'u64
  P5 = 2870177450012600261'u64
proc rot(x: uint64, n: int): uint64 {.inline.} = (x shl n) or (x shr (64-n))
proc round(acc, x: uint64): uint64 {.inline.} = rot(acc+x*P2, 31)*P1
proc merge(acc, x: uint64): uint64 {.inline.} = (acc xor round(0, x))*P1+P4
proc finishHash(value: uint64, data: openArray[char]): uint64 =
  result = value
  var p = 0
  while p <= data.len-8:
    result = rot(result xor round(0, readLe(data, p, 8)), 27)*P1+P4
  if p <= data.len-4:
    result = rot(result xor (readLe(data, p, 4)*P1), 23)*P2+P3
  while p < data.len:
    result = rot(result xor (readLe(data, p, 1)*P5), 11)*P1
  result = result xor (result shr 33)
  result *= P2
  result = result xor (result shr 29)
  result *= P3
  result = result xor (result shr 32)

proc xxh64*(data: openArray[char]): uint64 =
  var p = 0
  if data.len >= 32:
    var a = P1+P2
    var b = P2
    var c = 0'u64
    var d = 0'u64-P1
    while p <= data.len-32:
      a = round(a, readLe(data, p, 8))
      b = round(b, readLe(data, p, 8))
      c = round(c, readLe(data, p, 8))
      d = round(d, readLe(data, p, 8))
    result = rot(a, 1)+rot(b, 7)+rot(c, 12)+rot(d, 18)
    result = merge(merge(merge(merge(result, a), b), c), d)
  else: result = P5
  result += uint64(data.len)
  result = finishHash(result, data.toOpenArray(p, data.len-1))

type Xxh64State* = object
  total: uint64
  lanes: array[4, uint64]
  tail: array[32, char]
  used: int

proc initXxh64*(): Xxh64State =
  result.lanes = [P1+P2, P2, 0'u64, 0'u64-P1]

proc stripe(h: var Xxh64State, data: openArray[char], p: var int) =
  for lane in h.lanes.mitems: lane = round(lane, readLe(data, p, 8))

proc update*(h: var Xxh64State, data: openArray[char]) =
  h.total += uint64(data.len)
  var p = 0
  if h.used > 0:
    let n = min(32-h.used, data.len)
    if n > 0: copyMem(addr h.tail[h.used], unsafeAddr data[0], n)
    h.used += n
    p += n
    if h.used < 32: return
    var q = 0
    h.stripe(h.tail, q)
    h.used = 0
  while p <= data.len-32: h.stripe(data, p)
  h.used = data.len-p
  if h.used > 0: copyMem(addr h.tail[0], unsafeAddr data[p], h.used)

proc digest*(h: Xxh64State): uint64 =
  result = P5
  if h.total >= 32:
    result = rot(h.lanes[0], 1)+rot(h.lanes[1], 7)+rot(h.lanes[2], 12)+rot(h.lanes[3], 18)
    for lane in h.lanes: result = merge(result, lane)
  result = finishHash(result+h.total, h.tail.toOpenArray(0, h.used-1))
