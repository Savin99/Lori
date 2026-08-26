import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { createServer as createHttpServer } from 'node:http'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

const root = new URL('..', import.meta.url).pathname
const token = 'test-token-for-lori-only'
const summaryPayload = { brief: 'Итог готов.', keyPoints: [], decisions: [], tasks: [], facts: [], openQuestions: [], uncertainties: [] }

async function freePort() {
  const server = createServer()
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address()
  await new Promise((resolve) => server.close(resolve))
  return port
}
async function waitFor(callback, message) {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try { const value = await callback(); if (value) return value } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  throw new Error(message ?? 'timed out')
}
// Подставной транскрайбер: спит заданное время и пишет markdown в --output.
async function fakeTranscriber(directory, seconds) {
  await mkdir(join(directory, '.venv/bin'), { recursive: true })
  await mkdir(join(directory, 'mac_transcriber/scripts'), { recursive: true })
  await writeFile(join(directory, 'mac_transcriber/scripts/transcribe_md.py'), '')
  const shim = join(directory, '.venv/bin/python')
  await writeFile(shim, `#!/usr/bin/env bash\nout=""; prev=""\nfor arg in "$@"; do if [ "$prev" = "--output" ]; then out="$arg"; fi; prev="$arg"; done\nsleep ${seconds}\nif [ -n "$out" ]; then mkdir -p "$(dirname "$out")"; printf '# Fake\\n\\n## Расшифровка\\n\\n[00:00:00 - 00:00:03] **Спикер:** Подставная расшифровка.\\n' > "$out"; fi\n`)
  await chmod(shim, 0o755)
  return shim
}

