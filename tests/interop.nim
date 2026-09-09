## Optional interoperability tests; only this test executable invokes zstd.
import std/[os, osproc, strutils, random, tempfiles, streams]
import zimstd
let exe = findExe("zstd")
doAssert exe.len > 0, "install the reference zstd CLI to run nimble interop"
let dir = createTempDir("zimstd-", "")
try:
  var rng = initRand(8878)
  var sources = @["", "a", repeat('x', 300000), repeat("abcd12345\n", 30000)]
  for size in [255,256,65791,65792,131071,131072,131073,700000]:
    var s = newString(size)
    for c in s.mitems: c = char(rng.rand(255))
    sources.add s
    for c in s.mitems: c = char(rng.rand(15))
    sources.add s
  var rows: string
  for i in 0..<30000: rows.add "record=" & $i & " common text repeated status=ok\n"
  sources.add rows
  let raw = dir / "input"
  let packed = dir / "packed.zst"
  let decoded = dir / "decoded"
  var cases = 0
  for i, source in sources:
    writeFile(raw, source)
    for check in [false, true]:
      for streaming in [false, true]:
        if streaming:
          let input = newFileStream(raw, fmRead)
          let output = newFileStream(packed, fmWrite)
          try: compress(input, output, check)
          finally:
            input.close()
            output.close()
        else: writeFile(packed, compress(source, check))
        let command = quoteShell(exe) & " -dqf " & quoteShell(packed) & " -o " & quoteShell(decoded)
        let run = execCmdEx(command)
        doAssert run.exitCode == 0, run.output
        doAssert readFile(decoded) == source, "Nim encode case " & $i
        inc cases
    for level in [1,3,9,19]:
      let command = quoteShell(exe) & " -qf --check -" & $level & " " & quoteShell(raw) & " -o " & quoteShell(packed)
      let run = execCmdEx(command)
      doAssert run.exitCode == 0, run.output
      doAssert decompress(readFile(packed)) == source, "Nim decode case " & $i & " level " & $level
      inc cases
      let input = newFileStream(packed, fmRead)
      let output = newFileStream(decoded, fmWrite)
      try: decompress(input, output)
      finally:
        input.close()
        output.close()
      doAssert readFile(decoded) == source, "stream decode case " & $i & " level " & $level
      inc cases
  # Small windows force history compaction repeatedly, with cross-block matches
  # and repeated entropy tables produced by an independent encoder.
  var pattern = newString(100000)
  for c in pattern.mitems: c = char(rng.rand(15))
  let longSource = repeat(pattern, 65)
  writeFile(raw, longSource)
  for windowLog in [10,17,20]:
    let command = quoteShell(exe) & " -qf --check -9 --zstd=wlog=" & $windowLog &
      " " & quoteShell(raw) & " -o " & quoteShell(packed)
    let run = execCmdEx(command)
    doAssert run.exitCode == 0, run.output
    let input = newFileStream(packed, fmRead)
    let output = newFileStream(decoded, fmWrite)
    try: decompress(input, output, maxWindow = 1 shl windowLog)
    finally:
      input.close()
      output.close()
    doAssert readFile(decoded) == longSource, "history compaction window " & $windowLog
    inc cases
  echo cases, " reference interoperability cases passed"
finally: removeDir(dir)
