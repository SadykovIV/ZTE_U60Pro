# 1.24.11 — firmware adaptation research

Local candidate: macOS ARM64 build 52 and Windows x64 FileVersion 1.24.11.0.
Bundled agent remains 2.9.0-esim.4. This version is not published to GitHub.

## Changes from 1.24.10

- **Collect firmware adaptation data** now includes a fresh technical survey in the same ZIP as screen files and sanitized application activity.
- Research expands from 46 to 55 probes: application RPC schemas, agent mode, component installation state, Launcher readiness, VPN/Wi-Fi, TTL/APN and passive eSIM dependencies.
- Available screen fonts are included for Cyrillic glyph and layout analysis. Missing optional files are listed separately.
- Both desktop clients verify that file capture and research belong to the selected SSH session. Partial technical results remain available; a changed device or interrupted session cannot produce a confirmed archive.

Use **Modem preparation → Diagnostics → Collect firmware adaptation data**.
[Collection details and component adaptation work](FIRMWARE-ADAPTATION-DATA.md).

## Validation scope

Focused Swift and C# tests exercise collection, continuity, cancellation, partial results, redaction, archives and UI wiring. Shell fixtures execute the bundled collection commands. Read-only hardware validation uses **CN_ZTE_MU5250V1.0.0B31 / BD_CNMU5250V1.0.0B31**.

The supplied FLY B28 archive was checked offline. Screen and Launcher adaptation, VPN and TTL on B28 still require implementation and device validation. Native Windows execution is not available on this Mac. Package manifests and delivery verification accompany the local archives.

## Русский

Локальная версия: macOS ARM64 build 52 и Windows x64 1.24.11.0. Агент остаётся 2.9.0-esim.4. На GitHub эта версия пока не опубликована.

### Изменения относительно 1.24.10

- Кнопка **«Собрать данные для адаптации прошивки»** сохраняет свежее исследование, экранные файлы и очищенный журнал в один ZIP.
- Вместо 46 — 55 проверок: схемы RPC, режим агента, состояние установки компонентов, готовность Launcher, VPN/Wi-Fi, TTL/APN и пассивные зависимости eSIM.
- Добавлены доступные шрифты экрана для проверки кириллицы и размеров текста. Отсутствующие необязательные файлы перечисляются отдельно.
- Сбор файлов и исследование проверяются в рамках выбранного SSH-сеанса. Частичные технические результаты сохраняются; смена устройства или потеря сеанса не выдаются за подтверждённый сбор.

Путь: **«Подготовка модема → Диагностика → Собрать данные для адаптации прошивки»**.

Проверяются сценарии сбора, смены устройства, отмены, неполных результатов, удаления секретов, упаковки и подключения кнопок. Shell-тесты выполняют реальные команды сборщика на тестовых данных. Аппаратная проверка чтением проводится на **CN_ZTE_MU5250V1.0.0B31 / BD_CNMU5250V1.0.0B31**.

Архив FLY B28 исследован офлайн. Адаптация экрана и Launcher, а также VPN и TTL на B28 ещё требуют доработки и проверки на устройстве. Запуск Windows-программы на настоящей Windows здесь не проверен. Манифесты и результаты проверки поставляются вместе со сборками.
