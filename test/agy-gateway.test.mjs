import { test } from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import { request as httpRequest } from 'node:http'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, rename, rm, symlink, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { createGateway, gatewayConfig } from '../ui/agy-gateway.mjs'

const executeFile = promisify(execFile)
const TOKEN = 'lori-test-token-012345678901234567890123456789'
const FOREIGN = '11111111-1111-4111-8111-111111111111'
const LATE_FOREIGN = '22222222-2222-4222-8222-222222222222'
const fakeSource = String.raw`
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { spawn, execFileSync } from 'node:child_process'
const home = process.env.HOME
const args = process.argv.slice(2)
const get = (flag) => args[args.indexOf(flag) + 1]
const event = (value) => appendFileSync(join(home, 'events.ndjson'), JSON.stringify(value) + '\n')
if (args.includes('--version')) { event({ event: 'version' }); console.log('agy fake 1.5.2'); process.exit(0) }
let input = ''
for await (const chunk of process.stdin) input += chunk
const stream = args.includes('--input-format')
const schema = args.includes('--json-schema') ? JSON.parse(readFileSync(get('--json-schema'), 'utf8')) : undefined
const kind = !schema ? 'usage' : schema.properties.segments ? 'transcribe' : schema.properties.markdown ? 'report' : 'annotate'
const prompt = stream ? JSON.parse(input).message.content : get('-p')
const audioName = kind === 'transcribe' ? readdirSync(process.cwd()).find((name) => name.startsWith('part.')) : undefined
const content = kind === 'transcribe' ? readFileSync(join(process.cwd(), audioName), 'utf8') : prompt
// Наличие lock само по себе не доказывает параллельность: SIGKILL не запускает exit.
const lock = join(home, 'active')
if (existsSync(lock)) {
  try { process.kill(Number(readFileSync(lock, 'utf8')), 0); event({ event: 'parallel' }); process.exit(9) } catch {}
  unlinkSync(lock)
}
writeFileSync(lock, String(process.pid))
process.on('exit', () => { try { unlinkSync(lock) } catch {} })
const root = join(home, '.gemini/antigravity-cli')
for (const folder of ['conversations', 'brain', 'presence', 'cache']) mkdirSync(join(root, folder), { recursive: true })
const id = randomUUID()
let cache = existsSync(join(root, 'cache/last_conversations.json')) ? JSON.parse(readFileSync(join(root, 'cache/last_conversations.json'), 'utf8')) : {}
function traces (conversationId, workspace) {
  writeFileSync(join(root, 'conversations', conversationId + '.db'), 'private conversation')
  mkdirSync(join(root, 'brain', conversationId, '.system_generated/logs/media'), { recursive: true })
  writeFileSync(join(root, 'brain', conversationId, '.system_generated/logs/media', 'audio'), 'private audio')
  writeFileSync(join(root, 'presence', conversationId + '.lock'), 'presence')
  cache[workspace] = conversationId
  execFileSync('/usr/bin/sqlite3', [join(root, 'conversation_summaries.db'),
    "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT); CREATE VIRTUAL TABLE IF NOT EXISTS conversations_fts USING fts5(conversation_id UNINDEXED, body); INSERT INTO conversation_summaries VALUES ('" + conversationId + "', 'private'); INSERT INTO conversations_fts VALUES ('" + conversationId + "', 'private'); PRAGMA wal_checkpoint(TRUNCATE);"])
  // Настоящий agy закрывает базу без -wal и -shm, а системный sqlite3 их оставляет.
  for (const suffix of ['-wal', '-shm']) rmSync(join(root, 'conversation_summaries.db' + suffix), { force: true })
}
if (kind !== 'usage' || !process.env.FAKE_USAGE_NO_CONVERSATION) traces(id, process.cwd())
if (content?.includes('[foreign]')) traces('22222222-2222-4222-8222-222222222222', '/another-workspace')
writeFileSync(join(root, 'cache/last_conversations.json'), JSON.stringify(cache))
if (process.env.FAKE_SERVICE_TRACES) {
  writeFileSync(join(root, 'jetbox_summaries_proto.pb'), 'summary metadata: ' + id)
  for (const suffix of ['-wal', '-shm']) writeFileSync(join(root, 'conversation_summaries.db' + suffix), 'metadata')
  for (const folder of ['implicit', 'log']) mkdirSync(join(root, folder), { recursive: true })
  writeFileSync(join(root, 'implicit', id + '.pb'), 'UUID and workspace')
  writeFileSync(join(root, 'log', 'cli-' + id + '.log'), 'UUID and workspace')
}
event({ event: 'start', id, kind, pid: process.pid, directory: process.cwd(), mode: statSync(process.cwd()).mode & 511, args, input, audioName, audioBytes: kind === 'transcribe' ? Buffer.byteLength(content) : undefined, autoUpdate: process.env.AGY_CLI_DISABLE_AUTO_UPDATE })
if (stream) console.log(JSON.stringify({ event: 'init', conversation_id: id, init: {} }))
if (content?.includes('[hang]')) {
  // Потомок игнорирует TERM и наследует pipe: проверяем именно убийство группы.
  const descendant = spawn(process.execPath, ['-e', "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000)"], { stdio: ['ignore', 'inherit', 'inherit'] })
  event({ event: 'descendant', pid: descendant.pid })
  process.on('SIGTERM', () => {})
  setInterval(() => {}, 1000)
} else {
  await new Promise((resolve) => setTimeout(resolve, content?.includes('[link]') ? 700 : content?.includes('[slow]') ? 150 : 15))
  if (kind === 'usage') {
    const answer = { groups: [{ name: 'Gemini Models', buckets: [{ id: 'flash', window: '5h', remaining_fraction: 0, reset_time: new Date(Date.now() + 60000).toISOString() }] }] }
    console.log(JSON.stringify(process.env.FAKE_USAGE_FORMAT === 'direct' ? answer : process.env.FAKE_USAGE_FORMAT === 'structured'
      ? { status: 'SUCCESS', structured_output: answer }
      : { status: 'SUCCESS', command: { name: 'usage', data: answer }, response: 'human readable TSV' }))
  } else if (content?.includes('[auth-macmini]') || content?.includes('[auth-failed]')) {
    if (content.includes('[auth-macmini]')) console.error("Error: authentication required. Run 'agy' to log in, then retry.")
    console.error('error: authentication failed or timed out')
    const result = { status: 'ERROR', error: 'authentication failed or timed out', conversation_id: id }
    console.log(JSON.stringify(stream ? { event: 'result', result } : result))
    process.exitCode = 1
  } else if (content?.includes('[quota]') || content?.includes('[auth]') || content?.includes('[agent]')) {
    const code = content.includes('[quota]') ? 'RESOURCE_EXHAUSTED' : content.includes('[auth]') ? 'UNAUTHENTICATED' : 'INTERNAL'
    console.error('AGY_ERROR: ' + JSON.stringify({ code, message: process.env.FAKE_ERROR_MESSAGE || 'секретный текст расшифровки' }))
    process.exitCode = 3
  } else if (content?.includes('[malformed]')) {
    console.log('not json: секретный текст расшифровки')
  } else {
    const structured = kind === 'annotate'
      ? { title: '  План выпуска новой версии  ', description: '  Короткое описание.  ', summary: { brief: '  Обсудили выпуск. Остались вопросы. ', highlights: [' факт ', '', null, 17], decisions: [], tasks: [' проверить '], openQuestions: [] } }
      : kind === 'report' ? { markdown: '  # Суть\n\nПроверка отчёта.  ' }
      : { segments: [{ speaker: ' S1 ', start: '00:03', text: ' Привет, оговорка. ' }, { speaker: 'wrong', start: '00:99', text: ' ещё ' }, { text: ' ' }, { text: 77 }] }
    if (kind === 'annotate' && process.env.FAKE_ANNOTATION_JSON) Object.assign(structured, JSON.parse(process.env.FAKE_ANNOTATION_JSON))
    const result = { status: 'SUCCESS', conversation_id: id, structured_output: content?.includes('[bad-result]') ? { title: 7 } : structured,
      usage: { input_tokens: 123, output_tokens: 45 }, duration_seconds: 0.02,
      denied_actions: ['command(секретный текст расшифровки)', { action: 'read_url', target: 'секретный текст расшифровки' }] }
    if (content?.includes('[truncated]')) result.finished_reason = 'MAX_TOKENS'
    if (stream) {
      // Разрывы stdout не обязаны совпадать с границами NDJSON.
      process.stdout.write('{"event":"step_up')
      process.stdout.write('date","step_update":{}}\n')
      console.log(JSON.stringify({ event: 'result', result }))
    } else console.log(JSON.stringify(result))
  }
  event({ event: 'end', kind, id })
}
`
// Абсолютный путь в shebang не зависит от PATH дочернего HOME и launchd.
// Файл, HTTP-порт и HOME каждого теста свои; наружу тесты не обращаются.
async function fixture (t, settings = {}, prepare) {
  const directory = await mkdtemp(join(tmpdir(), 'lori-gateway-test-'))
  const home = join(directory, 'home')
  await mkdir(home)
  const bin = join(directory, 'agy')
  await writeFile(bin, `#!${process.execPath}\n` + fakeSource)
  await chmod(bin, 0o755)
  const tokenFile = join(directory, 'token')
  await writeFile(tokenFile, TOKEN, { mode: 0o600 })
  const root = join(home, '.gemini/antigravity-cli')
  await mkdir(root, { recursive: true })
  // Как у настоящего agy — режим WAL. После выхода процесса -wal и -shm удаляются,
  // и открыть такую базу только на чтение нельзя: на Mac mini чистка падала именно так.
  await executeFile('/usr/bin/sqlite3', [join(root, 'conversation_summaries.db'), 'PRAGMA journal_mode=WAL; CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT); CREATE VIRTUAL TABLE conversations_fts USING fts5(conversation_id UNINDEXED, body);'])
  const config = gatewayConfig({ ...process.env,
    LORI_AGY_BIN: bin, LORI_AGY_HOME: home, LORI_GATEWAY_TOKEN_FILE: tokenFile,
    LORI_GATEWAY_PORT: '0', LORI_AGY_CLEANUP: '1',
    LORI_GATEWAY_ANNOTATE_TIMEOUT_SECONDS: '5', LORI_GATEWAY_REPORT_TIMEOUT_SECONDS: '5', LORI_GATEWAY_TRANSCRIBE_TIMEOUT_SECONDS: '5',
    ...(typeof settings === 'function' ? await settings({ directory, home, root }) : settings)
  })
  const logs = []
  let gateway
  t.after(async () => { await gateway?.close(); await rm(directory, { recursive: true, force: true }) })
  await prepare?.({ directory, home, root, config })
  gateway = await createGateway(config, { logger: (entry) => logs.push(entry) })
  gateway.server.listen(0, '127.0.0.1')
  await once(gateway.server, 'listening')
  const base = `http://127.0.0.1:${gateway.server.address().port}`
  const request = async (path, options = {}) => {
    const response = await fetch(base + path, { ...options, headers: { authorization: `Bearer ${TOKEN}`, ...options.headers } })
    return { status: response.status, headers: response.headers, body: await response.json() }
  }
  const submit = async (transcript = 'Короткий русский текст.', extra = {}) => {
    const result = await request('/v1/jobs', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'annotate', transcript, ...extra }) })
    assert.equal(result.status, 202, JSON.stringify(result.body))
    return result.body
  }
  const events = async () => (await readFile(join(home, 'events.ndjson'), 'utf8')).trim().split('\n').map((line) => JSON.parse(line))
  const waitFor = async (read, check, timeout = 6000) => {
    const deadline = Date.now() + timeout
    let last
    do {
      last = await read()
      if (check(last)) return last
      await delay(15)
    } while (Date.now() < deadline)
    assert.fail(`Не дождались состояния: ${JSON.stringify(last)}`)
  }
  const job = async (id) => (await request(`/v1/jobs/${id}`)).body
  const done = async (id) => waitFor(() => job(id), (value) => ['done', 'failed', 'cancelled'].includes(value.state))
  return { directory, home, root, config, gateway, logs, base, request, submit, events, waitFor, job, done }
}

