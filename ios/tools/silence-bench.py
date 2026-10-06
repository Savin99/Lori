#!/usr/bin/env python3
"""Стенд детектора речи в пропусках расшифровки (`AudioLoudness.swift`).

Зачем: 6 октября 2026 владелец увидел плашки «Пропуск 4:19–5:19» и «Пропуск
20:17–20:34» над настоящей тишиной (ElevenLabs, запись 43:28). Прежнее правило —
пик в окне 10 с, полминуты «громких» окон — звало пропуском любую тихую минуту со
щелчком или вдохом. Здесь оба правила, старое и новое, гоняются на одних и тех же
синтетических пропусках, а числа из этой таблицы стоят в `ios/CLAUDE.md`
(раздел «Ложный пропуск на тишине») и в комментариях `AudioLoudness`.

Речь — настоящая, синтезом macOS (`say -v Milena`) или из папки записей
(`--speech`); помехи — синтетические: шум комнаты, щелчки, стуки по столу, кашель,
клавиатура, дверь, вдохи, ровный шум вентилятора. Записей владельца здесь нет:
это стенд правил, а не проверка на его звуке.

    python3 ios/tools/silence-bench.py                       # речь через say
    python3 ios/tools/silence-bench.py --speech <папка m4a>  # готовые записи речи
    python3 ios/tools/silence-bench.py --aac                 # ещё и через AAC 64k

Нужны numpy и ffmpeg (`/opt/homebrew/bin/ffmpeg` или в PATH).
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np

SR = 16000
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"

SENTENCES = [
    "Давайте начнём. Сегодня два вопроса: перенос релиза и бюджет на четвёртый квартал.",
    "По релизу предлагаю сдвинуть на две недели, иначе не успеем с оплатой.",
    "Согласен. Тогда бюджет пересчитываем под новую дату, смету согласует Лёша до пятницы.",
    "Хорошо, я пришлю ему цифры сегодня вечером.",
    "Подрядчик просит ещё две недели на второй этап.",
    "Правки сверх договора предлагаю оплачивать пополам. Решение пришлём письмом до среды.",
    "Главное со встречи: клиент хочет запуск в ноябре, бюджет не меняется.",
    "Расскажите, с чего начинается ваш рабочий день и как вы выбираете задачу.",
    "Здравствуйте, я хотел бы уточнить статус перевода, отправленного в пятницу.",
    "Сегодня мы поговорим о том, как менялись торговые пути в Средиземноморье.",
]


# ---------------------------------------------------------------- звук


def load(path):
    raw = subprocess.run(
        [
            FFMPEG,
            "-v",
            "error",
            "-i",
            path,
            "-ac",
            "1",
            "-ar",
            str(SR),
            "-f",
            "f32le",
            "-",
        ],
        capture_output=True,
        check=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def speech_files(folder):
    if folder:
        return sorted(
            glob.glob(os.path.join(folder, "*.m4a"))
            + glob.glob(os.path.join(folder, "*.wav"))
        )
    work = tempfile.mkdtemp(prefix="silence-bench-")
    paths = []
    for index, text in enumerate(SENTENCES):
        path = os.path.join(work, f"s{index}.aiff")
        subprocess.run(["say", "-v", "Milena", "-o", path, text], check=True)
        paths.append(path)
    return paths


def utterances(paths):
    """Фразы — куски речи между паузами от 0,25 с (кадры 20 мс тише −45 dBFS)."""
    result = []
    for path in paths:
        x = load(path)
        frames = x[: len(x) // 320 * 320].reshape(-1, 320)
        active = 20 * np.log10(np.sqrt((frames**2).mean(1)) + 1e-12) > -45
        i, n = 0, len(active)
        while i < n:
            if not active[i]:
                i += 1
                continue
            j = last = i
            while j < n and (active[j] or j - last < 12):
                if active[j]:
                    last = j
                j += 1
            if (last + 1 - i) * 320 > SR // 2:
                result.append(x[i * 320 : (last + 1) * 320])
            i = j
    if not result:
        sys.exit("речи не нашлось — проверь --speech")
    return result


def g(db):
    return 10 ** (db / 20)


class Bench:
    def __init__(self, utt):
        self.utt = utt
        active = np.concatenate(utt)
        active = active[np.abs(active) > 1e-4]
        self.rms = float(np.sqrt((active**2).mean()))
        self.peak = float(np.percentile(np.abs(np.concatenate(utt)), 99.9))

    # --- речь
    def hesitant(self, u, rng, prob):
        if prob <= 0:
            return u
        frames = u[: len(u) // 320 * 320].reshape(-1, 320)
        db = 20 * np.log10(np.sqrt((frames**2).mean(1)) + 1e-12)
        dips = [i for i in range(2, len(db) - 2) if db[i] < -35 <= db[i - 1]]
        out, last = [], 0
        for i in dips:
            if rng.random() < prob:
                out += [u[last : i * 320], np.zeros(int(rng.uniform(0.25, 0.7) * SR))]
                last = i * 320
        out.append(u[last:])
        return np.concatenate(out)

    def conversation(self, seconds, rng, gain=0.0, pauses=(0.3, 2.5), hesitation=0.0):
        out, spans, t = [], [], 0.0
        while t < seconds:
            u = self.hesitant(self.utt[rng.integers(0, len(self.utt))], rng, hesitation)
            seg = u * g(gain + [0.0, -5.0][rng.integers(0, 2)] + rng.uniform(-2, 2))
            spans.append((t, t + len(seg) / SR))
            out.append(seg)
            t += len(seg) / SR
            pause = float(np.exp(rng.uniform(np.log(pauses[0]), np.log(pauses[1]))))
            out.append(np.zeros(int(pause * SR)))
            t += pause
        x = np.concatenate(out)[: int(seconds * SR)]
        return x, [(a, min(b, seconds)) for a, b in spans if a < seconds]

    # --- помехи
    def noise(self, n, rms, rng):
        # Розоватый шум комнаты: белый через затухающее окно (низы гуще верхов),
        # без постоянной составляющей.
        w = rng.standard_normal(n)
        y = np.convolve(w, np.exp(-np.arange(200) / 33.0), "same")
        y = y - np.convolve(y, np.ones(400) / 400, "same")
        return y / np.sqrt((y**2).mean()) * rms

    @staticmethod
    def click(amp):
        t = np.arange(int(0.003 * SR)) / SR
        return amp * np.exp(-t / 0.0007) * np.where(np.arange(len(t)) % 2 == 0, 1, -1)

    @staticmethod
    def knock(rng, amp):
        t = np.arange(int(0.12 * SR)) / SR
        return (
            amp
            * np.exp(-t / rng.uniform(0.015, 0.04))
            * np.sin(2 * np.pi * rng.uniform(150, 700) * t)
        )

    @staticmethod
    def cough(rng, rms):
        parts = []
        for _ in range(rng.integers(1, 4)):
            t = np.arange(int(rng.uniform(0.2, 0.4) * SR)) / SR
            w = rng.standard_normal(len(t))
            s = np.convolve(w, np.ones(3) / 3, "same") - np.convolve(
                w, np.ones(40) / 40, "same"
            )
            s = s * np.minimum(1, t / 0.01) * np.exp(-t / 0.12)
            parts += [
                s / np.sqrt((s**2).mean()) * rms,
                np.zeros(int(rng.uniform(0.15, 0.35) * SR)),
            ]
        return np.concatenate(parts)

    def typing(self, rng, seconds, amp):
        out, t = np.zeros(int(seconds * SR)), 0.0
        while t < seconds - 0.01:
            c = self.click(amp * rng.uniform(0.5, 1.0))
            i = int(t * SR)
            out[i : i + len(c)] += c[: len(out) - i]
            t += rng.uniform(0.08, 0.25)
        return out

    @staticmethod
    def door(rng, amp):
        t = np.arange(int(0.9 * SR)) / SR
        low = np.convolve(rng.standard_normal(len(t)), np.ones(60) / 60, "same")
        return amp * np.exp(-t / 0.18) * low / np.abs(low).max()

    @staticmethod
    def breath(rng, rms):
        n = int(rng.uniform(0.5, 0.9) * SR)
        w = rng.standard_normal(n)
        s = (w - np.convolve(w, np.ones(8) / 8, "same")) * np.sin(
            np.pi * np.arange(n) / n
        ) ** 2
        return s / np.sqrt((s**2).mean() + 1e-12) * rms

    @staticmethod
    def place(x, s, at):
        i = int(at * SR)
        j = min(len(x), i + len(s))
        x[i:j] += s[: j - i]

    def gap(self, kind, rng, seconds, snr):
        """Наполнение пропуска. Число событий — на минуту, на коротком пропуске меньше."""
        n = int(seconds * SR)
        x = self.noise(n, self.rms * g(-snr), rng)
        per = seconds / 60
        rms, peak = self.rms, self.peak
        name, _, arg = kind.partition(":")

        def times(count, room=1.0):
            return [
                rng.uniform(0, max(0.1, seconds - room))
                for _ in range(max(1, int(round(count * per))))
            ]

        if name == "тишина":
            pass
        elif name == "клики":
            for at in times(10, 0.1):
                self.place(x, self.click(peak * rng.uniform(0.5, 1.5)), at)
        elif name == "стуки":
            for at in times(8, 0.2):
                self.place(x, self.knock(rng, peak * rng.uniform(0.5, 1.5)), at)
        elif name == "кашель":
            for at in times(4, 2):
                self.place(x, self.cough(rng, rms * g(rng.uniform(0, 6))), at)
        elif name == "кашель-подряд":
            for at in times(8, 2):
                self.place(x, self.cough(rng, rms * g(rng.uniform(0, 6))), at)
            for at in times(6, 1):
                self.place(x, self.breath(rng, rms * g(rng.uniform(-14, -8))), at)
        elif name == "клавиатура":
            for at in times(3, 8):
                self.place(
                    x,
                    self.typing(
                        rng,
                        rng.uniform(3, min(8, seconds)),
                        peak * rng.uniform(0.2, 0.6),
                    ),
                    at,
                )
        elif name == "дверь":
            self.place(
                x, self.door(rng, peak * 1.5), rng.uniform(0, max(0.1, seconds - 1))
            )
        elif name == "вдохи":
            t = rng.uniform(0, 3)
            while t < seconds - 1:
                self.place(x, self.breath(rng, rms * g(rng.uniform(-20, -10))), t)
                t += rng.uniform(3, 6)
        elif name == "всё-сразу":
            for at in times(6, 0.1):
                self.place(x, self.click(peak * rng.uniform(0.5, 1.5)), at)
            for at in times(4, 0.2):
                self.place(x, self.knock(rng, peak * rng.uniform(0.5, 1.5)), at)
            for at in times(2, 2):
                self.place(x, self.cough(rng, rms * g(rng.uniform(0, 6))), at)
            if rng.random() < per:
                self.place(
                    x,
                    self.typing(rng, min(5, seconds / 3), peak * 0.4),
                    rng.uniform(0, seconds * 0.6),
                )
            if rng.random() < per:
                self.place(
                    x, self.door(rng, peak * 1.5), rng.uniform(0, max(0.1, seconds - 1))
                )
            t = rng.uniform(0, 3)
            while t < seconds - 1:
                self.place(x, self.breath(rng, rms * g(rng.uniform(-20, -10))), t)
                t += rng.uniform(3, 6)
        elif name == "вентилятор":
            w = np.convolve(rng.standard_normal(n), np.ones(5) / 5, "same")
            x += w / np.sqrt((w**2).mean()) * rms * g(float(arg))
        elif name == "речь":
            sp, _ = self.conversation(seconds + 5, rng, gain=float(arg))
            x += sp[:n]
        elif name == "речь-с-запинками":
            sp, _ = self.conversation(
                seconds + 5, rng, gain=float(arg), pauses=(0.4, 3.0), hesitation=0.5
            )
            x += sp[:n]
        elif name == "фразы":
            # несколько фраз вразброс, всего arg секунд речи
            total = 0.0
            while total < float(arg):
                u = self.utt[rng.integers(0, len(self.utt))]
                self.place(
                    x,
                    u * g(rng.uniform(-5, 0)),
                    rng.uniform(0, max(0.1, seconds - len(u) / SR)),
                )
                total += len(u) / SR
        elif name == "одна-фраза":
            target = float(arg)
            pool = [u for u in self.utt if abs(len(u) / SR - target) <= 1.5] or self.utt
            u = pool[rng.integers(0, len(pool))]
            self.place(x, u, max(0.0, seconds / 2 - len(u) / SR / 2))
        else:
            raise ValueError(kind)
        return x

    def recording(self, kind, seed, gap, snr):
        rng = np.random.default_rng(seed)
        a, sa = self.conversation(60, rng)
        b, sb = self.conversation(60, rng)
        a = a + self.noise(len(a), self.rms * g(-snr), rng)
        b = b + self.noise(len(b), self.rms * g(-snr), rng)
        x = np.concatenate([a, self.gap(kind, rng, gap, snr), b])
        spans = sa + [(s + 60 + gap, e + 60 + gap) for s, e in sb]
        return x, spans, (60.0, 60.0 + gap)


# ---------------------------------------------------------------- правила


def old_rule(x, spans, a, b):
    """До 6 октября 2026: пик в окне 10 с против 0,25 медианы пиков речи; громких
    окон на min(30 с, длина участка)."""
    cands = []
    for s, e in spans:
        t = s
        while True:
            cands.append(t)
            t += 10
            if not t < e:
                break
    step = max(1, len(cands) // 12)
    peaks = sorted(
        np.abs(x[int(c * SR) : int((c + 10) * SR)]).max() for c in cands[::step][:12]
    )
    threshold = max(peaks[len(peaks) // 2] * 0.25, 0.001)
    loud, t = 0.0, a
    while t < b:
        length = min(10.0, b - t)
        if np.abs(x[int(t * SR) : int((t + length) * SR)]).max() >= threshold:
            loud += length
        t += length
    return loud >= min(30.0, b - a)


def windows(x, a, b):
    """Окна 0,5 с; уровень — 80-й перцентиль энергии кадров 20 мс, из неё RMS."""
    out, t = [], a
    while t < b - 1e-9:
        seg = x[int(round(t * SR)) : int(round(min(t + 0.5, b) * SR))]
        if len(seg) < SR // 10:
            break
        k = len(seg) // 320
        energy = (seg[: k * 320].reshape(k, 320) ** 2).mean(1)
        out.append((t, min(t + 0.5, b), float(np.sqrt(np.percentile(energy, 80)))))
        t += 0.5
    return out


def loudness(x, spans, a, b, guard=True):
    """Окна участка и какие из них громкие — порог как у `AudioLoudness.verdict`."""
    levels = [
        lv
        for s, e in spans
        for (ws, we, lv) in windows(x, s, e)
        if s <= (ws + we) / 2 <= e
    ]
    level = float(np.median(levels)) if levels else None
    w = windows(x, a, b)
    if not w:
        return w, np.array([], dtype=bool)
    lv = np.array([v for _, _, v in w])
    threshold = max((level or 0) * 0.25, 0.001)
    if guard:
        noise = float(np.percentile(lv, 10)) * 2
        threshold = max(threshold, min(noise, level * 0.7) if level else noise)
    return w, lv >= threshold


def new_rule(x, spans, a, b, guard=True, bridge=1):
    """С 6 октября 2026 — как `AudioLoudness.verdict`. `guard` и `bridge` — для
    проверки, зачем нужны поправка на фон и склейка (`--ablation`)."""
    w, loud = loudness(x, spans, a, b, guard)
    if not w:
        return False
    length = w[-1][1] - w[0][0]
    need_phrase, need_total = min(4.0, length), min(max(5.0, 0.1 * length), length)
    total, i = 0.0, 0
    while i < len(loud):
        if not loud[i]:
            i += 1
            continue
        end, j, got = i, i + 1, w[i][1] - w[i][0]
        while j < len(loud):
            if loud[j]:
                end, got = j, got + w[j][1] - w[j][0]
            elif j - end > bridge:
                break
            j += 1
        if w[end][1] - w[i][0] >= need_phrase - 1e-3:
            total += got
        i = end + 1
    return total >= need_total - 1e-3


def longest_run(loud):
    best = run = 0
    for flag in loud:
        run = run + 1 if flag else 0
        best = max(best, run)
    return best * 0.5


def aac(x):
    raw = x.astype(np.float32).tobytes()
    enc = subprocess.run(
        [
            FFMPEG,
            "-v",
            "error",
            "-f",
            "f32le",
            "-ar",
            str(SR),
            "-ac",
            "1",
            "-i",
            "-",
            "-ar",
            "44100",
            "-c:a",
            "aac",
            "-b:a",
            "64k",
            "-f",
            "adts",
            "-",
        ],
        input=raw,
        capture_output=True,
        check=True,
    ).stdout
    dec = subprocess.run(
        [
            FFMPEG,
            "-v",
            "error",
            "-f",
            "aac",
            "-i",
            "-",
            "-ac",
            "1",
            "-ar",
            str(SR),
            "-f",
            "f32le",
            "-",
        ],
        input=enc,
        capture_output=True,
        check=True,
    ).stdout
    y = np.frombuffer(dec, dtype=np.float32).astype(np.float64)
    shift = int(np.argmax(np.correlate(y[: 5 * SR + 4000], x[: 5 * SR], "valid")))
    return y[shift : shift + len(x)]


SILENCE = [
    "тишина",
    "клики",
    "стуки",
    "кашель",
    "кашель-подряд",
    "клавиатура",
    "дверь",
    "вдохи",
    "всё-сразу",
    "вентилятор:-15",
    "вентилятор:-9",
    "вентилятор:-6",
    "вентилятор:-3",
]
SPEECH = [
    "одна-фраза:3",
    "одна-фраза:6",
    "фразы:10",
    "фразы:20",
    "речь:0",
    "речь:-6",
    "речь:-10",
    "речь-с-запинками:0",
    "речь-с-запинками:-6",
    "речь-с-запинками:-10",
]


def ablation(bench, seeds):
    """Зачем каждая часть нового правила: что будет без неё."""
    print("\n== поправка на фон: шум комнаты −12 dB, пропуск 60 с — без поправки | с ней")
    for kind in ["тишина", "клики", "стуки", "кашель", "клавиатура", "дверь", "вдохи", "всё-сразу"]:
        off = on = 0
        for seed in range(seeds):
            x, spans, (a, b) = bench.recording(kind, 7000 + seed, 60, 12)
            off += new_rule(x, spans, a, b, guard=False)
            on += new_rule(x, spans, a, b)
        print(f"{kind:22s}  {off:3d} | {on:<3d} из {seeds}")

    print("\n== склейка одного тихого окна: шум −25 dB — без склейки | со склейкой")
    for gap in (60, 17):
        for kind in ["речь-с-запинками:0", "речь-с-запинками:-6", "кашель-подряд", "всё-сразу"]:
            off = on = 0
            for seed in range(seeds):
                x, spans, (a, b) = bench.recording(kind, 8000 + seed, gap, 25)
                off += new_rule(x, spans, a, b, bridge=0)
                on += new_rule(x, spans, a, b)
            print(f"пропуск {gap:2d} с  {kind:22s}  {off:3d} | {on:<3d} из {seeds}")

    print("\n== самая длинная серия громких окон, шум −25 dB, пропуск 60 с (макс. / 95-й перцентиль)")
    for kind in ["кашель", "кашель-подряд", "дверь", "вдохи", "клики", "стуки", "клавиатура", "всё-сразу"]:
        runs = []
        for seed in range(seeds):
            x, spans, (a, b) = bench.recording(kind, 9000 + seed, 60, 25)
            runs.append(longest_run(loudness(x, spans, a, b)[1]))
        print(f"{kind:22s}  {max(runs):4.1f} с / {np.percentile(runs, 95):4.1f} с")

    print("\n== доля громких окон в пропуске, полном речи, шум −25 dB")
    for kind in ["речь:0", "речь:-6", "речь-с-запинками:0"]:
        shares = []
        for seed in range(seeds):
            x, spans, (a, b) = bench.recording(kind, 9500 + seed, 60, 25)
            shares.append(float(np.mean(loudness(x, spans, a, b)[1])))
        print(f"{kind:22s}  {np.mean(shares) * 100:4.0f}% (от {min(shares) * 100:.0f}% до {max(shares) * 100:.0f}%)")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--speech",
        help="папка с записями речи (m4a/wav); без неё — синтез say -v Milena",
    )
    parser.add_argument("--seeds", type=int, default=30)
    parser.add_argument(
        "--ablation",
        action="store_true",
        help="только проверка частей правила: поправка на фон, склейка, длина серий",
    )
    parser.add_argument(
        "--aac", action="store_true", help="прогнать ещё и через AAC 64 кбит/с"
    )
    args = parser.parse_args()

    bench = Bench(utterances(speech_files(args.speech)))
    print(
        f"речь: {len(bench.utt)} фраз, {sum(len(u) for u in bench.utt) / SR:.1f} с; RMS {bench.rms:.3f}"
    )

    def table(gap, snrs, kinds, transform=None):
        print(
            f"\n== пропуск {gap:.0f} с: сколько из {args.seeds} названо пропуском — старое правило | новое"
        )
        print(f"{'':22s}" + "".join(f"  шум −{snr} dB " for snr in snrs))
        for kind in kinds:
            cells = []
            for snr in snrs:
                old = new = 0
                for seed in range(args.seeds):
                    x, spans, (a, b) = bench.recording(kind, 1000 * snr + seed, gap, snr)
                    if transform:
                        x = transform(x)
                    old += old_rule(x, spans, a, b)
                    new += new_rule(x, spans, a, b)
                cells.append(f"{old:5d} | {new:<4d}")
            print(f"{kind:22s}" + "".join(f"  {c}" for c in cells))

    if args.ablation:
        ablation(bench, args.seeds)
        return
    table(60, (30, 20, 12), SILENCE + SPEECH)
    for gap in (30, 17, 10):
        table(
            gap,
            (25, 15),
            [
                "всё-сразу",
                "кашель-подряд",
                "вентилятор:-9",
                "речь:0",
                "речь-с-запинками:0",
                "речь-с-запинками:-6",
            ],
        )
    if args.aac:
        table(
            60,
            (25,),
            [
                "клики",
                "стуки",
                "клавиатура",
                "кашель",
                "всё-сразу",
                "вдохи",
                "речь:0",
                "речь-с-запинками:0",
                "фразы:10",
            ],
            transform=aac,
        )


if __name__ == "__main__":
    main()
