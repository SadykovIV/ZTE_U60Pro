import SwiftUI

/// The command examples describe the local implementation, not executable UI actions.
/// Keep this content aligned with Onboarding.swift, Engine.swift and DeviceHelpers/src.
enum OperationHelpTopic: String {
    case preparation
    case imei

    var title: String {
        switch self {
        case .preparation: return "Как выполняется подготовка модема"
        case .imei: return "Как записываются оба IMEI"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .preparation: return "Подробно о подготовке модема"
        case .imei: return "Подробно о записи обоих IMEI"
        }
    }

    var introduction: String {
        switch self {
        case .preparation:
            return "Подготовка создаёт постоянный доступ к модему: при необходимости включает ADB, устанавливает агент и настраивает SSH по ключу. VPN-компоненты устанавливаются отдельно кнопкой «Установить компоненты VPN» в меню VPN. Здесь описаны фактическая последовательность, изменяемые файлы и проверки приложения. Открытие этой справки ничего на модеме не выполняет."
        case .imei:
            return "Кнопка записывает пару IMEI в два индекса NV550 через проверенные помощники DIAG/EFS. Перед записью приложение сохраняет исходные данные на Mac, временно включает разрешение записи, а затем возвращает исходный config и проверяет результат после перезагрузки. Открытие этой справки ничего не запускает."
        }
    }

    var sections: [OperationHelpSection] {
        switch self {
        case .preparation: return Self.preparationSections
        case .imei: return Self.imeiSections
        }
    }

