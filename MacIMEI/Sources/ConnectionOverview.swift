import Foundation

enum ConnectionOverviewSection: String, CaseIterable, Sendable {
    case information, display, vpn, ttl, screen, access, agent, applications
    var title: String {
        switch self {
        case .information: return "Информация о модеме"
        case .display: return "Лаунчер"
        case .vpn: return "VPN"
        case .ttl: return "TTL"
        case .screen: return "Русификация"
        case .access: return "Доступы и SSH-пользователи"
        case .agent: return "Агент"
        case .applications: return "Приложения"
        }
    }
}

/// Each optional value has either been read from the current modem or has a
/// section error. A failed optional component is not a failed connection.
struct ConnectionOverviewSnapshot: Sendable {
    var summary: ConnectionDeviceSummary
    var limitedToADB: Bool
    // Nil values clear only the explicitly requested sections. A scoped
    // refresh must never erase or replace another page's data or editor draft.
    var sections: Set<ConnectionOverviewSection> = Set(ConnectionOverviewSection.allCases)
    var information: ModemInformation?
    var display: ModemDisplayInspection?
    var vpn: VPNInspection?
    var ttl: TTLStatus?
    var screen: ScreenLocalizationStatus?
    var access: AccessManagementState?
    var agent: AgentInstallationStatus?
    var applications: ModemApplicationInventory?
    var errors: [ConnectionOverviewSection: String] = [:]
}

/// Explicit readers keep connect separate from actions which install, repair,
/// or enable a component. Also provide a seam for failure-isolation tests.
struct ConnectionOverviewReaders {
    var information: () throws -> ModemInformation
    var display: (() throws -> ModemDisplayInspection)?
    var vpn: (() throws -> VPNInspection)?
    var ttl: (() throws -> TTLStatus)?
    var screen: (() throws -> ScreenLocalizationStatus)?
    var access: (() throws -> AccessManagementState)?
    var agent: (() throws -> AgentInstallationStatus)?
    var applications: (() throws -> ModemApplicationInventory)?
}

enum ConnectionOverview {
    /// Caller holds the application's local operation lock. No installation or
    /// NV/EFS helpers are invoked. Ordinary application reads require SSH.
    static func collect(engine: ModemEngine, session: ReadOnlyChannelSession,
                        sections: Set<ConnectionOverviewSection> = Set(ConnectionOverviewSection.allCases),
                        update: @escaping (ConnectionOverviewSection) -> Void = { _ in }) throws -> ConnectionOverviewSnapshot {
        try require(engine.lockFD >= 0, "Обновление разделов требует блокировки приложения")
        guard session.mode == .ssh, let shell = session.diagnosticSession, shell.transport == "ssh" else {
            throw IMEIError.message("Для подключения к модему требуется SSH")
        }
        let sections = session.summary.fields["accessProfile"] == "linux-arm64-access" ? sections.intersection([.information]) : sections
        let readers = ConnectionOverviewReaders(
            information: {
                let result = try shell.run(ModemInformationManager.command, timeout: 30)
                try require(result.status == 0, "Не удалось прочитать сведения: " + ActivityJournal.redact(String(decoding: result.stderr.prefix(2048), as: UTF8.self)))
                return try ModemInformationManager.parse(String(decoding: result.stdout, as: UTF8.self), identity: shell.proof.identity, boot: shell.proof.bootID)
            },
            display: { try ModemDisplayManager(engine: engine).inspect() },
            vpn: { try VPNSettingsManager(engine: engine).inspect() },
            ttl: { try readTTL(engine: engine, cid: shell.proof.identity.cid) },
            screen: { try ScreenLocalization(engine: engine).perform(.status) },
            access: { try readAccess(engine: engine, cid: shell.proof.identity.cid) },
            agent: { try readAgent(engine: engine) },
            applications: { try ModemApplications(engine: engine).inventoryWithManagedApps() }
        )
        return try collect(session: session, readers: readers, sections: sections, update: update) {
            // The session verifies its original transport. Separately bind the
            // manager's engine to that same device and boot before using SSH.
            if session.mode == .ssh {
                let current = try engine.accessIdentity()
                try require(current.0 == shell.proof.identity && current.1 == shell.proof.bootID,
                            "Устройство, прошивка или сеанс загрузки SSH изменились; обновление разделов остановлено")
            }
        }
    }

