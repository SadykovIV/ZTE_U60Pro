import { ruCore } from './locales/ru-core'
import { ruFeatures } from './locales/ru-features'
import { ruTtl } from './locales/ru-ttl'
import { ruApi } from './locales/ru-api'
import { ruVpn } from './locales/ru-vpn'
import { ruEsim } from './locales/ru-esim'

export type Locale = 'ru' | 'en'
export type Values = Record<string, string | number>
export const LOCALE_KEY = 'u60.locale'
export const ru: Record<string, string> = { ...ruCore, ...ruFeatures, ...ruTtl, ...ruApi, ...ruVpn, ...ruEsim }

export function resolveLocale(saved: string | null, language: string): Locale {
  if (saved === 'ru' || saved === 'en') return saved
  return /^ru(?:-|$)/i.test(language) ? 'ru' : 'en'
}

function initialLocale(): Locale {
  let saved = null
  try { saved = localStorage.getItem(LOCALE_KEY) } catch { /* Private browsing may block storage. */ }
  return resolveLocale(saved, typeof navigator === 'undefined' ? 'en' : navigator.language)
}

let currentLocale: Locale = initialLocale()
const renderedMessages = new Map<string, { key: string; values: Values }>()
export function getLocale(): Locale { return currentLocale }
export function setCurrentLocale(locale: Locale) { currentLocale = locale }
export function localeTag(locale = currentLocale) { return locale === 'ru' ? 'ru-RU' : 'en-US' }

/** Only explicitly registered source keys are translated; user data is never inferred. */
export function translate(key: string, values: Values = {}, locale = currentLocale): string {
  const template = locale === 'ru' ? ru[key] ?? key : key
  const result = template.replace(/\{([A-Za-z_][A-Za-z_0-9]*)\}/g, (token, name: string) =>
    Object.prototype.hasOwnProperty.call(values, name) ? String(values[name]) : token,
  )
  if (Object.hasOwn(ru, key)) {
    if (renderedMessages.size > 1024) renderedMessages.clear()
    renderedMessages.set(result, { key, values: { ...values } })
  }
  return result
}

export function formatNumber(value: number, options: Intl.NumberFormatOptions = {}, locale = currentLocale): string {
  return new Intl.NumberFormat(localeTag(locale), options).format(value)
}

export function formatDate(value: Date | number, options: Intl.DateTimeFormatOptions = {}, locale = currentLocale): string {
  return new Intl.DateTimeFormat(localeTag(locale), options).format(value)
}

const pluralMessages = {
  'active carriers': {
    en: { one: '{count} active carrier', other: '{count} active carriers' },
    ru: { one: '{count} активная несущая', few: '{count} активные несущие', many: '{count} активных несущих', other: '{count} активной несущей' },
  },
} as const

export function translatePlural(key: keyof typeof pluralMessages, count: number, locale = currentLocale): string {
  const forms: Partial<Record<Intl.LDMLPluralRule, string>> = pluralMessages[key][locale]
  const category = new Intl.PluralRules(localeTag(locale)).select(count)
  return (forms[category] ?? forms.other!).replace('{count}', formatNumber(count, {}, locale))
}

export function isKnownMessage(message: string): boolean {
  return renderedMessages.has(message) || Object.hasOwn(ru, message) || Object.values(ru).includes(message)
}

/** Re-render transient UI messages after a language change without translating raw diagnostic data. */
export function retranslate(message: string): string {
  const source = renderedMessages.get(message)
  return source ? translate(source.key, source.values) : translate(message)
}
