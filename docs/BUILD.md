# Сборка публичной версии

Сборка не использует приватный рабочий проект, бэкапы или подключённый модем.
Готовое приложение не требует перечисленных инструментов — они нужны только
разработчику. Точный список источников и лицензий: [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).

## Инструменты

- Для `.app`: macOS 13+, Apple Silicon, Xcode Command Line Tools (`swiftc`, `codesign`, `ditto`).
- Python 3.10+ для сборочных скриптов, без сторонних Python-пакетов.
- Rust через rustup с target `aarch64-unknown-linux-musl`; релиз проверен с Rust 1.98.1.
- `aarch64-linux-musl-gcc` в PATH (или `ZTE_CROSS_CC` для C-компонентов); Rust linker задаётся в `ModemAgent/.cargo/config.toml`.
- Node.js `^20.19.0 || >=22.12.0`, npm; CMake и Ninja для lpac. Зависимости закреплены package-lock.json.

## Полная сборка

Из корня репозитория:

```sh
rustup target add aarch64-unknown-linux-musl
python3 tools/fetch_dependencies.py
(cd ModemAgent && cargo fetch --locked)
(cd tools/removable-euicc/device && cargo fetch --locked)
python3 tools/build.py
```

`fetch_dependencies.py` загружает только закреплённый архив **из Releases этого
репозитория**, проверяет SHA-256 архива и каждого бинарника и распаковывает
разрешённые обычные файлы. Манифест — `tools/dependencies.json`. Это ADB, OpenSSH, Dropbear, OpenDoas, uhttpd, официальный Mihomo,
диагностические пакеты, изолированный opkg и публичные модемные помощники.
SSClash в нём нет. Лицензии входят в комплект, соответствующие исходники
опубликованы отдельно в `Third-party-sources-1.23.3.tar.gz`. Каталоги кэша и сборки
исключены из Git.

`build.py` последовательно собирает runtime eSIM (lpac/bridge), расширение экрана, VPN-контроллер, агент eSIM,
веб-панель, C-помощники и `zte-timeout`, обновляет зависимые SHA-256 и собирает `.app`/ZIP.
Пути домашнего каталога в Rust и Swift переназначаются перед компиляцией.
Результат: `MacIMEI/dist/ZTE-U60Pro-Manager-1.23.3-arm64.zip` и `build-manifest.json`.
Rust-рецепт использует offline-сборку после `cargo fetch --locked`; для первой сборки нужен доступ к закреплённым crates. Сборка подписывается ad-hoc; сертификат разработчика и нотарификация не требуются.

Проверка ABI расширения на исходном UI необязательна для повторной сборки:
укажите `ZTE_STOCK_UI` и `ZTE_RUSSIAN_UI` для её выполнения. Полные файлы прошивки
в Git не включайте. При установке и запуске на устройстве проверки SHA-256
штатного UI остаются обязательными независимо от этой сборочной проверки.

## Windows x64

На Windows нужен .NET SDK 10, Python 3 для получения зависимостей и PowerShell.
После клонирования публичного репозитория:

```powershell
python tools/fetch_dependencies.py
.\Windows_x64\build.cmd
```

Результат — `Windows_x64/dist/ZTE-U60Pro-Manager-1.23.3-Windows-x64-portable.zip`.
Готовому приложению SDK, Python и отдельно установленная .NET не нужны.
Не удаляйте `Resources` рядом с EXE. Для USB ADB может понадобиться драйвер ZTE.
EXE не подписан сертификатом. Версии NuGet закреплены lock-файлами.

Исходники Windows полностью находятся в `Windows_x64`. Модемные ARM64 ELF и
Windows ADB/OpenSSH загружаются из закреплённого архива зависимостей, поэтому
обычная Windows-сборка не требует Mac или ARM64-компилятора. Если вы изменили
код агента, сначала пересоберите цепь на Mac/Linux; после публичной полной
сборки выполните `python3 Windows_x64/sync_public_resources.py`, затем `build.cmd`.
Синхронизация обновляет хэши C# и ресурсов, не использует частный проект.

