# 1.24.14 — diagnostics and independent desktop operations

**English** · [Русский](#русский)

Local candidate: macOS build **55**, Windows FileVersion **1.24.14.0**.
The modem agent remains **2.9.0-esim.6**; its binary and VPN runtime are unchanged.
Changes from [1.24.13](RELEASE-1.24.13.md):

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

No modem was changed during this work. Native Windows execution and full B28
hardware operation remain unverified. Existing hardware-specific requirements
remain in TTL, VPN and radio switching; removing agent dependencies does not
remove those requirements. See [operation requirements](OPERATION-DEPENDENCIES.md).

The previously tested B31 identifies as **CN_ZTE_MU5250V1.0.0B31 /
BD_CNMU5250V1.0.0B31**. The supplied B28 materials identify as
**FLY_CN_MU5250V1.0.0B13 / BD_FLYMODEMMU5250V1.0.0B28**.
[Collect firmware adaptation data](FIRMWARE-ADAPTATION-DATA.md).

## Русский

Локальный кандидат: macOS build **55**, Windows FileVersion **1.24.14.0**.
Агент остаётся **2.9.0-esim.6**; его бинарник и компоненты VPN не пересобирались.
Изменения относительно 1.24.13:

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
