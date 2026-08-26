import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { createServer as createHttpServer } from 'node:http'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

const root = new URL('..', import.meta.url).pathname
const token = 'test-token-for-lori-only'

async function freePort() {
  const server = createServer()
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address()
  await new Promise((resolve) => server.close(resolve))
  return port
}

async function waitFor(callback, message) {
  let last
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try { const value = await callback(); if (value) return value; last = value } catch {}
    await new Promise((resolve) => setTimeout(resolve, 75))
  }
  throw new Error(message ?? String(last ?? 'timed out'))
}

test('migrates records, resumes a text job, preserves edits, folders and export', async (t) => {
  const temp = await mkdtemp(join(tmpdir(), 'lori-test-'))
  const vault = join(temp, 'vault')
  const library = join(temp, 'library')
  const tokenFile = join(temp, 'token')
  const passwordFile = join(temp, 'password.json')
  const legacyPath = 'Inbox/Транскрипты/2026-08/2026-08-19 0930 RUDN.md'
  const folderId = '11111111-1111-4111-8111-111111111111'
  const oldId = Buffer.from(legacyPath).toString('base64url')
  const port = await freePort()
  let summaryRequests = 0
  const openai = createHttpServer(async (request, response) => {
    assert.equal(request.method, 'POST')
    assert.equal(request.url, '/v1/responses')
    assert.equal(request.headers.authorization, 'Bearer test-lori-key')
    const chunks = []; for await (const chunk of request) chunks.push(chunk)
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    assert.equal(body.model, 'gpt-5.4-mini')
    assert.equal(body.store, false)
    assert.deepEqual(body.tools, [])
    assert.equal(body.text.format.type, 'json_schema')
    assert.match(body.input, /\[P1\]/)
    summaryRequests += 1
    response.setHeader('content-type', 'application/json')
    if (summaryRequests === 1) return response.end(JSON.stringify({ output_text: 'not valid JSON' }))
    response.end(JSON.stringify({ output_text: JSON.stringify({ brief: 'План на неделю согласован.', keyPoints: [{ text: 'План согласован.', segmentIds: ['P1'] }], decisions: [], tasks: [{ text: 'Подготовить список задач.', segmentIds: ['P1'] }], facts: [], openQuestions: [], uncertainties: [] }), usage: { input_tokens: 123, output_tokens: 45 } }))
  })
  await new Promise((resolve) => openai.listen(0, '127.0.0.1', resolve))
  const openaiPort = openai.address().port
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
  await writeFile(join(vault, legacyPath), '---\ntype: transcript\ncreated: 2026-08-19\n---\n\n# Встреча RUDN\n\n## Расшифровка\n\nОбсудили документы и назначили срок на пятницу.\n')
  await writeFile(join(library, 'library.json'), JSON.stringify({ version: 1, folders: [{ id: folderId, name: 'RUDN', description: '' }], assignments: { [oldId]: folderId } }))
  child = spawn(process.execPath, ['ui/server.mjs'], { cwd: root, env: { ...process.env, OPENAI_API_KEY: 'test-lori-key', LORI_OPENAI_API_BASE_URL: `http://127.0.0.1:${openaiPort}`, LORI_PORT: String(port), LORI_VAULT: vault, LORI_LIBRARY: library, LORI_TOKEN_FILE: tokenFile, LORI_PASSWORD_FILE: passwordFile } })
  const base = `http://127.0.0.1:${port}`
  const request = (path, options = {}) => fetch(base + path, { ...options, headers: { authorization: `Bearer ${token}`, ...(options.headers ?? {}) } })
  const anonymous = (path, options = {}) => fetch(base + path, options)

  await waitFor(async () => (await request('/api/meta')).ok, 'server did not start')
  const loginPage = await anonymous('/login')
  assert.equal(loginPage.status, 200)
  assert.match(await loginPage.text(), /id="loginForm"/)
  const protectedHome = await anonymous('/', { redirect: 'manual' })
  assert.equal(protectedHome.status, 303)
  assert.equal(protectedHome.headers.get('location'), '/login')
  const legacyKeyLink = await anonymous(`/?k=${token}`, { redirect: 'manual' })
  assert.equal(legacyKeyLink.status, 303)
  assert.equal(legacyKeyLink.headers.get('location'), '/login')
  const setup = await anonymous('/api/auth/setup', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ password: 'test-passphrase' }) })
  assert.equal(setup.status, 204)
  const session = setup.headers.get('set-cookie').split(';')[0]
  assert.match(session, /^lori_key=/)
  assert.equal((await anonymous('/api/meta', { headers: { cookie: session } })).status, 200)
  const wrongPassword = await anonymous('/api/auth/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ password: 'not-the-password' }) })
  assert.equal(wrongPassword.status, 401)
  const login = await anonymous('/api/auth/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ password: 'test-passphrase' }) })
  assert.equal(login.status, 204)
  for (let attempt = 0; attempt < 5; attempt += 1) await anonymous('/api/auth/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ password: 'not-the-password' }) })
  const throttled = await anonymous('/api/auth/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ password: 'not-the-password' }) })
  assert.equal(throttled.status, 429)
  const migrated = await (await request('/api/library')).json()
  assert.equal(migrated.records.length, 1)
  assert.equal(migrated.records[0].folderId, folderId)
  assert.match(migrated.records[0].id, /^[0-9a-f-]{36}$/)

  const upload = await request('/api/jobs', { method: 'POST', headers: { 'x-lori-name': encodeURIComponent('meeting.vtt'), 'x-lori-title': encodeURIComponent('Созвон'), 'x-lori-folder': folderId }, body: 'WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nСогласовали план на неделю.\n' })
  assert.equal(upload.status, 202)
  const { job } = await upload.json()
  const completed = await waitFor(async () => {
    const result = await (await request(`/api/jobs/${job.id}`)).json()
    return result.job.state === 'transcript_ready' ? result.job : null
  }, 'text job did not complete')
  assert.equal(completed.state, 'transcript_ready')

  const record = (await (await request(`/api/record?id=${job.recordId}`)).json()).record
  assert.equal(record.status, 'transcript_ready')
  assert.equal(record.segments[0].id, 'S1')
  assert.match(record.transcript, /Согласовали план/)

  const edited = await request(`/api/records/${record.id}`, { method: 'PATCH', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ transcript: 'Исправленный текст расшифровки.' }) })
  assert.equal(edited.status, 200)
  assert.equal((await edited.json()).record.transcript, 'Исправленный текст расшифровки.')

  const summary = await request(`/api/records/${record.id}/summaries`, { method: 'POST' })
  assert.equal(summary.status, 202)
  const summaryJob = (await summary.json()).job
  const summaryFinished = await waitFor(async () => {
    const result = await (await request(`/api/jobs/${summaryJob.id}`)).json()
    return result.job.state === 'ready' ? result.job : null
  }, 'summary job did not complete')
  assert.equal(summaryFinished.state, 'ready')
  assert.equal(summaryRequests, 2, 'invalid structured output is retried once')
  const summarized = (await (await request(`/api/record?id=${record.id}`)).json()).record
  assert.equal(summarized.status, 'ready')
  assert.equal(summarized.summary.data.brief, 'План на неделю согласован.')
  assert.deepEqual(summarized.summary.data.tasks[0].segmentIds, ['P1'])
  const meta = await (await request('/api/meta')).json()
  assert.equal(meta.aiSummary, 'configured')
  assert.equal(meta.aiSummaryModel, 'gpt-5.4-mini')

  const exported = await request(`/api/export?id=${record.id}&content=transcript&format=md`)
  assert.equal(exported.status, 200)
  assert.match(await exported.text(), /Исправленный текст/)

  const deletedFolder = await request(`/api/folders/${folderId}`, { method: 'DELETE' })
  assert.equal(deletedFolder.status, 200)
  const afterFolderDelete = (await (await request(`/api/record?id=${record.id}`)).json()).record
  assert.equal(afterFolderDelete.folderId, null)
})
