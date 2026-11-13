#!/bin/bash
# Короткие синтетические файлы: никакой личной речи и сетевых источников.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
dest="$root/LoriLocalTests/Fixtures/Formats"
mkdir -p "$dest"
ffmpeg_bin="${LORI_FFMPEG:-ffmpeg}"
audio() { "$ffmpeg_bin" -nostdin -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1.6' "$@"; }
audio -c:a libopus -b:a 24k "$dest/opus.ogg"
cp "$dest/opus.ogg" "$dest/opus.oga"
cp "$dest/opus.ogg" "$dest/opus.opus"
# Сборка ffmpeg владельца без libvorbis: штатный экспериментальный Vorbis.
audio -ac 2 -c:a vorbis -strict -2 -b:a 48k "$dest/vorbis.ogg"
audio -c:a flac "$dest/lossless.flac"
audio -c:a mp2 -b:a 64k "$dest/layer2.mp2"
audio -c:a ac3 -b:a 96k "$dest/dolby.ac3"
audio -ac 1 -ar 16000 -c:a aac -b:a 32k -f 3gp "$dest/mobile.3gp"
audio -c:a pcm_mulaw "$dest/mulaw.wav"
audio -c:a libopus -b:a 24k "$dest/voice.webm"
audio -c:a aac -b:a 48k "$dest/matroska.mkv"
audio -c:a wmav2 -b:a 32k "$dest/windows.wma"
for suffix in mp4 mov; do
  "$ffmpeg_bin" -nostdin -hide_banner -loglevel error -y -f lavfi -i 'color=c=green:s=32x32:r=10:d=1.6' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1.6' -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 48k -shortest "$dest/video.$suffix"
done
# У видео может быть немой хвост: сравнивать нужно звук, а не длину видеоряда.
"$ffmpeg_bin" -nostdin -hide_banner -loglevel error -y -f lavfi -i 'color=c=green:s=32x32:r=10:d=4' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1.6' -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 48k "$dest/sparse-audio.mov"
printf 'broken ogg fixture\n' > "$dest/broken.ogg"
# Форматы для прежних тестов копирования: теперь импорт обязан проверять звук.
audio -c:a aac -b:a 48k "$dest/reference.m4a"
audio -c:a libmp3lame -b:a 32k "$dest/reference.mp3"
audio -c:a pcm_s16le -ar 16000 "$dest/reference.wav"
audio -c:a aac -b:a 48k -f adts "$dest/reference.aac"
# AMR/AMR-WB в этой сборке ffmpeg не кодируются — образца здесь нет.
