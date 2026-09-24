import { useI18n, formatDate as localizedDate } from '../../i18n'
import { useCallback, useEffect, useState } from 'react'
import { useHome } from '../../app/HomeContext'
import { api } from '../../data/api'
import { formatBytes, formatUptime } from '../../format'
import type { UsagePeriod } from '../../types'
import { Button, Input } from '../../ui/controls'
import { toast, toastError } from '../../ui/feedback'
import { Card, Skeleton } from '../../ui/primitives'

function clampResetDay(day: number, year: number, month: number) {
  return Math.min(day, new Date(year, month + 1, 0).getDate())
}

function cycleWindow(resetDay: number, now = new Date()) {
  const currentDay = clampResetDay(resetDay, now.getFullYear(), now.getMonth())
  const startsThisMonth = now.getDate() >= currentDay
  const startMonth = startsThisMonth ? now.getMonth() : now.getMonth() - 1
  const startYear = now.getFullYear() + (startMonth < 0 ? -1 : 0)
  const normalizedStartMonth = (startMonth + 12) % 12
  const start = new Date(startYear, normalizedStartMonth, clampResetDay(resetDay, startYear, normalizedStartMonth))
  const nextMonth = normalizedStartMonth + 1
  const nextYear = startYear + (nextMonth > 11 ? 1 : 0)
  const normalizedNextMonth = nextMonth % 12
  const nextStart = new Date(nextYear, normalizedNextMonth, clampResetDay(resetDay, nextYear, normalizedNextMonth))
  const end = new Date(nextStart)
  end.setDate(end.getDate() - 1)
  return { start, end, nextStart }
}

function formatDate(date: Date) {
  return localizedDate(date, { day: 'numeric', month: 'short', year: 'numeric' })
}

function UsageTotals({ usage }: { usage: UsagePeriod }) {
  const { t } = useI18n()
  const total = usage.rx_bytes + usage.tx_bytes
  return (
    <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
      <div className="rounded-lg bg-surface2/70 p-3">
        <p className="text-[10px] font-semibold uppercase tracking-wider text-ok">{t("Download")}</p>
        <p className="tnum mt-1 text-xl font-bold text-ink">{formatBytes(usage.rx_bytes)}</p>
      </div>
      <div className="rounded-lg bg-surface2/70 p-3">
        <p className="text-[10px] font-semibold uppercase tracking-wider text-accent">{t("Upload")}</p>
        <p className="tnum mt-1 text-xl font-bold text-ink">{formatBytes(usage.tx_bytes)}</p>
      </div>
      <div className="rounded-lg bg-surface2/70 p-3">
        <p className="text-[10px] font-semibold uppercase tracking-wider text-ink3">{t("Total")}</p>
        <p className="tnum mt-1 text-xl font-bold text-ink">{formatBytes(total)}</p>
      </div>
    </div>
  )
}

