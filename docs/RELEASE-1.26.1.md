# 1.26.1 — clean reinstall and interrupted-operation recovery

[GitHub release](https://github.com/SadykovIV/ZTE_U60Pro/releases/tag/v1.26.1) · [Windows x64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.26.1/ZTE-U60Pro-Manager-1.26.1-Windows-x64-portable.zip) · [macOS ARM64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.26.1/ZTE-U60Pro-Manager-1.26.1-macOS-arm64.zip)

macOS build **66** · Windows FileVersion **1.26.1.0**.
Agent **2.9.0-esim.13** and VPN controller **1.5.0** retain their versions.

## English

Version 1.26 could reject its own installed VPN files during component cleanup:
the cleanup helper still expected older service, manager and firewall hashes.
The desktop client then reduced `SERVICE` and `VPN_INTEGRITY` to a generic
unconfirmed-cleanup message. The defect was reproduced locally; nine of the
previous 34 cleanup tests failed on the 1.26 source. That suite was missing
from the aggregate modem build checks.

This update repairs the clean-reinstall path, including its continuation after
interruption or modem reboot. It preserves the component archive before removal, stops owned VPN
services and separates reversible preparation from the recorded cleanup steps.
Explicit clean reinstall can retire an abandoned owned installation after
verifying the device and absence of its installer process; it preserves the old
journal and current files instead of requiring a factory reset.

Cleanup errors include a fixed reason and the failed stage. A lost completion
response is followed by a bounded read-only status check, without sending a
second removal command. Desktop builds also check that the cleanup helper accepts
the exact bundled payloads. The full cleanup and installer suites are included in `build.py --tests`.

To continue an existing cleanup, open 1.26.1 with the same saved connection and
choose **Continue clean reinstall**. To start over after a preparation error,
select **Clean reinstall**. Existing backup archives are retained. VPN profiles,
additional display pages and dashboard components are part of cleanup; they can
then be installed again. The modem's stock settings, IMEI, SIM/eUICC data and
unrelated services are outside this cleanup.

### Verification scope

The supplied screenshot does not contain the remote failure code. The reproduced
defect explains one possible cause of its message, but is not proof of the exact
remote state. The earlier device photograph identifies XCBZ HK B04; no supplied
report binds the screenshot's identifier to a firmware image. Firmware names do
not replace measured device identity.

Local checks passed: 57 shell cleanup tests, 97 installer tests, 454 Windows UI
checks, plus desktop recovery and backup tests. The aggregate modem build also
passed agent (190), eSIM bridge (67), VPN controller (74) and web (74) tests.
Three optional controller tests requiring external fixtures were not run. There is no new installation on the reported B04 device or the owner's
working modem. Windows is cross-built on macOS; native Windows execution remains
unverified. The earlier IKEv2/display live checks belong to 1.26 and are not new
hardware validation of this installer patch.

## Русский

В 1.26 очистка могла отвергать VPN-компоненты из собственного комплекта: в ней
остались старые контрольные суммы службы, manager и firewall. Клиент превращал
ошибки `SERVICE` и `VPN_INTEGRITY` в общее «очистка не подтверждена». Дефект
воспроизведён: на исходниках 1.26 падали 9 из прежних 34 тестов очистки. Эти тесты
не входили в общий запуск проверок модемной сборки.

Исправлена чистая переустановка и продолжение после прерывания или перезагрузки модема. Сначала сохраняется
проверенный архив компонентов, затем останавливаются собственные службы VPN и
выполняются записанные шаги очистки. При явно выбранной чистой переустановке можно
архивировать брошенную собственную установку после проверки устройства и отсутствия
её процесса. Старый журнал и текущие файлы сохраняются; заводской сброс не требуется.

В ошибках видны этап и конкретный код. После потери ответа о завершении выполняется
ограниченная проверка состояния без повторной команды удаления. Сборки проверяют,
что очистка принимает именно вложенные компоненты. Полные тесты очистки и установщика добавлены
в `build.py --tests`.

Для уже начатой очистки откройте 1.26.1 с прежним подключением и нажмите
**«Продолжить чистую установку»**. Для новой попытки после ошибки подготовки
выберите **«Чистая переустановка»**. Прежние резервные копии сохраняются. Очистка
включает VPN-профили, дополнительные страницы дисплея и компоненты веб-панели;
после неё их можно установить заново. Штатные настройки, IMEI, SIM/eUICC и
посторонние службы в эту очистку не входят.

### Границы проверки

На скриншоте нет конкретного кода удалённой ошибки. Найденный дефект объясняет
одну из причин такого сообщения, но не доказывает состояние удалённого устройства.
На прежнем фото указана XCBZ HK B04; присланные отчёты не связывают идентификатор
нового скриншота с образом прошивки.

Пройдены 57 shell-тестов очистки, 97 тестов установщика, 454 проверки интерфейса
Windows и тесты восстановления и резервных копий обоих клиентов. Общая сборка
также прошла тесты агента (190), моста eSIM (67), VPN-контроллера (74) и панели
(74). Три дополнительных теста контроллера с внешними тестовыми данными не запускались.
Новой установки на B04 друга и на рабочем модеме владельца не было. Windows собран
на macOS; запуск на самой Windows ещё не проверен. Прежние живые проверки IKEv2
и дисплея относятся к 1.26 и не подтверждают новую установку этого исправления.