test('queue, cancellation, summaries, ranges and trash survive real use', async (t) => {
  const temp = await mkdtemp(join(tmpdir(), 'lori-stability-'))
  const vault = join(temp, 'vault')
  const library = join(temp, 'library')
  const tokenFile = join(temp, 'token')
  const brokenDate = 'Inbox/Транскрипты/2026-08/2026-08-18 1100 Битый.md'
  const port = await freePort()
  let summaryCalls = 0
  const openai = createHttpServer(async (request, response) => {
    for await (const chunk of request) void chunk
    summaryCalls += 1
    await new Promise((resolve) => setTimeout(resolve, 1200))
    response.setHeader('content-type', 'application/json')
    response.end(JSON.stringify({ output_text: JSON.stringify(summaryPayload) }))
  })
  await new Promise((resolve) => openai.listen(0, '127.0.0.1', resolve))
  let child
  t.after(async () => {
    child?.kill('SIGTERM')
    await new Promise((resolve) => child?.once('exit', resolve) ?? resolve())
    await new Promise((resolve) => openai.close(resolve))
    await rm(temp, { recursive: true, force: true })
  })

  await mkdir(join(vault, 'Inbox/Транскрипты/2026-08'), { recursive: true })
  await mkdir(library, { recursive: true })
  await writeFile(tokenFile, token)
  await writeFile(join(vault, brokenDate), '---\ntype: transcript\ncreated: неизвестно\n---\n\n# Битая дата\n\n## Расшифровка\n\nТекст расшифровки без нормальной даты.\n')
  await fakeTranscriber(join(temp, 'gigaam'), 2)

  child = spawn(process.execPath, ['ui/server.mjs'], {
    cwd: root,
    env: {
      ...process.env, OPENAI_API_KEY: 'test-lori-key', LORI_OPENAI_API_BASE_URL: `http://127.0.0.1:${openai.address().port}`,
      LORI_PORT: String(port), LORI_VAULT: vault, LORI_LIBRARY: library, LORI_TOKEN_FILE: tokenFile,
      LORI_PASSWORD_FILE: join(temp, 'password.json'), LORI_ENV_FILE: '/dev/null', LORI_GIGAAM_ROOT: join(temp, 'gigaam'),
    },
    stdio: ['ignore', 'ignore', 'inherit'],
  })
  const request = (path, options = {}) => fetch(`http://127.0.0.1:${port}${path}`, { ...options, headers: { authorization: `Bearer ${token}`, ...(options.headers ?? {}) } })
  const json = async (path, options) => (await request(path, options)).json()
  const media = () => new Blob([new Uint8Array(4096)])
  await waitFor(async () => (await request('/api/meta')).ok, 'server did not start')

  await t.test('нечитаемая дата из frontmatter не доходит до интерфейса', async () => {
    const record = (await json('/api/library')).records.find((item) => item.title === 'Битая дата')
    assert.match(record.created, /^\d{4}-\d{2}-\d{2}$/)
  })

  await t.test('второй файл в очереди не зависает', async () => {
    const first = await json('/api/jobs', { method: 'POST', headers: { 'x-lori-name': encodeURIComponent('Первая встреча.wav') }, body: media() })
    await new Promise((resolve) => setTimeout(resolve, 500))
    const second = await json('/api/jobs', { method: 'POST', headers: { 'x-lori-name': encodeURIComponent('Вторая встреча.wav') }, body: media() })
    assert.equal(first.job.filename, 'Первая встреча.wav', 'расширение не дублируется')
    await waitFor(async () => {
      const states = await Promise.all([first.jobId, second.jobId].map(async (id) => (await json(`/api/jobs/${id}`)).job.state))
      return states.every((state) => state === 'transcript_ready')
    }, 'второе задание осталось в очереди')
  })

  await t.test('отмена расшифровки остаётся отменой, а не ошибкой', async () => {
    const upload = await json('/api/jobs', { method: 'POST', headers: { 'x-lori-name': encodeURIComponent('Отменяемая.wav') }, body: media() })
    await waitFor(async () => (await json(`/api/jobs/${upload.jobId}`)).job.state === 'transcribing', 'расшифровка не началась')
    assert.equal((await request(`/api/jobs/${upload.jobId}/cancel`, { method: 'POST' })).status, 200)
    const job = await waitFor(async () => { const value = (await json(`/api/jobs/${upload.jobId}`)).job; return ['cancelled', 'failed'].includes(value.state) ? value : null })
    assert.equal(job.state, 'cancelled')
    const record = (await json(`/api/record?id=${upload.job.recordId}`)).record
    assert.equal(record.status, 'cancelled')
    assert.equal(record.error, null)
  })

  await t.test('одновременные запросы итога не оплачиваются дважды', async () => {
    const target = (await json('/api/library')).records.find((item) => item.title === 'Битая дата')
    const before = summaryCalls
    const responses = await Promise.all([1, 2, 3].map(() => json(`/api/records/${target.id}/summaries`, { method: 'POST' })))
    assert.equal(new Set(responses.map((item) => item.job.id)).size, 1)
    await waitFor(async () => (await json(`/api/record?id=${target.id}`)).record.status === 'ready', 'итог не создан')
    assert.equal(summaryCalls - before, 1)
  })

  await t.test('правка библиотеки во время задания не теряется', async () => {
    const target = (await json('/api/library')).records.find((item) => item.title === 'Битая дата')
    await json(`/api/records/${target.id}/summaries`, { method: 'POST' })
    const folder = (await json('/api/folders', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name: 'Живучая папка' }) })).folder
    await waitFor(async () => (await json(`/api/record?id=${target.id}`)).record.status === 'ready', 'итог не создан')
    assert.ok((await json('/api/library')).folders.some((item) => item.id === folder.id), 'папка исчезла после сохранения задания')
    const stored = JSON.parse(await readFile(join(library, 'library.json'), 'utf8'))
    assert.ok(stored.folders.some((item) => item.id === folder.id), 'папки нет на диске')
  })

  await t.test('битый Range не роняет мост', async () => {
    const record = (await json('/api/library')).records.find((item) => item.media?.available)
    const tail = await request(`/api/records/${record.id}/media`, { headers: { range: 'bytes=-500' } })
    assert.equal(tail.status, 206)
    assert.equal(tail.headers.get('content-range'), 'bytes 3596-4095/4096')
    for (const value of ['bytes=100-50', 'bytes=abc-xyz', 'bytes=99999-']) {
      assert.equal((await request(`/api/records/${record.id}/media`, { headers: { range: value } })).status, 416, value)
    }
    assert.ok((await request('/api/meta')).ok, 'сервер умер на битом диапазоне')
  })

  await t.test('удаление уносит файл из хранилища, восстановление возвращает', async () => {
    const record = (await json('/api/library')).records.find((item) => item.title === 'Битая дата')
    const file = join(vault, brokenDate)
    assert.equal((await request(`/api/records/${record.id}`, { method: 'DELETE' })).status, 202)
    await assert.rejects(stat(file), 'исходник остался в хранилище — после чистки корзины запись вернулась бы')
    assert.equal((await json('/api/library')).records.some((item) => item.id === record.id), false)
    assert.equal((await request(`/api/records/${record.id}/restore`, { method: 'POST' })).status, 200)
    await stat(file)
    const restored = (await json('/api/library')).records.find((item) => item.id === record.id)
    assert.ok(restored.wordCount > 0)
  })
})
