# Firmware adaptation data / Данные для адаптации прошивки

## English

Open **Modem preparation → Diagnostics → Collect firmware adaptation data** in ZTE U60Pro Manager 1.24.10 and choose where to save the ZIP. The modem must be connected through SSH. ADB is used to prepare SSH; this collection does not switch access methods or change the modem.

The archive contains unchanged bytes from these fixed paths:

- `/usr/bin/zte_topsw_devui` — current screen executable.
- `/usr/ui/language/English.ini` and `/usr/ui/language/Chinese.ini` — current language resources.
- `/etc/init.d/zte_topsw_devui` — screen startup service.

If a verified backup from this application's screen localization is available, its original copies are included separately. The current executable may already be modified or mounted by another installation; the manifest does not label unknown bytes as stock firmware.

Safe metadata includes full Firmware/Inner versions, platform, file sizes and SHA-256, observed agent mode and process state, and unauthenticated HTTP status codes. A `401` response means authorization is required; it does not by itself mean the agent is broken. The archive also includes sanitized application activity, which may contain earlier actions and does not establish that those actions belong to the same modem.

Passwords, SSH keys, agent startup scripts, the process environment, user settings, NV/IMEI records, SIM/eSIM profiles and full flash images are not collected. The capture does not enable unsupported functions or authorize writes.

If a required file is unavailable, the ZIP is marked **incomplete** and lists missing inputs. A changed device, changed file, interrupted transfer or invalid checksum prevents a completed archive. A file above the collector's transport limit is listed as omitted; it is not classified as incompatible firmware.

For FLY B28, these files are needed to inspect its different screen executable and English resource. The current report's hashes alone cannot establish the correct font patch offsets. Further validation on the B28 device is still required after an adapter is prepared.

## Русский

В ZTE U60Pro Manager 1.24.10 откройте **«Подготовка модема → Диагностика → Собрать данные для адаптации прошивки»** и выберите место для ZIP. Требуется подключение по SSH. ADB нужен для подготовки SSH; сам сбор не меняет способ подключения или состояние модема.

Сохраняются точные байты текущего экранного бинарника, `English.ini`, `Chinese.ini` и скрипта запуска экрана. Если доступна проверенная резервная копия нашей русификации, её исходные файлы включаются отдельно. Неизвестный бинарник не объявляется штатным только по имени пути.

В манифесте будут полные Firmware/Inner, платформа, размеры и SHA-256 файлов, режим и состояние агента, HTTP-коды. Код `401` означает необходимость авторизации, а не поломку агента. Очищенный журнал программы может содержать прежние действия; он не доказывает их принадлежность этому же модему.

Пароли, SSH-ключи, скрипты запуска агента, окружение процессов, пользовательские настройки, NV/IMEI, SIM/eSIM-профили и полный образ флеш-памяти не собираются. Операция не включает неподдерживаемые функции и не разрешает запись.

Отсутствующий нужный файл даёт **неполный архив** со списком недостающих данных. Смена устройства, изменение файла, обрыв передачи или неверная контрольная сумма не позволяют подтвердить архив. Превышение транспортного размера отмечается как пропуск файла, а не несовместимость прошивки.

Для B28 этот архив позволит исследовать другой бинарник экрана и `English.ini`, определить корректный патч шрифта и отдельно проверить режим агента. Установка адаптера потребует последующей проверки на самом B28.
