"""Экспорт GigaAM v3 e2e RNN-T в Core ML для Lori iOS.

RNN-T распадается на три модели, и они экспортируются по одной в отдельных
процессах: пик памяти тогда равен самой большой части (энкодер), а не их сумме.

    /Users/ilyaqa/Projects/GigaAM/.venv/bin/python export_coreml.py --out ./build

Проверка ресурсов делается перед каждой частью: AGENTS.md запрещает тяжёлые
прогоны без замера, а на 16 ГБ машине конвертация Conformer уводит систему в свап.

Что получается на выходе:
    GigaAM-encoder.mlpackage     features[1,64,T] + lengths[1] -> encoded[1,768,T'] + encoded_lengths[1]
    GigaAM-prediction.mlpackage  x[1,1] + hi[1,1,320] + ci[1,1,320] -> dec[1,1,320] + ho + co
    GigaAM-joint.mlpackage       enc[1,768,1] + dec[1,320,1] -> joint[1,1,1,1025]
    vocab.txt                    1024 куска sentencepiece, blank = 1024
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Части различаются на два порядка: энкодер — Conformer на 240M параметров,
# предиктор — эмбеддинг плюс однослойный LSTM 320, joint — два линейных слоя.
# Поэтому порог по памяти у них свой.
# Оценка пика: модель fp32 около 1 ГБ, копия под трассировку ещё столько же,
# граф MIL в coremltools примерно вдвое от модели. Итого 3–4 ГБ на энкодер.
# Пик зависит от окна трассировки: ось времени в готовой модели всё равно
# динамическая (RangeDim), поэтому трассировать можно коротким отрезком —
# активации при конвертации падают в разы. Замеренный пик см. в README.
MIN_FREE_RAM_GB = {"encoder": 1.5, "prediction": 1.0, "joint": 1.0}
MIN_FREE_DISK_GB = 5.0
MODEL_NAME = "v3_e2e_rnnt"
PARTS = ("encoder", "prediction", "joint")


def free_ram_gb() -> float:
    """Сколько можно занять, не уходя в свап.

    Размер страницы читается из вывода `vm_stat`: на Apple Silicon он 16 КБ,
    и захардкоженные 4096 давали заниженную вчетверо оценку.
    `Pages inactive` не учитываем — это занятая, хоть и вытесняемая память.
    Ориентир тот же, что `top` показывает как unused.
    """
    out = subprocess.run(["vm_stat"], capture_output=True, text=True, check=True).stdout
    page_size = 4096
    header = re.search(r"page size of (\d+) bytes", out)
    if header:
        page_size = int(header.group(1))
    pages = {}
    for line in out.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            digits = value.strip().rstrip(".")
            if digits.isdigit():
                pages[key.strip()] = int(digits)
    usable = (
        pages.get("Pages free", 0)
        + pages.get("Pages speculative", 0)
        + pages.get("Pages purgeable", 0)
    )
    return usable * page_size / 1024 ** 3


def swap_used_gb() -> float:
    out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True, check=True).stdout
    match = re.search(r"used\s*=\s*([0-9.]+)M", out)
    return float(match.group(1)) / 1024 if match else 0.0


def preflight(part: str) -> None:
    ram, disk, swap = free_ram_gb(), shutil.disk_usage(Path.home()).free / 1024 ** 3, swap_used_gb()
    print(f"[{part}] свободно RAM: {ram:.1f} ГБ, диска: {disk:.1f} ГБ, в свапе: {swap:.1f} ГБ")
    if swap > 6.0:
        print(f"[{part}] предупреждение: машина уже в свапе, конвертация будет упираться в диск")
    required = MIN_FREE_RAM_GB[part]
    problems = []
    if ram < required:
        problems.append(f"нужно хотя бы {required:.1f} ГБ свободной RAM")
    if disk < MIN_FREE_DISK_GB:
        problems.append(f"нужно хотя бы {MIN_FREE_DISK_GB:.0f} ГБ свободного диска")
    if problems:
        sys.exit(f"[{part}] отказ: " + "; ".join(problems) + ". Закрой лишнее и повтори.")
    try:
        import coremltools  # noqa: F401
    except ImportError:
        sys.exit("Нет coremltools. Установи: pip install 'coremltools>=8.0'")


def patch_scalar_cast() -> None:
    """coremltools 9 против numpy 2.

    Для узла `aten::Int` конвертер делает `int(x.val)`, а numpy 2 больше не приводит
    массив из одного элемента к скаляру — падает «only 0-dimensional arrays can be
    converted to Python scalars». В графе энкодера такие узлы есть: длины после
    свёрточного сабсэмплинга. Заплатка приводит массив из одного элемента к 0-мерному.
    """
    from coremltools.converters.mil.frontend.torch import ops
    from coremltools.converters.mil.mil import Builder as mb

    original = ops._cast

    def patched(context, node, dtype, dtype_str):
        x = context[node.inputs[0]]
        value = getattr(x, "val", None)
        if value is not None and getattr(value, "ndim", 0) > 0 and value.size == 1:
            context.add(mb.const(val=dtype(value.reshape(())), name=node.name))
            return
        return original(context, node, dtype, dtype_str)

    ops._cast = patched


def export_part(part: str, out_dir: Path, seconds: float) -> None:
    preflight(part)

    import coremltools as ct
    import numpy as np

    patch_scalar_cast()
    import gigaam
    import torch

    print(f"[{part}] загружаю {MODEL_NAME}…")
    model = gigaam.load_model(MODEL_NAME, device="cpu")
    model.eval()
    cfg = model.cfg.preprocessor
    target = out_dir / f"GigaAM-{part}.mlpackage"

    if part == "encoder":
        # Вход — лог-мел признаки фиксированной длины плюс НАСТОЯЩАЯ длина куска.
        #
        # Длина обязательна: из неё строится маска паддинга, а внимание в Conformer
        # глобальное — без маски модель считает валидными все кадры окна, включая
        # тишину в хвосте, и портит реальные. Проверено: с константной длиной
        # терялось первое слово записи.
        #
        # Само окно фиксированное, потому что в граф запекается длина
        # последовательности (`view(t, b, h, d_k)` в rotary-внимании).
        # Приложение дополняет хвост тишиной log(1e-9) и передаёт реальную длину.
        samples = int(seconds * cfg.sample_rate)
        frames = (samples - cfg.win_length) // cfg.hop_length + 1
        features = torch.randn(1, cfg.features, frames)
        lengths = torch.tensor([frames], dtype=torch.int32)

        class Encoder(torch.nn.Module):
            def __init__(self, encoder):
                super().__init__()
                self.encoder = encoder

            def forward(self, features, feature_lengths):
                encoded, encoded_lengths = self.encoder(features, feature_lengths)
                return encoded, encoded_lengths

        module = Encoder(model.encoder).eval()
        with torch.no_grad():
            reference = tuple(t.clone() for t in module(features, lengths))
        traced = torch.jit.trace(module, (features, lengths), strict=False, check_trace=False)
        inputs = [
            ct.TensorType(name="features", shape=(1, cfg.features, frames), dtype=np.float32),
            ct.TensorType(name="feature_lengths", shape=(1,), dtype=np.int32),
        ]
        outputs = [
            ct.TensorType(name="encoded", dtype=np.float32),
            ct.TensorType(name="encoded_lengths", dtype=np.int32),
        ]
        verification = (features, lengths, reference, frames)

    elif part == "prediction":
        decoder = model.head.decoder
        hidden, layers = decoder.pred_hidden, decoder.lstm.num_layers
        label = torch.zeros(1, 1, dtype=torch.int32)
        state_h = torch.zeros(layers, 1, hidden)
        state_c = torch.zeros(layers, 1, hidden)

        class Prediction(torch.nn.Module):
            def __init__(self, decoder):
                super().__init__()
                self.decoder = decoder

            def forward(self, x, hi, ci):
                dec, (ho, co) = self.decoder.predict(x, (hi, ci), batch_size=1)
                return dec, ho, co

        module = Prediction(decoder).eval()
        traced = torch.jit.trace(module, (label, state_h, state_c), strict=False)
        inputs = [
            ct.TensorType(name="x", shape=(1, 1), dtype=int),
            ct.TensorType(name="hi", shape=(layers, 1, hidden), dtype=np.float32),
            ct.TensorType(name="ci", shape=(layers, 1, hidden), dtype=np.float32),
        ]
        outputs = [
            ct.TensorType(name="dec", dtype=np.float32),
            ct.TensorType(name="ho", dtype=np.float32),
            ct.TensorType(name="co", dtype=np.float32),
        ]

    else:
        joint = model.head.joint
        encoder_dim = model.cfg.head.joint.enc_hidden
        enc = torch.zeros(1, encoder_dim, 1)
        dec = torch.zeros(1, joint.pred_hidden, 1)
        module = joint.eval()
        traced = torch.jit.trace(module, (enc, dec), strict=False)
        inputs = [
            ct.TensorType(name="enc", shape=(1, encoder_dim, 1), dtype=np.float32),
            ct.TensorType(name="dec", shape=(1, joint.pred_hidden, 1), dtype=np.float32),
        ]
        outputs = [ct.TensorType(name="joint", dtype=np.float32)]

    print(f"[{part}] конвертирую в Core ML (fp16)…")
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        outputs=outputs,
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.save(str(target))
    size = sum(f.stat().st_size for f in target.rglob("*")) / 1024 ** 2
    print(f"[{part}] готово: {target.name} ({size:.0f} МБ)")

    if part == "encoder":
        features, lengths, reference, frames = verification

        predicted = mlmodel.predict({
            "features": features.numpy(),
            "feature_lengths": lengths.numpy().astype(np.int32),
        })
        expected = reference[0].numpy()
        got = np.array(predicted["encoded"])
        if got.shape != expected.shape:
            sys.exit(f"[encoder] формы разошлись: PyTorch {expected.shape}, Core ML {got.shape}")
        deviation = float(np.abs(got - expected).max())
        scale = float(np.abs(expected).max())
        print(f"[encoder] справочно, сверка с PyTorch на шуме: max|Δ| = {deviation:.4f} при масштабе {scale:.2f}")
        # Это только справка, а не приёмка. Сравнивать активации бессмысленно: fp16
        # через 16 слоёв Conformer накапливает заметную разницу, а на случайном входе
        # она ещё и раздувается — на шуме внимание плохо обусловлено.
        # Настоящая проверка в verify_coreml.py: он сверяет ИТОГОВЫЙ ТЕКСТ с тем,
        # что выдаёт сама библиотека на example.wav.
        print(
            f"[encoder] окно фиксировано: {frames} кадров признаков "
            f"= {frames * cfg.hop_length + cfg.win_length} отсчётов (~{seconds:.0f} с аудио)"
        )


def dump_vocabulary(out_dir: Path) -> None:
    import sentencepiece as spm

    candidates = list(
        Path.home().glob(".cache/huggingface/hub/models--ai-sage--GigaAM-v3/snapshots/*/tokenizer.model")
    )
    if not candidates:
        print("токенизатор не найден, словарь не выгружен")
        return
    sp = spm.SentencePieceProcessor()
    sp.Load(str(candidates[0]))
    pieces = [sp.IdToPiece(i) for i in range(sp.GetPieceSize())]
    (out_dir / "vocab.txt").write_text("\n".join(pieces) + "\n", encoding="utf-8")
    meta = {"pieces": len(pieces), "blankIndex": len(pieces), "classCount": len(pieces) + 1}
    (out_dir / "vocab.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(f"словарь: {len(pieces)} кусков, blank = {len(pieces)}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="./build")
    # 25 секунд — это LONGFORM_THRESHOLD из самой библиотеки: дольше модель за раз
    # не обрабатывает, а на окне 45 секунд она теряла начало записи.
    parser.add_argument("--seconds", type=float, default=25.0, help="фиксированное окно энкодера")
    parser.add_argument("--part", choices=PARTS, help="служебный режим: одна часть в этом процессе")
    args = parser.parse_args()

    out_dir = Path(args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.part:
        export_part(args.part, out_dir, args.seconds)
        return

    # Каждая часть в своём процессе: память освобождается полностью между ними.
    for part in PARTS:
        result = subprocess.run(
            [sys.executable, os.path.abspath(__file__), "--out", str(out_dir),
             "--seconds", str(args.seconds), "--part", part]
        )
        if result.returncode != 0:
            sys.exit(f"часть «{part}» не собралась, код {result.returncode}")
    dump_vocabulary(out_dir)
    print("все три части и словарь готовы:", out_dir)


if __name__ == "__main__":
    main()
