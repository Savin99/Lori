# GigaAM на iPhone — что измерено и что осталось

Состояние на 24 августа 2026. Ничего тяжёлого пока не запускалось.

## Что есть на Mac

- `/Users/ilyaqa/Projects/GigaAM` — библиотека с собственным экспортом в ONNX (`GigaAMASR._to_onnx`).
  В venv стоят torch 2.12, onnx 1.19, onnxruntime 1.23, sentencepiece. **coremltools не установлен.**
- В кеше HuggingFace только `v3_e2e_rnnt`: `pytorch_model.bin` 428 МБ + `tokenizer.model` 252 КБ.
  Готовых ONNX-экспортов нет — `triton_scripts/repos/*_onnx` содержат только `config.pbtxt`.

## Целевая модель: v3_e2e_rnnt

Выбор владельца: она уже скачана (428 МБ в кеше HuggingFace), стоит в production
(`transcribe_md.py`, `DEFAULT_MODEL = "v3_e2e_rnnt"`) и по качеству RNN-T обычно
обходит CTC на том же энкодере. Дополнительного скачивания не требуется.

Пунктуацию и заглавные буквы расставляет сама модель: в словаре есть
`. , ? ! : ; — « » ...` и 188 кусков с заглавной кириллицей. Отдельная модель
для пунктуации не нужна — это и означает `e2e` в названии.

## Цена RNN-T против CTC

Библиотека пишет: «`ctc`: exported entirely in encoder-decoder format, `rnnt`: exported in
encoder/decoder/joint parts separately». То есть RNN-T — это три модели Core ML вместо одной
и авторегрессивный цикл на Swift. Оба декодера уже написаны и покрыты тестами
(`CTCGreedyDecoder`, `RNNTGreedyDecoder`), так что переключиться на CTC можно в любой момент,
если экспорт трёх частей окажется болезненным.

## Препроцессинг: брать из конфига, а не из кода

`gigaam/preprocess.py` содержит дефолты `win_length = sample_rate // 40` (400) и `center=True`,
но **реальный конфиг v3 другой**:

| параметр | значение |
| --- | --- |
| sample_rate | 16000 |
| features (n_mels) | 64 |
| n_fft | 320 |
| win_length | 320 |
| hop_length | 160 |
| center | **false** |
| mel_scale | htk |
| mel_norm | null (нет нормализации фильтров) |
| power | 2.0 (дефолт torchaudio) |
| f_min / f_max | 0 / 8000 |
| логарифм | натуральный, вход зажат в [1e-9, 1e9] |
| длина выхода | `floor((samples - 320) / 160) + 1` |

Свифтовый фронтенд должен повторить это бит-в-бит, иначе распознавание деградирует молча.
Сверять надо не «на слух», а по числам: посчитать лог-мел одного файла в torchaudio и в Swift
и сравнить максимальное отклонение.

## Модель

Conformer: 16 слоёв, `d_model=768`, `subsampling_factor=4`, rotary attention, `feat_in=64`.
~240M параметров: fp32 — 428 МБ, fp16 в Core ML ожидается ~240 МБ. В бандл приложения такое
кладут неохотно — правильнее докачивать при первом использовании.

Словарь sentencepiece: 1024 куска, маркер начала слова `▁`. Для CTC число классов = 1025
(blank последним). Детокенизация: склеить куски, `▁` заменить на пробел.

## Замер на живом iPhone 16 Pro Max / iOS 26.5 (25 августа 2026)

Ключевой факт, из-за которого движок Apple для русского не годится как основной:

- `SpeechTranscriber` (новый, iOS 26) знает **30 локалей, русского среди них нет**:
  de-AT/CH/DE, en-AU/CA/GB/IE/IN/NZ/SG/US/ZA, es-CL/ES/MX/US, fr-BE/CA/CH/FR, it-CH/IT,
  ja-JP, ko-KR, pt-BR/PT, yue-CN, zh-CN/HK/TW.
- `SpeechTranscriber.supportedLocale(equivalentTo: ru_RU)` при этом **возвращает «ru-RU»** —
  API врёт, и попытка скачать модель заканчивается
  `transcription.ru asset unavailable after attempted download, final state: Not Installing`.
- Классический `SFSpeechRecognizer` русский умеет и работает на устройстве
  (`supportsOnDeviceRecognition = true`). На 14-секундном файле выдал почти точный текст за секунду.
  Его ограничение — `SFSpeechURLRecognitionRequest` рассчитан на короткую диктовку, длинные записи
  придётся резать на куски.

