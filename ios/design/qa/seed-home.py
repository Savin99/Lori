#!/usr/bin/env python3
"""Home-screen fixture for Lori QA on an explicitly selected simulator.

Кладёт в рабочую папку Lori QA записи за три дня: с расшифровками (таймкоды,
говорящие, разные движки и режимы) и одну без расшифровки. С `--inbox` ещё пять
файлов ждут в Documents/Inbox — так их оставляет «Поделиться» → Lori, и при
запуске приложение прикрепит их к нижней панели.

Только добавление, через safe-container.py: существующий файл — отказ, а не
перезапись; личное приложение и чужой контейнер отклоняются до копирования.

    python3 design/qa/seed-home.py <simulator-uuid> [--inbox] [--inbox-only]

Снимки с очередью и ошибкой — с проверочным движком: запуск Lori QA с
`--ui-stub-engine` (см. QAStubEngine.swift).
"""

import argparse
import datetime as dt
import importlib.util
import os
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FFMPEG = "/opt/homebrew/bin/ffmpeg"


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


safe = load("safe-container")

# Записи главного экрана: (папка, имя файла, когда, длительность в секундах,
# движок, режим, реплики). Реплики — (говорящий или None, текст). Без реплик —
# запись без расшифровки. Заголовок карточки берётся из первой фразы текста:
# у засеянных записей нет имени в хранилище заголовков, как у записей с диктофона.
ELEVEN = "ElevenLabs Scribe v2, в облаке"
GIGAAM = "GigaAM v3 CTC (int8), на этом iPhone"
GEMINI = "Gemini 3.5 Transcribe, в облаке"
WHISPER = "Whisper large-v3 turbo, на этом iPhone"

RECORDS = [
    (
        "Recordings",
        "Новая запись 14",
        ("today", -40),
        24 * 60 + 10,
        ELEVEN,
        "Дословно",
        [
            (
                "S1",
                "Оффер бэкенд-кандидату. Обсудили условия: дедлайн — пятница, бюджет согласует Лёша.",
            ),
            (
                "S2",
                "Вилка та же, что в вакансии, плюс опцион после испытательного срока.",
            ),
            ("S1", "Кандидат просит удалёнку два дня в неделю, я не против."),
            (
                "S2",
                "Тогда готовлю письмо с оффером сегодня и отправляю после звонка с Лёшей.",
            ),
        ],
    ),
    (
        "Recordings",
        "Новая запись 13",
        ("today", -170),
        12 * 60 + 3,
        GIGAAM,
        "Быстрый",
        [
            (
                None,
                "Планёрка по релизу. Сборка готова, осталось проверить импорт длинных файлов на старом айфоне.",
            ),
            (None, "Исправление обещали к вечеру, выпуск переносим на четверг утром."),
        ],
    ),
    ("Recordings", "Новая запись 12", ("today", -310), 3 * 60 + 12, None, None, []),
    (
        "Recordings",
        "Новая запись 11",
        ("yesterday", 18 * 60 + 40),
        41 * 60 + 12,
        GEMINI,
        "Спикеры и таймкоды",
        [
            (
                "S1",
                "Созвон с дизайнером про новые карточки: убираем иконки, заголовку нужна вся ширина.",
            ),
            (
                "S2",
                "Согласна. Дату переносим в заголовок дня, на карточке оставим время и длительность.",
            ),
            ("S1", "А состояние записи показываем, только когда она не готова."),
            ("S2", "Да, и цвет — только там, где нужно внимание."),
        ],
    ),
    (
        "Recordings",
        "Новая запись 10",
        ("yesterday", 9 * 60 + 10),
        8 * 60 + 45,
        WHISPER,
        None,
        [
            (
                "",
                "Лекция про рабочую память. Объём у неё небольшой, около четырёх смысловых единиц, "
                "поэтому длинные инструкции забываются к середине. Помогает разбивать задачу на шаги "
                "и записывать промежуточные итоги.",
            ),
        ],
    ),
    (
        "Recordings",
        "Новая запись 9",
        ("days", 3, 16 * 60 + 30),
        5 * 60 + 30,
        ELEVEN,
        "Дословно",
        [
            (
                "S1",
                "Идеи для статьи о расшифровке на телефоне: приватность, скорость и длинные записи.",
            ),
            (
                "S2",
                "Начни с истории про пропавшую расшифровку — с неё понятно, зачем всё это.",
            ),
            ("S1", "Хорошо, а в конце — как отдать текст в ИИ одним файлом."),
        ],
    ),
]

