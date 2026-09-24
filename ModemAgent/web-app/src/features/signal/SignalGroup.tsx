import { useI18n, translate as t } from '../../i18n'
import { useState } from 'react'
import { Tabs } from '../../ui/Tabs'
import Overview from './Overview'
import Locking from './Locking'

type Tab = 'overview' | 'locking'

export default function SignalGroup() {
  useI18n()
  const [tab, setTab] = useState<Tab>('overview')

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-ink">{t("Signal")}</h1>
        <p className="mt-0.5 text-[13px] text-ink2">{t("Live radio metrics, band and cell locking")}</p>
      </div>

      <Tabs
        tabs={[
          { id: 'overview', label: t("Overview") },
          { id: 'locking', label: t("Mode & Locking") },
        ]}
        active={tab}
        onChange={setTab}
      />

      {tab === 'overview' ? <Overview /> : <Locking />}
    </div>
  )
}
