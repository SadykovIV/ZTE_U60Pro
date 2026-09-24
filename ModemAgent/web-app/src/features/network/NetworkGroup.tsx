import { useI18n, translate as t } from '../../i18n'
import { useState } from 'react'
import { Tabs } from '../../ui/Tabs'
import ClientsTab from './ClientsTab'
import WifiTab from './WifiTab'
import RouterTab from './RouterTab'
import VpnTab from './VpnTab'

type Tab = 'clients' | 'wifi' | 'router' | 'vpn'

export default function NetworkGroup() {
  useI18n()
  const [tab, setTab] = useState<Tab>('clients')

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-ink">{t("Network")}</h1>
        <p className="mt-0.5 text-[13px] text-ink2">{t("Connected clients, Wi-Fi and router settings")}</p>
      </div>

      <Tabs
        tabs={[
          { id: 'clients', label: t("Clients") },
          { id: 'wifi', label: 'Wi-Fi' },
          { id: 'router', label: t("Router") },
          { id: 'vpn', label: 'VPN' },
        ]}
        active={tab}
        onChange={setTab}
      />

      {tab === 'clients' && <ClientsTab />}
      {tab === 'wifi' && <WifiTab />}
      {tab === 'router' && <RouterTab />}
      {tab === 'vpn' && <VpnTab />}
    </div>
  )
}
