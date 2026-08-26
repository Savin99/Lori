const screen = document.getElementById('screen')
const header = document.getElementById('appHeader')
const bottomBar = document.getElementById('bottomBar')
const drawer = document.getElementById('drawer')
const folderList = document.getElementById('folderList')
const overlay = document.getElementById('overlay')
const sheet = document.getElementById('sheet')
const busy = document.getElementById('busy')
const busyTitle = document.getElementById('busyTitle')
const busyText = document.getElementById('busyText')
const toast = document.getElementById('toast')
const mediaPicker = document.getElementById('mediaPicker')
const textPicker = document.getElementById('textPicker')

const state = {
  library: { folders: [], records: [] }, mode: 'home', folderId: null, query: '', record: null,
  overlay: null, folderFilter: '', addFolderId: null, draftTitle: '', draftText: '', upload: null,
  detailTab: 'summary', shareContent: 'summary', activeFolder: null,
}
let toastTimer = null
let toastAction = null
let polling = null
let events = null
let reconnectDelay = 2000
let refreshInFlight = null
let refreshPending = false
let started = false
let submitting = false

const icon = (name, className = '') => `<i class="ti ti-${name}${className ? ` ${className}` : ''}" aria-hidden="true"></i>`
const escapeHtml = (value) => String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#039;')
const text = (value) => escapeHtml(value).replace(/\n/g, '<br>')
const folderFor = (id) => state.library.folders.find((folder) => folder.id === id) ?? null
const bytes = (value) => value < 1024 * 1024 ? `${Math.ceil(value / 1024)} КБ` : `${(value / 1024 / 1024).toFixed(1)} МБ`
const duration = (seconds) => { if (seconds == null) return ''; const value = Math.max(0, Math.round(seconds)); return `${String(Math.floor(value / 60)).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}` }
const plural = (number, one, few, many) => { const ten = number % 10; const hundred = number % 100; return ten === 1 && hundred !== 11 ? one : ten >= 2 && ten <= 4 && !(hundred >= 12 && hundred <= 14) ? few : many }

function formatDay(value) {
  const day = new Date(`${value}T12:00:00`)
  if (Number.isNaN(day.getTime())) return String(value ?? 'Без даты')
  const today = new Date(); const current = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime(); const delta = Math.round((current - day.getTime()) / 86400000)
  if (delta === 0) return 'Сегодня'; if (delta === 1) return 'Вчера'
  return new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long' }).format(day)
}
async function api(path, options = {}) {
  const response = await fetch(path, { ...options, headers: { ...(options.body && !(options.body instanceof Blob) && !(options.body instanceof File) ? { 'content-type': 'application/json' } : {}), ...(options.headers ?? {}) } })
  if (!response.ok) { const data = await response.json().catch(() => ({})); throw Object.assign(new Error(data.error ?? 'Не удалось выполнить действие'), { status: response.status }) }
  return response.json()
}
async function reloadLibrary() { state.library = await api('/api/library') }
async function refreshCurrentRecord() {
  if (!state.record) return
  try { state.record = (await api(`/api/record?id=${encodeURIComponent(state.record.id)}`)).record } catch (cause) {
    if (cause.status !== 404) throw cause
    state.record = null; if (state.mode === 'detail') { state.mode = 'home'; showToast('Запись больше недоступна') }
  }
}
async function refreshFromServer() {
  refreshPending = true
  if (refreshInFlight) return refreshInFlight
  refreshInFlight = (async () => {
    do {
      refreshPending = false
      await reloadLibrary()
      if (state.record) await refreshCurrentRecord()
      render({ preserveOverlay: Boolean(state.overlay) })
    } while (refreshPending)
  })()
  try { return await refreshInFlight } finally { refreshInFlight = null }
}
function showToast(message, action = null) {
  toastAction = action?.run ?? null
  toast.innerHTML = `<span>${escapeHtml(message)}</span>${action ? `<button type="button" class="toast-action" data-action="toast-action">${escapeHtml(action.label)}</button>` : ''}`
  toast.hidden = false; clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toast.hidden = true; toastAction = null }, action ? 8000 : 4200)
}
function setBusy(title, copy) { busyTitle.textContent = title; busyText.textContent = copy; busy.hidden = false }
function clearBusy() { busy.hidden = true }
function reportFailure(cause) {
  // До первой удачной отрисовки показываем экран ошибки, дальше — тост: одна мелкая ошибка не должна гасить приложение.
  if (!started) return showStartupError(cause)
  console.error(cause)
  showToast(cause instanceof Error ? cause.message : 'Что-то пошло не так')
}
function showStartupError(cause) {
  const message = cause instanceof Error ? cause.message : 'Неизвестная ошибка интерфейса'
  header.innerHTML = `<div class="brand">${icon('wave-sine')}<span>Lori</span></div>`
  bottomBar.hidden = true
  screen.innerHTML = `<div class="load-error"><h1>Не получилось открыть библиотеку</h1><p>${escapeHtml(message)}</p><button class="share-button" type="button" onclick="location.reload()">Повторить</button></div>`
}

