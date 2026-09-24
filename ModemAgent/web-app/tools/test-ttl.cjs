const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require('typescript')
const sourceRoot = path.join(__dirname, '../src')

const status = (outbound = 64, inbound_inc = 1) => ({
  schema_version: 2, state: outbound !== null || inbound_inc !== null ? 'configured' : 'disabled',
  outbound, inbound_inc, capability: 'supported',
  verification: outbound !== null || inbound_inc !== null ? 'unverified' : 'not-applicable', persistence: 'boot',
})
const success = (data = status()) => ({ ok: true, status: 200, json: async () => ({ ok: true, data }) })
const failure = (code, http = 500, error = 'Raw English diagnostic', manager_code) => ({
  ok: false, status: http, json: async () => ({ ok: false, code, error, manager_code }),
})

function fixture(locale = 'en') {
  const cache = new Map(), timers = new Map(), requests = [], delays = [], events = []
  let timerId = 0, token = 'test-session-token', handler = async () => success()
  const globals = {
    Error, Event, Intl, AbortController,
    localStorage: { getItem: () => locale }, navigator: { language: 'en-US' },
    sessionStorage: { getItem: () => token, setItem: (_, value) => { token = value }, removeItem: () => { token = null } },
    window: { location: { hostname: '192.168.0.1' }, dispatchEvent: (event) => events.push(event.type) },
    setTimeout: (fn, ms) => { timers.set(++timerId, fn); delays.push(ms); return timerId },
    clearTimeout: (id) => timers.delete(id),
    fetch: async (url, options) => { requests.push({ url, options }); return handler(url, options) },
  }
  function load(relative) {
    const full = path.resolve(sourceRoot, relative.endsWith('.ts') ? relative : `${relative}.ts`)
    if (cache.has(full)) return cache.get(full)
    const exports = {}; cache.set(full, exports)
    const context = { ...globals, exports, require: (name) => {
      assert.ok(name.startsWith('.'), `Unexpected dependency: ${name}`)
      return load(path.relative(sourceRoot, path.resolve(path.dirname(full), name)))
    } }
    const code = ts.transpileModule(fs.readFileSync(full, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText
    vm.runInNewContext(code, context, { filename: full })
    return exports
  }
  return {
    client: load('data/client'), api: load('data/api').api, i18n: load('i18n-core'),
    requests, timers, delays, events,
    respond: (next) => { handler = next },
    fireDeadline: () => { const [id, callback] = timers.entries().next().value; timers.delete(id); callback() },
    token: () => token,
  }
}

async function errorFrom(promise) {
  try { await promise } catch (error) { return error }
  assert.fail('Expected request to fail')
}

test('TTL API sends schema 2 with exact outgoing and increment incoming values, including null directions', async () => {
  const f = fixture()
  f.respond(async (_, options) => {
    if (options.method === 'PUT') { const body = JSON.parse(options.body); return success(status(body.outbound, body.inbound_inc)) }
    if (options.method === 'DELETE') return success(status(null, null))
    return success()
  })
  assert.equal((await f.api.ttlStatus()).outbound, 64)
  for (const [outbound, incoming] of [[64, 1], [1, 255], [255, null], [null, 1], [null, null]]) {
    const result = await f.api.ttlSet(outbound, incoming)
    const request = f.requests.at(-1)
    assert.equal(request.url, 'http://192.168.0.1:9090/api/ttl/set')
    assert.equal(request.options.method, 'PUT')
    assert.deepEqual(JSON.parse(request.options.body), { schema_version: 2, outbound, inbound_inc: incoming })
    assert.equal(result.outbound, outbound); assert.equal(result.inbound_inc, incoming)
    assert.equal(result.verification, outbound === null && incoming === null ? 'not-applicable' : 'unverified')
  }
  assert.equal((await f.api.ttlClear()).state, 'disabled')
  assert.equal(f.requests.at(-1).options.method, 'DELETE')
  assert.equal(f.requests.at(-1).options.body, undefined)
  assert.ok(f.requests.every(({ options }) => options.headers.Authorization === 'Bearer test-session-token'))
  assert.ok(f.delays.every((delay) => delay === 100_000), 'Every TTL endpoint must outlast the 90-second manager deadline')
  assert.equal(f.timers.size, 0)
})

test('cached legacy TTL payload rejection preserves machine code and explains page reload in both languages', async () => {
  const f = fixture('ru')
  f.respond(async () => failure('TTL_SCHEMA_UPGRADE_REQUIRED', 409, 'This TTL API has changed.'))
  const error = await errorFrom(f.client.req('PUT', '/api/ttl/set', { ttl: 65 }))
  assert.equal(error.status, 409); assert.equal(error.code, 'TTL_SCHEMA_UPGRADE_REQUIRED')
  assert.match(error.message, /Перезагрузите страницу/)
  assert.equal(error.details, 'TTL_SCHEMA_UPGRADE_REQUIRED\nThis TTL API has changed.')
  f.i18n.setCurrentLocale('en')
  assert.equal(error.message, 'The TTL interface has changed. Reload this page to continue.')
  assert.equal(f.token(), 'test-session-token')
})

test('all TTL failures have a Russian explanation while diagnostic details remain verbatim', async () => {
  const f = fixture('ru')
  for (const code of ['TTL_INVALID_CONFIGURATION', 'TTL_MANAGER_UNAVAILABLE', 'TTL_MANAGER_INTEGRITY', 'TTL_BUSY', 'TTL_OTHER_TRANSACTION', 'TTL_TIMEOUT', 'TTL_INVALID_STATUS', 'TTL_APPLY_UNCONFIRMED', 'TTL_MANAGER_FAILED', 'TTL_MANAGER_IO', 'TTL_UNSUPPORTED_PROFILE']) {
    const raw = 'Untranslated diagnostic: rmnet_data0 <raw> & 5G'
    f.respond(async () => failure(code, 500, raw, 'RULE_APPLY'))
    const error = await errorFrom(f.api.ttlSet(64, 1))
    assert.equal(error.code, code); assert.match(error.message, /[А-Яа-яЁё]/, code)
    assert.equal(error.details, `${code}\nRULE_APPLY\n${raw}`)
    const russian = error.message
    f.i18n.setCurrentLocale('en'); assert.notEqual(error.message, russian)
    assert.equal(error.details, `${code}\nRULE_APPLY\n${raw}`)
    f.i18n.setCurrentLocale('ru')
  }
})

test('unknown server failures use an honest localized fallback and retain bounded technical details', async () => {
  const f = fixture('ru')
  const raw = 'Private raw modem response ' + 'x'.repeat(3000)
  f.respond(async () => failure('FUTURE_CODE', 500, raw))
  const error = await errorFrom(f.api.ttlStatus())
  assert.equal(error.message, 'Модем не смог выполнить запрос.')
  assert.equal(error.details.length, 2048)
  assert.ok(error.details.startsWith('FUTURE_CODE\nPrivate raw modem response '))
  assert.ok(!error.message.includes('Private'))
})

test('401 from TTL invalidates the session once and subsequent requests do not reuse its token', async () => {
  const f = fixture('ru')
  f.respond(async () => failure(undefined, 401, 'unauthorized'))
  const error = await errorFrom(f.api.ttlStatus())
  assert.equal(error.message, 'Сеанс завершён. Войдите снова.')
  assert.equal(f.token(), null); assert.equal(f.client.hasToken(), false)
  assert.deepEqual(f.events, ['zte-auth-expired'])
  assert.equal(f.i18n.getLocale(), 'ru')
  f.respond(async () => success())
  await f.api.ttlStatus()
  assert.equal(f.requests.at(-1).options.headers.Authorization, undefined)
})

test('failed sign-in does not emit a session-expired event or overwrite the locale', async () => {
  const f = fixture('ru')
  f.respond(async () => failure(undefined, 401, 'invalid credentials'))
  const error = await errorFrom(f.client.login('wrong'))
  assert.equal(error.message, 'Неверный пароль или PIN-код.')
  assert.deepEqual(f.events, []); assert.equal(f.i18n.getLocale(), 'ru')
})

test('TTL request deadline aborts fetch, localizes the timeout and keeps the session', async () => {
  const f = fixture('ru')
  f.respond((_, options) => new Promise((_, reject) => {
    options.signal.addEventListener('abort', () => { const error = new Error('aborted'); error.name = 'AbortError'; reject(error) })
  }))
  const request = f.api.ttlSet(64, 1)
  assert.equal(f.delays.at(-1), 100_000)
  f.fireDeadline()
  const error = await errorFrom(request)
  assert.equal(error.message, 'Агент не ответил вовремя.')
  assert.equal(f.requests[0].options.signal.aborted, true)
  assert.equal(f.timers.size, 0); assert.equal(f.token(), 'test-session-token')
})

test('HTTP success with a failed envelope and malformed JSON cannot become TTL success', async () => {
  const f = fixture('en')
  f.respond(async () => ({ ok: true, status: 200, json: async () => ({ ok: false, code: 'TTL_APPLY_UNCONFIRMED', error: 'not confirmed' }) }))
  assert.equal((await errorFrom(f.api.ttlSet(64, 1))).code, 'TTL_APPLY_UNCONFIRMED')
  f.respond(async () => ({ ok: true, status: 200, json: async () => { throw new Error('HTML response') } }))
  assert.equal((await errorFrom(f.api.ttlStatus())).message, 'Invalid response from agent (200)')
  for (const envelope of [null, [], 42]) {
    f.respond(async () => ({ ok: true, status: 200, json: async () => envelope }))
    assert.equal((await errorFrom(f.api.ttlStatus())).message, 'Invalid response from agent (200)')
  }
  assert.equal(f.timers.size, 0)
})

// Exercise the real component handlers through a tiny hooks/JSX harness. This
// requires neither a browser nor a second copy of the validation implementation.
function componentFixture() {
  const slots = [], effects = [], toasts = [], mutations = []
  let index = 0, mounted = false, nextState = status(), nextError = null, nextApplyError = null, reads = 0
  const api = {
    ttlStatus: async () => { reads++; if (nextError) throw nextError; return nextState },
    ttlSet: async (outbound, incoming) => { mutations.push([outbound, incoming]); if (nextApplyError) throw nextApplyError; return status(outbound, incoming) },
  }
  const React = {
    useCallback: (callback) => callback,
    useState: (initial) => { const slot = index++; if (!(slot in slots)) slots[slot] = initial; return [slots[slot], (value) => { slots[slot] = typeof value === 'function' ? value(slots[slot]) : value }] },
    useEffect: (effect) => { if (!mounted) effects.push(effect) },
  }
  const jsx = (type, props) => ({ type, props })
  const exports = {}
  const context = { exports, Error, require: (name) => {
    if (name === 'react') return React
    if (name === 'react/jsx-runtime') return { jsx, jsxs: jsx }
    if (name === '../../data/api') return { api }
    if (name === '../../data/client') return { ApiError: Error }
    if (name === '../../i18n') return { useI18n: () => ({ t: (key) => key }) }
    if (name === '../../ui/feedback') return { toast: (...args) => toasts.push(args), toastError: (error) => toasts.push([error.message, 'err']) }
    if (name === '../../ui/controls') return Object.fromEntries(['Button', 'Field', 'Input', 'Toggle'].map((key) => [key, key]))
    if (name === '../../ui/primitives') return Object.fromEntries(['Card', 'Chip', 'Spinner'].map((key) => [key, key]))
    throw new Error(`Unexpected import: ${name}`)
  } }
  const file = path.join(sourceRoot, 'features/modem/TtlTab.tsx')
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).outputText, context)
  const render = () => { index = 0; const tree = exports.default(); mounted = true; return tree }
  const find = (tree, type) => {
    const found = []
    function walk(node) {
      if (Array.isArray(node)) return node.forEach(walk)
      if (!node || typeof node !== 'object') return
      if (node.type === type) found.push(node)
      Object.values(node.props ?? {}).forEach(walk)
    }
    walk(tree); return found
  }
  return { render, find, effects, toasts, mutations, reads: () => reads, setReadError: (error) => { nextError = error }, setStatus: (value) => { nextState = value }, setApplyError: (error) => { nextApplyError = error } }
}
const settle = () => new Promise((resolve) => setImmediate(resolve))
const applyButton = (f, tree) => f.find(tree, 'Button').find((node) => node.props.variant === 'primary')

