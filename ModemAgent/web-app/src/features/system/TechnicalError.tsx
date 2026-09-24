import { useI18n, isKnownMessage, retranslate } from '../../i18n'

/** Keep the modem's diagnostic bytes available without making them the UI message. */
export function TechnicalError({ detail, fallback }: { detail: string; fallback: string }) {
  const { t } = useI18n()
  return (
    <div role="alert" className="text-[12px] text-danger">
      <p>{isKnownMessage(detail) ? retranslate(detail) : t(fallback)}</p>
      <details className="mt-1 text-ink3">
        <summary className="cursor-pointer">{t('Technical details')}</summary>
        <pre className="mt-1 whitespace-pre-wrap break-words font-mono text-[11px]">{detail}</pre>
      </details>
    </div>
  )
}
