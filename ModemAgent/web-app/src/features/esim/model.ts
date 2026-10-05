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
export type CardReason = 'busy' | 'open_rejected' | 'cleanup_unknown' | 'not_ready' | 'unsupported_device' | 'read_failed' | 'operation_failed'
export type CardStatus = { kind: 'ordinary_sim'; management: 'unavailable'; reason: 'isdr_not_found'; cleanup_confirmed: true } | { kind: 'euicc_confirmed'; management: 'available'; reason: 'eid_and_profiles_read'; cleanup_confirmed: true } |
  { kind: 'unknown'; management: 'unknown'; reason: CardReason; cleanup_confirmed: false }
export interface EsimResult { ok: boolean; snapshot?: Snapshot; changed?: boolean; notifications_pending?: boolean; modem_verified?: boolean; radio_restored?: boolean; error?: string; component_error?: unknown; card?: unknown }
export const unknownCard = (reason: CardReason = 'read_failed'): CardStatus => ({ kind: 'unknown', management: 'unknown', reason, cleanup_confirmed: false })
export class EsimOperationError extends Error {
  readonly card: CardStatus
  constructor(code: string, card: CardStatus = unknownCard()) { super(code); this.card = card }
}
/** An omitted field supports older agents; a present field must match the full contract. */
export function parsedCard(value: unknown, successful: boolean): CardStatus | undefined {
  if (value === undefined) return undefined
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).sort().join(',') !== 'cleanup_confirmed,kind,management,reason') throw new Error('unconfirmed')
  const card = value as Record<string, unknown>
  if (successful && card.kind === 'euicc_confirmed' && card.management === 'available' && card.reason === 'eid_and_profiles_read' && card.cleanup_confirmed === true) {
    return { kind: 'euicc_confirmed', management: 'available', reason: 'eid_and_profiles_read', cleanup_confirmed: true }
  }
  if (successful && card.kind === 'ordinary_sim' && card.management === 'unavailable' && card.reason === 'isdr_not_found' && card.cleanup_confirmed === true) return { kind: 'ordinary_sim', management: 'unavailable', reason: 'isdr_not_found', cleanup_confirmed: true }
  if (!successful && card.kind === 'unknown' && card.management === 'unknown' && card.cleanup_confirmed === false &&
      typeof card.reason === 'string' && ['busy', 'open_rejected', 'cleanup_unknown', 'not_ready', 'unsupported_device', 'read_failed', 'operation_failed'].includes(card.reason)) {
    return unknownCard(card.reason as CardReason)
  }
  throw new Error('unconfirmed')
}
export function verifiedCard(request: EsimRequest, result: EsimResult): { snapshot: Snapshot | null; card: CardStatus } {
  const card = parsedCard(result.card, result.ok === true)
  if (card?.kind === 'ordinary_sim') {
    if (request.operation !== 'list' || result.ok !== true || 'snapshot' in result || 'error' in result || 'component_error' in result || 'modem_verified' in result || 'radio_restored' in result || result.changed !== false || result.notifications_pending !== false) throw new Error('unconfirmed')
    return { snapshot: null, card }
  }
  // In particular, a legacy success is not inferred from EID or metadata alone.
  const snapshot = verifiedResult(request, result)
  return { snapshot, card: parsedCard(result.card, true) ?? { kind: 'euicc_confirmed', management: 'available', reason: 'eid_and_profiles_read', cleanup_confirmed: true } }
}
export function cardMessage(card: CardStatus | null, checking: boolean): string {
  if (checking) return 'Checking the SIM card and profiles…'
  if (!card) return 'Card type has not been checked.'
  if (card.kind === 'euicc_confirmed') return 'eUICC confirmed: EID and profiles were read, and the card channel was closed.'
  if (card.kind === 'ordinary_sim') return 'Ordinary SIM: eSIM management is unavailable.'
  return 'Card type is unknown. This response does not identify an ordinary SIM card.'
}
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
  if (parsedCard(result.card, true)?.kind === 'ordinary_sim') throw new Error('unconfirmed')
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