function alive (pid) {
  try { process.kill(pid, 0); return true } catch (cause) { if (cause.code === 'ESRCH') return false; throw cause }
}

// Можно проверить заведомо огромный Content-Length, не выделяя 95 МБ памяти.
function declaredBody (base, path, length, type = 'audio/mp4') {
  return new Promise((resolveResponse, reject) => {
    const req = httpRequest(base + path, { method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'content-type': type, 'content-length': String(length) } }, (response) => {
      const chunks = []
      response.on('data', (chunk) => chunks.push(chunk))
      response.on('end', () => { resolveResponse({ status: response.statusCode, body: JSON.parse(Buffer.concat(chunks)) }); req.destroy() })
    })
    req.on('error', reject)
    req.flushHeaders()
  })
}

test('настройки и отказ старта без длинного токена', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'lori-gateway-token-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const config = gatewayConfig({ HOME: directory })
  assert.equal(config.host, '127.0.0.1')
  assert.equal(config.port, 18890)
  assert.equal(config.resultTtlMs, 7200000)
  assert.equal(config.maxAudioBytes, 95 * 1024 * 1024)
  assert.equal(config.uploadTimeout, 600)
  await assert.rejects(createGateway(config), /файл токена/)
  config.tokenFile = join(directory, 'token')
  await writeFile(config.tokenFile, 'short')
  await assert.rejects(createGateway(config), /короче 32/)
  assert.throws(() => gatewayConfig({ LORI_GATEWAY_ANNOTATE_TIMEOUT_SECONDS: 'oops' }), /настройка/)
})

