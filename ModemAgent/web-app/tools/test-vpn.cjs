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
  require: name => name === '../../i18n' ? { translate: value => value } : name === '../../ui/controls' ? { Button: props => React.createElement('button', props) } : name === './vpnModel' ? loadModel() : require(name),
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
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, { exports, TextEncoder })
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
      if (name === './Ikev2ProfileForm') return { Ikev2ProfileForm: () => null }
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
      if (name === './Ikev2ProfileForm') return { Ikev2ProfileForm: () => null }
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

const ikev2Fixture = {
  name: 'Work VPN', server: 'vpn.example.test', server_id: '', username: 'domain\\user',
  password: 'synthetic-password', ca_certificate: '-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----', dns: '10.0.2.1',
}
test('IKEv2 requests preserve credentials, default certificate identity and stable IDs without reading back passwords', () => {
  assert.equal(model.protocolLabel('ikev2'), 'IKEv2 / IPsec')
  assert.equal(model.emptyIkev2Draft().dns, '10.0.2.1')
  assert.equal(model.emptyIkev2Draft().name, 'UserGate')
  assert.equal(model.ikev2Validation(ikev2Fixture), undefined)
  const request = model.ikev2Request({ ...ikev2Fixture, password: ' leading and trailing ', name: ' Work VPN ' })
  assert.equal(request.action, 'save_ikev2')
  assert.equal(request.name, 'Work VPN')
  assert.equal(request.ikev2.password, ' leading and trailing ')
  assert.equal(request.ikev2.server_id, 'vpn.example.test')
  assert.ok(!Object.hasOwn(request, 'id'))
  const draft = model.ikev2Draft({ id: 'stable-id', name: 'Work VPN', proxy: { type: 'ikev2', ...ikev2Fixture, password_set: true } })
  assert.equal(draft.password, '')
  assert.equal(model.ikev2Validation(draft), undefined)
  const edit = model.ikev2Request(draft)
  assert.equal(edit.id, 'stable-id')
  assert.ok(!Object.hasOwn(edit.ikev2, 'password'))
  assert.equal(model.ikev2Request({ ...draft, password: 'replacement' }).ikev2.password, 'replacement')
})
test('IKEv2 forms reject URLs, missing create passwords, script material and DNS outside private VPN routes', () => {
  for (const overrides of [
    { name: '' }, { server: 'https://vpn.example.test' }, { server: 'vpn.example.test:500' },
    { username: 'user\nextra' }, { password: '' }, { password: 'secret\nextra' },
    { ca_certificate: '#!/bin/sh\nanything' }, { ca_certificate: '-----BEGIN PRIVATE KEY-----\nYWJj\n-----END PRIVATE KEY-----' },
    { dns: '1.1.1.1' }, { dns: '127.0.0.1' }, { dns: '224.0.0.1' }, { dns: '172.32.0.1' }, { dns: '192.168.1.999' }, { dns: '192.168.50.1' }, { dns: '::1' },
  ]) assert.equal(typeof model.ikev2Validation({ ...ikev2Fixture, ...overrides }), 'string', JSON.stringify(overrides))
  for (const dns of ['10.0.2.1', '172.16.0.1', '172.31.255.254', '192.168.1.1']) assert.equal(model.ikev2Validation({ ...ikev2Fixture, dns }), undefined)
})
test('IKEv2 details redact password and raw source even from an obsolete or malformed controller reply', () => {
  const html = renderToStaticMarkup(React.createElement(exportsObject.VpnProfileDetails, { onClose() {}, value: { schema_version: 1, active: true, profile: {
    id: 'fixture', name: 'Work VPN', protocol: 'ikev2', warnings: [], source_config: 'password=synthetic-password', source_uri: 'synthetic-password',
    proxy: { type: 'ikev2', ...ikev2Fixture, password_set: true },
  } } }))
  assert.ok(html.includes('vpn.example.test') && html.includes('10.0.2.1'))
  assert.ok(html.includes('Server certificate identity') && html.includes('CA certificate (PEM)'))
  assert.ok(html.includes('Private networks') && html.includes('Public internet uses the mobile connection.'))
  assert.ok(html.includes(model.IKEV2_DNS_HINT))
  assert.ok(!html.includes('synthetic-password'))
  assert.ok(!html.includes('Original profile data'))
})
function loadIkev2Form(profile, onSave) {
  const exports = {}, states = []
  let stateIndex = 0
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(`${__dirname}/../src/features/network/Ikev2ProfileForm.tsx`, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText, {
    exports, TextDecoder,
    require: name => {
      if (name === 'react') return { ...React, useState(value) {
        const index = stateIndex++
        if (!(index in states)) states[index] = typeof value === 'function' ? value() : value
        return [states[index], value => { states[index] = typeof value === 'function' ? value(states[index]) : value }]
      } }
      if (name === '../../i18n') return { translate: value => value }
      if (name === '../../ui/controls') return { Button: ({ loading, ...props }) => React.createElement('button', props), Field: ({ label, hint, children }) => React.createElement('label', {}, label, children, hint), Input: props => React.createElement('input', props) }
      if (name === './vpnModel') return model
      return require(name)
    },
  })
  return { states, render() { stateIndex = 0; return exports.Ikev2ProfileForm({ profile, busy: false, onSave, onCancel() {} }) } }
}
test('IKEv2 editor sends one structured save, keeps the saved password and clears its draft after success', async () => {
  const requests = []
  const form = loadIkev2Form({ id: 'stable-id', name: 'Work VPN', proxy: { ...ikev2Fixture, password_set: true } }, async value => { requests.push(value); return true })
  const tree = form.render()
  const html = renderToStaticMarkup(tree)
  assert.ok(html.includes('type="password"') && html.includes('Leave empty to keep the saved password.'))
  assert.ok(html.includes('Open CA certificate') && html.includes('Save IKEv2 changes'))
  assert.ok(html.includes(model.IKEV2_DNS_HINT))
  assert.ok(!html.includes('synthetic-password'))
  tree.props.onSubmit({ preventDefault() {} })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(requests.length, 1)
  assert.equal(requests[0].id, 'stable-id')
  assert.ok(!Object.hasOwn(requests[0].ikev2, 'password'))
  assert.equal(form.states[0].username, '')
})
test('IKEv2 failed saves retain the draft and new profiles require a password', async () => {
  let requests = 0
  const form = loadIkev2Form(undefined, async () => { requests++; return false })
  form.render()
  form.states[0] = { ...ikev2Fixture, password: '' }
  form.render().props.onSubmit({ preventDefault() {} })
  assert.equal(requests, 0)
  assert.equal(form.states[1], 'Enter your IKEv2 password without line breaks.')
  form.states[0] = { ...ikev2Fixture }
  form.render().props.onSubmit({ preventDefault() {} })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(requests, 1)
  assert.equal(form.states[0].password, 'synthetic-password')
})
test('IKEv2 errors and routing explanation have English messages and Russian translations', () => {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(`${__dirname}/../src/locales/ru-vpn.ts`, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, { exports })
  assert.ok(exports.ruVpn[model.IKEV2_ROUTING].includes('мобильное соединение'))
  assert.equal(exports.ruVpn[model.IKEV2_DNS_HINT], 'DNS-сервер профиля доступен через VPN. Без туннеля сайты по имени могут не открываться, даже если LTE работает.')
  for (const [code, message] of Object.entries(exports.vpnErrors).filter(([code]) => code.startsWith('VPN_IKEV2_'))) {
    assert.ok(/^[A-Z]/.test(message), code)
    assert.ok(/[А-Яа-я]/.test(exports.ruVpn[message]), code)
  }
  for (const label of ['Edit IKEv2 profile', 'IKEv2 username', 'IKEv2 password', 'Server certificate identity', 'CA certificate (PEM)', 'VPN DNS server', 'IKEv2 tunnel', 'Connected', 'Disconnected']) assert.ok(exports.ruVpn[label], label)
})
test('active IKEv2 profiles allow explicit reconnect for MFA and editing uses the same profile ID', async () => {
  const exports = {}, states = [], refs = [], requests = []
  const initial = { schema_version: 1, installed: true, enabled: true, core_running: true, ikev2_connected: false, ikev2_state: 'waiting', active_profile: 'stable-id', profiles: [{ id: 'stable-id', name: 'Work VPN', protocol: 'ikev2', transport: 'udp', warnings: [], active: true }] }
  let stateIndex = 0, refIndex = 0
  const Form = () => null
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(`${__dirname}/../src/features/network/VpnTab.tsx`, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX } }).outputText, {
    exports,
    require: name => {
      if (name === 'react') return { ...React, useEffect() {}, useRef(value) { const index = refIndex++; return refs[index] ??= { current: value } }, useState(value) {
        const index = stateIndex++
        if (!(index in states)) states[index] = index === 0 ? initial : value
        return [states[index], value => { states[index] = typeof value === 'function' ? value(states[index]) : value }]
      } }
      if (name === '../../i18n') return { useI18n() {}, translate: value => value }
      if (name === '../../data/client') return { ApiError: Error, async req(method, path, body) {
        requests.push({ method, path, body })
        if (body.action === 'details') return { schema_version: 1, profile: { id: 'stable-id', name: 'Work VPN', proxy: { ...ikev2Fixture, type: 'ikev2', password: undefined, password_set: true }, warnings: [] } }
        return initial
      } }
      if (name === '../../ui/controls') return { Button: ({ loading, ...props }) => React.createElement('button', props), Field: ({ label, children }) => React.createElement('label', {}, label, children), Input: props => React.createElement('input', props) }
      if (name === '../../ui/primitives') return { Card: ({ title, children }) => React.createElement('section', {}, React.createElement('h2', {}, title), children) }
      if (name === '../../ui/feedback') return { toast() {} }
      if (name === './VpnProfileDetails') return exportsObject
      if (name === './Ikev2ProfileForm') return { Ikev2ProfileForm: Form }
      if (name === './vpnModel') return model
      if (name === '../../locales/ru-vpn') return { vpnErrors: {} }
      return require(name)
    },
  })
  function render() { stateIndex = 0; refIndex = 0; return exports.default() }
  function find(tree, predicate) {
    if (!tree || typeof tree !== 'object') return
    if (predicate(tree)) return tree
    for (const child of [tree.props?.children].flat(Infinity)) { const found = find(child, predicate); if (found) return found }
  }
  const button = text => find(render(), node => node.props?.children === text)
  let html = renderToStaticMarkup(render())
  assert.equal(requests.length, 0)
  assert.ok(html.includes('Waiting for connection or push approval'))
  assert.ok(html.includes(model.IKEV2_DNS_HINT))
  assert.ok(html.includes('approve the push in your authentication app'))
  assert.equal(button('Connect').props.disabled, true)
  states[0] = { ...initial, ikev2_state: 'disconnected' }
  assert.equal(button('Connect').props.disabled, false)
  button('Connect').props.onClick()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(requests.length, 1)
  assert.equal(requests[0].body.action, 'activate')
  assert.equal(requests[0].body.id, 'stable-id')
  button('Edit IKEv2 profile').props.onClick()
  await new Promise(resolve => setImmediate(resolve))
  const form = find(render(), node => node.type === Form)
  assert.equal(form.props.profile.id, 'stable-id')
  const draft = model.ikev2Draft(form.props.profile)
  assert.equal(await form.props.onSave(model.ikev2Request(draft)), true)
  assert.equal(requests.length, 3)
  assert.equal(requests[2].body.action, 'save_ikev2')
  assert.equal(requests[2].body.id, 'stable-id')
  assert.ok(!Object.hasOwn(requests[2].body.ikev2, 'password'))
  states[0] = { ...initial, ikev2_connected: true, ikev2_state: 'connected' }
  html = renderToStaticMarkup(render())
  assert.ok(!html.includes('Waiting for connection or push approval'))
  assert.ok(html.includes('Connected'))
  assert.equal(button('Connect').props.disabled, true)
  states[0] = { ...initial, ikev2_state: 'disconnected' }
  html = renderToStaticMarkup(render())
  assert.ok(html.includes('Disconnected'))
  assert.ok(!html.includes('Waiting for connection or push approval'))
})
