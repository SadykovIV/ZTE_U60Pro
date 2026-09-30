# Скриншоты интерфейса 1.23.2

Свежие снимки настоящих компонентов интерфейса с **синтетическими данными**, без подключения к модему. Это иллюстрации функций, а не квитанции аппаратных испытаний.

- **macOS:** нативный SwiftUI на macOS ARM64. Модель отключена от модема; discovery и исследование прошивки блокируются preview-обвязкой.
- **Windows:** настоящий интерфейс Avalonia из сборки 1.23.2, отрисованный headless на macOS ARM64 с подставным сервисом. **Запуск в Windows этими снимками не проверялся.** Надпись «Подключено» отражает только синтетическое состояние модели.
- Профили, EID/ICCID и адреса — примеры. Реальных QR, Matching ID, паролей или ключей нет. Поля кодов оставлены пустыми; никакой профиль не загружался и не переключался.

| Экран | macOS · RU | macOS · EN | Windows UI · RU | Windows UI · EN |
|---|---|---|---|---|
| Подключение: адрес, SSH и подготовка модема | [PNG](macos-connection-ru.png) | [PNG](macos-connection-en.png) | [PNG](windows-connection-ru.png) | [PNG](windows-connection-en.png) |
| eSIM: активный и выключенный профили, SM-DP+ Address и Activation code | [PNG](macos-esim-ru.png) | [PNG](macos-esim-en.png) | [PNG](windows-esim-ru.png) | [PNG](windows-esim-en.png) |
| Launcher: чекбоксы страниц и стрелки порядка; eSIM и информация выбраны, VPN выключен | [PNG](macos-launcher-ru.png) | [PNG](macos-launcher-en.png) | [PNG](windows-launcher-ru.png) | [PNG](windows-launcher-en.png) |

Исходные компоненты UI соответствуют проверенной версии 1.23.2. PNG получены непосредственным захватом отрисованных окон, без генерации изображений или дорисовки. Хеши, размеры и происхождение: [screenshots-manifest.json](screenshots-manifest.json).

## English

These are fresh captures of the actual 1.23.2 UI using synthetic fixtures. No modem was contacted. macOS images use native SwiftUI; Windows UI images use the production Avalonia assembly in a macOS headless host, **not a verified Windows OS session**. The simulated connection indicator does not represent a live connection. Profiles and identifiers are synthetic; activation and confirmation fields are empty.
