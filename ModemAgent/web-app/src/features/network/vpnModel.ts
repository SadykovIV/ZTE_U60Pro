export type ImportSummary = { added: number; updated: number; removed: number; duplicates: number; retained_active: number; skipped: { index: number; code: string }[] }

export function protocolLabel(protocol = 'vless'): string {
  return ({ vless: 'VLESS', hysteria2: 'HY2', wireguard: 'WireGuard', amneziawg2: 'AWG 2', amneziawg3: 'AWG 3', 'amneziawg3.1': 'AWG 3.1' } as Record<string, string>)[protocol] ?? protocol
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