Отсюда и смысл GigaAM: для длинного русского аудио у Apple нет подходящего пути ни в новом
движке, ни в старом.

## Что уже сделано на стороне Swift

`LoriLocal/Services/RNNTGreedyDecoder.swift` — greedy-цикл RNN-T, повторяющий
`RNNTGreedyDecoding.decode` для батча из одного элемента. Нейронные части спрятаны за
протоколом `RNNTNetwork`, поэтому цикл тестируется заглушкой, без модели.
Главное, что легко переврать и что закреплено тестом: **на blank ни последний токен,
ни состояние LSTM не обновляются**. Ограничитель `maxSymbolsPerStep` (в библиотеке 10)
не даёт кадру выпускать токены бесконечно.

`LoriLocal/Services/CTCGreedyDecoder.swift` и `SentencePieceVocabulary.swift` — тот же путь
для CTC и общая детокенизация: склейка кусков, `▁` → пробел. Blank — индекс сразу за словарём
(1024 при 1025 классах), как в `gigaam/decoding.py`.


`LoriLocal/Services/LogMelSpectrogram.swift` — фронтенд признаков, сверенный с torchaudio
(`LoriLocalTests/LogMelSpectrogramTests.swift`, эталон в `LoriLocalTests/Fixtures/`).
DFT длины 320 берётся через vDSP: 320 = 5 × 2⁶, такие длины он умеет, хотя это и не степень двойки.

Про метрику сверки: сравнивать логарифмы напрямую нельзя. У чистого тона почти все мел-полосы
лежат на уровне 1e-9, и там две разные реализации float32-FFT расходятся в последних битах —
в логарифме это выглядит как отклонение 0.05 при значении −20.4, хотя линейная разница 5e-11.
Поэтому строгий порог применяется к полосам с реальной энергией, а остальные сверяются
по относительной линейной мощности.

## Состояние на 25 августа 2026

Готово и покрыто тестами, модель для этого не нужна:

| файл | что делает |
| --- | --- |
| `LogMelSpectrogram.swift` | признаки по параметрам config.json, сверены с torchaudio |
| `RNNTGreedyDecoder.swift` | greedy-цикл RNN-T, нейросети за протоколом `RNNTNetwork` |
| `CTCGreedyDecoder.swift` | тот же путь для CTC, если RNN-T окажется болезненным |
| `SentencePieceVocabulary.swift` | детокенизация, blank = индекс за словарём |
| `AudioSamples.swift` | любой аудиофайл → моно float 16 кГц |
| `GigaAMCoreML.swift` | `RNNTNetwork` и энкодер поверх трёх `MLModel` |
| `LocalTranscriber.swift` | полный путь: аудио → признаки → энкодер → декодер |

`coremltools 9.0` установлен в venv GigaAM (добавились только `cattrs` и `pyaml`,
`torch 2.12` и `numpy 2.4.6` не тронуты). Предупреждение самого coremltools:
с torch новее 2.7 он не тестировался, на конвертации возможны неподдержанные операции.

Не сделано: экспорт трёх частей. Упирается в память, а не в код.
Замер 25 августа: 0.7 ГБ свободно, 14.6 ГБ в свапе, компрессор держит 7.3 ГБ
поверх ~900 процессов. Остановка 13 контейнеров Docker хосту память не вернула —
Docker не отдаёт footprint виртуалки при остановке контейнеров, для этого нужен
перезапуск Docker Desktop.

## Порядок работ

1. Освободить RAM (нужно ≥6 ГБ свободных) и диск (≥12 ГБ). На момент замера было 0.7 ГБ и 11 ГБ.
2. `pip install 'coremltools>=8.0'` в venv GigaAM.
3. `python export_coreml.py --model v3_e2e_ctc --out ./build` — скрипт сам проверит ресурсы и откажется, если мало.
4. Сверить лог-мел Swift против torchaudio на `example.wav` из репозитория GigaAM.
5. ~~STFT + мел-банк + натуральный лог, greedy-декодеры, детокенизация~~ — сделано и покрыто тестами.
   Осталось соединить их с моделями Core ML: `RNNTNetwork` — это три `MLModel` (encoder, prediction, joint)
   с переносом состояния LSTM между вызовами.
6. Подставить `GigaAMCoreMLTranscriber` вместо заглушки — интерфейс `LocalTranscribing` уже готов,
   менять больше ничего не нужно.
7. Замерить на устройстве: время расшифровки минуты речи и пик памяти. Только после этого можно
   утверждать, что GigaAM работает на iPhone.
