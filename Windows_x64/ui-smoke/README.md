# Проверка интерфейса без модема на macOS arm64

Тест использует Avalonia.Headless и Skia: открывает все 8 страниц и 18
подразделов, проверяет переключение RU/EN, каталог только из проверенных
приложений, сохранение установленных приложений вне каталога, выбор SSH
файлов и ссылки «О программе». Отдельно проверяются автоматическое открытие
Terminal, отсутствие дубликатов при обновлении, ручное отключение, повторный
вход и отсутствие подключения. Модем и сеть не используются; языковые
настройки пользователя не изменяются.

Сохраняются восемь PNG в `Windows_x64/dist/ui-preview`: подготовка, каталог,
терминал и «О программе» на русском и английском. Применяется та же тема,
что в основном приложении, и значок из `Resources/Branding`.

Из корня проекта:

```sh
dotnet build Windows_x64/src/ZteImeiStudio.Windows.csproj -c Debug -r osx-arm64 \
  --self-contained false -p:PublishSingleFile=false -p:NuGetAudit=false \
  -p:NuGetLockFilePath=../ui-smoke/host.packages.lock.json
dotnet build Windows_x64/ui-smoke/UiSmoke.csproj -r osx-arm64 \
  --self-contained false -p:NuGetAudit=false
dotnet Windows_x64/ui-smoke/bin/Debug/net10.0/osx-arm64/UiSmoke.dll
```

Это не проверяет запуск PE на Windows и не заменяет тест на реальном модеме.
Для host-проверки используется отдельный lock-файл, чтобы не менять закреплённые
зависимости основной сборки win-x64.