function statusInfo(record) {
  const map = {
    queued: ['В очереди', 'clock-hour-4', 'status--queued'], transcribing: ['Расшифровываю', 'wave-sine', 'status--active'],
    summarizing: ['Делаю итог', 'sparkles', 'status--active'], transcript_ready: ['Транскрипт готов', 'file-check', 'status--ready'],
    ready: ['Готово', 'circle-check', 'status--ready'], failed: ['Ошибка', 'alert-circle', 'status--failed'], cancelled: ['Отменено', 'ban', 'status--muted'],
  }
  return map[record.status] ?? map.transcript_ready
}
function recordMeta(record) { const pieces = [record.time]; const folder = folderFor(record.folderId); if (folder) pieces.push(folder.name); if (record.duration) pieces.push(record.duration); return pieces.filter(Boolean).join(' · ') }
function recordCard(record) {
  const [label, mark, className] = statusInfo(record); const folder = folderFor(record.folderId)
  return `<button class="record-card" type="button" data-action="open-record" data-id="${escapeHtml(record.id)}"><span class="record-card__mark">${icon(record.status === 'failed' ? 'alert-circle' : 'microphone-2')}</span><span class="record-card__main"><strong>${escapeHtml(record.title)}</strong><span class="record-card__meta">${escapeHtml(recordMeta(record))}</span><span class="record-card__summary">${escapeHtml(record.status === 'failed' ? record.error ?? label : (record.summary?.data?.brief || record.excerpt) || label)}</span><span class="record-status ${className}">${icon(mark)}${label}</span></span><span class="record-card__folder" aria-label="${escapeHtml(folder?.name ?? 'Без папки')}">${icon('folder')}</span></button>`
}
function recordsForCurrentView() {
  const needle = state.query.trim().toLocaleLowerCase('ru-RU')
  return state.library.records.filter((record) => (!state.folderId || record.folderId === state.folderId) && (!needle || [record.title, record.excerpt, record.summary?.data?.brief].join(' ').toLocaleLowerCase('ru-RU').includes(needle)))
}
function renderHome() {
  const records = recordsForCurrentView(); const folder = folderFor(state.folderId); const groups = new Map()
  for (const record of records) { if (!groups.has(record.created)) groups.set(record.created, []); groups.get(record.created).push(record) }
  header.innerHTML = `<button class="icon-button" type="button" data-action="open-drawer" aria-label="Открыть папки">${icon('folders')}</button><div class="brand">${icon('wave-sine')}<span>Lori</span></div><button class="icon-button" type="button" data-action="open-search" aria-label="Искать в записях">${icon('search')}</button>`
  bottomBar.hidden = false
  const list = [...groups.entries()].sort(([left], [right]) => String(right).localeCompare(String(left))).map(([day, recordsForDay]) => `<section class="day-group"><h2>${formatDay(day)}</h2><div class="record-list">${recordsForDay.map(recordCard).join('')}</div></section>`).join('')
  screen.innerHTML = `<section class="home-view"><p class="eyebrow">${state.folderId ? 'Папка' : 'Библиотека'}</p><h1>${escapeHtml(folder?.name ?? 'Мои записи')}</h1>${folder?.description ? `<p class="folder-description">${escapeHtml(folder.description)}</p>` : ''}${list || `<div class="empty-state"><span class="empty-state__icon">${icon('file-description')}</span><h2>${state.query ? 'Ничего не нашлось' : 'Пока нет записей'}</h2><p>${state.query ? 'Попробуй другое слово.' : 'Добавь аудио, видео, файл расшифровки или текстовую заметку.'}</p>${state.query ? '<button class="text-button" data-action="clear-search">Очистить поиск</button>' : ''}</div>`}</section>`
}
function updateSearchResults() {
  const output = document.getElementById('searchOutput'); if (!output) return
  const records = recordsForCurrentView()
  output.innerHTML = `<p class="result-count">${records.length} ${plural(records.length, 'запись', 'записи', 'записей')}</p><div class="search-results">${records.map(recordCard).join('') || '<p class="search-empty">По этому запросу записей нет.</p>'}</div>`
  const clear = document.getElementById('searchClear'); if (clear) clear.hidden = !state.query
}
function renderSearch() {
  // Поле ввода не пересобираем: раньше каждая буква создавала новый input, каретка прыгала в начало,
  // а на телефоне пропадал фокус — «план» превращался в «налп».
  const input = document.getElementById('recordSearch')
  if (input) { if (input.value !== state.query) input.value = state.query; updateSearchResults(); return }
  header.innerHTML = `<button class="icon-button" type="button" data-action="back-home" aria-label="Закрыть поиск">${icon('x')}</button><div class="top-title">Поиск</div><span class="header-spacer"></span>`; bottomBar.hidden = true
  screen.innerHTML = `<section class="search-view"><label class="large-search">${icon('search')}<input id="recordSearch" type="search" value="${escapeHtml(state.query)}" placeholder="Поиск по расшифровкам" autocomplete="off"><button id="searchClear" type="button" data-action="clear-search" aria-label="Очистить" hidden>${icon('x')}</button></label><div id="searchOutput"></div></section>`
  updateSearchResults()
  requestAnimationFrame(() => document.getElementById('recordSearch')?.focus())
}
function summaryView(record) {
  const generating = record.status === 'summarizing'
  if (!record.summary) return `<section class="summary-card summary-card--empty"><div class="summary-card__head"><span>${icon('sparkles')}</span><h2>${generating ? 'Создаю AI-итог' : 'Итог ещё не создан'}</h2></div><p>${generating ? 'В OpenAI отправлен только текст расшифровки. Можно закрыть страницу — Lori сохранит результат.' : 'Расшифровка сохранена локально. По вашей команде Lori отправит в OpenAI только её текст и создаст структурированный итог.'}</p>${generating ? '' : '<button class="text-button" type="button" data-action="create-summary">Создать AI-итог</button><button class="text-button" type="button" data-action="show-ai-info">Что будет в итоге</button>'}</section>`
  const data = record.summary.data; const section = (name, values) => Array.isArray(values) && values.length ? `<section class="summary-section"><h2>${name}</h2><ul>${values.map((value) => `<li>${escapeHtml(typeof value === 'string' ? value : value.text ?? value.title ?? '')}${value.segmentIds?.length ? value.segmentIds.map((segment) => `<button class="segment-link" data-action="show-segment" data-segment="${escapeHtml(segment)}">${escapeHtml(segment)}</button>`).join('') : ''}</li>`).join('')}</ul></section>` : ''
  return `<section class="summary-card"><div class="summary-card__head"><span>${icon('sparkles')}</span><h2>Главное из записи</h2></div><p>${escapeHtml(data.brief ?? '')}</p>${record.summary.stale ? '<p class="summary-stale">Транскрипт изменён — этот итог устарел.</p>' : ''}${generating ? '<p class="summary-stale">Создаю новую версию итога.</p>' : '<button class="text-button" type="button" data-action="create-summary">Создать новую версию</button>'}</section>${section('Ключевые пункты', data.keyPoints)}${section('Решения', data.decisions)}${section('Задачи', data.tasks)}${section('Важные даты и факты', data.facts)}${section('Открытые вопросы', data.openQuestions)}${section('Неуверенные места', data.uncertainties)}`
}
function transcriptView(record) {
  const segments = record.segments ?? []
  if (!segments.length) return `<div class="empty-state empty-state--compact"><span class="empty-state__icon">${icon(record.status === 'failed' ? 'alert-circle' : 'loader-2')}</span><h2>${record.status === 'failed' ? 'Расшифровка не готова' : 'Расшифровка в процессе'}</h2><p>${record.status === 'failed' ? record.error ?? 'Попробуй повторить обработку.' : 'Она появится здесь автоматически — страницу можно закрыть.'}</p></div>`
  return `<section class="transcript-section"><div class="transcript-section__head"><h2>Полная расшифровка</h2><span>${record.wordCount.toLocaleString('ru-RU')} ${plural(record.wordCount, 'слово', 'слова', 'слов')}</span></div><div class="transcript-text">${segments.map((segment) => `<p class="transcript-segment" id="segment-${escapeHtml(segment.id)}">${segment.start != null ? `<button class="timestamp" type="button" data-action="play-segment" data-start="${segment.start}">${duration(segment.start)}</button>` : ''}${segment.speaker ? `<strong>${escapeHtml(segment.speaker)}</strong> ` : ''}${text(segment.text)}</p>`).join('')}</div></section>`
}
function audioView(record) {
  if (!record.media?.available) return `<div class="empty-state empty-state--compact"><span class="empty-state__icon">${icon('clock-off')}</span><h2>Файл уже удалён</h2><p>Исходное медиа хранится локально 30 дней после успешной расшифровки.</p></div>`
  return `<section class="audio-panel"><p>Исходный файл будет удалён ${new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long' }).format(new Date(record.media.expiresAt))}.</p><audio id="recordAudio" controls preload="metadata" src="/api/records/${encodeURIComponent(record.id)}/media"></audio><button class="text-button danger-text" data-action="delete-media">Удалить исходный файл сейчас</button></section>`
}
function renderDetail() {
  const record = state.record; if (!record) { state.mode = 'home'; return render() }
  const folder = folderFor(record.folderId); const tabs = [['summary', 'Итог'], ['transcript', 'Транскрипт'], ...(record.media ? [['audio', 'Аудио']] : [])]
  header.innerHTML = `<button class="icon-button" type="button" data-action="back-home" aria-label="Назад">${icon('chevron-left')}</button><span class="header-spacer"></span><div class="detail-actions"><button class="icon-button" type="button" data-action="open-record-menu" aria-label="Действия">${icon('dots')}</button><button class="share-button" type="button" data-action="open-share">Поделиться</button></div>`; bottomBar.hidden = true
  const content = state.detailTab === 'summary' ? summaryView(record) : state.detailTab === 'transcript' ? transcriptView(record) : audioView(record)
  screen.innerHTML = `<article class="detail-view"><h1>${escapeHtml(record.title)}</h1><div class="detail-meta"><span>${icon('calendar-event')}${escapeHtml(`${formatDay(record.created)} · ${record.time}`)}</span><button type="button" class="detail-folder" data-action="open-assign">${icon('folder')}${escapeHtml(folder?.name ?? 'Без папки')}</button><span class="detail-status ${statusInfo(record)[2]}">${statusInfo(record)[0]}</span></div>${record.error ? `<div class="error-banner">${escapeHtml(record.error)}${record.jobId ? '<button class="text-button" data-action="retry-job">Повторить</button>' : ''}</div>` : ''}<nav class="detail-tabs" aria-label="Содержание записи">${tabs.map(([id, label]) => `<button type="button" class="detail-tab${state.detailTab === id ? ' detail-tab--active' : ''}" data-action="select-tab" data-tab="${id}">${label}</button>`).join('')}</nav><div class="detail-content">${content}</div></article>`
}
function renderFolders() {
  const needle = state.folderFilter.trim().toLocaleLowerCase('ru-RU'); const folders = state.library.folders.filter((folder) => folder.name.toLocaleLowerCase('ru-RU').includes(needle))
  folderList.innerHTML = `<button class="folder-row${!state.folderId ? ' folder-row--active' : ''}" type="button" data-action="select-folder" data-folder=""><span class="folder-row__icon">${icon('inbox')}</span><span>Все записи</span><span class="folder-row__count">${state.library.records.length}</span></button>${folders.map((folder) => `<div class="folder-line"><button class="folder-row${state.folderId === folder.id ? ' folder-row--active' : ''}" type="button" data-action="select-folder" data-folder="${escapeHtml(folder.id)}"><span class="folder-row__icon">${icon('folder')}</span><span>${escapeHtml(folder.name)}</span><span class="folder-row__count">${state.library.records.filter((record) => record.folderId === folder.id).length}</span></button><button class="folder-more" type="button" data-action="edit-folder" data-folder="${escapeHtml(folder.id)}" aria-label="Настроить папку">${icon('dots')}</button></div>`).join('')}${folders.length === 0 && needle ? '<p class="drawer__empty">Таких папок нет.</p>' : ''}`
}
function folderOptions(selected = state.addFolderId) { return `<option value="">Без папки</option>${state.library.folders.map((folder) => `<option value="${escapeHtml(folder.id)}"${folder.id === selected ? ' selected' : ''}>${escapeHtml(folder.name)}</option>`).join('')}` }
function renderOverlay() {
  const type = state.overlay; if (!type) { overlay.hidden = true; sheet.innerHTML = ''; return }; overlay.hidden = false
  if (type === 'add') sheet.innerHTML = `<div class="sheet__grab"></div><div class="sheet__heading"><h2>Добавить запись</h2><button class="sheet-close" data-action="close-overlay" aria-label="Закрыть">${icon('x')}</button></div><p class="sheet__copy">Файлы и расшифровки остаются на твоём Mac. Итог сейчас не отправляется в облако.</p><div class="action-list"><button class="action-row" data-action="pick-media"><span class="action-row__icon">${icon('microphone-2')}</span><span><strong>Аудио или видео</strong><small>Расшифровать локально</small></span>${icon('chevron-right', 'action-row__chevron')}</button><button class="action-row" data-action="pick-text"><span class="action-row__icon">${icon('file-text')}</span><span><strong>Текстовый файл</strong><small>TXT, Markdown, SRT или VTT</small></span>${icon('chevron-right', 'action-row__chevron')}</button><button class="action-row" data-action="open-manual"><span class="action-row__icon">${icon('pencil')}</span><span><strong>Создать вручную</strong><small>Добавить текст расшифровки</small></span>${icon('chevron-right', 'action-row__chevron')}</button></div>`
  else if (type === 'confirm') { const file = state.upload; sheet.innerHTML = `<form id="uploadForm" class="form-sheet"><div class="form-top"><button class="round-back" type="button" data-action="open-add" aria-label="Назад">${icon('chevron-left')}</button><button class="form-submit" type="submit">Поставить в очередь</button></div><h2>Проверим запись</h2><div class="file-preview">${icon(file.kind === 'media' ? 'wave-sine' : 'file-text')}<span><strong>${escapeHtml(file.file.name)}</strong><small>${bytes(file.file.size)}${file.duration ? ` · ${duration(file.duration)}` : ''}</small></span></div><label class="simple-field"><span>Название</span><input name="title" value="${escapeHtml(file.title)}" required maxlength="90"></label><label class="simple-field"><span>Папка</span><span class="select-wrap"><select name="folderId">${folderOptions(state.addFolderId)}</select>${icon('chevron-down')}</span></label>${file.kind === 'media' ? '<label class="check-field"><input name="diarize" type="checkbox"><span>Разделить спикеров <small>Необязательно; по умолчанию выключено.</small></span></label>' : ''}<p class="form-note">После загрузки можно закрыть страницу: очередь продолжит работу локально.</p></form>` }
  else if (type === 'manual') sheet.innerHTML = `<form id="manualForm" class="form-sheet"><div class="form-top"><button class="round-back" type="button" data-action="open-add" aria-label="Назад">${icon('chevron-left')}</button><button class="form-submit" type="submit">Сохранить</button></div><h2>Новая расшифровка</h2><label class="simple-field"><span>Название</span><input name="title" value="${escapeHtml(state.draftTitle)}" placeholder="Например, созвон с командой" required maxlength="90"></label><label class="simple-field"><span>Папка</span><span class="select-wrap"><select name="folderId">${folderOptions()}</select>${icon('chevron-down')}</span></label><label class="textarea-field textarea-field--transcript"><span>Расшифровка</span><textarea name="text" required>${escapeHtml(state.draftText)}</textarea></label></form>`
  else if (type === 'folder') sheet.innerHTML = `<form id="folderForm" class="form-sheet"><div class="form-top"><button class="round-back" type="button" data-action="close-overlay" aria-label="Назад">${icon('chevron-left')}</button><button class="form-submit" type="submit">Создать</button></div><h2>Новая папка</h2><label class="name-field"><span class="name-field__icon">${icon('folder')}</span><input id="folderName" name="name" placeholder="Название папки" required maxlength="90"></label><label class="textarea-field"><span>Описание</span><textarea name="description" maxlength="280"></textarea></label></form>`
  else if (type === 'folder-edit') { const folder = state.activeFolder; sheet.innerHTML = `<form id="folderEditForm" class="form-sheet"><div class="form-top"><button class="round-back" type="button" data-action="close-overlay" aria-label="Назад">${icon('chevron-left')}</button><button class="form-submit" type="submit">Сохранить</button></div><h2>Папка</h2><label class="simple-field"><span>Название</span><input name="name" value="${escapeHtml(folder.name)}" required maxlength="90"></label><label class="textarea-field"><span>Описание</span><textarea name="description" maxlength="280">${escapeHtml(folder.description ?? '')}</textarea></label><button type="button" class="danger-button" data-action="delete-folder">Удалить папку</button><p class="form-note">Записи останутся в библиотеке, просто перейдут в «Без папки».</p></form>` }
  else if (type === 'assign') sheet.innerHTML = `<div class="sheet__grab"></div><div class="sheet__heading"><h2>Переместить в папку</h2><button class="sheet-close" data-action="close-overlay" aria-label="Закрыть">${icon('x')}</button></div><div class="folder-choice-list"><button class="folder-choice${!state.record?.folderId ? ' folder-choice--selected' : ''}" data-action="assign-folder" data-folder="">${icon('inbox')}<span>Без папки</span>${!state.record?.folderId ? icon('check') : ''}</button>${state.library.folders.map((folder) => `<button class="folder-choice${state.record?.folderId === folder.id ? ' folder-choice--selected' : ''}" data-action="assign-folder" data-folder="${escapeHtml(folder.id)}">${icon('folder')}<span>${escapeHtml(folder.name)}</span>${state.record?.folderId === folder.id ? icon('check') : ''}</button>`).join('')}</div>`
  else if (type === 'share') sheet.innerHTML = `<div class="sheet__grab"></div><div class="sheet__heading"><h2>Поделиться записью</h2><button class="sheet-close" data-action="close-overlay" aria-label="Закрыть">${icon('x')}</button></div><p class="sheet__copy">Сначала выбери содержание. По умолчанию — только итог.</p><fieldset class="content-choice"><label><input type="radio" name="content" value="summary"${state.shareContent === 'summary' ? ' checked' : ''}${state.record?.summary ? '' : ' disabled'}> Только итог${state.record?.summary ? '' : ' — пока недоступен'}</label><label><input type="radio" name="content" value="transcript"${state.shareContent === 'transcript' ? ' checked' : ''}> Полный транскрипт</label><label><input type="radio" name="content" value="both"${state.shareContent === 'both' ? ' checked' : ''}${state.record?.summary ? '' : ' disabled'}> Итог + транскрипт</label></fieldset><div class="action-list action-list--tight"><button class="action-row" data-action="export" data-format="pdf"><span class="action-row__icon">${icon('file-type-pdf')}</span><span><strong>PDF</strong><small>Удобно читать и отправлять</small></span>${icon('download', 'action-row__chevron')}</button><button class="action-row" data-action="export" data-format="md"><span class="action-row__icon">${icon('markdown')}</span><span><strong>Markdown (.md)</strong><small>Текст для дальнейшей работы</small></span>${icon('download', 'action-row__chevron')}</button></div>`
  else if (type === 'record-menu') sheet.innerHTML = `<div class="sheet__grab"></div><div class="sheet__heading"><h2>Запись</h2><button class="sheet-close" data-action="close-overlay" aria-label="Закрыть">${icon('x')}</button></div><div class="action-list"><button class="action-row" data-action="open-edit"><span class="action-row__icon">${icon('pencil')}</span><span><strong>Редактировать</strong><small>Название и текст</small></span>${icon('chevron-right', 'action-row__chevron')}</button>${state.record?.jobId && ['queued', 'transcribing'].includes(state.record.status) ? `<button class="action-row" data-action="cancel-job"><span class="action-row__icon">${icon('ban')}</span><span><strong>Отменить обработку</strong><small>Файл останется в очереди отменённых</small></span>${icon('chevron-right', 'action-row__chevron')}</button>` : ''}<button class="action-row action-row--danger" data-action="delete-record"><span class="action-row__icon">${icon('trash')}</span><span><strong>Удалить запись</strong><small>Можно восстановить 30 дней</small></span>${icon('chevron-right', 'action-row__chevron')}</button></div>`
  else if (type === 'edit') sheet.innerHTML = `<form id="editRecordForm" class="form-sheet"><div class="form-top"><button class="round-back" type="button" data-action="open-record-menu" aria-label="Назад">${icon('chevron-left')}</button><button class="form-submit" type="submit">Сохранить</button></div><h2>Редактировать</h2><label class="simple-field"><span>Название</span><input name="title" value="${escapeHtml(state.record.title)}" required maxlength="90"></label><label class="textarea-field textarea-field--transcript"><span>Расшифровка</span><textarea name="transcript" required>${escapeHtml(state.record.transcript)}</textarea></label><p class="form-note">Исходный Markdown остаётся неизменным. Правка создаёт отдельную версию и помечает итог устаревшим.</p></form>`
  else if (type === 'ai-info') sheet.innerHTML = `<div class="sheet__grab"></div><div class="sheet__heading"><h2>Что будет в AI-итоге</h2><button class="sheet-close" data-action="close-overlay" aria-label="Закрыть">${icon('x')}</button></div><p class="sheet__copy">Краткий вывод, ключевые пункты, решения, задачи, факты, открытые вопросы и неуверенные места — со ссылками на сегменты транскрипта. В облако пойдёт только текст расшифровки, не исходное медиа.</p><p class="form-note">Подключение OpenAI и первый платный запуск выполняются только после отдельного подтверждения.</p>`
  requestAnimationFrame(() => sheet.querySelector('input, textarea, button')?.focus())
}
function openOverlay(type) { state.overlay = type; renderOverlay() }
function closeOverlay() { state.overlay = null; renderOverlay() }
function render({ preserveOverlay = false } = {}) {
  if (state.mode === 'search') renderSearch(); else if (state.mode === 'detail') renderDetail(); else renderHome()
  renderFolders()
  if (!preserveOverlay) renderOverlay()
}

