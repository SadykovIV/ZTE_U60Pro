import { TechnicalError } from './TechnicalError'
import { useI18n, translate as t, formatNumber as n } from '../../i18n'
import { useEffect, useState } from 'react'
import { api } from '../../data/api'
import { usePoll } from '../../data/poll'
import { tempColorClass } from '../../format'
import type { BatteryBspInfo, BatteryDetail, ChargeControlState, CpuInfo, MemInfo, ThermalAll } from '../../types'
import { formatBytes } from '../../format'
import { Button, Toggle } from '../../ui/controls'
import { toastError } from '../../ui/feedback'
import { Card, Meter, Skeleton } from '../../ui/primitives'

interface MetricsData {
  thermal: ThermalAll | null
  battery: BatteryDetail | null
  batteryInfo: BatteryBspInfo | null
  cpu: CpuInfo | null
  mem: MemInfo | null
}

function ThermalBar({ label, value }: { label: string; value?: number | null }) {
  useI18n()
  if (value == null) {
    return (
      <div className="flex justify-between text-[12px]">
        <span className="text-ink2">{label}</span>
        <span className="font-medium text-ink3">{t("Unavailable")}</span>
      </div>
    )
  }
  const pct = Math.min((value / 100) * 100, 100)
  const tone = value > 80 ? 'bg-danger' : value > 60 ? 'bg-warn' : 'bg-ok'
  return (
    <div>
      <div className="mb-0.5 flex justify-between text-[12px]">
        <span className="text-ink2">{label}</span>
        <span className={`tnum font-semibold ${tempColorClass(value)}`}>{n(value, { minimumFractionDigits: 1, maximumFractionDigits: 1 })}°C</span>
      </div>
      <Meter pct={pct} tone={tone} />
    </div>
  )
}

// ── Charge control ────────────────────────────────────────────────────────────

function ChargeControlCard() {
  useI18n()
  const { data: cc, mutate } = usePoll('charge-control', api.chargeControl, 10000)
  const [busy, setBusy] = useState(false)
  const [limit, setLimit] = useState<number | null>(null)
  const [dragging, setDragging] = useState(false)

  useEffect(() => {
    if (!dragging && cc) setLimit(cc.charge_limit)
  }, [cc, dragging])

  async function apply(body: Partial<ChargeControlState>) {
    setBusy(true)
    try {
      // The PUT returns the authoritative new state — publish it rather than
      // spending a second request re-reading what we were just handed.
      mutate(await api.chargeControlSet(body))
    } catch (e) {
      toastError(e, t("Charge control failed"))
    } finally {
      setBusy(false)
    }
  }

  if (!cc) return null

  return (
    <Card title={t("Charge control")}>
      <div className="space-y-3">
        {cc.last_error && <TechnicalError detail={cc.last_error} fallback="Charge control error" />}
        <div className="flex items-center justify-between gap-2">
          <div className="min-w-0">
            <p className="text-[13px] font-medium text-ink">{t("Charging status")}</p>
            <p className="truncate text-[12px] text-ink2">
              {t(cc.battery_status ?? 'Battery data unavailable')}{cc.capacity != null ? ` · ${n(cc.capacity)}%` : ''}{cc.manual_override ? t(" · manual override") : ''}
            </p>
          </div>
          <Button
            size="sm"
            variant={cc.charging_stopped ? 'primary' : 'outline'}
            loading={busy}
            disabled={!cc.charger_available}
            onClick={() => apply({ charging_stopped: !cc.charging_stopped })}
          >
            {cc.charging_stopped ? t("Resume charging") : t("Stop charging")}
          </Button>
        </div>

        <div className="border-t border-line/8 pt-3">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-[13px] font-medium text-ink">{t("Charge limit")}</p>
              <p className="text-[12px] text-ink2">
                {t('Stop at limit, resume {difference}% below', { difference: cc.hysteresis })}
              </p>
            </div>
            <Toggle
              checked={cc.charge_limit_enabled}
              disabled={busy || !cc.battery_available}
              onChange={(v) => apply({ charge_limit_enabled: v })}
              label={t("Charge limit enforcer")}
            />
          </div>
          <div className="mt-2 flex items-center gap-3">
            <input
              aria-label={t('Charge limit')}
              type="range"
              min={50}
              max={100}
              step={5}
              value={limit ?? cc.charge_limit}
              disabled={busy || !cc.charge_limit_enabled || !cc.battery_available}
              onChange={(e) => setLimit(Number(e.target.value))}
              onPointerDown={() => setDragging(true)}
              onPointerUp={(e) => {
                setDragging(false)
                apply({ charge_limit: Number(e.currentTarget.value) })
              }}
              onKeyUp={(e) => apply({ charge_limit: Number(e.currentTarget.value) })}
              className="w-full accent-[rgb(var(--accent))] disabled:opacity-40"
            />
            <span className="tnum w-12 text-right text-[13px] font-semibold text-ink">
              {limit ?? cc.charge_limit}%
            </span>
          </div>
        </div>

        <p className="text-[11px] leading-snug text-ink3">{t("Firmware note: the charger switch is inverted (enable = stop). Charging auto-resumes when the charger is unplugged or the limit is disabled.")}</p>
        {!cc.available && <p className="text-[12px] font-medium text-warn">{t("Battery and charger hardware data are unavailable; controls are disabled.")}</p>}
      </div>
    </Card>
  )
}

