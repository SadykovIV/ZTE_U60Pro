const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const ts = require('typescript')
const React = require('react')
const { renderToStaticMarkup } = require('react-dom/server')
const exportsObject = {}
const source = fs.readFileSync(`${__dirname}/../src/features/network/VpnProfileDetails.tsx`, 'utf8')
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText, {
  exports: exportsObject,
  require: name => name === '../../i18n' ? { translate: value => value } : name === '../../ui/controls' ? { Button: props => React.createElement('button', props) } : require(name),
})
test('profile details expose the original link and every core option, with escaped user text', () => {
  const uri = 'vless://private-id@example.test:443?type=xhttp#<script>bad</script>'
  const html = renderToStaticMarkup(React.createElement(exportsObject.VpnProfileDetails, { onClose() {}, value: { schema_version: 1, active: false, profile: {
    id: 'fixture', name: 'User name', source_uri: uri, warnings: [], proxy: { name: 'VPN', server: 'example.test', uuid: 'private-id', 'xhttp-opts': { path: '/test', mode: 'auto' }, encryption: 'none' },
  } } }))
  assert.ok(html.includes('private-id'))
  assert.ok(html.includes('example.test'))
  assert.ok(html.includes('/test'))
  assert.ok(html.includes('vless://'))
  assert.ok(html.includes('&lt;script&gt;'))
  assert.ok(!html.includes('<script>'))
  assert.ok(!html.includes('type="password"'))
  assert.ok(html.includes('readOnly=""'))
})

function loadModel() {
  const exports = {}
  const source = fs.readFileSync(`${__dirname}/../src/features/network/vpnModel.ts`, 'utf8')
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, { exports })
  return exports
}
const model = loadModel()
test('unified import preserves AWG bytes and routes URI profiles separately', () => {
  const config = '\uFEFF# exported\r\n[Interface]\r\nPrivateKey=synthetic-secret\r\n'
  const action = model.profileImport(config, ' Example ')
  assert.equal(action.action, 'import_config')
  assert.equal(action.config, config)
  assert.equal(action.name, 'Example')
  for (const uri of ['vless://fixture@example.test:443', 'hy2://fixture@example.test:443']) {
    assert.equal(model.profileImport(uri, '').action, 'import')
    assert.equal(model.profileImport(uri, '').uri, uri)
  }
  assert.equal(model.protocolLabel('amneziawg3.1'), 'AWG 3.1')
  assert.equal(model.protocolLabel('hysteria2'), 'HY2')
  assert.equal(model.protocolLabel(), 'VLESS')
  assert.equal(model.warningText('VPN_IPV6_GUEST_DISABLED'), 'The VPN Wi-Fi network uses IPv4. IPv6 tunnel settings are preserved.')
  assert.equal(model.warningText('VPN_INSECURE_TLS'), 'The link disables TLS certificate verification.')
  assert.equal(model.warningText('unknown'), undefined)
})
test('AWG details preserve source config and native subscription details avoid empty source field', () => {
  for (const source of [{ source_config: '[Interface]\nPrivateKey=synthetic-secret' }, {}]) {
    const html = renderToStaticMarkup(React.createElement(exportsObject.VpnProfileDetails, { onClose() {}, value: { schema_version: 1, active: false, profile: {
      id: 'fixture', name: 'Example', ...source, proxy: { name: 'VPN', type: 'wireguard', 'private-key': 'synthetic-secret' }, warnings: [],
    } } }))
    assert.ok(html.includes('synthetic-secret'))
    assert.equal(html.includes('<textarea'), !!source.source_config)
    if (source.source_config) assert.ok(html.includes('[Interface]'))
  }
})
test('shared profile list enables applying pending active updates and shows subscription summaries', () => {
  const exports = {}
  const source = fs.readFileSync(`${__dirname}/../src/features/network/VpnTab.tsx`, 'utf8')
  const status = { schema_version: 1, installed: true, profiles: [{ id: 'p', name: 'AWG fixture', active: true, protocol: 'amneziawg3.1', transport: 'udp', update_available: true, removed_from_subscription: true, warnings: [] }], subscriptions: [{ id: 's', name: 'Feed', host: 'example.test', profile_count: 43 }] }
  const summary = { added: 2, updated: 1, removed: 0, duplicates: 3, retained_active: 1, skipped: [{ index: 5, code: 'VPN_UNSUPPORTED_PROTOCOL' }] }
  let state = 0
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText, {
    exports,
    require: name => {
      if (name === 'react') return { ...React, useEffect() {}, useRef: value => ({ current: value }), useState: value => [state++ === 0 ? status : state === 7 ? summary : value, () => {}] }
      if (name === '../../i18n') return { useI18n() {}, translate: value => value }
      if (name === '../../data/client') return { req() { throw new Error('No network in render') }, ApiError: Error }
      if (name === '../../ui/controls') return { Button: ({ loading, ...props }) => React.createElement('button', props), Field: ({ label, children }) => React.createElement('label', {}, label, children), Input: props => React.createElement('input', props) }
      if (name === '../../ui/primitives') return { Card: ({ title, children }) => React.createElement('section', {}, React.createElement('h2', {}, title), children) }
      if (name === '../../ui/feedback') return { toast() {} }
      if (name === './VpnProfileDetails') return exportsObject
      if (name === './vpnModel') return model
      if (name === '../../locales/ru-vpn') return { vpnErrors: { VPN_UNSUPPORTED_PROTOCOL: 'Unsupported protocol' } }
      return require(name)
    },
  })
  const html = renderToStaticMarkup(React.createElement(exports.default))
  assert.ok(html.includes('AWG 3.1'))
  assert.match(html, /<button>Apply update<\/button>/)
  assert.match(html, /<button disabled="">Delete<\/button>/)
  assert.ok(html.includes('example.test') && html.includes('43'))
  assert.ok(html.includes('Add subscription') && html.includes('Update subscription') && html.includes('Remove subscription'))
  assert.match(html, /<button>Update all subscriptions<\/button>/)
  assert.ok(html.includes('Import result') && html.includes('Unsupported protocol'))
  assert.ok(html.includes('Your current connection is preserved.'))
})

