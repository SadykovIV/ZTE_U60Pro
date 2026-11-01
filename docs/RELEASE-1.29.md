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

Точные результаты сборки и тестов этого выпуска записываются в `VERIFICATION.json`.
Исторические аппаратные проверки B31 отделены от новой сборки: в 1.27.1 читалась
съёмная 9eSIM в слоте 1; в локальной 1.28 подтверждены установка, чтение
внутренней eUICC, физическая YOTA с HTTPS, правильное имя сети на реальном экране
и автозапуск после перезагрузки. Интернет через внутреннюю Tele2 в том прогоне
не подтверждён после неудачных запросов; изменения профилей не выполнялись.
Эти результаты не доказывают работу нового бинарника 1.29.

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
Recorded earlier B31 hardware runs do not validate this new build; see the
release verification report for completed tests and remaining device limits.
