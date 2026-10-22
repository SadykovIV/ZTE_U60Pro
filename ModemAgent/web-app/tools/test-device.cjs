const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const ts = require('typescript')
const React = require('react')
const { renderToStaticMarkup } = require('react-dom/server')

function load(file, dependencies = {}, globals = {}) {
  const exports = {}
  const source = fs.readFileSync(`${__dirname}/../src/${file}`, 'utf8')
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX,
  } }).outputText, {
    exports, require: name => dependencies[name] ?? require(name), ...globals,
  })
  return exports
}

function fixtureApi(device) {
  return load('data/api.ts', { './client': { get: async path => {
    if (path === '/api/device') return device
    if (path === '/api/dashboard') return { device, sources: { firmware: { stale: false } } }
    throw new Error(`Unexpected fixture request: ${path}`)
  } } }).api
}

const kernel = 'Linux version 5.15.194-perf+ (fixture@builder) #1 SMP PREEMPT'
const versions = {
  integrate_version: 'CN_ZTE_MU5250V1.0.0B31',
  wa_inner_version: 'BD_CNMU5250V1.0.0B31',
}

test('dashboard and device retain real firmware labels and separate the kernel release', async () => {
  for (const firmware of ['CN_ZTE_MU5250V1.0.0B31', 'BD_FLYMU5250V1.0.0B28', 'XCBZ_HK_MU5250V1.0.0B04']) {
    const api = fixtureApi({ ...versions, integrate_version: firmware, kernel, uptime_secs: 42, load_avg: [0.1, 0.2, 0.3], imei: 'PRIVATE_IDENTIFIER_CANARY' })
    const device = await api.device()
    const home = await api.home()
    assert.equal(device.firmware, firmware)
    assert.equal(device.internal_firmware, versions.wa_inner_version)
    assert.equal(device.kernel, '5.15.194-perf+')
    assert.equal(device.uptime_secs, 42)
    assert.deepEqual(Array.from(device.load_avg), [0.1, 0.2, 0.3])
    assert.deepEqual(home.device, device)
    assert.equal(home.sources.firmware.stale, false)
    assert.ok(!JSON.stringify(device).includes('PRIVATE_IDENTIFIER_CANARY'))
  }
})

test('old agents and missing firmware never relabel kernel or internal firmware as firmware', async () => {
  for (const raw of [{ kernel }, { kernel, integrate_version: null, wa_inner_version: null }, { kernel, wa_inner_version: versions.wa_inner_version }]) {
    const api = fixtureApi(raw)
    const device = await api.device()
    assert.equal(device.firmware, undefined)
    assert.equal(device.kernel, '5.15.194-perf+')
    assert.equal(device.internal_firmware, raw.wa_inner_version ?? undefined)
    assert.deepEqual((await api.home()).device, device)
  }
})

test('malformed version fields are rejected independently while supported labels are trimmed', async () => {
  for (const bad of [null, 5, {}, [], '', '   ', 'B31\n', 'B31\r', 'B31\r\n', 'B31\0hidden', 'B31\u202e', 'x'.repeat(257)]) {
    const device = await fixtureApi({ kernel, integrate_version: bad, wa_inner_version: versions.wa_inner_version }).device()
    assert.equal(device.firmware, undefined)
    assert.equal(device.internal_firmware, versions.wa_inner_version)
    assert.equal(device.kernel, '5.15.194-perf+')
  }
  const device = await fixtureApi({ integrate_version: ` ${versions.integrate_version} `, kernel: {} }).device()
  assert.equal(device.firmware, versions.integrate_version)
  assert.equal(device.kernel, undefined)
})

function renderDevicePage(page, device) {
  const i18n = { translate: value => value, formatNumber: String }
  i18n.useI18n = () => ({ t: i18n.translate, tp: value => value, formatNumber: String })
  const primitives = load('ui/primitives.tsx', { '../i18n': i18n })
  const format = load('format.ts', { './i18n-core': i18n })
  const empty = () => null
  const icons = Object.fromEntries(['IActivity', 'IBolt', 'IDownload', 'IRadio', 'IUpload', 'ILogout', 'IPower', 'IRefresh', 'IRestart'].map(name => [name, empty]))
  let stateIndex = 0
  const component = load(page, {
    '../../i18n': i18n, '../../format': format, '../../icons': icons,
    '../../ui/primitives': primitives,
    '../../app/HomeContext': { useHome: () => ({ data: { device } }) },
    react: { ...React, useEffect() {}, useCallback: fn => fn, useState: value => [stateIndex++ === 0 ? device : value, () => {}] },
    '../../data/api': { api: new Proxy({}, { get() { throw new Error('No network during render') } }) },
    '../../data/client': { API_BASE: 'http://fixture.invalid' },
    '../../ui/controls': { Button: ({ children }) => React.createElement('button', {}, children), Toggle: empty },
    '../../ui/feedback': {}, './TechnicalError': { TechnicalError: empty },
  }, { window: { location: { origin: 'http://fixture.invalid' } } }).default
  return renderToStaticMarkup(React.createElement(component, { onLogout() {} }))
}

for (const page of ['features/home/HomePage.tsx', 'features/system/SettingsTab.tsx']) {
  test(`${page} renders firmware and kernel in distinct wrapping rows`, async () => {
    const html = renderDevicePage(page, await fixtureApi({ ...versions, kernel }).device())
    assert.match(html, /Firmware<\/span><span class="[^"]*break-all[^"]*">CN_ZTE_MU5250V1\.0\.0B31<\/span>/)
    assert.match(html, /Kernel<\/span><span class="[^"]*break-all[^"]*">5\.15\.194-perf\+<\/span>/)
    if (page.includes('SettingsTab')) assert.match(html, /Internal firmware<\/span><span class="[^"]*break-all[^"]*">BD_CNMU5250V1\.0\.0B31<\/span>/)
    const missing = renderDevicePage(page, await fixtureApi({ kernel }).device())
    assert.match(missing, /Firmware<\/span><span class="[^"]*">—<\/span>/)
    assert.match(missing, /Kernel<\/span><span class="[^"]*">5\.15\.194-perf\+<\/span>/)
  })
}
