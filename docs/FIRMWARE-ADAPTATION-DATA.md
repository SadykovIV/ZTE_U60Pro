# Firmware adaptation data / Данные для адаптации прошивки

## English

In **ZTE U60Pro Manager 1.24.11**, connect through SSH, then open **Modem preparation → Diagnostics → Collect firmware adaptation data** and choose a ZIP destination. One archive contains a **fresh technical survey** and the available fixed firmware files. You do not need a separate research export. The ZIP is saved locally and is not uploaded automatically.

### What the ZIP contains

- **Research specification revision 10: 55 probes.** The survey covers application dependencies, projected runtime state and RPC schemas. Failed, missing and unassessed observations remain distinct. Schemas are read through introspection. Separate probes invoke only selected read methods.
- **Up to 11 fixed files**, copied without changing their bytes:
  - Four required files: `/usr/bin/zte_topsw_devui`, `/usr/ui/language/English.ini`, `/usr/ui/language/Chinese.ini`, `/etc/init.d/zte_topsw_devui`.
  - Four optional original copies from a verified backup made by this application's screen localization.
  - Three optional fonts from `/usr/ui/fonts/`: `ZTEZhengYuan.ttf`, `Roboto.ttf`, `Zoswald-Medium-24.ttf`.
- Full Firmware/Inner and OpenWrt version fields; file sizes, SHA-256, source paths and timestamps; SSH continuity results; sanitized application activity. Earlier activity may describe a different session or modem.

Current screen files may already be patched or mounted. Unknown bytes are not labelled stock firmware. Missing optional fonts or originals are listed as omissions. Missing required files or a partial survey produce an **incomplete** archive; changed files/device/session, invalid checksums or interrupted transfers prevent a completed archive. A size omission does not mean incompatible firmware. If CID or boot evidence is unavailable, the manifest records weaker binding rather than claiming full identity verification.

### Evidence and its limits

| Component | Collected evidence | What still needs separate validation |
|---|---|---|
| SSH, preparation, agent | Platform, tools, private installation paths, startup metadata, process/disk agreement, selected agent mode, HTTP status codes | Authentication, installation/rollback and each hardware operation. `discovery` is an intentional restricted mode; `401` means authentication is required. Neither proves a broken agent. |
| Screen localization | Current/original ELF and language resources, init script, available fonts, hashes and mount metadata | Exact patch ABI, glyph coverage and a real install/restore/display check |
| Launcher pages | OEM ABI hashes, installed service state, mapped library/ready-process agreement, fixed failure codes and VPN process metadata | Hook addresses, object layouts, rendering, gestures, sleep/wake and recovery |
| VPN and Wi-Fi | Component/service hashes and pending state, guest timers and selected UCI fields, hostapd state, TUN/modules, reserved routing occupancy, RPC input schemas | Actual core/profile validity, network setup, traffic isolation and enable/disable behavior. Installed files are not proof that VPN works. |
| TTL, IMEI, backups, applications | Read-only dependency/layout facts, TTL settings format, APN mode, diagnostic-router/ABI metadata, storage and package tools | TTL packet behavior, NV reads/writes, backup restore, application install/rollback. No IMEI/NV operation is performed by this capture. |
| Physical SIM/eUICC and built-in ZTE SIM | Vendor API/symbol availability, component hashes, passive QRTR/module/device metadata and card-lock metadata | Card type, selected physical route, standard ISD-R access and profile management. These remain unknown without a separate card operation. |

The capture does **not** run eSIM list/SELECT/APDU, switch SIM slots, power-cycle a card, change radio or Wi-Fi settings, start components, acquire/clear their operation locks or grant write permission. Agent environment data is projected to one mode enum; raw environment, startup scripts and credentials are not exported. Raw HTTP responses, user configurations, VPN/APN/SIM profiles, SSH keys, IMEI/NV records and full flash images are excluded. Share the ZIP privately for diagnosis; vendor binaries and fonts are not application assets for redistribution.

### What is known about the supplied B28 build

The examined files identify **Firmware `FLY_CN_MU5250V1.0.0B13` / Inner `BD_FLYMODEMMU5250V1.0.0B28`**. Its Chinese dictionary and screen init match the compared B31 files; its English dictionary lacks four keys, and its screen ELF differs. A font-patch candidate passed **offline checks only**. Font files and an on-device install/restore/render check are still needed.

Launcher analysis found unique normalized candidates for 31 of 32 absolute function references, together with candidate hook slots. This is not a working B28 Launcher adapter: one function remains ambiguous, and data layout, hooks and runtime behavior still need verification. Observed `discovery` mode explains restricted API responses such as `403`; `401` alone is an authentication result. Do not install a B31 binary patch on B28 by bypassing its ABI check.

## Русский

В **ZTE U60Pro Manager 1.24.11** подключитесь по SSH, откройте **«Подготовка модема → Диагностика → Собрать данные для адаптации прошивки»** и выберите место для ZIP. В один архив входят **свежее техническое исследование** и доступные файлы прошивки из фиксированного списка. Отдельно экспортировать исследование не нужно. ZIP сохраняется на компьютере и автоматически никуда не отправляется.

