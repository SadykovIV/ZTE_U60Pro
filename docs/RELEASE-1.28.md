# 1.28 Internal eUICC — local alternative

macOS build **70** · Windows FileVersion **1.28.0.0** ·
Agent **2.10.0-internal.1** · VPN controller **1.5.1**.

## Русский

Отдельный локальный вариант на базе 1.27.2 для MU5250, в котором оригинальная
впаянная eSIM заменена настоящей eUICC. Программа и веб-панель сохраняют
существующее меню eSIM, но адресуют physical slot **2** / logical slot **2**.
Оригинальная eSIM ZTE этим выпуском не разблокируется.

- Чтение, загрузка, переименование и удаление выключенного профиля обращаются
  к заменённой eUICC без изменения выбранной SIM для связи. Проверяются
  текущий маршрут, EID, полный список профилей и завершение сеанса.
- Для включения профиля или перечитывания уже активного профиля выберите
  **eSIM** в существующем меню **SIM**. Агент проверяет оба штатных признака
  выбора перед ES10c и повторно перед изменением радио. Другой корректный
  выбор даёт `esim_slot_not_selected`; нечитаемое или некорректное состояние —
  `radio_read_failed`.
- Физический слот остаётся доступен для другой карты штатным способом.
  Автоматического выбора SIM, переназначения слотов и перехода к slot 1 при
  ошибке нет. Одновременная работа двух мобильных подключений не заявляется.
- Веб-панель требует capability target `internal-euicc-slot2`, а настольные
  клиенты используют соответствующий закреплённый агент. Стандартные старые
  агент и панель не следует смешивать с этим вариантом.
- Для страницы eSIM на экране сначала установите/обновите комплектный
  **Internal agent** в разделе **«Агент»**, затем нажмите в разделе **eSIM**
  **«Установить / обновить страницу eSIM»** (на Windows —
  **«Установить / обновить страницу eSIM на модеме»**). Вторая кнопка обновляет
  **Launcher** и проверяет установленный агент, но не обновляет его сама.
  Обновление одного агента также не заменяет Launcher. Отдельная команда
  `--esim-launcher-internal` отклоняет смешанные старые/новые пары.
- Для проверенного набора компонентов экрана B31 Launcher выводит имя
  зарегистрированной сети из SDK вместо фиксированного китайского названия
  из `Operator2`. Для применения обновляется Launcher; SIM и UCI-настройки
  этой коррекцией отображения не изменяются. Подробности в исходниках:
  `docs/NETWORK-NAME-B31.md`.

У альтернативных приложений отдельные настройки на компьютере. Для уже
подготовленного модема вручную выберите имеющийся SSH-ключ в настройках
подключения. Настольные операции eSIM временно запускают комплектный агент
по SSH и не требуют постоянной установки. Для работы через веб-панель или
страницу модема постоянный агент устанавливается обычным действием и заменяет
старый в том же `/data/zte-agent`; две службы рядом не создаются.

Комплект сохраняется в `Releases/Local/1.28-internal-euicc`: это локальный
кандидат, не опубликованный на GitHub. Основная рабочая копия и прежние комплекты
сохранены. Выполнена только аутентифицированная диагностика B31 по SSH
с чтением состояния сети, выбора SIM и хэшей экрана: сеть сообщает T2/Tele2,
а прежняя метка `Operator2` содержит CUCC. Новая сборка на модем не установлена;
исправление отображения не развёртывалось, снимков исправленного экрана нет.
Чтение EID/профилей, изменения на заменённой eUICC, проверка исправленного
экрана, восстановление мобильной связи и запуск EXE на Windows не выполнены.
Результаты локальной сборки и тестов фиксируются отдельно
в `VERIFICATION.json`; прежние результаты со съёмной 9eSIM относятся к другой
конфигурации.

## English

This separate local variant builds on 1.27.2 for a real eUICC wired in place
of the original MU5250 soldered eSIM. The existing eSIM menu targets QMI
physical slot **2**, logical slot **2**. It does not unlock the original ZTE
card. Card-only operations do not change the network SIM selection. Enabling
or rereading an active profile requires **eSIM** to be selected through the
existing **SIM** menu, with both stock getters checked before the profile
change and again before the shared radio transition.

The physical SIM slot remains selectable. There is no automatic SIM selection,
remap, slot-1 fallback or dual-active claim. The dashboard requires the Internal
eUICC capability target. For the modem-screen menu, first install/update the
bundled **Internal agent** on the **Agent** page, then choose **Install/update
the eSIM page** on the **eSIM** page. The latter updates **Launcher** and checks
the installed agent; it does not update the agent itself. An agent update alone
does not update Launcher. Mixed old/new pairs are rejected through the separate
internal command.
For the exact supported B31 screen/SDK pair, Launcher displays the registered
network name from SDK instead of the legacy `Operator2` label, without changing
SIM or UCI settings. Apply this display change by updating Launcher.

Desktop settings are separate; manually choose the existing SSH key for a
prepared modem. Desktop eSIM operations stage their bundled agent and do not
need a permanent installation. Permanent installation replaces the existing
`/data/zte-agent` service and matching dashboard.

The local bundle is in `Releases/Local/1.28-internal-euicc`. Authenticated
read-only B31 diagnostics observed T2/Tele2 network fields alongside the legacy
CUCC label and verified the screen/SDK hashes. The new build and display fix
were not deployed; there are no screenshots of the corrected physical screen.
No replacement-card APDU operation, corrected-screen runtime check, native
Windows execution or GitHub publication is claimed. Local build/test results
belong in `VERIFICATION.json`; historical removable-card results do not
validate the modified wiring.

Further source-tree documentation: `docs/INTERNAL-EUICC.md`,
`docs/AGENT-PACKAGE.md` and `docs/ESIM-APP-CONTRACT.md`.