test('все пути требуют токен, версия кешируется, после 20 ошибок блокируются и верные токены', async (t) => {
  const f = await fixture(t)
  for (const [path, method] of [['/v1/health', 'GET'], ['/v1/usage', 'GET'], ['/v1/jobs', 'POST'], ['/v1/jobs/abc', 'GET'], ['/v1/jobs/abc', 'DELETE']]) {
    assert.equal((await f.request(path, { method, headers: { authorization: '' } })).status, 401)
  }
  const health = await f.request('/v1/health')
  assert.equal(health.body.ok, true)
  assert.deepEqual(health.body.agy, { path: f.config.agyBin, version: 'agy fake 1.5.2' })
  await f.request('/v1/health')
  assert.equal((await f.events()).filter((item) => item.event === 'version').length, 1)
  for (let i = 5; i < 20; i++) {
    const response = await f.request('/v1/health', { headers: { authorization: 'Bearer wrong' } })
    assert.equal(response.status, i === 19 ? 429 : 401)
  }
  const blocked = await f.request('/v1/health')
  assert.equal(blocked.status, 429)
  assert.equal(blocked.headers.get('retry-after'), '60')
})

test('annotate/report идут через stdin со схемой, нормализуются, содержимое не попадает в журнал', async (t) => {
  const f = await fixture(t, { LORI_GATEWAY_REPORT_MODEL: 'report-model' })
  const transcript = 'секретный текст расшифровки'
  const first = await f.done((await f.submit(transcript)).id)
  assert.equal(first.state, 'done')
  assert.deepEqual(first.result, {
    title: 'План выпуска новой версии', description: 'Короткое описание.',
    summary: { brief: 'Обсудили выпуск. Остались вопросы.', highlights: ['факт'], decisions: [], tasks: ['проверить'], openQuestions: [] }
  })
  assert.deepEqual(first.usage, { inputTokens: 123, outputTokens: 45 })
  assert.ok(first.durationSeconds >= 0)
  const report = await f.done((await f.submit(transcript, { kind: 'report' })).id)
  assert.equal(report.result.markdown, '# Суть\n\nПроверка отчёта.')
  const starts = (await f.events()).filter((item) => item.event === 'start')
  for (const start of starts) {
    assert.ok(start.args.includes('--sandbox'))
    assert.ok(start.args.includes('--disable-slash-commands'))
    assert.ok(start.args.includes('--json-schema'))
    assert.ok(!start.args.includes('--dangerously-skip-permissions'))
    assert.ok(!start.args.some((arg) => arg.includes(transcript)))
    assert.equal(start.input.trim().split('\n').length, 1)
    assert.equal(JSON.parse(start.input).event, 'user')
    const policy = JSON.parse(start.args[start.args.indexOf('--settings') + 1])
    assert.deepEqual(policy.permissions.deny, ['command(*)', 'write_file(*)', 'read_url(*)', 'execute_url(*)', 'mcp(*)'])
    assert.equal(policy.useG1Credits, false)
    assert.equal(policy.allowNonWorkspaceAccess, false)
    assert.equal(start.mode, 0o700)
    assert.equal(start.autoUpdate, '1')
    assert.equal(existsSync(start.directory), false)
  }
  assert.equal(starts[1].args[starts[1].args.indexOf('--model') + 1], 'report-model')
  assert.ok(!JSON.stringify(f.logs).includes(transcript))
  assert.ok(!JSON.stringify(f.logs).includes('part.m4a'))
  assert.ok(!JSON.stringify(f.logs).includes(f.home))
  assert.deepEqual(f.logs.find((entry) => entry.type === 'job').deniedActions, ['command', 'read_url'])
})

