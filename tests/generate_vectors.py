"""Optional fixture maintenance. Python stdlib + reference zstd CLI only."""
from pathlib import Path
import random
import subprocess

root = Path(__file__).parent / "vectors"
rng = random.Random(8878)
sources = {
    "huffman": bytes(rng.choices(range(32, 127), weights=range(1, 96), k=90000)),
    "multiblock": b"".join(b"row=%08d status=ok repeated common phrase\n" % i
                          for i in range(8000)),
    "binary": bytes(rng.randrange(16) for _ in range(140000)),
}
for name, data in sources.items():
    for level in (1, 9, 19):
        stem = root / f"{name}-{level}"
        stem.with_suffix(".raw").write_bytes(data)
        stem.with_suffix(".zst").write_bytes(subprocess.check_output(
            ["zstd", "-q", f"-{level}", "--check", "-c"], input=data))
