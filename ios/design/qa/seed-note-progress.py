#!/usr/bin/env python3
"""Append a 12-minute synthetic chunk fixture only to the explicit QA simulator."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("safe_container", Path(__file__).with_name("safe-container.py"))
safe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safe)
container = safe.container_for(sys.argv[1])
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    seed = root / "seed"
    seed.mkdir()
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=220:sample_rate=16000:duration=720",
                    "-c:a", "aac", "-b:a", "24k", str(seed / "Progress QA.m4a")], check=True)
    (seed / "Transcripts").mkdir()
    (seed / "Transcripts/Progress QA.md").write_text("# Progress QA\n\nПроверка прогресса по частям.\n")
    safe.copy_new(seed, container, "Documents/Lori/Workspace")
print("Added synthetic 12-minute Progress QA recording, append only.")
