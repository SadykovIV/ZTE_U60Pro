const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm')
const ts = require('typescript')
const base = path.join(__dirname, '../src/features/esim')
function load(name, imports = {}, extra = {}) {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(base, name + '.ts'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true }
  }).outputText, { exports, URL, Uint8ClampedArray, Uint8Array, Set, Date, JSON, ...extra,
    require: name => imports[name] ?? (() => { throw Error('unexpected import: ' + name) })() })
  return exports
}
const model = load('model')
const errors = load('errors')
const journal = load('journal', { './errors': errors })
const profile = (suffix, enabled = false) => ({ iccid: '8900000000000000' + suffix, isdp_aid: null, state: enabled ? 'enabled' : 'disabled', enabled, nickname: null, name: 'Synthetic', service_provider: 'Example' })
const snapshot = profiles => ({ ok: true, eid: '9'.repeat(32), profiles })
test('eSIM manual input composes the exact wire code and rejects ambiguous address/Matching ID', () => {
  assert.equal(model.compose('https://Example.com:443/', 'matching-123'), 'LPA:1$example.com$matching-123')
  for (const address of ['http://example.com', 'https://u:p@example.com/', 'https://example.com/path', 'https://example.com/?x=y', 'example.com:443', 'localhost', '192.168.0.1', 'a.123', '-a.com']) assert.throws(() => model.compose(address, 'test'), address)
  for (const id of ['', 'x$y', ' space', 'x\ny', '\u0000', 'тест']) assert.throws(() => model.compose('example.com', id))
  assert.equal(model.activation('LPA:1$example.com$test$$1'), 'LPA:1$example.com$test$$1')
})
test('eSIM snapshots reject duplicate IDs, invalid state, false success and identifier inconsistencies', () => {
  const valid = snapshot([profile('01'), profile('02', true)])
  assert.equal(model.validSnapshot(valid), true)
  for (const value of [null, {}, { ...valid, ok: false }, { ...valid, eid: '1' }, { ...valid, eid: 123 }, snapshot([{ ...profile('01'), iccid: 890000000000000000 }]), snapshot([profile('01'), profile('01')]), snapshot([{ ...profile('01'), enabled: true }]), snapshot([{ ...profile('01'), isdp_aid: '' }])]) assert.equal(model.validSnapshot(value), false)
})
test('all eSIM mutation postconditions must match the exact prior card and selected profile', () => {
  const before = snapshot([profile('01'), profile('02', true)])
  const check = (operation, after, iccid = before.profiles[0].iccid) => model.verifiedResult({ protocol: 1, operation, expected_snapshot: before, iccid }, { ok: true, changed: true, snapshot: after, modem_verified: true, radio_restored: true })
  assert.equal(check('enable', snapshot([profile('01', true), profile('02')])).profiles[0].enabled, true)
  assert.throws(() => check('enable', before))
  assert.throws(() => check('enable', snapshot([profile('01', true), profile('02', true)])))
  assert.equal(check('delete', snapshot([profile('02', true)])).profiles.length, 1)
  assert.throws(() => check('delete', snapshot([profile('01')]), before.profiles[1].iccid))
  assert.equal(check('download', snapshot([...before.profiles, profile('03')])).profiles.length, 3)
  assert.throws(() => check('download', snapshot([...before.profiles, profile('03', true)])))
  assert.throws(() => check('download', { ...before, eid: '8'.repeat(32) }))
  assert.throws(() => model.verifiedResult({ protocol: 1, operation: 'list' }, { ok: false, snapshot: before }))
})
test('enable success requires both modem readback and restored radio; refresh permits unchanged active card', () => {
  const before = snapshot([profile('01')]), after = snapshot([profile('01', true)])
  const request = { protocol: 1, operation: 'enable', expected_snapshot: before, iccid: before.profiles[0].iccid }
  for (const fields of [{}, { modem_verified: true }, { radio_restored: true }, { modem_verified: false, radio_restored: true }, { modem_verified: true, radio_restored: false }, { modem_verified: 'true', radio_restored: true }]) {
    assert.throws(() => model.verifiedResult(request, { ok: true, changed: true, snapshot: after, ...fields }))
  }
  assert.equal(model.verifiedResult({ ...request, expected_snapshot: after }, { ok: true, changed: false, snapshot: after, modem_verified: true, radio_restored: true }).profiles[0].enabled, true)
  assert.throws(() => model.verifiedResult(request, { ok: true, changed: false, snapshot: after, modem_verified: true, radio_restored: true }))
})
test('real QR decoder reads a synthetic LPA image and rejects multiple or unrelated QR codes', () => {
  const qr = load('qr', { jsqr: require('jsqr'), './model': model })
  function decode(name) {
    const dir = path.join(__dirname, 'fixtures/esim')
    const size = JSON.parse(fs.readFileSync(path.join(dir, name + '.json')))
    return qr.decodePixels(new Uint8ClampedArray(fs.readFileSync(path.join(dir, name + '.rgba'))), size.width, size.height)
  }
  assert.equal(decode('single-qr'), 'LPA:1$example.com$synthetic-test')
  assert.throws(() => decode('multiple-qr'), /multiple_qr|qr_missing/)
  assert.throws(() => decode('non-esim-qr'))
})
test('job client posts once, follows only its ID and verifies a completed result', async () => {
  const calls = [], snap = snapshot([profile('01')]), id = 'ab'.repeat(16)
  const req = async (method, url, body) => {
    calls.push({ method, url, body })
    return method === 'POST' ? { job_id: id, state: 'running' } : { job_id: id, state: 'complete', result: { ok: true, snapshot: snap } }
  }
  const api = load('api', { '../../data/client': { req }, './model': model, './journal': journal, './errors': errors }, {
    window: { crypto: { getRandomValues: bytes => bytes.fill(0xab) } }, setTimeout, clearTimeout
  })
  const value = await api.runOperation({ protocol: 1, operation: 'list' }, () => {}, new AbortController().signal)
  assert.equal(value.snapshot.eid, snap.eid); assert.equal(calls.filter(c => c.method === 'POST').length, 1)
  assert.equal(calls[1].url, '/api/esim/jobs/' + id)
  assert.equal(calls[0].body.request_id, id)
})
test('lost start response, mismatched job and false result never become a successful operation or an automatic retry', async () => {
  for (const failure of ['lost', 'foreign', 'false-result']) {
    let posts = 0
    const req = async method => {
      if (method === 'POST') { posts++; if (failure === 'lost') throw Error('network'); return { job_id: 'ab'.repeat(16), state: 'running' } }
      return { job_id: (failure === 'foreign' ? 'cd' : 'ab').repeat(16), state: 'complete', result: { ok: false, snapshot: snapshot([]) } }
    }
    const api = load('api', { '../../data/client': { req }, './model': model, './journal': journal, './errors': errors }, { window: { crypto: { getRandomValues: b => b.fill(1) } }, setTimeout, clearTimeout })
    await assert.rejects(api.runOperation({ protocol: 1, operation: 'list' }, () => {}, new AbortController().signal))
    assert.equal(posts, 1)
  }
})