### Что входит в архив

- **Спецификация исследования revision 10: 55 проверок.** Сбор включает зависимости функций, выбранные признаки текущего состояния и схемы RPC. Ошибка, отсутствие и непроверенный факт различаются. Схемы читаются через introspection; отдельные проверки вызывают только выбранные методы чтения.
- **До 11 файлов** с сохранением исходных байтов:
  - Четыре обязательных: `/usr/bin/zte_topsw_devui`, `/usr/ui/language/English.ini`, `/usr/ui/language/Chinese.ini`, `/etc/init.d/zte_topsw_devui`.
  - Четыре необязательные исходные копии из проверенного бэкапа нашей русификации.
  - Три необязательных шрифта из `/usr/ui/fonts/`: `ZTEZhengYuan.ttf`, `Roboto.ttf`, `Zoswald-Medium-24.ttf`.
- Полные Firmware/Inner и версия OpenWrt; размеры, SHA-256, пути источников и время сбора; результаты проверки неизменности SSH-сеанса; очищенный журнал программы. Прежние записи журнала могут относиться к другому сеансу или модему.

Текущие экранные файлы могут быть уже изменены или смонтированы поверх штатных. Неизвестные байты не объявляются заводскими. Отсутствующие шрифты и исходные копии отмечаются как пропуски. Отсутствие обязательных файлов или неполное исследование дают **неполный архив**. Смена файла, устройства или сеанса, неверный хэш и обрыв передачи не позволяют подтвердить полный архив. Превышение размера не означает несовместимость прошивки. Если CID или boot недоступны, манифест явно указывает ограниченную проверку идентичности.

### Собранные сведения и границы выводов

| Компонент | Что собирается | Что требует отдельной проверки |
|---|---|---|
| SSH, подготовка, агент | Платформа, инструменты, приватные пути установки, метаданные startup, совпадение процесса и файла, выбранный режим агента, HTTP-коды | Авторизация, установка/откат и каждая аппаратная операция. `discovery` — предусмотренный ограниченный режим; `401` требует авторизации. Это не доказательства поломки агента. |
| Русификация экрана | Текущие/исходные ELF и словари, init, доступные шрифты, хэши и метаданные монтирования | Точный ABI патча, наличие глифов, реальная установка/восстановление и отображение |
| Дополнительные страницы | ABI-хэши штатного экрана, состояние службы, загруженная библиотека и готовность процесса, фиксированные ошибки и метаданные VPN-процесса | Адреса хуков, структура объектов, отрисовка, жесты, сон/пробуждение и восстановление |
| VPN и Wi-Fi | Хэши компонентов/службы, незавершённые изменения, таймеры и выбранные поля UCI, hostapd, TUN/модули, занятость служебной маршрутизации, входные схемы RPC | Работа ядра/профиля, настройка сети, изоляция трафика, включение/выключение. Наличие файлов не доказывает работу VPN. |
| TTL, IMEI, бэкапы, приложения | Зависимости и структура файлов, формат настроек TTL, режим APN, метаданные diag-router/ABI, хранилище и пакетные инструменты | Реальный TTL пакетов, чтение/запись NV, восстановление бэкапа, установка/откат приложений. Этот сбор не выполняет операций IMEI/NV. |
| Физическая SIM/eUICC и встроенная ZTE SIM | Наличие vendor API/символов, хэши компонентов, пассивные сведения QRTR/модулей/устройств и метаданные блокировки карты | Тип карты, выбранный физический маршрут, стандартный ISD-R и управление профилями. Без отдельной операции с картой они остаются неизвестными. |

Сбор **не выполняет** eSIM list/SELECT/APDU, переключение слота, питание карты, изменение радио или Wi-Fi, запуск компонентов, захват/очистку их блокировок и не разрешает запись. Из окружения агента выделяется только режим; полное окружение, startup и учётные данные не экспортируются. Исключены сырые HTTP-ответы, пользовательские конфигурации, VPN/APN/SIM-профили, SSH-ключи, IMEI/NV и полный образ памяти. Передавайте ZIP приватно для диагностики; бинарники и шрифты производителя не предназначены для публикации вместе с программой.

### Что известно о присланной B28

Исследована связка **Firmware `FLY_CN_MU5250V1.0.0B13` / Inner `BD_FLYMODEMMU5250V1.0.0B28`**. Китайский словарь и init экрана совпадают со сравниваемыми файлами B31; в английском словаре отсутствуют четыре ключа, а экранный ELF отличается. Кандидат шрифтового патча прошёл **только офлайн-проверки**. Нужны файлы шрифтов и последующая проверка установки, восстановления и отображения на устройстве.

Для Launcher найдены уникальные нормализованные кандидаты для 31 из 32 абсолютных ссылок на функции и кандидаты слотов хуков. Это ещё не рабочий адаптер B28: одна функция неоднозначна, структура данных, хуки и поведение требуют проверки. Наблюдаемый режим `discovery` объясняет ограничения API, включая `403`; сам по себе `401` означает необходимость авторизации. Не устанавливайте бинарный патч B31 на B28 через обход проверки ABI.
