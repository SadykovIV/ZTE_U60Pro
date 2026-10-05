import { req } from '../../data/client'
import { EsimOperationError, parsedCard, unknownCard, verifiedCard, type CardStatus, type EsimRequest, type EsimResult, type Snapshot } from './model'
import { journalEntry, resultDiagnostic } from './journal'
import { safeEsimErrors } from './errors'

interface Job { job_id: string; state: 'running' | 'complete'; stage?: string; result?: EsimResult | null; logs?: unknown[] }
export const capabilities = () => req('GET', '/api/esim/capabilities')
export async function runOperation(request: EsimRequest, progress: (stage: string, safeLog?: string) => void, signal: AbortSignal): Promise<{ snapshot: Snapshot | null; card: CardStatus; pending: boolean }> {
  // Never retry POST after an ambiguous network outcome.
  const bytes = new Uint8Array(16)
  window.crypto.getRandomValues(bytes)
  const request_id = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('')
  let job = await req('POST', '/api/esim/jobs', { request_id, request }) as unknown as Job
  if (!/^[a-f0-9]{32}$/.test(job.job_id)) throw new Error('invalid_job')
  const jobID = job.job_id, deadline = Date.now() + 20 * 60_000
  let sequence = -1
  function consumeLogs(value: Job) {
    if (!Array.isArray(value.logs)) return
    for (const item of value.logs.slice(-256)) {
      const line = journalEntry(item)
      if (line && line.seq > sequence) { sequence = line.seq; progress(value.stage ?? '', line.text) }
    }
  }
  consumeLogs(job)
  while (job.state === 'running') {
    if (signal.aborted || Date.now() > deadline) throw new Error('unconfirmed')
    progress(job.stage ?? '')
    await new Promise<void>(resolve => {
      const done = () => { clearTimeout(timer); signal.removeEventListener('abort', done); resolve() }
      const timer = setTimeout(done, 750)
      signal.addEventListener('abort', done, { once: true })
    })
    if (signal.aborted) throw new Error('unconfirmed')
    job = await req('GET', `/api/esim/jobs/${jobID}`) as unknown as Job
    if (job.job_id !== jobID) throw new Error('invalid_job')
    consumeLogs(job)
  }
  if (job.state !== 'complete' || !job.result) throw new Error('unconfirmed')
  const diagnostic = resultDiagnostic(job.result)
  if (diagnostic) progress('cleanup', diagnostic)
  if (job.result.ok === false) {
    const card = parsedCard(job.result.card, false) ?? unknownCard('operation_failed')
    const code = typeof job.result.error === 'string' && safeEsimErrors.has(job.result.error) ? job.result.error : 'unconfirmed'
    throw new EsimOperationError(code, card)
  }
  return { ...verifiedCard(request, job.result), pending: job.result.notifications_pending === true }
}
