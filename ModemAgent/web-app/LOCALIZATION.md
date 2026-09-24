# Interface languages

The dashboard supports English and Russian. English source strings are the canonical message keys and English catalog; `src/locales/ru-*.ts` provides their Russian equivalents. `i18n-core.ts` merges the four catalogs, and the catalog tests reject missing literal keys or mismatched interpolation parameters.

`I18nProvider` wraps the existing application without changing component keys. A language change therefore preserves authentication, selected tabs, open forms and their values. The selector is available before sign-in and in both desktop and mobile navigation. The browser stores `ru` or `en` under `u60.locale`; absent a valid saved value, a Russian browser language selects Russian and other languages select English. Storage failures still allow changing the language for the current page. This preference does not change the modem display or its configuration.

Components use `const { t } = useI18n()` and `t('English source', { name: value })`. Non-React helpers use `translate` from `i18n-core.ts`; their owning components must subscribe with `useI18n()`. Translate module-level option labels when rendering, rather than when the module loads. Use `formatNumber`, `formatDate`, shared `format.ts` helpers, and `translatePlural` for locale-sensitive output. The Russian carrier counter uses the one/few/many/other forms, including 1, 2, 5, 21, 22 and 25.

SSID, APN values, device names, SMS contents, addresses and raw diagnostic output are data and must not be passed through a guessed translation. Errors show a registered localized message or an honest general failure, with technical details available separately. Toasts and confirmation dialogs retain the original message key and interpolation values so that already displayed messages can follow a language change.

Run `node --test tools/test-i18n.cjs`, `npm run lint` and `npm run build` after editing translations. Browser acceptance also checks both languages, both themes and narrow/wide layouts, including language changes while a form has unsaved input.