# «Поделиться» → Lori: пять файлов разом. «(fail)» в имени роняет проверочный
# движок — так видна строка ошибки с «Повторить».
INBOX = [
    ("Совещание по бюджету", 41 * 60 + 12),
    ("Интервью Маши", 31 * 60 + 40),
    ("Звонок поставщику (fail)", 5 * 60 + 2),
    ("Разбор отзывов", 12 * 60),
    ("Планёрка", 18 * 60 + 30),
]


def when(spec, now):
    """Дата записи: относительно «сейчас» для сегодняшних, чтобы не уйти в будущее."""
    kind = spec[0]
    if kind == "today":
        return now + dt.timedelta(minutes=spec[1])
    if kind == "yesterday":
        day = (now - dt.timedelta(days=1)).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        return day + dt.timedelta(minutes=spec[1])
    day = (now - dt.timedelta(days=spec[1])).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return day + dt.timedelta(minutes=spec[2])


def stamp(seconds):
    seconds = int(seconds)
    return f"{seconds // 60}:{seconds % 60:02d}"


def markdown(base, engine, mode, lines):
    """Тот же формат, что пишет `Transcript.markdown`: заголовок, движок, режим, реплики."""
    parts = [f"# {base}", f"_Расшифровано: {engine}_"]
    if mode:
        parts.append(f"_Режим: {mode}_")
    start = 0.0
    for speaker, text in lines:
        if speaker == "":
            # Движок без таймкодов и говорящих — текст абзацем, как у Whisper без разметки.
            parts.append(text)
            continue
        length = max(2.0, round(len(text) / 14))
        body = f"{speaker}: {text}" if speaker else text
        parts.append(f"**[{stamp(start)}–{stamp(start + length)}]** {body}")
        start += length + 1
    return "\n\n".join(parts) + "\n"


def audio(text, seconds, destination, work):
    """Короткая фраза голосом и тишина до нужной длины: карточке нужна правдивая длительность."""
    speech = work / f"{destination.stem}.aiff"
    subprocess.run(["say", "-v", "Milena", "-o", str(speech), text], check=True)
    subprocess.run(
        [
            FFMPEG,
            "-v",
            "error",
            "-y",
            "-i",
            str(speech),
            "-af",
            "apad",
            "-t",
            str(seconds),
            "-ar",
            "16000",
            "-ac",
            "1",
            "-c:a",
            "aac",
            "-b:a",
            "16k",
            str(destination),
        ],
        check=True,
    )


def touch(path, moment):
    stamp_value = moment.timestamp()
    os.utime(path, (stamp_value, stamp_value))


def seed_workspace(container, work, now):
    tree = work / "workspace"
    created = []
    for folder, name, spec, seconds, engine, mode, lines in RECORDS:
        (tree / folder).mkdir(parents=True, exist_ok=True)
        clip = tree / folder / f"{name}.m4a"
        audio(
            lines[0][1] if lines else "Проверка записи без расшифровки.",
            seconds,
            clip,
            work,
        )
        moment = when(spec, now)
        created.append((Path(folder) / clip.name, moment))
        if lines:
            (tree / "Transcripts").mkdir(exist_ok=True)
            (tree / "Transcripts" / f"{name}.md").write_text(
                markdown(name, engine, mode, lines), encoding="utf-8"
            )
            created.append((Path("Transcripts") / f"{name}.md", moment))
    safe.copy_new(tree, container, "Documents/Lori/Workspace")
    # Даты — после копирования: копия получает «сейчас», а группы по дням и время
    # на карточке читаются именно из даты изменения файла.
    for relative, moment in created:
        touch(container / "Documents/Lori/Workspace" / relative, moment)
    print(f"Added {len(RECORDS)} records to the Lori QA workspace.")


def seed_inbox(container, work, now):
    tree = work / "inbox"
    tree.mkdir(parents=True, exist_ok=True)
    for name, seconds in INBOX:
        audio(
            f"{name}. Проверка пакетного импорта.", seconds, tree / f"{name}.m4a", work
        )
    safe.copy_new(tree, container, "Documents/Inbox")
    # Порядок в панели — по дате файла: первый в списке — самый старый.
    for index, (name, _) in enumerate(INBOX):
        touch(
            container / "Documents/Inbox" / f"{name}.m4a",
            now - dt.timedelta(seconds=len(INBOX) - index),
        )
    print(f"Added {len(INBOX)} files to Documents/Inbox of Lori QA.")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("device")
    parser.add_argument(
        "--inbox", action="store_true", help="also leave five files in Documents/Inbox"
    )
    parser.add_argument(
        "--inbox-only", action="store_true", help="only the Documents/Inbox files"
    )
    args = parser.parse_args()
    container = safe.container_for(args.device)
    now = dt.datetime.now()
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        if not args.inbox_only:
            seed_workspace(container, work, now)
        if args.inbox or args.inbox_only:
            seed_inbox(container, work, now)


if __name__ == "__main__":
    main()
