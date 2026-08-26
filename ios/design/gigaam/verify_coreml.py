"""Сквозная сверка экспорта: три модели Core ML против самой библиотеки GigaAM.

Численное сравнение активаций энкодера мало о чём говорит — fp16 через 16 слоёв
Conformer накапливает заметную разницу, особенно на нереалистичном входе.
Значение имеет итоговый текст, поэтому здесь повторяется весь путь: признаки,
энкодер, greedy RNN-T с переносом состояния LSTM, детокенизация — и результат
сравнивается со тем, что выдаёт библиотека на том же файле.

    /Users/ilyaqa/Projects/GigaAM/.venv/bin/python verify_coreml.py --build ./build
"""

import argparse
from pathlib import Path

import numpy as np


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", default="/tmp/gigaam-build")
    parser.add_argument("--audio", default="/Users/ilyaqa/Projects/GigaAM/example.wav")
    args = parser.parse_args()

    import coremltools as ct
    import gigaam
    import torch

    build = Path(args.build)
    encoder = ct.models.MLModel(str(build / "GigaAM-encoder.mlpackage"))
    prediction = ct.models.MLModel(str(build / "GigaAM-prediction.mlpackage"))
    joint = ct.models.MLModel(str(build / "GigaAM-joint.mlpackage"))
    pieces = (build / "vocab.txt").read_text(encoding="utf-8").rstrip("\n").split("\n")
    blank = len(pieces)

    print("загружаю модель для эталона…")
    model = gigaam.load_model("v3_e2e_rnnt", device="cpu")
    model.eval()

    expected = model.transcribe(args.audio).text
    print("эталон библиотеки:", expected[:160])

    # Окно энкодера фиксировано: берём его из описания входа модели.
    spec = encoder.get_spec()
    window = int(spec.description.input[0].type.multiArrayType.shape[2])
    mels = int(spec.description.input[0].type.multiArrayType.shape[1])

    from gigaam.preprocess import load_audio

    audio = load_audio(args.audio)
    with torch.no_grad():
        features, _ = model.preprocessor(
            audio.unsqueeze(0), torch.tensor([audio.numel()], dtype=torch.int32)
        )
    features = features.numpy()[0]
    print(f"признаков: {features.shape}, окно энкодера: {mels}×{window}")

    # Аудио длиннее окна режется; хвост дополняется тишиной ровно как в приложении.
    silence = float(np.log(1e-9))
    tokens: list[int] = []
    chunks = max(1, -(-features.shape[1] // window))
    for index in range(chunks):
        piece = features[:, index * window:(index + 1) * window]
        if piece.shape[1] < window:
            piece = np.pad(piece, ((0, 0), (0, window - piece.shape[1])), constant_values=silence)
        real = min(window, features.shape[1] - index * window)
        encoded = np.array(encoder.predict({
            "features": piece[None, :, :].astype(np.float32),
            "feature_lengths": np.array([real], dtype=np.int32),
        })["encoded"])
        # [1, D, T] -> [T, D]
        frames = encoded.shape[2]
        dim = encoded.shape[1]
        encoded = encoded[0].T

        state_h = np.zeros((1, 1, 320), dtype=np.float32)
        state_c = np.zeros((1, 1, 320), dtype=np.float32)
        last = blank
        for frame in range(frames):
            for _ in range(10):
                out = prediction.predict({
                    "x": np.array([[last]], dtype=np.int32),
                    "hi": state_h,
                    "ci": state_c,
                })
                dec = np.array(out["dec"]).reshape(1, -1, 1)[:, :320, :]
                logits = np.array(joint.predict({
                    "enc": encoded[frame].reshape(1, dim, 1).astype(np.float32),
                    "dec": dec.astype(np.float32),
                })["joint"]).reshape(-1)
                token = int(np.argmax(logits))
                if token == blank:
                    break
                tokens.append(token)
                last = token
                state_h = np.array(out["ho"], dtype=np.float32)
                state_c = np.array(out["co"], dtype=np.float32)
        print(f"  кусок {index + 1}/{chunks}: токенов всего {len(tokens)}")

    text = "".join(pieces[t] for t in tokens).replace("▁", " ").strip()
    print("Core ML:", text[:160])

    same = text.strip() == expected.strip()
    print("совпадение с библиотекой:", same)
    if not same:
        print("длина эталона:", len(expected), "длина Core ML:", len(text))


if __name__ == "__main__":
    main()
