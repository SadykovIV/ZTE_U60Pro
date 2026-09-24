import { useI18n, translate as t } from '../../i18n'
import { useState } from 'react'
import { Tabs } from '../../ui/Tabs'
import MetricsTab from './MetricsTab'
import ToolsTab from './ToolsTab'
import SettingsTab from './SettingsTab'

type Tab = 'metrics' | 'tools' | 'settings'

export default function SystemGroup({ onLogout }: { onLogout: () => void }) {
  useI18n()
  const [tab, setTab] = useState<Tab>('metrics')

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-ink">{t("System")}</h1>
        <p className="mt-0.5 text-[13px] text-ink2">{t("Health metrics, diagnostic tools and device controls")}</p>
      </div>

      <Tabs
        tabs={[
          { id: 'metrics', label: t("Metrics") },
          { id: 'tools', label: t("Tools") },
          { id: 'settings', label: t("Settings") },
        ]}
        active={tab}
        onChange={setTab}
      />

      {tab === 'metrics' && <MetricsTab />}
      {tab === 'tools' && <ToolsTab />}
      {tab === 'settings' && <SettingsTab onLogout={onLogout} />}
    </div>
  )
}
