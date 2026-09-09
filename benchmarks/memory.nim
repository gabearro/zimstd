## One codec call, no warm-up or correctness-copy allocations in the process.
## Run via /usr/bin/time -l; use the independent regression/interop tests first.
import std/os
import zimstd
import zimstd/xxhash
doAssert paramCount() == 2 and paramStr(1) in ["encode", "decode"]
let data = readFile(paramStr(2))
let before = getOccupiedMem()
let output = if paramStr(1) == "encode": compress(data) else: decompress(data)
let retained = getOccupiedMem()-before
echo data.len, ",", output.len, ",", retained, ",", xxh64(output)
