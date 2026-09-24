# Сборка публичной версии

Сборка не использует приватный рабочий проект, бэкапы или подключённый модем.
Готовое приложение не требует перечисленных инструментов — они нужны только
разработчику. Точный список источников и лицензий: [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).

## Инструменты

- Для `.app`: macOS 13+, Apple Silicon, Xcode Command Line Tools (`swiftc`, `codesign`, `ditto`).
- Python 3.10+ для сборочных скриптов, без сторонних Python-пакетов.
- Rust через rustup с target `aarch64-unknown-linux-musl`; релиз проверен с Rust 1.98.1.
- `aarch64-linux-musl-gcc` в PATH (или `ZTE_CROSS_CC` для C-компонентов); Rust linker задаётся в `ModemAgent/.cargo/config.toml`.
- Node.js `^20.19.0 || >=22.12.0`, npm. Зависимости закреплены package-lock.json.

## Полная сборка

Из корня репозитория:

```sh
rustup target add aarch64-unknown-linux-musl
python3 tools/fetch_dependencies.py
python3 tools/build.py
```

`fetch_dependencies.py` загружает только закреплённый архив **из Releases этого
репозитория**, проверяет SHA-256 архива и каждого бинарника и распаковывает
разрешённые обычные файлы. Манифест — `tools/dependencies.json`. Это ADB, Dropbear,
OpenDoas, uhttpd и официальный Mihomo; SSClash в нём нет. Лицензии и архивы
исходников Mihomo/OpenDoas находятся в том же архиве. Каталоги кэша и сборки
исключены из Git.

`build.py` последовательно собирает расширение экрана, VPN-контроллер, агент,
веб-панель и C-помощники, обновляет зависимые SHA-256 и собирает `.app`/ZIP.
Пути домашнего каталога в Rust и Swift переназначаются перед компиляцией.
Результат: `MacIMEI/dist/ZTE-IMEI-Studio-1.9.1-arm64.zip` и `build-manifest.json`.
Сборка подписывается ad-hoc; сертификат разработчика и нотарификация не требуются.

Проверка ABI расширения на исходном UI необязательна для повторной сборки:
укажите `ZTE_STOCK_UI` и `ZTE_RUSSIAN_UI` для её выполнения. Полные файлы прошивки
в Git не включайте. При установке и запуске на устройстве проверки SHA-256
штатного UI остаются обязательными независимо от этой сборочной проверки.

## Только агент / панель

```sh
cd ModemAgent
cargo build --locked --release --target aarch64-unknown-linux-musl -p zte-agent
cd web-app
npm ci
npm run build
```

Отдельная сборка агента использует текущий закреплённый хэш VPN-контроллера.
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
Для упаковки нужны исходные архивы `mihomo-v1.19.31-source.tar.gz` и
`opendoas-6.8.2.tar.xz` в `.cache`; они доступны в предыдущем архиве
Build-dependencies (раздел sources) и по точным ссылкам в THIRD_PARTY_NOTICES.

Ни один скрипт сборки не публикует файлы автоматически. Перед Git push/release
проверьте `git diff --cached`, прогоните аудит исходников и содержимого архивов.
История приватного проекта и секреты в неё не импортируются.