test('journal ignores secrets and arbitrary diagnostics while keeping timings and counters', () => {
  const event = { type: 'progress', stage: 'downloading', detail: { event: 'http_end', elapsed_ms: 1500, log_seq: 4, http_status: 200, request_bytes: 500, response_bytes: 400, duration_ms: 200, outcome: 'ok', apdu_count: 8, http_count: 1, activation_code: 'SECRET-CODE', url: 'https://private.example/SECRET', error: 'SECRET-RAW' } }
  const value = journal.journalEntry(event)
  assert.equal(value.seq, 4); assert.match(value.text, /http_status=200/); assert.match(value.text, /1.5s/); assert.doesNotMatch(value.text, /SECRET|private/)
  assert.equal(journal.journalEntry({ ...event, stage: 'SECRET' }), null)
  assert.equal(journal.journalEntry({ ...event, detail: { ...event.detail, event: 'SECRET' } }), null)
  assert.equal(journal.journalEntry({ ...event, detail: { ...event.detail, elapsed_ms: '10' } }), null)
})
test('radio stages and recovery diagnostics are fixed and no card identifiers enter the journal', () => {
  for (const stage of ['radio_offline', 'radio_online', 'reading_modem']) {
    assert.notEqual(journal.stageMessage(stage), 'The agent is processing the eUICC operation…')
    const entry = journal.journalEntry({ type: 'progress', stage, detail: { event: 'stage', elapsed_ms: 500, log_seq: 1, error: 'radio_restore_failed', iccid: '89000000000000000001', raw: 'private-fixture' } })
    assert.match(entry.text, /radio_restore_failed/)
    assert.doesNotMatch(entry.text, /890000|private-fixture/)
  }
  assert.equal(journal.stageMessage('private-fixture'), 'The agent is processing the eUICC operation…')
})
test('radio recovery failure remains a fixed failure and is never retried', async () => {
  let posts = 0
  const api = load('api', { '../../data/client': { req: async () => { posts++; return { job_id: 'ab'.repeat(16), state: 'complete', result: { ok: false, error: 'radio_restore_failed', modem_verified: false, radio_restored: false } } } }, './model': model, './journal': journal, './errors': errors }, { window: { crypto: { getRandomValues: b => b.fill(1) } }, setTimeout, clearTimeout })
  await assert.rejects(api.runOperation({ protocol: 1, operation: 'enable', expected_snapshot: snapshot([profile('01')]), iccid: profile('01').iccid }, () => {}, new AbortController().signal), /radio_restore_failed/)
  assert.equal(posts, 1)
})

