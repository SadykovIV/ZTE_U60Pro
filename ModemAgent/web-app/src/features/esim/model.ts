export interface Profile {
  iccid: string; isdp_aid: string | null; state: 'enabled' | 'disabled' | 'unknown'; enabled: boolean
  nickname: string | null; service_provider: string | null; name: string | null
}
export interface Snapshot { ok: true; eid: string; profiles: Profile[] }
export type Operation = 'list' | 'download' | 'enable' | 'delete'
export interface EsimRequest {
  protocol: 1; operation: Operation; expected_snapshot?: Snapshot; activation_code?: string
  confirmation_code?: string; iccid?: string; confirm_delete?: true
}
export interface EsimResult { ok: boolean; snapshot?: Snapshot; changed?: boolean; notifications_pending?: boolean; modem_verified?: boolean; radio_restored?: boolean; error?: string; component_error?: unknown }
export function domain(value: string): boolean {
  return value.length <= 253 && value.includes('.') && /[a-zA-Z]/.test(value.split('.').at(-1) ?? '') &&
    value.split('.').every(part => /^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/.test(part))
}
export function activation(value: string): string {
  const code = value.trim()
  const fields = code.split('$')
  if (code.length > 512 || fields.length < 3 || !/^[\x21-\x7e]+$/.test(code) || fields[0] !== 'LPA:1' ||
      !domain(fields[1]) || !/^[\x21-\x23\x25-\x7e]+$/.test(fields[2])) throw new Error('invalid_code')
  return code
}
export function compose(address: string, matchingID: string): string {
  let host = address.trim()
  if (/^https:\/\//i.test(host)) {
    const url = new URL(host)
    if (url.username || url.password || url.search || url.hash || url.pathname !== '/' || url.port) throw new Error('invalid_address')
    host = url.hostname
  }
  if (!domain(host) || !/^[\x21-\x23\x25-\x7e]+$/.test(matchingID)) throw new Error('invalid_address')
  return activation(`LPA:1$${host.toLowerCase()}$${matchingID}`)
}
export function validSnapshot(value: unknown): value is Snapshot {
  if (!value || typeof value !== 'object') return false
  const s = value as Snapshot
  if (s.ok !== true || typeof s.eid !== 'string' || !/^\d{32}$/.test(s.eid) || !Array.isArray(s.profiles) || s.profiles.length > 1024) return false
  const ids = new Set<string>(), aids = new Set<string>()
  return s.profiles.every(p => {
    if (!p || typeof p.iccid !== 'string' || !/^\d{18,20}$/.test(p.iccid) || ids.has(p.iccid) || !['enabled', 'disabled', 'unknown'].includes(p.state) || p.enabled !== (p.state === 'enabled')) return false
    ids.add(p.iccid)
    if (p.isdp_aid !== null) {
      if (typeof p.isdp_aid !== 'string' || !/^(?:[a-fA-F0-9]{2}){1,32}$/.test(p.isdp_aid) || aids.has(p.isdp_aid.toLowerCase())) return false
      aids.add(p.isdp_aid.toLowerCase())
    }
    return [p.name, p.nickname, p.service_provider].every(v => v === null || typeof v === 'string' && v.length <= 4096)
  })
}
export const mask = (id: string) => id.slice(0, 4) + '••••' + id.slice(-4)
export const profileName = (p: Profile) => p.nickname || p.name || p.service_provider || mask(p.iccid)
export function verifiedResult(request: EsimRequest, result: EsimResult): Snapshot {
  if (result.ok !== true || result.component_error !== undefined || !validSnapshot(result.snapshot)) throw new Error('unconfirmed')
  const after = result.snapshot, before = request.expected_snapshot
  if (request.operation === 'list') return after
  if (!before || before.eid !== after.eid || typeof result.changed !== 'boolean' || request.operation !== 'enable' && !result.changed) throw new Error('unconfirmed')
  const identity = (p: Profile) => `${p.iccid}:${(p.isdp_aid ?? '').toLowerCase()}`
  const inventory = (p: Profile) => `${identity(p)}:${p.state}`
  const same = (a: string[], b: string[]) => JSON.stringify(a.sort()) === JSON.stringify(b.sort())
  if (request.operation === 'download') {
    const added = after.profiles.filter(p => !before.profiles.some(b => b.iccid === p.iccid))
    if (added.length !== 1 || added[0].state !== 'disabled' || !same(before.profiles.map(inventory), after.profiles.filter(p => p !== added[0]).map(inventory))) throw new Error('unconfirmed')
  } else if (request.operation === 'enable') {
    const selected = before.profiles.find(p => p.iccid === request.iccid)
    if (!selected || result.changed !== !selected.enabled || result.modem_verified !== true || result.radio_restored !== true || !same(before.profiles.map(identity), after.profiles.map(identity)) ||
      !after.profiles.every(p => p.state === (p.iccid === request.iccid ? 'enabled' : 'disabled'))) throw new Error('unconfirmed')
  } else if (!before.profiles.some(p => p.iccid === request.iccid && p.state === 'disabled') || after.profiles.some(p => p.iccid === request.iccid) ||
    !same(before.profiles.filter(p => p.iccid !== request.iccid).map(inventory), after.profiles.map(inventory))) throw new Error('unconfirmed')
  return after
}
