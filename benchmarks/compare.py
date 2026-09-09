"""Paired file benchmarks, exact encoder comparison, and reference verification.
Python stdlib and reference zstd CLI are only needed for this benchmark driver.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import random
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("before")
parser.add_argument("after")
parser.add_argument("corpus", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--repeats", type=int, default=5)
parser.add_argument("--mib", type=int, default=32)
parser.add_argument("--chunk", type=int, default=0)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
executables = {"before": args.before, "after": args.after}
files = sorted(p for p in args.corpus.iterdir() if p.is_file() and p.suffix != ".zst")
assert files and args.repeats > 0 and args.mib > 0 and args.chunk >= 0
rng = random.Random(20260909)
fields = ["file", "variant", "repeat", "input_bytes", "reference_bytes", "encoded_bytes",
          "chunk", "rounds", "encode_mib_s", "decode_mib_s", "encode_ns_call",
          "fingerprint", "sink", "rss_bytes"]
manifest = []
with tempfile.TemporaryDirectory(prefix="zimstd-compare-") as work:
    # These correctness passes finish before any timings. Keep all inputs,
    # including workloads that compress poorly or expose regressions.
    for path in files:
        reference = Path(str(path) + ".zst")
        if not reference.exists():
            subprocess.run(["zstd", "-q", "-3", "--check", str(path), "-o", str(reference)], check=True)
        encoded = []
        for variant, exe in executables.items():
            dump = Path(work) / (variant + ".zst")
            subprocess.run([exe, str(path), str(reference), "1", "encode",
                            str(args.chunk or path.stat().st_size), str(dump)],
                           check=True, stdout=subprocess.DEVNULL)
            encoded.append(dump.read_bytes())
        assert encoded[0] == encoded[1], f"Encoder bytes changed: {path}"
        original = path.read_bytes()
        decoded = subprocess.check_output(["zstd", "-dq", "-c", str(dump)])
        assert decoded == original, f"Reference decoder mismatch: {path}"
        manifest.append({"file": path.name, "input_bytes": len(original),
                         "sha256": hashlib.sha256(original).hexdigest(),
                         "encoded_bytes": len(encoded[0]),
                         "encoded_sha256": hashlib.sha256(encoded[0]).hexdigest(),
                         "reference_sha256": hashlib.sha256(reference.read_bytes()).hexdigest()})
        print("verified", path.name, flush=True)
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with (args.output / "timings.csv").open("w", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(fields)
        for repeat in range(args.repeats):
            order = files.copy()
            rng.shuffle(order)
            for path in order:
                variants = list(executables)
                rng.shuffle(variants)
                rounds = max(2, args.mib * 1024 * 1024 // path.stat().st_size)
                for variant in variants:
                    command = ["/usr/bin/time", "-l", executables[variant], str(path),
                               str(path) + ".zst", str(rounds), "encode" if args.chunk else "both"]
                    if args.chunk:
                        command.append(str(args.chunk))
                    run = subprocess.run(command, check=True, text=True, capture_output=True)
                    rss = re.search(r"(\d+)\s+maximum resident set size", run.stderr)[1]
                    writer.writerow([path.name, variant, repeat] + run.stdout.strip().split(",") + [rss])
                    file.flush()
            print("paired run", repeat + 1, "complete", flush=True)
