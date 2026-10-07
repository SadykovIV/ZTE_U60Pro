# 1.24.13 — remove the agent's global diagnostic mode

**English** · [Русский](#русский)

Local candidate: macOS build **54**, Windows FileVersion **1.24.13.0**,
agent **2.9.0-esim.6**. Changes from [1.24.12](RELEASE-1.24.12.md):

- Removed the global `discovery` API/CLI restriction. The agent provides information
  and controls, with authentication and checks for each operation. Firmware research
  stays in the desktop application over SSH and does not require the agent.
- Preparation no longer creates or verifies a diagnostic mode. Windows status no
  longer makes an additional process-environment query. Existing startup scripts
  remain recognized during updates and recovery.
- Removed a false installation failure caused by checking an old startup address.
  The existing login verifies the selected address. A saved private LAN address is
  a fallback; the agent follows the current LAN setting after an address change.
- Missing status sources return an unavailable/partial result. Disabled charge
  control does not change charging when a cable is unplugged. Legacy DNS cleanup
  checks that its own old redirect is still active before changing it.

## Verification and limits

- 178 Rust tests; plain-agent compilation; Linux ARM64 eSIM agent build.
- Local HTTP checks: 20 information routes, operation-specific errors, authentication,
  legacy startup mode ignored, absent VPN component, and refusal to restart an
  uninstalled test process. Vendor commands were stubs; no modem was changed.
- macOS and Windows preparation, installation, recovery and status regressions;
  shared installer/service tests and source-package checks.
- Desktop package audits check versions, compiled source identity, resource hashes,
  ZIP contents and English catalogs. Native Windows execution remains unverified.

This release removes software blockers. Full B28 functionality, including VPN/TTL,
radio/NV writes, USB behavior and eUICC operations, still needs checks on that modem.
No new on-device test was performed for this release.

The previously tested B31 device identifies as **CN_ZTE_MU5250V1.0.0B31 /
BD_CNMU5250V1.0.0B31**. The supplied B28 files identify as
**FLY_CN_MU5250V1.0.0B13 / BD_FLYMODEMMU5250V1.0.0B28**.
[Collect data for firmware adaptation](FIRMWARE-ADAPTATION-DATA.md).

## Русский

Локальный кандидат: macOS build **54**, Windows FileVersion **1.24.13.0**,
агент **2.9.0-esim.6**. Изменения относительно 1.24.12:

- Удалён общий режим `discovery`, блокировавший HTTP API и CLI. Агент предоставляет
  информацию и управление с авторизацией и проверками каждой операции.
  Исследование прошивки выполняет программа по SSH и не требует агента.
- Подготовка больше не создаёт и не проверяет диагностический режим. Статус агента
  в Windows не делает дополнительный запрос окружения процессов. Старые сценарии
  запуска распознаются при обновлении и восстановлении.
- Удалена ложная ошибка установки из-за проверки старого адреса в сценарии запуска.
  Доступ подтверждает существующая проверка входа по выбранному адресу. Сохранённый
  адрес служит запасным: после смены LAN агент использует текущую настройку.
- Недоступные источники статуса дают явный неполный результат или ошибку.
  Отключённая политика зарядки не меняет зарядку при отключении кабеля.
  Очистка старой настройки DNS проверяет, что прежнее перенаправление ещё активно.

Проверены 178 Rust-тестов, сборки обычного и eSIM-агента, локальный HTTP API,
сценарии подготовки и восстановления macOS/Windows, установщики и упаковка.
Команды модема в HTTP-тесте заменены заглушками. Архивы приложений проверяются
по версиям, исходникам, ресурсам и переводам; запуск на настоящей Windows
не проверен.

Полная работа B28, включая VPN/TTL, запись радио/NV, USB и eUICC, ещё требует
проверки на самом модеме. В этой версии новых аппаратных проверок не проводилось.
