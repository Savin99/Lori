#!/usr/bin/env node
// Прокси к API моделей через этот компьютер.
//
// Зачем: Google отвечает «User location is not supported for the API use» по региону
// запроса. С компьютера владельца ключи работают, с телефона — нет, и вместо возни с
// профилями VPN на iPhone проще пустить запросы приложения через машину, где всё уже
// работает. Ключ через прокси не хранится и не подставляется: его присылает клиент.
//
//   node ui/api-proxy.mjs                       # Gemini на :8788
//   LORI_PROXY_TARGET=api.openai.com LORI_PROXY_PORT=8789 node ui/api-proxy.mjs
//
// В приложении: Настройки → Google Gemini API → «Адрес API» → http://<ip-компьютера>:8788
//
// Слушает только локальную сеть. Наружу его выставлять не надо: это открытый ретранслятор
// к API, пусть и без ключа внутри.

import { createServer } from 'node:http'
import { networkInterfaces } from 'node:os'

const TARGET = process.env.LORI_PROXY_TARGET ?? 'generativelanguage.googleapis.com'
// Схема отдельной переменной ради тестов: подставной «Google» поднимается по http.
const SCHEME = process.env.LORI_PROXY_SCHEME ?? 'https'
const PORT = Number(process.env.LORI_PROXY_PORT ?? 8788)
const HOST = process.env.LORI_PROXY_HOST ?? '0.0.0.0'
// Пропускаем только пути самих API: v1beta — Gemini и его Files API, v1 — OpenAI.
const ALLOWED = [/^\/v1beta\//, /^\/upload\/v1beta\//, /^\/v1\//]
const MAX_BODY = 64 * 1024 * 1024

// Заголовки соединения не пересылаются: их значения относятся к нашему каналу, а не к целевому.
const SKIP_REQUEST = new Set(['host', 'connection', 'content-length', 'accept-encoding', 'transfer-encoding'])
const SKIP_RESPONSE = new Set(['connection', 'content-length', 'content-encoding', 'transfer-encoding'])

async function readBody (request) {
  const chunks = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > MAX_BODY) throw new Error(`тело запроса больше ${MAX_BODY} байт`)
    chunks.push(chunk)
  }
  return chunks.length ? Buffer.concat(chunks) : undefined
}

function localAddresses () {
  return Object.values(networkInterfaces())
    .flat()
    .filter((item) => item && item.family === 'IPv4' && !item.internal)
    .map((item) => item.address)
}

const server = createServer(async (request, response) => {
  const started = Date.now()
  const path = request.url ?? '/'
  if (!ALLOWED.some((pattern) => pattern.test(path))) {
    response.writeHead(404, { 'content-type': 'application/json; charset=utf-8' })
    response.end(JSON.stringify({ error: { message: `прокси не обслуживает путь ${path}` } }))
    return
  }

  try {
    const body = await readBody(request)
    const headers = {}
    for (const [name, value] of Object.entries(request.headers)) {
      if (!SKIP_REQUEST.has(name) && typeof value === 'string') headers[name] = value
    }

    const target = await fetch(`${SCHEME}://${TARGET}${path}`, {
      method: request.method,
      headers,
      body,
      redirect: 'follow'
    })

    const own = `http://${request.headers.host ?? `${localAddresses()[0]}:${PORT}`}`
    for (const [name, value] of target.headers) {
      if (SKIP_RESPONSE.has(name)) continue
      // Адрес возобновляемой загрузки Google отдаёт на своём хосте — по нему телефон
      // снова упрётся в тот же отказ по региону, поэтому подменяем на себя.
      response.setHeader(name, name === 'x-goog-upload-url' ? value.replace(`${SCHEME}://${TARGET}`, own) : value)
    }

    const payload = Buffer.from(await target.arrayBuffer())
    response.writeHead(target.status)
    response.end(payload)
    console.log(`[proxy] ${request.method} ${path} → ${target.status}, ${payload.length} Б, ${Date.now() - started} мс`)
  } catch (cause) {
    console.error(`[proxy] ${request.method} ${path}: ${cause?.message ?? cause}`)
    response.writeHead(502, { 'content-type': 'application/json; charset=utf-8' })
    response.end(JSON.stringify({ error: { message: `прокси не смог обратиться к ${TARGET}: ${cause?.message ?? cause}` } }))
  }
})

export { server }

server.listen(PORT, HOST, () => {
  console.log(`[proxy] ${TARGET} доступен на порту ${PORT}`)
  for (const address of localAddresses()) console.log(`[proxy] адрес для приложения: http://${address}:${PORT}`)
})
