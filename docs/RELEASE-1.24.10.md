# 1.24.10 — firmware adaptation data and custom agent installation

macOS **1.24.10 build 51**, Windows **1.24.10.0**. Agent **2.9.0-esim.4** is unchanged.

- Added **Collect firmware adaptation data** under **Modem preparation → Diagnostics**, with an information button explaining its contents.
- Collects current screen executable, language files and startup service over SSH; verified originals from this application's backup are included when available.
- Records full firmware versions and safe agent mode/HTTP facts. File bytes, sizes and SHA-256 are checked before creating the ZIP.
- Missing inputs produce an explicit incomplete archive. Changed device/files and failed transfers cannot be reported as a successful capture.
- Windows now lets you choose and install a local Linux ARM64 agent file under **Agent installation**. The selected file is checked again before installation; the existing backup and rollback procedure is used.

[Collection instructions and scope in English/Russian](FIRMWARE-ADAPTATION-DATA.md).

## По-русски

В **«Подготовка модема → Диагностика»** добавлена кнопка **«Собрать данные для адаптации прошивки»** и справка ⓘ. Архив содержит необходимые файлы экранного интерфейса и безопасные сведения об агенте. Сбор выполняется через SSH без изменения модема и проверки совпадения с B31.

В Windows в разделе **«Установка агента»** добавлены выбор своего файла агента и его установка. Программа проверяет формат Linux ARM64 ELF и контрольную сумму файла перед установкой, затем использует существующий механизм резервной копии и восстановления.

Это сбор исходных данных для исследования B28 и других прошивок. Он не объявляет русификацию или полное управление агентом на B28 готовыми. Управление eSIM по-прежнему требует физическую eUICC; встроенная eSIM ZTE этим компонентом не поддерживается.

Точные тесты и проверки пакетов сохраняются рядом с ZIP в `dist/1.24.10`. Выполнение Windows-кода на Mac не подтверждает запуск в нативной Windows.
