# 1.24.12 — B28 screen support and firmware adaptation data

Local candidate: macOS ARM64 build 53, Windows x64 FileVersion 1.24.12.0,
and agent 2.9.0-esim.5. This candidate is not published to GitHub.

## Changes from 1.24.11

- Russian screen localization selects an exact B31 or FLY B28 patch profile.
  Launcher has separate ABI profiles for these screen binaries.
- Windows verifies the screen process after releasing the installation lock.
  A pending startup check preserves the successful file-installation result.
- SSH account/service management, diagnostic utilities, and Windows bundled
  agent/dashboard installation use the actual Linux ARM64 platform and component
  requirements. Unrelated IMEI/preparation journals no longer block these actions.
- SSClash and the application inventory use measured device identity. Reading
  private opkg status and feeds no longer requires B31; package mutations retain
  their existing checks. The stale Windows SSClash removal-script pin is fixed.
- Service management recognises current and earlier reviewed agent releases.
  The same release registry is generated into both desktop packages.
- The agent's discovery mode exposes 21 status GET routes and an authenticated
  restart of its verified own installation. Hardware changes remain restricted.
  Missing status sources are reported as unknown.
- Firmware adaptation capture includes up to 40 fixed component files, a fresh
  survey with 57 probes, and sanitized application activity in one local ZIP.
  It now covers modem/network services, libraries, USB layout and RPC schemas.

Use **Modem preparation → Diagnostics → Collect firmware adaptation data**.
[Data collected and validation limits](FIRMWARE-ADAPTATION-DATA.md).

## Firmware and validation scope

- The available test device is **CN_ZTE_MU5250V1.0.0B31 /
  BD_CNMU5250V1.0.0B31**.
- The supplied B28 files identify **FLY_CN_MU5250V1.0.0B13 /
  BD_FLYMODEMMU5250V1.0.0B28**. Localization and Launcher profiles were checked
  against these exact binaries; local tests cover installation and recovery.
- B28 hardware execution is still required. VPN/TTL traffic behavior, modem/NV
  writes, radio changes and physical eUICC switching are not validated on B28.
  This candidate does not claim complete B28 support.
- Windows is compiled and tested on this Mac; native Windows execution is not
  verified. See the accompanying build manifests and verification report.

## Русский

Локальная версия: macOS ARM64 build 53, Windows x64 1.24.12.0,
агент 2.9.0-esim.5. На GitHub эта версия пока не опубликована.

### Что изменилось

- Для русификации и Launcher добавлены отдельные точные профили B31 и FLY B28.
- В Windows проверка запуска экрана выполняется после снятия блокировки установки.
  Ожидание запуска больше не превращает успешную установку файлов в ошибку.
- Управление SSH-пользователями и службами, диагностические утилиты, установка
  агента и его веб-панели в Windows проверяют платформу и нужные компоненты.
  Чужие журналы IMEI/подготовки не блокируют эти независимые операции.
- SSClash и список приложений используют фактическую идентификацию устройства.
  Чтение состояния и источников opkg больше не требует B31; установка пакетов
  сохраняет прежние проверки. Исправлена контрольная сумма удаления SSClash в Windows.
- Управление службами распознаёт текущий агент и предыдущие проверенные сборки.
  Реестр версий синхронизируется при упаковке macOS и Windows.
- В режиме discovery доступны 21 GET-запрос состояния и перезапуск собственной
  подтверждённой установки агента после авторизации. Неизвестный источник данных
  явно отмечается; изменение аппаратных настроек пока ограничено.
- Сбор для адаптации содержит до 40 файлов компонентов, 57 свежих проверок
  и очищенный журнал действий. Добавлены сетевые и модемные службы, библиотеки,
  структура USB и схемы RPC.

Путь: **«Подготовка модема → Диагностика → Собрать данные для адаптации прошивки»**.

Проверяемый модем: **CN_ZTE_MU5250V1.0.0B31 / BD_CNMU5250V1.0.0B31**.
Присланная B28: **FLY_CN_MU5250V1.0.0B13 / BD_FLYMODEMMU5250V1.0.0B28**.
Патчи B28 проверены по её файлам и локальным сценариям установки/восстановления.
Работу на самом B28 ещё нужно проверить. VPN/TTL, запись NV, управление радио
и переключение физической eUICC на B28 пока не подтверждены. Полная поддержка B28
этой сборкой не заявляется. Нативный запуск Windows здесь также не проверен.
