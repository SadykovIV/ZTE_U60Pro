import Foundation

enum ModemDisplayState: String, Sendable {
    case absent, ready, outdated, failed, recoveryPending, unsupported
}

struct ModemDisplayInspection: Sendable {
    var state: ModemDisplayState
    var detail: String
    var identity: Identity
    var bootID: String
    var installedHash: String?
    var expectedHash: String
    var running: Bool = false
    var canInstall: Bool = false
    var layout: ModemDisplayLayout? = .defaultLayout
    var layoutWarning: String?
    var layoutIsDefault: Bool = true
    var layoutIsSafe: Bool = true
    var canApplyLayout: Bool { state == .ready && layoutIsSafe }
    var pages: ModemLauncherPages? = .defaultPages
    var pagesWarning: String?
    var pagesIsDefault: Bool = true
    var pagesIsSafe: Bool = true
    var canApplyPages: Bool { state == .ready && pagesIsSafe && pages != nil }

    var title: String {
        switch state {
        case .absent: return "Дополнительные плитки не установлены"
        case .ready: return running ? "Плитки работают на дисплее" : "Плитки установлены"
        case .outdated: return "Доступно обновление плиток"
        case .failed: return "Дисплей требует проверки"
        case .recoveryPending: return "Установка дисплея не завершена"
        case .unsupported: return "Экран этой прошивки пока не поддерживается"
        }
    }
}

/// The caller holds ModemEngine.locked for the whole operation. Display changes
/// always require the exact reviewed B31 UI ABI, even when general checks are off.
final class ModemDisplayManager {
    static let root = "/data/zte-launcher"
    static let layoutPath = root + "/info-layout.conf"
    static let pagesPath = root + "/page-layout.conf"
    static let payloadNames = ["launcher.so", "launcher-run.sh", "launcher-watch.sh", "launcher-service.sh", "launcher-start.sh"]
    static let fileNames = payloadNames + ["launcher.sha256", "install-launcher.sh"]
    static let uiHashes: Set<String> = [
        "e3914e78a8488cb736770f0ac9fb8ce10e0e5222fa50285f08e9e8be90d7f1e9",
        "16eb92e27f54b5cf5c6b316a6e7a62b782053a2a609d0d4904a7f08a7bc0afa4"
    ]
    static let initHashes: Set<String> = [
        "a30da6481637f1fd94e037373d406e574be7e722937a4965325086740be67e35",
        "0a462f4021b1306ac5fbf074a674bae9fef952f240436a47468c0126c5d41b50"
    ]
    let engine: ModemEngine
    private let updateVPNIntegration: (() throws -> Bool)?
    private let prepareEsimAgent: (() throws -> Void)?

    init(engine: ModemEngine, updateVPNIntegration: (() throws -> Bool)? = nil, prepareEsimAgent: (() throws -> Void)? = nil) {
        self.engine = engine
        self.updateVPNIntegration = updateVPNIntegration
        self.prepareEsimAgent = prepareEsimAgent
    }

    private struct Assets {
        var files: [String: Data]
        var hashes: [String: String]
    }

    private func assets() throws -> Assets {
        let directory = engine.resources.appendingPathComponent("VPN")
        let manifest = try readJSON([String: String].self, directory.appendingPathComponent("SHA256.json"))
        var files = [String: Data](), hashes = [String: String]()
        for name in Self.fileNames {
            guard let hash = manifest[name], Self.isHash(hash) else {
                throw IMEIError.message("Неполный встроенный комплект дисплея: " + name)
            }
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            try require(!data.isEmpty && data.count <= 4 * 1024 * 1024 && digest(data) == hash,
                        "Повреждён встроенный компонент дисплея: " + name)
            files[name] = data; hashes[name] = hash
        }
        var payloadHashes = [String: String]()
        for line in String(decoding: files["launcher.sha256"]!, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            try require(fields.count == 2 && Self.payloadNames.contains(fields[1]) && payloadHashes[fields[1]] == nil && Self.isHash(fields[0]),
                        "Повреждён список контрольных сумм дисплея")
            payloadHashes[fields[1]] = fields[0]
        }
        try require(Set(payloadHashes.keys) == Set(Self.payloadNames) && payloadHashes.allSatisfy { hashes[$0.key] == $0.value },
                    "Контрольные суммы комплекта дисплея не согласованы")
        return Assets(files: files, hashes: hashes)
    }

