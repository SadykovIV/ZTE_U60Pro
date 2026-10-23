# 1.27 — automatic component replacement

[GitHub release](https://github.com/SadykovIV/ZTE_U60Pro/releases/tag/v1.27) · [Windows x64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.27/ZTE-U60Pro-Manager-1.27-Windows-x64-portable.zip) · [macOS ARM64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.27/ZTE-U60Pro-Manager-1.27-macOS-arm64.zip)

macOS build **67** · Windows FileVersion **1.27.0.0** · Agent **2.9.0-esim.14** · VPN controller **1.5.0**.

## Русский

Подготовка модема и установка комплектного агента используют один путь замены
агента, SSH и веб-панели. Флажки принудительной/чистой установки удалены. Если
доступ SSH уже есть, повторное получение ADB не требуется. При первой установке
программа использует доступный проверенный способ подготовки.

Старые исполняемые файлы, сценарии и оставшиеся журналы сохраняются перед заменой.
Неизвестная версия старого компонента, устаревший owner, брошенная блокировка,
каталог или ссылка вместо файла запуска больше не требуют заводского сброса.
Установщик не запускает неизвестные старые сценарии. Проверки текущего устройства,
целостности комплекта и действительно выполняющейся операции остаются.

Работающий SSH сохраняется. VPN-профили, настройки дополнительных страниц,
пользовательские ключи, резервные копии, штатные настройки и SIM/eUICC не очищаются.
При установке агента прежний пароль переносится на самом модеме из обычного
файла запуска. Если восстановить его невозможно, пароль задаётся в существующих
полях подготовки. Подготовка применяет введённый пароль агента.

После потери соединения приложение проверяет сохранённый этап. Ошибка обновления
панели не запускает повторную замену уже установленного агента. Старые запросы
очистки, отправленные предыдущей версией, продолжаются с сохранёнными условиями;
ещё не начатая очистка отменяется перед обычной заменой компонентов.

Общий флажок отключения проверки прошивки удалён. Требования проверяются отдельно
для каждой операции. Добавлены варианты IMEI и переключения физической eUICC для
известной B04 без `modem.b16`; ошибка чтения или симлинк не считаются отсутствием.
Для новой прошивки используется уже существующий сбор данных в «Диагностике».
Архив сохраняется локально и автоматически никуда не отправляется.

### Проверки и ограничения

Проверяются реальные shell-установщики в изолированной файловой системе,
восстановление и журналирование обоих клиентов, совместимость прошивок,
eSIM, VPN-контроллер и веб-панель. Состав и результаты итогового прогона входят
в `VERIFICATION.json` релиза. Встроенные файлы, контрольные суммы и содержимое
обоих архивов проверяются перед публикацией.

Новой установки на модемах друзей или рабочем модеме владельца в этом выпуске
не проводилось. Windows собран на macOS; запуск EXE на Windows не проверен.
По B02 отсутствуют необходимые исходные данные для ряда адаптеров, поэтому
полная поддержка всех функций B02 не заявляется. Для B28/B04 наличие адаптеров
и локальные тесты также не означают проверки каждой функции на устройстве.
Подробности: [матрица совместимости](https://github.com/SadykovIV/ZTE_U60Pro/blob/v1.27/docs/FIRMWARE-COMPATIBILITY.md).

## English

Modem preparation and bundled-agent installation now share automatic replacement
of the agent, SSH components and dashboard. The force/clean-install checkboxes
are removed. An existing verified SSH connection is used directly; first-time
preparation uses an available verified bootstrap method.

Old program files and abandoned installation state are archived before replacement.
Unknown old versions, stale ownership markers, abandoned locks, and a directory
or symlink in place of a startup file no longer require a factory reset. Unknown
old scripts are not executed by the installer. Device binding, payload integrity
and genuinely active-operation checks remain.

The active SSH connection, VPN profiles, display settings, user keys, backups,
stock settings and SIM/eUICC data are retained. Agent installation preserves
literal credentials on the modem; if they cannot be recovered, use the existing
password fields in preparation. A lost reply is reconciled from recorded state.
A dashboard failure does not replay a completed core installation. Previously
dispatched cleanup retains its original intent; undispatched cleanup is cancelled.

The global firmware bypass checkbox is removed. Each feature checks its own
requirements. Known B04 variants without `modem.b16` gain IMEI and physical-eUICC
radio-switch support with measured prerequisites. Firmware adaptation data uses
the existing Diagnostics export and is never uploaded automatically.

Verification covers isolated production shell installers, both desktop recovery
paths, firmware fixtures, eSIM, VPN and web tests. The release's `VERIFICATION.json`
records the final results. No new hardware installation or native Windows run is
claimed. B02 still lacks evidence for several adapters; see the
[compatibility matrix](https://github.com/SadykovIV/ZTE_U60Pro/blob/v1.27/docs/FIRMWARE-COMPATIBILITY.md).
