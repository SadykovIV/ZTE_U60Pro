# 1.25 — VPN, backups and independent modem operations

[GitHub release](https://github.com/SadykovIV/ZTE_U60Pro/releases/tag/v1.25) · [macOS ARM64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.25/ZTE-U60Pro-Manager-1.25-macOS-arm64.zip) · [Windows x64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.25/ZTE-U60Pro-Manager-1.25-Windows-x64-portable.zip)
macOS ARM64, build **64** · Windows x64, FileVersion **1.25.0.0** ·
Agent **2.9.0-esim.12** · VPN controller **1.4.1**.

## English

### Since the previous GitHub release, 1.24.14

This release includes the intervening local builds and the 1.25 audit:

- WireGuard, AmneziaWG 2/3.1, Hysteria2 and HTTPS subscriptions extend the existing
  VLESS catalogue shared by desktop, agent and Launcher. Subscriptions can be
  refreshed from the apps, web panel and modem screen.
- Extended B28/B04 component adapters, factory-reset preparation recovery,
  persistent ADB disable after verified SSH and agent Web diagnostics.
- IMEI backup/write/restore follow the actual one or two active records.
- Fixed TTL/VPN installation and updates, automatic IPA preparation, agent
  compatibility and preservation of VPN Wi-Fi state after reboot.
- Expanded adaptation data and backup coverage, improved application-history
  export, and removed more unrelated blockers from independent operations.

[Compare published versions](https://github.com/SadykovIV/ZTE_U60Pro/compare/v1.24.14...v1.25).
The detailed changes below use local build 1.24.22 as their baseline.

### Detailed changes since local 1.24.22

- Removed unrelated saved preparation/IMEI journals as blockers for TTL, VPN,
  copying backups and recovering SSH. The journals are preserved; actual
  operation locks, firmware-update checks and operation-specific recovery remain.
  Desktop TTL, VPN, eSIM, IMEI and screen operations use SSH and their own
  components; the permanent agent is optional.
- Configuration and `/data` backups follow the actual read contract rather than
  a B31-only firmware check. Radio-partition and full-device capture recognize
  the measured B31, FLY B28 and XCBZ HK B04 images and still verify the partition
  layout. Configuration backups include the VPN catalogue, Wi-Fi settings and
  Launcher layouts. Full-device restore still requires the separate offline
  environment and matching device/layout checks.
- Explicit TTL apply/disable can update known older managers with a verified
  backup and interruption recovery. Reading TTL status does not update anything
  and is not blocked by an unfinished ADB setup record.
- VPN status recognizes the previous 1.24.22 controller before an explicit
  update. Profile warnings about `spx`, TLS, IPv6 or a shortened name no longer
  appear as a failed VPN operation.
- VPN updates replace the controller's complete runtime file set, including
  the firewall and service scripts. A failed update restores the previous set;
  recovery also accepts snapshots made by the older updater. Updating the
  agent alone preserves compatibility with reviewed previous VPN controllers,
  including 1.24.22.
- Fixed a VPN boot sequence that could save Wi-Fi as disabled when IPA was not
  ready yet. Startup now registers supervised workers before waiting for IPA
  and preserves the selected Wi-Fi state. Both enabled and disabled Wi-Fi states
  survived separate hardware reboots on B31.
- Added the measured B28 radio profile for physical-eUICC switching. An empty
  eUICC can pass the selected-slot check before its first profile; activation
  still verifies the resulting SIM identity and readiness. This does not enable
  the built-in ZTE eSIM.
- Firmware adaptation now assesses each feature's actual requirements, with
  updated B28/B04 comparisons and passive radio/NV/EFS summaries. Unknown
  firmware remains available for data collection.

### Included VPN features

The features introduced in [1.24.22](RELEASE-1.24.22.md) are included: WireGuard,
AmneziaWG 2/3.1 `.conf` files, VLESS/Hysteria2 links and HTTPS subscriptions;
one profile catalogue shared by desktop, agent and Launcher; explicit activation;
subscription refresh that preserves the running connection; and automatic IPA
preparation with a backup of its settings. The agent and Launcher can refresh all
subscriptions in sequence. Deleting a subscription keeps its profiles.

The desktop downloads subscriptions through the computer's internet connection;
the agent and Launcher use the modem's connection. Refresh is manual, without a
background schedule.

### What was checked

Live checks used **ZTE U60 Pro / MU5250** with the complete firmware identity
**CN_ZTE_MU5250V1.0.0B31 / BD_CNMU5250V1.0.0B31**:

- Production installers updated the agent, VPN controller and Launcher while
  preserving profiles, active selection and page preferences. The Web dashboard
  returned HTTP 200 from the computer.
- TTL settings, VPN enable/disable, Launcher page order and screen localization
  were applied and restored. Two captured outgoing packets had TTL **64**;
  incoming TTL adjustment was not packet-tested.
- All 15 desktop read/status operations returned validated responses. SSH
  reconnect and ADB disable were checked after a normal reboot. After the VPN
  fix, two further reboots preserved enabled and disabled Wi-Fi selections.
  Both confirmed the running core, network readiness, IPA state for the current
  boot, firewall rules, HTTPS through the local proxy and the selected profile.
  SSH returned after approximately 86 and 88 seconds.
- Three subscriptions were imported and refreshed. Failed refresh preserved the
  catalogue. AWG 2 and 3.1 carried HTTPS traffic through the core's local SOCKS
  listener. The final catalogue was left on the modem: **72 profiles and three
  subscriptions**, including AWG 2/3.1. Import preserved the profile selected by
  the user. The Launcher model accepted all 72 profiles and three subscriptions;
  its pagination covered all 24 pages under AddressSanitizer/UndefinedBehaviorSanitizer.
- On **14 October 2026**, the owner confirmed that websites opened from a phone
  connected to Wi-Fi with VPN with mobile data disabled, AWG and subscription
  profiles appeared on the modem screen, and the agent's VPN error disappeared.
  This is a user-reported check; throughput and every imported profile were not tested.
- IMEI read/backup found two records and validated the backup. Configuration,
  radio-partition and `/data` copies passed stream and local hash verification.
  Fresh adaptation data and current logs were collected without omissions.
  History export now prioritizes the main application journals: all 14 daily
  journals were included, seven as their last 2 MiB. Older detailed traces remain
  subject to archive limits; the export is explicitly partial and original local
  logs remain unchanged.

B28 (**FLY_CN_MU5250V1.0.0B13 / BD_FLYMODEMMU5250V1.0.0B28**) and B04
(**XCBZ_HK_MU5250V1.0.0B04 / BD_XCBZHKMU5250V1.0.0B04**) were compared using
captured files, reports and local regression tests. These are not fresh hardware
tests of 1.25. Native Windows execution was not tested.

This audit did not perform a factory reset, IMEI write, raw/full-device restore, or live eUICC profile
installation/switching. eSIM management requires a **removable physical eUICC in
the SIM slot**; ordinary operator SIM cards cannot store these profiles. The
built-in ZTE eSIM remains unsupported.

## Русский

### Относительно предыдущего выпуска на GitHub — 1.24.14

Включены промежуточные локальные сборки и аудит 1.25:

- К общему каталогу VLESS в программе, агенте и Launcher добавлены WireGuard,
  AmneziaWG 2/3.1, Hysteria2 и HTTPS-подписки. Подписки можно обновлять из
  приложений, веб-панели и с экрана модема.
- Расширены адаптеры B28/B04; исправлены подготовка после заводского сброса,
  отключение ADB с автозапуском после проверки SSH и диагностика веб-панели.
- Бэкап, запись и восстановление IMEI учитывают одну или две активные записи.
- Исправлены установка и обновление TTL/VPN, автоматическая подготовка IPA,
  совместимость агента и сохранение состояния Wi-Fi с VPN после перезагрузки.
- Расширены данные для адаптации и возможности резервных копий, улучшена
  выгрузка истории приложения; устранены дополнительные зависимости операций.

[Сравнение опубликованных версий](https://github.com/SadykovIV/ZTE_U60Pro/compare/v1.24.14...v1.25).
Ниже — подробные изменения относительно локальной сборки 1.24.22.

### Подробные изменения относительно локальной 1.24.22

- Сохранённые журналы подготовки/IMEI больше не блокируют независимые действия:
  TTL, VPN, копирование резервных копий и восстановление SSH. Сами журналы
  сохраняются. Блокировки реально выполняемых операций, обновления прошивки и
  восстановление конкретной операции остаются. Для TTL, VPN, eSIM, IMEI и
  экранных компонентов программа использует SSH; постоянный агент необязателен.
- Копии конфигурации и `/data` проверяют фактическую возможность чтения вместо
  ограничения B31. Для копирования модемных разделов и полного устройства
  добавлены измеренные образы B28/B04 с проверкой разметки. В конфигурационную
  копию включены каталог VPN, настройки Wi-Fi и расположение страниц Launcher.
  Полное восстановление по-прежнему требует отдельной автономной среды и
  проверки устройства/разметки.
- При явном применении или выключении TTL известный старый менеджер может
  обновиться с проверенной копией и восстановлением прерванной замены. Чтение
  статуса ничего не устанавливает; запись незавершённой подготовки ADB ему не
  мешает.
- Исправлено чтение статуса VPN-контроллера из 1.24.22 перед обновлением.
  Предупреждения о `spx`, TLS, IPv6 и сокращённом имени больше не показываются
  как ошибка настройки VPN.
- Обновление VPN заменяет весь комплект файлов контроллера, включая firewall
  и службу. При ошибке возвращается предыдущий комплект; поддержано и
  восстановление из копий старого установщика. Обновление только агента
  сохраняет совместимость с проверенными предыдущими VPN-контроллерами,
  включая 1.24.22.
- Исправлен ранний запуск VPN: неготовность IPA больше не сохраняет Wi-Fi
  выключенным. Служба регистрирует управляемые процессы до ожидания IPA и
  сохраняет выбор пользователя. На B31 выполнены две перезагрузки: с включённой
  и выключенной сетью VPN. Оба состояния сохранились.
- Добавлен точный профиль радио B28 для переключения физической eUICC.
  Пустая eUICC допускается на этапе проверки выбранного слота; после активации
  сохраняются проверки SIM и её готовности. Поддержка встроенной eSIM этим не
  добавляется.
- Исследование прошивки сверяет требования отдельных функций, учитывает
  различия B28/B04 и собирает безопасные сводки радио/NV/EFS. Данные неизвестной
  прошивки можно собрать для адаптации.

### Возможности VPN в этой версии

Сохранены возможности [1.24.22](RELEASE-1.24.22.md): WireGuard, AmneziaWG 2/3.1
из `.conf`, ссылки VLESS/Hysteria2, HTTPS-подписки, общий список профилей для
программы, агента и Launcher, отдельная активация и автоматическая подготовка
IPA с резервной копией настроек. Обновление подписки сохраняет действующее
подключение. В агенте и Launcher можно последовательно обновить все подписки;
удаление подписки оставляет её профили.

Программа загружает подписки через интернет компьютера, агент и Launcher —
через интернет модема. Обновление запускается вручную, расписание не добавлено.

### Проверка и ограничения

На **ZTE U60 Pro / MU5250**, полная версия прошивки
**CN_ZTE_MU5250V1.0.0B31 / BD_CNMU5250V1.0.0B31**, проверены:

- Обновление агента, VPN и Launcher штатными установщиками с сохранением
  профилей, активного выбора и расположения страниц. Веб-панель доступна
  с компьютера (HTTP 200).
- Применение и возврат настроек TTL, включение/выключение VPN, порядка страниц
  и русификации. У двух исходящих пакетов подтверждён TTL **64**; изменение TTL
  входящих пакетов не проверялось.
- Все 15 операций чтения/проверки состояния из программы получили корректный
  ответ. После обычной перезагрузки проверены подключение по SSH и выключение
  ADB. После исправления VPN ещё две перезагрузки сохранили включённое и
  выключенное состояние Wi-Fi. В обоих случаях подтверждены работа ядра,
  готовность сети, состояние IPA для текущей загрузки, правила firewall,
  HTTPS через локальный прокси и прежний активный профиль. SSH восстановился
  примерно через 86 и 88 секунд.
- Импорт и обновление трёх подписок, сохранение каталога при ошибке загрузки;
  HTTPS через локальный SOCKS-порт ядра для AWG 2 и 3.1. На модеме оставлен
  каталог из **72 профилей и трёх подписок**, включая AWG 2/3.1. Импорт сохранил
  профиль, выбранный пользователем. Модель Launcher прочитала все 72 профиля
  и три подписки; проверены все 24 страницы под AddressSanitizer/UndefinedBehaviorSanitizer.
- **14 октября 2026 года** владелец подтвердил: сайты открываются на телефоне
  через Wi-Fi с VPN при выключенных мобильных данных; профили AWG и подписок
  видны на экране модема; ошибка VPN в веб-панели агента исчезла. Это проверка
  по сообщению пользователя. Скорость и каждый импортированный профиль не проверялись.
- Чтение двух IMEI и проверенный бэкап без записи; копирование конфигурации,
  модемных разделов и `/data` со сверкой хешей. Свежая адаптация и текущие журналы
  получены без пропусков. При выгрузке истории основные журналы имеют приоритет:
  включены все 14 дневных журналов, семь — в виде последних 2 МиБ. Старые
  подробные трассировки ограничены размером архива; выгрузка явно отмечена как
  частичная. Исходные локальные журналы сохранены.

B28 (**FLY_CN_MU5250V1.0.0B13 / BD_FLYMODEMMU5250V1.0.0B28**) и B04
(**XCBZ_HK_MU5250V1.0.0B04 / BD_XCBZHKMU5250V1.0.0B04**) проверены по
присланным файлам, журналам и локальным тестам. Свежей аппаратной проверки
1.25 на них и запуска на нативной Windows не было.

В этом аудите не выполнялись заводской сброс, запись IMEI, восстановление сырых разделов/полного
образа, установка или переключение профилей на eUICC. Для eSIM нужна
**съёмная физическая eUICC в SIM-слоте**; обычная операторская SIM такие профили
не хранит. Встроенная eSIM ZTE не поддерживается.