test('аудио передаётся файлом, словарь декодируется, говорящие отключаются по запросу', async (t) => {
  const f = await fixture(t)
  const submit = (speakers, type = 'audio/mp4') => f.request('/v1/jobs?kind=transcribe', {
    method: 'POST', headers: { 'content-type': type, 'x-lori-speakers': speakers, 'x-lori-language': 'ru', 'x-lori-vocabulary': encodeURIComponent('Лори,Джемини') }, body: Buffer.from('fake audio')
  })
  const response = await submit('1', 'audio/x-m4a; codecs=mp4a')
  assert.equal(response.status, 202)
  const first = await f.done(response.body.id)
  assert.equal(first.state, 'done')
  assert.deepEqual(first.result.segments, [{ speaker: 'S1', start: '00:03', text: 'Привет, оговорка.' }, { speaker: null, start: null, text: 'ещё' }])
  const second = await f.done((await submit('0')).body.id)
  assert.ok(second.result.segments.every((item) => item.speaker === null))
  const start = (await f.events()).find((item) => item.event === 'start')
  assert.equal(start.input, '')
  assert.ok(start.args.includes('-p'))
  assert.match(start.args[start.args.indexOf('-p') + 1], /part\.m4a.*read_file/)
  assert.match(start.args[start.args.indexOf('-p') + 1], /Лори,Джемини/)
})

test('идемпотентность queued/running/done, разные kind и повторы failed/cancelled', async (t) => {
  const f = await fixture(t)
  const first = await f.submit('[slow]', { key: 'same' })
  const second = await f.submit('другой текст', { key: 'queued' })
  assert.equal((await f.submit('повтор', { key: 'queued' })).id, second.id)
  assert.equal((await f.submit('повтор', { key: 'same' })).id, first.id)
  await f.done(first.id)
  await f.done(second.id)
  assert.equal((await f.submit('повтор', { key: 'same' })).id, first.id)
  const report = await f.submit('текст', { kind: 'report', key: 'same' })
  assert.notEqual(report.id, first.id)
  await f.done(report.id)
  const failed = await f.submit('[agent]', { key: 'failed' })
  await f.done(failed.id)
  const retry = await f.submit('повтор', { key: 'failed' })
  assert.notEqual(retry.id, failed.id)
  await f.done(retry.id)
  const running = await f.submit('[hang]')
  await f.waitFor(f.events, (events) => events.some((item) => item.event === 'descendant'))
  const queued = await f.submit('текст', { key: 'cancel' })
  assert.equal((await f.request(`/v1/jobs/${queued.id}`, { method: 'DELETE' })).body.state, 'cancelled')
  const replacement = await f.submit('новый', { key: 'cancel' })
  assert.notEqual(replacement.id, queued.id)
  await f.request(`/v1/jobs/${running.id}`, { method: 'DELETE' })
  await f.done(replacement.id)
  assert.ok(!(await f.events()).some((entry) => entry.event === 'parallel'))
})

test('FIFO общая с /usage, максимум 20 ожидающих и дубликат принимается при полной очереди', async (t) => {
  const f = await fixture(t)
  const first = await f.submit('[hang]', { key: 'active' })
  await f.waitFor(f.events, (events) => events.some((entry) => entry.event === 'descendant'))
  const second = await f.submit('второй', { kind: 'report' })
  let usagePromise = f.request('/v1/usage')
  await f.waitFor(() => f.job(second.id), (job) => job.position === 1)
  const queued = []
  // Второй и /usage уже занимают два места.
  for (let i = 0; i < 18; i++) queued.push(await f.submit(`текст ${i}`))
  assert.equal((await f.request('/v1/jobs', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'annotate', transcript: 'переполнение' }) })).status, 503)
  assert.equal((await f.submit('повтор', { key: 'active' })).id, first.id)
  for (const item of queued) await f.request(`/v1/jobs/${item.id}`, { method: 'DELETE' })
  await f.request(`/v1/jobs/${first.id}`, { method: 'DELETE' })
  assert.equal((await f.done(second.id)).state, 'done')
  const usage = await usagePromise
  assert.equal(usage.status, 200)
  assert.equal(usage.body.groups[0].buckets[0].remainingFraction, 0)
  assert.ok(usage.body.groups[0].buckets[0].resetTime)
  const events = await f.events()
  assert.ok(!events.some((entry) => entry.event === 'parallel'))
  assert.deepEqual(events.filter((entry) => entry.event === 'start').map((entry) => entry.kind), ['annotate', 'report', 'usage'])
  const usageArgs = events.find((entry) => entry.kind === 'usage' && entry.event === 'start').args
  assert.ok(!usageArgs.includes('--disable-slash-commands'))
})

test('отмена JSON-расшифровки убивает группу и чистит следы даже без envelope', async (t) => {
  const f = await fixture(t)
  const response = await f.request('/v1/jobs?kind=transcribe', { method: 'POST', headers: { 'content-type': 'audio/mp4' }, body: '[hang]' })
  const events = await f.waitFor(f.events, (items) => items.some((entry) => entry.event === 'descendant'))
  const start = events.find((entry) => entry.event === 'start')
  const descendant = events.find((entry) => entry.event === 'descendant')
  const cancelled = await f.request(`/v1/jobs/${response.body.id}`, { method: 'DELETE' })
  assert.equal(cancelled.body.state, 'cancelled')
  await f.waitFor(async () => [alive(start.pid), alive(descendant.pid)], (items) => items.every((value) => !value))
  assert.equal(existsSync(start.directory), false)
  assert.equal(existsSync(join(f.root, 'conversations', start.id + '.db')), false)
  assert.equal(existsSync(join(f.root, 'brain', start.id)), false)
  assert.deepEqual(JSON.parse(await readFile(join(f.root, 'cache/last_conversations.json'), 'utf8')), {})
})

test('quota/auth/timeout/agent и оборванный или некорректный ответ не раскрывают исходник', async (t) => {
  const f = await fixture(t)
  for (const [marker, code] of [['[quota]', 'quota'], ['[auth]', 'auth'], ['[hang]', 'timeout'], ['[agent]', 'agent'], ['[truncated]', 'agent'], ['[bad-result]', 'agent'], ['[malformed]', 'agent']]) {
    f.config.timeouts.annotate = marker === '[hang]' ? 0.7 : 5
    const result = await f.done((await f.submit(marker + ' секретный текст расшифровки')).id)
    assert.equal(result.state, 'failed', marker)
    assert.equal(result.error.code, code, marker)
    assert.ok(!JSON.stringify(result.error).includes('секретный текст расшифровки'))
    if (code === 'quota') assert.ok(result.error.retryAfter > 0 && result.error.retryAfter <= 60)
    if (code === 'auth') assert.ok(result.error.message.includes(`HOME=${f.home}`))
    if (marker === '[truncated]') assert.match(result.error.message, /оборван/)
  }
  assert.ok(!JSON.stringify(f.logs).includes('секретный текст расшифровки'))
  assert.ok(!(await f.events()).some((entry) => entry.event === 'parallel'))
})