    static func collect(session: ReadOnlyChannelSession, readers: ConnectionOverviewReaders,
                        sections: Set<ConnectionOverviewSection> = Set(ConnectionOverviewSection.allCases),
                        update: @escaping (ConnectionOverviewSection) -> Void = { _ in },
                        verifyEngine: () throws -> Void = {}) throws -> ConnectionOverviewSnapshot {
        guard session.mode == .ssh, let shell = session.diagnosticSession, shell.transport == "ssh" else {
            throw IMEIError.message("Для подключения к модему требуется SSH")
        }
        let summary = try session.readSummary()
        try require(summary.identity == shell.proof.identity && summary.bootID == shell.proof.bootID,
                    "Сведения подключения не совпадают с проверенным сеансом модема")
        var snapshot = ConnectionOverviewSnapshot(summary: summary, limitedToADB: false, sections: sections)
        func verify() throws { try shell.verify(); try verifyEngine() }
        func read<T>(_ section: ConnectionOverviewSection, _ reader: (() throws -> T)?) throws -> T? {
            guard sections.contains(section) else { return nil }
            try verify()
            let outcome: Result<T, Error>
            if let reader { update(section); outcome = Result { try reader() } }
            else { outcome = .failure(IMEIError.message("Проверка раздела недоступна")) }
            // Identity/boot failure must escape instead of being mistaken for
            // an unsupported module. Discard the whole mixed-device snapshot.
            try verify()
            switch outcome {
            case .success(let value): return value
            case .failure(let error):
                snapshot.errors[section] = String(ActivityJournal.redact(error.localizedDescription).prefix(1500))
                return nil
            }
        }
        snapshot.information = try read(.information, readers.information)
        if session.mode == .ssh {
            snapshot.display = try read(.display, readers.display)
            snapshot.vpn = try read(.vpn, readers.vpn)
            snapshot.ttl = try read(.ttl, readers.ttl)
            snapshot.screen = try read(.screen, readers.screen)
            snapshot.access = try read(.access, readers.access)
            snapshot.agent = try read(.agent, readers.agent)
            snapshot.applications = try read(.applications, readers.applications)
        }
        // Recheck the complete public identity, including IMEI, before handing
        // the overview to the UI. No partial overview is accepted after drift.
        snapshot.summary = try session.readSummary()
        try verify()
        return snapshot
    }

    private static func script(_ engine: ModemEngine, relativePath: String, hash: String) throws -> Data {
        let data = try Data(contentsOf: engine.resources.appendingPathComponent(relativePath))
        try require(digest(data) == hash, "Повреждён компонент проверки: " + relativePath)
        return data
    }
    static func readAgent(engine: ModemEngine) throws -> AgentInstallationStatus {
        let data = try script(engine, relativePath: "AgentInstallation/manager.sh", hash: AgentInstallationManager.scriptHash)
        // inspect() stages an installer and takes the general remote lock;
        // its audited status branch needs neither. Never inherit its test root.
        let raw = try engine.remote("unset ZTE_AGENT_TEST_ROOT; sh -s -- status", input: data, timeout: 30)
        return try AgentInstallationStatus.parse(String(decoding: raw, as: UTF8.self))
    }
    static func readTTL(engine: ModemEngine, cid: String) throws -> TTLStatus {
        guard let hash = TTLSettingsManager.resourceHashes["manager.sh"] else { throw IMEIError.message("Неполный комплект проверки TTL") }
        let data = try script(engine, relativePath: "TTL/manager.sh", hash: hash)
        // The status branch uses its own short-lived TTL lock/scratch files to
        // compare current rules. It changes no rules, settings, or boot hooks.
        let raw = try engine.remote("sh -s -- status " + shellQuote(cid), input: data, timeout: 45)
        return try TTLSettings.parseStatus(String(decoding: raw, as: UTF8.self))
    }
    static func readAccess(engine: ModemEngine, cid: String) throws -> AccessManagementState {
        let hashes = try readJSON([String: String].self, engine.resources.appendingPathComponent("SSHAccounts/SHA256.json"))
        guard let hash = hashes["access-services.sh"] else { throw IMEIError.message("Неполный комплект проверки доступов") }
        let data = try script(engine, relativePath: "SSHAccounts/access-services.sh", hash: hash)
        let raw = try engine.remote("sh -s -- status " + shellQuote(cid) + " " + shellQuote(engine.connection.host), input: data, timeout: 45)
        let services = try AccessManager.parseServices(String(decoding: raw, as: UTF8.self), host: engine.connection.host)
        // Do not call inspect(): its separate engine would recursively acquire
        // the application's operation lock already held by this collector.
        let accounts = try SSHAccountManager(root: engine.root, resources: engine.resources, connection: engine.connection,
                                            transport: engine.transport).readStateUnlocked()
        return AccessManagementState(services: services, sshAccounts: accounts)
    }
}
