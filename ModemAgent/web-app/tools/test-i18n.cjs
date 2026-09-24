const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require('typescript')
const sourceRoot = path.join(__dirname, '../src')

function fixture(saved = null, language = 'en-US') {
  const cache = new Map()
  function load(file) {
    const full = path.resolve(sourceRoot, file.endsWith('.ts') ? file : `${file}.ts`)
    if (cache.has(full)) return cache.get(full)
    const exports = {}
    cache.set(full, exports)
    const context = { exports, Intl, localStorage: { getItem: () => saved }, navigator: { language },
      require: (name) => load(path.relative(sourceRoot, path.resolve(path.dirname(full), name))),
    }
    const code = ts.transpileModule(fs.readFileSync(full, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText
    vm.runInNewContext(code, context, { filename: full })
    return exports
  }
  return { i18n: load('i18n-core'), format: load('format') }
}

test('saved browser preference wins; otherwise only Russian browsers default to Russian', () => {
  assert.equal(fixture('en', 'ru-RU').i18n.getLocale(), 'en')
  assert.equal(fixture('ru', 'en-US').i18n.getLocale(), 'ru')
  assert.equal(fixture(null, 'ru').i18n.getLocale(), 'ru')
  assert.equal(fixture(null, 'ru-RU').i18n.getLocale(), 'ru')
  assert.equal(fixture('invalid', 'de-DE').i18n.getLocale(), 'en')
  assert.equal(fixture(null, 'russian').i18n.getLocale(), 'en')
})

test('every Russian translation preserves the English interpolation parameters', () => {
  const { i18n } = fixture()
  const parameters = (text) => [...text.matchAll(/\{([A-Za-z_][A-Za-z_0-9]*)\}/g)].map((match) => match[1]).sort()
  assert.ok(Object.keys(i18n.ru).length > 400)
  for (const [key, value] of Object.entries(i18n.ru)) {
    assert.ok(value.trim(), `Empty Russian translation: ${key}`)
    assert.deepEqual(parameters(value), parameters(key), key)
  }
})

test('all literal t/translate calls in the UI have a Russian catalog entry', () => {
  const { i18n } = fixture()
  const missing = []
  function inspect(directory) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name)
      if (entry.isDirectory()) { if (entry.name !== 'locales') inspect(file); continue }
      if (!/\.tsx?$/.test(file)) continue
      const ast = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true)
      function visit(node) {
        if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && ['t', 'translate'].includes(node.expression.text)) {
          const key = node.arguments[0]
          if (key && ts.isStringLiteral(key) && !Object.hasOwn(i18n.ru, key.text)) missing.push(`${path.relative(sourceRoot, file)}: ${key.text}`)
        }
        ts.forEachChild(node, visit)
      }
      visit(ast)
    }
  }
  inspect(sourceRoot)
  assert.deepEqual(missing, [])
})

test('visible JSX text and attributes contain no untranslated prose', () => {
  // Protocol names, identifiers and technical examples intentionally stay the same in both languages.
  const technicalText = new Set(['ZTE U60 Pro', 'U60 Pro', 'PCI', 'LTE', '+ LTE', 'IPv4', 'IPv6', 'DNS', 'internet', 'PAP', 'CHAP', 'PAP/CHAP', 'IPv4v6', 'MAC', 'SSID', 'SSID:', 'ARFCN', 'RSRP', 'RSRQ', 'SINR', 'RSSI', 'USB', 'PMIC', 'IMEI', 'ICCID', 'IMSI', 'MCC/MNC', 'API', 'AT+COPS?', 'PID', 'English'])
  const untranslated = []
  function inspect(directory) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name)
      if (entry.isDirectory()) { inspect(file); continue }
      if (!file.endsWith('.tsx')) continue
      const ast = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true)
      function record(value, node) {
        const text = value.trim().replace(/\s+/g, ' ')
        if (/[A-Za-z]{3,}/.test(text) && !technicalText.has(text)) untranslated.push(`${path.relative(sourceRoot, file)}:${ast.getLineAndCharacterOfPosition(node.pos).line + 1}: ${text}`)
      }
      function visit(node) {
        if (ts.isJsxText(node)) record(node.text, node)
        if (ts.isJsxAttribute(node) && ['title', 'label', 'body', 'hint', 'placeholder', 'aria-label'].includes(node.name.getText()) && node.initializer && ts.isStringLiteral(node.initializer)) record(node.initializer.text, node)
        ts.forEachChild(node, visit)
      }
      visit(ast)
    }
  }
  inspect(sourceRoot)
  assert.deepEqual(untranslated, [])
})

test('Russian plural forms handle 1, 2, 5, 21, 22 and 25; English handles singular and plural', () => {
  const { i18n } = fixture()
  const expected = ['1 активная несущая', '2 активные несущие', '5 активных несущих', '21 активная несущая', '22 активные несущие', '25 активных несущих']
  ;[1, 2, 5, 21, 22, 25].forEach((count, index) => assert.equal(i18n.translatePlural('active carriers', count, 'ru'), expected[index]))
  assert.equal(i18n.translatePlural('active carriers', 1, 'en'), '1 active carrier')
  assert.equal(i18n.translatePlural('active carriers', 2, 'en'), '2 active carriers')
})

test('interpolation keeps user text intact and never translates unknown technical text', () => {
  const { i18n } = fixture('ru')
  const userText = '<SSID> English {other} & 5G'
  assert.equal(i18n.translate('Peak download: {speed}', { speed: userText }), `Максимум приёма: ${userText}`)
  assert.equal(i18n.translate(userText), userText)
  assert.equal(i18n.translate('Peak download: {speed}'), 'Максимум приёма: {speed}')
  assert.equal(i18n.isKnownMessage(userText), false)
})

test('an already displayed message changes language with its original values intact', () => {
  const { i18n } = fixture('en')
  const original = i18n.translate('Reset day set to day {day}', { day: 22 })
  i18n.setCurrentLocale('ru')
  const russian = i18n.retranslate(original)
  assert.equal(russian, 'Сброс счётчика: 22-е число')
  i18n.setCurrentLocale('en')
  assert.equal(i18n.retranslate(russian), original)
  assert.equal(i18n.retranslate('raw socket error 123'), 'raw socket error 123')
})

test('changing the active locale updates plain helpers, numbers, dates and units', () => {
  const { i18n, format } = fixture('en')
  assert.equal(format.formatBytes(1500000), '1.5 MB')
  assert.equal(format.formatSpeed(1250000), '10.0 Mbps')
  assert.equal(format.formatDuration(61), '1m 1s')
  i18n.setCurrentLocale('ru')
  assert.equal(format.formatBytes(1500000), '1,5 МБ')
  assert.equal(format.formatSpeed(1250000), '10,0 Мбит/с')
  assert.equal(format.formatDuration(61), '1 мин 1 с')
  assert.equal(format.qualityLabel('excellent'), 'Отлично')
  assert.equal(i18n.formatDate(new Date(2026, 8, 22), { day: 'numeric', month: 'long', year: 'numeric' }), '22 сентября 2026 г.')
  i18n.setCurrentLocale('en')
  assert.equal(format.qualityLabel('excellent'), 'Excellent')
})
