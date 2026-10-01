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
| Диагностические утилиты | htop 3.3.0, mtr 0.95, iperf3 3.17.1, tcpdump 4.99.4; пакеты OpenWrt 23.05.4 | GPL-2.0+ для htop/mtr, BSD для iperf/tcpdump/libpcap; версии, URLs и SHA в Resources/DiagnosticTools/PROVENANCE.json, лицензии в LICENSES.txt |
| Изолированный opkg | opkg d038e5b6, BusyBox 1.36.1, mbedTLS 2.28.10, ca-bundle 20241223, OpenWrt uclient/usign/libubox | GPL-2.0/GPL-2.0+/MPL/ISC по компонентам; Resources/ExperimentalOpkg/PROVENANCE.json и LICENSES.txt |
| Библиотеки ARM64 | GCC runtime 12.3.0, musl, ncurses 6.4 | GCC GPL-3.0 + Runtime Library Exception; musl/ncurses MIT. Corresponding sources и точные рецепты в архиве исходников |
| Windows ADB и OpenSSH | Android platform-tools 37.0.1, Win32-OpenSSH 10.0.0.0p2-Preview | Полные notices и provenance в Windows_x64/Resources/Tools |
| .NET/Avalonia и C#-зависимости | .NET 10.0.7, Avalonia 11.3.12, SSH.NET 2025.0.0, Skia/HarfBuzz и зависимости | MIT/BSD/Apache и другие лицензии компонентов; Windows_x64/Resources/Licenses, packages.json и NuGet lock-файлы |
| xterm.js и addon-fit | Точные версии в MacIMEI/Resources/Terminal/PROVENANCE.json | MIT; XTERM-LICENSE.txt и FIT-LICENSE.txt рядом с ресурсами |
| lpac v2.3.0 | [estkme-group/lpac](https://github.com/estkme-group/lpac/tree/c2fcf5e4b21c712d54e35a11da2ad9ad134fb821), commit c2fcf5e4b21c712d54e35a11da2ad9ad134fb821; закреплённые stdio backports | CLI: AGPL-3.0; libeuicc: LGPL-2.1; cJSON: MIT. Точные исходники, патчи, lock-файлы и рецепты: `third_party/lpac`, `third_party/lpac-build`, `eSIM-sources.tar.gz` |
| QMI/ES10 bridge | Компонент физической eUICC; исходники `tools/removable-euicc/device/`, точные SHA-256 в `component.json` | Лицензия не указана. Корневая MIT-лицензия не предоставляет права на этот компонент. См. [сферу лицензирования](LICENSE-SCOPE.md) |
| jsQR 1.4.0 | [cozmo/jsQR](https://github.com/cozmo/jsQR), точный npm integrity в package-lock.json | Apache-2.0; локальное декодирование QR в веб-панели. LICENSE-jsQR-Apache-2.0.txt в панели |
| GSMA production RSP root certificates | Официальные GSMA roots; URLs и SHA-256 DER/PEM: `tools/removable-euicc/certs/gsma-rsp-roots.json` | Публичные корневые сертификаты, не ключи; проверка TLS остаётся включённой |
| Roboto | [Google Fonts / Roboto](https://github.com/googlefonts/roboto) | Apache-2.0, LICENSE/NOTICE в Resources/VPN. Дополнительный шрифт для страницы eSIM; штатные шрифты ZTE не распространяются |
| SSClash-Go v6.4.1 | [Официальный релиз](https://github.com/zerolabnet/SSClash-Go/releases/tag/v6.4.1) | Проприетарное ПО. Бинарник не распространяется; загрузка самим владельцем по явной кнопке. Текст лицензии и third-party notices включены в Resources/Applications |

## eSIM: исходники и пересборка

`eSIM-sources.tar.gz` поставляется внутри `Resources/Esim`, отдельного архива агента и `Third-party-sources-1.23.2.tar.gz`. Он содержит полный lpac/libeuicc/cJSON, upstream stdio patch, локальные агент/bridge/launcher/web-компоненты, лицензии и рецепты. Исходники также доступны в Git. [Описание изменений и сборки](third_party/ESIM-SOURCES.md). `PROVENANCE.json` фиксирует upstream commit, SHA-256 компонентов и архива; версия lpac явно закреплена как `v2.3.0-stdio-backports`.

## Исходники распространяемых компонентов

Mihomo поставляется без изменения официального ELF; его SHA-256:
`1b315bc038d05f84ee86d232f3c3d2b020b5044e9b971bb8fe215b6e6a2148f3`.
Соответствующий архив исходников указанного commit включён в
**Third-party-sources-1.23.2.tar.gz → mihomo-v1.19.31-source.tar.gz**,
который доступен рядом с программой на [странице релиза](https://github.com/SadykovIV/ZTE_U60Pro/releases/tag/v1.23.2).
Он также доступен [на сервере upstream](https://codeload.github.com/MetaCubeX/mihomo/tar.gz/ab405bad5beeeac8b003bb01f60f134f6df54471).
Архив содержит go.mod/go.sum, исходники и Makefile upstream; зависимости и
инструменты их сборки определены этим проектом. Лицензия GPL относится к
соответствующему компоненту, а не переименовывает исходники приложения в GPL.

В тот же архив включены OpenDoas, htop, mtr, opkg, BusyBox, mbedTLS,
ca-certificates, GCC runtime, permissive-библиотеки и архивы OpenWrt/build recipes.
Манифесты фиксируют URL, SHA-256, версии, commit рецептов и SourceDateEpoch
распространяемых IPK. Feed 23.05 обновлялся после тега 23.05.4: точные версии
определяются PROVENANCE.json и соответствующими рецептами, а не только тегом
прошивки. Бит-в-бит воспроизводимость сторонних IPK не заявляется.

Зависимости прошивки (libdiag, ubus, UCI, LVGL и другие) используются на
устройстве и не скопированы из прошивки. Дополнительные musl/OpenWrt runtime
получены из открытых исходников/официальных пакетов и размещаются отдельно в `/data`.
Небольшой патч экранного UI применяется к файлу, считанному с устройства;
полный файл и штатные шрифты не распространяются. Переводы сохраняют служебные
идентификаторы и общие надписи штатного UI ZTE.