async function openRecord(id) { setBusy('Открываю запись', 'Собираю расшифровку.'); try { state.record = (await api(`/api/record?id=${encodeURIComponent(id)}`)).record; state.detailTab = state.record.summary ? 'summary' : 'transcript'; state.mode = 'detail'; state.query = ''; closeOverlay(); render() } catch (cause) { showToast(cause.message) } finally { clearBusy() } }
async function createFolder(form) { setBusy('Создаю папку', 'Почти готово.'); try { const data = await api('/api/folders', { method: 'POST', body: JSON.stringify({ name: form.elements.name.value, description: form.elements.description.value }) }); await reloadLibrary(); state.folderId = data.folder.id; closeOverlay(); render(); showToast('Папка создана') } catch (cause) { showToast(cause.message) } finally { clearBusy() } }
async function saveFolder(form) { setBusy('Сохраняю папку', ''); try { await api(`/api/folders/${state.activeFolder.id}`, { method: 'PATCH', body: JSON.stringify({ name: form.elements.name.value, description: form.elements.description.value }) }); await reloadLibrary(); closeOverlay(); render(); showToast('Папка обновлена') } catch (cause) { showToast(cause.message) } finally { clearBusy() } }
async function createManual(form) { setBusy('Сохраняю расшифровку', 'Запись останется в локальной библиотеке.'); try { const data = await api('/api/transcripts', { method: 'POST', body: JSON.stringify({ title: form.elements.title.value, text: form.elements.text.value, folderId: form.elements.folderId.value || null }) }); await reloadLibrary(); state.record = data.record; state.mode = 'detail'; state.detailTab = 'transcript'; state.draftTitle = ''; state.draftText = ''; closeOverlay(); render(); showToast('Расшифровка сохранена') } catch (cause) { showToast(cause.message) } finally { clearBusy() } }
async function uploadFile(form) {
  const file = state.upload?.file; if (!file) return
  setBusy('Загружаю файл', 'Запись появится в очереди сразу после загрузки.')
  try { const response = await fetch('/api/jobs', { method: 'POST', headers: { 'x-lori-name': encodeURIComponent(file.name), 'x-lori-title': encodeURIComponent(form.elements.title.value), 'x-lori-folder': form.elements.folderId.value || '', 'x-lori-diarize': String(Boolean(form.elements.diarize?.checked)) }, body: file }); if (!response.ok) { const data = await response.json().catch(() => ({})); throw new Error(data.error ?? 'Не удалось загрузить файл') }; const data = await response.json(); await reloadLibrary(); const record = state.library.records.find((item) => item.id === data.job.recordId); state.record = record ? (await api(`/api/record?id=${encodeURIComponent(record.id)}`)).record : null; state.mode = state.record ? 'detail' : 'home'; state.detailTab = 'transcript'; state.upload = null; closeOverlay(); render(); showToast('Файл в очереди — можно закрыть страницу') } catch (cause) { showToast(cause.message) } finally { clearBusy() } }