test('границы JSON/расшифровки/аудио и неподдерживаемые типы отклоняются до запуска agy', async (t) => {
  const f = await fixture(t)
  assert.equal((await declaredBody(f.base, '/v1/jobs?kind=transcribe', 95 * 1024 * 1024 + 1)).status, 413)
  assert.equal((await declaredBody(f.base, '/v1/jobs', 4 * 1024 * 1024 + 1, 'application/json')).status, 413)
  for (const type of ['text/plain', 'video/mp4', 'application/octet-stream']) {
    assert.equal((await f.request('/v1/jobs?kind=transcribe', { method: 'POST', headers: { 'content-type': type }, body: 'abc' })).status, 415)
  }
  const tooLong = await f.request('/v1/jobs', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'annotate', transcript: 'x'.repeat(1000001) }) })
  assert.equal(tooLong.status, 413)
  const jsonOptions = { method: 'POST', headers: { 'content-type': 'application/json' } }
  for (const body of ['{bad', 'null', '[]', '{"kind":"other"}', '{"kind":"annotate","transcript":7}', '{"kind":"annotate","transcript":" "}']) {
    assert.equal((await f.request('/v1/jobs', { ...jsonOptions, body })).status, 400)
  }
  assert.equal((await f.request('/v1/jobs?kind=transcribe', { method: 'POST', headers: { 'content-type': 'audio/mp4' }, body: '' })).status, 400)
  assert.equal((await f.request('/v1/jobs?kind=transcribe', { method: 'POST', headers: { 'content-type': 'audio/mp4', 'x-lori-vocabulary': '%' }, body: 'abc' })).status, 400)
  assert.equal((await f.events()).filter((item) => item.event === 'start').length, 0)
  // Малые внутренние пределы позволяют проверить chunked-body без сотни мегабайт.
  f.config.maxAudioBytes = 4
  f.config.maxJsonBytes = 4
  const stream = () => new ReadableStream({ start (controller) { controller.enqueue(Buffer.from('123')); controller.enqueue(Buffer.from('456')); controller.close() } })
  for (const [path, type] of [['/v1/jobs?kind=transcribe', 'audio/mp4'], ['/v1/jobs', 'application/json']]) {
    assert.equal((await f.request(path, { method: 'POST', duplex: 'half', headers: { 'content-type': type }, body: stream() })).status, 413)
  }
})

test('чистка удаляет ровно свою историю, SQLite/FTS/кеш; чужая и новая чужая остаются', async (t) => {
  const f = await fixture(t, ({ home }) => ({ HOME: home, LORI_AGY_HOME: home }))
  for (const directory of ['conversations', 'brain', 'presence', 'cache']) await mkdir(join(f.root, directory), { recursive: true })
  await writeFile(join(f.root, 'conversations', FOREIGN + '.db'), 'foreign')
  await mkdir(join(f.root, 'brain', FOREIGN))
  await writeFile(join(f.root, 'brain', FOREIGN, 'private'), 'foreign')
  await writeFile(join(f.root, 'presence', FOREIGN + '.lock'), 'foreign')
  await writeFile(join(f.root, 'cache/last_conversations.json'), JSON.stringify({ '/foreign': FOREIGN }))
  await executeFile('/usr/bin/sqlite3', [join(f.root, 'conversation_summaries.db'), `INSERT INTO conversation_summaries VALUES ('${FOREIGN}', 'foreign'); INSERT INTO conversations_fts VALUES ('${FOREIGN}', 'foreign');`])
  assert.equal((await f.done((await f.submit('[foreign]')).id)).state, 'done')
  const start = (await f.events()).find((entry) => entry.event === 'start')
  for (const id of [FOREIGN, LATE_FOREIGN]) {
    assert.ok(existsSync(join(f.root, 'conversations', id + '.db')))
    assert.ok(existsSync(join(f.root, 'brain', id)))
    assert.ok(existsSync(join(f.root, 'presence', id + '.lock')))
  }
  for (const path of [`conversations/${start.id}.db`, `brain/${start.id}`, `presence/${start.id}.lock`]) assert.equal(existsSync(join(f.root, path)), false)
  const cache = JSON.parse(await readFile(join(f.root, 'cache/last_conversations.json'), 'utf8'))
  assert.deepEqual(cache, { '/foreign': FOREIGN, '/another-workspace': LATE_FOREIGN })
  for (const table of ['conversation_summaries', 'conversations_fts']) {
    const { stdout } = await executeFile('/usr/bin/sqlite3', [join(f.root, 'conversation_summaries.db'), `SELECT conversation_id FROM ${table} ORDER BY conversation_id;`])
    assert.deepEqual(stdout.trim().split('\n'), [FOREIGN, LATE_FOREIGN])
  }
})

test('LORI_AGY_CLEANUP=0 сохраняет историю, временная рабочая папка всё равно удаляется', async (t) => {
  const f = await fixture(t, { LORI_AGY_CLEANUP: '0', FAKE_SERVICE_TRACES: '1' })
  await f.done((await f.submit()).id)
  const start = (await f.events()).find((entry) => entry.event === 'start')
  assert.ok(existsSync(join(f.root, 'conversations', start.id + '.db')))
  assert.ok(existsSync(join(f.root, 'brain', start.id)))
  for (const relative of ['jetbox_summaries_proto.pb', 'conversation_summaries.db', 'conversation_summaries.db-wal', 'conversation_summaries.db-shm', `implicit/${start.id}.pb`, `log/cli-${start.id}.log`]) assert.ok(existsSync(join(f.root, relative)))
  assert.equal(existsSync(start.directory), false)
})

