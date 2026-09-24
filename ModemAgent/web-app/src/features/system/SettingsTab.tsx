import { TechnicalError } from './TechnicalError'
import { useI18n, translate as t, formatNumber as n } from '../../i18n'
import { useCallback, useEffect, useState } from 'react'
import { api } from '../../data/api'
import { API_BASE } from '../../data/client'
import { formatUptime } from '../../format'
import type { DeviceInfo, SimInfo, UsbStatus } from '../../types'
import { ILogout, IPower, IRefresh, IRestart } from '../../icons'
import { Button, Toggle } from '../../ui/controls'
import { confirm, toast, toastError } from '../../ui/feedback'
import { Card, Row } from '../../ui/primitives'

// ── USB mode + powerbank ──────────────────────────────────────────────────────

type UsbModeKey = 'rndis' | 'ecm' | 'ncm' | 'debug'

const USB_MODE_INFO: Record<UsbModeKey, { label: string; description: string; warning?: string }> = {
  rndis: {
    label: 'RNDIS',
    description: "Microsoft's USB networking. Native on Windows; needs unmaintained drivers on macOS.",
  },
  ecm: {
    label: 'ECM',
    description: 'CDC-ECM USB Ethernet. Driver-free on macOS, Linux and modern Windows. Best supported mode.',
  },
  ncm: {
    label: 'NCM',
    description:
      'CDC-NCM USB Ethernet. Higher throughput in theory. Experimental — ZTE does not wire ncm.0 into the normal USB switch.',
    warning: 'Experimental',
  },
  debug: {
    label: 'Debug (ADB)',
    description: 'USB debug composition with adbd. Reboot returns to normal tethering.',
  },
}

