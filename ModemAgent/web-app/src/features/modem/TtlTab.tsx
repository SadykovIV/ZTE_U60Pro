import { useCallback, useEffect, useState } from 'react'
import { api } from '../../data/api'
import { ApiError } from '../../data/client'
import type { TtlStatus } from '../../types'
import { useI18n } from '../../i18n'
import { Button, Field, Input, Toggle } from '../../ui/controls'
import { Card, Chip, Spinner } from '../../ui/primitives'
import { toast, toastError } from '../../ui/feedback'

export default function TtlTab() {
  const { t } = useI18n()
  const [status, setStatus] = useState<TtlStatus | null>(null)
  const [outEnabled, setOutEnabled] = useState(false)
  const [inEnabled, setInEnabled] = useState(false)
  const [outValue, setOutValue] = useState('64')
  const [inValue, setInValue] = useState('1')
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<Error | null>(null)
  const [uncertain, setUncertain] = useState(false)

  const accept = useCallback((data: TtlStatus) => {
    if (data.schema_version !== 2) throw new ApiError('Update the modem agent to use these TTL settings.')
    setStatus(data)
    setOutEnabled(data.outbound !== null)
    setInEnabled(data.inbound_inc !== null)
    setOutValue(String(data.outbound ?? 64))
    setInValue(String(data.inbound_inc ?? 1))
    setError(null)
    setUncertain(false)
  }, [])

  const refresh = useCallback(async () => {
    setLoading(true)
    try { accept(await api.ttlStatus()) }
    catch (e) { setError(e instanceof ApiError ? e : new ApiError('Could not read TTL settings.', undefined, undefined, e instanceof Error ? e.message : undefined)) }
    finally { setLoading(false) }
  }, [accept])

  useEffect(() => { void refresh() }, [refresh]) // Language changes never change modem state.

  async function apply() {
    for (const [enabled, value] of [[outEnabled, outValue], [inEnabled, inValue]] as const) {
      if (enabled && (!/^\d{1,3}$/.test(value) || Number(value) < 1 || Number(value) > 255)) {
        toast(t('Enter a whole number from 1 to 255 for each enabled direction.'), 'err')
        return
      }
    }
    setBusy(true)
    setError(null)
    try {
      accept(await api.ttlSet(outEnabled ? Number(outValue) : null, inEnabled ? Number(inValue) : null))
      toast(t('TTL settings saved on the modem.'))
    } catch (e) {
      setError(e instanceof ApiError ? e : new ApiError('Could not save TTL settings.', undefined, undefined, e instanceof Error ? e.message : undefined))
      setUncertain(true)
      toastError(e)
    } finally { setBusy(false) }
  }

  const available = status !== null && status.capability === 'supported' && !error && !uncertain && !loading
  const stateLabel = status?.state === 'configured' ? t('Rules installed')
    : status?.state === 'disabled' ? t('Disabled') : status?.state === 'unsupported' ? t('Unavailable') : t('Check required')

  return (
    <Card title={t('IPv4 TTL')} action={
      <Button size="sm" disabled={busy || loading} onClick={() => void refresh()}>
        {loading && <Spinner size={12} />}{t('Refresh status')}
      </Button>
    }>
      <div className="space-y-5">
        <p className="text-[13px] leading-relaxed text-ink2">{t('These settings are shared with the Mac app and saved on the modem. IPv6 is unchanged.')}</p>
        {loading && !status && <p className="flex items-center gap-2 text-sm text-ink2"><Spinner />{t('Reading TTL settings…')}</p>}
        {status && <div className="flex flex-wrap items-center gap-2">
          <Chip tone={status.state === 'configured' ? 'ok' : 'default'}>{stateLabel}</Chip>
          {status.persistence === 'boot' && <Chip>{t('Applies after restart')}</Chip>}
        </div>}
        {status?.state === 'error' && <p role="alert" className="text-[13px] text-warn">{t('Saved TTL settings do not match the active rules or startup configuration. Apply the settings again to repair them.')}</p>}
        {error && <div role="alert" className="rounded-lg border border-danger/25 bg-danger/5 p-3 text-[13px] text-danger">
          {error.message}
          {error instanceof ApiError && error.details && <details className="mt-2"><summary>{t('Technical details')}</summary><pre className="mt-1 whitespace-pre-wrap break-all text-xs">{error.details}</pre></details>}
          {uncertain && <p className="mt-1">{t('The result is uncertain. Refresh the status before making another change.')}</p>}
        </div>}
        <div className="grid gap-5 sm:grid-cols-2">
          <div className="space-y-3 rounded-lg border border-line/10 p-3">
            <div className="flex items-center justify-between gap-3"><h3 className="text-sm font-semibold">{t('Outgoing TTL')}</h3>
              <Toggle label={t('Set outgoing TTL')} checked={outEnabled} onChange={setOutEnabled} disabled={!available || busy} />
            </div>
            <p className="min-h-10 text-xs leading-relaxed text-ink2">{t('Set an exact TTL for IPv4 packets sent to the mobile network, including traffic from the modem.')}</p>
            <Field label={t('Exact value')}><Input inputMode="numeric" type="number" min={1} max={255} step={1} value={outValue} onChange={e => setOutValue(e.target.value)} disabled={!available || busy || !outEnabled} /></Field>
          </div>
          <div className="space-y-3 rounded-lg border border-line/10 p-3">
            <div className="flex items-center justify-between gap-3"><h3 className="text-sm font-semibold">{t('Incoming TTL')}</h3>
              <Toggle label={t('Increase incoming TTL')} checked={inEnabled} onChange={setInEnabled} disabled={!available || busy} />
            </div>
            <p className="min-h-10 text-xs leading-relaxed text-ink2">{t('Add N to incoming IPv4 TTL on its way to LAN clients. +1 offsets the normal routing decrement; the result cannot exceed 255.')}</p>
            <Field label={t('Increment (+N)')}><Input inputMode="numeric" type="number" min={1} max={255} step={1} value={inValue} onChange={e => setInValue(e.target.value)} disabled={!available || busy || !inEnabled} /></Field>
          </div>
        </div>
        <p className="text-xs leading-relaxed text-ink3">{t('An off switch leaves that direction unchanged. Software packet processing may reduce throughput. Status checks confirm rules, not packet measurements.')}</p>
        <div className="flex flex-wrap items-center gap-3"><Button variant="primary" loading={busy} disabled={!available} onClick={() => void apply()}>{t('Apply')}</Button>
          <span className="text-xs text-ink3">{t('Both directions are saved together.')}</span>
        </div>
      </div>
    </Card>
  )
}
