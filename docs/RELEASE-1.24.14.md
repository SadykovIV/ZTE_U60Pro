# 1.24.14 — diagnostics and independent desktop operations

**English** · [Русский](#русский)

macOS build **55**, Windows FileVersion **1.24.14.0**.
The modem agent remains **2.9.0-esim.6**; its binary and VPN runtime are unchanged.
## Since the published 1.24.9

This release includes the local 1.24.10–1.24.14 changes: two diagnostic exports,
expanded firmware capture, exact B31/FLY B28 screen and Launcher profiles,
custom-agent installation on Windows, removal of the global agent diagnostic
mode, and desktop VPN profile management. Independent operations no longer
install or block one another through unrelated components.

## Changes from local 1.24.13

- Diagnostics has two actions: **Logs and journals** and **Firmware adaptation
  data**. The first exports preparation, connections, operation errors and available
  modem logs, including an offline fallback. The second combines a fresh survey
  and firmware files in one ZIP. Detailed checks stay in the archive.
- Desktop VPN management now lists, imports, activates, renames and deletes profiles
  and controls VPN Wi-Fi. The desktop, agent and modem screen use the same profiles.
  Import accepts one VLESS link from text or a UTF-8 file and leaves it inactive.
- VPN, agent and Launcher installers no longer update one another. TTL, eSIM and
  VPN desktop operations work over SSH without the permanent agent. The eSIM
  screen page still needs its local executable helper.
- IMEI changes require an existing SSH connection and run only as an explicit
  desktop action, with a backup before writing. Unrelated IMEI/preparation journals
  no longer block TTL, Launcher, opkg or the SSH terminal.
- Removed a duplicate remote lock from Windows VPN profile operations. Explicit
  VPN installation verifies the installed result; macOS also checks the existing
  core checksum. A large installation-log history no longer prevents ZIP export.

## Verification and limits

Focused local checks cover macOS application state, diagnostics, firmware support,
VPN profiles/installers, TTL, Launcher, agent installation and opkg; Windows checks
cover profile dispatch, installers, terminal, diagnostics export and RU/EN UI.
Package checks verify versions, compiled source identity, bundled resources,
English catalogs and ZIP contents. Tests use simulated modem responses.

No modem was changed during the 1.24.14 desktop refactor and packaging. Native Windows execution and full B28
hardware operation remain unverified. Existing hardware-specific requirements
remain in TTL, VPN and radio switching; removing agent dependencies does not
remove those requirements. See [operation requirements](OPERATION-DEPENDENCIES.md).

The previously tested B31 identifies as **CN_ZTE_MU5250V1.0.0B31 /
BD_CNMU5250V1.0.0B31**. The supplied B28 materials identify as
**FLY_CN_MU5250V1.0.0B13 / BD_FLYMODEMMU5250V1.0.0B28**.
[Collect firmware adaptation data](FIRMWARE-ADAPTATION-DATA.md).

## Русский

macOS build **55**, Windows FileVersion **1.24.14.0**.
Агент остаётся **2.9.0-esim.6**; его бинарник и компоненты VPN не пересобирались.
### Относительно опубликованной 1.24.9

Включены изменения локальных 1.24.10–1.24.14: два диагностических экспорта,
расширенный сбор прошивки, точные профили экрана и Launcher для B31/FLY B28,
установка своего агента в Windows, удаление общего диагностического режима
агента и управление VPN-профилями из программы. Независимые операции разделены.

### Изменения относительно локальной 1.24.13

- В диагностике два действия: **«Логи и журналы»** и **«Данные для адаптации
  прошивки»**. Первый ZIP содержит подготовку, подключения, ошибки операций
  и доступные журналы модема; без SSH сохраняются локальные данные. Второй
  объединяет свежее исследование и файлы прошивки. Подробные проверки — в ZIP.
- Программа управляет VPN-профилями: список, импорт, активация, переименование,
  удаление и VPN Wi-Fi. Программа, агент и экран используют одни профили.
  Импорт принимает одну VLESS-ссылку или текстовый файл UTF-8 и не активирует её.
- Установки VPN, агента и Launcher разделены. Для TTL, eSIM и VPN из программы
  постоянный агент не нужен. Страница eSIM на модеме требует свой исполняемый
  компонент, который вызывается по запросу.
- Смена IMEI — отдельное действие из программы после подключения по SSH,
  с резервной копией перед записью. Чужие журналы IMEI/подготовки больше не
  блокируют TTL, Launcher, opkg и терминал.
- Убрана двойная блокировка VPN-профилей в Windows. Установщик подтверждает
  итог установки, а macOS дополнительно проверяет целостность уже установленного
  ядра. Большое число старых установочных журналов больше не срывает экспорт ZIP.

Локальные тесты проверяют операции и ошибки на моделях транспорта, интерфейс
RU/EN, архивы и установщики. Сборки сверяются с исходниками, версиями, ресурсами
и переводами. На модем в рамках этой работы ничего не устанавливалось.
Запуск на настоящей Windows и полная работа B28 ещё не проверены. Требования
TTL, VPN и переключения радио к прошивке сохранены.
[Матрица зависимостей и ограничений](OPERATION-DEPENDENCIES.md).
