import { translate as t } from '../../i18n'
import { Button } from '../../ui/controls'

export type ProfileDetails = { schema_version: number; active: boolean; profile: {
  id: string; name: string; proxy: Record<string, unknown>; source_uri: string; warnings: string[]
} }

export function VpnProfileDetails({ value, onClose }: { value: ProfileDetails; onClose: () => void }) {
  const { profile } = value
  const proxy = profile.proxy
  const labels: Record<string, string> = {
    type: t('Protocol'), server: t('Server'), port: t('Port'), uuid: t('VLESS identifier'),
    network: t('Transport'), tls: t('TLS'), servername: t('Server name (SNI)'),
    'client-fingerprint': t('Client fingerprint'), flow: t('Flow'), encryption: t('Encryption'),
    'reality-opts': t('REALITY settings'), 'xhttp-opts': t('XHTTP settings'),
    'ws-opts': t('WebSocket settings'), 'grpc-opts': t('gRPC settings'), udp: t('UDP'),
    'packet-encoding': t('Packet encoding'), 'skip-cert-verify': t('Skip certificate verification'),
  }
  return <section className="w-full min-w-0 space-y-3 rounded-xl bg-surface2/60 p-4" aria-label={t('Profile details')}>
    <div className="flex items-center justify-between gap-2">
      <h3 className="text-sm font-semibold text-ink">{t('Profile details')}</h3>
      <Button onClick={onClose}>{t('Close')}</Button>
    </div>
    <dl className="space-y-2 text-[13px]">
      {Object.entries(proxy).filter(([key]) => key !== 'name').map(([key, item]) => <div key={key} className="grid gap-1 border-b border-line/10 pb-2 sm:grid-cols-[160px_minmax(0,1fr)]">
        <dt className="text-ink2">{labels[key] ?? key}</dt>
        <dd className="min-w-0 whitespace-pre-wrap break-all font-mono text-ink">{typeof item === 'boolean' ? (item ? t('Yes') : t('No')) : typeof item === 'object' ? JSON.stringify(item, null, 2) : String(item)}</dd>
      </div>)}
    </dl>
    <label className="block text-xs font-semibold text-ink2">
      {t('Original profile link')}
      <textarea className="mt-2 block h-28 w-full resize-y rounded-lg border border-line/15 bg-surface p-3 font-mono text-xs font-normal text-ink" readOnly value={profile.source_uri} spellCheck={false} onFocus={e => e.currentTarget.select()} />
    </label>
    <p className="text-xs text-ink2">{t('Renaming changes the name in your list. The original link and connection settings stay unchanged.')}</p>
    <details className="text-xs text-ink2">
      <summary className="cursor-pointer">{t('VPN core configuration')}</summary>
      <pre className="mt-2 max-h-80 overflow-auto whitespace-pre-wrap break-all rounded-lg bg-surface p-3 text-ink">{JSON.stringify(proxy, null, 2)}</pre>
    </details>
  </section>
}
