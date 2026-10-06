#!/usr/bin/env python3
"""Две записи для проверки плашек «Пропуск A–B» на экране записи (Lori QA).

6 октября 2026 владелец увидел на записи 43:28 (ElevenLabs) плашки «Пропуск
4:19–5:19» и «Пропуск 20:17–20:34» над настоящей тишиной. Старое правило звало
пропуском любую тихую минуту со щелчком; такие строки `>` уже лежат в файлах, и
экран записи теперь сверяет их со звуком (`GapRecheck`).

  «Тишина посреди разговора» — речь, минута тишины со щелчками, стуками по столу,
      кашлем и клавиатурой, снова речь; в расшифровке строка `> Пропуск …` ровно
      на эту минуту, как её написало бы старое правило. Плашки на экране быть
      не должно.
  «Речь в пропуске» — та же раскладка, но в середине речь, которой нет в тексте.
      Плашка остаётся: это настоящий пропуск.

Только добавление, через safe-container.py; личное приложение отклоняется.
Речь — `say -v Milena`, помехи — `ffmpeg`.

    python3 design/redesign-2026-10-05/seed-silence.py <simulator-uuid>

Снимки — `SilentGapUITests` (`record-silence-*.png` в этой же папке).
"""

import argparse
import datetime as dt
import importlib.util
import os
import subprocess
import tempfile
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
FFMPEG = "/opt/homebrew/bin/ffmpeg"
RATE = 22050


def load(name):
    spec = importlib.util.spec_from_file_location(
        name, HERE.parent / "qa" / f"{name}.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


safe = load("safe-container")

ENGINE = "ElevenLabs · scribe_v2"
MODE = "Дословно"
GAP = 60.0

# Помехи тихой минуты. Уровни — от речи синтеза (RMS около 0,14, пик около 0,7):
# щелчки и стуки громче пика речи, кашель — на уровне речи, клавиатура — тише.
# Каждый щелчок в старом правиле (пик в окне 10 с) делал громким всё окно.
NOISES = "+".join(
    [
        # щелчок каждые 7,3 с: 3 мс, затухание 0,7 мс
        "0.9*exp(-mod(t+3.2,7.3)/0.0007)*lt(mod(t+3.2,7.3),0.003)",
        # стук по столу каждые 11,1 с: затухающий тон 400 Гц
        "0.8*exp(-mod(t+5.5,11.1)/0.025)*sin(2*PI*400*t)*lt(mod(t+5.5,11.1),0.12)",
        # приступ кашля: три шумовых всплеска по 0,3 с
        "(2*random(0)-1)*0.3*(between(t,22,22.3)+between(t,22.55,22.85)+between(t,23.1,23.4))",
        # клавиатура: четыре секунды по семь нажатий в секунду
        "0.4*exp(-mod(t,1/7)/0.0007)*lt(mod(t,1/7),0.003)*between(t,40,44)",
    ]
)


def run(*args):
    subprocess.run(list(args), check=True)


def speech(text, path, work):
    """Фраза голосом в WAV 22,05 кГц моно; возвращает длительность."""
    aiff = work / (path.stem + ".aiff")
    run("say", "-v", "Milena", "-o", str(aiff), text)
    run(
        FFMPEG,
        "-v",
        "error",
        "-y",
        "-i",
        str(aiff),
        "-ar",
        str(RATE),
        "-ac",
        "1",
        "-c:a",
        "pcm_s16le",
        str(path),
    )
    with wave.open(str(path)) as clip:
        return clip.getnframes() / clip.getframerate()


def silence_with_noises(path):
    run(
        FFMPEG,
        "-v",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        f"aevalsrc=exprs='{NOISES}':s={RATE}:d={GAP}",
        "-f",
        "lavfi",
        "-i",
        f"anoisesrc=color=pink:amplitude=0.004:r={RATE}:d={GAP}",
        "-filter_complex",
        "[0][1]amix=inputs=2:normalize=0",
        "-ar",
        str(RATE),
        "-ac",
        "1",
        "-c:a",
        "pcm_s16le",
        str(path),
    )


def stamp(seconds):
    total = int(seconds)
    return f"{total // 60}:{total % 60:02d}"


def record(name, first, middle, last, work, tree, transcribed_middle=None):
    """Аудио «речь — середина — речь» и расшифровка без середины, с плашкой на неё."""
    a = work / f"{name}-a.wav"
    b = work / f"{name}-b.wav"
    gap = work / f"{name}-gap.wav"
    first_length = speech(first[1], a, work)
    last_length = speech(last[1], b, work)
    if middle is None:
        silence_with_noises(gap)
        middle_length = GAP
    else:
        middle_length = speech(middle, gap, work)
    joined = work / f"{name}.wav"
    run(
        FFMPEG,
        "-v",
        "error",
        "-y",
        "-i",
        str(a),
        "-i",
        str(gap),
        "-i",
        str(b),
        "-filter_complex",
        "[0][1][2]concat=n=3:v=0:a=1",
        "-ar",
        str(RATE),
        "-ac",
        "1",
        str(joined),
    )
    (tree / "Recordings").mkdir(parents=True, exist_ok=True)
    run(
        "afconvert",
        "-f",
        "m4af",
        "-d",
        "aac",
        str(joined),
        str(tree / "Recordings" / f"{name}.m4a"),
    )

    gap_start, gap_end = first_length, first_length + middle_length
    after = gap_end
    lines = [
        f"# {name}",
        f"_Расшифровано: {ENGINE}_",
        f"_Режим: {MODE}_",
        f"**[0:00–{stamp(first_length)}]** {first[0]}: {first[1]}",
        f"**[{stamp(after)}–{stamp(after + last_length)}]** {last[0]}: {last[1]}",
        # Так плашку писал ElevenLabs до 6 октября 2026 — в конце файла.
        f"> Пропуск {stamp(gap_start)}–{stamp(gap_end)}: в ответе сервиса нет текста для этого участка.",
    ]
    (tree / "Transcripts").mkdir(parents=True, exist_ok=True)
    (tree / "Transcripts" / f"{name}.md").write_text(
        "\n\n".join(lines) + "\n", encoding="utf-8"
    )
    return [Path("Recordings") / f"{name}.m4a", Path("Transcripts") / f"{name}.md"]


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("device")
    args = parser.parse_args()
    container = safe.container_for(args.device)
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        tree = work / "workspace"
        created = record(
            "Тишина посреди разговора",
            (
                "S1",
                "Давайте начнём с отчёта по затратам. Цифры за сентябрь уже у всех есть.",
            ),
            None,
            (
                "S2",
                "Продолжим. По эксплуатации здания расходы выросли на семь процентов.",
            ),
            work,
            tree,
        )
        created += record(
            "Речь в пропуске",
            ("S1", "Проверяем плашку пропуска на настоящей речи."),
            "Эта фраза звучит в записи, но в расшифровке её нет, и плашка должна остаться.",
            ("S2", "После пропуска разговор продолжается как обычно."),
            work,
            tree,
        )
        safe.copy_new(tree, container, "Documents/Lori/Workspace")
        now = dt.datetime.now().timestamp()
        for relative in created:
            os.utime(container / "Documents/Lori/Workspace" / relative, (now, now))
    print(
        "Added «Тишина посреди разговора» and «Речь в пропуске» to the Lori QA workspace."
    )


if __name__ == "__main__":
    main()
