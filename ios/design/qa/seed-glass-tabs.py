#!/usr/bin/env python3
"""Append synthetic tab fixtures to the explicitly selected QA simulator."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import wave

spec = importlib.util.spec_from_file_location("safe_container", Path(__file__).with_name("safe-container.py"))
safe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safe)
container = safe.container_for(sys.argv[1])
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    seed = root / "seed"
    (seed / "Transcripts").mkdir(parents=True)
    for name, seconds in (("Glass Tabbed QA", 60), ("Glass Missing QA", 53)):
        with wave.open(str(root / "silence.wav"), "wb") as audio:
            audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes(bytes(16000 * 2 * seconds))
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", str(root / "silence.wav"), str(seed / (name + ".m4a"))], check=True)
    (seed / "Transcripts/Glass Tabbed QA.md").write_text(
        "# Glass Tabbed QA\n\n_Расшифровано: Проверочный движок QA, на этом iPhone_\n\n"
        "**[0:00–0:30]** S1: Три вкладки проверяем на записи.\n\n"
        "**[0:30–1:00]** S2: Последняя реплика должна оставаться выше плеера.\n")
    safe.copy_new(seed, container, "Documents/Lori/Workspace")
print("Added glass tab fixtures to Lori QA; existing files preserved.")