// ── Tab ───────────────────────────────────────────────────────────────────────

export default function MetricsTab() {
  useI18n()
  const { data } = usePoll<MetricsData>(
    'metrics',
    async () => {
      const [t, b, bi, c, m] = await Promise.allSettled([
        api.thermalAll(),
        api.batteryDetail(),
        api.batteryInfoUbus(),
        api.cpu(),
        api.memory(),
      ])
      return {
        thermal: t.status === 'fulfilled' ? t.value : null,
        battery: b.status === 'fulfilled' ? b.value : null,
        batteryInfo: bi.status === 'fulfilled' ? bi.value : null,
        cpu: c.status === 'fulfilled' ? c.value : null,
        mem: m.status === 'fulfilled' ? m.value : null,
      }
    },
    5000,
  )

  if (!data) {
    return (
      <div className="grid grid-cols-1 gap-3 lg:grid-cols-2">
        <Skeleton className="h-64" />
        <Skeleton className="h-64" />
        <Skeleton className="h-48" />
        <Skeleton className="h-48" />
      </div>
    )
  }

  const { thermal, battery, batteryInfo, cpu, mem } = data

  const cpuAvg =
    thermal?.available && thermal.cpu_0 != null
      ? [thermal.cpu_0, thermal.cpu_1, thermal.cpu_2, thermal.cpu_3]
          .filter((v): v is number => v != null)
          .reduce((a, b) => a + b, 0) /
        [thermal.cpu_0, thermal.cpu_1, thermal.cpu_2, thermal.cpu_3].filter((v) => v != null).length
      : undefined

  const batteryHealth =
    battery?.available && battery.charge_full_design_mah != null && battery.charge_full_design_mah > 0 && battery.charge_full_mah != null
      ? Math.round((battery.charge_full_mah / battery.charge_full_design_mah) * 100)
      : undefined

  return (
    <div className="grid grid-cols-1 gap-3 lg:grid-cols-2">
      <Card title={t("Temperatures")}>
        {thermal?.available ? (
          <div className="space-y-2.5">
            <ThermalBar label={t("CPU (avg)")} value={cpuAvg} />
            <ThermalBar label={t("Modem (Q6 DSP)")} value={thermal.modem} />
            <ThermalBar label={t("Modem SS")} value={thermal.modem_ss0} />
            <ThermalBar label={t("PA (power amplifier)")} value={thermal.pa} />
            <ThermalBar label={t("SDR (radio)")} value={thermal.sdr} />
            <ThermalBar label={t("Battery")} value={thermal.battery} />
            <ThermalBar label="USB" value={thermal.usb} />
            <ThermalBar label={t("Ethernet PHY")} value={thermal.eth_phy} />
            <ThermalBar label="PMIC" value={thermal.pmic} />
            <ThermalBar label={t("Board (XO)")} value={thermal.xo_therm} />
          </div>
        ) : (
          <div className="space-y-2.5">
            <p className="text-[12px] font-medium text-warn">{t("Thermal sensors are unavailable.")}</p>
            {[t("CPU (avg)"), t("Modem (Q6 DSP)"), t("Modem SS"), t("PA (power amplifier)"), t("SDR (radio)"), t("Battery"), 'USB', t("Ethernet PHY"), 'PMIC', t("Board (XO)")].map((label) => <ThermalBar key={label} label={label} />)}
          </div>
        )}
      </Card>

      <div className="space-y-3">
        <Card title={t("CPU usage")}>
          {cpu ? (
            <div className="space-y-3">
              <div>
                <div className="mb-1 flex justify-between text-[13px]">
                  <span className="font-medium text-ink">{t("Overall")}</span>
                  <span className="tnum text-ink2">{n(cpu.overall, { minimumFractionDigits: 1, maximumFractionDigits: 1 })}%</span>
                </div>
                <Meter pct={cpu.overall} />
              </div>
              {cpu.cores.length > 0 && (
                <div className="space-y-1.5 border-t border-line/8 pt-2.5">
                  {cpu.cores.map((pct, i) => (
                    <div key={i}>
                      <div className="mb-0.5 flex justify-between text-[11px]">
                        <span className="text-ink3">{t('Core {index}', { index: i })}</span>
                        <span className="tnum text-ink2">{n(pct, { minimumFractionDigits: 1, maximumFractionDigits: 1 })}%</span>
                      </div>
                      <Meter pct={pct} />
                    </div>
                  ))}
                </div>
              )}
            </div>
          ) : (
            <p className="text-[13px] text-ink3">{t("No CPU data")}</p>
          )}
        </Card>

        <Card title={t("Memory")}>
          {mem ? (
            <div>
              <div className="mb-1 flex justify-between text-[13px]">
                <span className="text-ink2">{t("Usage")}</span>
                <span className="tnum text-ink">
                  {formatBytes(mem.used_kb * 1024)} / {formatBytes(mem.total_kb * 1024)} ({n(mem.usage_pct, { maximumFractionDigits: 0 })}%)
                </span>
              </div>
              <Meter pct={mem.usage_pct} tone="bg-warn" />
            </div>
          ) : (
            <p className="text-[13px] text-ink3">{t("No memory data")}</p>
          )}
        </Card>
      </div>

      <Card title={t("Battery")}>
        {battery?.available ? (
          <div className="space-y-3">
            <div>
              <div className="mb-1 flex justify-between text-[13px]">
                <span className="tnum font-semibold text-ink">{battery.capacity != null ? `${n(battery.capacity)}%` : t("Unavailable")}</span>
                <span className="text-ink2">{t(battery.status ?? 'Unavailable')}</span>
              </div>
              {battery.capacity != null && <Meter pct={battery.capacity} tone={battery.capacity > 20 ? 'bg-ok' : 'bg-danger'} />}
            </div>
            <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-[13px]">
              <Info label={t("Power")} value={formatMeasure(battery.power_mw, (value) => `${n(value / 1000, { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ${t('W')}`)} />
              <Info label={t("Voltage")} value={formatMeasure(battery.voltage_mv, (value) => `${n(value / 1000, { minimumFractionDigits: 3, maximumFractionDigits: 3 })} ${t('V')}`)} />
              <Info label={t("Current")} value={formatMeasure(battery.current_ma, (value) => `${n(value)} ${t('mA')}`)} />
              <Info label={t("Charge type")} value={t(battery.charge_type ?? 'Unavailable')} />
              <Info label={t("Temperature")} value={formatMeasure(battery.temperature_c, (value) => `${n(value, { minimumFractionDigits: 1, maximumFractionDigits: 1 })}°C`)} cls={battery.temperature_c != null ? tempColorClass(battery.temperature_c) : 'text-ink3'} />
              <Info
                label={battery.status === 'Charging' ? t("Time to full") : t("Time to empty")}
                value={formatClock(battery.status === 'Charging' ? battery.time_to_full_secs : battery.time_to_empty_secs)}
              />
              <Info label={t("Charge counter")} value={formatMeasure(battery.charge_counter_mah, (value) => `${n(value)} ${t('mAh')}`)} />
              <Info label={t("Cycles")} value={formatMeasure(battery.cycle_count, n)} />
              <Info label={t("Fuel gauge")} value={batteryInfo?.available && batteryInfo.using_hw_fg_chip != null ? (batteryInfo.using_hw_fg_chip ? t("Hardware") : t("Software")) : t("Unavailable")} />
              <Info label={t("Battery online")} value={batteryInfo?.available && batteryInfo.online != null ? (batteryInfo.online ? t("Yes") : t("No")) : t("Unavailable")} />
            </div>
          </div>
        ) : (
          <p className="text-[13px] font-medium text-warn">{t("Battery hardware data are unavailable.")}</p>
        )}
      </Card>

      <div className="space-y-3">
        <Card title={t("Battery health")}>
          {battery?.available ? (
            <div className="space-y-1.5 text-[13px]">
              <KV k={t("Health")} v={t(battery.health === 'Good' ? 'Healthy' : battery.health ?? 'Unavailable')} />
              <KV k={t("Capacity")} v={battery.charge_full_mah != null && battery.charge_full_design_mah != null ? `${n(battery.charge_full_mah)} / ${n(battery.charge_full_design_mah)} ${t('mAh')}` : t("Unavailable")} />
              {batteryHealth != null && (
                <div className="flex justify-between">
                  <span className="text-ink2">{t("Capacity retention")}</span>
                  <span className={`tnum font-semibold ${batteryHealth > 80 ? 'text-ok' : 'text-warn'}`}>{n(batteryHealth)}%</span>
                </div>
              )}
              <KV k="OCV" v={formatMeasure(battery.voltage_ocv_mv, (value) => `${n(value / 1000, { minimumFractionDigits: 3, maximumFractionDigits: 3 })} ${t('V')}`)} />
            </div>
          ) : (
          <p className="text-[13px] font-medium text-warn">{t("Battery health measures are unavailable.")}</p>
          )}
        </Card>

        <ChargeControlCard />
      </div>
    </div>
  )
}

function Info({ label, value, cls = 'text-ink' }: { label: string; value: string; cls?: string }) {
  useI18n()
  return (
    <div className="min-w-0">
      <p className="text-[10px] font-semibold uppercase tracking-wider text-ink3">{label}</p>
      <p className={`tnum truncate font-medium ${cls}`}>{value}</p>
    </div>
  )
}

function KV({ k, v }: { k: string; v: string }) {
  useI18n()
  return (
    <div className="flex justify-between">
      <span className="text-ink2">{k}</span>
      <span className="tnum font-medium text-ink">{v}</span>
    </div>
  )
}

function formatMeasure(value: number | null, format: (value: number) => string) {
  return value == null ? t("Unavailable") : format(value)
}

function formatClock(secs: number | null) {
  if (secs == null || secs <= 0) return t("Unavailable")
  const h = Math.floor(secs / 3600)
  const m = Math.floor((secs % 3600) / 60)
  return h > 0 ? t('{hours}h {minutes}m', { hours: h, minutes: m }) : t('{minutes}m', { minutes: m })
}