test('component diagnostics match the exact fixed catalog and discard unsafe values', () => {
  const catalog = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../tools/esim-app/fixtures/component-error-codes.json'), 'utf8'))
  assert.equal(catalog.length, 51)
  assert.deepEqual([...errors.safeComponentErrors].sort(), catalog.sort())
  for (const code of catalog) assert.equal(errors.componentError(code), code)
  for (const value of ['qmi_open_rejected\nSECRET', 'SECRET-RAW-STDERR', 123, null, { code: 'qmi_open_rejected' }]) assert.equal(errors.componentError(value), undefined)
})
test('final journal keeps fixed component cause and never copies unknown diagnostics', () => {
  const line = journal.resultDiagnostic({ ok: false, error: 'card_open_rejected', component_error: 'qmi_open_rejected', stderr: 'SECRET-RAW', iccid: '89000000000000000001' })
  assert.match(line, /error=card_open_rejected.*component_error=qmi_open_rejected/)
  assert.doesNotMatch(line, /SECRET|890000/)
  assert.equal(journal.resultDiagnostic({ ok: true, component_error: 'qmi_open_rejected' }), null)
  assert.equal(journal.resultDiagnostic({ ok: false, error: 'SECRET', component_error: 'SECRET' }), 'result · error=unconfirmed')
})
test('card recovery instructions distinguish restart, wait and channel rejection in both languages', () => {
  const source = fs.readFileSync(path.join(__dirname, '../src/locales/ru-esim.ts'), 'utf8')
  const localized = {}
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, { exports: localized })
  for (const code of ['card_busy', 'card_open_rejected', 'card_cleanup_unknown', 'card_not_ready', 'card_reset_failed', 'card_power_restore_failed']) {
    assert.equal(errors.safeEsimErrors.has(code), true)
    assert.ok(localized.ruEsim[errors.failureMessage(code)])
  }
  assert.match(errors.failureMessage('card_cleanup_unknown'), /Restart the modem before retrying/)
  assert.match(errors.failureMessage('card_not_ready'), /Wait, then read profiles/)
  assert.match(errors.failureMessage('card_reset_failed'), /restart is unconfirmed.*Read profiles again/)
  assert.match(errors.failureMessage('card_power_restore_failed'), /power restoration is unconfirmed.*Restart the modem/)
  for (const code of ['card_reset_failed', 'card_power_restore_failed']) assert.equal(errors.componentError(code), undefined)
  assert.doesNotMatch(errors.failureMessage('private-error'), /private-error/)
})
test('fixed card failure and component cause are logged once with no automatic job retry', async () => {
  for (const code of ['card_busy', 'card_open_rejected', 'card_cleanup_unknown', 'card_not_ready', 'card_reset_failed', 'card_power_restore_failed']) {
    let posts = 0; const logs = []
    const api = load('api', { '../../data/client': { req: async () => { posts++; return { job_id: 'ab'.repeat(16), state: 'complete', result: { ok: false, error: code, component_error: 'qmi_open_rejected', raw: 'SECRET' } } } }, './model': model, './journal': journal, './errors': errors }, { window: { crypto: { getRandomValues: b => b.fill(1) } }, setTimeout, clearTimeout })
    await assert.rejects(api.runOperation({ protocol: 1, operation: 'list' }, (_, line) => logs.push(line), new AbortController().signal), new RegExp(code))
    assert.equal(posts, 1); assert.equal(logs.length, 1)
    assert.match(logs[0], /component_error=qmi_open_rejected/); assert.doesNotMatch(logs[0], /SECRET/)
  }
  assert.throws(() => model.verifiedResult({ protocol: 1, operation: 'list' }, { ok: true, snapshot: snapshot([]), component_error: 'qmi_open_rejected' }))
})