test('TTL form rejects malformed enabled values before any write and ignores disabled direction text', async () => {
  const f = componentFixture(); f.render(); f.effects.forEach((effect) => effect()); await settle()
  for (const direction of [0, 1]) {
  for (const value of ['', '0', '-1', '256', '1.5', '1e2', ' 64', '64 ', '64x']) {
    let tree = f.render(); f.find(tree, 'Input')[direction].props.onChange({ target: { value } })
    tree = f.render(); applyButton(f, tree).props.onClick(); await settle()
    assert.equal(f.mutations.length, 0, value)
    assert.equal(f.toasts.at(-1)[1], 'err', value)
  }
  f.find(f.render(), 'Input')[direction].props.onChange({ target: { value: direction === 0 ? '64' : '1' } })
  }
  f.find(f.render(), 'Input')[0].props.onChange({ target: { value: 'invalid but disabled' } })
  let tree = f.render(); f.find(tree, 'Toggle')[0].props.onChange(false)
  tree = f.render(); applyButton(f, tree).props.onClick(); await settle()
  assert.deepEqual(f.mutations, [[null, 1]])
  tree = f.render(); f.find(tree, 'Toggle')[0].props.onChange(true)
  f.find(tree, 'Input')[0].props.onChange({ target: { value: '255' } })
  tree = f.render(); applyButton(f, tree).props.onClick(); await settle()
  assert.deepEqual(f.mutations.at(-1), [255, 1])
})

