import process from 'node:process'

const required = '^20.19.0 || >=22.12.0'
const version = process.argv[2] ?? process.versions.node
const match = /^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(version)

if (!match) {
  console.error(`Unable to parse Node.js version "${version}"; required ${required}.`)
  process.exit(1)
}

const [, majorText, minorText] = match
const major = Number(majorText)
const minor = Number(minorText)
const supported = (major === 20 && minor >= 19)
  || (major === 22 && minor >= 12)
  || major > 22

if (!supported) {
  console.error(`Unsupported Node.js ${version}; dashboard builds require ${required}.`)
  process.exit(1)
}

console.log(`Node.js ${version} satisfies ${required}.`)
