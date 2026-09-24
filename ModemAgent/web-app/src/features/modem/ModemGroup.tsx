import { useI18n } from '../../i18n'
import { useState } from 'react'
import { Tabs } from '../../ui/Tabs'
import ApnTab from './ApnTab'
import DataTab from './DataTab'
import TtlTab from './TtlTab'
import SmsTab from './SmsTab'

type Tab = 'apn' | 'data' | 'ttl' | 'sms'

export default function ModemGroup() {
  const { t } = useI18n()
  const [tab, setTab] = useState<Tab>('apn')

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-ink">{t("Modem")}</h1>
        <p className="mt-0.5 text-[13px] text-ink2">{t("APN profiles, data usage, TTL and SMS")}</p>
      </div>

      <Tabs
        tabs={[
          { id: 'apn', label: t('APN') },
          { id: 'data', label: t('Data') },
          { id: 'ttl', label: t('TTL') },
          { id: 'sms', label: t('SMS') },
        ]}
        active={tab}
        onChange={setTab}
      />

      {tab === 'apn' && <ApnTab />}
      {tab === 'data' && <DataTab />}
      {tab === 'ttl' && <TtlTab />}
      {tab === 'sms' && <SmsTab />}
    </div>
  )
}