export default function DataTab() {
  const { t } = useI18n()
  // The home batch already carries data_usage; a second poll for it was
  // duplicate ubus load on the agent.
  const { data: home, refresh } = useHome()
  const [editingResetDay, setEditingResetDay] = useState(false)
  const [resetDay, setResetDay] = useState('1')
  const [busy, setBusy] = useState(false)

  const usage = home?.usage ?? null

  useEffect(() => {
    if (usage?.reset_day && !editingResetDay) setResetDay(String(usage.reset_day))
  }, [usage?.reset_day, editingResetDay])

  const saveResetDay = useCallback(async () => {
    const day = parseInt(resetDay, 10)
    if (!day || day < 1 || day > 31) {
      toast(t('Reset day must be between 1 and 31'), 'err')
      return
    }
    setBusy(true)
    try {
      await api.dataUsageResetDaySet(day)
      setEditingResetDay(false)
      toast(t('Reset day set to day {day}', { day }))
      refresh()
    } catch (e) {
      toastError(e, t('Failed to set reset day'))
    } finally {
      setBusy(false)
    }
  }, [resetDay, refresh, t])

  if (!usage) {
    return (
      <div className="space-y-3">
        <Skeleton className="h-48" />
        <Skeleton className="h-32" />
      </div>
    )
  }

  const currentResetDay = usage.reset_day ?? (parseInt(resetDay, 10) || 1)
  const dates = cycleWindow(currentResetDay)
  const cycle = usage.cycle ?? usage.month
  const sincePowerOn = usage.since_power_on

  return (
    <div className="space-y-3">
      <Card
        title={t("Current data cycle")}
        action={
          <Button size="sm" variant="ghost" onClick={() => setEditingResetDay((v) => !v)}>{t("Set reset day")} </Button>
        }
      >
        {editingResetDay && (
          <div className="mb-3 flex flex-wrap items-end gap-2 rounded-lg bg-surface2/70 p-3">
            <div className="w-28">
              <p className="mb-1 text-[11px] font-semibold uppercase tracking-wider text-ink3">{t("Reset day")}</p>
              <Input type="number" min={1} max={31} value={resetDay} onChange={(e) => setResetDay(e.target.value)} />
            </div>
            <Button variant="primary" onClick={saveResetDay} loading={busy}>{t("Save")} </Button>
            <Button variant="ghost" onClick={() => setEditingResetDay(false)}>{t("Cancel")} </Button>
          </div>
        )}

        {cycle ? (
          <div className="space-y-3">
            <div className="flex flex-wrap gap-x-4 gap-y-1 text-[13px] text-ink2">
              <span>{t("Reset day:")} <span className="tnum font-bold text-ink">{currentResetDay}</span>
              </span>
              <span>{t("Period:")} <span className="font-bold text-ink">{formatDate(dates.start)} – {formatDate(dates.end)}</span>
              </span>
              <span>{t("Next reset:")} <span className="font-bold text-ink">{formatDate(dates.nextStart)}</span>
              </span>
            </div>
            <UsageTotals usage={cycle} />
            <p className="text-[12px] text-ink3">{t("Counters are maintained by the router and reset on the configured day each month.")} </p>
          </div>
        ) : (
          <p className="text-[13px] text-ink3">{t("No cycle data")}</p>
        )}
      </Card>

      {sincePowerOn && (
        <Card title={t("Since power on")}>
          <UsageTotals usage={sincePowerOn} />
          <p className="mt-2 text-[12px] text-ink3">{t('Counter time:')} {formatUptime(sincePowerOn.time_secs)}</p>
        </Card>
      )}

      <Card title={t("Other counters")} pad={false}>
        <div className="overflow-x-auto px-4 pb-3">
          <table className="w-full text-[13px]">
            <thead>
              <tr className="border-b border-line/8 text-left text-[11px] uppercase tracking-wider text-ink3">
                <th className="pb-1.5 pr-4 font-semibold">{t("Period")}</th>
                <th className="pb-1.5 pr-4 text-right font-semibold">{t("Down")}</th>
                <th className="pb-1.5 pr-4 text-right font-semibold">{t("Up")}</th>
                <th className="pb-1.5 pr-4 text-right font-semibold">{t("Total")}</th>
                <th className="pb-1.5 text-right font-semibold">{t("Time")}</th>
              </tr>
            </thead>
            <tbody>
              {[
                { label: t('Today'), data: usage.day },
                { label: t('Device lifetime'), data: usage.total },
              ].map(({ label, data: d }) => (
                <tr key={label} className="border-b border-line/6 last:border-0">
                  <td className="py-2 pr-4 text-ink2">{label}</td>
                  <td className="tnum py-2 pr-4 text-right text-ok">{formatBytes(d.rx_bytes)}</td>
                  <td className="tnum py-2 pr-4 text-right text-accent">{formatBytes(d.tx_bytes)}</td>
                  <td className="tnum py-2 pr-4 text-right font-semibold text-ink">
                    {formatBytes(d.rx_bytes + d.tx_bytes)}
                  </td>
                  <td className="tnum py-2 text-right text-ink3">{formatUptime(d.time_secs)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  )
}
