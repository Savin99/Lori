#!/usr/bin/env python3
"""Приём надиктовок: аудио из inbox → транскрипт и заметка в Obsidian.

Запускается launchd-агентом по появлению файла в inbox-папке хранилища.
Транскрипцию выполняет GigaAM через ``mac_transcriber/scripts/transcribe_md.py``;
здесь только оркестрация: дождаться дозагрузки из iCloud, вызвать транскрайбер,
разложить результат по vault и убрать исходник.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

logger = logging.getLogger("lori.ingest")

# Корень проекта GigaAM: там venv с моделью и сам транскрайбер.
GIGAAM_ROOT = Path(
    os.environ.get("LORI_GIGAAM_ROOT", "/Users/ilyaqa/Projects/GigaAM")
).expanduser()
GIGAAM_PYTHON = GIGAAM_ROOT / ".venv" / "bin" / "python"
TRANSCRIBE_SCRIPT = GIGAAM_ROOT / "mac_transcriber" / "scripts" / "transcribe_md.py"

# Хранилище Obsidian и его inbox.
VAULT = Path(
    os.environ.get(
        "LORI_VAULT",
        "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian [BRAIN]",
    )
).expanduser()
# Куда кладём расшифровки — та же раскладка, что у моста.
NOTES_DIR = VAULT / "Inbox" / "Транскрипты"
# Откуда забираем аудио. От NOTES_DIR не зависит: это разные места.
AUDIO_INBOX = VAULT / "Inbox" / "_audio"
DONE_DIR = AUDIO_INBOX / "done"
FAILED_DIR = AUDIO_INBOX / "failed"

# Рабочая директория Lori: логи, промежуточные артефакты, замок.
STATE_DIR = Path(os.environ.get("LORI_STATE", "~/.local/state/lori")).expanduser()
WORK_ROOT = STATE_DIR / "work"
LOCK_PATH = STATE_DIR / "ingest.lock"
LOG_PATH = STATE_DIR / "ingest.log"

AUDIO_SUFFIXES = frozenset({".m4a", ".mp3", ".wav", ".ogg", ".opus", ".mp4", ".aac"})

# Сколько ждать, пока файл перестанет расти (iCloud тянет его в фоне).
STABLE_TIMEOUT_S = 600.0
STABLE_INTERVAL_S = 2.0


def main() -> int:
    """Обрабатывает все аудиофайлы, лежащие в inbox.

    Returns:
        0 — все файлы обработаны либо обрабатывать нечего; 1 — были ошибки.
    """
    setup_logging()
    for directory in (NOTES_DIR, AUDIO_INBOX, DONE_DIR, FAILED_DIR, WORK_ROOT):
        directory.mkdir(parents=True, exist_ok=True)

    if not acquire_lock():
        logger.info("Другой запуск уже идёт, выхожу")
        return 0

    try:
        request_icloud_downloads()
        pending = sorted(collect_pending())
        if not pending:
            logger.debug("Inbox пуст")
            return 0

        logger.info("К обработке: %d файл(ов)", len(pending))
        failures = 0
        for audio in pending:
            try:
                process(audio)
            except Exception:  # noqa: BLE001 — один плохой файл не должен ронять очередь
                failures += 1
                logger.exception("Не удалось обработать %s", audio.name)
                quarantine(audio)
        return 1 if failures else 0
    finally:
        LOCK_PATH.unlink(missing_ok=True)


def process(audio: Path) -> None:
    """Прогоняет один файл через транскрайбер и раскладывает результат.

    Args:
        audio: Путь к аудиофайлу в inbox.

    Raises:
        RuntimeError: Файл не стабилизировался или транскрайбер вернул ошибку.
    """
    logger.info("Обрабатываю %s", audio.name)
    if not wait_until_stable(audio):
        raise RuntimeError(f"файл всё ещё догружается: {audio.name}")

    when = datetime.fromtimestamp(audio.stat().st_mtime)
    stamp = when.strftime("%Y-%m-%d %H%M")
    slug = slugify(audio.stem) or "zapis"

    # Раскладка по месяцам — та же, что у моста, чтобы вкладка была одна.
    month_dir = NOTES_DIR / when.strftime("%Y-%m")
    month_dir.mkdir(parents=True, exist_ok=True)
    note_path = unique_path(month_dir / f"{stamp} {slug}.md")

    # Здесь нужна только локальная расшифровка. GigaAM умеет подхватить
    # AI-отчёт из окружения даже без флага --report, поэтому изолируем
    # дочерний процесс от всех сетевых и отчётных провайдеров.
    command = [
        str(GIGAAM_PYTHON),
        str(TRANSCRIBE_SCRIPT),
        str(audio),
        "--title", audio.stem,
        "--output", str(note_path),
        "--work-root", str(WORK_ROOT),
        "--device", os.environ.get("LORI_DEVICE", "cpu"),
    ]
    logger.debug("Команда: %s", " ".join(command))

    started = time.monotonic()
    result = subprocess.run(
        command,
        cwd=GIGAAM_ROOT,
        capture_output=True,
        env=local_transcriber_env(),
        text=True,
        check=False,
    )
    elapsed = time.monotonic() - started

    if result.returncode != 0:
        logger.error("Транскрайбер упал (код %d)\n%s", result.returncode, result.stderr[-4000:])
        raise RuntimeError(f"transcribe_md.py вернул {result.returncode}")

    logger.info("Готово за %.0f c → %s", elapsed, note_path.name)
    shutil.move(str(audio), str(unique_path(DONE_DIR / audio.name)))


def collect_pending() -> list[Path]:
    """Возвращает аудиофайлы верхнего уровня inbox, готовые к обработке."""
    return [
        item
        for item in AUDIO_INBOX.iterdir()
        if item.is_file()
        and item.suffix.lower() in AUDIO_SUFFIXES
        and not item.name.startswith(".")
    ]


def request_icloud_downloads() -> None:
    """Просит iCloud материализовать плейсхолдеры ``.*.icloud`` в inbox."""
    placeholders = list(AUDIO_INBOX.glob(".*.icloud"))
    if not placeholders:
        return
    logger.info("Плейсхолдеров iCloud: %d, запрашиваю загрузку", len(placeholders))
    for placeholder in placeholders:
        subprocess.run(
            ["/usr/bin/brctl", "download", str(placeholder)],
            capture_output=True,
            check=False,
        )


def wait_until_stable(path: Path, timeout: float = STABLE_TIMEOUT_S) -> bool:
    """Ждёт, пока размер файла перестанет меняться два замера подряд.

    Args:
        path: Проверяемый файл.
        timeout: Предельное время ожидания в секундах.

    Returns:
        True, если размер стабилизировался и файл непустой.
    """
    deadline = time.monotonic() + timeout
    previous = -1
    while time.monotonic() < deadline:
        if not path.exists():
            return False
        current = path.stat().st_size
        if current > 0 and current == previous:
            return True
        previous = current
        time.sleep(STABLE_INTERVAL_S)
    return False


def quarantine(audio: Path) -> None:
    """Убирает необработанный файл в ``failed/``, чтобы не крутить его в цикле."""
    if audio.exists():
        shutil.move(str(audio), str(unique_path(FAILED_DIR / audio.name)))


def acquire_lock() -> bool:
    """Ставит замок против параллельных запусков launchd.

    Returns:
        True, если замок взят этим процессом.
    """
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        with LOCK_PATH.open("x") as handle:
            handle.write(str(os.getpid()))
        return True
    except FileExistsError:
        # Замок от умершего процесса старше часа считаем протухшим.
        if time.time() - LOCK_PATH.stat().st_mtime > 3600:
            logger.warning("Снимаю протухший замок")
            LOCK_PATH.unlink(missing_ok=True)
            return acquire_lock()
        return False


def unique_path(path: Path) -> Path:
    """Подбирает свободное имя, добавляя ``-2``, ``-3`` и далее."""
    if not path.exists():
        return path
    for index in range(2, 1000):
        candidate = path.with_name(f"{path.stem}-{index}{path.suffix}")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"не смог подобрать имя для {path}")


def slugify(value: str) -> str:
    """Приводит имя файла к безопасному для Obsidian виду."""
    cleaned = re.sub(r"[^\w\s-]", "", value, flags=re.UNICODE).strip()
    return re.sub(r"[\s_-]+", " ", cleaned)


def setup_logging() -> None:
    """Пишет лог в файл состояния и в stderr (его подхватывает launchd)."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=os.environ.get("LORI_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)-7s %(message)s",
        handlers=[logging.FileHandler(LOG_PATH, encoding="utf-8"), logging.StreamHandler()],
    )


def local_transcriber_env() -> dict[str, str]:
    """Возвращает окружение для строго локального ASR без внешнего ИИ."""
    env = os.environ.copy()
    env.update(
        {
            "MAC_TRANSCRIBER_REPORT_MODE": "local",
            "MAC_TRANSCRIBER_REPORT_PDF": "0",
            "MAC_TRANSCRIBER_DATABASE_URL": "",
            "MAC_TRANSCRIBER_POSTGRES_DSN": "",
            "MAC_TRANSCRIBER_OPENAI_ENV_FILE": "",
            "OPENAI_API_KEY": "",
        }
    )
    return env


if __name__ == "__main__":
    sys.exit(main())