test('failed TTL refresh disables Apply instead of allowing writes from stale state', async () => {
  const f = componentFixture(); f.render(); f.effects.forEach((effect) => effect()); await settle()
  let tree = f.render(); assert.equal(applyButton(f, tree).props.disabled, false)
  f.setReadError(new Error('Could not read TTL settings.'))
  f.find(tree, 'Button').find((node) => node.props.size === 'sm').props.onClick(); await settle()
  tree = f.render(); assert.equal(applyButton(f, tree).props.disabled, true)
  assert.equal(f.mutations.length, 0)
})

test('rendering the TTL form preserves unsaved values and never applies defaults', async () => {
  const f = componentFixture(); f.setStatus(status(null, null)); f.render(); f.effects.forEach((effect) => effect()); await settle()
  let tree = f.render(); assert.deepEqual(f.find(tree, 'Toggle').map((node) => node.props.checked), [false, false])
  f.find(tree, 'Toggle')[0].props.onChange(true)
  f.find(tree, 'Input')[0].props.onChange({ target: { value: '128' } })
  for (let count = 0; count < 3; count++) tree = f.render()
  assert.equal(f.find(tree, 'Input')[0].props.value, '128')
  assert.equal(f.reads(), 1); assert.equal(f.mutations.length, 0)
})