// Одни файлы agy восстанавливает из служебного кеша, другие нужны для входа и
// настройки. Проверяем границу чистки на реальных файлах, включая вложенные папки.
async function metadataFixture (root) {
  for (const folder of ['implicit/nested', 'log/nested', 'cache']) await mkdir(join(root, folder), { recursive: true })
  const retained = new Map([
    ['antigravity-oauth-token', 'isolated auth token'],
    ['cache/onboarding.json', '{"complete":true}'],
    ['cache/other.json', '{"keep":true}'],
    ['other.pb', 'unrelated binary'],
    ['other.db', 'unrelated database'],
    ['log/notes.txt', 'unrelated log note'],
    ['log/nested/keep.log', 'nested log remains']
  ])
  for (const [relative, content] of retained) await writeFile(join(root, relative), content, { mode: 0o600 })
  const settings = join(root, 'settings.json')
  if (!existsSync(settings)) await writeFile(settings, '{"model":"owner-model"}', { mode: 0o600 })
  retained.set('settings.json', await readFile(settings, 'utf8'))
  const metadata = new Map([
    ['jetbox_summaries_proto.pb', 'old summary metadata'],
    ['implicit/old.pb', 'old UUID metadata'],
    ['implicit/nested/old.txt', 'nested UUID metadata'],
    ['log/cli-old.log', 'old log metadata']
  ])
  for (const [relative, content] of metadata) await writeFile(join(root, relative), content)
  await writeFile(join(root, 'cache/last_conversations.json'), JSON.stringify({ '/foreign': FOREIGN }))
  return { retained, metadata }
}

test('отдельный HOME удаляет восстанавливаемую базу и служебные следы, сохраняя вход и настройки', async (t) => {
  const f = await fixture(t, { FAKE_SERVICE_TRACES: '1' })
  const { retained } = await metadataFixture(f.root)
  const cleared = async () => {
    for (const relative of ['jetbox_summaries_proto.pb', 'conversation_summaries.db', 'conversation_summaries.db-wal', 'conversation_summaries.db-shm']) assert.equal(existsSync(join(f.root, relative)), false, relative)
    assert.deepEqual(await readdir(join(f.root, 'implicit')), [])
    assert.deepEqual((await readdir(join(f.root, 'log'))).sort(), ['nested', 'notes.txt'])
    assert.deepEqual(JSON.parse(await readFile(join(f.root, 'cache/last_conversations.json'), 'utf8')), {})
    for (const [relative, content] of retained) assert.equal(await readFile(join(f.root, relative), 'utf8'), content, relative)
  }
  for (const kind of ['annotate', 'report']) {
    assert.equal((await f.done((await f.submit('запись', { kind })).id)).state, 'done')
    await cleared()
  }
  // /usage тоже оставляет логи, даже когда не создаёт разговор и не выдаёт UUID.
  f.config.childEnv.FAKE_USAGE_NO_CONVERSATION = '1'
  assert.equal((await f.request('/v1/usage')).status, 200)
  await cleared()
})

test('в HOME владельца служебные protobuf, база, implicit и log сохраняются', async (t) => {
  for (const explicit of [false, true, 'alias']) {
    const f = await fixture(t, async ({ directory, home }) => {
      let agyHome = explicit ? home : undefined
      if (explicit === 'alias') {
        agyHome = join(directory, 'owner-alias')
        await symlink(home, agyHome)
      }
      return { HOME: home, LORI_AGY_HOME: agyHome }
    })
    const { retained, metadata } = await metadataFixture(f.root)
    const result = await f.done((await f.submit()).id)
    assert.equal(result.state, 'done')
    assert.ok(existsSync(join(f.root, 'conversation_summaries.db')))
    for (const [relative, content] of [...retained, ...metadata]) assert.equal(await readFile(join(f.root, relative), 'utf8'), content, relative)
    assert.deepEqual(JSON.parse(await readFile(join(f.root, 'cache/last_conversations.json'), 'utf8')), { '/foreign': FOREIGN })
    const start = (await f.events()).find((entry) => entry.event === 'start')
    assert.equal(existsSync(join(f.root, 'conversations', start.id + '.db')), false)
    assert.equal(existsSync(join(f.root, 'brain', start.id)), false)
  }
})

test('общая чистка отдельного HOME не проходит по ссылкам в служебных путях', async (t) => {
  for (const relative of ['implicit', 'log', 'jetbox_summaries_proto.pb', '.']) {
    const f = await fixture(t)
    const outside = join(f.directory, 'outside')
    if (relative === '.') await rename(f.root, outside)
    else await mkdir(outside)
    const file = join(outside, 'cli-private.log')
    await writeFile(file, 'outside metadata')
    await symlink(relative.endsWith('.pb') ? file : outside, join(f.root, relative))
    const result = await f.done((await f.submit()).id)
    assert.equal(result.state, 'failed', relative)
    assert.equal(result.error.code, 'agent')
    assert.equal(await readFile(file, 'utf8'), 'outside metadata')
    if (relative === '.') {
      const start = (await f.events()).find((entry) => entry.event === 'start')
      assert.ok(existsSync(join(outside, 'conversations', start.id + '.db')))
    }
  }
})

test('результат и ключ истекают по TTL', async (t) => {
  const f = await fixture(t, { LORI_GATEWAY_RESULT_TTL_SECONDS: '0.18' })
  const first = await f.submit('текст', { key: 'expire' })
  assert.equal((await f.done(first.id)).state, 'done')
  await f.waitFor(() => f.request(`/v1/jobs/${first.id}`), (response) => response.status === 404)
  assert.notEqual((await f.submit('текст', { key: 'expire' })).id, first.id)
})

test('остановка шлюза гасит текущую задачу и не запускает оставшиеся', async (t) => {
  const f = await fixture(t)
  await f.submit('[hang]')
  const events = await f.waitFor(f.events, (items) => items.some((entry) => entry.event === 'descendant'))
  await f.submit('следующий')
  await f.gateway.close()
  for (const event of events.filter((entry) => ['start', 'descendant'].includes(entry.event))) assert.equal(alive(event.pid), false)
  assert.equal((await f.events()).filter((entry) => entry.event === 'start').length, 1)
})

