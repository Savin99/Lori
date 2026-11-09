#!/usr/bin/env python3
"""Add synthetic approved Granola content to one explicit QA simulator; preserve other records."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

spec = importlib.util.spec_from_file_location('safe_container', Path(__file__).with_name('safe-container.py'))
safe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safe)
container = safe.container_for(sys.argv[1])
# Stop before merging stores so the running app cannot write an older snapshot back.
subprocess.run(['xcrun', 'simctl', 'terminate', sys.argv[1], safe.QA_BUNDLE], capture_output=True)
name = 'Granola Approved QA'
record = name + '.m4a'
workspace = container / 'Documents/Lori/Workspace'
with tempfile.TemporaryDirectory() as temp:
    seed = Path(temp) / 'seed'
    (seed / 'Transcripts').mkdir(parents=True)
    (seed / 'Reports').mkdir()
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'anullsrc=r=16000:cl=mono', '-t', '872',
                    '-c:a', 'aac', '-b:a', '16k', str(seed / record)], check=True)
    lines = [
        ('0:00', '0:40', 'S1', 'Давайте честно: фон ещё не готов. На моём телефоне запись дважды обрывалась при звонке.'),
        ('0:42', '1:10', 'S2', 'Обрывалась совсем или ставилась на паузу? Если пауза — это мы уже лечили.'),
        ('4:12', '4:58', 'S1', 'Совсем. Поэтому предлагаю перенести релиз на среду и до пятницы дописать тесты.'),
        ('4:58', '5:46', 'S2', 'Согласен. Тогда к четвергу обновлю инструкцию по выпуску.'),
        ('9:30', '10:08', 'S1', 'И вопрос: нам вообще нужен отчёт в PDF, или Markdown хватит?'),
    ]
    transcript = '# Перенос релиза Лори\n\n_Расшифровано: Проверочный движок QA, на этом iPhone_\n\n' + '\n\n'.join(
        f'**[{start}–{end}]** {speaker}: {text}' for start, end, speaker, text in lines) + '\n'
    (seed / 'Transcripts' / (name + '.md')).write_text(transcript)
    (seed / 'Reports' / (name + '.md')).write_text('''# Отчёт по встрече

## Суть

Команда решила сдвинуть выпуск Лори на неделю: запись в фоне обрывается при звонке, и это нужно закрыть до релиза.

## Ход обсуждения

- [00:42] Обрывы записи на телефоне Анны при входящем звонке
- [04:15] Сроки: среда против пятницы, чем рискуем
- [09:30] Нужен ли отчёт в PDF или хватит Markdown

## Решения

- Релиз — в следующую среду
- Фоновую запись проверяем на двух телефонах

## Задачи

- Дописать тесты записи в фоне — Анна, до пятницы
- Обновить инструкцию по выпуску — Борис, к четвергу

## Неуверенные места

На 11:05 речь неразборчива — возможно, обсуждали третий телефон для проверки.
''')
    if not (workspace / record).exists():
        safe.copy_new(seed, container, 'Documents/Lori/Workspace')
        print('Added synthetic Granola audio, transcript and report.')
    else:
        print('Granola recording already present; audio, transcript and report preserved.')

metadata = container / 'Library/Application Support/Lori'
metadata.mkdir(parents=True, exist_ok=True)

def append(filename, value):
    target = metadata / filename
    if target.is_symlink():
        raise ValueError('Refusing symlink metadata')
    old = json.loads(target.read_text()) if target.exists() else {}
    if record in old:
        return
    old[record] = value
    temporary = target.with_suffix('.granola-new.json')
    with temporary.open('x') as stream:
        json.dump(old, stream, ensure_ascii=False)
    os.replace(temporary, target)

append('summaries.json', dict(title='Перенос релиза Лори', detail='', origin='manual', summarized=True, stale=False, replaceManual=False))
append('speakers.json', dict(S1='Анна', S2='Борис'))
append('recording-summaries.json', dict(
    summary=dict(
        brief='Релиз переносим на следующую среду: проверка записи в фоне ещё не готова. До пятницы Анна дописывает тесты, Борис обновляет инструкцию.',
        highlights=[], decisions=['Релиз — в следующую среду', 'Фоновую запись проверяем на двух телефонах'],
        tasks=[dict(text='Дописать тесты записи в фоне', owner='Анна', due='до пятницы'),
               dict(text='Обновить инструкцию по выпуску', owner='Борис', due='к четвергу'),
               dict(text='Проверить отчёт в PDF на длинной записи', owner=None, due=None)],
        openQuestions=['Нужен ли отчёт в PDF или хватит Markdown']),
    fingerprint=hashlib.sha256('\n'.join(line[3] for line in lines).encode()).hexdigest(),
    createdAt=time.time() - 978307200 - 60, source='gateway', stale=False,
    completedTasks=['Проверить отчёт в PDF на длинной записи']))
topics_file = metadata / 'topics.json'
if topics_file.is_symlink():
    raise ValueError('Refusing symlink topics')
topics = json.loads(topics_file.read_text()) if topics_file.exists() else dict(topics=[], assigned={})
if record not in topics['assigned']:
    if 'Работа' not in topics['topics']:
        topics['topics'].append('Работа')
    topics['assigned'][record] = 'Работа'
    temporary = topics_file.with_suffix('.granola-new.json')
    with temporary.open('x') as stream:
        json.dump(topics, stream, ensure_ascii=False)
    os.replace(temporary, topics_file)
print('Only missing fixture keys appended; existing metadata preserved.')
