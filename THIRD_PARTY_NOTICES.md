# Источники и лицензии

Авторство upstream сохранено. Лицензия корня репозитория не заменяет лицензий
перечисленных компонентов. В сборке нет прошивки ZTE, ключей, профилей, дампов
и исполняемого файла SSClash.

| Компонент | Источник / версия | Лицензия и способ использования |
| --- | --- | --- |
| Агент, основа веб-панели, runner и протокол подготовки | [Jesther Silvestre](https://github.com/jesther-ai/open-u60-pro), [David Klasens, v2.4](https://github.com/dklasens/MU5250-OpenUI/tree/fabaf8b53678dc50e3c3fa2fa3de8b51061967cc) | MIT, уведомления в LICENSE и ModemAgent/LICENSE; модификации перечислены в документации |
| ADB 37.0.1 для macOS ARM64 | [Android platform-tools](https://developer.android.com/tools/releases/platform-tools), копия из [MU5250-OpenUI v2.4](https://github.com/dklasens/MU5250-OpenUI/releases/tag/v2.4) | Apache/BSD и другие лицензии компонентов: полный ADB-NOTICE.txt в Resources/Onboarding |
| Dropbear 2022.82-6 | [Пакет OpenWrt 23.05.4](https://downloads.openwrt.org/releases/23.05.4/targets/armsr/armv8/packages/dropbear_2022.82-6_aarch64_generic.ipk), [исходники](https://github.com/mkj/dropbear/tree/DROPBEAR_2022.82) | MIT/BSD; LICENSE, libtomcrypt и libtommath notices в Resources/Onboarding |
| OpenDoas 6.8.2 | [Официальный исходный архив](https://github.com/Duncaen/OpenDoas/releases/download/v6.8.2/opendoas-6.8.2.tar.xz) | ISC/BSD; Resources/SSHAccounts/OpenDoas-LICENSE.txt. Параметры сборки в provenance.json |
| Mihomo 1.19.31 | [Официальный ARM64 asset](https://github.com/MetaCubeX/mihomo/releases/download/v1.19.31/mihomo-linux-arm64-v1.19.31.gz), [точные исходники](https://github.com/MetaCubeX/mihomo/tree/ab405bad5beeeac8b003bb01f60f134f6df54471) | GPLv3; неизменённый официальный бинарник. Полный текст лицензии в Resources/VPN/Mihomo-LICENSE.txt |
| uhttpd 2023-06-25-34a8a74d-2 | [Пакет OpenWrt](https://downloads.openwrt.org/releases/23.05.4/targets/armsr/armv8/packages/uhttpd_2023-06-25-34a8a74d-2_aarch64_generic.ipk), [исходники](https://github.com/openwrt/uhttpd/tree/34a8a74d) | ISC; Resources/VPN/uhttpd-NOTICE.txt |
| network.stock | [OpenWrt netifd init script](https://github.com/openwrt/openwrt/blob/v23.05.4/package/network/config/netifd/files/etc/init.d/network), вариант штатной B31 | GPL-2.0, текст в licenses/OpenWrt-GPL-2.0.txt. Это исходный скрипт службы, не конфигурация пользователя |
| React, React DOM, scheduler | [React](https://github.com/facebook/react); точные версии package-lock.json | MIT; тексты в licenses/ |
| Rust-библиотеки | Cargo.lock, ссылки и версии в licenses/Rust-dependencies.txt | MIT/Apache/BSD по компонентам; уведомления собраны в том же файле |
| SSClash-Go v6.4.1 | [Официальный релиз](https://github.com/zerolabnet/SSClash-Go/releases/tag/v6.4.1) | Проприетарное ПО. Бинарник не распространяется; загрузка самим владельцем по явной кнопке. Текст лицензии и third-party notices включены в Resources/Applications |

## Исходники распространяемых компонентов

Mihomo поставляется без изменения официального ELF; его SHA-256:
`1b315bc038d05f84ee86d232f3c3d2b020b5044e9b971bb8fe215b6e6a2148f3`.
Соответствующий архив исходников указанного commit включён в
**Build-dependencies-20260924.tar.gz → sources/mihomo-v1.19.31-source.tar.gz**,
который доступен рядом с программой на [странице релиза](https://github.com/SadykovIV/ZTE_U60Pro/releases/tag/v1.9.1).
Он также доступен [на сервере upstream](https://codeload.github.com/MetaCubeX/mihomo/tar.gz/ab405bad5beeeac8b003bb01f60f134f6df54471).
Архив содержит go.mod/go.sum, исходники и Makefile upstream; зависимости и
инструменты их сборки определены этим проектом. Лицензия GPL относится к
соответствующему компоненту, а не переименовывает исходники приложения в GPL.

Архив исходников OpenDoas также включён в Build-dependencies. Остальные
распространяемые бинарники сопровождаются лицензионными уведомлениями и ссылками
на точные исходные проекты. Зависимости прошивки (libdiag, ubus, musl, UCI, LVGL
и другие) используются на устройстве и не скопированы из прошивки в дистрибутив.
Небольшой патч экранного UI применяется к файлу, считанному с устройства;
полный файл и штатные шрифты не распространяются. Переводы сохраняют служебные
идентификаторы и общие надписи штатного UI ZTE.
