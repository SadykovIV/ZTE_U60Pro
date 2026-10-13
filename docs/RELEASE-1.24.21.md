# 1.24.21 — B04 components and agent Web diagnostics

macOS ARM64 · Windows x64 · Agent **2.9.0-esim.10**.

## English

- Fixed recognition of **XCBZ_HK_MU5250V1.0.0B04 /
  BD_XCBZHKMU5250V1.0.0B04** in VPN, TTL and ADB control. The new dumps contain a
  baseband image that was unavailable in the earlier dump. Its measured hash is
  now accepted alongside the existing component checks. B31/B28 profiles remain.
- Fixed recognition of the agent and VPN controller from 1.24.20 before updating
  them. Their existing status remains readable during an upgrade.
- Applying TTL settings can update the known manager shipped in 1.24.20, with a
  verified backup and recovery from an interrupted replacement. Reading status
  does not install or update components.
- Checking or installing the agent now reports HTTP availability of the Web UI
  on port **8080**, separately through modem loopback, its LAN address and the
  computer. Results appear in the app journal and diagnostic ZIP. A failed HTTP
  check is a warning and does not invalidate a successful agent installation.
- Fixed the agent's reported API version; it now comes from the build version.
  The updated agent recognizes the new VPN and TTL components.
- Reading IMEI works when the first record is valid and the second is explicitly
  inactive. The UI reports the inactive second record. Backup, write and restore
  still require the complete validated pair.
- Added the measured B04 component profile to the existing physical-eUICC SIM
  refresh path used after profile switching. Existing radio and SIM checks remain.

### Evidence and limits

The supplied Windows 1.24.20 logs confirm successful clean preparation, root SSH
on **2222**, agent installation and screen localization on B04. Both adaptation
dumps show the agent and an HTTP listener on **8080**. They do not establish why
the friend's browser could not open the page; the new explicit HTTP checks help
locate that failure.

Native helper, shell, Rust, macOS and Windows regression tests cover the changed
paths, including B31/B28 profiles. **B04 hardware was not available for a live
test.** VPN client internet, actual TTL packets, ADB persistence after reboot and
physical-eUICC switching on B04 need owner verification. This release does not
enable B04 IMEI/NV writes or custom QR provisioning on the built-in ZTE eSIM.
Both supplied QMI snapshots are identical and do not prove a switch between the
physical SIM and the built-in chip.

### Retest

1. Connect with the existing SSH settings. Another factory reset is unnecessary.
2. Explicitly update the agent and Web UI to **2.9.0-esim.10**, then check its
   status. Open **http://192.168.0.1:8080/** and record any browser error.
3. Install/update VPN components and test a connected Wi-Fi client with an active
   profile. Apply TTL settings and check ADB disable separately.
4. If a step fails, export **Logs and journals** immediately after the operation.
   For built-in eSIM research, select that card, wait for readiness, then collect
   **Firmware adaptation data** and label the selected card.

## Русский

- Исправлено распознавание **XCBZ_HK_MU5250V1.0.0B04 /
  BD_XCBZHKMU5250V1.0.0B04** для VPN, TTL и управления ADB. В новых выгрузках
  появился образ модемной прошивки, недоступный в первом архиве. Добавлен его
  измеренный хэш; проверки остальных компонентов и профили B31/B28 сохранены.
- Исправлено распознавание агента и VPN-контроллера из 1.24.20 перед обновлением.
  Состояние прежних компонентов остаётся доступным для чтения.
- При применении TTL программа может обновить известный менеджер из 1.24.20:
  с проверенной резервной копией и продолжением прерванной замены. Простое
  чтение статуса ничего не устанавливает.
- При проверке и установке агента программа отдельно проверяет веб-панель на
  порту **8080**: через loopback модема, его LAN-адрес и с компьютера. Результаты
  попадают в журнал приложения и диагностический ZIP. Ошибка HTTP показывается
  как предупреждение и не отменяет успешную установку агента.
- Исправлена версия, которую агент возвращает через API: она берётся из сборки.
  Новый агент распознаёт обновлённые компоненты VPN и TTL.
- Чтение IMEI работает при корректной первой и явно неактивной второй записи.
  Неактивность второго IMEI отображается в интерфейсе. Резервное копирование,
  запись и восстановление по-прежнему требуют проверенной пары записей.
- Измеренный профиль B04 добавлен в существующий механизм перечитывания SIM
  после смены профиля съёмной eUICC. Проверки состояния радио и SIM сохранены.

### Проверки и ограничения

Присланные журналы Windows 1.24.20 подтверждают чистую подготовку B04, root SSH
на **2222**, установку агента и русификации экрана. В обеих выгрузках агент
запущен, порт **8080** слушает. Причина недоступности страницы в браузере друга
по этим архивам не установлена; новые проверки помогут определить место сбоя.

Изменения проверены тестами native helper, shell, Rust, macOS и Windows, включая
регрессию профилей B31/B28. **Живого B04 у разработчика нет.** Интернет у клиента
WiFi-VPN, изменение TTL пакетов, отключение ADB после перезагрузки и переключение
съёмной eUICC на B04 ещё требуют проверки владельцем. Запись IMEI/NV на B04 и
загрузка своего QR во встроенный чип ZTE этим выпуском не включаются. Оба
QMI-снимка совпадают и не подтверждают переключение физической/встроенной карты.

### Повторная проверка

1. Подключиться с прежними параметрами SSH. Повторный заводской сброс не нужен.
2. Явно обновить агент и веб-панель до **2.9.0-esim.10**, затем проверить статус.
   Открыть **http://192.168.0.1:8080/** и записать ошибку браузера, если она будет.
3. Установить/обновить VPN-компоненты и проверить интернет на Wi-Fi-клиенте
   с активным профилем. Отдельно применить TTL и проверить выключение ADB.
4. При ошибке сразу выгрузить **Логи и журналы**. Для исследования встроенной
   eSIM выбрать её, дождаться готовности и собрать **Данные для адаптации
   прошивки**, указав выбранную карту.