test('activation success requires the requested profile and applied pending configuration', () => {
  assert.equal(model.activationConfirmed({ active_profile: 'p', profiles: [{ id: 'p', active: true, update_available: false }] }, 'p'), true)
  assert.equal(model.activationConfirmed({ active_profile: 'p', profiles: [{ id: 'p', active: true }] }, 'p'), true)
  assert.equal(model.activationConfirmed({ active_profile: 'p', profiles: [{ id: 'p', active: true, update_available: true }] }, 'p'), false)
  assert.equal(model.activationConfirmed({ active_profile: 'other', profiles: [{ id: 'p', active: true }] }, 'p'), false)
  assert.equal(model.activationConfirmed({ active_profile: 'p', profiles: [{ id: 'p', active: false }] }, 'p'), false)
  assert.equal(model.activationConfirmed({ active_profile: 'p' }, 'p'), false)
})

test('update all uses a snapshot, runs sequentially and continues after a private error', async () => {
  const subscriptions = [{ id: 'a', name: 'First' }, { id: 'b', name: 'Second' }, { id: 'c', name: 'Third' }]
  const calls = [], progress = []
  let running = 0
  const receipt = { added: 3, updated: 0, removed: 0, duplicates: 0, retained_active: 1, skipped: [] }
  const results = await model.updateSubscriptionsSequentially(subscriptions, async id => {
    assert.equal(running, 0); running++
    calls.push(id)
    if (id === 'a') subscriptions.splice(1, 1, { id: 'other', name: 'Changed after start' })
    await Promise.resolve()
    running--
    if (id === 'b') throw new Error('https://private.example/token-secret')
    return receipt
  }, () => 'VPN_SUBSCRIPTION_FETCH', values => progress.push(values))
  assert.deepEqual(calls, ['a', 'b', 'c'])
  assert.deepEqual(progress.map(values => values.length), [1, 2, 3])
  assert.equal(results[0].ok, true); assert.equal(results[0].import.retained_active, 1)
  assert.equal(results[1].ok, false); assert.equal(results[1].code, 'VPN_SUBSCRIPTION_FETCH')
  assert.equal(results[1].name, 'Second'); assert.equal(results[2].ok, true)
  assert.ok(!JSON.stringify(results).includes('token-secret'))
  assert.equal(progress[0].length, 1)
})
test('empty subscription list sends no request', async () => {
  let calls = 0
  const results = await model.updateSubscriptionsSequentially([], async () => { calls++; }, () => '', () => { calls++; })
  assert.equal(results.length, 0); assert.equal(calls, 0)
})