test('/usage принимает конверт CLI, прямой payload и structured_output', async (t) => {
  const f = await fixture(t)
  for (const format of ['command', 'direct', 'structured']) {
    f.config.childEnv.FAKE_USAGE_FORMAT = format
    const response = await f.request('/v1/usage')
    assert.equal(response.status, 200, format)
    const group = response.body.groups[0]
    assert.equal(group.name, 'Gemini Models')
    assert.deepEqual(Object.keys(group.buckets[0]), ['id', 'window', 'remainingFraction', 'resetTime'])
    assert.equal(group.buckets[0].remainingFraction, 0)
  }
})

test('все поддерживаемые MIME-типы дают правильное расширение, повтор аудио не запускает модель', async (t) => {
  const f = await fixture(t)
  const types = { 'audio/mp4': 'm4a', 'audio/m4a': 'm4a', 'audio/x-m4a': 'm4a', 'audio/aac': 'aac', 'audio/mpeg': 'mp3', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/flac': 'flac', 'audio/ogg': 'ogg', 'audio/opus': 'opus', 'audio/webm': 'webm' }
  for (const [type, extension] of Object.entries(types)) {
    const response = await f.request('/v1/jobs?kind=transcribe', { method: 'POST', headers: { 'content-type': type }, body: 'audio' })
    assert.equal(response.status, 202, type)
    assert.equal((await f.done(response.body.id)).state, 'done', type)
    assert.equal((await f.events()).filter((entry) => entry.event === 'start').at(-1).audioName, `part.${extension}`)
  }
  const options = { method: 'POST', headers: { 'content-type': 'audio/mp4', 'x-lori-key': 'same-audio' }, body: '[slow]' }
  const first = await f.request('/v1/jobs?kind=transcribe', options)
  assert.equal((await f.request('/v1/jobs?kind=transcribe', options)).body.id, first.body.id)
  assert.equal((await f.done(first.body.id)).state, 'done')
  assert.equal((await f.request('/v1/jobs?kind=transcribe', options)).body.id, first.body.id)
  assert.equal((await f.events()).filter((entry) => entry.event === 'start').length, 12)
})

test('загрузка аудио пишет все чанки до запуска agy', async (t) => {
  const f = await fixture(t)
  const size = 1024 * 1024 + 13
  const response = await f.request('/v1/jobs?kind=transcribe', { method: 'POST', headers: { 'content-type': 'audio/mp4' }, body: Buffer.alloc(size, 65) })
  assert.equal((await f.done(response.body.id)).state, 'done')
  const start = (await f.events()).find((entry) => entry.event === 'start')
  assert.equal(start.audioBytes, size)
})

test('ошибка безопасной чистки не скрывается, ссылка не удаляет данные вне папки agy', async (t) => {
  const f = await fixture(t)
  const submitted = await f.submit('[link]')
  const events = await f.waitFor(f.events, (items) => items.some((entry) => entry.event === 'start'))
  const start = events.find((entry) => entry.event === 'start')
  const outside = join(f.directory, 'outside')
  await rename(join(f.root, 'brain', start.id), outside)
  await symlink(outside, join(f.root, 'brain', start.id))
  const result = await f.done(submitted.id)
  assert.equal(result.state, 'failed')
  assert.equal(result.error.code, 'agent')
  assert.ok(existsSync(join(outside, '.system_generated/logs/media/audio')))
  assert.ok(!JSON.stringify(f.logs).includes(outside))
})

test('auth имеет приоритет над timed out в фактическом выводе agy с Mac mini', async (t) => {
  const f = await fixture(t)
  for (const marker of ['[auth-macmini]', '[auth-failed]']) {
    const result = await f.done((await f.submit(marker)).id)
    assert.equal(result.state, 'failed')
    assert.equal(result.error.code, 'auth')
    assert.match(result.error.message, /Требуется вход/)
    assert.ok(result.error.message.includes(`HOME=${f.home}`))
  }
  f.config.childEnv.FAKE_ERROR_MESSAGE = 'Quota exhausted; request timed out'
  const quota = await f.done((await f.submit('[quota]')).id)
  assert.equal(quota.error.code, 'quota', 'упоминание timed out не должно скрывать и квоту')
})

test('annotate принимает короткий заголовок и обрезает длинные поля по словам', async (t) => {
  const f = await fixture(t)
  const title = 'Длинный заголовок обсуждения важного выпуска мобильного приложения Лори для всей команды'
  const description = 'Подробности обсуждения и следующие действия команды. '.repeat(5).trim()
  for (const [input, expected] of [
    ['Два слова', 'Два слова'],
    ['Один два три четыре пять шесть семь', 'Один два три четыре пять шесть семь'],
    [title, 'Длинный заголовок обсуждения важного выпуска мобильного'],
    ['А'.repeat(75), 'А'.repeat(60)]
  ]) {
    f.config.childEnv.FAKE_ANNOTATION_JSON = JSON.stringify({ title: input, description })
    const result = await f.done((await f.submit('запись')).id)
    assert.equal(result.state, 'done')
    assert.equal(result.result.title, expected)
    assert.ok(result.result.title.length <= 60)
    assert.ok(result.result.description.length <= 160)
    assert.equal(result.result.description, 'Подробности обсуждения и следующие действия команды. Подробности обсуждения и следующие действия команды. Подробности обсуждения и следующие действия команды.…')
  }
  for (const field of ['title', 'description', 'brief']) {
    const value = field === 'brief' ? { summary: { brief: ' ' } } : { [field]: ' ' }
    f.config.childEnv.FAKE_ANNOTATION_JSON = JSON.stringify(value)
    const result = await f.done((await f.submit('запись')).id)
    assert.equal(result.state, 'failed', field)
    assert.equal(result.error.code, 'agent')
  }
})

test('таймаут загрузки по умолчанию 600 секунд, значение из окружения применяется к HTTP-серверу', async (t) => {
  const standard = await fixture(t)
  assert.equal(standard.gateway.server.requestTimeout, 600000)
  assert.equal(standard.gateway.server.headersTimeout, 15000)
  const custom = await fixture(t, { LORI_GATEWAY_UPLOAD_TIMEOUT_SECONDS: '901' })
  assert.equal(custom.gateway.server.requestTimeout, 901000)
  assert.equal(custom.gateway.server.headersTimeout, 15000)
  assert.throws(() => gatewayConfig({ LORI_GATEWAY_UPLOAD_TIMEOUT_SECONDS: '0' }), /LORI_GATEWAY_UPLOAD_TIMEOUT_SECONDS/)
})

test('/usage сразу возвращает кеш во время модели, без второго agy, и обновляет cachedAt после успеха', async (t) => {
  const f = await fixture(t)
  let previousAt = ''
  for (let attempt = 0; attempt < 2; attempt++) {
    const before = Date.now()
    const fresh = await f.request('/v1/usage')
    assert.equal(fresh.status, 200)
    assert.equal(fresh.body.stale, undefined)
    const refreshed = Date.now()
    const submitted = await f.submit('[hang]')
    await f.waitFor(f.events, (items) => items.filter((entry) => entry.event === 'descendant').length === attempt + 1)
    const cached = await f.request('/v1/usage', { signal: AbortSignal.timeout(1000) })
    assert.equal(cached.status, 200)
    assert.equal(cached.body.stale, true)
    assert.deepEqual(cached.body.groups, fresh.body.groups)
    assert.equal(new Date(cached.body.cachedAt).toISOString(), cached.body.cachedAt)
    assert.ok(Date.parse(cached.body.cachedAt) >= before && Date.parse(cached.body.cachedAt) <= refreshed)
    if (previousAt) assert.ok(cached.body.cachedAt > previousAt)
    previousAt = cached.body.cachedAt
    assert.equal((await f.job(submitted.id)).state, 'running')
    assert.equal((await f.events()).filter((entry) => entry.event === 'start' && entry.kind === 'usage').length, attempt + 1)
    const again = await f.request('/v1/usage')
    assert.equal(again.body.cachedAt, cached.body.cachedAt)
    await f.request(`/v1/jobs/${submitted.id}`, { method: 'DELETE' })
  }
  assert.ok(!(await f.events()).some((entry) => entry.event === 'parallel'))
})

test('в отдельном HOME политика атомарно сливается с settings.json, остальные ключи остаются', async (t) => {
  let before
  const f = await fixture(t, {}, async ({ root }) => {
    const path = join(root, 'settings.json')
    await writeFile(path, JSON.stringify({ model: 'personal-model', notifications: true, custom: { keep: 'value' }, useG1Credits: true, allowNonWorkspaceAccess: true, toolPermission: 'always-proceed', permissions: { deny: ['old-rule'], allow: ['command(*)'], ask: ['read_file(*)'], customPermissionKey: 'preserved' } }))
    await chmod(path, 0o644)
    before = await lstat(path)
  })
  const path = join(f.root, 'settings.json')
  const settings = JSON.parse(await readFile(path, 'utf8'))
  assert.equal(settings.model, 'personal-model')
  assert.equal(settings.notifications, true)
  assert.deepEqual(settings.custom, { keep: 'value' })
  assert.equal(settings.useG1Credits, false)
  assert.equal(settings.allowNonWorkspaceAccess, false)
  assert.equal(settings.toolPermission, 'request-review')
  assert.deepEqual(settings.permissions, { deny: ['command(*)', 'write_file(*)', 'read_url(*)', 'execute_url(*)', 'mcp(*)'], allow: [], ask: [], customPermissionKey: 'preserved' })
  const after = await lstat(path)
  assert.equal(after.mode & 0o777, 0o600)
  assert.notEqual(after.ino, before.ino, 'новый файл подставлен rename, а не перезаписан на месте')
  assert.ok(!(await readdir(f.root)).some((name) => name.startsWith('.settings-lori-')))
})

test('при настоящем HOME настройки владельца не читаются и не меняются, даже если JSON повреждён', async (t) => {
  for (const explicit of [false, true, 'alias']) {
    let before
    const content = '{ original invalid settings for owner'
    const f = await fixture(t, async ({ directory, home }) => {
      let agyHome = explicit ? home : undefined
      if (explicit === 'alias') {
        agyHome = join(directory, 'home-alias')
        await symlink(home, agyHome)
      }
      return { HOME: home, LORI_AGY_HOME: agyHome }
    }, async ({ root }) => {
      const path = join(root, 'settings.json')
      await writeFile(path, content)
      await chmod(path, 0o640)
      before = await lstat(path)
    })
    const path = join(f.root, 'settings.json')
    const after = await lstat(path)
    assert.equal(after.mode, before.mode)
    assert.equal(after.ino, before.ino)
    assert.equal(after.mtimeMs, before.mtimeMs)
    assert.equal(after.atimeMs, before.atimeMs)
    assert.equal(await readFile(path, 'utf8'), content)
    assert.equal((await f.request('/v1/health')).status, 200)
  }
})

test('при повреждённом settings.json отдельного HOME шлюз не стартует и не трогает файл', async (t) => {
  for (const content of ['{ invalid json', 'null', '[]']) {
    let path
    let home
    let before
    await assert.rejects(fixture(t, {}, async (setup) => {
      home = setup.home
      path = join(setup.root, 'settings.json')
      await writeFile(path, content)
      await chmod(path, 0o644)
      before = await lstat(path)
    }), /Не удалось разобрать settings.json.*Файл не изменён, шлюз не запущен/)
    const after = await lstat(path)
    assert.equal(after.ino, before.ino)
    assert.equal(after.mode, before.mode)
    assert.equal(after.mtimeMs, before.mtimeMs)
    assert.equal(await readFile(path, 'utf8'), content)
    assert.equal(existsSync(join(home, 'events.ndjson')), false, 'до отказа CLI не должен запускаться')
  }
})
