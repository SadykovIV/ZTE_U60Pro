const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm')
const ts = require('typescript')
const base = path.join(__dirname, '../src/features/esim')
function load(name, imports = {}, extra = {}, extension = 'ts') {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(base, name + '.' + extension), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX }
  }).outputText, { exports, URL, Uint8Array, Set, Date, JSON, AbortController, ...extra,
    require: name => imports[name] ?? (() => { throw Error('unexpected import: ' + name) })() })
  return exports
}
const model = load('model'), errors = load('errors'), journal = load('journal', { './errors': errors })
const confirmed = () => ({ kind: 'euicc_confirmed', management: 'available', reason: 'eid_and_profiles_read', cleanup_confirmed: true })
const unknown = (reason = 'read_failed') => ({ kind: 'unknown', management: 'unknown', reason, cleanup_confirmed: false })
const profile = { iccid: '89000000000000000001', isdp_aid: null, state: 'disabled', enabled: false, nickname: null, name: 'Synthetic', service_provider: null }
const snapshot = (profiles = []) => ({ ok: true, eid: '9'.repeat(32), profiles })
const request = { protocol: 1, operation: 'list' }
const failureReasons = ['busy', 'open_rejected', 'cleanup_unknown', 'not_ready', 'unsupported_device', 'read_failed', 'operation_failed']
function apiFor(req) {
  return load('api', { '../../data/client': { req }, './model': model, './errors': errors, './journal': journal }, {
    window: { crypto: { getRandomValues: bytes => bytes.fill(1) } }, setTimeout, clearTimeout
  })
}
test('new and legacy accepted empty inventories confirm eUICC, never ordinary SIM', () => {
  for (const extra of [{}, { card: confirmed() }]) {
    const value = model.verifiedCard(request, { ok: true, snapshot: snapshot(), ...extra })
    assert.equal(value.card.kind, 'euicc_confirmed')
    assert.equal(value.snapshot.profiles.length, 0)
    assert.equal(value.card.cleanup_confirmed, true)
  }
  for (const value of [{ ok: false, snapshot: snapshot() }, { ok: true }, { ok: true, snapshot: { ...snapshot(), eid: 'bad' } }, { ok: true, snapshot: snapshot(), component_error: 'qmi_open_rejected' }]) {
    assert.throws(() => model.verifiedCard(request, value))
  }
})
test('present card metadata validates exact keys, enums, boolean and outcome consistency', () => {
  const malformed = [null, [], {}, { ...confirmed(), cleanup_confirmed: 'true' }, { ...confirmed(), cleanup_confirmed: false },
    { ...confirmed(), kind: 'ordinary_sim' }, { ...confirmed(), kind: 'absent' }, { ...confirmed(), kind: 'unavailable' },
    { ...confirmed(), management: 'unknown' }, { ...confirmed(), reason: 'private-reason' }, { ...confirmed(), raw: 'PRIVATE_CANARY' }, unknown()]
  for (const card of malformed) assert.throws(() => model.verifiedCard(request, { ok: true, snapshot: snapshot(), card }))
  for (const reason of failureReasons) assert.equal(model.parsedCard(unknown(reason), false).reason, reason)
  for (const card of [confirmed(), { ...unknown(), cleanup_confirmed: true }, { ...unknown(), reason: 'PRIVATE_CANARY' }]) assert.throws(() => model.parsedCard(card, false))
})
test('metadata does not bypass mutation postconditions or a full inventory', () => {
  const before = snapshot([profile])
  const mutation = { protocol: 1, operation: 'enable', expected_snapshot: before, iccid: profile.iccid }
  assert.throws(() => model.verifiedCard(mutation, { ok: true, snapshot: before, changed: true, card: confirmed(), radio_restored: true, modem_verified: true }))
  assert.throws(() => model.verifiedCard(request, { ok: true, snapshot: { ...before, profiles: [profile, profile] }, card: confirmed() }))
})
test('failed jobs preserve only typed unknown card metadata and never retry or accept stale snapshots', async () => {
  for (const reason of failureReasons) {
    let calls = 0; const logs = []
    const api = apiFor(async () => { calls++; return { job_id: 'ab'.repeat(16), state: 'complete', result: { ok: false, error: 'card_open_rejected', card: unknown(reason), snapshot: snapshot([profile]), raw: 'PRIVATE_CANARY' } } })
    await assert.rejects(api.runOperation(request, (_, line) => logs.push(line), new AbortController().signal), error => {
      assert.equal(error.message, 'card_open_rejected'); assert.equal(error.card.kind, 'unknown'); assert.equal(error.card.reason, reason)
      assert.equal(error.snapshot, undefined); return true
    })
    assert.equal(calls, 1); assert.doesNotMatch(JSON.stringify(logs), /PRIVATE_CANARY|890000|999999/)
  }
})
test('malformed final metadata fails closed, while successful legacy API derives confirmed card', async () => {
  for (const result of [{ ok: false, error: 'card_busy', card: confirmed() }, { ok: true, snapshot: snapshot(), card: unknown() }, { ok: true, snapshot: snapshot(), card: { ...confirmed(), raw: 'PRIVATE_CANARY' } }]) {
    let calls = 0
    const api = apiFor(async () => { calls++; return { job_id: 'ab'.repeat(16), state: 'complete', result } })
    await assert.rejects(api.runOperation(request, () => {}, new AbortController().signal), /unconfirmed/)
    assert.equal(calls, 1)
  }
  const api = apiFor(async () => ({ job_id: 'ab'.repeat(16), state: 'complete', result: { ok: true, snapshot: snapshot() } }))
  assert.equal((await api.runOperation(request, () => {}, new AbortController().signal)).card.kind, 'euicc_confirmed')
})
test('every type banner is translated and cleanup unconfirmed alone never gives restart advice', () => {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(base, '../../locales/ru-esim.ts'), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, { exports })
  for (const card of [null, confirmed(), ...failureReasons.map(unknown)]) {
    const message = model.cardMessage(card, false)
    assert.ok(exports.ruEsim[message]); assert.doesNotMatch(message, /Restart|reboot|PRIVATE/)
  }
  assert.ok(exports.ruEsim[model.cardMessage(null, true)])
  assert.equal(journal.stageMessage('checking_card'), model.cardMessage(null, true))
})

