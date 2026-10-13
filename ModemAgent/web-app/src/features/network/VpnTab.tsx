import { useEffect, useRef, useState } from 'react'
import { req, ApiError } from '../../data/client'
import { useI18n, translate as t } from '../../i18n'
import { Button, Field, Input } from '../../ui/controls'
import { Card } from '../../ui/primitives'
import { toast } from '../../ui/feedback'
import { VpnProfileDetails, type ProfileDetails } from './VpnProfileDetails'
import { vpnErrors } from '../../locales/ru-vpn'
import { activationConfirmed, profileImport, protocolLabel, updateSubscriptionsSequentially, warningText, type ImportSummary, type SubscriptionUpdate } from './vpnModel'

type Profile = { id: string; name: string; transport: string; warnings: string[]; active: boolean; protocol?: string; subscription_id?: string; update_available?: boolean; removed_from_subscription?: boolean }
type Subscription = { id: string; name: string; host: string; updated_at: string | number; profile_count: number }
type Status = { schema_version: number; installed: boolean; enabled?: boolean; core_running?: boolean;
  configured?: boolean; network_ok?: boolean; ssid?: string; active_profile?: string; recovery_pending?: boolean; screen?: { installed?: boolean; integrated?: boolean; active: boolean; ready: boolean; last_error?: string }; profiles: Profile[]; subscriptions?: Subscription[]; last_import?: ImportSummary }