async function assignFolder(folderId) { if (!state.record) return; setBusy('Перемещаю запись', ''); try { state.record = (await api(`/api/records/${state.record.id}`, { method: 'PATCH', body: JSON.stringify({ folderId: folderId || null }) })).record; await reloadLibrary(); closeOverlay(); render(); showToast('Папка обновлена') } catch (cause) { showToast(cause.message) } finally { clearBusy() } }
async function saveEdit(form) { if (!state.record) return; setBusy('Сохраняю правку', 'Итог будет отмечен устаревшим.'); try { state.record = (await api(`/api/records/${state.record.id}`, { method: 'PATCH', body: JSON.stringify({ title: form.elements.title.value, transcript: form.elements.transcript.value }) })).record; await reloadLibrary(); closeOverlay(); render(); showToast('Правка сохранена') } catch (cause) { showToast(cause.message) } finally { clearBusy() } }
async function createSummary() { if (!state.record || state.record.status === 'summarizing') return; if (!confirm('Создать AI-итог? В OpenAI уйдёт только текст расшифровки. Это платный запрос.')) return; setBusy('Создаю AI-итог', 'В облако отправляю только текст расшифровки.'); try { await api(`/api/records/${state.record.id}/summaries`, { method: 'POST' }); await reloadLibrary(); await refreshCurrentRecord(); render(); showToast('AI-итог добавлен в очередь') } catch (cause) { showToast(cause.message) } finally { clearBusy() } }
async function exportRecord(format) { if (!state.record) return; const content = state.shareContent; setBusy(`Готовлю ${format === 'pdf' ? 'PDF' : 'Markdown'}`, 'Собираю запись для отправки.'); try { const response = await fetch(`/api/export?id=${encodeURIComponent(state.record.id)}&content=${content}&format=${format}`); if (!response.ok) { const data = await response.json().catch(() => ({})); throw new Error(data.error ?? 'Не удалось подготовить файл') }; const blob = await response.blob(); const file = new File([blob], `Lori - ${state.record.title}.${format}`, { type: blob.type }); if (navigator.canShare && navigator.canShare({ files: [file] })) await navigator.share({ files: [file], title: state.record.title }); else { const link = document.createElement('a'); link.href = URL.createObjectURL(blob); link.download = file.name; document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(link.href), 2000); showToast('Файл скачан') }; closeOverlay() } catch (cause) { if (cause.name !== 'AbortError') showToast(cause.message) } finally { clearBusy() } }
async function retryJob() { if (!state.record?.jobId) return; try { await api(`/api/jobs/${state.record.jobId}/retry`, { method: 'POST' }); await reloadLibrary(); await refreshCurrentRecord(); render(); showToast('Задание снова в очереди') } catch (cause) { showToast(cause.message) } }
async function cancelJob() { if (!state.record?.jobId) return; try { await api(`/api/jobs/${state.record.jobId}/cancel`, { method: 'POST' }); await reloadLibrary(); await refreshCurrentRecord(); closeOverlay(); render(); showToast('Обработка отменена') } catch (cause) { showToast(cause.message) } }
async function deleteRecord() {
  if (!state.record || !confirm('Переместить запись в корзину Lori на 30 дней?')) return
  const id = state.record.id
  try { await api(`/api/records/${id}`, { method: 'DELETE' }); await reloadLibrary(); state.record = null; state.mode = 'home'; closeOverlay(); render(); showToast('Запись перемещена в корзину', { label: 'Отменить', run: () => restoreRecord(id) }) } catch (cause) { showToast(cause.message) }
}
async function restoreRecord(id) {
  setBusy('Возвращаю запись', '')
  try { const data = await api(`/api/records/${id}/restore`, { method: 'POST' }); await reloadLibrary(); state.record = data.record; state.mode = 'detail'; state.detailTab = data.record.summary ? 'summary' : 'transcript'; render(); showToast('Запись восстановлена') } catch (cause) { showToast(cause.message) } finally { clearBusy() }
}
async function deleteMedia() { if (!state.record || !confirm('Удалить исходный файл сейчас? Расшифровка и итог останутся.')) return; try { state.record = (await api(`/api/records/${state.record.id}/media`, { method: 'DELETE' })).record; await reloadLibrary(); state.detailTab = 'transcript'; render(); showToast('Исходный файл удалён') } catch (cause) { showToast(cause.message) } }
async function deleteFolder() { if (!state.activeFolder || !confirm('Удалить папку? Записи останутся в библиотеке.')) return; try { await api(`/api/folders/${state.activeFolder.id}`, { method: 'DELETE' }); await reloadLibrary(); if (state.folderId === state.activeFolder.id) state.folderId = null; closeOverlay(); render(); showToast('Папка удалена') } catch (cause) { showToast(cause.message) } }
function playSegment(start) {
  if (!Number.isFinite(Number(start))) return
  const audio = document.getElementById('recordAudio')
  if (audio) { audio.currentTime = Number(start); audio.play().catch(() => {}); return }
  if (!state.record?.media?.available) { showToast('Исходный файл недоступен — играть нечего'); return }
  state.detailTab = 'audio'; render()
  requestAnimationFrame(() => { const player = document.getElementById('recordAudio'); if (player) { player.currentTime = Number(start); player.play().catch(() => {}) } })
}
function chooseFile(file, kind) { if (!file) return; state.upload = { file, kind, title: file.name.replace(/\.(m4a|mp3|wav|aac|caf|aif|aiff|ogg|opus|webm|amr|flac|mp4|mov|mkv|avi|mpeg|mpg|txt|md|markdown|srt|vtt)$/i, '').replace(/[-_]/g, ' '), duration: null }; state.addFolderId = state.folderId; if (kind === 'media') { const probe = document.createElement('audio'); probe.preload = 'metadata'; probe.onloadedmetadata = () => { if (state.upload?.file === file) { state.upload.duration = probe.duration; renderOverlay() }; URL.revokeObjectURL(probe.src) }; probe.src = URL.createObjectURL(file) }; openOverlay('confirm') }
async function importText(file) { if (!file) return; try { state.draftTitle = file.name.replace(/\.(md|markdown|txt|vtt|srt)$/i, '').replace(/[-_]/g, ' '); state.draftText = await file.text(); state.addFolderId = state.folderId; openOverlay('manual') } catch { showToast('Не удалось прочитать файл') } }
async function claimShared() { if (!new URLSearchParams(location.search).has('shared')) return; try { const drop = (await api('/api/share')).drop; if (drop?.data) { const array = Uint8Array.from(atob(drop.data), (letter) => letter.charCodeAt(0)); const file = new File([array], drop.name ?? 'вложение', { type: drop.mimeType ?? '' }); if (/\.(txt|md|markdown|srt|vtt)$/i.test(file.name)) await importText(file); else chooseFile(file, 'media') }; history.replaceState({}, '', location.pathname) } catch (cause) { showToast(cause.message) } }
function startPolling() {
  if (polling) return
  polling = setInterval(() => refreshFromServer().catch(() => {}), 12000)
}
function stopPolling() { if (polling) { clearInterval(polling); polling = null } }
function subscribe() {
  try {
    events = new EventSource('/api/events')
    const refresh = () => refreshFromServer().catch(() => {})
    // The bridge emits named SSE events; `onmessage` only receives unnamed ones.
    for (const type of ['job', 'record', 'folder']) events.addEventListener(type, refresh)
    events.onmessage = refresh
    events.onopen = () => { stopPolling(); reconnectDelay = 2000; refresh() }
    events.onerror = () => {
      // Пока связи нет, живём на опросе, но продолжаем возвращаться к событиям с растущей паузой.
      events?.close(); events = null; startPolling()
      setTimeout(() => { if (!events) subscribe() }, reconnectDelay)
      reconnectDelay = Math.min(reconnectDelay * 2, 60_000)
    }
  } catch { startPolling() }
}