// Execute the production page's hooks and event handlers without browser/network.
// State persists across render calls; the explicit operation uses a controlled promise.
function pageFixture() {
  let cursor = 0, effects = [], cleanups = [], mounted = false, operationCalls = 0, capabilityCalls = 0, resolve, reject
  const state = [], refs = new Set(), listeners = new Map()
  function useState(initial) { const i = cursor++; if (!(i in state)) state[i] = initial; return [state[i], value => { state[i] = typeof value === 'function' ? value(state[i]) : value }] }
  function useRef(initial) { const i = cursor++; if (!refs.has(i)) { state[i] = { current: initial }; refs.add(i) } return state[i] }
  const node = (type, props) => ({ type, props: props ?? {} })
  const ui = { Button: 'button', Field: 'field', Input: 'input', Select: 'select' }
  const module = load('EsimPage', { react: { useState, useRef, useEffect: effect => { if (!mounted) effects.push(effect) } },
    'react/jsx-runtime': { jsx: node, jsxs: node }, '../../i18n': { useI18n: () => ({ t: x => x }) }, '../../ui/controls': ui,
    '../../ui/primitives': { Card: 'card', Chip: 'chip' }, '../../ui/feedback': { confirm: async () => true },
    './api': { capabilities: async () => { capabilityCalls++; return { protocol: 1, operations: ['list', 'enable', 'download', 'delete'] } },
      runOperation: () => { operationCalls++; return new Promise((yes, no) => { resolve = yes; reject = no }) } },
    './model': model, './qr': { decodeImage: async () => { throw Error('not used') } }, './journal': journal, './errors': errors
  }, { window: { addEventListener: (name, fn) => listeners.set(name, fn), removeEventListener: name => listeners.delete(name) } }, 'tsx')
  const render = () => { cursor = 0; return module.default() }
  const elements = value => {
    if (!value || typeof value !== 'object') return []
    if (Array.isArray(value)) return value.flatMap(elements)
    return [value, ...Object.values(value.props ?? {}).flatMap(elements)]
  }
  const clickCheck = () => { const button = elements(render()).find(e => e.type === 'button' && e.props.children === 'Check card and profiles'); assert.equal(button.props.disabled, false); button.props.onClick() }
  return { render, elements, clickCheck, get calls() { return operationCalls }, get capabilityCalls() { return capabilityCalls },
    mount: () => { render(); cleanups = effects.map(effect => effect()); effects = []; mounted = true },
    resolve: value => resolve(value), reject: value => reject(value), unmount: () => cleanups.forEach(fn => fn?.()) }
}
const settle = () => new Promise(resolve => setImmediate(resolve))
test('page checks only on demand and clears accepted profiles and write permissions during failed refresh', async () => {
  const page = pageFixture(); page.mount(); await settle(); assert.equal(page.calls, 0); assert.equal(page.capabilityCalls, 1)
  page.clickCheck(); assert.equal(page.calls, 1)
  assert.match(JSON.stringify(page.render()), /Checking the SIM card and profiles/)
  page.resolve({ snapshot: snapshot([profile]), card: confirmed(), pending: false }); await settle()
  let tree = page.render(), elements = page.elements(tree)
  elements.find(e => e.type === 'button' && e.props['aria-pressed'] === false).props.onClick()
  elements = page.elements(page.render())
  assert.equal(elements.find(e => e.type === 'button' && e.props.children === 'Make active').props.disabled, false)
  page.clickCheck(); assert.equal(page.calls, 2)
  assert.equal(page.elements(page.render()).find(e => e.type === 'button' && e.props.children === 'Make active').props.disabled, true)
  page.reject(new model.EsimOperationError('card_open_rejected', unknown('open_rejected'))); await settle()
  tree = page.render(); assert.match(JSON.stringify(tree), /Card type is unknown/); assert.doesNotMatch(JSON.stringify(tree), /99999999|89000000000000000001|EID and profiles were read/)
  for (const label of ['Make active', 'Delete profile', 'Install profile']) assert.equal(page.elements(tree).find(e => e.type === 'button' && e.props.children === label).props.disabled, true)
  page.render(); await settle(); assert.equal(page.calls, 2)
  page.unmount()
})
test('unmounted page does not accept a late card result or send another operation', async () => {
  const page = pageFixture(); page.mount(); await settle(); page.clickCheck(); page.unmount()
  page.resolve({ snapshot: snapshot([profile]), card: confirmed(), pending: false }); await settle()
  assert.doesNotMatch(JSON.stringify(page.render()), /EID and profiles were read|99999999|89000000000000000001/)
  assert.equal(page.calls, 1)
})
