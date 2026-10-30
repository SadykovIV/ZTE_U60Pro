# 1.27.2 — FLY B27/B11 compatibility and firmware comparison

[GitHub release](https://github.com/SadykovIV/ZTE_U60Pro/releases/tag/v1.27.2) · [Windows x64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.27.2/ZTE-U60Pro-Manager-1.27.2-Windows-x64-portable.zip) · [macOS ARM64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.27.2/ZTE-U60Pro-Manager-1.27.2-macOS-arm64.zip)

macOS build **69** · Windows FileVersion **1.27.2.0** · Agent **2.9.0-esim.17** · VPN controller **1.5.1**.

## Русский

Полученные журналы относятся к `FLY_CN_MU5250V1.0.0B11` /
`BD_FLYMODEMMU5250V1.0.0B27`. В версии 1.27.1 подготовка на этом модеме
завершилась: SSH, агент и веб-панель работают, журналы установки закрыты.
Дальнейшие ошибки возникали в отдельных проверках совместимости VPN,
переключения ADB и русификации экрана.

- Для VPN, IPA и TTL добавлены измеренные компоненты B27. Проверены штатный
  сетевой скрипт, скрипт управления ускорением и обработчики сигналов нового
  `ipacm`. Старые настройки сохраняются; режим восстановления и проверка
  результата остаются частью каждой операции.
- ADB принимает отдельный комплект B27, заново проверяя штатные методы,
  USB-конфигурацию и готовность дескрипторов. Сохраняется восстановление
  незавершённых операций предыдущих выпусков.
- Русификация и Launcher получили собственные профили исходного и изменённого
  экранного ELF B27. Адреса функций, инструкции и данные проверены по архиву;
  подстановка адресов B28 не используется.
- Для радио физической eUICC добавлен точный комплект B27 image/MDM/router.
  В архиве подтверждены чтение QMI operating mode и состояния слотов. Перед
  изменением профиля повторно проверяются карта, выбранный маршрут и радио;
  после изменения — результат и восстановление связи.
- В веб-агенте доступно переименование профиля eSIM с сохранением на карте:
  до 64 Unicode-символов, без переключения профиля и без доступа в интернет.
  Для длинных UTF-8 имён исправлен размер буфера DER в комплектном lpac.
- Сообщение об отсутствующем SSH-ключе на Windows объясняет, как подготовить
  новый модем или выбрать ключ ранее настроенного подключения.

### Сравнение прошивок

Существующий экспорт данных для адаптации расширен зависимостями установщика.
Сведения о правах startup-файлов теперь записываются отдельными числовыми
полями, чтобы фильтр IP-адресов не скрывал их. Новая утилита
`tools/compare_firmware_captures.py` проверяет размеры и SHA-256 всех вложений,
а затем сравнивает системные компоненты нескольких архивов. Текущие файлы
отделены от резервных оригиналов. Совпадение файлов само по себе не означает,
что все функции проверены на устройстве.

Исправлено обезличивание служебных признаков: наличие инструментов, права
каталогов и фиксированные параметры Wi-Fi больше не теряются из-за совпадения
имён полей со словами `private`, `secret` или введённым паролем. Исключение
ограничено 18 полями с заданными типами и значениями; произвольный текст и
учётные данные продолжают скрываться.

Полный образ памяти остаётся отдельной резервной копией. Он может включать
данные владельца и не добавляется автоматически в диагностический экспорт.
Для подтверждённых отказов из этих журналов полного образа не потребовалось.

### Проверки и границы

Проверки выполняются на компьютере: установка и восстановление, соответствие
новых профилей исходным компонентам, русификация и ABI Launcher, VPN/IPA/TTL,
ADB, обработка ошибок eSIM, сбор и сравнение архивов. Точные завершённые наборы
и результаты сборки записаны в `VERIFICATION.json` релиза.

Модем B27 недоступен для новой установки. **Эта версия ещё не проверена на
физическом B27**: нужны установка, изображение/жесты экрана, реальный VPN/TTL
трафик, USB-переключение и операции радио. Выпуск не заявляет совместимость
всех других прошивок, ABI записи DIAG/NV, восстановления полного образа или
встроенной eSIM. Windows собран на macOS; запуск EXE в Windows не проверен.

## English

The supplied FLY B27/B11 logs show successful preparation, SSH and permanent
agent/dashboard installation in 1.27.1. Subsequent VPN, ADB and localization
failures came from separate component compatibility checks. This release adds
measured B27 adapters for VPN/IPA, TTL, ADB, screen localization, Launcher and
physical-eUICC radio transitions, while retaining operation-specific validation
and recovery. Web-agent eSIM nicknames are stored on the card; long UTF-8 names
also receive a corrected lpac DER buffer.

Firmware exports retain numeric startup permissions and include more installer
dependencies. The offline comparison tool verifies every ZIP payload before
comparing system component hashes. A typed allowlist preserves 18 public
diagnostic metadata fields through redaction without preserving arbitrary
values or credentials. Full flash images remain separate private
backups and are not included in diagnostic exports.

Validation is local and includes actual captured ELF/resource checks plus
isolated installation, recovery and runtime tests. **The updated build has not
been tested on the physical B27 modem.** Native Windows execution, real B27
traffic, display/gestures, USB switching and radio transitions remain device
validation items. This release does not certify all firmware variants or private
DIAG/NV, raw restore and built-in eSIM operations. See `VERIFICATION.json` for
the completed build and test results.