document.addEventListener('click', async (event) => {
  const target = event.target.closest('[data-action]'); if (!target) return; const action = target.dataset.action
  if (action === 'toast-action') { const run = toastAction; toastAction = null; toast.hidden = true; if (run) return run(); return }
  if (action === 'open-drawer') { drawer.hidden = false; return } if (action === 'close-drawer') { drawer.hidden = true; return }
  if (action === 'select-folder') { state.folderId = target.dataset.folder || null; state.mode = 'home'; state.query = ''; drawer.hidden = true; render(); return }
  if (action === 'open-search') { state.mode = 'search'; render(); return } if (action === 'back-home') { state.mode = 'home'; state.query = ''; render(); return } if (action === 'clear-search') { state.query = ''; render(); return }
  if (action === 'open-record') return openRecord(target.dataset.id)
  if (action === 'open-add') { state.addFolderId = state.folderId; return openOverlay('add') } if (action === 'close-overlay') return closeOverlay()
  if (action === 'open-folder-form') { drawer.hidden = true; return openOverlay('folder') } if (action === 'edit-folder') { state.activeFolder = folderFor(target.dataset.folder); drawer.hidden = true; return openOverlay('folder-edit') }
  if (action === 'pick-media') return mediaPicker.click(); if (action === 'pick-text') return textPicker.click(); if (action === 'open-manual') return openOverlay('manual')
  if (action === 'open-assign') return openOverlay('assign'); if (action === 'assign-folder') return assignFolder(target.dataset.folder || null)
  if (action === 'open-share') return openOverlay('share'); if (action === 'export') return exportRecord(target.dataset.format)
  if (action === 'open-record-menu') return openOverlay('record-menu'); if (action === 'open-edit') return openOverlay('edit'); if (action === 'delete-record') return deleteRecord(); if (action === 'delete-folder') return deleteFolder()
  if (action === 'retry-job') return retryJob(); if (action === 'cancel-job') return cancelJob(); if (action === 'select-tab') { state.detailTab = target.dataset.tab; render(); return }
  if (action === 'show-ai-info') return openOverlay('ai-info'); if (action === 'create-summary') return createSummary(); if (action === 'delete-media') return deleteMedia(); if (action === 'play-segment') return playSegment(target.dataset.start); if (action === 'show-segment') { state.detailTab = 'transcript'; render(); requestAnimationFrame(() => document.getElementById(`segment-${target.dataset.segment}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' })) }
})
document.addEventListener('input', (event) => { if (event.target.id === 'recordSearch') { state.query = event.target.value; updateSearchResults() } if (event.target.id === 'folderSearch') { state.folderFilter = event.target.value; renderFolders() } })
document.addEventListener('change', (event) => { if (event.target.name === 'content') state.shareContent = event.target.value })
document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && state.overlay) closeOverlay() })
const formHandlers = { folderForm: createFolder, folderEditForm: saveFolder, manualForm: createManual, uploadForm: uploadFile, editRecordForm: saveEdit }
document.addEventListener('submit', async (event) => {
  const handler = formHandlers[event.target.id]; if (!handler) return
  event.preventDefault()
  if (submitting) return
  submitting = true
  const button = event.target.querySelector('.form-submit'); if (button) button.disabled = true
  try { await handler(event.target) } finally { submitting = false; if (button?.isConnected) button.disabled = false }
})
mediaPicker.addEventListener('change', () => { const file = mediaPicker.files[0]; mediaPicker.value = ''; chooseFile(file, 'media') })
textPicker.addEventListener('change', () => { const file = textPicker.files[0]; textPicker.value = ''; importText(file) })
window.addEventListener('error', (event) => reportFailure(event.error ?? new Error(event.message)))
window.addEventListener('unhandledrejection', (event) => reportFailure(event.reason))
async function start() { try { await reloadLibrary(); render(); started = true; subscribe(); await claimShared() } catch (cause) { showStartupError(cause) } }
start()
