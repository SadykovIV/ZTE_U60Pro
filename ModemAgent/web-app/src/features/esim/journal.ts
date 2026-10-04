import { componentError, safeEsimErrors } from './errors'
const messages: Record<string, string> = {
  checking_card: 'Checking the SIM card and profiles…', reading_profiles: 'Reading all card profiles…',
  downloading: 'Downloading the profile…', enabling: 'Enabling the selected profile…',
  deleting: 'Deleting the profile…', notifications: 'Sending operator notifications…',
  verifying: 'Verifying card state…', cleanup: 'Closing the card channel…',
  radio_offline: 'Entering flight mode to reread the SIM…', radio_online: 'Radio is online; rereading the SIM…',
  reading_modem: 'Verifying the selected profile in the modem…',
}
const stages = new Set(Object.keys(messages))
export const stageMessage = (stage: string): string => Object.prototype.hasOwnProperty.call(messages, stage) ? messages[stage] : 'The agent is processing the eUICC operation…'
const events = new Set(['stage','waiting','component_start','component_exit','apdu_sent','apdu_reply','http_start','http_end','cleanup_start','cleanup_end'])
const components = new Set(['snapshot','bridge','lpac'])
const waits = new Set(['card','operator_https','cleanup'])
const safeInt = (value: unknown, max = Number.MAX_SAFE_INTEGER): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= max
export interface JournalEntry { seq: number; text: string }

// Build from typed allowlisted fields. Never stringify dependency diagnostics,
// URLs, profile identifiers, request bodies, activation codes or APDU bytes.
export function journalEntry(value: unknown): JournalEntry | null {
  if (!value || typeof value !== 'object') return null
  const v = value as Record<string, unknown>
  if (v.type !== 'progress' || typeof v.stage !== 'string' || !stages.has(v.stage) || !v.detail || typeof v.detail !== 'object') return null
  const d = v.detail as Record<string, unknown>
  if (typeof d.event !== 'string' || !events.has(d.event) || !safeInt(d.elapsed_ms, 86_400_000) || !safeInt(d.log_seq)) return null
  const parts = [`${(d.elapsed_ms / 1000).toFixed(1)}s`, v.stage, d.event]
  if (typeof d.component === 'string' && components.has(d.component)) parts.push(d.component)
  if (typeof d.waiting_for === 'string' && waits.has(d.waiting_for)) parts.push(`waiting=${d.waiting_for}`)
  for (const key of ['apdu_count','http_count','duration_ms','request_bytes','response_bytes','http_status']) {
    if (safeInt(d[key], key === 'http_status' ? 599 : 100_000_000)) parts.push(`${key}=${d[key]}`)
  }
  if (d.outcome === 'ok' || d.outcome === 'failed') parts.push(`outcome=${d.outcome}`)
  if (typeof d.error === 'string' && safeEsimErrors.has(d.error)) parts.push(`error=${d.error}`)
  return { seq: d.log_seq, text: parts.join(' · ') }
}

export function resultDiagnostic(value: unknown): string | null {
  if (!value || typeof value !== 'object') return null
  const result = value as Record<string, unknown>
  if (result.ok !== false) return null
  const error = typeof result.error === 'string' && safeEsimErrors.has(result.error) ? result.error : 'unconfirmed'
  const cause = componentError(result.component_error)
  return `result · error=${error}${cause ? ` · component_error=${cause}` : ''}`
}
