# 1.24.22 — VPN subscriptions, AmneziaWG and IMEI topology

macOS ARM64 (build 63) · Windows x64 · Agent **2.9.0-esim.11** · VPN controller **1.4.0**.

## English

- macOS VPN updates no longer need a successful status response from the old
  controller. The bundled installer checks the existing files, upgrades a known
  controller and then verifies the new one. Windows already uses this order.

- VPN activation prepares incompatible IPA hardware acceleration automatically,
  saving its original settings first. Failures identify the actual stage rather
  than asking the user to find an undocumented switch. B31, FLY B28 and XCBZ HK B04
  retain their measured component profiles.
- IMEI backup, change and restore follow the records actually present on the
  modem: one active record or two. An explicitly inactive second record is not
  created. A read failure is not interpreted as an absent record. Restore checks
  the device and record topology again.
- Import WireGuard, AmneziaWG 2 and AmneziaWG 3.1 `.conf` files, VLESS and
  Hysteria2 links, and HTTPS subscriptions. The supplied subscriptions produce
  **14, 43 and 9** profiles with the pinned Mihomo **1.19.31** core.
- Desktop apps, the agent and the launcher share the modem's profile catalogue.
  Protocol badges in the desktop apps and agent identify the connection type. Adding profiles does not
  activate them. Launcher pagination now supports the larger subscription lists.
- Refresh individual subscriptions in the desktop apps and agent. The agent and
  launcher also have **Update subscriptions**, which updates each subscription
  in turn. The agent shows individual results; the launcher shows the completed
  count and the first error code. A failed download preserves that
  subscription's previous profiles; other subscriptions can still update.
- Refreshing a subscription preserves the running connection. Changed active
  profiles are marked for explicit reactivation; removed active profiles remain
  available. Deleting a subscription detaches its profiles rather than deleting
  them. Error codes are included in the diagnostic VPN log without subscription
  tokens or connection keys.

The desktop downloads subscriptions over the computer's connection. The agent
and launcher download over the modem's connection. Refresh is started by the
button; this version does not install a background refresh timer. Mihomo runs
and validates the profiles; the shared controller maintains their identity,
subscription membership and active selection.

### Verification limits

On the attached **CN_ZTE_MU5250V1.0.0B31 / BD_CNMU5250V1.0.0B31**, the production
installers updated the agent, VPN controller and launcher. Both supplied
AmneziaWG configurations passed normal controller activation and real HTTPS
traffic through the core's local SOCKS listener. All three subscriptions were
downloaded again by the modem, including an authenticated agent API refresh.
The second provider returned 45 profiles on refresh, versus 43 at initial import.
The original two profiles and active selection were restored after the tests.
The new generator changed the shared DNS resolver from UDP to DNS-over-HTTPS
through VPN; the remaining configuration fields were unchanged.

The dashboard returned HTTP 200 from the modem and computer, and the new launcher
plugin was confirmed loaded and ready. Physical launcher button presses and
traffic from a physical Wi-Fi client were not tested. B04 and B28 require owner
tests on those devices. No IMEI write was performed on the attached modem.
Native Windows execution is a separate check from cross-building and testing
its services/UI on macOS.

The built-in ZTE eSIM remains unsupported. The eSIM manager requires a removable
physical eUICC card in the SIM slot.

## Русский

- Обновление VPN в macOS больше не требует успешного ответа старого
  контроллера. Установщик проверяет файлы, заменяет известную сборку и затем
  проверяет новый контроллер. Windows уже использует этот порядок.

- VPN автоматически подготавливает несовместимое ускорение IPA с резервной
  копией его настроек. Ошибки указывают конкретный этап. Сохранены профили
  компонентов B31, FLY B28 и XCBZ HK B04.
- Бэкап, смена и восстановление IMEI работают с фактическим числом записей:
  одной или двумя. Неактивная вторая запись не создаётся. Ошибка чтения не
  считается отсутствием записи; перед восстановлением число записей проверяется
  повторно.
- Добавлены WireGuard, AmneziaWG 2 и 3.1 из `.conf`, ссылки VLESS/Hysteria2 и
  HTTPS-подписки. Три предоставленных сервиса дают **14, 43 и 9** профилей.
- Общий список профилей хранится на модеме и доступен программе, агенту и
  лаунчеру. В программе и агенте рядом с профилем отображается протокол.
  Импорт не включает VPN.
- В агенте и лаунчере есть **«Обновить подписки»**: последовательное обновление
  всех подписок. Агент показывает результат каждой, лаунчер — число обновлённых
  подписок и код первой ошибки. Недоступная подписка сохраняет прежние
  данные и не мешает обновить остальные. В программе и агенте можно обновить
  отдельную подписку.
- Обновление не прерывает действующее подключение. Изменённый активный профиль
  применяется отдельной командой; удалённый провайдером активный профиль
  сохраняется. Удаление подписки оставляет её профили в общем списке.

Программа загружает подписки через интернет компьютера; агент и лаунчер — через
интернет модема. Обновление запускается кнопкой, расписание в этой версии не
добавляется. Коды ошибок входят в диагностический журнал VPN; секретные ссылки и
ключи туда не записываются.

На подключённом **CN_ZTE_MU5250V1.0.0B31 / BD_CNMU5250V1.0.0B31** штатно
обновлены агент, контроллер VPN и лаунчер. Оба конфига AmneziaWG прошли штатное
включение и передали HTTPS-трафик через локальный SOCKS-порт ядра VPN.
Все три подписки повторно загружены самим модемом, одна — по команде через
авторизованный API агента. Второй сервис при обновлении вернул 45 профилей
вместо первоначальных 43.

После тестов возвращены исходные два профиля и активный выбор. Новый генератор
заменил общий DNS по UDP на DNS-over-HTTPS через VPN; остальные поля конфига
сохранились. Веб-панель доступна с модема и компьютера (HTTP 200), плагин
лаунчера загружен и готов. Физическое нажатие кнопки на экране, B04/B28 и
интернет с физического клиента Wi-Fi требуют проверки владельцами.
Запись IMEI на подключённом модеме не выполнялась. Сборка Windows проверена
по составу, исходникам, ресурсам и тестам; запуск на Windows ещё не проверен.
Встроенная eSIM ZTE не поддерживается; для управления eSIM нужна физическая
карта eUICC в SIM-слоте.

### Повторная проверка

1. Обновите компоненты VPN, агент с веб-панелью и страницы лаунчера из одной
   версии программы. Сброс модема для этого не нужен.
2. Импортируйте `.conf` или подписку, выберите профиль и включите Wi-Fi с VPN.
   Проверьте интернет с подключённого к этой сети телефона или компьютера.
3. Нажмите «Обновить подписки» в агенте и на экране модема. Проверьте, что
   активное подключение сохранилось. Агент показывает результат каждой подписки,
   экран — число обновлённых и код первой ошибки, если она возникла.
4. Для проверки IMEI сначала выполните чтение и резервное копирование.
   При ошибке сразу экспортируйте «Логи и журналы».