test('failed TTL apply requires a fresh status read before another change', async () => {
  const f = componentFixture(); f.render(); f.effects.forEach((effect) => effect()); await settle()
  f.setApplyError(new Error('The modem has not confirmed the requested TTL settings.'))
  let tree = f.render(); applyButton(f, tree).props.onClick(); await settle()
  tree = f.render(); assert.equal(applyButton(f, tree).props.disabled, true)
  assert.ok(f.find(tree, 'Toggle').every((node) => node.props.disabled))
  assert.match(JSON.stringify(tree), /result is uncertain/)
  f.find(tree, 'Button').find((node) => node.props.size === 'sm').props.onClick(); await settle()
  tree = f.render(); assert.equal(applyButton(f, tree).props.disabled, false)
  assert.equal(f.mutations.length, 1)
})

test('manager state error exposes mismatch and allows an explicit supported repair', async () => {
  const f = componentFixture(); f.setStatus({ ...status(), state: 'error' })
  f.render(); f.effects.forEach((effect) => effect()); await settle()
  const tree = f.render()
  assert.match(JSON.stringify(tree), /Saved TTL settings do not match/)
  assert.equal(applyButton(f, tree).props.disabled, false)
  assert.equal(f.mutations.length, 0)
})


test('a legacy agent status cannot enable controls or write the new default settings', async () => {
  const f = componentFixture(); f.setStatus({ active: true, ipv6_active: true, ttl_value: 65 })
  f.render(); f.effects.forEach((effect) => effect()); await settle()
  const tree = f.render()
  assert.equal(applyButton(f, tree).props.disabled, true)
  assert.match(JSON.stringify(tree), /Update the modem agent to use these TTL settings/)
  assert.equal(f.mutations.length, 0)
})
