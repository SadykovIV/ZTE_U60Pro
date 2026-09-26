# Проверка интерфейса без модема на macOS arm64

Сначала Windows-исходники собираются отдельно для host-target `osx-arm64`;
smoke-проект использует относительную ссылку на эту сборку и запускает её
через Avalonia.Headless. Тест проверяет маскировку Backup-key suffix, его передачу только в подготовку
и повторный ввод после ошибки. Затем открывает 8 страниц и 18 подразделов и
проверяет, что кнопка «Прочитать IMEI» вызывает `IModemService.RunAsync` у
тестового сервиса. Модем и сеть не используются.

Из корня репозитория с .NET SDK 10 выполните:

```sh
dotnet build Windows_x64/src/ZteImeiStudio.Windows.csproj -c Debug -r osx-arm64 \
  --self-contained false -p:PublishSingleFile=false -p:NuGetAudit=false
dotnet build Windows_x64/ui-smoke/UiSmoke.csproj -r osx-arm64 \
  --self-contained false -p:NuGetAudit=false
dotnet Windows_x64/ui-smoke/bin/Debug/net10.0/osx-arm64/UiSmoke.dll
```

Это не проверяет запуск PE на Windows и не заменяет тест на реальном модеме.
