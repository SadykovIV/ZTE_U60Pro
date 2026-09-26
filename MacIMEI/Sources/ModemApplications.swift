import Foundation

struct ModemStorageVolume: Sendable, Identifiable {
    var mount: String; var totalKiB: Int64; var usedKiB: Int64; var availableKiB: Int64
    var id: String { mount }
}
struct ModemPackage: Sendable, Identifiable {
    var name: String; var version: String
    var id: String { name }
    var canRemove: Bool { false }
    var removalBlockReason: String { "Компонент прошивки. Системные пакеты не удаляются из приложения." }
}
struct ModemApplicationStorage: Sendable {
    var mount: String = "/data"
    var installRoot: String = "/data/zte-imei-apps"
    var totalKiB: Int64; var availableKiB: Int64; var managedUsedKiB: Int64
}
struct ModemManagedApplication: Sendable, Identifiable {
    var id: String; var name: String; var version: String
    var isRunning: Bool; var canRemove: Bool; var removalBlockReason: String?
}
struct ModemCatalogApplication: Sendable, Identifiable {
    var id: String; var name: String; var version: String; var summary: String
    var requiredFreeKiB: Int64; var isBundled: Bool
    var licenseSummary: String
}
struct ModemApplicationInventory: Sendable {
    var storage: [ModemStorageVolume]
    var memoryTotalKiB: Int64; var memoryAvailableKiB: Int64
    var installedPackages: [ModemPackage]
    var opkgWritable: Bool; var ssclashInstalled: Bool; var ssclashRunning: Bool
    var architecture: String; var release: String
    var applicationStorage: ModemApplicationStorage? = nil
    var ssclashProxyRunning: Bool = false
    var ssclashUnmanaged: Bool = false
    var managedAppsChecked = false
    var diagnosticTools: DiagnosticToolsStatus? = nil
    var experimentalOpkg: ExperimentalOpkgStatus? = nil
    var managedAppErrors: [String: String] = [:]
    var opkgInstallationSupported: Bool { false }
    var installedApplications: [ModemManagedApplication] {
        guard ssclashInstalled || ssclashUnmanaged else { return [] }
        let reason = ssclashUnmanaged ? "Установка создана или изменена вне приложения. Автоматическое удаление недоступно." : ssclashProxyRunning ? "Сначала остановите прокси в веб-панели SSClash." : nil
        return [ModemManagedApplication(id: "ssclash", name: "SSClash-Go", version: ssclashInstalled ? ModemApplications.ssclashVersion : "Не проверена", isRunning: ssclashRunning, canRemove: reason == nil, removalBlockReason: reason)]
    }
}

