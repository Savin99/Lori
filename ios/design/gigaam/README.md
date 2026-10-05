# GigaAM на iPhone

Состояние на 27 августа 2026. Модель запускается на телефоне через **ONNX Runtime**
и скачивается из приложения одной кнопкой.

## Почему ONNX, а не Core ML

Готового Core ML-экспорта GigaAM не публикует никто: на HuggingFace лежат ONNX, MLX и GGUF.
Экспорт в Core ML пришлось бы делать самому на Mac с `coremltools` (модель 845 МБ в fp32,
на 8 ГБ памяти конвертация не проходит), а потом ещё где-то раздавать файлы — то есть
человеку всё равно пришлось бы что-то настраивать руками. Поэтому взят открытый ONNX-экспорт
[`istupakov/gigaam-v3-onnx`](https://huggingface.co/istupakov/gigaam-v3-onnx): публичный,
без ключей и регистрации, int8-варианты по ~225 МБ.

В приложение добавлен официальный SPM-пакет
[`onnxruntime-swift-package-manager`](https://github.com/microsoft/onnxruntime-swift-package-manager).
Core ML-провайдер подключается «по возможности»: квантованные графы он часто отдаёт обратно
на CPU, и это нормально.

## Что качается

| Вариант | Файлы | Размер |
| --- | --- | --- |
| `rnnt` (по умолчанию) | `v3_e2e_rnnt_encoder.int8.onnx`, `..._decoder...`, `..._joint...`, `v3_e2e_rnnt_vocab.txt` | ~226 МБ |
| `ctc` | `v3_e2e_ctc.int8.onnx`, `v3_e2e_ctc_vocab.txt` | ~225 МБ |

Размеры и SHA-256 зашиты в `GigaAMCatalog.swift` и сверяются после скачивания: файл, который
не совпал, не устанавливается, и папка модели остаётся прежней. Файлы качаются по одному —
архива нет, потому что распаковывать zip на iOS нечем без сторонней библиотеки.

## Интерфейс графов

Проверено по `onnx-asr` (он потребляет ровно эти файлы) и живым прогоном в симуляторе:

```text
RNN-T  encoder:  audio_signal [1,64,T] + length [1]  ->  encoded [1,768,T'] + encoded_len
       decoder:  x [1,1] + h.1 [1,1,320] + c.1 [1,1,320]  ->  dec + h + c
       joint:    enc [1,768,1] + dec [1,320,1]  ->  joint [1,1,1,1025]
CTC    model:    features [1,64,T] + feature_lengths [1]  ->  log_probs [1,T',257]
```

Длины объявлены как int64, но встречаются сборки с int32 — `OnnxSession` пробует второй тип
и запоминает удачный. Порядок осей `log_probs` проверяется по числу классов, а не берётся
на веру. Словарь лежит строками «кусок пробел индекс», последняя строка — `<blk>`; blank
в проекте живёт за словарём, поэтому эта строка отбрасывается.

## Препроцессинг: брать из конфига, а не из кода

`gigaam/preprocess.py` содержит дефолты `win_length = sample_rate // 40` (400) и `center=True`,
но **реальный конфиг v3 другой** (см. `v3_e2e_rnnt.yaml` в репозитории модели):

| параметр | значение |
| --- | --- |
| sample_rate | 16000 |
| features (n_mels) | 64 |
| n_fft | 320 |
| win_length | 320 |
| hop_length | 160 |
| mel_scale | htk |
| mel_norm | null |
| center | false |

Именно эти числа стоят в `LogMelSpectrogram`. Ошибка здесь не ломает запуск — она тихо
портит качество.

## Проверка на настоящей модели

Модель в репозиторий не входит. Для интеграционного теста её кладут в контейнер приложения
в симуляторе:

```bash
BASE=https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/main
mkdir -p models/GigaAM-v3-ctc
curl -L -o models/GigaAM-v3-ctc/v3_e2e_ctc.int8.onnx "$BASE/v3_e2e_ctc.int8.onnx"
curl -L -o models/GigaAM-v3-ctc/v3_e2e_ctc_vocab.txt "$BASE/v3_e2e_ctc_vocab.txt"

./design/qa/seed-audio.sh <udid>              # русская фраза в рабочую папку
./design/gigaam/seed-models.sh <udid> models   # модели в Application Support
xcodebuild -project LoriLocal.xcodeproj -scheme LoriLocal \
  -destination 'id=<udid>' -only-testing:LoriLocalTests/GigaAMOnnxIntegrationTests \
  CODE_SIGNING_ALLOWED=NO test
```

Без модели или без аудио тест пропускается, а не падает.

## Окно и нарезка

Окно энкодера графом не задано — входы динамические. Куски всё равно режутся по 20 секунд:
внимание в Conformer глобальное, и память растёт квадратично по длине. Границы ищутся по
тишине, куски перекрываются (`AudioChunker`), дубли из перекрытия отбрасываются по времени
в `TranscriptAssembler.merge`. Тайминги слов считаются как в `gigaam/timestamps_utils.py`:
шаг кадра — длительность куска, поделённая на число кадров энкодера.


## Замеры 27 августа 2026 (симулятор iPhone 17 Pro, CPU Mac)

Запись 2 минуты 42 секунды, RNN-T int8, куски по 12 секунд:

| что | значение |
| --- | --- |
| загрузка энкодера | ~1,1 с |
| один кусок (12 с аудио) | ~0,8–1,3 с |
| вся запись (16 кусков) | ~14 с |
| память процесса | 31–273 МБ, без роста от куска к куску |
| текст | полный и с пунктуацией, одна опечатка в слове на 2500 символов |

Память гуляет, потому что веса читаются с диска отображением в память: резидентная
часть то растёт, то отдаётся системе. Утечки нет — это и проверялось.

Смотреть эти же числа на телефоне:

```bash
log stream --device-udid <udid> --predicate 'subsystem == "ru.ilyaqa.lori.local"'
# или после факта, включая прошлые запуски:
xcrun simctl spawn <udid> log show --last 5m --predicate 'subsystem == "ru.ilyaqa.lori.local"'
```

Записи идут уровнем `notice`: `info` живёт только в памяти и после вылета приложения
не читается, а нужен он ровно тогда.
