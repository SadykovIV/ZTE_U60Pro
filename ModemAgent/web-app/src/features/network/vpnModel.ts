export type ImportSummary = { added: number; updated: number; removed: number; duplicates: number; retained_active: number; skipped: { index: number; code: string }[] }

export function protocolLabel(protocol = 'vless'): string {
  return ({ vless: 'VLESS', hysteria2: 'HY2', wireguard: 'WireGuard', amneziawg2: 'AWG 2', amneziawg3: 'AWG 3', 'amneziawg3.1': 'AWG 3.1', ikev2: 'IKEv2 / IPsec' } as Record<string, string>)[protocol] ?? protocol
}

export type Ikev2Draft = { id?: string; name: string; server: string; server_id: string; username: string; password: string; ca_certificate: string; dns: string }
export const IKEV2_ROUTING = 'Private networks (10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16) use IKEv2. Public internet uses the mobile connection. Private traffic is blocked if the tunnel is unavailable.'
export const IKEV2_DNS_HINT = 'The profile DNS server is reached through VPN. Without the tunnel, websites may not open by name even when the mobile connection works.'
export function emptyIkev2Draft(): Ikev2Draft {
  return { name: 'UserGate', server: '', server_id: '', username: '', password: '', ca_certificate: '', dns: '10.0.2.1' }
}
export function ikev2Draft(profile: { id: string; name: string; proxy: Record<string, unknown> }): Ikev2Draft {
  const text = (key: string) => typeof profile.proxy[key] === 'string' ? profile.proxy[key] as string : ''
  return { id: profile.id, name: profile.name, server: text('server'), server_id: text('server_id'), username: text('username'), password: '', ca_certificate: text('ca_certificate'), dns: text('dns') || '10.0.2.1' }
}
export function ikev2Request(draft: Ikev2Draft): Record<string, unknown> {
  return { action: 'save_ikev2', ...(draft.id ? { id: draft.id } : {}), name: draft.name.trim(), ikev2: {
    server: draft.server.trim(), server_id: draft.server_id.trim() || draft.server.trim(), username: draft.username.trim(),
    ...(draft.password ? { password: draft.password } : {}), ca_certificate: draft.ca_certificate.trim(), dns: draft.dns.trim(),
  } }
}
export function ikev2Validation(draft: Ikev2Draft): string | undefined {
  const bytes = (value: string) => new TextEncoder().encode(value).length
  const plain = (value: string, max: number) => value.length > 0 && bytes(value) <= max && Array.from(value).every(char => { const code = char.codePointAt(0)!; return code > 31 && (code < 127 || code > 159) })
  if (!plain(draft.name.trim(), 256) || Array.from(draft.name.trim()).length > 64) return 'Use a name of 1 to 64 characters without line breaks.'
  if (!plain(draft.server.trim(), 253) || /[\s/\\:@]/.test(draft.server.trim())) return 'Enter the VPN server hostname or IPv4 address without a URL or port.'
  if (!plain(draft.server_id.trim() || draft.server.trim(), 253)) return 'Enter the server identity from its certificate.'
  if (!plain(draft.username.trim(), 253)) return 'Enter your IKEv2 username without line breaks.'
  if ((!draft.id || draft.password) && !plain(draft.password, 1024)) return 'Enter your IKEv2 password without line breaks.'
  if (bytes(draft.ca_certificate) > 65536 || !/^-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\s]+-----END CERTIFICATE-----\s*$/.test(draft.ca_certificate.trim())) return 'Paste or open one CA certificate in PEM format, no larger than 64 KiB.'
  const octets = draft.dns.trim().split('.')
  if (octets.length !== 4 || octets.some(value => !/^(0|[1-9]\d{0,2})$/.test(value) || Number(value) > 255)) return 'Enter a valid IPv4 DNS server address.'
  const [first, second] = octets.map(Number)
  if (!(first === 10 || (first === 172 && second >= 16 && second <= 31) || (first === 192 && second === 168))) return 'The VPN DNS server must be in 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16.'
  if (first === 192 && second === 168 && Number(octets[2]) === 50) return 'The VPN DNS server must be outside the modem’s 192.168.50.0/24 subnet.'
  return undefined
}

export function profileImport(input: string, name: string): Record<string, unknown> {
  const first = input.replace(/^\uFEFF/, '').split('\n').map(line => line.split('#')[0].trim()).find(Boolean)
  return { ...(first?.toLowerCase() === '[interface]' ? { action: 'import_config', config: input } : { action: 'import', uri: input.trim() }), ...(name.trim() ? { name: name.trim() } : {}) }
}

export function warningText(code: string): string | undefined {
  if (code === 'VPN_SPX_PRESERVED') return 'The spx parameter is preserved in the source link but is not used by this VPN core.'
  if (code === 'VPN_INSECURE_TLS') return 'The link disables TLS certificate verification.'
  if (code === 'VPN_IPV6_GUEST_DISABLED') return 'The VPN Wi-Fi network uses IPv4. IPv6 tunnel settings are preserved.'
  return undefined
}

export function activationConfirmed(status: { active_profile?: string; profiles?: { id: string; active: boolean; update_available?: boolean }[] }, id: unknown): boolean {
  return status?.active_profile === id && Array.isArray(status.profiles) && status.profiles.some(profile => profile.id === id && profile.active && profile.update_available !== true)
}

export type SubscriptionUpdate = { id: string; name: string; ok: boolean; code?: string; import?: ImportSummary }

// Snapshot IDs before starting: every saved feed is attempted once, in order.
// The caller owns its busy state and maps errors to public, fixed messages.
export async function updateSubscriptionsSequentially(
  subscriptions: { id: string; name: string }[],
  update: (id: string) => Promise<ImportSummary | undefined>,
  errorCode: (error: unknown) => string,
  progress: (results: SubscriptionUpdate[]) => void,
): Promise<SubscriptionUpdate[]> {
  const selected = subscriptions.map(({ id, name }) => ({ id, name }))
  const results: SubscriptionUpdate[] = []
  for (const subscription of selected) {
    try { results.push({ ...subscription, ok: true, import: await update(subscription.id) }) }
    catch (error) { results.push({ ...subscription, ok: false, code: errorCode(error) }) }
    progress([...results])
  }
  return results
}