    private static let preparationSections: [OperationHelpSection] = [
        .init("1. Проверка подключений и подготовка — разные действия", "При открытии страницы приложение проверяет доступность SSH, агента, USB ADB и штатного Web без входа в HTTP-сервисы. Кнопка «Проверить подключения» дополнительно проверяет введённые пароли Web и агента: выполняет по одной попытке входа и читает идентификацию. Пустой пароль не отправляется. Недоступный сервис и отвергнутый пароль показываются отдельно. Проверка не устанавливает компоненты и не включает ADB. «Подключиться» автоматически выбирает SSH, затем USB ADB. Web и агент показываются как сведения о доступе. Подготовку запускает отдельная кнопка с паролями штатного Web и агента. При уже доступном SSH новая предварительная подготовка недоступна. Галочка «Не проверять прошивку» разрешает её повторный запуск. Незавершённую подготовку можно продолжить с включённой проверкой прошивки.\n\nДля установки нужны доступный штатный Web и USB-кабель с передачей данных, если SSH с агентом ещё не подготовлены. Приложение блокирует параллельные операции и проверяет, нет ли незавершённой смены IMEI или восстановления полного образа."),
        .init("2. Вход в Web и свежая резервная копия", "Приложение обращается по HTTP к указанному IPv4-адресу. Через JSON-RPC /ubus/ запрашивает challenge zte_web_sault, вычисляет SHA-256 от пароля и затем SHA-256 от полученного хэша вместе с challenge; передаёт хэш штатному web_login. Полученные сессия и cookie используются для дальнейших запросов.\n\nПосле входа читаются IMEI, внешняя и внутренняя версии прошивки. Затем модем создаёт свежий зашифрованный бэкап настроек, который скачивается на Mac. Идентичность Web повторно проверяется после скачивания. Эта стадия выполняется и при уже настроенном доступе. Пароль Web в архив или командную строку не добавляется.", commands: #"""
        POST http://<адрес>/ubus/
        zwrt_web.web_login_info {}
        zwrt_web.web_login {"password":"<challenge-хэш>"}
        zwrt_web.device_info {}
        zwrt_mc.device.manager.device_backup_proc {"procType":"web"}
        GET http://<адрес>/backup/back_parameter
        """#),
        .init("3. Проверка архива и включение ADB на B31", "На Mac архив расшифровывается ключом, составленным из IMEI модема и введённого владельцем Backup-key suffix; этот ключ не включён в приложение и не сохраняется. Проверяются формат OpenSSL Salted__, структура gzip/tar, MD5 внутреннего архива, содержимое и расположение etc/rc.local. Архив обрабатывается в памяти.\n\nИзменяется только etc/rc.local: сразу после #!/bin/sh добавляется приведённая строка. Остальные записи и их метаданные сравниваются с оригиналом. После упаковки обновляется MD5, архив шифруется заново и повторно расшифровывается для проверки. На Mac сохраняются back_parameter.original, identity.json и manifest.json; перед загрузкой также сохраняется back_parameter.adb-only. Это бэкап настроек, а не полный образ памяти.\n\nЕсли уже найдены и проверены SSH с агентом либо подходящий ADB, восстановление для включения ADB не запускается. Если строка уже присутствует, приложение ждёт ADB и не отправляет бэкап повторно.", commands: #"""
        # Строка, добавляемая в etc/rc.local внутри бэкапа:
        echo 1 > /sys/class/android_usb/android0/usb_op
        """#),
        .init("4. Загрузка изменённого бэкапа — только когда нужна", "Этот путь разрешён для проверенного профиля MU5250 B31. Изменённый архив отправляется штатному CGI-загрузчику с назначением /tmp/back_parameter. Ответ должен содержать точную SHA-256 загруженного файла. Перед загрузкой и перед восстановлением приложение снова сверяет Web-идентичность.\n\nЗатем штатный device_restore_proc восстанавливает настройки и перезагружает модем. На Mac заранее сохраняется отметка restore-requested. Если HTTP оборвался во время перезагрузки, восстановление не отправляется повторно: приложение до четырёх минут ждёт ADB. Если ранее известен только CID, но не подтверждена его связь с IMEI, включение через Web блокируется, чтобы не изменять другой модем.", commands: #"""
        POST http://<адрес>/cgi-bin/cgi-upload
          filename=/tmp/back_parameter
          filedata=<проверенный зашифрованный архив>
        POST http://<адрес>/ubus/
          zwrt_mc.device.manager.device_restore_proc {"procType":"web"}
        """#),
        .init("5. Выбор ADB-устройства и проверка прошивки", "Встроенный adb перечисляет устройства. Для каждого кандидата приложение требует root, архитектуру aarch64, читает SHA-256 modem.b16 и diag-router, eMMC CID и сведения штатного Web через ubus. IMEI и версии должны совпасть с устройством, у которого скачан бэкап. При нескольких подходящих устройствах установка останавливается.\n\nПо умолчанию разрешён проверенный B31. Отключение общей проверки прошивки не отменяет ограничения установщика: он принимает только точные известные хэши B31 либо отдельного экспериментального B02. Для B02 нужен уже работающий root ADB именно по USB; включение ADB восстановлением бэкапа на B02 не выполняется. Готовность доступа B02 не означает подтверждённую совместимость изменения IMEI.", commands: #"""
        adb devices -l
        adb -s <serial> shell '<команды ниже>'

        set -e
        test "$(id -u)" = 0
        test "$(uname -m)" = aarch64
        sha256sum /firmware/image/modem.b16 /usr/bin/diag-router
        cat /sys/block/mmcblk0/device/cid
        ubus call zwrt_web device_info '{}'
        """#),
        .init("6. Подготовка каталогов и передача файлов", "До установки скрипт проверяет точные хэши, CID, доступные команды, типы и права каталогов, доступность записи и исполнения в /data, /etc и используемых точках монтирования, синтаксис rc.local, отсутствие чужой операции и свободное место: не менее 16 МиБ в /data и 2 МиБ в /etc.\n\nЕсли /data/local или /data/local/tmp отсутствует, приложение создаёт каждый каталог с правами 755. Оно проверяет владельца root, отсутствие символических ссылок и записи для группы/остальных пользователей. Каталог этой установки создаётся с правами 700 и собственным маркером владельца. Это устраняет прежнюю зависимость от наличия /data/local/tmp.\n\nВ него через adb push передаются zte-agent, dropbear, setup-agent.sh, start_zte_imei_studio.sh, открытый ключ id_ed25519.pub и сценарий запуска агента. Каждый файл сначала поступает под уникальным incoming-именем, получает права 600, проверяется по SHA-256 и только затем переименовывается. Удалённый код завершения shell проверяется отдельно от кода самого процесса adb.", commands: #"""
        # Упрощённые шаблоны; проверки владельца/прав выполняются до mkdir.
        mkdir -m 755 /data/local
        mkdir -m 755 /data/local/tmp
        mkdir -m 700 /data/local/tmp/zte-imei-setup-<UUID>
        adb -s <serial> push <файл> <stage>/incoming-<UUID>
        adb -s <serial> shell 'chmod 600 <incoming>; sha256sum <incoming>'
        sh <stage>/setup-agent.sh <stage> <CID> <SHA256-агента> \
          <SHA256-dropbear> <SHA256-открытого-ключа> \
          <b31|b02-experimental> <SHA256-прошивки> <SHA256-diag-router>
        """#),
        .init("7. Что устанавливается и сохраняется на модеме", "До первой постоянной правки установщик повторно проверяет устройство и создаёт приватный журнал /data/local/tmp/zte-imei-installations/<UUID>. В before сохраняются исходные версии всех затрагиваемых существующих файлов, вместе с отметками их наличия и контрольными суммами. Каждая замена идёт через временный файл и переименование.\n\nНовый агент устанавливается в /data/zte-agent, его запуск — в /data/local/tmp/start_zte_agent.sh. Заданный пароль агента хранится в этом root-сценарии с правами 700 как ZTE_AGENT_PASSWORD. При уже существующем агенте его бинарник, сценарий запуска и пароль сохраняются; поле нового пароля не сбрасывает старый пароль. Агент слушает порт 9090.\n\nDropbear и dropbearkey размещаются в /data/bin, если их ещё нет. Открытый ключ приложения добавляется в /etc/dropbear/authorized_keys с сохранением других ключей. При отсутствии создаются серверные ключи Ed25519/RSA. Их копии и authorized_keys сохраняются в /data/dropbear.\n\nВ /etc/rc.local добавляется запуск /data/local/tmp/start_zte_imei_studio.sh перед первым exit 0. Существующие строки сохраняются. Этот сценарий запускает отсутствующий агент и SSH на порту 2222; уже работающий слушатель не останавливается. Новый SSH настроен на ключи, без входа по паролю.", commands: #"""
        # Постоянная строка автозапуска:
        sh /data/local/tmp/start_zte_imei_studio.sh

        # Запуск нового слушателя SSH:
        /data/bin/dropbear -s -P /var/run/zte-imei-dropbear.pid -p 2222 \
          -r /etc/dropbear/dropbear_ed25519_host_key \
          -r /etc/dropbear/dropbear_rsa_host_key
        """#),
        .init("8. Ключ SSH и итоговая проверка", "На Mac создаётся или повторно используется собственная пара SSH Ed25519. Закрытый ключ остаётся на Mac с правами 600; на модем передаётся только открытая часть. Ключ сервера читается через проверенный ADB, с повторной сверкой CID до и после чтения, и записывается в отдельный known_hosts для адреса модема и порта 2222. Последующие SSH-команды используют StrictHostKeyChecking=yes.\n\nПосле установки сверяются идентичности ADB и SSH. На B31 помощник читает оба NV IMEI и сравнивает их с ubus, а процесс агента проверяется по /proc/<pid>/exe. Для нового агента проверяется вход заданным паролем. На B02 проверяются root, ARM64, прошивка, идентичность, процесс и вход в агент; запись NV не запускается.\n\nТолько после этих проверок установщик получает --commit, сверяет after.sha256 и помечает журнал завершённым. Приложение сохраняет параметры SSH, подключается и обновляет данные разделов. Временные переданные файлы удаляются; приватные снимки восстановления остаются.", commands: #"""
        # На Mac, только если своей пары ключей ещё нет:
        ssh-keygen -q -t ed25519 -N '' -C 'ZTE IMEI Studio' -f <ключ-Mac>
        # Через проверенный ADB:
        /data/bin/dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key
        # Проверка входа агента через SSH; пароль передаётся через stdin:
        curl --noproxy '*' --fail --silent --show-error \
          -H 'Content-Type: application/json' --data-binary @- \
          http://<адрес>:9090/api/auth/login
        sh <stage>/setup-agent.sh --commit <журнал> <CID> \
          <профиль> <SHA256-прошивки> <SHA256-diag-router>
        """#),
        .init("9. Если подготовка прервалась", "Локальный setup-pending.json сохраняет устройство и стадию операции. Если восстановление бэкапа уже запрошено, оно автоматически не повторяется. Если установка уже запрошена, приложение сначала читает удалённый журнал; автоматическое завершение допускается только из ready или complete, после проверки SSH и устройства. Незавершённые ранние стадии сохраняются для разбора и восстановления; установка не объявляется успешной и не запускается заново поверх неизвестного состояния.\n\nПодготовка изменяет перечисленные файлы настроек и доступа. Она не устанавливает плитки или русификацию, не записывает новые IMEI, не перемонтирует /usr/zte_web в rw и не прошивает раздел ZTEDATA. Оригинальный Web-архив и журнал установки находятся на Mac в данных приложения: SetupBackups/<UUID>. Фактические команды и результаты доступны в журнале действий.")
    ]

    private static let imeiSections: [OperationHelpSection] = [
        .init("1. Какой доступ используется", "Запись выполняется по SSH от root с собственным ключом и строгой проверкой известного ключа сервера. Web, агент и ADB не используются вместо SSH для операции записи NV.\n\nЕсли SSH ещё не подключён, но заполнены пароли Web и агента, комбинированная кнопка сначала выполняет подготовку, описанную в справке рядом с кнопкой «Выполнить предварительную подготовку модема». На проверенном B31 она затем читает пару и продолжает запись, если целевые IMEI отличаются. На экспериментальном B02 подготовка доступа автоматически в запись IMEI не переходит. Поэтому при первоначальной подготовке может потребоваться дополнительная перезагрузка для включения ADB.\n\nПеред началом нужны два разных IMEI из 15 цифр с правильной контрольной цифрой Luhn. Пара должна отличаться от текущей. Незавершённая установка, операция IMEI или восстановление полного образа блокируют новую запись.", commands: #"""
        # Схема SSH-транспорта; <команда> выполняется на модеме:
        ssh -F /dev/null -T -p <порт> -i <ключ-Mac> \
          -o IdentitiesOnly=yes -o BatchMode=yes \
          -o StrictHostKeyChecking=yes \
          -o UserKnownHostsFile=<known_hosts-Mac> \
          -o GlobalKnownHostsFile=/dev/null root@<адрес> '<команда>'
        """#),
        .init("2. Проверка устройства и чтение исходной пары", "Приложение сверяет eMMC CID, хэши modem.b16 и diag-router и идентификатор текущей загрузки boot_id. По умолчанию допускается проверенная MU5250 B31. Даже при отключённой общей проверке хэшей остаются строгие проверки формата NV, структуры /config и совпадения устройства. Отключение галочки само по себе не доказывает совместимость другой прошивки.\n\nСоздаются локальная блокировка операции и удалённая /tmp/zte-imei-app.lock с токеном владельца. Помощник zte_nv читает NV550, индексы 0 и 1: по 128 байт каждый. Дополнительно legacy-чтение NV550 должно полностью совпасть с индексом 0. Оба IMEI декодируются и сравниваются с get_imei/get_imei2 штатного API.", commands: #"""
        sha256sum /firmware/image/modem.b16 /usr/bin/diag-router
        cat /sys/block/mmcblk0/device/cid /proc/sys/kernel/random/boot_id
        <путь-к-загруженному-zte_nv> --snapshot
        ubus call zwrt_zte_mdm.api get_imei
        ubus call zwrt_zte_mdm.api get_imei2
        """#),
        .init("3. Как работают временные помощники", "Для каждого вызова приложение сверяет встроенный бинарник с helpers.json, создаёт приватный каталог /tmp/zte-imei-<UUID> и передаёт помощник по stdin SSH командой cat. Затем выставляет 700 и сравнивает SHA-256 на модеме. Если нужен план, он также передаётся через stdin, хранится с правами 600 и проверяется по SHA-256. После вызова приложение пытается удалить собственные временные файлы и каталог.\n\nzte_nv, zte_config и zte_config_read используют /usr/lib/libdiag.so.1, проверяют владение DIAG-сессией, ответы и CRC кадров, после работы освобождают сессию. Они не получают произвольные пути или произвольные команды записи. Отдельных команд остановки/запуска радио в этом сценарии нет; связь прерывается при перезагрузках.", commands: #"""
        umask 077; mkdir '/tmp/zte-imei-<UUID>'
        umask 077; cat > '<tmp>/helper' && chmod 700 '<tmp>/helper' \
          && sha256sum '<tmp>/helper'
        umask 077; cat > '<tmp>/plan' && sha256sum '<tmp>/plan'
        '<tmp>/helper' '<режим>' '<tmp>/plan'
        """#),
        .init("4. Бэкап перед первой записью", "Помощник zte_config_read читает /config внутри EFS модемного процессора. Это объект DIAG/EFS, а не обычный Linux-файл /config. Ожидается точная структура B31: 15 073 байта, 249 записей, заголовок и окончание, корректный CRC, единственный config102 в известном месте. Исходный флаг должен быть 0. NV читается повторно и должен совпасть с первым снимком.\n\nНа Mac сохраняются nv0.bin и nv1.bin целиком, config.bin и manifest.json с SHA-256, IMEI, CID и хэшем прошивки. Бэкап сразу повторно открывается и проверяется. Только затем создаётся pending.json с целевыми полными NV-записями, идентичностью и стадией prepared.\n\nНовые IMEI кодируются только в первые 9 байт каждого 128-байтного NV. Остальные 119 байт сохраняются побайтно. Это целевой бэкап пары и EFS config; он не заменяет полный образ модема из раздела резервного копирования.", commands: #"""
        <путь-к-zte_config_read> --read-config
        <путь-к-zte_nv> --snapshot

        # На Mac, в данных приложения:
        Backups/<UUID>/nv0.bin
        Backups/<UUID>/nv1.bin
        Backups/<UUID>/config.bin
        Backups/<UUID>/manifest.json
        pending.json
        """#),
        .init("5. Временное разрешение записи и первая перезагрузка", "Из исходного EFS config создаётся кандидат: байт флага config102 по смещению 499 меняется с 0 на 1, CRC в байтах 12–15 пересчитывается. Другие байты сохраняются. План помощника содержит ровно исходный config и кандидат.\n\nzte_config открывает /config только на чтение. Для изменения он создаёт отдельные принадлежащие ему файлы кандидата и отката в EFS, проверяет их полное содержимое и синхронизацию, затем заменяет /config командой EFS RENAME14. После замены снова проверяет все байты и синхронизацию. При чужих временных файлах или неизвестном содержимом запись запрещается.\n\nПриложение сохраняет стадию rebooting-to-enable и один раз отправляет штатную команду перезагрузки. До четырёх минут ожидает SSH, новый boot_id и тот же CID/хэш прошивки. Обрыв SSH во время перезагрузки ожидаем; команда не повторяется вслепую.", commands: #"""
        <путь-к-zte_config> --enable-flag <план-original+candidate>
        ubus call zwrt_mc.device.manager device_reboot '{"moduleName":"web"}'
        """#),
        .init("6. Последовательная запись двух индексов NV550", "После загрузки повторно сверяются устройство, config и оба NV. Каждый индекс должен точно совпадать с известным исходным либо целевым содержимым. Формируется 512-байтный план: текущий NV0, текущий NV1, целевой NV0, целевой NV1. План сохраняется также в локальном журнале nv-plan.bin.\n\nzte_nv --apply-plan ещё раз проверяет план и начальное состояние. Через индексированный DIAG-запрос записывается индекс 0, затем полностью перечитываются оба индекса и legacy-алиас. Только при точном совпадении ожидаемой пары записывается индекс 1 и выполняется такая же полная проверка. После помощника приложение отдельно сравнивает NV и оба значения ubus с целевыми IMEI.\n\nЭто последовательные операции с контролем после каждого шага, а не одна атомарная запись двух слотов. При ошибке помощник пытается вернуть известные исходные записи в обратном порядке и проверяет результат. Неизвестные или нечитаемые данные он не заменяет вслепую; успешный откат не гарантируется при потере питания/связи.", commands: #"""
        <путь-к-zte_nv> --apply-plan <план-512-байт>
        <путь-к-zte_nv> --snapshot
        ubus call zwrt_zte_mdm.api get_imei
        ubus call zwrt_zte_mdm.api get_imei2
        """#),
        .init("7. Возврат config, вторая перезагрузка и проверка", "После подтверждения целевой пары zte_config возвращает точный исходный EFS config из бэкапа, включая прежнее значение флага и CRC. Используется тот же механизм проверенных временных файлов, переименования, чтения и синхронизации.\n\nПриложение сохраняет стадию final-reboot и boot_id до перезагрузки, отправляет команду один раз и ждёт новый boot_id того же модема. Затем повторно читает оба NV, проверяет IMEI штатным API и побайтное совпадение config с оригиналом. Только при полном успехе сохраняются completed.json и result.json, а pending.json удаляется.\n\nВ обычной новой операции выполняются две перезагрузки. При продолжении уже выполненные этапы определяются по фактическим данным и журналу; новые записи не запускаются только из-за обрыва соединения.", commands: #"""
        <путь-к-zte_config> --restore-original-config <план-original+candidate>
        ubus call zwrt_mc.device.manager device_reboot '{"moduleName":"web"}'
        <путь-к-zte_nv> --snapshot
        ubus call zwrt_zte_mdm.api get_imei
        ubus call zwrt_zte_mdm.api get_imei2
        <путь-к-zte_config> --check-original <план-original+candidate>
        """#),
        .init("8. Продолжение и восстановление", "При ошибке приложение сохраняет бэкап и pending.json, останавливает новую запись и предлагает «Продолжить». Продолжение заново проверяет хэши бэкапа, CID, прошивку, текущие NV и config. Если данные не принадлежат известному исходному или целевому состоянию, операция останавливается для разбора. При неопределённом результате EFS-команды помощник сохраняет файлы восстановления и не отправляет новые записи в той же сессии.\n\nДля возврата к сохранённой паре используется отдельное действие восстановления выбранного бэкапа. Оно требует совпадения устройства/прошивки и неизменности остальных 119 байт обоих NV; перед возвратом создаётся новый бэкап текущего состояния. Восстановление пары проходит через те же проверки, временный config и перезагрузки.\n\nЭта операция не прошивает raw-разделы, не записывает образ ZTEDATA и не перемонтирует /usr/zte_web. Изменения относятся к NV550 и временному EFS config; на Linux-стороне создаются временные помощники и блокировка. Если сначала нужна подготовка доступа, дополнительно изменяются перечисленные в её справке файлы агента, SSH и автозапуска.")
    ]
}

struct OperationHelpSection: Identifiable {
    let title: String
    let body: String
    let commands: String?
    var id: String { title }

    init(_ title: String, _ body: String, commands: String? = nil) {
        self.title = title
        self.body = body
        self.commands = commands
    }
}

@MainActor
struct OperationInfoButton: View {
    let topic: OperationHelpTopic
    @StudioState private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(StudioStyle.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text(topic.accessibilityLabel))
        .accessibilityLabel(L10n.text(topic.accessibilityLabel))
        .accessibilityIdentifier("operation-help-" + topic.rawValue)
        .sheet(isPresented: $isPresented) { OperationHelpSheet(topic: topic) }
    }
}

@MainActor
struct OperationHelpSheet: View {
    let topic: OperationHelpTopic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 24)).foregroundStyle(StudioStyle.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text(topic.title)).font(.system(size: 20, weight: .semibold))
                    Text(L10n.text("Последовательность, команды и сохраняемые данные"))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                }
                Spacer(minLength: 0)
                Button(L10n.text("Закрыть")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("operation-help-close")
            }
            .padding(24)
            Divider().overlay(StudioStyle.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(L10n.text(topic.introduction))
                        .font(.system(size: 13)).lineSpacing(4)
                    Text(L10n.text("В примерах <…> обозначает адрес, UUID, путь, хэш или другой параметр конкретной операции. Пароли и ключи здесь не показываются. Приведены основные вызовы; приложение дополнительно выполняет описанные проверки и защитные обёртки. Команды не нужно вводить вручную."))
                        .font(.system(size: 12)).lineSpacing(3)
                        .foregroundStyle(StudioStyle.secondary)
                        .padding(14)
                        .background(StudioStyle.elevated, in: RoundedRectangle(cornerRadius: 10))
                    ForEach(topic.sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.text(section.title)).font(.system(size: 15, weight: .semibold))
                            Text(L10n.text(section.body)).font(.system(size: 13)).lineSpacing(4)
                            if let commands = section.commands {
                                Text(commands)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(StudioStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioStyle.line))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 740, height: 680)
        .foregroundStyle(StudioStyle.text)
        .background(StudioStyle.surface)
        .preferredColorScheme(.dark)
    }
}
