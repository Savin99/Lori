#!/usr/bin/env node
/** Lori: локальная очередь файлов и библиотека расшифровок.
 *
 * Расшифровка остаётся локальной. OpenAI получает только текст расшифровки и
 * только после явного запроса пользователя на создание итога.
 */
import { spawn } from 'node:child_process'
import { createHash, createHmac, randomBytes, randomUUID, scrypt, timingSafeEqual } from 'node:crypto'
import { createReadStream, createWriteStream, existsSync } from 'node:fs'
import { chmod, copyFile, mkdir, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises'
import { finished } from 'node:stream/promises'
import { createServer } from 'node:http'
import { homedir } from 'node:os'
import { basename, dirname, extname, join, normalize, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const ROOT = fileURLToPath(new URL('.', import.meta.url))
const WEB_DIR = join(ROOT, 'web')
const ENV_FILE = resolve(process.env.LORI_ENV_FILE ?? join(ROOT, '..', '.env.local'))

async function loadLocalEnv(file) {
  const raw = await readFile(file, 'utf8').catch(() => '')
  for (const line of raw.split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/)
    if (!match || Object.hasOwn(process.env, match[1])) continue
    const value = match[2]
    process.env[match[1]] = (value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")) ? value.slice(1, -1) : value
  }
}

await loadLocalEnv(ENV_FILE)

const PORT = Number(process.env.LORI_PORT ?? 4173)
const VAULT = resolve(process.env.LORI_VAULT ?? '/Users/ilyaqa/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian [BRAIN]')
const TRANSCRIPTS = process.env.LORI_TRANSCRIPTS ?? 'Inbox/Транскрипты'
const LIBRARY_DIR = resolve(process.env.LORI_LIBRARY ?? join(VAULT, 'Lori'))
const LIBRARY_FILE = join(LIBRARY_DIR, 'library.json')
const JOB_DIR = join(LIBRARY_DIR, 'jobs')
const UPLOAD_DIR = join(LIBRARY_DIR, 'uploads')
const MEDIA_DIR = join(LIBRARY_DIR, 'media')
const TRASH_DIR = join(LIBRARY_DIR, 'trash')
const GIGAAM = process.env.LORI_GIGAAM_ROOT ?? '/Users/ilyaqa/Projects/GigaAM'
const TOKEN = (await readFile(process.env.LORI_TOKEN_FILE ?? join(homedir(), '.config', 'lori', 'token'), 'utf8').catch(() => '')).trim()
const PASSWORD_FILE = resolve(process.env.LORI_PASSWORD_FILE ?? join(homedir(), '.config', 'lori', 'password.json'))
const OPENAI_API_KEY = process.env.OPENAI_API_KEY?.trim() ?? ''
const OPENAI_MODEL = process.env.LORI_OPENAI_MODEL?.trim() || 'gpt-5.4-mini'
const OPENAI_API_BASE_URL = process.env.LORI_OPENAI_API_BASE_URL?.trim() || 'https://api.openai.com'
const MAX_SUMMARY_CHARS = Number(process.env.LORI_SUMMARY_MAX_CHARS ?? 600000)
const MAX_UPLOAD_BYTES = Number(process.env.LORI_MAX_UPLOAD_BYTES ?? 1024 * 1024 * 1024)
const RETENTION_MS = 30 * 24 * 60 * 60 * 1000
const COOKIE = 'lori_key'
const TEXT_EXTENSIONS = new Set(['.txt', '.md', '.markdown', '.srt', '.vtt'])
const MEDIA_EXTENSIONS = new Set(['.m4a', '.mp3', '.wav', '.aac', '.caf', '.aif', '.aiff', '.ogg', '.opus', '.webm', '.amr', '.flac', '.mp4', '.mov', '.mkv', '.avi', '.mpeg', '.mpg'])
const MIME = { '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json', '.m4a': 'audio/mp4', '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.ogg': 'audio/ogg', '.opus': 'audio/ogg', '.webm': 'audio/webm', '.mp4': 'video/mp4', '.mov': 'video/quicktime' }
const SUMMARY_SECTIONS = ['keyPoints', 'decisions', 'tasks', 'facts', 'openQuestions', 'uncertainties']
const SUMMARY_ITEM_SCHEMA = { type: 'object', additionalProperties: false, required: ['text', 'segmentIds'], properties: { text: { type: 'string' }, segmentIds: { type: 'array', items: { type: 'string' } } } }
const SUMMARY_SCHEMA = { type: 'object', additionalProperties: false, required: ['brief', ...SUMMARY_SECTIONS], properties: { brief: { type: 'string' }, ...Object.fromEntries(SUMMARY_SECTIONS.map((section) => [section, { type: 'array', items: SUMMARY_ITEM_SCHEMA }])) } }
const scryptAsync = promisify(scrypt)
const LOGIN_MAX_FAILURES = 5
const LOGIN_WINDOW_MS = 60_000
const PASSWORD_MIN_LENGTH = 8

if (!TOKEN) { console.error('[lori] нет токена — запуск без авторизации запрещён'); process.exit(1) }

let workerRunning = false
let sharedDrop = null
let eventId = 0
const eventLog = []
const sseClients = new Set()
const loginAttempts = new Map()
const EMPTY_LIBRARY = () => ({ version: 2, folders: [], records: {}, trash: {}, legacyAssignments: {} })

const err = (message, status = 400) => Object.assign(new Error(message), { status })
const sha = (value) => createHash('sha256').update(value).digest('hex')
const isUuid = (value) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value ?? '')
const isIsoDate = (value) => /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') && !Number.isNaN(new Date(`${value}T12:00:00`).getTime())
const legacyId = (path) => Buffer.from(path, 'utf8').toString('base64url')
const safeName = (value, fallback = 'запись') => String(value ?? '').replace(/[\\/:*?"<>|]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 90) || fallback
const mediaType = (name) => MIME[extname(name).toLowerCase()] ?? 'application/octet-stream'
const supportedKind = (name) => TEXT_EXTENSIONS.has(extname(name).toLowerCase()) ? 'text' : MEDIA_EXTENSIONS.has(extname(name).toLowerCase()) ? 'media' : null

function nowParts(value = new Date()) {
  const part = (number) => String(number).padStart(2, '0')
  return { date: `${value.getFullYear()}-${part(value.getMonth() + 1)}-${part(value.getDate())}`, time: `${part(value.getHours())}:${part(value.getMinutes())}` }
}
function inside(base, path) {
  const target = resolve(base, path ?? '.')
  if (relative(base, target).startsWith('..') || resolve(target) !== target) throw err('путь вне хранилища', 403)
  return target
}
const insideVault = (path) => inside(VAULT, path)
const insideLibrary = (path) => inside(LIBRARY_DIR, path)
const transcriptRoot = () => insideVault(TRANSCRIPTS)
function sameSecret(candidate, expected) { return typeof candidate === 'string' && typeof expected === 'string' && candidate.length === expected.length && timingSafeEqual(Buffer.from(candidate), Buffer.from(expected)) }
function cookieValue(request, name) {
  const value = (request.headers.cookie ?? '').split(';').map((part) => part.trim().split('=')).find(([key]) => key === name)?.slice(1).join('=')
  try { return value ? decodeURIComponent(value) : '' } catch { return '' }
}
function authRequestKey(request) { return request.socket.remoteAddress ?? 'unknown' }
function loginBlocked(request) { const state = loginAttempts.get(authRequestKey(request)); return Boolean(state?.blockedUntil && state.blockedUntil > Date.now()) }
function recordLoginFailure(request) {
  const key = authRequestKey(request); const now = Date.now(); const previous = loginAttempts.get(key)
  const state = !previous || previous.windowEndsAt <= now ? { failures: 0, windowEndsAt: now + LOGIN_WINDOW_MS, blockedUntil: 0 } : previous
  state.failures += 1
  if (state.failures >= LOGIN_MAX_FAILURES) state.blockedUntil = now + LOGIN_WINDOW_MS
  loginAttempts.set(key, state)
}
function clearLoginFailures(request) { loginAttempts.delete(authRequestKey(request)) }
async function loadPasswordConfig() {
  let raw
  try { raw = await readFile(PASSWORD_FILE, 'utf8') } catch (cause) { if (cause?.code === 'ENOENT') return null; throw cause }
  const value = JSON.parse(raw)
  if (value?.version !== 1 || typeof value.salt !== 'string' || typeof value.hash !== 'string' || Buffer.from(value.salt, 'base64').length < 16 || Buffer.from(value.hash, 'base64').length !== 64) throw new Error('[lori] файл пароля повреждён')
  return { version: 1, salt: value.salt, hash: value.hash }
}
let passwordConfig = await loadPasswordConfig()
let passwordSetupInProgress = false
function passwordSession() {
  if (!passwordConfig) return ''
  return createHmac('sha256', TOKEN).update(`lori-password-session:v1:${passwordConfig.salt}:${passwordConfig.hash}`).digest('base64url')
}
function secureCookie(request, maxAge) {
  const localHost = /^(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?$/i.test(request.headers.host ?? '')
  const localPeer = /^(?:127\.0\.0\.1|::1|::ffff:127\.0\.0\.1)$/.test(request.socket.remoteAddress ?? '')
  const secure = localHost && localPeer ? '' : 'Secure; '
  return `${COOKIE}=${encodeURIComponent(passwordSession())}; HttpOnly; ${secure}SameSite=Strict; Path=/; Max-Age=${maxAge}`
}
async function savePasswordConfig(value) {
  await mkdir(dirname(PASSWORD_FILE), { recursive: true })
  const temporary = `${PASSWORD_FILE}.${randomUUID()}.tmp`
  try {
    await writeFile(temporary, JSON.stringify(value) + '\n', { encoding: 'utf8', mode: 0o600 })
    await rename(temporary, PASSWORD_FILE)
    await chmod(PASSWORD_FILE, 0o600)
  } catch (cause) { await rm(temporary, { force: true }).catch(() => {}); throw cause }
}
function validatePassword(value) {
  if (typeof value !== 'string' || value.length < PASSWORD_MIN_LENGTH) throw err(`пароль должен быть не короче ${PASSWORD_MIN_LENGTH} символов`)
  if (value.length > 256) throw err('пароль слишком длинный')
  return value
}
async function setPassword(value) {
  if (passwordConfig || passwordSetupInProgress) throw err('пароль уже настроен', 409)
  passwordSetupInProgress = true
  try {
    const salt = randomBytes(16); const hash = await scryptAsync(validatePassword(value), salt, 64)
    const next = { version: 1, salt: salt.toString('base64'), hash: hash.toString('base64') }
    await savePasswordConfig(next); passwordConfig = next
  } finally { passwordSetupInProgress = false }
}
async function matchesPassword(value) {
  if (!passwordConfig || typeof value !== 'string') return false
  const expected = Buffer.from(passwordConfig.hash, 'base64')
  const actual = await scryptAsync(value, Buffer.from(passwordConfig.salt, 'base64'), expected.length)
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}
function auth(request) {
  const bearer = (request.headers.authorization ?? '').replace(/^Bearer\s+/i, '')
  if (sameSecret(bearer, TOKEN)) return 'service'
  return passwordConfig && sameSecret(cookieValue(request, COOKIE), passwordSession()) ? 'password' : 'deny'
}
function reply(response, status, data) {
  // Ответ мог уже начаться (например, отдача файла): второй writeHead бросал ERR_HTTP_HEADERS_SENT и убивал процесс.
  if (response.headersSent || response.writableEnded) { response.end(); return }
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); response.end(JSON.stringify(data))
}

async function readJson(request, limit = 2 * 1024 * 1024) {
  const chunks = []; let size = 0
  for await (const chunk of request) { size += chunk.length; if (size > limit) throw err('запрос слишком большой', 413); chunks.push(chunk) }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')) } catch { throw err('некорректный JSON') }
}
async function readRaw(request, limit = 8 * 1024 * 1024) {
  const chunks = []; let size = 0
  for await (const chunk of request) { size += chunk.length; if (size > limit) throw err('файл слишком большой', 413); chunks.push(chunk) }
  return Buffer.concat(chunks)
}
async function saveRequestToFile(request, target) {
  await mkdir(dirname(target), { recursive: true })
  const output = createWriteStream(target, { flags: 'wx' }); let size = 0
  try {
    for await (const chunk of request) {
      size += chunk.length; if (size > MAX_UPLOAD_BYTES) throw err('файл больше допустимого лимита', 413)
      if (!output.write(chunk)) await new Promise((done) => output.once('drain', done))
    }
    if (!size) throw err('пустой файл')
    output.end(); await finished(output); return size
  } catch (cause) { output.destroy(); await rm(target, { force: true }).catch(() => {}); throw cause }
}
async function writeAtomic(path, content) {
  await mkdir(dirname(path), { recursive: true })
  const temporary = `${path}.${randomUUID()}.tmp`; await writeFile(temporary, content, 'utf8'); await rename(temporary, path)
}

function normalizeLibrary(value) {
  const input = value && typeof value === 'object' ? value : {}
  return { version: 2, folders: Array.isArray(input.folders) ? input.folders.filter((folder) => folder && isUuid(folder.id)) : [], records: input.records && typeof input.records === 'object' && !Array.isArray(input.records) ? input.records : {}, trash: input.trash && typeof input.trash === 'object' ? input.trash : {}, legacyAssignments: input.assignments && typeof input.assignments === 'object' ? input.assignments : {} }
}
async function loadLibrary() {
  let raw
  try { raw = await readFile(LIBRARY_FILE, 'utf8') } catch (cause) { if (cause?.code !== 'ENOENT') console.error(`[lori] библиотеку не удалось прочитать (${cause.code ?? cause.message}) — работаю с пустой`); return EMPTY_LIBRARY() }
  try { return normalizeLibrary(JSON.parse(raw)) } catch (cause) {
    // Повреждённый файл не затираем молча: рядом остаётся копия, иначе первая же запись уничтожит библиотеку.
    const backup = `${LIBRARY_FILE}.corrupt-${Date.now()}`
    await writeFile(backup, raw, 'utf8').catch(() => {})
    console.error(`[lori] библиотека повреждена (${cause.message}); копия: ${backup}`)
    return EMPTY_LIBRARY()
  }
}
// Библиотека живёт в памяти единственным экземпляром: параллельные запросы правят один и тот же объект,
// поэтому запись очереди больше не затирает переименование папки и наоборот.
let libraryState = null
let libraryLoading = null
let migratedAt = 0
let saveChain = Promise.resolve()
const MIGRATION_INTERVAL_MS = Number(process.env.LORI_MIGRATION_INTERVAL_MS ?? 15_000)
function saveLibrary(library = libraryState) {
  if (!library) return Promise.resolve()
  const snapshot = () => JSON.stringify({ version: 2, folders: library.folders, records: library.records, trash: library.trash }, null, 2) + '\n'
  saveChain = saveChain.then(() => writeAtomic(LIBRARY_FILE, snapshot())).catch((cause) => { console.error(`[lori] библиотеку не удалось сохранить: ${cause.message ?? cause}`) })
  return saveChain
}
async function walkMarkdown(dir) {
  let entries; try { entries = await readdir(dir, { withFileTypes: true }) } catch { return [] }
  const result = []
  for (const entry of entries) { if (entry.name.startsWith('.')) continue; const file = join(dir, entry.name); if (entry.isDirectory()) result.push(...await walkMarkdown(file)); else if (entry.isFile() && extname(entry.name).toLowerCase() === '.md') result.push(file) }
  return result
}
// File Provider can return EAGAIN if the file is being hydrated. Reading and
// stat'ing in parallel made that intermittent condition much more likely.
async function retrying(action, attempts = 4) {
  let failure
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try { return await action() } catch (cause) {
      failure = cause
      if (attempt + 1 < attempts) await new Promise((resolveWait) => setTimeout(resolveWait, 80 * (attempt + 1)))
    }
  }
  throw failure
}
async function readLegacyTranscript(file) { return retrying(async () => { const raw = await readFile(file, 'utf8'); const info = await stat(file); return [raw, info] }) }
// Один и тот же транскрипт читается на каждый /api/library. Пока mtime и размер те же, файл берём из памяти.
const transcriptCache = new Map()
async function readTranscriptFile(file) {
  const info = await retrying(() => stat(file))
  const key = `${info.mtimeMs}:${info.size}`
  const cached = transcriptCache.get(file)
  if (cached?.key === key) return [cached.raw, cached.info]
  const raw = await retrying(() => readFile(file, 'utf8'))
  if (transcriptCache.size >= 500) transcriptCache.clear()
  transcriptCache.set(file, { key, raw, info })
  return [raw, info]
}
function frontmatter(raw) {
  const match = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?/); if (!match) return { fields: {}, body: raw }
  const fields = {}; for (const line of match[1].split(/\r?\n/)) { const item = line.match(/^([\w-]+):\s*(.*)$/); if (item) fields[item[1]] = item[2].replace(/^['"]|['"]$/g, '').trim() }
  return { fields, body: raw.slice(match[0].length) }
}
function rawTranscript(body) { const heading = body.match(/^##\s+(?:Transcript|Расшифровка)\s*$/mi); return (heading ? body.slice(heading.index + heading[0].length) : body).replace(/^#\s+.+$/m, '').replace(/\r/g, '').trim() }
function titleFrom(path, body) { return body.match(/^#\s+(.+)$/m)?.[1].trim() || basename(path, '.md').replace(/^\d{4}-\d{2}-\d{2}\s+\d{4}\s*/, '').trim() || 'Без названия' }
function dateFrom(path, fallback) { const match = basename(path).match(/^(\d{4}-\d{2}-\d{2})\s+(\d{2})(\d{2})/); return match ? { date: match[1], time: `${match[2]}:${match[3]}` } : nowParts(fallback ?? new Date()) }
function seconds(value) { const bits = String(value).replace(',', '.').split(':').map(Number); return bits.length === 3 ? bits[0] * 3600 + bits[1] * 60 + bits[2] : bits[0] * 60 + bits[1] }
function parseSegments(text, extension = '') {
  const segments = []; const pattern = /(?:^|\n)\s*(?:\[S(\d+)(?:-S\d+)?\]\s*)?\[(\d\d:\d\d:\d\d)\s*-\s*(\d\d:\d\d:\d\d)\]\s*(?:\*\*([^*]+):\*\*\s*)?([^\n]+)/g; let found
  while ((found = pattern.exec(text))) segments.push({ id: `S${found[1] ?? segments.length + 1}`, start: seconds(found[2]), end: seconds(found[3]), speaker: found[4]?.trim() || null, text: found[5].trim() })
  if (segments.length) return segments
  if (['.srt', '.vtt'].includes(extension)) {
    for (const block of text.replace(/^WEBVTT[^\n]*\n?/i, '').trim().split(/\n\s*\n/)) {
      const lines = block.split(/\n/).filter(Boolean); const timing = lines.find((line) => /-->/.test(line)); if (!timing) continue
      const [start, end] = timing.split(/\s*-->\s*/).map((part) => part.trim()); const content = lines.slice(lines.indexOf(timing) + 1).join(' ').replace(/<[^>]+>/g, '').trim()
      if (content) segments.push({ id: `S${segments.length + 1}`, start: seconds(start), end: seconds(end), speaker: null, text: content })
    }
  }
  return segments.length ? segments : text.trim().split(/\n{2,}/).filter(Boolean).map((part, index) => ({ id: `P${index + 1}`, start: null, end: null, speaker: null, text: part.replace(/\s+/g, ' ').trim() }))
}
const segmentText = (segments, fallback) => segments.length ? segments.map((segment) => segment.text).join('\n\n') : fallback.trim()

async function migrateLegacy(library) {
  const known = new Set([...Object.values(library.records).map((record) => record?.transcriptPath), ...Object.values(library.trash ?? {}).map((entry) => entry?.originalPath)].filter(Boolean)); let changed = false
  for (const file of await walkMarkdown(transcriptRoot())) {
    const path = relative(VAULT, file); if (known.has(path)) continue
    let raw; let info
    try { [raw, info] = await readTranscriptFile(file) } catch (cause) { console.error(`[lori] транскрипт пока не читается (${cause?.code ?? cause?.message}): ${path}`); continue }
    const parsed = frontmatter(raw); const when = dateFrom(path, info.mtime); const id = randomUUID()
    library.records[id] = { id, title: titleFrom(path, parsed.body), created: isIsoDate(parsed.fields.created) ? parsed.fields.created : when.date, time: when.time, duration: parsed.fields.duration ?? null, source: parsed.fields.source ?? null, transcriptPath: path, folderId: library.legacyAssignments[legacyId(path)] ?? null, status: 'transcript_ready', transcriptHash: sha(rawTranscript(parsed.body)), summaries: [], currentSummaryId: null, createdAt: info.birthtime.toISOString(), updatedAt: info.mtime.toISOString() }; known.add(path); changed = true
  }
  if (changed) await saveLibrary(library); return library
}
async function getLibrary({ migrate = true } = {}) {
  if (!libraryState) { libraryLoading ??= loadLibrary(); libraryState = await libraryLoading; libraryLoading = null }
  // Обход хранилища — дорогая операция на iCloud, поэтому не чаще раза в MIGRATION_INTERVAL_MS.
  if (migrate && Date.now() - migratedAt >= MIGRATION_INTERVAL_MS) { migratedAt = Date.now(); await migrateLegacy(libraryState) }
  return libraryState
}
const currentSummary = (meta) => meta.summaries?.find((summary) => summary.id === meta.currentSummaryId) ?? null
const isStale = (meta) => Boolean(currentSummary(meta) && currentSummary(meta).transcriptHash !== meta.transcriptHash)
// Дата из чужого frontmatter может быть любой строкой; интерфейс форматирует её через Intl и падает на мусоре.
function safeCreated(meta) {
  if (isIsoDate(meta?.created)) return meta.created
  const fallback = new Date(meta?.createdAt ?? Date.now())
  return nowParts(Number.isNaN(fallback.getTime()) ? new Date() : fallback).date
}
const safeTime = (meta) => /^\d{1,2}:\d{2}$/.test(meta?.time ?? '') ? meta.time : '00:00'
async function recordFrom(meta, includeTranscript = false) {
  if (!meta?.transcriptPath) return { id: meta.id, title: meta.title, created: safeCreated(meta), time: safeTime(meta), folderId: meta.folderId ?? null, status: meta.status, error: meta.error ?? null, updated: new Date(meta.updatedAt).getTime(), wordCount: 0, excerpt: '', summary: null, summaryStatus: 'missing', media: null, jobId: meta.jobId ?? null }
  const file = insideVault(meta.transcriptPath); const [raw, info] = await readTranscriptFile(file); const parsed = frontmatter(raw); const original = rawTranscript(parsed.body); const text = meta.transcriptOverride?.text ?? original; const segments = parseSegments(text, extname(meta.source ?? meta.transcriptPath).toLowerCase()); const transcript = segmentText(segments, text); const summary = currentSummary(meta)
  return { id: meta.id, title: meta.title || titleFrom(meta.transcriptPath, parsed.body), created: safeCreated(meta), time: safeTime(meta), duration: meta.duration ?? null, source: meta.source ?? null, folderId: meta.folderId ?? null, status: meta.status ?? 'transcript_ready', error: meta.error ?? null, updated: new Date(meta.updatedAt ?? info.mtime).getTime(), wordCount: transcript.split(/\s+/).filter(Boolean).length, excerpt: transcript.replace(/\s+/g, ' ').slice(0, 180), summary: summary ? { ...summary, stale: isStale(meta) } : null, summaryStatus: summary ? isStale(meta) ? 'stale' : 'ready' : 'missing', media: meta.media ? { ...meta.media, available: Boolean(meta.media.path && existsSync(insideLibrary(meta.media.path))) } : null, jobId: meta.jobId ?? null, ...(includeTranscript ? { transcript, segments, transcriptVersion: meta.transcriptOverride?.version ?? 0 } : {}) }
}
async function getRecord(id, library, includeTranscript = true) { if (!isUuid(id) || !library.records[id] || library.trash[id]) throw err('запись не найдена', 404); return recordFrom(library.records[id], includeTranscript) }
async function listRecords(library) { const output = []; for (const meta of Object.values(library.records)) if (meta && !library.trash[meta.id]) { try { output.push(await recordFrom(meta)) } catch {} } return output.sort((left, right) => right.updated - left.updated) }

async function writeTranscript({ id, title, text, source }) {
  const when = nowParts(); const folder = join(transcriptRoot(), when.date.slice(0, 7)); await mkdir(folder, { recursive: true }); const stem = `${when.date} ${when.time.replace(':', '')} ${safeName(title)}`; let file = join(folder, `${stem}.md`)
  for (let index = 2; existsSync(file); index += 1) file = join(folder, `${stem}-${index}.md`)
  const cleaned = String(text ?? '').replace(/\r/g, '').trim(); await writeFile(file, ['---', 'type: transcript', `lori_id: ${id}`, `created: ${when.date}`, ...(source ? [`source: ${JSON.stringify(source)}`] : []), 'tags: [расшифровка]', '---', '', `# ${safeName(title)}`, '', '## Расшифровка', '', cleaned, ''].join('\n'), 'utf8')
  return { path: relative(VAULT, file), created: when.date, time: when.time, hash: sha(cleaned) }
}
async function createTextRecord(input) {
  const title = safeName(input.title); const text = String(input.text ?? '').replace(/\r/g, '').trim(); if (text.length < 3) throw err('добавь текст расшифровки')
  const library = await getLibrary(); const folderId = input.folderId ? String(input.folderId) : null; if (folderId && !library.folders.some((folder) => folder.id === folderId)) throw err('папка не найдена', 404)
  const id = randomUUID(); const written = await writeTranscript({ id, title, text, source: input.source ?? null }); library.records[id] = { id, title, created: written.created, time: written.time, transcriptPath: written.path, source: input.source ?? null, folderId, status: 'transcript_ready', transcriptHash: written.hash, summaries: [], currentSummaryId: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() }; await saveLibrary(library); broadcast('record', { id, status: 'transcript_ready' }); return getRecord(id, library)
}

const jobPath = (id) => join(JOB_DIR, `${id}.json`)
async function saveJob(job) { job.updatedAt = new Date().toISOString(); await writeAtomic(jobPath(job.id), JSON.stringify(job, null, 2) + '\n') }
async function loadJob(id) { if (!isUuid(id)) throw err('задание не найдено', 404); try { return JSON.parse(await readFile(jobPath(id), 'utf8')) } catch { throw err('задание не найдено', 404) } }
async function listJobs() { let entries; try { entries = await readdir(JOB_DIR) } catch { return [] }; const jobs = await Promise.all(entries.filter((entry) => entry.endsWith('.json')).map(async (entry) => { try { return JSON.parse(await readFile(join(JOB_DIR, entry), 'utf8')) } catch { return null } })); return jobs.filter(Boolean).sort((left, right) => left.createdAt.localeCompare(right.createdAt)) }
function publicJob(job) { return { id: job.id, recordId: job.recordId, filename: job.filename, state: job.state, error: job.error ?? null, createdAt: job.createdAt, updatedAt: job.updatedAt } }
function broadcast(type, data) { const event = { id: ++eventId, type, data }; eventLog.push(event); if (eventLog.length > 100) eventLog.shift(); const message = `id: ${event.id}\nevent: ${type}\ndata: ${JSON.stringify(data)}\n\n`; for (const client of sseClients) client.write(message) }
// HTTP-заголовки приходят в latin1: процентную запись раскодируем, «сырой» UTF-8 восстанавливаем из байтов,
// иначе русское имя из «Поделиться» превращалось в мохибейк вроде «ÐÑÑÑÐµÑÐ°».
function headerText(value, fallback = '') {
  const raw = String(value ?? '')
  if (!raw) return fallback
  const repaired = Buffer.from(raw, 'latin1').toString('utf8')
  if (/%[0-9a-fA-F]{2}/.test(raw)) { try { return decodeURIComponent(raw) || fallback } catch { return repaired || fallback } }
  return repaired || fallback
}
async function enqueueUpload(request) {
  const name = headerText(request.headers['x-lori-name'], 'запись')
  const extension = extname(name).toLowerCase()
  const filename = safeName(basename(name, extname(name)), 'запись') + extension; const kind = supportedKind(filename); if (!kind) throw err('поддерживаются аудио, видео, TXT, Markdown, SRT и VTT')
  const library = await getLibrary(); const folderId = String(request.headers['x-lori-folder'] ?? '') || null; if (folderId && !library.folders.some((folder) => folder.id === folderId)) throw err('папка не найдена', 404)
  const requestedTitle = headerText(request.headers['x-lori-title'])
  const jobId = randomUUID(); const recordId = randomUUID(); const upload = join(UPLOAD_DIR, `${jobId}-${filename}`); const size = await saveRequestToFile(request, upload); const when = nowParts(); const title = safeName(requestedTitle || basename(filename, extname(filename)))
  library.records[recordId] = { id: recordId, title, created: when.date, time: when.time, transcriptPath: null, source: filename, folderId, status: 'queued', transcriptHash: null, summaries: [], currentSummaryId: null, jobId, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() }; await saveLibrary(library)
  const job = { id: jobId, recordId, filename, kind, uploadPath: relative(LIBRARY_DIR, upload), size, diarize: String(request.headers['x-lori-diarize'] ?? '') === 'true', state: 'queued', error: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() }; await saveJob(job); broadcast('job', publicJob(job)); pumpQueue().catch((cause) => console.error(`[lori] очередь остановилась: ${cause?.message ?? cause}`)); return job
}
// Раньше подпроцесс был один на весь сервер: отмена расшифровки могла убить экспорт PDF и наоборот.
const activeChildren = new Map()
function run(command, args, env = process.env, jobId = null) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(command, args, { env, stdio: ['ignore', 'pipe', 'pipe'], detached: true })
    if (jobId) activeChildren.set(jobId, child)
    let stderr = ''
    child.stderr.on('data', (chunk) => { stderr += String(chunk) })
    child.on('error', (cause) => { if (jobId) activeChildren.delete(jobId); rejectRun(cause) })
    child.on('exit', (code, signal) => { if (jobId) activeChildren.delete(jobId); resolveRun({ code: code ?? 1, signal, stderr }) })
  })
}
function stopJobChild(jobId) {
  const child = activeChildren.get(jobId); if (!child) return false
  // detached: гасим всю группу, иначе python и ffmpeg остаются работать после отмены.
  try { process.kill(-child.pid, 'SIGTERM') } catch { child.kill('SIGTERM') }
  return true
}
async function transcribeMedia(file, diarize, jobId = null) {
  const work = join(LIBRARY_DIR, 'work', randomUUID()); const output = join(work, 'transcript.md'); await mkdir(work, { recursive: true })
  try { const result = await run(`${GIGAAM}/.venv/bin/python`, [`${GIGAAM}/mac_transcriber/scripts/transcribe_md.py`, file, '--output', output, '--work-root', join(work, 'asr'), '--device', process.env.LORI_DEVICE ?? 'cpu', ...(diarize ? ['--diarize'] : [])], { ...process.env, MAC_TRANSCRIBER_REPORT_MODE: 'local', MAC_TRANSCRIBER_REPORT_PDF: '0', MAC_TRANSCRIBER_DATABASE_URL: '', MAC_TRANSCRIBER_POSTGRES_DSN: '', MAC_TRANSCRIBER_OPENAI_ENV_FILE: '', OPENAI_API_KEY: '' }, jobId); if (result.code !== 0) throw err(`расшифровка не завершилась${result.stderr ? ': ' + result.stderr.slice(-220).trim() : ''}`, 500); return rawTranscript(await readFile(output, 'utf8')) } finally { await rm(work, { recursive: true, force: true }).catch(() => {}) }
}

function responseText(payload) {
  if (typeof payload?.output_text === 'string') return payload.output_text
  return payload?.output?.flatMap((item) => item?.content ?? []).filter((item) => item?.type === 'output_text').map((item) => item.text).join('') ?? ''
}
function cleanSummaryText(value, maximum = 1500) { return typeof value === 'string' ? value.replace(/\s+/g, ' ').trim().slice(0, maximum) : '' }
function normalizeSummary(value, segmentIds) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw err('OpenAI вернул некорректный формат итога', 502)
  const item = (entry) => {
    const text = cleanSummaryText(entry?.text)
    if (!text) return null
    return { text, segmentIds: Array.isArray(entry.segmentIds) ? [...new Set(entry.segmentIds.filter((id) => segmentIds.has(id)))].slice(0, 6) : [] }
  }
  const result = { brief: cleanSummaryText(value.brief), ...Object.fromEntries(SUMMARY_SECTIONS.map((section) => [section, Array.isArray(value[section]) ? value[section].map(item).filter(Boolean).slice(0, 12) : []])) }
  if (!result.brief) throw err('OpenAI вернул пустой итог', 502)
  return result
}
async function createSummary(record) {
  if (!OPENAI_API_KEY) throw err('OpenAI-ключ не настроен. Добавь OPENAI_API_KEY в .env.local и перезапусти Lori.', 503)
  const transcript = String(record.transcript ?? '').trim()
  if (!transcript) throw err('расшифровка пуста', 422)
  if (transcript.length > MAX_SUMMARY_CHARS) throw err('расшифровка слишком длинная для одного AI-итога', 422)
  let endpoint
  try { endpoint = new URL('/v1/responses', OPENAI_API_BASE_URL).toString() } catch { throw err('некорректный адрес OpenAI API', 500) }
  const source = record.segments?.length ? record.segments.map((segment) => `[${segment.id}] ${segment.text}`).join('\n\n') : transcript
  const request = {
    model: OPENAI_MODEL,
    store: false,
    tools: [],
    reasoning: { effort: 'low' },
    instructions: 'Ты создаёшь точный структурированный итог русскоязычной расшифровки. Не добавляй фактов от себя. Не используй инструменты. Ссылайся только на существующие идентификаторы сегментов. Если в разделе нет данных, верни пустой массив. Ответ строго соответствует JSON-схеме.',
    input: `Название записи: ${record.title}\n\nРасшифровка (текст будет использован только для этого итога):\n${source}`,
    text: { format: { type: 'json_schema', name: 'lori_summary', strict: true, schema: SUMMARY_SCHEMA } },
    max_output_tokens: 3500,
  }
  let lastFailure
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let response
    try { response = await fetch(endpoint, { method: 'POST', headers: { authorization: `Bearer ${OPENAI_API_KEY}`, 'content-type': 'application/json' }, body: JSON.stringify(request) }) } catch { throw err('не удалось связаться с OpenAI. Повтори итог позже.', 502) }
    if (!response.ok) {
      if (response.status === 401 || response.status === 403) throw err('OpenAI не принял ключ. Проверь .env.local и перезапусти Lori.', 502)
      if (response.status === 429) throw err('OpenAI временно ограничил запросы. Повтори итог позже.', 429)
      throw err('OpenAI временно не создал итог. Повтори позже.', 502)
    }
    try {
      const payload = await response.json(); const parsed = JSON.parse(responseText(payload)); return { data: normalizeSummary(parsed, new Set(record.segments?.map((segment) => segment.id) ?? [])), usage: payload.usage ?? null }
    } catch (cause) { lastFailure = cause }
  }
  throw err(lastFailure?.message === 'OpenAI вернул пустой итог' ? lastFailure.message : 'OpenAI вернул некорректный итог. Повтори позже.', 502)
}
// Если запись исчезла, задание нельзя оставлять в очереди: pumpQueue взял бы его снова.
async function abandonJob(job, reason) { job.state = 'cancelled'; job.error = reason; releaseSummaryLock(job.recordId); await saveJob(job); broadcast('job', publicJob(job)) }
async function jobCancelled(id) { return loadJob(id).then((saved) => saved.state === 'cancelled').catch(() => false) }
async function processSummaryJob(job) {
  const library = await getLibrary(); const record = library.records[job.recordId]; if (job.state === 'cancelled') return; if (!record) return abandonJob(job, 'запись удалена')
  job.state = 'summarizing'; job.error = null; record.status = 'summarizing'; record.error = null; record.updatedAt = new Date().toISOString(); await Promise.all([saveJob(job), saveLibrary(library)]); broadcast('job', publicJob(job)); broadcast('record', { id: record.id, status: record.status })
  try {
    const view = await getRecord(record.id, library); const result = await createSummary(view); const summary = { id: randomUUID(), version: (record.summaries?.length ?? 0) + 1, createdAt: new Date().toISOString(), transcriptHash: record.transcriptHash, model: OPENAI_MODEL, data: result.data, usage: result.usage ? { inputTokens: result.usage.input_tokens ?? null, outputTokens: result.usage.output_tokens ?? null } : null }
    record.summaries = [...(record.summaries ?? []), summary]; record.currentSummaryId = summary.id; record.status = 'ready'; record.error = null; record.updatedAt = new Date().toISOString(); job.state = 'ready'
  } catch (cause) {
    if (await jobCancelled(job.id)) { job.state = 'cancelled'; job.error = null; record.status = 'transcript_ready'; record.error = null }
    else { job.state = 'failed'; job.error = String(cause.message ?? cause); record.status = 'transcript_ready'; record.error = job.error }
    record.updatedAt = new Date().toISOString()
  }
  releaseSummaryLock(job.recordId)
  await Promise.all([saveJob(job), saveLibrary(library)]); broadcast('job', publicJob(job)); broadcast('record', { id: record.id, status: record.status, error: record.error ?? null })
}
async function processJob(job) {
  if (job.kind === 'summary') return processSummaryJob(job)
  const library = await getLibrary(); const record = library.records[job.recordId]; if (job.state === 'cancelled') return; if (!record) return abandonJob(job, 'запись удалена'); const upload = insideLibrary(job.uploadPath)
  job.state = 'transcribing'; job.error = null; record.status = 'transcribing'; record.error = null; record.updatedAt = new Date().toISOString(); await Promise.all([saveJob(job), saveLibrary(library)]); broadcast('job', publicJob(job)); broadcast('record', { id: record.id, status: record.status })
  try {
    const text = job.kind === 'text' ? await readFile(upload, 'utf8') : await transcribeMedia(upload, job.diarize, job.id); if (!text.trim()) throw err('из файла не удалось получить текст', 422); const written = await writeTranscript({ id: record.id, title: record.title, text, source: job.filename }); Object.assign(record, { transcriptPath: written.path, transcriptHash: written.hash, created: written.created, time: written.time, status: 'transcript_ready', updatedAt: new Date().toISOString() })
    if (job.kind === 'media') { const path = join(MEDIA_DIR, `${record.id}${extname(job.filename).toLowerCase()}`); await mkdir(MEDIA_DIR, { recursive: true }); await rename(upload, path); record.media = { name: job.filename, path: relative(LIBRARY_DIR, path), mimeType: mediaType(job.filename), expiresAt: new Date(Date.now() + RETENTION_MS).toISOString() } } else await rm(upload, { force: true })
    job.state = 'transcript_ready'; await Promise.all([saveJob(job), saveLibrary(library)])
  } catch (cause) {
    // Отмена приходит убийством подпроцесса: это не ошибка расшифровки, и запись должна остаться «Отменено».
    if (await jobCancelled(job.id)) { job.state = 'cancelled'; job.error = null; record.status = 'cancelled'; record.error = null }
    else { job.state = 'failed'; job.error = String(cause.message ?? cause); record.status = 'failed'; record.error = job.error }
    record.updatedAt = new Date().toISOString(); await Promise.all([saveJob(job), saveLibrary(library)])
  }
  broadcast('job', publicJob(job)); broadcast('record', { id: record.id, status: record.status, error: record.error ?? null })
}
// Список заданий перечитываем на каждом шаге: иначе загруженный во время работы файл ждал бы до следующего запуска.
async function pumpQueue() {
  if (workerRunning) return
  workerRunning = true
  try {
    for (let guard = 0; guard < 10_000; guard += 1) {
      const next = (await listJobs()).find((job) => job.state === 'queued')
      if (!next) return
      try { await processJob(next) } catch (cause) {
        // Неожиданный сбой обязан оставить терминальное состояние, иначе очередь закрутится на этом задании.
        console.error(`[lori] задание не обработалось: ${cause?.message ?? cause}`)
        next.state = 'failed'; next.error = String(cause?.message ?? cause)
        await saveJob(next).catch(() => {}); broadcast('job', publicJob(next))
      }
    }
  } finally { workerRunning = false }
}
async function recoverQueue() { for (const job of await listJobs()) if (['transcribing', 'summarizing'].includes(job.state)) { job.state = 'queued'; job.error = null; await saveJob(job) }; await pumpQueue() }
// Замок в памяти нужен потому, что проверка «уже считается?» и запись задания на диск разделены await:
// три одновременных нажатия успевали проскочить проверку и оплатить три запроса в OpenAI.
const summaryLocks = new Map()
const releaseSummaryLock = (recordId) => summaryLocks.delete(recordId)
async function enqueueSummary(recordId) {
  if (!OPENAI_API_KEY) throw err('OpenAI-ключ не настроен. Добавь OPENAI_API_KEY в .env.local и перезапусти Lori.', 503)
  const pending = summaryLocks.get(recordId)
  if (pending) return pending
  const job = { id: randomUUID(), recordId, kind: 'summary', filename: null, state: 'queued', error: null, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() }
  summaryLocks.set(recordId, job)
  try {
    const library = await getLibrary(); const record = library.records[recordId]
    if (!record || library.trash[recordId]) throw err('запись не найдена', 404)
    if (!record.transcriptPath) throw err('расшифровка ещё не готова', 409)
    // Задание могло остаться в очереди с прошлого запуска — тогда отдаём его, а не создаём второе.
    const running = (await listJobs()).find((item) => item.recordId === recordId && item.kind === 'summary' && item.id !== job.id && ['queued', 'summarizing'].includes(item.state))
    if (running) { summaryLocks.set(recordId, running); return running }
    record.status = 'summarizing'; record.error = null; record.jobId = job.id; record.updatedAt = new Date().toISOString()
    await Promise.all([saveJob(job), saveLibrary(library)])
    broadcast('job', publicJob(job)); broadcast('record', { id: record.id, status: record.status })
    pumpQueue().catch((cause) => console.error(`[lori] очередь остановилась: ${cause?.message ?? cause}`))
    return job
  } catch (cause) { releaseSummaryLock(recordId); throw cause }
}

async function updateRecord(id, input) {
  const library = await getLibrary(); const record = library.records[id]; if (!record || library.trash[id]) throw err('запись не найдена', 404)
  if (Object.hasOwn(input, 'title')) record.title = safeName(input.title)
  if (Object.hasOwn(input, 'folderId')) { const folderId = input.folderId ? String(input.folderId) : null; if (folderId && !library.folders.some((folder) => folder.id === folderId)) throw err('папка не найдена', 404); record.folderId = folderId }
  if (Object.hasOwn(input, 'transcript')) { const text = String(input.transcript ?? '').replace(/\r/g, '').trim(); if (text.length < 3) throw err('расшифровка слишком короткая'); record.transcriptOverride = { text, version: (record.transcriptOverride?.version ?? 0) + 1, editedAt: new Date().toISOString() }; record.transcriptHash = sha(text) }
  record.updatedAt = new Date().toISOString(); await saveLibrary(library); broadcast('record', { id, status: record.status }); return getRecord(id, library)
}
function summaryMarkdown(summary) {
  if (!summary?.data) return ''; const data = summary.data; const section = (name, values) => Array.isArray(values) && values.length ? `## ${name}\n\n${values.map((value) => `- ${typeof value === 'string' ? value : value.text ?? value.title ?? ''}`).join('\n')}\n\n` : ''
  return [data.brief ? `## Краткий вывод\n\n${data.brief}\n\n` : '', section('Ключевые пункты', data.keyPoints), section('Решения', data.decisions), section('Задачи', data.tasks), section('Важные даты и факты', data.facts), section('Открытые вопросы', data.openQuestions), section('Неуверенные места', data.uncertainties)].join('')
}
function exportMarkdown(record, content) { return [`# ${record.title}`, '', `${record.created} · ${record.time}`, '', ...((content === 'summary' || content === 'both') && record.summary ? [summaryMarkdown(record.summary)] : []), ...((content === 'transcript' || content === 'both') ? ['## Расшифровка', '', record.transcript, ''] : [])].join('\n') }
const escapeHtml = (value) => String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
function exportHtml(record, content) { return `<!doctype html><meta charset="utf-8"><style>@page{size:A4;margin:21mm 18mm}body{font-family:Arial,sans-serif;font-size:11pt;line-height:1.55;color:#202020}h1{font:400 25pt Georgia}h2{font-size:13pt;margin-top:7mm}p{margin:0 0 3mm}li{margin-bottom:2mm}</style>${exportMarkdown(record, content).split('\n').map((line) => line.startsWith('# ') ? `<h1>${escapeHtml(line.slice(2))}</h1>` : line.startsWith('## ') ? `<h2>${escapeHtml(line.slice(3))}</h2>` : line.startsWith('- ') ? `<li>${escapeHtml(line.slice(2))}</li>` : line ? `<p>${escapeHtml(line)}</p>` : '').join('')}` }
async function pdfFor(record, content) {
  const work = join(LIBRARY_DIR, 'work', randomUUID()); const html = join(work, 'record.html'); const pdf = join(work, 'record.pdf'); const binaries = [process.env.LORI_SOFFICE, '/Applications/LibreOffice.app/Contents/MacOS/soffice', '/opt/homebrew/bin/soffice', '/usr/local/bin/soffice'].filter(Boolean); await mkdir(work, { recursive: true })
  try { await writeFile(html, exportHtml(record, content)); for (const binary of binaries) if (existsSync(binary)) { const result = await run(binary, ['--headless', '--convert-to', 'pdf:writer_pdf_Export', '--outdir', work, html]).catch(() => ({ code: 1 })); if (result.code === 0 && existsSync(pdf)) return readFile(pdf) }; throw err('на Mac не найден конвертер PDF', 500) } finally { await rm(work, { recursive: true, force: true }).catch(() => {}) }
}
function filenameFor(record, extension) { const slug = safeName(record.title, 'record').replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 42) || 'record'; return `lori-${record.created.replace(/-/g, '')}-${slug}.${extension}` }
async function purgeExpired() {
  const library = await getLibrary(); const now = Date.now(); let changed = false
  for (const record of Object.values(library.records)) if (record?.media?.expiresAt && new Date(record.media.expiresAt).getTime() <= now && record.media.path) { await rm(insideLibrary(record.media.path), { force: true }).catch(() => {}); record.media.deletedAt = new Date().toISOString(); delete record.media.path; changed = true }
  for (const [id, deleted] of Object.entries(library.trash)) if (new Date(deleted.deletedAt).getTime() + RETENTION_MS <= now) { if (deleted.path) await rm(insideLibrary(deleted.path), { force: true }).catch(() => {}); delete library.trash[id]; delete library.records[id]; changed = true }
  if (changed) await saveLibrary(library)
}
// Плееры Safari присылают и суффиксные диапазоны (`bytes=-500`), и заведомо неверные.
// Раньше `bytes=100-50` давал отрицательный content-length и валил весь сервер.
function parseRange(header, size) {
  if (!header) return null
  const match = /^bytes=(\d*)-(\d*)$/.exec(String(header).trim())
  if (!match || (!match[1] && !match[2])) return 'invalid'
  let start; let end
  if (!match[1]) { const length = Number(match[2]); if (!length) return 'invalid'; start = Math.max(0, size - length); end = size - 1 }
  else { start = Number(match[1]); end = match[2] ? Number(match[2]) : size - 1 }
  if (!Number.isFinite(start) || !Number.isFinite(end) || start > end || start >= size) return 'invalid'
  return { start, end: Math.min(end, size - 1) }
}
async function serveStatic(pathname, response) { const file = resolve(WEB_DIR, '.' + normalize(pathname === '/' ? '/index.html' : pathname)); if (!file.startsWith(WEB_DIR + '/') && file !== WEB_DIR) { response.writeHead(403).end('forbidden'); return }; try { const info = await stat(file); if (!info.isFile()) throw new Error(); response.writeHead(200, { 'content-type': MIME[extname(file).toLowerCase()] ?? 'application/octet-stream', 'content-length': info.size, 'cache-control': 'no-cache' }); createReadStream(file).pipe(response) } catch { response.writeHead(404).end('not found') } }
function serveEvents(request, response) { response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' }); const last = Number(request.headers['last-event-id'] ?? 0); for (const event of eventLog.filter((event) => event.id > last)) response.write(`id: ${event.id}\nevent: ${event.type}\ndata: ${JSON.stringify(event.data)}\n\n`); response.write(': connected\n\n'); sseClients.add(response); const timer = setInterval(() => response.write(': ping\n\n'), 25000); request.on('close', () => { clearInterval(timer); sseClients.delete(response) }) }

const server = createServer(async (request, response) => {
  let url
  try { url = new URL(request.url, `http://${request.headers.host ?? '127.0.0.1'}`) } catch { reply(response, 400, { error: 'некорректный адрес запроса' }); return }
  try {
    if (url.pathname === '/api/auth/status' && request.method === 'GET') return reply(response, 200, { passwordConfigured: Boolean(passwordConfig) })
    if (url.pathname === '/api/auth/setup' && request.method === 'POST') {
      if (passwordConfig || passwordSetupInProgress) throw err('пароль уже настроен', 409)
      await setPassword((await readJson(request)).password)
      response.writeHead(204, { 'set-cookie': secureCookie(request, 60 * 60 * 24 * 30), 'cache-control': 'no-store' }).end(); return
    }
    if (url.pathname === '/api/auth/login' && request.method === 'POST') {
      if (!passwordConfig) throw err('сначала задай пароль', 409)
      if (loginBlocked(request)) throw err('слишком много попыток. Подожди минуту и попробуй снова.', 429)
      if (!await matchesPassword((await readJson(request)).password)) { recordLoginFailure(request); throw err('неверный пароль', 401) }
      clearLoginFailures(request); response.writeHead(204, { 'set-cookie': secureCookie(request, 60 * 60 * 24 * 30), 'cache-control': 'no-store' }).end(); return
    }
    const verdict = auth(request)
    if (url.pathname === '/login' && request.method === 'GET') {
      if (verdict !== 'deny') { response.writeHead(303, { location: '/' }).end(); return }
      await serveStatic('/login.html', response); return
    }
    if (['/login.css', '/login.js', '/icon.svg'].includes(url.pathname) && request.method === 'GET') { await serveStatic(url.pathname, response); return }
    if (verdict === 'deny') {
      if (url.pathname.startsWith('/api/')) return reply(response, 401, { error: 'войдите с паролем' })
      response.writeHead(303, { location: '/login', 'cache-control': 'no-store' }).end(); return
    }
    if (url.pathname === '/api/auth/logout' && request.method === 'POST') { response.writeHead(204, { 'set-cookie': `${COOKIE}=; HttpOnly; Path=/; Max-Age=0; SameSite=Strict`, 'cache-control': 'no-store' }).end(); return }
    if (url.pathname === '/api/events' && request.method === 'GET') return serveEvents(request, response)
    if (url.pathname === '/api/library' && request.method === 'GET') { const library = await getLibrary(); return reply(response, 200, { folders: library.folders, records: await listRecords(library) }) }
    if (url.pathname === '/api/records' && request.method === 'GET') { const library = await getLibrary(); return reply(response, 200, { records: await listRecords(library) }) }
    if (url.pathname === '/api/record' && request.method === 'GET') { const library = await getLibrary(); return reply(response, 200, { record: await getRecord(url.searchParams.get('id'), library) }) }
    if (url.pathname === '/api/jobs' && request.method === 'POST') { const job = await enqueueUpload(request); return reply(response, 202, { jobId: job.id, job: publicJob(job) }) }
    const jobRoute = url.pathname.match(/^\/api\/jobs\/([0-9a-f-]+)(?:\/(retry|cancel))?$/i)
    if (jobRoute) {
      const job = await loadJob(jobRoute[1]); if (request.method === 'GET' && !jobRoute[2]) return reply(response, 200, { job: publicJob(job) })
      if (request.method === 'POST' && jobRoute[2] === 'retry') { if (!['failed', 'cancelled'].includes(job.state)) throw err('это задание нельзя повторить сейчас', 409); job.state = 'queued'; job.error = null; if (job.kind === 'summary') summaryLocks.set(job.recordId, job); await saveJob(job); const library = await getLibrary(); if (library.records[job.recordId]) { library.records[job.recordId].status = job.kind === 'summary' ? 'summarizing' : 'queued'; library.records[job.recordId].error = null; await saveLibrary(library) }; broadcast('job', publicJob(job)); pumpQueue().catch((cause) => console.error(`[lori] очередь остановилась: ${cause?.message ?? cause}`)); return reply(response, 202, { job: publicJob(job) }) }
      if (request.method === 'POST' && jobRoute[2] === 'cancel') { if (['ready', 'transcript_ready', 'failed', 'cancelled'].includes(job.state)) throw err('это задание уже нельзя отменить', 409); job.state = 'cancelled'; job.error = null; releaseSummaryLock(job.recordId); await saveJob(job); stopJobChild(job.id); const library = await getLibrary(); if (library.records[job.recordId]) { library.records[job.recordId].status = 'cancelled'; await saveLibrary(library) }; broadcast('job', publicJob(job)); return reply(response, 200, { job: publicJob(job) }) }
    }
    if (url.pathname === '/api/folders' && request.method === 'POST') { const input = await readJson(request); const name = safeName(input.name, ''); if (!name) throw err('назови папку'); const library = await getLibrary(); const folder = { id: randomUUID(), name, description: String(input.description ?? '').trim().slice(0, 280), createdAt: new Date().toISOString() }; library.folders.push(folder); await saveLibrary(library); broadcast('folder', { id: folder.id, action: 'created' }); return reply(response, 201, { folder }) }
    const folderRoute = url.pathname.match(/^\/api\/folders\/([0-9a-f-]+)$/i)
    if (folderRoute && request.method === 'PATCH') { const input = await readJson(request); const library = await getLibrary(); const folder = library.folders.find((item) => item.id === folderRoute[1]); if (!folder) throw err('папка не найдена', 404); if (Object.hasOwn(input, 'name')) folder.name = safeName(input.name, '') || folder.name; if (Object.hasOwn(input, 'description')) folder.description = String(input.description ?? '').trim().slice(0, 280); await saveLibrary(library); return reply(response, 200, { folder }) }
    if (folderRoute && request.method === 'DELETE') { const library = await getLibrary(); const index = library.folders.findIndex((item) => item.id === folderRoute[1]); if (index < 0) throw err('папка не найдена', 404); library.folders.splice(index, 1); for (const record of Object.values(library.records)) if (record?.folderId === folderRoute[1]) record.folderId = null; await saveLibrary(library); broadcast('folder', { id: folderRoute[1], action: 'deleted' }); return reply(response, 200, { ok: true }) }
    if (url.pathname === '/api/folders/assign' && request.method === 'POST') { const input = await readJson(request); return reply(response, 200, { record: await updateRecord(String(input.id), { folderId: input.folderId ?? null }) }) }
    if (url.pathname === '/api/transcripts' && request.method === 'POST') return reply(response, 201, { record: await createTextRecord(await readJson(request)) })
    const recordRoute = url.pathname.match(/^\/api\/records\/([0-9a-f-]+)$/i)
    if (recordRoute && request.method === 'PATCH') return reply(response, 200, { record: await updateRecord(recordRoute[1], await readJson(request)) })
    if (recordRoute && request.method === 'DELETE') {
      const library = await getLibrary(); const record = library.records[recordRoute[1]]
      if (!record || library.trash[record.id]) throw err('запись не найдена', 404)
      let path = null
      if (record.transcriptPath) {
        const trashFile = join(TRASH_DIR, `${record.id}.md`); await mkdir(TRASH_DIR, { recursive: true })
        await copyFile(insideVault(record.transcriptPath), trashFile); path = relative(LIBRARY_DIR, trashFile)
        // Исходник обязан уйти из хранилища: иначе после чистки корзины миграция вернёт «удалённую» запись обратно.
        await rm(insideVault(record.transcriptPath), { force: true }).catch((cause) => console.error(`[lori] исходный файл не удалён: ${cause?.message ?? cause}`))
      }
      library.trash[record.id] = { deletedAt: new Date().toISOString(), path, originalPath: record.transcriptPath ?? null }
      await saveLibrary(library); broadcast('record', { id: record.id, status: 'deleted' })
      return reply(response, 202, { ok: true, restoreUntil: new Date(Date.now() + RETENTION_MS).toISOString() })
    }
    const restoreRoute = url.pathname.match(/^\/api\/records\/([0-9a-f-]+)\/restore$/i)
    if (restoreRoute && request.method === 'POST') {
      const library = await getLibrary(); const id = restoreRoute[1]; const entry = library.trash[id]; const record = library.records[id]
      if (!entry || !record) throw err('в корзине нет такой записи', 404)
      if (entry.path && entry.originalPath) {
        const target = insideVault(entry.originalPath)
        if (!existsSync(target)) { await mkdir(dirname(target), { recursive: true }); await copyFile(insideLibrary(entry.path), target) }
        await rm(insideLibrary(entry.path), { force: true }).catch(() => {})
      }
      delete library.trash[id]; record.updatedAt = new Date().toISOString(); await saveLibrary(library)
      broadcast('record', { id, status: record.status }); return reply(response, 200, { record: await getRecord(id, library) })
    }
    const summaryRoute = url.pathname.match(/^\/api\/records\/([0-9a-f-]+)\/summaries$/i)
    if (summaryRoute && request.method === 'POST') return reply(response, 202, { job: publicJob(await enqueueSummary(summaryRoute[1])) })
    const versionRoute = url.pathname.match(/^\/api\/summaries\/([0-9a-f-]+)(?:\/(activate))?$/i)
    if (versionRoute && request.method === 'PATCH') { const input = await readJson(request); const library = await getLibrary(); const record = Object.values(library.records).find((item) => item?.summaries?.some((summary) => summary.id === versionRoute[1])); if (!record) throw err('версия итога не найдена', 404); const summary = record.summaries.find((item) => item.id === versionRoute[1]); if (!input?.data || typeof input.data !== 'object' || Array.isArray(input.data)) throw err('нет данных итога'); summary.data = { ...summary.data, ...input.data }; summary.editedAt = new Date().toISOString(); await saveLibrary(library); return reply(response, 200, { summary }) }
    if (versionRoute && request.method === 'POST' && versionRoute[2] === 'activate') { const library = await getLibrary(); const record = Object.values(library.records).find((item) => item?.summaries?.some((summary) => summary.id === versionRoute[1])); if (!record) throw err('версия итога не найдена', 404); record.currentSummaryId = versionRoute[1]; record.status = 'ready'; await saveLibrary(library); return reply(response, 200, { ok: true }) }
    if (url.pathname === '/api/export' && request.method === 'GET') { const library = await getLibrary(); const record = await getRecord(url.searchParams.get('id'), library); const content = url.searchParams.get('content') ?? 'summary'; const format = url.searchParams.get('format'); if (!['summary', 'transcript', 'both'].includes(content)) throw err('выбери содержание'); if (content === 'summary' && !record.summary) throw err('итог пока не создан', 409); if (format === 'md') { response.writeHead(200, { 'content-type': 'text/markdown; charset=utf-8', 'content-disposition': `attachment; filename="${filenameFor(record, 'md')}"` }); response.end(exportMarkdown(record, content)); return } if (format === 'pdf') { const pdf = await pdfFor(record, content); response.writeHead(200, { 'content-type': 'application/pdf', 'content-disposition': `attachment; filename="${filenameFor(record, 'pdf')}"` }); response.end(pdf); return } throw err('выбери формат md или pdf') }
    const mediaRoute = url.pathname.match(/^\/api\/records\/([0-9a-f-]+)\/media$/i)
    if (mediaRoute && request.method === 'DELETE') { const library = await getLibrary(); const record = library.records[mediaRoute[1]]; const media = record?.media; if (!record || !media?.path) throw err('исходный файл уже удалён', 404); await rm(insideLibrary(media.path), { force: true }); media.deletedAt = new Date().toISOString(); delete media.path; await saveLibrary(library); broadcast('record', { id: record.id, status: record.status }); return reply(response, 200, { record: await getRecord(record.id, library) }) }
    if (mediaRoute && request.method === 'GET') {
      const library = await getLibrary(); const media = library.records[mediaRoute[1]]?.media
      if (!media?.path || !existsSync(insideLibrary(media.path))) throw err('исходный файл уже удалён', 404)
      const file = insideLibrary(media.path); const info = await stat(file); const type = media.mimeType ?? mediaType(media.name)
      const range = parseRange(request.headers.range, info.size)
      if (range === 'invalid') { response.writeHead(416, { 'content-range': `bytes */${info.size}`, 'accept-ranges': 'bytes' }).end(); return }
      if (!range) { response.writeHead(200, { 'content-type': type, 'content-length': info.size, 'accept-ranges': 'bytes' }); createReadStream(file).pipe(response); return }
      response.writeHead(206, { 'content-type': type, 'content-length': range.end - range.start + 1, 'content-range': `bytes ${range.start}-${range.end}/${info.size}`, 'accept-ranges': 'bytes' })
      createReadStream(file, { start: range.start, end: range.end }).pipe(response); return
    }
    if (url.pathname === '/api/share') { if (request.method === 'POST') { const boundary = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(request.headers['content-type'] ?? ''); if (!boundary) throw err('ожидался файл из «Поделиться»'); const raw = await readRaw(request); const part = raw.toString('binary').split(`--${(boundary[1] ?? boundary[2]).trim()}`).find((chunk) => /filename="/.test(chunk)); const name = headerText(/filename="([^"]*)"/i.exec(part ?? '')?.[1]); const marker = part?.indexOf('\r\n\r\n') ?? -1; const data = marker >= 0 ? Buffer.from(part.slice(marker + 4, -2), 'binary') : null; sharedDrop = data && name ? { name, mimeType: /content-type:\s*([^\r\n]+)/i.exec(part)?.[1] ?? '', data: data.toString('base64') } : null; response.writeHead(303, { location: '/?shared=1' }).end(); return }; if (request.method === 'GET') { const drop = sharedDrop; sharedDrop = null; return reply(response, 200, { drop }) } }
    if (url.pathname === '/api/meta') return reply(response, 200, { name: 'Lori', mode: 'transcripts', aiSummary: OPENAI_API_KEY ? 'configured' : 'not_configured', aiSummaryModel: OPENAI_API_KEY ? OPENAI_MODEL : null })
    await serveStatic(url.pathname, response)
  } catch (cause) {
    const status = cause?.status ?? 500
    if (status >= 500) console.error(`[lori] ${request.method} ${url.pathname}: ${cause?.stack ?? cause}`)
    if (response.headersSent || response.writableEnded) { response.destroy(); return }
    reply(response, status, { error: String(cause?.message ?? cause) })
  }
})
server.on('error', (cause) => { console.error(`[lori] сервер не поднялся: ${cause.message ?? cause}`); process.exit(1) })
async function maintenance() {
  try {
    // iCloud may transiently reject a concurrent read. Keep startup work serial and never let maintenance kill the bridge.
    await recoverQueue()
    await purgeExpired()
  } catch (cause) { console.error(`[lori] фоновое обслуживание отложено: ${cause.message ?? cause}`) }
}
server.listen(PORT, '127.0.0.1', () => { console.error(`[lori] библиотека расшифровок: http://127.0.0.1:${server.address().port}`); void maintenance(); setInterval(() => void maintenance(), 60 * 60 * 1000) })
// Одинокий сбой в фоне не должен ронять мост: launchd поднимет его через 10 секунд,
// а вместе с процессом умрут активная расшифровка и все открытые SSE-подписки.
process.on('unhandledRejection', (cause) => console.error(`[lori] необработанный отказ: ${cause?.stack ?? cause}`))
process.on('uncaughtException', (cause) => console.error(`[lori] необработанное исключение: ${cause?.stack ?? cause}`))
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)))
