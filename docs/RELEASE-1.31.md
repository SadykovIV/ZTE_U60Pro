# ZTE U60Pro Manager 1.31

macOS arm64 (build 81) · Windows x64 (1.31.0.0) · Agent 2.12.0 · VPN controller 1.7.0

## Что изменилось

- На вкладке VPN в программе и веб-панели агента можно отметить несколько профилей, выбрать весь список и удалить отмеченные одной командой. На macOS при поиске «Отметить все показанные» выбирает результаты фильтра.
- При удалении подписки контроллер удаляет все профили с её идентификатором, включая переименованные и оставшиеся после предыдущих обновлений. Ручные профили и профили других подписок сохраняются. У профилей, отсоединённых старыми версиями программы, связи с подпиской уже нет. Их можно выбрать для пакетного удаления.
- Перед удалением показывается число профилей. Если удаляется активный профиль, контроллер выключает Wi-Fi с VPN и очищает выбор. После обрыва связи обновите состояние. Если у контроллера осталось прерванное изменение, его можно завершить в веб-панели или следующим действием с VPN.
- Для измеренной прошивки FLY B14 / B29 добавлены проверки компонентов VPN и IPv4 TTL, а также поддержка русификации экрана. При обновлении VPN контроллер сверяет файлы установленной версии перед заменой. [Точные версии и границы поддержки](https://github.com/SadykovIV/ZTE_U60Pro/blob/v1.31/README.ru.md#поддерживаемые-прошивки-zte-u60-pro--mu5250).

Для обновления установите программу 1.31, обновите агент через раздел установки агента и нажмите **Установить / обновить** в разделе **VPN**. После обновления веб-панели перезагрузите её страницу. На роутере пакеты используют общий каталог профилей.

## Changes

- Select and delete multiple VPN profiles in the macOS app, Windows app, or agent dashboard. Each batch is committed in one catalog update.
- Deleting a subscription removes all its associated profiles, including renamed and previously retained entries. Deleting the active profile turns off VPN Wi-Fi. Other subscriptions and manually imported profiles keep their settings.
- FLY B14 / B29 support verifies the modem components for VPN, IPv4 TTL and screen translation. The release was checked with local tests and firmware fixtures. Hardware testing on a B29 and native Windows execution are still pending.

The release contains the two desktop ZIPs and the complete agent package. GitHub provides the tagged source in ZIP and tar.gz formats. [Third-party notices](https://github.com/SadykovIV/ZTE_U60Pro/blob/v1.31/THIRD_PARTY_NOTICES.md).