/// Caller owns ModemEngine.locked, firmware identity validation and the remote lock.
/// This class never changes IMEI, remounts system partitions or edits stock feeds.
final class ModemApplications {
    static let ssclashVersion = "v6.4.1"
    static let ssclashHash = "38ba859187c953d159cdd4f1ff397feb5f29116e0bfc7dc284c45b1a6766c770"
    static let ssclashURL = URL(string: "https://github.com/zerolabnet/SSClash-Go/releases/download/v6.4.1/ssclash-linux-arm64")!
    static let remoteRoot = "/data/zte-imei-apps/ssclash"
    static let servicePath = "/etc/init.d/zte_imei_ssclash"
    static let serviceTemplateHash = "7c8586a6a743b180b118bad214e9ca48f6bff8231ca6676d719f7a181198f7b8"
    static let removalScriptHash = "7497bace3fea997bd9b079efe8bb8caa722a53a197784b2bc88d96786be2e5bc"
    static let catalog = [ModemCatalogApplication(id: "ssclash", name: "SSClash-Go", version: ssclashVersion, summary: "Веб-панель управления прокси. Ядро Mihomo и профиль подключения настраиваются отдельно.", requiredFreeKiB: 64 * 1024, isBundled: false, licenseSummary: "Проприетарная лицензия SSClash: использование на собственных устройствах. Загрузка по кнопке из официального релиза; бинарник в программу не включён.")]
    let engine: ModemEngine
    let assetLoader: (URL) throws -> Data
    init(engine: ModemEngine, assetLoader: ((URL) throws -> Data)? = nil) {
        self.engine = engine
        self.assetLoader = assetLoader ?? Self.downloadOfficialAsset
    }
    /// Downloads only the pinned official asset when the owner chooses Install.
    static func downloadOfficialAsset(_ url: URL) throws -> Data {
        try require(url == ssclashURL, "Неизвестный источник SSClash")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let gate = DispatchSemaphore(value: 0)
        final class ResultBox: @unchecked Sendable { var result: Result<Data, Error>? }
        let box = ResultBox()
        let task = session.downloadTask(with: url) { file, response, error in
            defer { gate.signal() }
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.url?.scheme == "https", let file else {
                    throw IMEIError.message("Не удалось загрузить официальный SSClash")
                }
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                try require(size == 11_010_232, "Размер загруженного SSClash не совпал")
                let bytes = try Data(contentsOf: file)
                try validateAsset(bytes)
                box.result = .success(bytes)
            } catch { box.result = .failure(error) }
        }
        task.resume()
        guard gate.wait(timeout: .now() + 185) == .success else {
            task.cancel(); throw IMEIError.message("Истекло время загрузки SSClash")
        }
        guard let result = box.result else { throw IMEIError.message("Нет результата загрузки SSClash") }
        return try result.get()
    }
    static func validateSSClashPassword(password: String) throws {
        try require((8...128).contains(password.utf8.count) && password == password.trimmingCharacters(in: .whitespacesAndNewlines) && !password.contains("\n") && !password.contains("\r") && !password.contains("\0"), "Пароль SSClash: от 8 до 128 байт, без переносов строк и пробелов по краям")
    }
    static func validatePackageName(_ name: String) throws {
        let bytes = Array(name.utf8)
        try require((1...100).contains(bytes.count) && bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [43, 46, 95, 45].contains($0) } && ((97...122).contains(bytes[0]) || (48...57).contains(bytes[0])), "Некорректное имя пакета opkg")
        try require(!name.hasPrefix("kmod-") && !["kernel", "libc", "libgcc", "libgcc1", "busybox", "opkg", "base-files", "procd", "ubus", "netifd", "firewall", "firewall4"].contains(name), "Системные пакеты и модули ядра через это меню не устанавливаются")
    }
    static func validateAsset(_ data: Data) throws {
        try require(data.count == 11_010_232 && digest(data) == ssclashHash, "SHA-256 SSClash не совпадает с проверенным релизом v6.4.1")
        try require(Array(data.prefix(6)) == [0x7f, 0x45, 0x4c, 0x46, 2, 1] && data[18] == 183 && data[19] == 0, "SSClash должен быть Linux ELF64 ARM64")
    }
    static let inventoryCommand = #"""
    set -eu
    printf '__ZTE_RELEASE__\n'
    cat /etc/openwrt_release
    printf '__ZTE_STORAGE__\n'
    df -Pk / /data /overlay /etc
    printf '__ZTE_MEMORY__\n'
    cat /proc/meminfo
    printf '__ZTE_MOUNTS__\n'
    cat /proc/mounts
    printf '__ZTE_PACKAGES__\n'
    cat /usr/lib/opkg/status
    printf '__ZTE_APPLICATION_STORAGE__\n'
    if test -e /data/zte-imei-apps || test -L /data/zte-imei-apps; then
        test -d /data/zte-imei-apps && test ! -L /data/zte-imei-apps || exit 1
        test "$(stat -c '%u' /data/zte-imei-apps)" = 0 || exit 1
        test "$(cat /data/zte-imei-apps/.zte-imei-owner 2>/dev/null)" = zte-imei-apps-v1 || exit 1
        du -sk /data/zte-imei-apps | awk '{print "managedUsedKiB=" $1}'
    else echo managedUsedKiB=0; fi
    printf '__ZTE_FLAGS__\n'
    if test -w /usr/lib/opkg/status && test -w /usr/bin && test -w /lib && test -w /bin && test -w /sbin; then echo opkgWritable=1; else echo opkgWritable=0; fi
    if test ! -L /data/zte-imei-apps/ssclash && test -x /data/zte-imei-apps/ssclash/bin/ssclash && test "$(cat /data/zte-imei-apps/ssclash/.zte-imei-owner 2>/dev/null)" = zte-imei-ssclash-v1; then echo ssclashInstalled=1; else echo ssclashInstalled=0; fi
    if test -e /data/zte-imei-apps/ssclash || test -L /data/zte-imei-apps/ssclash; then echo ssclashPresent=1; else echo ssclashPresent=0; fi
    proxy=0
    for proc in /proc/[0-9]*/exe; do
        executable=$(readlink "$proc" 2>/dev/null || true)
        case "$executable" in /data/zte-imei-apps/ssclash/bin/clash|/data/zte-imei-apps/ssclash/bin/clash\ \(deleted\)|/data/zte-imei-apps/ssclash/bin/mihomo|/data/zte-imei-apps/ssclash/bin/mihomo\ \(deleted\)) proxy=1;; esac
    done
    echo ssclashProxyRunning=$proxy
    running=0
    for pid in $(pidof ssclash 2>/dev/null || true); do
        test "$(readlink /proc/$pid/exe 2>/dev/null)" = /data/zte-imei-apps/ssclash/bin/ssclash || continue
        address=$(tr '\000' '\n' < /proc/$pid/environ | sed -n 's/^SSCLASH_ADDR=//p')
        case "$address" in 0.0.0.0:*|127.*|:*) continue;; esac
        printf '%s\n' "$address" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:9091$' || continue
        if netstat -ltnp 2>/dev/null | awk -v address="$address" -v owner="$pid/" '$4 == address && index($7, owner) == 1 {found=1} END {exit !found}'; then running=1; fi
    done
    echo ssclashRunning=$running
    """#
    func inventory() throws -> ModemApplicationInventory { try Self.parseInventory(engine.text(Self.inventoryCommand)) }
    static func parseInventory(_ output: String) throws -> ModemApplicationInventory {
        var parts = [String: [String]](), section = ""
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("__ZTE_") && line.hasSuffix("__") { section = line; parts[section] = [] }
            else { parts[section, default: []].append(line) }
        }
        for name in ["RELEASE", "STORAGE", "MEMORY", "MOUNTS", "PACKAGES", "FLAGS", "APPLICATION_STORAGE"] { try require(parts["__ZTE_" + name + "__"] != nil, "Неполная инвентаризация приложений: \(name)") }
        let release = parts["__ZTE_RELEASE__"]!.joined(separator: "\n")
        func field(_ key: String) -> String {
            let line = release.components(separatedBy: "\n").first { $0.hasPrefix(key + "=") } ?? ""
            return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        var volumes = [ModemStorageVolume]()
        for line in parts["__ZTE_STORAGE__"]! {
            let f = line.split(whereSeparator: \.isWhitespace)
            if f.count == 6, let total = Int64(f[1]), let used = Int64(f[2]), let available = Int64(f[3]), total >= 0, used >= 0, available >= 0 {
                volumes.append(ModemStorageVolume(mount: String(f[5]), totalKiB: total, usedKiB: used, availableKiB: available))
            }
        }
        try require(Set(volumes.map(\.mount)) == Set(["/", "/data", "/overlay", "/etc"]) && volumes.count == 4, "Не получены размеры файловых систем /, /data, /overlay и /etc")
        var memory = [String: Int64]()
        for line in parts["__ZTE_MEMORY__"]! {
            let f = line.split(whereSeparator: \.isWhitespace)
            if f.count >= 2, let v = Int64(f[1]), v >= 0 { memory[String(f[0].dropLast())] = v }
        }
        guard let total = memory["MemTotal"], let available = memory["MemAvailable"], total > 0, available <= total else { throw IMEIError.message("Не удалось отдельно прочитать оперативную память") }
        var packages = [ModemPackage]()
        for stanza in parts["__ZTE_PACKAGES__"]!.joined(separator: "\n").components(separatedBy: "\n\n") {
            var p = [String: String]()
            for line in stanza.components(separatedBy: "\n") {
                if let colon = line.firstIndex(of: ":") { p[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            }
            if let name = p["Package"], let version = p["Version"], p["Status"]?.split(separator: " ").last == "installed" { packages.append(ModemPackage(name: name, version: version)) }
        }
        let flags = Set(parts["__ZTE_FLAGS__"]!)
        let mounts: [(String, Set<String>)] = parts["__ZTE_MOUNTS__"]!.compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= 4 else { return nil }
            return (String(fields[1]), Set(fields[3].split(separator: ",").map(String.init)))
        }
        func filesystemWritable(_ path: String) -> Bool {
            guard let mount = mounts.filter({ $0.0 == "/" || path == $0.0 || path.hasPrefix($0.0 + "/") }).max(by: { $0.0.count < $1.0.count }) else { return false }
            return mount.1.contains("rw") && !mount.1.contains("ro")
        }
        // BusyBox test -w can return true for root even on a read-only mount.
        let actualWritable = ["/usr/lib/opkg/status", "/usr/bin", "/lib", "/bin", "/sbin"].allSatisfy(filesystemWritable)
        let measured = parts["__ZTE_APPLICATION_STORAGE__"]!.filter { !$0.isEmpty }
        guard measured.count == 1, measured[0].hasPrefix("managedUsedKiB="), let managed = Int64(measured[0].dropFirst("managedUsedKiB=".count)), managed >= 0, let dataVolume = volumes.first(where: { $0.mount == "/data" }), dataVolume.totalKiB > 0, dataVolume.availableKiB <= dataVolume.totalKiB, managed <= dataVolume.totalKiB else { throw IMEIError.message("Не удалось измерить место установки приложений на /data") }
        let installed = flags.contains("ssclashInstalled=1")
        return ModemApplicationInventory(storage: volumes, memoryTotalKiB: total, memoryAvailableKiB: available, installedPackages: packages.sorted { $0.name < $1.name }, opkgWritable: flags.contains("opkgWritable=1") && actualWritable, ssclashInstalled: installed, ssclashRunning: flags.contains("ssclashRunning=1"), architecture: field("DISTRIB_ARCH"), release: field("DISTRIB_RELEASE"), applicationStorage: ModemApplicationStorage(totalKiB: dataVolume.totalKiB, availableKiB: dataVolume.availableKiB, managedUsedKiB: managed), ssclashProxyRunning: flags.contains("ssclashProxyRunning=1"), ssclashUnmanaged: !installed && flags.contains("ssclashPresent=1"))
    }
    /// Existing cached indices only; never refreshes or modifies feed configuration.
    func previewPackage(_ name: String) throws -> String {
        try Self.validatePackageName(name)
        let state = try inventory()
        let result = try engine.transport.run("opkg --noaction install " + shellQuote(name), input: nil, timeout: 60)
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        return output + (state.opkgWritable ? "" : "\nУстановка заблокирована: системные каталоги B31 доступны только для чтения. Раздел /data не заменяет пути установки opkg.")
    }
    func installPackage(_ name: String) throws -> String {
        try Self.validatePackageName(name); let state = try inventory()
        try require(state.release == "23.05.4" && state.architecture == "aarch64_cortex-a53", "Неизвестный профиль пакетов прошивки")
        try require(state.opkgWritable, "Установка opkg остановлена: /usr, /lib, /bin или база пакетов доступны только для чтения. Используйте адаптированные приложения на /data.")
        // A writable device alone is insufficient. No signed feed deployment has yet
        // been implemented; do not accidentally trust modified stock/third-party feeds.
        throw IMEIError.message("Прямая установка opkg пока недоступна: требуется проверенный подписанный профиль источников и зависимостей для этой прошивки. Предпросмотр и список установленных пакетов доступны.")
    }

    private func serviceData() throws -> Data {
        let bytes = try Data(contentsOf: engine.resources.appendingPathComponent("Applications/ssclash-service.sh"))
        try require(digest(bytes) == Self.serviceTemplateHash, "Повреждён встроенный шаблон службы SSClash")
        return Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "__ZTE_LAN_IPV4__", with: engine.connection.host).utf8)
    }

    func startSSClash() throws -> String {
        try engine.connection.validate()
        let expectedService = try serviceData()
        let directories = "for dir in /data /data/zte-imei-apps " + Self.remoteRoot + " " + Self.remoteRoot + "/bin " + Self.remoteRoot + "/.ssclash /etc/init.d; do test -d \"$dir\"; test ! -L \"$dir\"; test \"$(stat -c '%u' \"$dir\")\" = 0; mode=$(stat -c '%a' \"$dir\"); test \"$((0$mode & 022))\" = 0; done; "
        let lanCheck = "ip -o -4 addr show | awk -v address=" + shellQuote(engine.connection.host) + " '{split($4, a, \"/\"); if(a[1] == address) found=1} END {exit !found}'; "
        let guards = "set -eu; " + directories + lanCheck + "test ! -L " + Self.remoteRoot + "; test \"$(cat " + Self.remoteRoot + "/.zte-imei-owner)\" = zte-imei-ssclash-v1; test ! -L " + Self.servicePath + "; test ! -L " + Self.remoteRoot + "/bin/ssclash; test -s " + Self.remoteRoot + "/.ssclash/password; test ! -L " + Self.remoteRoot + "/.ssclash/password; grep -q '^pbkdf2[$]' " + Self.remoteRoot + "/.ssclash/password; sha256sum " + Self.remoteRoot + "/bin/ssclash " + Self.servicePath
        let hashes = try engine.text(guards).components(separatedBy: "\n").map { String($0.split(separator: " ").first ?? "") }
        try require(hashes == [Self.ssclashHash, digest(expectedService)], "SSClash или его служба изменены. Автоматический запуск остановлен")
        do {
            _ = try engine.remote(Self.servicePath + " start")
            let address = "http://" + engine.connection.host + ":9091"
            var ready = false
            for _ in 0..<10 {
                if let result = try? curl(address + "/login"), result.status == 200, result.body.contains("action=\"/login\"") { ready = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            try require(ready, "Страница входа SSClash не запустилась")
            let anonymous = try curl(address + "/api/status")
            try require([302, 303, 401, 403].contains(anonymous.status), "SSClash API не требует авторизации")
            return "SSClash запущен: " + address + ". Сохранённые настройки приложения используются без изменения."
        } catch {
            _ = try? engine.remote(Self.servicePath + " stop", timeout: 30)
            throw error
        }
    }

    func installSSClash(password: String) throws -> String {
        try Self.validateSSClashPassword(password: password)
        try engine.connection.validate()
        let originalIdentity = try engine.identity().0
        let state = try inventory()
        try require(state.release == "23.05.4" && state.architecture == "aarch64_cortex-a53", "Установщик SSClash проверен только для B31 / aarch64_cortex-a53")
        try require(!state.ssclashInstalled && !state.ssclashRunning, "SSClash уже установлен или запущен. Существующая установка не перезаписывается")
        try require((state.storage.first { $0.mount == "/data" }?.availableKiB ?? 0) >= 64 * 1024, "На /data требуется не менее 64 MiB свободного места")
        engine.update("Загружаю SSClash-Go v6.4.1 из официального релиза…", 0.1)
        let binary = try assetLoader(Self.ssclashURL); try Self.validateAsset(binary)
        try require(try engine.identity().0 == originalIdentity, "После проверки SSClash подключён другой модем")
        let service = try serviceData()
        let token = UUID().uuidString.lowercased(), base = "/data/zte-imei-apps", stage = "/data/zte-imei-apps/.ssclash-" + token
        let journal = engine.logDirectory.appendingPathComponent("ssclash-install.json")
        func record(_ phase: String) throws { try saveJSON(["phase": phase, "version": Self.ssclashVersion, "sha256": Self.ssclashHash, "host": engine.connection.host, "stage": stage], journal) }
        try record("download-verified")
        let safeDirectory = "safe_dir() { test -d \"$1\" && test ! -L \"$1\" && test \"$(stat -c '%u' \"$1\")\" = 0 && mode=$(stat -c '%a' \"$1\") && test \"$((0$mode & 022))\" = 0; }; "
        let lanCheck = "ip -o -4 addr show | awk -v address=" + shellQuote(engine.connection.host) + " '{split($4, a, \"/\"); if(a[1] == address) found=1} END {exit !found}'; "
        let preflight = "set -eu; " + safeDirectory + "safe_dir /data; safe_dir /etc/init.d; " + lanCheck + "test -w /data; test -w /etc/init.d; test ! -e " + Self.remoteRoot + "; test ! -L " + Self.remoteRoot + "; test ! -e " + Self.servicePath + "; test ! -L " + Self.servicePath + "; command -v curl >/dev/null; command -v procd >/dev/null; command -v netstat >/dev/null; test -f /etc/rc.common; if pidof clash >/dev/null 2>&1; then echo 'Уже работает ядро Clash/Mihomo' >&2; exit 1; fi; if netstat -ltn | awk 'NR>2 && $4 ~ /:9091$/ {found=1} END {exit !found}'; then echo 'Порт 9091 уже занят' >&2; exit 1; fi; if test -e " + base + " || test -L " + base + "; then safe_dir " + base + "; test \"$(cat " + base + "/.zte-imei-owner)\" = zte-imei-apps-v1; else umask 077; mkdir " + base + "; printf '%s' zte-imei-apps-v1 > " + base + "/.zte-imei-owner; fi; umask 077; mkdir " + stage + "; mkdir " + stage + "/bin; printf '%s' zte-imei-ssclash-v1 > " + stage + "/.zte-imei-owner"
        _ = try engine.remote(preflight)
        var promoted = false, serviceCreated = false
        do {
            let received = try engine.remote("set -eu; umask 077; set -C; cat > " + stage + "/bin/ssclash; chmod 700 " + stage + "/bin/ssclash; sha256sum " + stage + "/bin/ssclash", input: binary, timeout: 120)
            try require(String(decoding: received, as: UTF8.self).split(separator: " ").first == Substring(Self.ssclashHash), "Переданный SSClash повреждён")
            let version = try engine.text(stage + "/bin/ssclash version")
            try require(version.contains("6.4.1"), "Версия установленного SSClash не совпала")
            engine.update("Создаю пароль web-панели до её первого запуска…", 0.5)
            // runSetpass in the pinned binary reads one stdin line when no argv password
            // is given. Password never enters command arguments, logs or environment.
            _ = try engine.remote("SSCLASH_ROOT=" + stage + " SSCLASH_PLATFORM=openwrt " + stage + "/bin/ssclash setpass", input: Data((password + "\n").utf8))
            _ = try engine.remote("set -eu; test -s " + stage + "/.ssclash/password; grep -q '^pbkdf2[$]' " + stage + "/.ssclash/password; test ! -e " + stage + "/bin/clash; test ! -e " + Self.remoteRoot + "; mv " + stage + " " + Self.remoteRoot)
            promoted = true; try record("password-provisioned")
            let tempService = "/etc/init.d/.zte-imei-ssclash-" + token
            _ = try engine.remote("set -eu; umask 077; set -C; cat > " + tempService + "; chmod 700 " + tempService + "; ln " + tempService + " " + Self.servicePath + "; rm " + tempService, input: service)
            serviceCreated = true; try record("service-created")
            // No enable, firewall change, Mihomo binary or proxy profile is installed.
            _ = try engine.remote(Self.servicePath + " start")
            engine.update("Проверяю вход в SSClash и выключенное состояние прокси…", 0.8)
            try verifySSClash(password: password)
            try record("authenticated-ui-verified-proxy-stopped")
            engine.update("SSClash установлен. Пароль проверен, прокси пока выключен.", 1)
            return "SSClash-Go 6.4.1 установлен. Web-панель: http://" + engine.connection.host + ":9091. Вход проверен; ядро Mihomo и proxy-профиль настраиваются в панели. Автозапуск не включён."
        } catch {
            if serviceCreated { _ = try? engine.remote(Self.servicePath + " stop", timeout: 30) }
            try? record(promoted ? (serviceCreated ? "needs-inspection-stop-requested" : "needs-inspection-service-not-started") : "staging-incomplete")
            throw IMEIError.message("Установка SSClash остановлена: " + error.localizedDescription + ". Файлы и журнал сохранены для проверки; повторная установка не перезаписывает их.")
        }
    }

    /// The existing daemon is stopped through its hash-checked procd service, never
    /// by process name or an untrusted PID file. A running proxy must first be stopped
    /// in SSClash so its own routes/firewall can be restored by its normal workflow.
    func removeSSClash() throws -> String {
        try engine.connection.validate()
        let identity = try engine.identity().0
        let state = try inventory()
        try require(state.ssclashInstalled && !state.ssclashUnmanaged, "Не найдена установка SSClash, созданная этим приложением")
        try require(!state.ssclashProxyRunning, "Сначала остановите прокси в веб-панели SSClash")
        let script = try Data(contentsOf: engine.resources.appendingPathComponent("Applications/ssclash-remove.sh"))
        try require(digest(script) == Self.removalScriptHash, "Повреждён встроенный сценарий удаления SSClash")
        let serviceHash = digest(try serviceData())
        let token = UUID().uuidString.lowercased()
        let recovery = "/data/zte-imei-apps/.removals/" + token
        let archive = engine.logDirectory.appendingPathComponent("ssclash-recovery-" + token + ".tar.gz")
        let journal = engine.logDirectory.appendingPathComponent("ssclash-remove-" + token + ".json")
        var verifiedArchiveHash = ""
        func record(_ phase: String, hash: String = "") throws {
            try saveJSON(["phase": phase, "application": "ssclash", "version": Self.ssclashVersion, "archive": archive.path, "archive_sha256": hash, "remote_recovery": recovery], journal)
        }
        func command(_ action: String, archiveHash: String? = nil) -> String {
            let args = [action, token, Self.ssclashHash, serviceHash] + (archiveHash.map { [$0] } ?? [])
            return "sh -s -- " + args.map(shellQuote).joined(separator: " ")
        }
        try record("preparing")
        do {
            engine.update("Проверяю SSClash и сохраняю резервную копию…", 0.15)
            let prepared = String(decoding: try engine.remote(command("prepare"), input: script, timeout: 180), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = prepared.split(separator: " ").map(String.init)
            try require(fields.count == 3 && fields[0] == "SSCLASH_ARCHIVE" && fields[1].hasPrefix("sha256=") && fields[2].hasPrefix("bytes="), "Не получены сведения о резервной копии SSClash")
            let archiveHash = String(fields[1].dropFirst(7))
            let byteCount = Int(fields[2].dropFirst(6)) ?? 0
            try require(archiveHash.count == 64 && archiveHash.allSatisfy { $0.isHexDigit && !$0.isUppercase } && byteCount > 0 && byteCount <= 256 * 1024 * 1024, "Недопустимый размер или SHA-256 резервной копии SSClash (предел — 256 МиБ)")
            let remoteArchive = recovery + "/archive.tar.gz"
            let readArchive = "set -eu; test -f " + shellQuote(remoteArchive) + "; test ! -L " + shellQuote(remoteArchive) + "; test \"$(stat -c '%s' " + shellQuote(remoteArchive) + ")\" = " + shellQuote(String(byteCount)) + "; cat " + shellQuote(remoteArchive)
            let bytes = try engine.remote(readArchive, timeout: 180)
            try require(bytes.count == byteCount && digest(bytes) == archiveHash, "Резервная копия SSClash повреждена при передаче; файлы приложения не удалены")
            try savePrivate(bytes, archive)
            verifiedArchiveHash = archiveHash
            try record("archive-verified-on-mac", hash: archiveHash)
            try require(try engine.identity().0 == identity, "Перед удалением подключён другой модем")
            engine.update("Удаляю SSClash. Настройки сохранены в резервной копии…", 0.75)
            let result = String(decoding: try engine.remote(command("commit", archiveHash: archiveHash), input: script, timeout: 120), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try require(result == "SSCLASH_REMOVED archive=" + remoteArchive, "Удаление SSClash не подтверждено; проверьте состояние приложения")
            try record("removed", hash: archiveHash)
            engine.update("SSClash удалён, резервная копия сохранена.", 1)
            return "SSClash удалён. Резервная копия настроек и приложения: " + archive.path + ". Её копия на модеме: " + remoteArchive + ". Архив на модеме учитывается в занятом месте приложений."
        } catch {
            try? record("needs-inspection", hash: verifiedArchiveHash)
            throw IMEIError.message("Удаление SSClash остановлено: " + error.localizedDescription + ". Данные для восстановления сохранены в " + recovery + "; журнал: " + journal.path)
        }
    }

    private func verifySSClash(password: String) throws {
        let address = "http://" + engine.connection.host + ":9091"
        // curl runs on the modem, so the password does not traverse the LAN in HTTP.
        var login: HTTPApplicationReply?
        for _ in 0..<10 {
            if let result = try? curl(address + "/login"), result.status == 200 { login = result; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let login else { throw IMEIError.message("Web-панель SSClash не запустилась") }
        try require(login.body.contains("action=\"/login\"") && !login.body.contains("action=\"/setup\""), "SSClash не требует заранее заданный пароль")
        guard let range = login.body.range(of: "name=\"csrf\" value=\""), let end = login.body[range.upperBound...].firstIndex(of: "\"") else { throw IMEIError.message("Не получен CSRF входа SSClash") }
        let csrf = String(login.body[range.upperBound..<end])
        let body = "csrf=" + Self.formEscape(csrf) + "&password=" + Self.formEscape(password)
        let signedIn = try curl(address + "/login", cookie: login.cookie, body: body)
        try require([302, 303].contains(signedIn.status) && !signedIn.cookie.isEmpty, "SSClash не подтвердил вход с заданным паролем")
        let status = try curl(address + "/api/status", cookie: signedIn.cookie)
        let object = try JSONSerialization.jsonObject(with: Data(status.body.utf8)) as? [String: Any]
        try require(status.status == 200 && (object?["running"] as? Bool) == false, "Не подтверждено выключенное состояние прокси SSClash")
        let anonymous = try curl(address + "/api/status")
        try require([302, 303, 401, 403].contains(anonymous.status), "SSClash API доступен без авторизации; требуется остановка панели")
    }
    static func formEscape(_ value: String) -> String {
        value.utf8.map { b in ((65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || [45,46,95,126].contains(b)) ? String(UnicodeScalar(b)) : String(format: "%%%02X", b) }.joined()
    }
    struct HTTPApplicationReply {
        var status: Int; var cookie: String; var body: String
        init(_ raw: String) throws {
            guard let end = raw.range(of: "\r\n\r\n") else { throw IMEIError.message("Неполный HTTP-ответ SSClash") }
            let headers = raw[..<end.lowerBound].components(separatedBy: "\r\n")
            guard let first = headers.first, let value = Int(first.split(separator: " ").dropFirst().first ?? "") else { throw IMEIError.message("Некорректный HTTP-статус SSClash") }
            status = value; body = String(raw[end.upperBound...])
            cookie = headers.filter { $0.lowercased().hasPrefix("set-cookie:") }.map { String($0.dropFirst(11)).trimmingCharacters(in: .whitespaces).components(separatedBy: ";")[0] }.joined(separator: "; ")
            try require(!cookie.contains("\n") && !cookie.contains("\r"), "Некорректный cookie SSClash")
        }
    }
    private func curl(_ url: String, cookie: String = "", body: String? = nil) throws -> HTTPApplicationReply {
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var config = "url = " + quote(url) + "\ninclude\nsilent\nshow-error\nmax-time = 10\nconnect-timeout = 3\nnoproxy = \"*\"\n"
        if !cookie.isEmpty { config += "header = " + quote("Cookie: " + cookie) + "\n" }
        if let body { config += "header = \"Content-Type: application/x-www-form-urlencoded\"\ndata = " + quote(body) + "\n" }
        return try HTTPApplicationReply(String(decoding: engine.remote("curl --config -", input: Data(config.utf8), timeout: 15), as: UTF8.self))
    }
}