Тесты: [Windows README](../Windows_x64/README.md). Cross-publish на Mac выполняется
через `pwsh -File Windows_x64/build.ps1`; это не проверка исполнения EXE на Windows.

## Только агент / панель

```sh
cd ModemAgent
cargo build --locked --release --target aarch64-unknown-linux-musl -p zte-agent --features esim --bin zte-agent-esim
cd web-app
npm ci
npm run build
```

Для пересборки всей модемной цепи без `.app` выполните из корня `python3 tools/build.py --modem-only --tests`. Отдельная сборка агента использует текущие закреплённые runtime eSIM и хэш VPN-контроллера.
Если меняете контроллер или его встроенные shell-ресурсы, выполняйте полную
сборку из корня, чтобы обновить всю цепочку хэшей. Пересборка иной версией
компилятора может изменить бинарные хэши; это не бит-в-бит воспроизводимый релиз.

## Локальные проверки без устройства

```sh
python3 MacIMEI/tools/check_diagnostics.py
python3 MacIMEI/tools/check_diagnostics.py AppTests BackupPatchTests
python3 MacIMEI/Tests/agent_installation_test.py
python3 MacIMEI/Tests/test_vpn_controller_upgrade.py
python3 MacIMEI/Tests/test_launcher_install.py
python3 MacIMEI/DeviceHelpers/tests/run_tests.py
(cd ModemAgent && cargo test --workspace --locked)
(cd ModemAgent/web-app && npm test && npm run lint)
python3 tools/esim-app/verify_public_release.py
python3 tools/audit_public.py
```

Тесты используют синтетические IMEI, EFS, CID и VPN-ссылки example.com.
`ModemApplicationsTests` дополнительно требует `ZTE_SSCLASH_TEST_ASSET` с путём к
самостоятельно загруженному официальному SSClash v6.4.1; этот файл нельзя включать
в Git/релиз. Экранные испытания, которым нужны штатные ELF, не входят в обычный
набор локальных тестов и требуют собственных файлов устройства.

Для проверки секретов можно дополнительно запустить **Gitleaks 8.30.1+** на
снимке отслеживаемых файлов с `.gitleaks.toml`. Не сканируйте/не публикуйте кэш,
бэкапы и рабочую папку исходного частного проекта вместе с публичным деревом.

## Упаковка релиза

`python3 tools/package_release.py` создаёт отдельный ELF, архив агента с панелью,
ZIP приложения, архив сборочных зависимостей и SHA256SUMS в `release/`.
Для упаковки нужны обе готовые сборки. Скрипт создаёт версионные файлы для
macOS/Windows, агент 2.7.0-esim.8, `Build-dependencies-1.23.3.tar.gz`, отдельный
`Third-party-sources-1.23.3.tar.gz`, манифесты и `SHA256SUMS`.

Исходные архивы `mihomo-v1.19.31-source.tar.gz` и `opendoas-6.8.2.tar.xz`
должны находиться в `.cache`, eSIM-sources.tar.gz и его сведения относятся к eSIM; остальные соответствующие исходники и рецепты —
в `.cache/public-sources`. Для повторной упаковки извлеките опубликованный
Third-party-sources: два указанных архива переместите в `.cache`, остальное —
в `.cache/public-sources`. Файлы `SOURCES.json`, `RECIPES.json` и
`PACKAGE-RECIPE-MATCH.json` содержат версии, хэши и соответствие рецептам.
`tools/dependencies.json` обновляется при упаковке: не публикуйте манифест
без соответствующего архива зависимостей.

Ни один скрипт сборки не публикует файлы автоматически. Перед Git push/release
проверьте `git diff --cached`, прогоните аудит исходников и содержимого архивов.
История приватного проекта и секреты в неё не импортируются.