function UsbSection() {
  useI18n()
  const [status, setStatus] = useState<UsbStatus | null>(null)
  const [busy, setBusy] = useState(false)
  const [powerbank, setPowerbank] = useState<boolean | null>(null)

  const fetchStatus = useCallback(async () => {
    try {
      setStatus(await api.usbStatus())
    } catch {
      /* ignore */
    }
    try {
      const charger = await api.chargerInfo()
      setPowerbank(Number(charger.otg_powerbank_state ?? 0) === 1)
    } catch {
      setPowerbank(null)
    }
  }, [])

  useEffect(() => {
    fetchStatus()
  }, [fetchStatus])

  async function setMode(mode: UsbModeKey) {
    const capability = status?.mode_capabilities?.find((c) => c.mode === mode)
    const isSupported =
      mode === 'debug' || capability?.supported || status?.supported_modes?.includes(mode)
    if (!isSupported) {
      toast(t('{mode} is not available on this firmware', { mode: t(USB_MODE_INFO[mode].label) }), 'err')
      return
    }
    const isExperimentalNcm = mode === 'ncm'
    if (isExperimentalNcm) {
      const ok = await confirm({
        title: t("Switch to experimental NCM?"),
        body: t("USB will disconnect and re-enumerate. Keep a Wi-Fi management path open."),
        confirmLabel: t("Switch"),
      })
      if (!ok) return
    }

    setBusy(true)
    try {
      await api.usbMode(mode, isExperimentalNcm ? { confirm_experimental: true } : undefined)
      toast(
        isExperimentalNcm
          ? t("NCM switch scheduled — USB will re-enumerate shortly")
          : mode === 'ecm' && status?.active_mode === 'ncm'
            ? t("ECM rollback scheduled — USB will re-enumerate shortly")
            : t('USB mode set to {mode} — reboot to apply', { mode: mode.toUpperCase() }),
      )
      fetchStatus()
    } catch (e) {
      toastError(e, t("Failed to set USB mode"))
    } finally {
      setBusy(false)
    }
  }

  async function setNcmDefault(enabled: boolean) {
    if (enabled) {
      const ok = await confirm({
        title: t("Persist NCM after boot?"),
        body: t("NCM will be re-applied automatically after each boot. Keep Wi-Fi management available."),
        confirmLabel: t("Enable"),
      })
      if (!ok) return
    }
    setBusy(true)
    try {
      await api.usbDefaultMode(enabled ? 'ncm' : 'ecm', enabled ? { confirm_experimental: true } : undefined)
      toast(enabled ? t("NCM will be applied automatically after boot") : t("USB boot default returned to ECM"))
      fetchStatus()
    } catch (e) {
      toastError(e, t("Failed to set USB boot default"))
    } finally {
      setBusy(false)
    }
  }

  async function togglePowerbank(on: boolean) {
    try {
      await api.usbPowerbank(on)
      setPowerbank(on)
      toast(on ? t("Powerbank (OTG) enabled") : t("Powerbank disabled"))
    } catch (e) {
      toastError(e, t("Failed to set powerbank"))
    }
  }

  const activeMode = status?.active_mode ?? null
  const ncmDefaultEnabled = status?.ncm_persist_on_boot ?? status?.default_mode === 'ncm'
  const supported = new Set(status?.supported_modes ?? ['rndis', 'ecm'])
  const modes: UsbModeKey[] = ['rndis', 'ecm', 'ncm', 'debug']

  return (
    <Card title={t("USB mode")}>
      <div className="space-y-3">
        <p className="text-[12px] text-ink2">
          {t('Switch USB operating mode. Most changes need a reboot to take effect.')}
          {activeMode && (
            <>
              {' '}{t('Active:')} <span className="font-bold text-ink">{activeMode.toUpperCase()}</span>.
            </>
          )}
        </p>
        {status?.ncm_last_error && <TechnicalError detail={status.ncm_last_error} fallback="The last NCM setup attempt failed" />}

        <div className="flex flex-wrap gap-1.5">
          {modes.map((mode) => {
            const info = USB_MODE_INFO[mode]
            const isActive = activeMode === mode
            const capability = status?.mode_capabilities?.find((c) => c.mode === mode)
            const isSupported = mode === 'debug' || capability?.supported || supported.has(mode)
            return (
              <button
                key={mode}
                onClick={() => setMode(mode)}
                disabled={busy || !isSupported}
                title={t(info.description)}
                className={`rounded-lg border px-3 py-1.5 text-[12px] font-bold transition-colors disabled:opacity-40 ${
                  isActive
                    ? 'border-ok/30 bg-ok/10 text-ok'
                    : !isSupported
                      ? 'border-line/8 bg-surface2/50 text-ink3'
                      : 'border-line/10 bg-surface text-ink2 hover:bg-surface2'
                }`}
              >
                {t(info.label)}
                {!isSupported && t(" · n/a")}
              </button>
            )
          })}
        </div>

        <div className="flex flex-wrap items-center justify-between gap-2 border-t border-line/8 pt-3">
          <div>
            <p className="text-[13px] font-semibold text-ink">{t("NCM after boot")}</p>
            <p className="text-[12px] text-ink2">{t("Applies NCM after the stock USB stack settles.")}</p>
          </div>
          <Toggle checked={ncmDefaultEnabled} disabled={busy} onChange={setNcmDefault} label={t("NCM after boot")} />
        </div>

        {powerbank !== null && (
          <div className="flex flex-wrap items-center justify-between gap-2 border-t border-line/8 pt-3">
            <div>
              <p className="text-[13px] font-semibold text-ink">{t("Powerbank / OTG")}</p>
              <p className="text-[12px] text-ink2">{t("Drive the USB-C port as a power output.")}</p>
            </div>
            <Toggle checked={powerbank} onChange={togglePowerbank} label={t("Powerbank")} />
          </div>
        )}
      </div>
    </Card>
  )
}

// ── Settings tab ──────────────────────────────────────────────────────────────

