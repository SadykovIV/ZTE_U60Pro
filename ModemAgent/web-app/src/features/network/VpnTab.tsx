import { useEffect, useRef, useState } from 'react'
import { req, ApiError } from '../../data/client'
import { useI18n, translate as t } from '../../i18n'
import { Button, Field, Input } from '../../ui/controls'
import { Card } from '../../ui/primitives'
import { toast } from '../../ui/feedback'
import { VpnProfileDetails, type ProfileDetails } from './VpnProfileDetails'
import { vpnErrors } from '../../locales/ru-vpn'

type Profile = { id: string; name: string; transport: string; warnings: string[]; active: boolean }
type Status = { schema_version: number; installed: boolean; enabled?: boolean; core_running?: boolean;
  configured?: boolean; network_ok?: boolean; ssid?: string; active_profile?: string; recovery_pending?: boolean; screen?: { installed?: boolean; integrated?: boolean; active: boolean; ready: boolean; last_error?: string }; profiles: Profile[] }

export default function VpnTab() {
  useI18n()
  const [status, setStatus] = useState<Status | null>(null)
  const [busy, setBusy] = useState(false)
  const [name, setName] = useState('')
  const [uri, setUri] = useState('')
  const [details, setDetails] = useState<ProfileDetails | null>(null)
  const [editing, setEditing] = useState('')
  const [editedName, setEditedName] = useState('')
  const [error, setError] = useState('')
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
      if (body.action === 'screen_open' || body.action === 'screen_close') {
        setStatus(current => current ? { ...current, screen: value.screen } : current)
      } else setStatus(value)
      if (body.action === 'rename') {
        setEditing('')
        setDetails(current => current && current.profile.id === body.id ? { ...current, profile: { ...current.profile, name: String(body.name).trim() } } : current)
      }
      if (body.action === 'delete') setDetails(current => current?.profile.id === body.id ? null : current)
      if (body.action === 'import') { setUri(''); setName(''); toast(t('VPN profile checked and saved')) }
      else if (body.action === 'screen_open' || body.action === 'screen_close') toast(t('Page selected. Wake and unlock the modem display.'))
      else toast(t('VPN settings saved'))
    } catch (e) { showError(e) }
    finally { changing.current = false; setBusy(false) }
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
      {status && !status.installed && <p className="mt-3 text-[13px] text-ink2">{t('Open VPN settings in ZTE IMEI Studio, check the components and click Install required components. Then import a profile here.')}</p>}
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
              <p className="text-xs text-ink2">{profile.active ? t('Active profile') + ' · ' : ''}{profile.transport.toUpperCase()}</p>
              {profile.warnings?.length > 0 && <p className="mt-1 text-xs text-ink2">{t('The spx parameter is preserved in the source link but is not used by this VPN core.')}</p>}
            </div>
            <div className="flex flex-wrap gap-2">
              <Button disabled={busy} onClick={() => void showDetails(profile.id)}>{t('Profile details')}</Button>
              <Button disabled={busy} onClick={() => { setEditing(profile.id); setEditedName(profile.name) }}>{t('Rename')}</Button>
              <Button disabled={busy || profile.active} onClick={() => void change({ action: 'activate', id: profile.id })}>{t('Activate')}</Button>
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
        <form className="space-y-3" onSubmit={e => { e.preventDefault(); void change({ action: 'import', uri, ...(name.trim() ? { name: name.trim() } : {}) }) }}>
          <Field label={t('Profile name (optional)')}><Input value={name} onChange={e => setName(e.target.value)} maxLength={64} disabled={busy} autoComplete="off" /></Field>
          <Field label={t('VLESS link')}><Input type="text" value={uri} onChange={e => setUri(e.target.value)} placeholder={t('VLESS link')} maxLength={32768} disabled={busy} autoComplete="off" autoCapitalize="none" spellCheck={false} /></Field>
          <p className="text-xs text-ink2">{t('Supports VLESS with TCP, WebSocket, gRPC and XHTTP, including REALITY. Import checks and saves a profile; activation is a separate step.')}</p>
          <Button type="submit" variant="primary" loading={busy} disabled={!uri.trim()}>{t('Check and import')}</Button>
        </form>
      </Card>
      <Card title={t('Modem display')}>
        <p className="text-[13px] text-ink2">{t('Swipe through five pages in the stock launcher: Home, Settings, About modem, VPN and eSIM. Wake and unlock the display to see a page selected here.')}</p>
        <div className="mt-3 flex flex-wrap gap-2">
          <Button disabled={busy || !status.screen?.ready} onClick={() => void change({ action: 'screen_open', page: 'modem' })}>{t('Show modem information')}</Button>
          <Button disabled={busy || !status.screen?.ready} onClick={() => void change({ action: 'screen_open', page: 'vpn' })}>{t('Show VPN controls')}</Button>
          <Button disabled={busy || !status.screen?.ready} onClick={() => void change({ action: 'screen_open', page: 'esim' })}>{t('Show eSIM controls')}</Button>
          {status.screen?.active && <Button disabled={busy} onClick={() => void change({ action: 'screen_close' })}>{t('Show home screen')}</Button>}
        </div>
        {status.screen?.last_error && <p className="mt-2 text-xs text-danger">{t('The launcher extension is unavailable. Reinstall the display component in ZTE IMEI Studio.')}</p>}
        {!status.screen?.installed && <p className="mt-2 text-xs text-ink2">{t('Install the display component from VPN settings in ZTE IMEI Studio.')}</p>}
      </Card>
    </>}
  </div>
}