for (const finalStatusFails of [false, true]) test(`update-all button preserves per-feed outcomes and uses existing requests (final status failure: ${finalStatusFails})`, async () => {
  const exports = {}, states = [], refs = [], requests = []
  const subscriptions = [{ id: 'a', name: 'First' }, { id: 'b', name: '<Second>' }, { id: 'c', name: 'Third' }]
  const status = { schema_version: 1, installed: true, active_profile: 'live', enabled: true, profiles: [], subscriptions }
  const receipt = { added: 1, updated: 0, removed: 0, duplicates: 0, retained_active: 1, skipped: [] }
  let stateIndex = 0, refIndex = 0, releaseFirst
  const firstResponse = new Promise(resolve => { releaseFirst = resolve })
  class ApiError extends Error { constructor(code, message) { super(message); this.code = code } }
  const source = fs.readFileSync(`${__dirname}/../src/features/network/VpnTab.tsx`, 'utf8')
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText, {
    exports,
    require: name => {
      if (name === 'react') return { ...React, useEffect() {}, useRef(value) { const index = refIndex++; return refs[index] ??= { current: value } }, useState(value) {
        const index = stateIndex++
        if (!(index in states)) states[index] = index === 0 ? status : value
        return [states[index], value => { states[index] = typeof value === 'function' ? value(states[index]) : value }]
      } }
      if (name === '../../i18n') return { useI18n() {}, translate: value => value }
      if (name === '../../data/client') return { ApiError, async req(method, path, body, _headers, timeout) {
        requests.push({ method, path, body, timeout })
        if (method === 'GET') {
          if (finalStatusFails) throw new Error('https://private.example/status-secret')
          return { ...status, ssid: 'Final status' }
        }
        assert.equal(body.action, 'subscription_update')
        assert.equal(timeout, 240_000)
        if (body.id === 'a') await firstResponse
        if (body.id === 'b') throw new ApiError('VPN_SUBSCRIPTION_FETCH', 'https://private.example/token-secret')
        return { ...status, last_import: receipt }
      } }
      if (name === '../../ui/controls') return { Button: ({ loading, ...props }) => React.createElement('button', props), Field: ({ label, children }) => React.createElement('label', {}, label, children), Input: props => React.createElement('input', props) }
      if (name === '../../ui/primitives') return { Card: ({ title, children }) => React.createElement('section', {}, React.createElement('h2', {}, title), children) }
      if (name === '../../ui/feedback') return { toast() { assert.fail('A batch must show per-feed outcomes instead of an overall success toast') } }
      if (name === './VpnProfileDetails') return exportsObject
      if (name === './vpnModel') return model
      if (name === '../../locales/ru-vpn') return { vpnErrors: { VPN_SUBSCRIPTION_FETCH: 'Could not download the subscription.' } }
      return require(name)
    },
  })
  function render() { stateIndex = 0; refIndex = 0; return exports.default() }
  function findButton(tree) {
    if (!tree || typeof tree !== 'object') return
    if (tree.props?.children === 'Update all subscriptions') return tree
    for (const child of [tree.props?.children].flat(Infinity)) { const found = findButton(child); if (found) return found }
  }
  const button = findButton(render())
  assert.equal(button.props.disabled, false)
  button.props.onClick(); button.props.onClick()
  let html = renderToStaticMarkup(render())
  assert.match(html, /Updating subscriptions.*0\/3/)
  assert.equal(findButton(render()).props.disabled, true)
  assert.equal(requests.length, 1)
  releaseFirst()
  for (let i = 0; i < 20 && states[1]; i++) await new Promise(resolve => setImmediate(resolve))
  assert.equal(states[1], false)
  assert.deepEqual(requests.map(item => item.body?.id ?? item.method), ['a', 'b', 'c', 'GET'])
  assert.equal(requests[3].path, '/api/vpn/status')
  assert.equal(states[0].active_profile, 'live'); assert.equal(states[0].enabled, true)
  html = renderToStaticMarkup(render())
  assert.equal((html.match(/Subscription updated/g) ?? []).length, 2)
  assert.ok(html.includes('&lt;Second&gt;') && html.includes('Could not download the subscription.'))
  assert.ok(!html.includes('token-secret') && !html.includes('status-secret'))
  assert.equal(html.includes('Could not refresh the final VPN status.'), finalStatusFails)
  if (!finalStatusFails) assert.ok(html.includes('Final status'))
  states[0] = { ...status, subscriptions: [] }
  assert.equal(findButton(render()).props.disabled, true)
})