export default function SettingsTab({ onLogout }: { onLogout: () => void }) {
  useI18n()
  const [device, setDevice] = useState<DeviceInfo | null>(null)
  const [sim, setSim] = useState<SimInfo | null>(null)
  const [imei, setImei] = useState('')
  const [busy, setBusy] = useState<string | null>(null)

  const fetchAll = useCallback(async () => {
    const [d, s, i] = await Promise.allSettled([api.device(), api.simInfo(), api.simImei()])
    if (d.status === 'fulfilled') setDevice(d.value)
    if (s.status === 'fulfilled') setSim(s.value)
    if (i.status === 'fulfilled' && i.value) setImei((i.value as { imei?: string }).imei ?? '')
  }, [])

  useEffect(() => {
    fetchAll()
  }, [fetchAll])

  async function restartAgent() {
    setBusy('restart')
    try {
      await api.restartAgent()
      toast(t("Agent restarting — reloading in a few seconds"))
      setTimeout(() => window.location.reload(), 5000)
    } catch (e) {
      toastError(e, t("Failed to restart agent"))
      setBusy(null)
    }
  }

  async function runPowerAction(action: 'reboot' | 'shutdown') {
    const ok = await confirm({
      title: action === 'reboot' ? t("Reboot the device?") : t("Shut down the device?"),
      body:
        action === 'reboot'
          ? t("All connections will drop for about 10-30 seconds.")
          : t("The device powers off. Use the physical power button to turn it back on."),
      confirmLabel: action === 'reboot' ? t("Reboot") : t("Shut down"),
      danger: true,
    })
    if (!ok) return
    setBusy(action)
    try {
      if (action === 'reboot') {
        await api.reboot()
        toast(t("Reboot command sent"))
      } else {
        await api.shutdown()
        toast(t("Shutdown command sent"))
      }
    } catch (e) {
      toastError(e, t(action === 'reboot' ? 'Failed to reboot device' : 'Failed to shut down device'))
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-1 gap-3 lg:grid-cols-2">
        <Card title={t("Device")}>
          <Row label={t("Model")} value={device?.model ?? '\u2014'} mono />
          <Row label={t("Firmware")} value={device?.firmware ?? '\u2014'} mono />
          <Row label={t("Uptime")} value={formatUptime(device?.uptime_secs)} />
          <Row label={t("Load")} value={device?.load_avg?.map((v) => n(v, { minimumFractionDigits: 2, maximumFractionDigits: 2 })).join(', ') ?? '\u2014'} mono />
          <Row label="IMEI" value={imei || '\u2014'} mono />
        </Card>

        <Card title={t("SIM card")}>
          <Row label={t("Status")} value={sim?.state === 'SIM_READY' ? t('Ready') : t(sim?.state ?? '\u2014')} />
          <Row label="ICCID" value={sim?.iccid ?? '\u2014'} mono />
          <Row label="IMSI" value={sim?.imsi ?? '\u2014'} mono />
          <Row label="MCC/MNC" value={sim?.mcc && sim?.mnc ? `${sim.mcc}/${sim.mnc}` : '\u2014'} mono />
        </Card>
      </div>

      <UsbSection />

      <Card title={t("Service controls")}>
        <div className="flex flex-wrap items-center gap-2">
          <Button variant="outline" onClick={restartAgent} loading={busy === 'restart'}>
            <IRefresh size={14} />{t("Restart agent")}</Button>
          <Button
            variant="outline"
            onClick={() => {
              toast(t("Reloading dashboard…"))
              setTimeout(() => window.location.reload(), 400)
            }}
          >
            <IRestart size={14} />{t("Reload dashboard")}</Button>
          <Button variant="danger" onClick={() => runPowerAction('reboot')} loading={busy === 'reboot'}>
            <IRestart size={14} />{t("Reboot")}</Button>
          <Button variant="danger" onClick={() => runPowerAction('shutdown')} loading={busy === 'shutdown'}>
            <IPower size={14} />{t("Shut down")}</Button>
        </div>
        <p className="mt-2.5 text-[12px] text-ink3">{t("Restart agent briefly interrupts the backend. Reboot and shut down interrupt all connections.")}</p>
      </Card>

      <Card title={t("Connection")}>
        <Row label="API" value={API_BASE} mono />
        <Row label={t("Dashboard")} value={window.location.origin} mono />
        <div className="mt-3 border-t border-line/8 pt-3">
          <Button variant="ghost" onClick={onLogout}>
            <ILogout size={14} />{t("Sign out")}</Button>
        </div>
      </Card>
    </div>
  )
}
