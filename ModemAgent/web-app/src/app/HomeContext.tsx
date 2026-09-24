/* eslint-disable react-refresh/only-export-components */
import { createContext, useContext, useMemo, type ReactNode } from 'react'
import { api } from '../data/api'
import { usePoll, type PollResult } from '../data/poll'
import type { HomeData } from '../types'
import { useI18n, translate, formatNumber } from '../i18n'

/**
 * The home poll is the app's heartbeat: one batched request that feeds the
 * Home screen, the Signal group, the Modem data tab and the global alert
 * banner. Those screens read it instead of re-fetching the same ubus data.
 *
 * `fast` is set for the groups that render live radio data; elsewhere the poll
 * only feeds the alert banner, so it idles. Changing the interval does not
 * restart the loop (see `usePoll`), so switching groups costs no extra request.
 */
const HomeContext = createContext<PollResult<HomeData> | null>(null)

export function HomeProvider({ fast, children }: { fast: boolean; children: ReactNode }) {
  const poll = usePoll('home', api.home, fast ? 3000 : 15000)
  return <HomeContext.Provider value={poll}>{children}</HomeContext.Provider>
}

export function useHome(): PollResult<HomeData> {
  const ctx = useContext(HomeContext)
  if (!ctx) throw new Error('useHome outside HomeProvider')
  return ctx
}

// ── Alerts derived from the home poll (no extra requests) ─────────────────────

export interface Alert {
  level: 'warning' | 'error'
  message: string
  details?: string
}

export function deriveAlerts(data: HomeData | null, t = translate): Alert[] {
  if (!data) return []
  const alerts: Alert[] = []
  const { battery, thermal } = data
  for (const [source, freshness] of Object.entries(data.sources ?? {})) {
    if (freshness.stale) {
      const age = freshness.age_ms == null ? t('No successful reading') : t('Last reading {seconds}s ago', { seconds: Math.floor(freshness.age_ms / 1000) })
      const names: Record<string, string> = { signal: 'Signal', battery: 'Battery', thermal: 'Temperatures', cpu: 'CPU', memory: 'Memory', device: 'Device', speed: 'Throughput', usage: 'Data usage', data_usage: 'Data usage', wan: 'IPv4 connection', wan6: 'IPv6 connection', charge_control: 'Charge control', cellular: 'Cellular network' }
      alerts.push({ level: 'warning', message: t('{source} unavailable: {age}', { source: t(names[source] ?? 'Data source'), age }), details: [source, freshness.error].filter(Boolean).join(': ') })
    }
  }
  if (data.charge_control_error) alerts.push({ level: 'error', message: t('Charge control error'), details: data.charge_control_error })

  if (battery) {
    const temp = battery.temperature_c
    if (temp != null && temp >= 50) {
      alerts.push({ level: 'error', message: t('Battery temperature critically high ({temperature}°C)', { temperature: formatNumber(temp, { maximumFractionDigits: 0 }) }) })
    } else if (temp != null && temp >= 45) {
      alerts.push({ level: 'warning', message: t('Battery temperature high ({temperature}°C)', { temperature: formatNumber(temp, { maximumFractionDigits: 0 }) }) })
    }
    if (!battery.charging) {
      if (battery.percent <= 5) {
        alerts.push({ level: 'error', message: t('Battery critically low ({percent}%)', { percent: battery.percent }) })
      } else if (battery.percent <= 15) {
        alerts.push({ level: 'warning', message: t('Battery low ({percent}%)', { percent: battery.percent }) })
      }
    }
  }

  if (thermal?.cpu_temp_c != null) {
    if (thermal.cpu_temp_c >= 90) {
      alerts.push({ level: 'error', message: t('CPU temperature critically high ({temperature}°C)', { temperature: formatNumber(thermal.cpu_temp_c) }) })
    } else if (thermal.cpu_temp_c >= 75) {
      alerts.push({ level: 'warning', message: t('CPU temperature elevated ({temperature}°C)', { temperature: formatNumber(thermal.cpu_temp_c) }) })
    }
  }

  return alerts
}

export function useAlerts(): Alert[] {
  const { t } = useI18n()
  const { data, error } = useHome()
  return useMemo(() => [
    ...(error ? [{ level: 'error' as const, message: t('Dashboard refresh failed; displayed readings may be old.'), details: error }] : []),
    ...deriveAlerts(data, t),
  ], [data, error, t])
}
