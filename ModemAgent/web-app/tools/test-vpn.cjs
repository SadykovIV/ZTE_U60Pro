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
