import { Component, type ReactNode } from 'react'
import { useI18n } from '../i18n'
import { Button } from '../ui/controls'
import { Card } from '../ui/primitives'

function SectionError() {
  const { t } = useI18n()
  return <Card title={t('This section could not be opened')}>
    <div role="alert" className="space-y-3">
      <p className="text-sm text-ink2">{t('Reload the page and try again. You can also open another section.')}</p>
      <Button onClick={() => window.location.reload()}>{t('Reload page')}</Button>
    </div>
  </Card>
}

/** Keep navigation available if a section cannot render; remount on navigation. */
export default class SectionBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false }
  static getDerivedStateFromError() { return { failed: true } }
  render() { return this.state.failed ? <SectionError /> : this.props.children }
}
