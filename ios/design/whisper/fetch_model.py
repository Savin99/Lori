#!/usr/bin/env python3
"""Скачивает Core ML-модель Whisper для Lori на Mac.

Приложение само ничего не качает: расшифровка обязана работать без сети,
и 600 МБ по мобильной сети — не то, что стоит делать за владельца. Папку,
которую собрал этот скрипт, кладут на iPhone через «Файлы» → Lori → Models.

Веса берутся из репозитория WhisperKit, файлы токенизатора — из репозитория
OpenAI: в папке WhisperKit их нет, а без них пакет пойдёт за ними в сеть.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

WEIGHTS_REPO = "argmaxinc/whisperkit-coreml"
TOKENIZER_REPO = "openai/whisper-large-v3"
TOKENIZER_FILES = ("tokenizer.json", "tokenizer_config.json")
DEFAULT_VARIANT = "openai_whisper-large-v3-v20240930_turbo_632MB"


def tree(repo: str, path: str) -> list[dict[str, object]]:
    """Список файлов папки репозитория HuggingFace."""
    url = f"https://huggingface.co/api/models/{repo}/tree/main/{path}?recursive=true"
    with urllib.request.urlopen(url) as response:
        return json.load(response)


def download(repo: str, remote: str, target: Path) -> int:
    """Кладёт один файл и возвращает его размер."""
    target.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://huggingface.co/{repo}/resolve/main/{remote}"
    with urllib.request.urlopen(url) as response, target.open("wb") as file:
        size = 0
        while chunk := response.read(1 << 20):
            file.write(chunk)
            size += len(chunk)
    return size


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", default=DEFAULT_VARIANT, help="папка модели в репозитории WhisperKit")
    parser.add_argument("--out", type=Path, default=Path("whisper-large-v3-turbo"), help="куда сложить")
    arguments = parser.parse_args()

    out: Path = arguments.out
    entries = [item for item in tree(WEIGHTS_REPO, arguments.variant) if item.get("type") == "file"]
    if not entries:
        print(f"В {WEIGHTS_REPO} нет папки {arguments.variant}", file=sys.stderr)
        return 1

    total = 0
    for index, item in enumerate(entries, start=1):
        remote = str(item["path"])
        relative = remote[len(arguments.variant) + 1 :]
        print(f"[{index}/{len(entries)}] {relative}")
        total += download(WEIGHTS_REPO, remote, out / relative)

    for name in TOKENIZER_FILES:
        print(f"[токенизатор] {name}")
        total += download(TOKENIZER_REPO, name, out / name)

    print(f"\nГотово: {out} — {total / 1024 / 1024:.0f} МБ.")
    print("Перенеси папку на iPhone: «Файлы» → «На моём iPhone» → Lori → Models.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
