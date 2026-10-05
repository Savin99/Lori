import { after, before, test } from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { once } from 'node:events'

// Ждать готовности через `for await ... break` нельзя: разрыв итератора закрывает
// stdout процесса, и прокси умирает на EPIPE при первой же записи в журнал —
// тест падал не на прокси, а на самом себе.
function start (env) {
  const child = spawn(process.execPath, ['ui/api-proxy.mjs'], {
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'inherit']
  })
  const ready = new Promise((resolve) => {
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk) => {
      if (chunk.includes('доступен на порту')) resolve()
    })
  })
  return { child, ready }
}

// Прокси проверяется против подставного «Google» на локальном порту: настоящий
// сервис в тестах не нужен, а важно другое — что пропускается, что подменяется
// и что происходит, когда цель недоступна.
const FAKE_PORT = 8991
const PROXY_PORT = 8992
let fake
let proxy
const seen = []

before(async () => {
  fake = createServer(async (request, response) => {
    const chunks = []
    for await (const chunk of request) chunks.push(chunk)
    seen.push({
      path: request.url,
      key: request.headers['x-goog-api-key'] ?? null,
      body: Buffer.concat(chunks).toString('utf8')
    })
    if (request.url.startsWith('/upload/v1beta/files')) {
      response.writeHead(200, {
        'content-type': 'application/json',
        'x-goog-upload-url': `http://127.0.0.1:${FAKE_PORT}/upload/v1beta/files?id=7`
      })
      response.end('{}')
      return
    }
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ models: [{ name: 'models/gemini-3.1-flash-lite' }] }))
  })
  fake.listen(FAKE_PORT)
  await once(fake, 'listening')

  const started = start({
    LORI_PROXY_TARGET: `127.0.0.1:${FAKE_PORT}`,
    LORI_PROXY_SCHEME: 'http',
    LORI_PROXY_PORT: String(PROXY_PORT),
    LORI_PROXY_HOST: '127.0.0.1'
  })
  proxy = started.child
  await started.ready
})

after(() => {
  proxy?.kill()
  fake?.close()
})

test('запрос и ключ доходят до сервиса без изменений', async () => {
  const response = await fetch(`http://127.0.0.1:${PROXY_PORT}/v1beta/models?pageSize=200`, {
    headers: { 'x-goog-api-key': 'test-key-123' }
  })
  assert.equal(response.status, 200)
  const body = await response.json()
  assert.equal(body.models[0].name, 'models/gemini-3.1-flash-lite')

  const last = seen.at(-1)
  assert.equal(last.path, '/v1beta/models?pageSize=200')
  assert.equal(last.key, 'test-key-123', 'ключ присылает клиент, прокси его не подменяет')
})

test('адрес возобновляемой загрузки подменяется на сам прокси', async () => {
  const response = await fetch(`http://127.0.0.1:${PROXY_PORT}/upload/v1beta/files`, {
    method: 'POST',
    headers: { 'x-goog-upload-command': 'start', 'content-type': 'application/json' },
    body: '{"file":{"display_name":"часть"}}'
  })
  assert.equal(response.status, 200)
  const address = response.headers.get('x-goog-upload-url')
  assert.match(address, new RegExp(`^http://127.0.0.1:${PROXY_PORT}/upload/v1beta/files`))
  assert.equal(seen.at(-1).body, '{"file":{"display_name":"часть"}}', 'тело запроса пересылается как есть')
})

test('посторонние пути не пересылаются', async () => {
  const response = await fetch(`http://127.0.0.1:${PROXY_PORT}/etc/passwd`)
  assert.equal(response.status, 404)
  const body = await response.json()
  assert.match(body.error.message, /не обслуживает путь/)
})

test('недоступная цель — это внятная ошибка, а не обрыв', async () => {
  const dead = start({
    LORI_PROXY_TARGET: '127.0.0.1:9',
    LORI_PROXY_SCHEME: 'http',
    LORI_PROXY_PORT: '8993',
    LORI_PROXY_HOST: '127.0.0.1'
  })
  await dead.ready
  const response = await fetch('http://127.0.0.1:8993/v1beta/models')
  assert.equal(response.status, 502)
  const body = await response.json()
  assert.match(body.error.message, /прокси не смог обратиться/)
  dead.child.kill()
})
