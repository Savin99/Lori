const form = document.querySelector('#loginForm')
const title = document.querySelector('#loginTitle')
const copy = document.querySelector('#loginCopy')
const password = document.querySelector('#password')
const confirmationField = document.querySelector('#confirmationField')
const confirmation = document.querySelector('#confirmation')
const submitButton = document.querySelector('#submitButton')
const message = document.querySelector('#loginMessage')
let setup = false

function showMessage(text = '') { message.hidden = !text; message.textContent = text }
function setMode(passwordConfigured) {
  setup = !passwordConfigured
  title.textContent = setup ? 'Защитить Lori' : 'Открыть Lori'
  copy.textContent = setup ? 'Это первый вход. Придумай пароль для своей библиотеки.' : 'Введи пароль, чтобы открыть свои расшифровки.'
  confirmationField.hidden = !setup
  confirmation.required = setup
  password.autocomplete = setup ? 'new-password' : 'current-password'
  submitButton.textContent = setup ? 'Создать пароль' : 'Войти'
}

try {
  const response = await fetch('/api/auth/status', { cache: 'no-store' })
  if (!response.ok) throw new Error()
  const status = await response.json()
  setMode(status.passwordConfigured)
} catch { showMessage('Не удалось открыть вход. Проверь соединение и обнови страницу.') }

form.addEventListener('submit', async (event) => {
  event.preventDefault(); showMessage()
  const value = password.value
  if (value.length < 8) return showMessage('Пароль должен быть не короче 8 символов.')
  if (setup && value !== confirmation.value) return showMessage('Пароли не совпадают.')
  submitButton.disabled = true
  try {
    const response = await fetch(setup ? '/api/auth/setup' : '/api/auth/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ password: value }) })
    if (!response.ok) {
      const body = await response.json().catch(() => ({}))
      throw new Error(body.error || 'Не удалось выполнить вход. Повтори попытку.')
    }
    window.location.replace('/')
  } catch (cause) { showMessage(cause.message) } finally { submitButton.disabled = false }
})
