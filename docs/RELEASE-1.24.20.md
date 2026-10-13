# 1.24.20 — preparation after reset / подготовка после сброса

macOS ARM64 · Windows x64 · Agent **2.9.0-esim.9** (unchanged binary / прежний бинарник).

## Русский

### Изменения

- Исправлено продолжение подготовки после перезагрузки или заводского сброса,
  если предыдущая попытка остановилась до запуска установщика. Программа снова
  проверяет устройство, сохраняет старый журнал и создаёт новый каталог установки.
  До запуска установщика можно включить чистую переустановку при повторной попытке.
- При явной чистой установке можно сохранить и закрыть нашу незавершённую
  транзакцию от предыдущей загрузки. Проверяются CID, наблюдаемые компоненты,
  журнал и отсутствие работающего установщика. Старый журнал и текущие файлы
  копируются с проверкой хэшей; прежние пароли и настройки не восстанавливаются.
  Активная операция той же загрузки и неизвестные файлы сохраняются для разбора.
- Если после сброса ADB выключен, чистая установка сначала восстанавливает USB ADB
  штатными способами через Web, затем повторно проверяет тот же модем и архивирует
  прежнюю транзакцию. Незавершённое включение ADB продолжается без повторной отправки
  уже выполненного восстановления. Очистка, остановившаяся до удаления файлов,
  сначала продолжается через SSH; после подтверждённой новой загрузки её журнал
  и скачанная резервная копия сохраняются перед новой попыткой.
- Исправлена очистка компонентов на прошивках без `/firmware/image/modem.b16`.
  Отсутствующий файл учитывается как отсутствие; существующий файл проверяется
  по его хэшу. Штатные данные модема и резервные копии сохраняются.
- Расширены «Данные для адаптации прошивки»: результаты чтения NV550 и структуры
  EFS `/config`, коды DIAG, проверки формата/CRC, состояние радио и SIM-слотов QMI,
  сведения о незавершённой подготовке. Эти временные инструменты запускаются
  программой через SSH и не требуют установленного агента. Содержимое NV/EFS
  и секреты не входят в новые отчёты этих инструментов.
- Для физической карты и встроенной eSIM собираются отдельные архивы при выбранной
  соответствующей карте. Сбор сам не переключает SIM, не перезапускает радио и
  не устанавливает профили.

### Что проверено

В журнале Windows 1.24.19 USB ADB подтвердил root и идентичность модема, затем
подготовку остановила проверка сохранённой идентичности/профиля. Чистую установку
блокировал локальный журнал. В ZIP нет прежних полей журнала, поэтому конкретное
несовпавшее поле, включая boot ID, по нему установить нельзя.

Исправления проверены локальными тестами macOS/Windows и исполнением shell-кода
на изолированных файловых системах. В этом цикле B31/B28 проверялись регрессионными
тестами. Запуска на устройстве **`XCBZ_HK_MU5250V1.0.0B04` /
`BD_XCBZHKMU5250V1.0.0B04`** у разработчика не было. Поддержка записи IMEI/NV на B04
и установки своего QR-профиля во встроенную eSIM этим выпуском не заявляется.

### Повторная проверка владельцем

1. Полностью распаковать новую сборку в отдельную папку. Сохранить данные программы
   и прежние журналы подготовки.
2. После заводского сброса подключить модем по USB. В подготовке включить флажок
   чистой установки компонентов программы с резервной копией и задать новый
   пароль агента. Дождаться проверки SSH на порту **2222**.
3. После успешного SSH выбрать физическую SIM, дождаться её готовности и собрать
   «Диагностика → Данные для адаптации прошивки».
4. Выбрать встроенную eSIM, дождаться готовности и собрать второй такой ZIP.
   Указать, какой архив относится к какой карте.
5. Если подготовка остановилась, сразу собрать «Логи и журналы». Не удалять
   вручную `active`, `lock` и резервные копии: они нужны для определения стадии.

## English

### Changes

- Preparation can resume after a reboot or factory reset when the previous attempt
  stopped before installer dispatch. The app rechecks the device, preserves the
  old journal and uses a new staging directory. A retry may enable clean reinstall
  before dispatch.
- An explicitly selected clean install can archive our interrupted transaction
  from a previous boot after checking device identity, ownership and running
  installers. Journal and current-file copies are hash-verified before ownership
  markers move. Old passwords and settings are not restored. Current-boot
  operations and unknown files remain preserved for investigation.
- If reset disabled ADB, clean setup restores USB ADB through the existing Web
  methods before verifying the same modem and archiving the old transaction.
  An interrupted ADB activation resumes without repeating a dispatched restore.
  Cleanup stopped before deletion first retries through SSH. After a verified
  reboot, its journal and downloaded backup remain preserved for the new attempt.
- Component cleanup now handles firmware with an observed missing `modem.b16`.
  OEM data and backups remain preserved.
- Firmware adaptation collects NV550/EFS structure summaries, DIAG outcomes and
  validation results, QMI radio/SIM-slot status, and preparation state. Temporary
  tools run through SSH without an installed agent. Their new reports omit raw
  NV/EFS records and secrets. Collect separate archives with the physical SIM and
  built-in eSIM selected; collection does not switch slots or provision profiles.

### Validation and retest

The supplied Windows 1.24.19 log confirms root USB ADB followed by a saved
identity/profile mismatch and a local clean-install block. It does not contain
old journal fields, so the exact differing field cannot be identified.

Local macOS/Windows and isolated shell regression tests passed. B31/B28 coverage
in this round is regression testing. **B04 hardware was not available** for a live
reset/reinstallation test. This release does not enable B04 IMEI/NV writes or
custom QR provisioning on the built-in ZTE eSIM. The agent binary remains
**2.9.0-esim.9**.

After reset, connect USB, select **clean installation with backup**, set a new
agent password and let preparation verify SSH on **2222**. Once SSH works,
collect one **Firmware adaptation data** ZIP with the physical SIM selected and
another with the built-in eSIM selected. Label both archives. If preparation
fails, export **Logs and journals** immediately and retain existing journals,
locks and backups.
