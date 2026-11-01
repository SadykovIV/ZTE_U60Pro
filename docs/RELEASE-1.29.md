# 1.29 — единое приложение для конфигураций SIM

macOS build **71** · Windows FileVersion **1.29.0.0** ·
Agent **2.11.0** · VPN controller **1.5.1**.

## Русский

- Один комплект приложения и агента для модема с одной SIM, штатной связкой
  физической SIM и китайской eSIM, а также заменённой внутренней eUICC.
- Добавлено управление **eUICC SIM-картой, установленной перепайкой вместо
  штатной внутренней китайской eSIM**, через существующее меню eSIM.
  Физический слот остаётся доступен для другой SIM.
- Меню определяет доступные карты и привязывает чтение и операции к выбранному
  слоту. При двух eUICC карту выбирает пользователь; ошибки чтения не означают
  обычную SIM. Автоматического переключения сетевой SIM и переназначения слотов нет.
- Launcher на проверенной B31 показывает имя зарегистрированной сети вместо
  сохранённой китайской метки. Для экранного меню сначала обновите агент в
  разделе **Агент**, затем страницу eSIM кнопкой её установки/обновления.

Штатная китайская eSIM сохраняет обычные функции модема; загрузка собственных
профилей на оригинальный чип ZTE не реализована. Управление профилями доступно
после подтверждения настоящей eUICC. Одновременная работа двух мобильных
подключений не заявляется. Включение профиля и восстановление радио требуют
отдельных проверок выбранной сетевой SIM, компонентов прошивки и состояния QMI.

### Проверки

На одном B31 подтверждены установка нового комплекта 1.29 штатными средствами
приложения, точные хэши компонентов, обнаружение обычной SIM и внутренней eUICC,
повторное чтение трёх неизменившихся профилей и реальная экранная страница eSIM.
Физическая YOTA работала в LTE: два HTTPS-адреса дали HTTP 200 в двух проверках
через мобильный интерфейс. Чтение внутренней eUICC доступно при выбранной
физической SIM; разрешение на включение профиля появляется после явного выбора
внутренней карты в штатном меню. Изменения профилей не выполнялись.
После перезагрузки подтверждены автозапуск агента, работа нового Launcher
с сохранёнными страницами и повторное обнаружение/чтение тех же профилей
рабочими реализациями приложения.

После наблюдавшегося перехода внутренней карты на 3G и неактивного WAN одна
контролируемая перезагрузка восстановила LTE-NSA/ENDC в этом прогоне: семь
измерений за приблизительно 30 секунд показали ENDC и активный WAN, экран —
Tele2 5G. Причина прежнего перехода на 3G не установлена; в ходе проверки
настройки диапазонов и RAT не меняли. Интернет внутренней eUICC **не подтверждён**: HTTPS завершается
ошибкой TLS, как до обновления, а HTTP перенаправляется на страницу оператора.
Причина переадресации не установлена.

Локально прошли 229 тестов агента, 90 web-тестов, 7712 проверок взаимодействия
с Launcher и 42 отрисованных экрана macOS. Точные результаты и ограничения записаны
в `VERIFICATION.json` и [отчёте проверки 1.29](UNIFIED-SIM-LIVE-20261101.md).
Исторические прогоны 1.27.1 и 1.28 не заменяют проверки этой сборки; один
аппаратный прогон не устанавливает надёжность всех конфигураций.

Адаптеры B27/B28/B04 и локальные проверки не означают аппаратной проверки всех
операций на этих прошивках. Нативный запуск Windows отдельно не подтверждён.
[Инструкция SIM/eUICC](UNIFIED-SIM.md) · [Матрица прошивок](FIRMWARE-COMPATIBILITY.md).

## English

One app and agent now cover a single physical SIM, the stock physical-SIM plus
Chinese-eSIM configuration, and a real eUICC SIM card soldered in place of the
original internal Chinese eSIM. The existing eSIM menu detects available cards
and binds operations to an explicit slot; the physical slot remains usable.
Two detected eUICCs require a user selection. There is no automatic network-SIM
switching, slot remapping, or dual-active claim. Custom profile provisioning on
the original ZTE chip remains unsupported.

The B31 Launcher displays the registered network name instead of a stored
Chinese label. Update the bundled agent first, then install/update the eSIM
screen page. Firmware and radio transitions keep their separate checks.
On one B31 unit, the new 1.29 installation, repeated internal-eUICC reads,
on-screen profile page and physical-SIM LTE/HTTPS were verified. No profile
mutations were performed. After an observed transition to 3G with WAN down,
one controlled reboot restored LTE-NSA/ENDC in this run; seven samples over
about 30 seconds retained ENDC and WAN up, and the screen showed Tele2 5G.
Post-reboot checks confirmed agent autostart, the new Launcher running with
preserved pages, and repeated card/profile reads through the production app code.
The earlier 3G transition remains unexplained; the verification did not change
band or RAT settings. Internal-eUICC internet remains unverified: HTTPS fails as before the
update, while HTTP redirects to the operator's page for an undetermined reason.
See the
[1.29 hardware report](UNIFIED-SIM-LIVE-20261101.md) and release verification
report for the exact scope; one unit does not validate all configurations.
