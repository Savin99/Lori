#!/usr/bin/env python3
"""Append a synthetic gateway fixture to the explicitly selected QA simulator."""
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
    (seed / "Transcripts").mkdir(parents=True)
    text = "Сегодня обсуждали выпуск Лори. Анна проверит качество записи завтра. Вопрос о словаре пока открыт."
    subprocess.run(["say", "-v", "Milena", "-o", str(root / "sample.aiff"), text], check=True)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", str(root / "sample.aiff"), str(seed / "Gateway QA.m4a")], check=True)
    (seed / "Transcripts/Gateway QA.md").write_text("# Gateway QA\n\n_Расшифровано: Проверочный движок QA, на этом iPhone_\n\n" + text + "\n")
    safe.copy_new(seed, container, "Documents/Lori/Workspace")
print("Added synthetic gateway recording to Lori QA.")
