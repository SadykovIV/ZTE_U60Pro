# 1.26 — IKEv2, VPN Wi-Fi and preparation recovery diagnostics

[GitHub release](https://github.com/SadykovIV/ZTE_U60Pro/releases/tag/v1.26) · [macOS ARM64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.26/ZTE-U60Pro-Manager-1.26-macOS-arm64.zip) · [Windows x64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.26/ZTE-U60Pro-Manager-1.26-Windows-x64-portable.zip)

macOS build **65** · Windows FileVersion **1.26.0.0** · Agent **2.9.0-esim.13** · VPN controller **1.5.0**.

## English

### Changes since 1.25

- Added IKEv2 EAP-MSCHAPv2 using native strongSwan, a verified server identity and
  a supplied CA. The agent and desktop clients provide profile fields; passwords
  are not returned by the profile API. Phone push MFA follows an explicit connect.
- Private RFC1918 IPv4 networks and the profile DNS server use IPsec from the
  dedicated VPN Wi-Fi. Public IPv4 uses LTE. Private traffic does not fall back
  to LTE; IPv6 is blocked on this network. Internal DNS is unavailable while the
  tunnel is down, even if the public IPv4 route remains usable.
- Switching VPN Wi-Fi off stops its connection; switching on connects the selected
  profile. Repeated enable is idempotent. Wi-Fi recovery respects saved enable
  state and checks firewall, DHCP, bridge and hostapd before raising a guest AP.
- A restarted worker can adopt its owned IKE daemon without initiating another
  authentication. XFRM cleanup selects only this controller's exact unmarked
  reqid/if_id states and policies, preserving unrelated IPsec connections.
- The modem display now places status and the Wi-Fi switch in one top row, with
  five profile rows and vertical scrolling below. Subscription refresh is available
  in the agent and desktop clients. Unsupported emoji have readable text fallbacks.
- Preparation can migrate known root-owned startup scripts with modes 640, 644,
  750 or 755 through a private validated copy. Links, extra hard links, other
  owners, writable-by-others scripts and unknown grammar remain rejected.
- Installer errors distinguish recovery-marker categories and unsafe startup
  files. Desktop recovery retains the failed read-only verification reason and
  distinguishes missing, unreadable or invalid state. No unknown recovery marker
  is deleted and SSH host-key verification remains required.
- The agent reports ZTE firmware and inner firmware separately from the Linux
  kernel. Missing firmware is displayed as unavailable instead of a kernel version.

[Detailed IKEv2 setup and routing](https://github.com/SadykovIV/ZTE_U60Pro/blob/v1.26/docs/IKEV2.md).

### Reports and verification scope

Three supplied Windows 1.25 reports were checked against their archive manifests.
They contain local application logs, without modem installation logs. The reports
show `LEGACY_STARTUP_GRAMMAR`, `EXISTING_AGENT_STARTUP_TYPE`, an unreadable previous
installation state and `RECOVERY_PENDING`, followed by missing or rejected SSH
credentials. A supplied screen identifies one device as XCBZ HK B04.

The reports do not reveal the exact startup bytes, permissions or blocking marker.
The permission compatibility gap was reproduced locally and corrected; the new
fixed diagnostic codes narrow the remaining cases. This release does not claim
that every reported device is recovered or that B04 is fully hardware-validated.
Unknown startup scripts and genuine unfinished operations still need investigation.
Private reports, screenshots, account data and device identifiers are not shipped.

Local installer/recovery, agent, VPN controller, web interface and desktop VPN
regressions passed. Both desktop packages were built successfully; resource
hashes, archive integrity and corresponding-source inputs were verified.

The IKEv2/controller/display candidate was exercised on **CN_ZTE_MU5250V1.0.0B31 /
BD_CNMU5250V1.0.0B31** on 22–23 October 2026: user-confirmed push authentication,
OFF/ON, repeat ON, automatic guest 2.4 GHz AP recovery, private DNS and verified
HTTPS from a temporary DHCP client on `br-vpn`, and the public IPv4 route via LTE.
The owner confirmed the physical display layout and scrolling. Isolated native
network tests checked routing and ownership-scoped XFRM cleanup. Temporary test
interfaces and namespaces were removed; the connection was left enabled.

The final agent firmware-label and installer changes are covered by local tests
and builds, not another installation on a modem. These checks do not cover a new
modem reboot, physical radio association by the temporary client, public HTTPS
through LTE, forced 5 GHz AP recovery, B28/B04 hardware, or execution of the Windows
EXE on Windows. The Windows package is cross-built on macOS. No factory reset,
IMEI write, full-image restore or eUICC profile mutation was performed for this release.

## Русский

### Изменения относительно 1.25

- IKEv2 на штатном strongSwan: логин, пароль, сервер, доверенный CA и внутренний DNS
  задаются в агенте или программах. Сертификат сервера проверяется. После команды
  подключения пользователь подтверждает push на телефоне.
- Приватные сети RFC1918 и DNS профиля идут через VPN, публичные IPv4 — через LTE.
  При обрыве туннеля приватный трафик не уходит в LTE. IPv6 выделенной сети заблокирован.
  Без туннеля внутренний DNS не отвечает, поэтому новые имена могут не разрешаться.
- Переключатель VPN Wi-Fi управляет подключением. Повторное включение не запускает
  его заново. Включённая гостевая точка восстанавливается после проверок готовности;
  выключенная пользователем сеть сама не запускается.
- Исправлены подхват работающего IKE-процесса и точная очистка собственных XFRM
  состояний без удаления чужих соединений.
- Статус и переключатель на дисплее занимают одну строку; ниже пять профилей и
  вертикальная прокрутка. Обновление подписок остаётся в агенте и программах.
  Неподдерживаемые эмодзи заменяются читаемыми обозначениями.
- Подготовка принимает известные файлы запуска с обычными правами 640/644/750/755
  через проверенную приватную копию. Чужой владелец, ссылки, опасные права и
  неизвестный формат по-прежнему вызывают отказ.
- Ошибки теперь различают причины блокировки восстановления, свойства файла
  запуска и состояние журнала установки. Причина неудачной проверки восстановления
  сохраняется. Непроверенные журналы не удаляются, проверка SSH host key сохраняется.
- Версия прошивки ZTE и внутренняя версия показываются отдельно от ядра Linux.

### Проверка и ограничения

Три присланных отчёта 1.25 подтверждают сбои подготовки, но не содержат журналов
установщика с модема, исходных файлов запуска и сведений о конкретной блокировке.
На фото одного устройства указана XCBZ HK B04. Воспроизведённое ограничение прав
файла исправлено; новые диагностические коды помогут определить оставшиеся причины.
Полное устранение проблемы на обоих устройствах ещё требует повторной проверки
у владельцев. Личные отчёты и фотографии в публичные материалы не включены.

Локальные тесты установщика и восстановления, агента, VPN-контроллера, веб-интерфейса
и VPN в программах прошли. Обе программы собраны; проверены контрольные суммы
ресурсов, целостность архивов и соответствие входных исходников сборкам.

На B31 проверены IKEv2 с push, выключение/включение, повторное включение, восстановление
гостевой точки 2,4 ГГц, внутренний DNS/HTTPS через временного DHCP-клиента и маршрут
публичного IPv4 через LTE. Пользователь подтвердил компоновку и прокрутку дисплея.
Тестовый клиент был подключён к мосту `br-vpn`, а не к радио. Изолированная проверка
штатного ядра подтвердила маршруты и сохранность чужих XFRM состояний при очистке.

Финальные изменения диагностики прошивки и установщика проверяются локально;
повторной установки на модем не было. Новая перезагрузка, внешний HTTPS через LTE,
восстановление 5 ГГц, физические B28/B04 и запуск EXE на Windows в эту проверку не входят.
Windows собран на macOS. Сброс, запись IMEI, восстановление полного образа и изменение
профилей eUICC не выполнялись. [Настройка и подробности IKEv2](https://github.com/SadykovIV/ZTE_U60Pro/blob/v1.26/docs/IKEV2.md).