    private static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static let probeCommand = #"""
    set -eu
    hash_file() { if test -f "$1" && test ! -L "$1"; then sha256sum "$1" | awk '{print $1}'; else printf '%s\n' missing; fi; }
    uid=$(id -u); arch=$(uname -m)
    ui=$(hash_file /usr/bin/zte_topsw_devui)
    init=$(hash_file /etc/init.d/zte_topsw_devui)
    root=/data/zte-launcher
    root_state=0; integrity=0; enabled=0; failure=0; service=0; startup=0; running=0; transaction=0; installed=missing; manifest=missing
    if test -e /data/zte-launcher-update || test -L /data/zte-launcher-update; then
        transaction=2
        if test -d /data/zte-launcher-update && test ! -L /data/zte-launcher-update && test "$(stat -c %u:%a /data/zte-launcher-update)" = 0:700 &&
           test "$(cat /data/zte-launcher-update/owner 2>/dev/null)" = zte-launcher-update-v1 &&
           test "$(cat /data/zte-launcher-update/cid 2>/dev/null)" = "$(cat /sys/block/mmcblk0/device/cid)"; then transaction=1; fi
    fi
    if test -e "$root" || test -L "$root"; then
        root_state=2
        if test -d "$root" && test ! -L "$root" && test "$(stat -c %u:%a "$root")" = 0:700 &&
           test "$(cat "$root/owner" 2>/dev/null)" = zte-native-launcher-v1 &&
           test "$(cat "$root/cid" 2>/dev/null)" = "$(cat /sys/block/mmcblk0/device/cid)"; then
            root_state=1; integrity=1
            for file in launcher.so launcher-run.sh launcher-watch.sh launcher-service.sh launcher-start.sh launcher.sha256; do
                if ! test -f "$root/$file" || test -L "$root/$file" || test "$(stat -c %u "$root/$file")" != 0; then integrity=0; break; fi
                mode=$(stat -c %a "$root/$file"); test "$((0$mode & 022))" = 0 || integrity=0
            done
            if test "$integrity" = 1; then (cd "$root" && sha256sum -c launcher.sha256 >/dev/null 2>&1) || integrity=0; fi
            installed=$(hash_file "$root/launcher.so"); manifest=$(hash_file "$root/launcher.sha256")
            test ! -f "$root/enabled" || test -L "$root/enabled" || enabled=1
            if test -e "$root/failed" || test -L "$root/failed"; then failure=1; fi
            if test -f /etc/init.d/zte_launcher && test ! -L /etc/init.d/zte_launcher && cmp -s /etc/init.d/zte_launcher "$root/launcher-service.sh"; then service=1; fi
            if test -f /etc/rc.local && test ! -L /etc/rc.local && grep -qFx 'sh /data/zte-launcher/launcher-start.sh' /etc/rc.local; then startup=1; fi
            pid=$(pidof zte_topsw_devui 2>/dev/null || true)
            case "$pid" in ''|*[!0-9]*) ;; *)
                if test "$integrity" = 1 && test "$enabled" = 1 && test "$failure" = 0 &&
                   test -d /tmp/zte-launcher && test ! -L /tmp/zte-launcher && test "$(stat -c %u:%a /tmp/zte-launcher)" = 0:700 &&
                   test -f /tmp/zte-launcher/ready && test ! -L /tmp/zte-launcher/ready && test "$(cat /tmp/zte-launcher/ready)" = "$pid" &&
                   awk -v path="$root/launcher.so" -v inode="$(stat -c %i "$root/launcher.so")" '$5==inode && $6==path && NF==6 {found=1} END {exit !found}' "/proc/$pid/maps"; then running=1; fi;;
            esac
        fi
    elif test -e /etc/init.d/zte_launcher || test -L /etc/init.d/zte_launcher; then root_state=2; fi
    printf 'MODEM_DISPLAY uid=%s arch=%s ui=%s init=%s root=%s integrity=%s enabled=%s failure=%s service=%s startup=%s running=%s transaction=%s installed=%s manifest=%s\n' "$uid" "$arch" "$ui" "$init" "$root_state" "$integrity" "$enabled" "$failure" "$service" "$startup" "$running" "$transaction" "$installed" "$manifest"
    """#

    static let layoutReadCommand = #"""
    # MODEM_DISPLAY_LAYOUT_READ
    set -eu
    root=/data/zte-launcher; file="$root/info-layout.conf"
    if ! test -d "$root" || test -L "$root" || test "$(stat -c %u:%a "$root")" != 0:700; then
        printf '%s\n' 'MODEM_DISPLAY_LAYOUT unsafe'; exit 0
    fi
    if test ! -e "$file" && test ! -L "$file"; then
        printf '%s\n' 'MODEM_DISPLAY_LAYOUT missing'; exit 0
    fi
    if ! test -f "$file" || test -L "$file" || test "$(stat -c %u:%a:%h "$file")" != 0:600:1; then
        printf '%s\n' 'MODEM_DISPLAY_LAYOUT unsafe'; exit 0
    fi
    if test "$(stat -c %s "$file")" -gt 512; then
        printf '%s\n' 'MODEM_DISPLAY_LAYOUT oversized'; exit 0
    fi
    printf '%s\n' 'MODEM_DISPLAY_LAYOUT data'
    dd if="$file" bs=513 count=1 2>/dev/null | base64
    """#

    static let pagesReadCommand = layoutReadCommand
        .replacingOccurrences(of: "MODEM_DISPLAY_LAYOUT", with: "MODEM_DISPLAY_PAGES")
        .replacingOccurrences(of: "info-layout.conf", with: "page-layout.conf")
        .replacingOccurrences(of: "512", with: "128")
        .replacingOccurrences(of: "513", with: "129")

    private func readPages(into result: inout ModemDisplayInspection) throws {
        let data = try engine.remote(Self.pagesReadCommand)
        try require(data.count <= 512, "Получен слишком большой список страниц")
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        switch lines.first {
        case "MODEM_DISPLAY_PAGES missing":
            result.pages = .defaultPages; result.pagesIsDefault = true
        case "MODEM_DISPLAY_PAGES unsafe", "MODEM_DISPLAY_PAGES oversized":
            result.pages = nil; result.pagesIsDefault = false; result.pagesIsSafe = false
            result.pagesWarning = "Файл страниц не прошёл проверку типа, владельца, прав или размера. Запись заблокирована."
        case "MODEM_DISPLAY_PAGES data":
            result.pagesIsDefault = false
            guard let bytes = Data(base64Encoded: lines.dropFirst().joined()) else { throw IMEIError.message("Повреждён ответ со списком страниц") }
            do { result.pages = try ModemLauncherPages.decode(bytes) }
            catch {
                result.pages = nil; result.pagesIsSafe = false
                result.pagesWarning = "Сохранённый список страниц повреждён. Установка и запись остановлены; требуется проверка файла на модеме."
            }
        default: throw IMEIError.message("Неизвестный ответ со списком страниц")
        }
    }

    private func readLayout(into result: inout ModemDisplayInspection) throws {
        let data = try engine.remote(Self.layoutReadCommand)
        try require(data.count <= 1024, "Получена слишком большая настройка дисплея")
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        switch lines.first {
        case "MODEM_DISPLAY_LAYOUT missing":
            result.layout = .defaultLayout; result.layoutIsDefault = true
        case "MODEM_DISPLAY_LAYOUT unsafe":
            result.layout = nil; result.layoutIsDefault = false; result.layoutIsSafe = false
            result.layoutWarning = "Файл настройки дисплея не прошёл проверку типа, владельца или прав. Запись заблокирована."
        case "MODEM_DISPLAY_LAYOUT oversized":
            result.layout = nil; result.layoutIsDefault = false; result.layoutIsSafe = false
            result.layoutWarning = "Сохранённая настройка дисплея превышает 512 байт. Требуется проверка файла на модеме; автоматическая запись заблокирована."
        case "MODEM_DISPLAY_LAYOUT data":
            result.layoutIsDefault = false
            let encoded = lines.dropFirst().joined()
            guard let bytes = Data(base64Encoded: encoded) else { throw IMEIError.message("Повреждён ответ с настройкой дисплея") }
            do { result.layout = try ModemDisplayLayout.decode(bytes) }
            catch {
                result.layout = nil
                result.layoutWarning = "Сохранённая настройка дисплея повреждена. Выберите показатели и примените настройку заново."
            }
        default: throw IMEIError.message("Неизвестный ответ с настройкой дисплея")
        }
    }

    private static func parse(_ text: String) throws -> [String: String] {
        let lines = text.split(whereSeparator: \.isNewline)
        try require(text.utf8.count <= 2048 && lines.count == 1, "Получен неполный статус дисплея")
        let fields = lines[0].split(whereSeparator: \.isWhitespace)
        try require(fields.first == "MODEM_DISPLAY", "Неизвестный формат статуса дисплея")
        var values = [String: String]()
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            try require(pair.count == 2 && values[pair[0]] == nil, "Повтор или повреждение поля дисплея")
            values[pair[0]] = pair[1]
        }
        try require(Set(values.keys) == Set(["uid", "arch", "ui", "init", "root", "integrity", "enabled", "failure", "service", "startup", "running", "transaction", "installed", "manifest"]), "Неполный статус дисплея")
        for key in ["root", "transaction"] { try require(["0", "1", "2"].contains(values[key]!), "Некорректное состояние дисплея") }
        for key in ["integrity", "enabled", "failure", "service", "startup", "running"] { try require(["0", "1"].contains(values[key]!), "Некорректное состояние дисплея") }
        for key in ["ui", "init", "installed", "manifest"] { try require(values[key] == "missing" || isHash(values[key]!), "Некорректная контрольная сумма дисплея") }
        return values
    }

    private func inspect(assets: Assets) throws -> ModemDisplayInspection {
        let (identity, boot) = try engine.diagnosticIdentity()
        let fields = try Self.parse(engine.text(Self.probeCommand))
        var result = ModemDisplayInspection(state: .absent, detail: "На экране будут доступны информация о модеме, VPN и eSIM.", identity: identity, bootID: boot,
                                           installedHash: fields["installed"] == "missing" ? nil : fields["installed"], expectedHash: assets.hashes["launcher.so"]!)
        if fields["root"] == "1" { try readLayout(into: &result); try readPages(into: &result) }
        let after = try engine.diagnosticIdentity()
        try require(after.0 == identity && after.1 == boot, "Во время проверки дисплея модем изменился или перезагрузился")
        guard identity.firmwareHash == ModemEngine.firmwareHash && fields["uid"] == "0" && fields["arch"] == "aarch64" &&
              Self.uiHashes.contains(fields["ui"]!) && Self.initHashes.contains(fields["init"]!) else {
            result.state = .unsupported
            result.detail = "Плитки проверены только для экранного интерфейса MU5250 B31 (штатного или русифицированного). Отключение общей проверки прошивки это ограничение не снимает."
            return result
        }
        if fields["transaction"] == "2" || fields["root"] == "2" {
            result.state = .failed; result.detail = "Каталог дисплея или его восстановления не прошёл проверку владельца и привязки к модему. Автоматическая перезапись остановлена."
        } else if fields["transaction"] == "1" {
            result.state = .recoveryPending; result.canInstall = true
            result.detail = "Обнаружена незавершённая установка этого модема. Повторная установка сначала проверит журнал и восстановит прежнее состояние."
        } else if fields["root"] == "0" {
            result.canInstall = true
        } else if fields["integrity"] != "1" || fields["service"] != "1" {
            result.state = .failed; result.detail = "Файлы дисплея или служба запуска изменены. Целостность установки не подтверждена."
        } else if fields["failure"] == "1" || fields["enabled"] != "1" || fields["startup"] != "1" {
            result.state = .failed; result.canInstall = true
            result.detail = "Дополнительные плитки отключены или не подтвердили запуск. Проверенная повторная установка восстановит их файлы и службу запуска."
        } else if fields["installed"] != assets.hashes["launcher.so"] || fields["manifest"] != assets.hashes["launcher.sha256"] {
            result.state = .outdated; result.canInstall = true
            result.detail = "Установлена прежняя версия плиток. Можно обновить её до комплекта из приложения."
        } else {
            result.state = .ready; result.canInstall = true; result.running = fields["running"] == "1"
            result.detail = result.running ? "Файлы, автозапуск и работа расширения в экранном интерфейсе подтверждены." : "Файлы и автозапуск подтверждены. Работа плиток на экране ещё не подтверждена; повторите проверку через несколько секунд."
        }
        if !result.layoutIsSafe || !result.pagesIsSafe { result.canInstall = false }
        return result
    }

    func inspect() throws -> ModemDisplayInspection { try inspect(assets: assets()) }

    /// Install the eSIM-capable bundle without applying a local editor draft.
    /// Existing VPN installations need their pinned controller upgraded together
    /// with the agent; an absent VPN is never installed by this action.
    func installEsimPage() throws -> ModemDisplayInspection {
        try require(engine.lockFD >= 0 && !engine.connection.skipFirmwareCheck, "Страница eSIM требует SSH и включённой проверки прошивки")
        try engine.connection.validate()
        for name in ["pending.json", "setup-pending.json", "adb-access-pending.json"] {
            try require(!FileManager.default.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала завершите настройку или смену IMEI")
        }
        let bundle = try assets(), before = try inspect(assets: bundle)
        try require(before.canInstall && before.layoutIsSafe && before.layout != nil, before.pagesWarning ?? before.layoutWarning ?? before.detail)
        try engine.acquireRemoteLock()
        let locked = try inspect(assets: bundle)
        try require(locked.identity == before.identity && locked.bootID == before.bootID && locked.layout == before.layout && locked.layoutIsDefault == before.layoutIsDefault && locked.pages == before.pages && locked.pagesIsDefault == before.pagesIsDefault,
                    "Перед установкой страницы eSIM модем или его раскладка изменились")
        try require(locked.canInstall && locked.layoutIsSafe, locked.pagesWarning ?? locked.layoutWarning ?? locked.detail)
        try preflightEsimLauncher(assets: bundle, expected: locked)
        // The existing VPN path includes agent, controller, dashboard and launcher
        // once, and preserves profile configuration. Avoid a second launcher apply.
        let integrated = try updateVPNIntegration?() ?? VPNSettingsManager(engine: engine).updateDisplayIntegrationIfNeeded()
        let installed: ModemDisplayInspection
        if integrated {
            installed = try confirmInstall(assets: bundle, expected: locked)
        } else {
            if let prepareEsimAgent { try prepareEsimAgent() }
            else {
                engine.update("Проверяю и устанавливаю агент для страницы eSIM", 0.25)
                let candidate = try AgentCandidate.inspect(engine.resources.appendingPathComponent("Onboarding/zte-agent"))
                try require(candidate.sha256 == BundledAgent.sha256, "Повреждён встроенный агент")
                _ = try AgentInstallationManager(engine: engine).installBundled(candidate)
            }
            let checked = try inspect(assets: bundle)
            try require(checked.identity == locked.identity && checked.bootID == locked.bootID && checked.layout == locked.layout && checked.layoutIsDefault == locked.layoutIsDefault && checked.pages == locked.pages && checked.pagesIsDefault == locked.pagesIsDefault,
                        "Во время обновления агента модем или его раскладка изменились")
            installed = try ModemDisplayManager(engine: engine, updateVPNIntegration: { false }).install()
        }
        try require(installed.identity == before.identity && installed.bootID == before.bootID && installed.layout == before.layout && installed.layoutIsDefault == before.layoutIsDefault && installed.pages == before.pages && installed.pagesIsDefault == before.pagesIsDefault,
                    "Страница eSIM установлена, но сохранение раскладки не подтверждено. Обновите состояние Launcher.")
        guard let pages = installed.pages else { throw IMEIError.message("Не удалось прочитать порядок страниц") }
        return try applyPagesLocked(pages.includingEsim(), assets: bundle, expected: installed)
    }

    private func preflightEsimLauncher(assets: Assets, expected: ModemDisplayInspection) throws {
        let stage = "/tmp/zte-vpn-agent-" + UUID().uuidString.lowercased()
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        defer { _ = try? engine.remote("rm -f " + Self.fileNames.map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage), timeout: 15) }
        for name in Self.fileNames {
            let path = stage + "/" + name
            let proof = try engine.remote("umask 077; cat > " + shellQuote(path) + " && chmod 700 " + shellQuote(path) + " && sha256sum " + shellQuote(path), input: assets.files[name]!, timeout: 120)
            let fields = String(decoding: proof, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            try require(fields.count == 2 && fields[0] == Substring(assets.hashes[name]!) && fields[1] == Substring(path), "При передаче повреждён компонент дисплея: " + name)
        }
        guard let token = engine.remoteLockToken else { throw IMEIError.message("Потеряна блокировка дисплея") }
        let command = "set -eu; test \"$(cat /tmp/zte-imei-app.lock/owner)\" = " + shellQuote(token) +
            "; test \"$(cat /sys/block/mmcblk0/device/cid)\" = " + shellQuote(expected.identity.cid) +
            "; test \"$(cat /proc/sys/kernel/random/boot_id)\" = " + shellQuote(expected.bootID) +
            "; sh " + shellQuote(stage + "/install-launcher.sh") + " " + shellQuote(stage) + " preflight"
        engine.update("Проверяю компоненты страницы eSIM до обновления агента", 0.15)
        let reply = try engine.remote(command, timeout: 45)
        try require(String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "LAUNCHER_PREFLIGHT_OK",
                    "Предварительная проверка Launcher не подтверждена. Компоненты не обновлялись.")
    }

    func install(layout: ModemDisplayLayout? = nil, pages: ModemLauncherPages? = nil) throws -> ModemDisplayInspection {
        try layout?.validate(); try pages?.validate()
        // The dedicated path prepares the agent and coupled VPN controller once.
        // Its inner generic install has no pages argument, so this cannot recurse.
        if pages?.pages.contains(.esim) == true {
            let installed = try installEsimPage()
            return try applyPreferences(layout: layout, pages: pages, assets: assets(), expected: installed)
        }
        try require(engine.lockFD >= 0, "Операция дисплея требует общей блокировки приложения")
        try engine.connection.validate()
        for name in ["pending.json", "setup-pending.json", "adb-access-pending.json"] {
            try require(!FileManager.default.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала завершите настройку или смену IMEI")
        }
        let bundle = try assets(), before = try inspect(assets: bundle)
        try require(before.canInstall, before.pagesWarning ?? before.layoutWarning ?? before.detail)
        try engine.acquireRemoteLock()
        let locked = try inspect(assets: bundle)
        try require(locked.identity == before.identity && locked.bootID == before.bootID, "Перед установкой дисплея модем изменился или перезагрузился")
        try require(locked.canInstall, locked.pagesWarning ?? locked.layoutWarning ?? locked.detail)
        if locked.state == .ready && locked.running {
            return try applyPreferences(layout: layout, pages: pages, assets: bundle, expected: locked)
        }
        let integrated = try updateVPNIntegration?() ?? VPNSettingsManager(engine: engine).updateDisplayIntegrationIfNeeded()
        if integrated {
            let installed = try confirmInstall(assets: bundle, expected: before)
            return try applyPreferences(layout: layout, pages: pages, assets: bundle, expected: installed)
        }
        let stage = "/tmp/zte-vpn-agent-" + UUID().uuidString.lowercased()
        _ = try engine.remote("umask 077; mkdir " + shellQuote(stage))
        defer {
            _ = try? engine.remote("rm -f " + Self.fileNames.map { shellQuote(stage + "/" + $0) }.joined(separator: " ") + "; rmdir " + shellQuote(stage), timeout: 15)
        }
        for (index, name) in Self.fileNames.enumerated() {
            let path = stage + "/" + name, data = bundle.files[name]!
            let proof = try engine.remote("umask 077; cat > " + shellQuote(path) + " && chmod 700 " + shellQuote(path) + " && sha256sum " + shellQuote(path), input: data, timeout: 120)
            let fields = String(decoding: proof, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            try require(fields.count == 2 && fields[0] == Substring(bundle.hashes[name]!) && fields[1] == Substring(path), "При передаче повреждён компонент дисплея: " + name)
            engine.update("Передаю компоненты дисплея: \(index + 1) из \(Self.fileNames.count)", 0.2 + Double(index + 1) / Double(Self.fileNames.count) * 0.5)
        }
        let checked = try inspect(assets: bundle)
        try require(checked.identity == before.identity && checked.bootID == before.bootID, "После передачи дисплея модем изменился или перезагрузился")
        try require(checked.canInstall, checked.detail)
        guard let token = engine.remoteLockToken else { throw IMEIError.message("Потеряна блокировка дисплея") }
        let command = "set -eu; test \"$(cat /tmp/zte-imei-app.lock/owner)\" = " + shellQuote(token) +
            "; test \"$(cat /sys/block/mmcblk0/device/cid)\" = " + shellQuote(before.identity.cid) +
            "; test \"$(cat /proc/sys/kernel/random/boot_id)\" = " + shellQuote(before.bootID) +
            "; sh " + shellQuote(stage + "/install-launcher.sh") + " " + shellQuote(stage)
        engine.update("Устанавливаю плитки дисплея", 0.85)
        let reply = try engine.remote(command, timeout: 120)
        try require(String(decoding: reply, as: UTF8.self).split(whereSeparator: \.isNewline).last == "LAUNCHER_INSTALLED", "Установщик дисплея не подтвердил завершение. Проверьте состояние.")
        let installed = try confirmInstall(assets: bundle, expected: before)
        return try applyPreferences(layout: layout, pages: pages, assets: bundle, expected: installed)
    }

    /// Writes only the small screen preference file. No service restart, firmware
    /// operation or VPN update occurs here; the running launcher reloads it.
    func applyLayout(_ layout: ModemDisplayLayout) throws -> ModemDisplayInspection {
        try layout.validate()
        try require(engine.lockFD >= 0, "Операция дисплея требует общей блокировки приложения")
        try engine.connection.validate()
        for name in ["pending.json", "setup-pending.json", "adb-access-pending.json"] {
            try require(!FileManager.default.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала завершите настройку или смену IMEI")
        }
        let bundle = try assets(), before = try inspect(assets: bundle)
        try require(before.canApplyLayout, before.layoutWarning ?? "Сначала установите или обновите плитки дисплея. " + before.detail)
        try engine.acquireRemoteLock()
        let locked = try inspect(assets: bundle)
        try require(locked.identity == before.identity && locked.bootID == before.bootID, "Перед настройкой дисплея модем изменился или перезагрузился")
        try require(locked.canApplyLayout, locked.layoutWarning ?? "Дисплей не готов к изменению настройки")
        return try applyLocked(layout, assets: bundle, expected: locked)
    }

    /// Writes only the small screen preference file. No service restart, firmware
    /// operation or VPN update occurs here; the running launcher reloads it.
    func applyPages(_ pages: ModemLauncherPages) throws -> ModemDisplayInspection {
        try pages.validate()
        try require(engine.lockFD >= 0, "Операция дисплея требует общей блокировки приложения")
        try engine.connection.validate()
        for name in ["pending.json", "setup-pending.json", "adb-access-pending.json"] {
            try require(!FileManager.default.fileExists(atPath: engine.root.appendingPathComponent(name).path), "Сначала завершите настройку или смену IMEI")
        }
        let bundle = try assets(), before = try inspect(assets: bundle)
        try require(before.canApplyPages, before.pagesWarning ?? "Сначала установите или обновите плитки дисплея. " + before.detail)
        try engine.acquireRemoteLock()
        let locked = try inspect(assets: bundle)
        try require(locked.identity == before.identity && locked.bootID == before.bootID, "Перед настройкой дисплея модем изменился или перезагрузился")
        try require(locked.canApplyPages, locked.pagesWarning ?? "Дисплей не готов к изменению настройки")
        return try applyPagesLocked(pages, assets: bundle, expected: locked)
    }

    private func layoutGuard(expected: ModemDisplayInspection, assets: Assets, fileName: String = "info-layout.conf") throws -> String {
        guard let token = engine.remoteLockToken else { throw IMEIError.message("Потеряна блокировка дисплея") }
        return "set -eu\n" +
            "test -d /tmp/zte-imei-app.lock && test ! -L /tmp/zte-imei-app.lock && test \"$(stat -c %u:%a /tmp/zte-imei-app.lock)\" = 0:700 || exit 73\n" +
            "test -f /tmp/zte-imei-app.lock/owner && test ! -L /tmp/zte-imei-app.lock/owner || exit 73\n" +
            "test \"$(cat /tmp/zte-imei-app.lock/owner)\" = " + shellQuote(token) + "\n" +
            "test \"$(cat /sys/block/mmcblk0/device/cid)\" = " + shellQuote(expected.identity.cid) + "\n" +
            "test \"$(cat /proc/sys/kernel/random/boot_id)\" = " + shellQuote(expected.bootID) + "\n" +
            "root=/data/zte-launcher; file=\"$root/" + fileName + "\"\n" +
            "test -d \"$root\" && test ! -L \"$root\" && test \"$(stat -c %u:%a \"$root\")\" = 0:700 || exit 73\n" +
            "test \"$(cat \"$root/owner\")\" = zte-native-launcher-v1 && test \"$(cat \"$root/cid\")\" = " + shellQuote(expected.identity.cid) + " || exit 73\n" +
            "test -f \"$root/launcher.so\" && test ! -L \"$root/launcher.so\" && test \"$(sha256sum \"$root/launcher.so\" | awk '{print $1}')\" = " + shellQuote(assets.hashes["launcher.so"]!) + " || exit 73\n" +
            "test -f \"$root/launcher.sha256\" && test ! -L \"$root/launcher.sha256\" && test \"$(sha256sum \"$root/launcher.sha256\" | awk '{print $1}')\" = " + shellQuote(assets.hashes["launcher.sha256"]!) + " || exit 73\n" +
            "(cd \"$root\" && sha256sum -c launcher.sha256 >/dev/null)\n" +
            "if test -e \"$file\" || test -L \"$file\"; then test -f \"$file\" && test ! -L \"$file\" && test \"$(stat -c %u:%a:%h \"$file\")\" = 0:600:1 || exit 73; fi\n"
    }

    private func applyLocked(_ layout: ModemDisplayLayout, assets: Assets, expected: ModemDisplayInspection) throws -> ModemDisplayInspection {
        let bytes = try layout.encoded()
        try require(expected.canApplyLayout, expected.layoutWarning ?? "Дисплей не готов к изменению настройки")
        if expected.layout == layout && !expected.layoutIsDefault { return expected }
        let stage = Self.root + "/.info-layout-" + UUID().uuidString.lowercased(), path = stage + "/layout"
        let guardCommand = try layoutGuard(expected: expected, assets: assets)
        let stageCommand = "# MODEM_DISPLAY_LAYOUT_STAGE\n" + guardCommand +
            "umask 077; mkdir -m 700 " + shellQuote(stage) + "\n" +
            "cat > " + shellQuote(path) + "\nchmod 600 " + shellQuote(path) + "\nsha256sum " + shellQuote(path)
        defer {
            _ = try? engine.remote("# MODEM_DISPLAY_LAYOUT_CLEANUP\n" + guardCommand +
                "test -d " + shellQuote(stage) + " && test ! -L " + shellQuote(stage) +
                " && test \"$(stat -c %u:%a " + shellQuote(stage) + ")\" = 0:700 || exit 73\n" +
                "rm -f " + shellQuote(path) + "; rmdir " + shellQuote(stage), timeout: 15)
        }
        let proof = try engine.remote(stageCommand, input: bytes, timeout: 30)
        let proofFields = String(decoding: proof, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        try require(proofFields.count == 2 && proofFields[0] == Substring(digest(bytes)) && proofFields[1] == Substring(path), "При передаче повреждена настройка дисплея; прежняя настройка сохранена")
        let checked = try inspect(assets: assets)
        try require(checked.identity == expected.identity && checked.bootID == expected.bootID, "Перед сохранением настройки дисплея модем изменился или перезагрузился")
        try require(checked.canApplyLayout, checked.layoutWarning ?? "Дисплей изменился перед сохранением настройки")
        let commit = "# MODEM_DISPLAY_LAYOUT_COMMIT\n" + guardCommand +
            "test -d " + shellQuote(stage) + " && test ! -L " + shellQuote(stage) + " && test \"$(stat -c %u:%a " + shellQuote(stage) + ")\" = 0:700 || exit 73\n" +
            "test -f " + shellQuote(path) + " && test ! -L " + shellQuote(path) + " && test \"$(stat -c %u:%a:%h " + shellQuote(path) + ")\" = 0:600:1 || exit 73\n" +
            "test \"$(stat -c %s " + shellQuote(path) + ")\" = " + String(bytes.count) + "\n" +
            "test \"$(sha256sum " + shellQuote(path) + " | awk '{print $1}')\" = " + shellQuote(digest(bytes)) + "\n" +
            "sync\nmv -f " + shellQuote(path) + " \"$file\"\nsync\nsha256sum \"$file\""
        engine.update("Сохраняю показатели и порядок на дисплее модема", 0.95)
        let reply = try engine.remote(commit, timeout: 30)
        let replyFields = String(decoding: reply, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        try require(replyFields.count == 2 && replyFields[0] == Substring(digest(bytes)) && replyFields[1] == Substring(Self.layoutPath), "Модем не подтвердил запись настройки дисплея. Повторите проверку.")
        var result = try inspect(assets: assets)
        try require(result.identity == expected.identity && result.bootID == expected.bootID, "После сохранения настройки дисплея модем изменился или перезагрузился")
        try require(result.canApplyLayout && result.layout == layout && !result.layoutIsDefault, "Проверка сохранённой настройки дисплея не пройдена")
        result.detail = "Показатели и порядок сохранены на модеме. Плитка применит настройку при открытии страницы или очередном обновлении экрана."
        return result
    }

    private func applyPreferences(layout: ModemDisplayLayout?, pages: ModemLauncherPages?, assets: Assets, expected: ModemDisplayInspection) throws -> ModemDisplayInspection {
        let afterLayout = try layout.map { try applyLocked($0, assets: assets, expected: expected) } ?? expected
        return try pages.map { try applyPagesLocked($0, assets: assets, expected: afterLayout) } ?? afterLayout
    }

    private func applyPagesLocked(_ pages: ModemLauncherPages, assets: Assets, expected: ModemDisplayInspection) throws -> ModemDisplayInspection {
        let bytes = try pages.encoded()
        try require(expected.canApplyPages, expected.pagesWarning ?? "Дисплей не готов к изменению настройки")
        if expected.pages == pages { return expected }
        let stage = Self.root + "/.page-layout-" + UUID().uuidString.lowercased(), path = stage + "/layout"
        let guardCommand = try layoutGuard(expected: expected, assets: assets, fileName: "page-layout.conf")
        let stageCommand = "# MODEM_DISPLAY_PAGES_STAGE\n" + guardCommand +
            "umask 077; mkdir -m 700 " + shellQuote(stage) + "\n" +
            "cat > " + shellQuote(path) + "\nchmod 600 " + shellQuote(path) + "\nsha256sum " + shellQuote(path)
        defer {
            _ = try? engine.remote("# MODEM_DISPLAY_PAGES_CLEANUP\n" + guardCommand +
                "test -d " + shellQuote(stage) + " && test ! -L " + shellQuote(stage) +
                " && test \"$(stat -c %u:%a " + shellQuote(stage) + ")\" = 0:700 || exit 73\n" +
                "rm -f " + shellQuote(path) + "; rmdir " + shellQuote(stage), timeout: 15)
        }
        let proof = try engine.remote(stageCommand, input: bytes, timeout: 30)
        let proofFields = String(decoding: proof, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        try require(proofFields.count == 2 && proofFields[0] == Substring(digest(bytes)) && proofFields[1] == Substring(path), "При передаче повреждена настройка дисплея; прежняя настройка сохранена")
        let checked = try inspect(assets: assets)
        try require(checked.identity == expected.identity && checked.bootID == expected.bootID, "Перед сохранением настройки дисплея модем изменился или перезагрузился")
        try require(checked.canApplyPages, checked.pagesWarning ?? "Дисплей изменился перед сохранением настройки")
        try require(checked.pages == expected.pages && checked.pagesIsDefault == expected.pagesIsDefault, "Порядок страниц изменился во время сохранения. Прочитайте его заново.")
        let previousGuard: String
        if expected.pagesIsDefault {
            previousGuard = "test ! -e \"$file\" && test ! -L \"$file\" || exit 73\n"
        } else {
            guard let oldPages = expected.pages else { throw IMEIError.message("Не удалось прочитать порядок страниц") }
            previousGuard = "test \"$(sha256sum \"$file\" | awk '{print $1}')\" = " + shellQuote(digest(try oldPages.encoded())) + " || exit 73\n"
        }
        let commit = "# MODEM_DISPLAY_PAGES_COMMIT\n" + guardCommand + previousGuard +
            "test -d " + shellQuote(stage) + " && test ! -L " + shellQuote(stage) + " && test \"$(stat -c %u:%a " + shellQuote(stage) + ")\" = 0:700 || exit 73\n" +
            "test -f " + shellQuote(path) + " && test ! -L " + shellQuote(path) + " && test \"$(stat -c %u:%a:%h " + shellQuote(path) + ")\" = 0:600:1 || exit 73\n" +
            "test \"$(stat -c %s " + shellQuote(path) + ")\" = " + String(bytes.count) + "\n" +
            "test \"$(sha256sum " + shellQuote(path) + " | awk '{print $1}')\" = " + shellQuote(digest(bytes)) + "\n" +
            "sync\nmv -f " + shellQuote(path) + " \"$file\"\nsync\nsha256sum \"$file\""
        engine.update("Сохраняю выбранные страницы и их порядок", 0.95)
        let reply = try engine.remote(commit, timeout: 30)
        let replyFields = String(decoding: reply, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        try require(replyFields.count == 2 && replyFields[0] == Substring(digest(bytes)) && replyFields[1] == Substring(Self.pagesPath), "Модем не подтвердил запись настройки дисплея. Повторите проверку.")
        var result = try inspect(assets: assets)
        try require(result.identity == expected.identity && result.bootID == expected.bootID, "После сохранения настройки дисплея модем изменился или перезагрузился")
        try require(result.canApplyPages && result.pages == pages && !result.pagesIsDefault, "Проверка сохранённой настройки дисплея не пройдена")
        result.detail = "Выбор и порядок страниц сохранены на модеме. Лаунчер применит их без перезапуска экрана."
        return result
    }

    private func confirmInstall(assets: Assets, expected: ModemDisplayInspection) throws -> ModemDisplayInspection {
        let result = try inspect(assets: assets)
        try require(result.identity == expected.identity && result.bootID == expected.bootID, "При установке дисплея модем изменился или перезагрузился")
        try require(result.state == .ready, "Дисплей после установки не подтвердил ожидаемое состояние. " + result.detail)
        return result
    }
}
