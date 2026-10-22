import { useState } from 'react'
import { translate as t } from '../../i18n'
import { Button, Field, Input } from '../../ui/controls'
import { IKEV2_DNS_HINT, IKEV2_ROUTING, emptyIkev2Draft, ikev2Draft, ikev2Request, ikev2Validation, type Ikev2Draft } from './vpnModel'
import type { ProfileDetails } from './VpnProfileDetails'

export function Ikev2ProfileForm({ profile, busy, onSave, onCancel }: {
  profile?: ProfileDetails['profile']; busy: boolean
  onSave: (request: Record<string, unknown>) => Promise<boolean>; onCancel: () => void
}) {
  const [draft, setDraft] = useState<Ikev2Draft>(() => profile ? ikev2Draft(profile) : emptyIkev2Draft())
  const [error, setError] = useState('')
  const update = (key: keyof Ikev2Draft, value: string) => setDraft(current => ({ ...current, [key]: value }))
  async function save() {
    const validation = ikev2Validation(draft)
    if (validation) { setError(validation); return }
    setError('')
    if (await onSave(ikev2Request(draft))) { setDraft(emptyIkev2Draft()); onCancel() }
  }
  return <form className="space-y-3" aria-label={t(profile ? 'Edit IKEv2 profile' : 'Add IKEv2 profile')} onSubmit={e => { e.preventDefault(); void save() }}>
    <h3 className="text-sm font-semibold text-ink">{t(profile ? 'Edit IKEv2 profile' : 'Add IKEv2 profile')}</h3>
    <p className="text-xs text-ink2">{t('IKEv2 with EAP-MSCHAPv2 login and a trusted CA certificate. Each profile has its own server and credentials.')}</p>
    <Field label={t('Profile name')}><Input required value={draft.name} onChange={e => update('name', e.target.value)} maxLength={64} disabled={busy} autoComplete="off" /></Field>
    <div className="grid gap-3 sm:grid-cols-2">
      <Field label={t('VPN server address')}><Input required value={draft.server} onChange={e => update('server', e.target.value)} maxLength={253} placeholder={t('VPN server address')} disabled={busy} autoComplete="off" autoCapitalize="none" spellCheck={false} /></Field>
      <Field label={t('Server certificate identity')} hint={t('Leave empty to use the VPN server address. It must match the server certificate.')}><Input value={draft.server_id} onChange={e => update('server_id', e.target.value)} maxLength={253} placeholder={draft.server || 'vpn.example.com'} disabled={busy} autoComplete="off" autoCapitalize="none" spellCheck={false} /></Field>
      <Field label={t('IKEv2 username')}><Input required value={draft.username} onChange={e => update('username', e.target.value)} maxLength={253} disabled={busy} autoComplete="off" autoCapitalize="none" spellCheck={false} /></Field>
      <Field label={t('IKEv2 password')} hint={profile ? t('Leave empty to keep the saved password.') : undefined}><Input type="password" required={!profile} value={draft.password} onChange={e => update('password', e.target.value)} maxLength={1024} disabled={busy} autoComplete="new-password" /></Field>
    </div>
    <Field label={t('CA certificate (PEM)')}><textarea required className="min-h-28 w-full rounded-lg border border-line/15 bg-surface p-3 font-mono text-xs text-ink" value={draft.ca_certificate} onChange={e => update('ca_certificate', e.target.value)} maxLength={65536} placeholder={'-----BEGIN CERTIFICATE-----\n…\n-----END CERTIFICATE-----'} disabled={busy} autoComplete="off" autoCapitalize="none" spellCheck={false} /></Field>
    <Field label={t('Open CA certificate')}><input type="file" accept=".pem,.crt,.cer,text/plain,application/x-pem-file" disabled={busy} onChange={e => {
      const file = e.currentTarget.files?.[0]; e.currentTarget.value = ''
      if (!file) return
      if (file.size > 65536) { setError('Paste or open one CA certificate in PEM format, no larger than 64 KiB.'); return }
      void file.arrayBuffer().then(bytes => { update('ca_certificate', new TextDecoder('utf-8', { fatal: true }).decode(bytes)); setError('') }).catch(() => setError('Paste or open one CA certificate in PEM format, no larger than 64 KiB.'))
    }} /></Field>
    <Field label={t('VPN DNS server')}><Input required value={draft.dns} onChange={e => update('dns', e.target.value)} maxLength={15} placeholder="10.0.2.1" disabled={busy} autoComplete="off" /></Field>
    <p className="text-xs text-ink2">{t(IKEV2_ROUTING)}</p>
    <p className="text-xs text-ink2">{t(IKEV2_DNS_HINT)}</p>
    <p className="text-xs text-ink2">{t('Saving keeps the current connection. Activate the profile or apply its update separately.')}</p>
    <p className="text-xs text-ink2">{t('After starting the connection, approve the push in your authentication app. If the request expires, reconnect.')}</p>
    {error && <p className="text-xs text-danger" role="alert">{t(error)}</p>}
    <div className="flex flex-wrap gap-2">
      <Button type="submit" variant="primary" loading={busy}>{t(profile ? 'Save IKEv2 changes' : 'Save IKEv2 profile')}</Button>
      <Button type="button" disabled={busy} onClick={onCancel}>{t('Cancel')}</Button>
    </div>
  </form>
}
