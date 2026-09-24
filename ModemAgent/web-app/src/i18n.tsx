/* eslint-disable react-refresh/only-export-components */
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { formatDate, formatNumber, getLocale, LOCALE_KEY, setCurrentLocale, translate, translatePlural, type Locale, type Values } from './i18n-core'
export { translate, translatePlural, formatDate, formatNumber, getLocale, localeTag, isKnownMessage, retranslate } from './i18n-core'
export type { Locale, Values } from './i18n-core'

function useLocaleValue() {
  const [locale, updateLocale] = useState<Locale>(getLocale)
  const setLocale = useCallback((next: Locale) => {
    setCurrentLocale(next)
    updateLocale(next)
    try { localStorage.setItem(LOCALE_KEY, next) } catch { /* The current page still changes language. */ }
  }, [])
  useEffect(() => {
    document.documentElement.lang = locale
    document.title = translate('U60 Pro — modem dashboard', {}, locale)
  }, [locale])
  return useMemo(() => ({
    locale, setLocale,
    t: (key: string, values?: Values) => translate(key, values, locale),
    tp: (key: Parameters<typeof translatePlural>[0], count: number) => translatePlural(key, count, locale),
    formatNumber: (value: number, options?: Intl.NumberFormatOptions) => formatNumber(value, options, locale),
    formatDate: (value: Date | number, options?: Intl.DateTimeFormatOptions) => formatDate(value, options, locale),
  }), [locale, setLocale])
}

const I18nContext = createContext<ReturnType<typeof useLocaleValue> | null>(null)
export function I18nProvider({ children }: { children: ReactNode }) {
  const value = useLocaleValue()
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>
}
export function useI18n() {
  const value = useContext(I18nContext)
  if (!value) throw new Error('useI18n outside I18nProvider')
  return value
}
export function LanguageSelect({ compact = false }: { compact?: boolean }) {
  const { locale, setLocale, t } = useI18n()
  return (
    <label className={`flex items-center gap-2 text-xs text-ink2 ${compact ? '' : 'w-full justify-between'}`}>
      <span className={compact ? 'sr-only' : ''}>{t('Language')}</span>
      <select value={locale} onChange={(event) => setLocale(event.target.value as Locale)} aria-label={t('Language')}
        className="h-8 max-w-[8rem] rounded-lg border border-line/12 bg-surface px-2 text-xs text-ink outline-none focus:border-accent">
        <option value="ru" lang="ru">Русский</option>
        <option value="en" lang="en">English</option>
      </select>
    </label>
  )
}
