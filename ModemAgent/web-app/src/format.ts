import { translate as t, formatNumber } from './i18n-core'
// Formatting helpers and signal-quality thresholds.

export function formatBytes(bytes: number): string {
  if (bytes >= 1e12) return `${formatNumber(bytes / 1e12, { minimumFractionDigits: 1, maximumFractionDigits: 1 })} ${t('TB')}`
  if (bytes >= 1e9) return `${formatNumber(bytes / 1e9, { minimumFractionDigits: 1, maximumFractionDigits: 1 })} ${t('GB')}`
  if (bytes >= 1e6) return `${formatNumber(bytes / 1e6, { minimumFractionDigits: 1, maximumFractionDigits: 1 })} ${t('MB')}`
  if (bytes >= 1e3) return `${formatNumber(bytes / 1e3, { maximumFractionDigits: 0 })} ${t('KB')}`
  return `${formatNumber(bytes)} ${t('B')}`
}

export function formatSpeed(bps: number): string {
  const mbps = (bps * 8) / 1_000_000
  if (mbps >= 1) return `${formatNumber(mbps, { minimumFractionDigits: 1, maximumFractionDigits: 1 })} ${t('Mbps')}`
  const kbps = (bps * 8) / 1000
  return `${formatNumber(kbps, { maximumFractionDigits: 0 })} ${t('Kbps')}`
}

export function parseBandwidthMHz(bandwidth?: string): number {
  if (!bandwidth || bandwidth === '\u2014') return 0
  const match = bandwidth.match(/\d+(?:\.\d+)?/)
  return match ? parseFloat(match[0]) : 0
}

export function sumBandwidthMHz(carriers: { bandwidth?: string }[]): number {
  return carriers.reduce((sum, c) => sum + parseBandwidthMHz(c.bandwidth), 0)
}

export function formatBandwidthMHz(mhz: number): string {
  if (mhz <= 0) return '\u2014'
  return `${formatNumber(mhz, { maximumFractionDigits: 1 })} ${t('MHz')}`
}

export function formatUptime(secs?: number): string {
  if (!secs) return '\u2014'
  const d = Math.floor(secs / 86400)
  const h = Math.floor((secs % 86400) / 3600)
  const m = Math.floor((secs % 3600) / 60)
  return [d && t('{count}d', { count: d }), (d || h) && t('{count}h', { count: h }), t('{count}m', { count: m })].filter(Boolean).join(' ')
}

export function formatDuration(secs: number): string {
  if (!Number.isFinite(secs) || secs <= 0) return t('{count}s', { count: 0 })
  const h = Math.floor(secs / 3600)
  const m = Math.floor((secs % 3600) / 60)
  const s = Math.floor(secs % 60)
  if (h > 0) return `${t('{count}h', { count: h })} ${t('{count}m', { count: m })}`
  if (m > 0) return `${t('{count}m', { count: m })} ${t('{count}s', { count: s })}`
  return t('{count}s', { count: s })
}

// ── Signal quality ────────────────────────────────────────────────────────────

export type Quality = 'excellent' | 'good' | 'fair' | 'poor' | 'unknown'

export function rsrpQuality(rsrp?: number): Quality {
  if (rsrp == null) return 'unknown'
  if (rsrp > -80) return 'excellent'
  if (rsrp > -90) return 'good'
  if (rsrp > -100) return 'fair'
  return 'poor'
}

export function qualityLabel(q: Quality): string {
  switch (q) {
    case 'excellent':
      return t('Excellent')
    case 'good':
      return t('Good')
    case 'fair':
      return t('Fair')
    case 'poor':
      return t('Weak')
    default:
      return '\u2014'
  }
}

/** Tailwind text color class for a quality level. */
export function qualityText(q: Quality): string {
  switch (q) {
    case 'excellent':
    case 'good':
      return 'text-ok'
    case 'fair':
      return 'text-warn'
    case 'poor':
      return 'text-danger'
    default:
      return 'text-ink3'
  }
}

/** Tailwind bg class for status dots / bars. */
export function qualityBg(q: Quality): string {
  switch (q) {
    case 'excellent':
    case 'good':
      return 'bg-ok'
    case 'fair':
      return 'bg-warn'
    case 'poor':
      return 'bg-danger'
    default:
      return 'bg-ink3'
  }
}

export function rsrpColorClass(rsrp?: number): string {
  return qualityText(rsrpQuality(rsrp))
}

export function rsrqColorClass(v?: number): string {
  if (v == null) return 'text-ink3'
  if (v > -10) return 'text-ok'
  if (v > -15) return 'text-warn'
  return 'text-danger'
}

export function sinrColorClass(v?: number): string {
  if (v == null) return 'text-ink3'
  if (v > 15) return 'text-ok'
  if (v > 5) return 'text-warn'
  return 'text-danger'
}

export function tempColorClass(c?: number): string {
  if (c == null) return 'text-ink3'
  if (c > 80) return 'text-danger'
  if (c > 60) return 'text-warn'
  return 'text-ok'
}

export function modemMode(type?: string): string {
  const raw = (type ?? '').toUpperCase()
  if (!raw) return '\u2014'
  if (raw.includes('ENDC') || raw.includes('NSA')) return 'ENDC'
  if (raw.includes('SA')) return 'SA'
  if (raw.includes('LTE') || raw === '4G') return 'LTE'
  if (raw.includes('NR') || raw.includes('5G')) return '5G'
  return raw
}