export default function VpnTab() {
  useI18n()
  const [status, setStatus] = useState<Status | null>(null)
  const [busy, setBusy] = useState(false)
  const [name, setName] = useState('')
  const [uri, setUri] = useState('')
  const [subscriptionUrl, setSubscriptionUrl] = useState('')
  const [subscriptionName, setSubscriptionName] = useState('')
  const [lastImport, setLastImport] = useState<ImportSummary | null>(null)
  const [details, setDetails] = useState<ProfileDetails | null>(null)
  const [editing, setEditing] = useState('')
  const [editedName, setEditedName] = useState('')
  const [error, setError] = useState('')
  const [subscriptionUpdates, setSubscriptionUpdates] = useState<SubscriptionUpdate[]>([])
  const [updatingSubscriptions, setUpdatingSubscriptions] = useState(0)
  const generation = useRef(0)
  const changing = useRef(false)
  function showError(e: unknown) {
    const message = e instanceof ApiError && e.code ? vpnErrors[e.code] : undefined
    setError(message ?? 'VPN settings could not be updated. Refresh the status before retrying.')
  }
  async function refresh() {
    if (changing.current) return
    const ticket = ++generation.current
    try {
      const value = await req('GET', '/api/vpn/status') as unknown as Status
      if (value.schema_version !== 1 || !Array.isArray(value.profiles)) throw new Error('Invalid status')
      if (ticket === generation.current) { setStatus(value) }
    } catch (e) { if (ticket === generation.current) showError(e) }
  }
  useEffect(() => {
    if (busy) return
    const epoch = generation
    void refresh()
    const timer = setInterval(() => void refresh(), 15_000)
    return () => { clearInterval(timer); epoch.current++ }
    // The request and translation helpers do not depend on the selected language.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [busy])
  async function change(body: Record<string, unknown>) {
    if (changing.current) return
    changing.current = true; generation.current++
    setBusy(true); setError('')
    try {
      const value = await req('POST', '/api/vpn/request', body, undefined, 240_000) as unknown as Status
      if (body.action === 'activate' && !activationConfirmed(value, body.id)) {
        setStatus(value); setError('The modem did not confirm profile activation. Refresh status before retrying.'); return
      }
      if (body.action === 'screen_open' || body.action === 'screen_close') {
        setStatus(current => current ? { ...current, screen: value.screen } : current)
      } else setStatus(value)
      if (body.action === 'rename') {
        setEditing('')
        setDetails(current => current && current.profile.id === body.id ? { ...current, profile: { ...current.profile, name: String(body.name).trim() } } : current)
      }
      if (body.action === 'delete') setDetails(current => current?.profile.id === body.id ? null : current)
      if (body.action === 'activate' || body.action === 'subscription_import' || body.action === 'subscription_update') setDetails(null)
      if (value.last_import) setLastImport(value.last_import)
      if (body.action === 'subscription_import') { setSubscriptionUrl(''); setSubscriptionName('') }
      if (body.action === 'import' || body.action === 'import_config') { setUri(''); setName(''); toast(t('VPN profile checked and saved')) }
      else if (body.action === 'screen_open' || body.action === 'screen_close') toast(t('Page selected. Wake and unlock the modem display.'))
      else toast(t('VPN settings saved'))
    } catch (e) { showError(e) }
    finally { changing.current = false; setBusy(false) }
  }
  async function updateAllSubscriptions() {
    if (changing.current || !status?.subscriptions?.length) return
    const subscriptions = status.subscriptions
    changing.current = true; generation.current++
    setBusy(true); setError(''); setDetails(null); setLastImport(null)
    setSubscriptionUpdates([]); setUpdatingSubscriptions(subscriptions.length)
    try {
      await updateSubscriptionsSequentially(subscriptions, async id => {
        const value = await req('POST', '/api/vpn/request', { action: 'subscription_update', id }, undefined, 240_000) as unknown as Status
        if (value.schema_version !== 1 || !Array.isArray(value.profiles) || !value.last_import) throw new Error('Invalid update result')
        setStatus(value)
        return value.last_import
      }, error => error instanceof ApiError && error.code && vpnErrors[error.code] ? error.code : 'VPN_OPERATION_FAILED', setSubscriptionUpdates)
      try {
        const value = await req('GET', '/api/vpn/status') as unknown as Status
        if (value.schema_version !== 1 || !Array.isArray(value.profiles)) throw new Error('Invalid status')
        setStatus(value)
      } catch { setError('Could not refresh the final VPN status. Individual subscription results are shown below.') }
    } finally { changing.current = false; setBusy(false); setUpdatingSubscriptions(0) }
  }
  async function showDetails(id: string) {
    if (changing.current) return
    changing.current = true; generation.current++
    setBusy(true); setError(''); setDetails(null)
    try {
      const value = await req('POST', '/api/vpn/request', { action: 'details', id }) as unknown as ProfileDetails
      if (value.schema_version !== 1 || value.profile?.id !== id || !value.profile.proxy) throw new Error('Invalid profile')
      setDetails(value)
    } catch (e) { showError(e) }
    finally { changing.current = false; setBusy(false) }
  }
  return <div className="space-y-4">
    <Card title={t('VPN settings')}>
      <div className="flex items-start justify-between gap-3">
        <p className="text-[13px] text-ink2">{t('VPN profiles and the separate Wi-Fi network run on this modem. Your computer can be turned off.')}</p>
        <Button onClick={() => void refresh()} disabled={busy}>{t('Refresh')}</Button>
      </div>
      {error && <p className="mt-3 text-[13px] text-danger" role="alert">{t(error)}</p>}
      {status && !status.installed && <p className="mt-3 text-[13px] text-ink2">{t('In ZTE U60Pro Manager for macOS or Windows, check and update the agent and VPN components. Then import a profile here.')}</p>}
    </Card>
    {status?.installed && <>
      <Card title={t('Wi-Fi with VPN')}>
        <div className="space-y-2 text-[13px]">
          <p className="font-semibold text-ink">{status.ssid}</p>
          <p className="text-ink2">{t('Network')}: {status.enabled ? t('Enabled') : t('Disabled')} · {t('VPN core')}: {status.core_running ? t('VPN core running') : t('VPN core stopped')}</p>
          <p className="text-ink2">{t('Copies your main Wi-Fi password during setup. Direct internet access is blocked when the VPN is unavailable. The modem screen can also switch this network on and off.')}</p>
          {status.configured && !status.network_ok && <p className="text-danger">{t('The VPN network configuration needs checking. Keep this network off until it is repaired.')}</p>}
          <div className="flex flex-wrap gap-2 pt-2">
            <Button loading={busy} disabled={!status.active_profile} onClick={() => void change({ action: 'set_enabled', enabled: !status.enabled })}>{status.enabled ? t('Turn off VPN Wi-Fi') : t('Turn on VPN Wi-Fi')}</Button>
            {status.recovery_pending && <Button disabled={busy} onClick={() => void change({ action: 'recover' })}>{t('Restore previous VPN profile')}</Button>}
          </div>
        </div>
      </Card>
      <Card title={t('Profiles on the modem')}>
        {!status.profiles.length && <p className="text-[13px] text-ink2">{t('Import your first VPN profile to begin.')}</p>}
        <div className="divide-y divide-line/10">
          {status.profiles.map(profile => <div key={profile.id} className="flex flex-wrap items-center justify-between gap-3 py-3">
            <div className="min-w-0 flex-1">
              <p className="break-words text-sm font-semibold text-ink">{profile.name}</p>
              <p className="text-xs text-ink2">{profile.active ? t('Active profile') + ' · ' : ''}{protocolLabel(profile.protocol)} · {profile.transport.toUpperCase()}</p>
              {profile.warnings?.map(warningText).filter(Boolean).map(text => <p key={text} className="mt-1 text-xs text-ink2">{t(text!)}</p>)}
              {profile.update_available && <p className="mt-1 text-xs text-ink2">{t('An update is saved. Apply it to reconnect with the new settings.')}</p>}
              {profile.removed_from_subscription && <p className="mt-1 text-xs text-ink2">{t('This profile was removed from the subscription. Your active connection is preserved.')}</p>}
            </div>
            <div className="flex flex-wrap gap-2">
              <Button disabled={busy} onClick={() => void showDetails(profile.id)}>{t('Profile details')}</Button>
              <Button disabled={busy} onClick={() => { setEditing(profile.id); setEditedName(profile.name) }}>{t('Rename')}</Button>
              <Button disabled={busy || (profile.active && !profile.update_available)} onClick={() => void change({ action: 'activate', id: profile.id })}>{t(profile.update_available ? 'Apply update' : 'Activate')}</Button>
              <Button disabled={busy || profile.active} onClick={() => void change({ action: 'delete', id: profile.id })}>{t('Delete')}</Button>
            </div>
            {editing === profile.id && <form className="flex w-full flex-wrap items-end gap-2" onSubmit={e => { e.preventDefault(); void change({ action: 'rename', id: profile.id, name: editedName }) }}>
              <div className="min-w-0 flex-1"><Field label={t('Profile name')}><Input autoFocus value={editedName} onChange={e => setEditedName(e.target.value)} maxLength={64} disabled={busy} /></Field></div>
              <Button type="submit" disabled={busy || !editedName.trim()}>{t('Save')}</Button>
              <Button type="button" disabled={busy} onClick={() => setEditing('')}>{t('Cancel')}</Button>
            </form>}
            {details?.profile.id === profile.id && <VpnProfileDetails value={details} onClose={() => setDetails(null)} />}
          </div>)}
        </div>
      </Card>
      <Card title={t('Import VPN profile')}>
        <form className="space-y-3" onSubmit={e => { e.preventDefault(); void change(profileImport(uri, name)) }}>
          <Field label={t('Profile name (optional)')}><Input value={name} onChange={e => setName(e.target.value)} maxLength={64} disabled={busy} autoComplete="off" /></Field>
          <Field label={t('VPN link or configuration')}><textarea className="min-h-28 w-full rounded-lg border border-line/15 bg-surface p-3 font-mono text-xs text-ink" value={uri} onChange={e => setUri(e.target.value)} placeholder={t('VPN link or configuration')} maxLength={32768} disabled={busy} autoComplete="off" autoCapitalize="none" spellCheck={false} /></Field>
          <Field label={t('Open profile file')}><input type="file" accept=".conf,.txt,text/plain" disabled={busy} onChange={e => {
            const file = e.currentTarget.files?.[0]; e.currentTarget.value = ''
            if (!file) return
            if (file.size > 32768) { setError('Use a UTF-8 profile file no larger than 32 KiB.'); return }
            void file.arrayBuffer().then(bytes => setUri(new TextDecoder('utf-8', { fatal: true }).decode(bytes))).catch(() => setError('Use a UTF-8 profile file no larger than 32 KiB.'))
          }} /></Field>
          <p className="text-xs text-ink2">{t('Supports VLESS and Hysteria2 links, and WireGuard, AmneziaWG 2 and 3.1 files. Import saves a profile; activation is a separate step.')}</p>
          <Button type="submit" variant="primary" loading={busy} disabled={!uri.trim()}>{t('Check and import')}</Button>
        </form>
      </Card>
      <Card title={t('VPN subscriptions')}>
        <div className="mb-3 flex flex-wrap items-center gap-3">
          <Button loading={updatingSubscriptions > 0} disabled={busy || !status.subscriptions?.length} onClick={() => void updateAllSubscriptions()}>{t('Update all subscriptions')}</Button>
          {updatingSubscriptions > 0 && <p className="text-xs text-ink2" role="status">{t('Updating subscriptions')}: {subscriptionUpdates.length}/{updatingSubscriptions}</p>}
        </div>
        <p className="mb-3 text-xs text-ink2">{t('The modem downloads subscriptions using its internet connection. All profiles appear in the shared list.')}</p>
        <form className="space-y-3" onSubmit={e => { e.preventDefault(); void change({ action: 'subscription_import', url: subscriptionUrl, ...(subscriptionName.trim() ? { name: subscriptionName.trim() } : {}) }) }}>
          <Field label={t('HTTPS subscription URL')}><Input type="password" value={subscriptionUrl} onChange={e => setSubscriptionUrl(e.target.value)} disabled={busy} autoComplete="off" autoCapitalize="none" spellCheck={false} maxLength={8192} placeholder={t('HTTPS subscription URL')} /></Field>
          <Field label={t('Subscription name (optional)')}><Input value={subscriptionName} onChange={e => setSubscriptionName(e.target.value)} maxLength={64} disabled={busy} autoComplete="off" /></Field>
          <Button type="submit" variant="primary" disabled={busy || !subscriptionUrl.trim()}>{t('Add subscription')}</Button>
        </form>
        <div className="mt-3 divide-y divide-line/10">{status.subscriptions?.map(subscription => <div key={subscription.id} className="flex flex-wrap items-center justify-between gap-3 py-3">
          <div className="min-w-0"><p className="break-words text-sm font-semibold text-ink">{subscription.name}</p><p className="break-words text-xs text-ink2">{subscription.host} · {t('Profiles')}: {subscription.profile_count}</p></div>
          <div className="flex flex-wrap gap-2">
            <Button disabled={busy} onClick={() => void change({ action: 'subscription_update', id: subscription.id })}>{t('Update subscription')}</Button>
            <Button disabled={busy} onClick={() => void change({ action: 'subscription_delete', id: subscription.id })}>{t('Remove subscription')}</Button>
          </div>
        </div>)}</div>
        <p className="mt-3 text-xs text-ink2">{t('Removing a subscription keeps its profiles. Updating does not interrupt the active VPN connection.')}</p>
        {subscriptionUpdates.length > 0 && <section className="mt-4 space-y-3" aria-label={t('Subscription update results')}>
          <h3 className="text-[13px] font-semibold text-ink">{t('Subscription update results')}</h3>
          {subscriptionUpdates.map(result => <div key={result.id} className="rounded-lg border border-line/10 p-3 text-xs">
            <p className="break-words font-semibold text-ink">{result.name}</p>
            <p className={result.ok ? 'mt-1 text-ink2' : 'mt-1 text-danger'}>{result.ok ? t('Subscription updated') : t(vpnErrors[result.code ?? ''] ?? 'Could not confirm this subscription update. Refresh status before retrying.')}</p>
            {result.import && <p className="mt-1 text-ink2">{t('Added')}: {result.import.added} · {t('Updated')}: {result.import.updated} · {t('Removed')}: {result.import.removed} · {t('Skipped')}: {result.import.skipped.length}</p>}
            {!!result.import?.skipped.length && <details className="mt-2 text-ink2"><summary className="cursor-pointer">{t('Skipped profiles')}</summary>{result.import.skipped.map((entry, i) => <p key={i} className="mt-1">#{entry.index} · {t(vpnErrors[entry.code] ?? 'This subscription entry is unsupported and was skipped.')}</p>)}</details>}
          </div>)}
        </section>}
      </Card>
      {lastImport && <Card title={t('Import result')}>
        <div className="flex flex-wrap gap-x-4 gap-y-1 text-[13px] text-ink2">{([['Added', lastImport.added], ['Updated', lastImport.updated], ['Removed', lastImport.removed], ['Duplicates', lastImport.duplicates], ['Skipped', lastImport.skipped.length]] as const).map(([label, count]) => <p key={label}>{t(label)}: {count}</p>)}</div>
        {lastImport.retained_active > 0 && <p className="mt-2 text-xs text-ink2">{t('Your current connection is preserved. Apply the updated profile separately.')}</p>}
        {lastImport.skipped.map((entry, i) => <p key={i} className="mt-1 text-xs text-ink2">#{entry.index} · {t(vpnErrors[entry.code] ?? 'This subscription entry is unsupported and was skipped.')}</p>)}
      </Card>}
      <Card title={t('Modem display')}>
        <p className="text-[13px] text-ink2">{t('Swipe through five pages in the stock launcher: Home, Settings, About modem, VPN and eSIM. Wake and unlock the display to see a page selected here.')}</p>
        <div className="mt-3 flex flex-wrap gap-2">
          <Button disabled={busy || !status.screen?.ready} onClick={() => void change({ action: 'screen_open', page: 'modem' })}>{t('Show modem information')}</Button>
          <Button disabled={busy || !status.screen?.ready} onClick={() => void change({ action: 'screen_open', page: 'vpn' })}>{t('Show VPN controls')}</Button>
          <Button disabled={busy || !status.screen?.ready} onClick={() => void change({ action: 'screen_open', page: 'esim' })}>{t('Show eSIM controls')}</Button>
          {status.screen?.active && <Button disabled={busy} onClick={() => void change({ action: 'screen_close' })}>{t('Show home screen')}</Button>}
        </div>
        {status.screen?.last_error && <p className="mt-2 text-xs text-danger">{t('The launcher extension is unavailable. Reinstall the display component in ZTE U60Pro Manager.')}</p>}
        {!status.screen?.installed && <p className="mt-2 text-xs text-ink2">{t('Install the display component from VPN settings in ZTE U60Pro Manager.')}</p>}
      </Card>
    </>}
  </div>
}
