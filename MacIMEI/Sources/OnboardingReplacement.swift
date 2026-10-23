import Foundation

/// A replacement is distinct from the older optional-component cleanup. Its
/// durable boundary prevents a lost SSH reply or a failed dashboard refresh
/// from sending the core installer again.
struct CoreReplacementPlan: Codable {
    var schema = 1
    var id: String
    var connection: Connection
    var cid: String
    var firmware: String
    var router: String
    var boot: String
    var preserveSettings: Bool
    var phase = "prepared"
    var agentSHA: String
    var installerSHA: String
    var previousSetupSHA: String?
    var stage: String { SetupRemotePaths.anchor + "/stage-" + id }
    var journal: String { SetupRemotePaths.anchor + "/installations/" + id }
    var policy: [String] { [cid, "linux-arm64-access", firmware, router, boot] }
    var identity: Identity { Identity(cid: cid, firmwareHash: firmware) }
    func validate(_ connection: Connection) throws {
        try require(schema == 1 && UUID(uuidString: id)?.uuidString.lowercased() == id &&
                    UUID(uuidString: boot)?.uuidString.lowercased() == boot &&
                    cid.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil &&
                    [agentSHA, installerSHA].allSatisfy(DeviceBackups.validHash) &&
                    (previousSetupSHA == nil || DeviceBackups.validHash(previousSetupSHA!)) &&
                    [firmware, router].allSatisfy({ $0 == "absent" || DeviceBackups.validHash($0) }) &&
                    ["prepared", "install-requested", "ready", "complete"].contains(phase) &&
                    self.connection.host == connection.host && self.connection.port == connection.port &&
                    self.connection.keyPath == connection.keyPath && self.connection.knownHostsPath == connection.knownHostsPath,
                    "Журнал замены относится к другому подключению или повреждён")
    }
}

extension OnboardingEngine {
    var replacementPending: URL { root.appendingPathComponent("core-replacement-pending.json") }

    /// Both public buttons use this entry point. Old dispatched cleanup keeps
    /// its original intent; an undispatched cleanup is cancelled read-only.
    func replaceCore(webPassword: String, agentPassword: String, preserveSettings: Bool = false,
                     expectedIdentity: Identity? = nil, expectedIMEI: String? = nil) throws -> SetupResult {
        var boundIdentity = expectedIdentity
        if ComponentCleanup.hasPending(root: root) {
            if let boundIdentity {
                let recorded=try JSONDecoder().decode(ComponentCleanupPlan.self,from:DeviceBackups.smallFile(ComponentCleanup.pendingURL(root),maximum:65536))
                try recorded.validate(root:root);try require(recorded.identity==boundIdentity,"Предыдущая подготовка относится к другому модему")
            }
            let reconciled: SetupResult
            if let plan = try ComponentCleanup.undispatchedRecoveryPlan(root: root),
               try retireUndispatchedCleanupForReplacement(plan, expectedIdentity:boundIdentity) {
                reconciled = SetupResult(connection: plan.connection, state: nil, identity: plan.identity, firmware: "unknown", suffix: "")
            } else if ComponentCleanup.canCancel(root: root) { reconciled = try cancelComponentCleanup() }
            else { reconciled = try run(webPassword: webPassword, agentPassword: agentPassword) }
            try require(reconciled.connection.host == host, "Журнал очистки относится к другому адресу модема")
            if let boundIdentity { try require(reconciled.identity == boundIdentity, "Предыдущая подготовка относится к другому модему") }
            boundIdentity = reconciled.identity
            currentConnection = reconciled.connection
        }
        let replaced = try locked {
            try replaceCoreOverSSH(agentPassword: agentPassword, preserveSettings: preserveSettings,
                                   expectedIdentity: boundIdentity, expectedIMEI: expectedIMEI)
        }
        let result: SetupResult
        if let replaced { result = replaced }
        else {
            // Archive a legacy installer only after fresh physical identity proof.
            // The new journal uses a fresh UUID and current trusted payloads.
            if let rebound = try replaceLegacyUSBJournal(expectedIdentity:boundIdentity) {
                if let boundIdentity { try require(boundIdentity == rebound, "USB относится к другому модему") }
                boundIdentity = rebound
            }
            result = try run(webPassword: replacementRequiresPhysicalUSB ? "" : webPassword, agentPassword: agentPassword,
                expectedIdentity: boundIdentity, expectedIMEI: expectedIMEI, forceReinstall: true)
            let ssh = sshFactory?(result.connection) ?? SSHTransport(result.connection)
            let reply = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
            try require(reply.status == 0, "SSH не подтвердил завершённую подготовку")
            let proof = try AccessIdentity.parse(reply.stdout)
            try require(proof.identity == result.identity, "Устройство изменилось после подготовки")
            let hashes = try verifyAssets()
            var completed = CoreReplacementPlan(id: UUID().uuidString.lowercased(), connection: result.connection,
                cid: proof.identity.cid, firmware: proof.identity.firmwareHash, router: proof.routerHash, boot: proof.bootID,
                preserveSettings: true, agentSHA: hashes["zte-agent"]!, installerSHA: hashes["setup-agent.sh"]!)
            completed.phase = "complete"
            try secureDirectory(root.appendingPathComponent("CoreReplacementBackups/" + completed.id))
            try saveJSON(completed, replacementPending)
        }
        try saveJSON(result.connection, root.appendingPathComponent("connection.json"))
        let engine = try ModemEngine(root: root, resources: resources, connection: result.connection,
                                    transport: sshFactory?(result.connection), update: update)
        if fm.fileExists(atPath: replacementPending.path) {
            engine.coreReplacementID = try readJSON(CoreReplacementPlan.self, replacementPending).id
        }
        try engine.locked {
            if let replacementDashboard { try replacementDashboard(result.connection) }
            else {
                _ = try AgentInstallationManager(engine: engine).installDashboardForCurrentAgent()
            }
            if fm.fileExists(atPath: replacementPending.path) {
                let plan = try readJSON(CoreReplacementPlan.self, replacementPending)
                try plan.validate(result.connection)
                try require(plan.phase == "complete", "Замена основных файлов ещё не подтверждена")
                let directory = root.appendingPathComponent("CoreReplacementBackups/" + plan.id)
                try saveJSON(plan, directory.appendingPathComponent("replacement-result.json"))
                try fm.removeItem(at: replacementPending)
            }
        }
        return result
    }

    /// A current trusted payload replaces an abandoned old installer; old staged code is never resumed here.
    private func replaceLegacyUSBJournal(expectedIdentity:Identity?) throws -> Identity? {
        try locked {
            guard fm.fileExists(atPath:pending.path) else { return nil }
            let original=try DeviceBackups.smallFile(pending,maximum:65536)
            guard let object=try JSONSerialization.jsonObject(with:original) as? [String:Any],object["installRequested"] as? Bool==true else { return nil }
            let identity:Identity,router:String
            if object["intent"] as? String=="linux-arm64-access" {
                let old=try JSONDecoder().decode(AccessSetupJournal.self,from:original);try old.validate(root:root)
                identity=Identity(cid:old.cid,firmwareHash:old.firmwareHash);router=old.routerHash
            } else {
                let old=try JSONDecoder().decode(SetupJournal.self,from:original)
                guard old.intent==nil,let cid=old.cid,let firmware=old.firmwareHash,let measuredRouter=old.routerHash else { throw IMEIError.message("Предыдущая установка не содержит идентичности модема") }
                _ = try SetupRemotePaths(id:old.id,installRequested:true,stage:old.remoteStage,journal:old.remoteJournal)
                try require(URL(fileURLWithPath:old.directory).standardizedFileURL.path==root.appendingPathComponent("SetupBackups/"+old.id).standardizedFileURL.path,"Повреждён предыдущий журнал установки")
                identity=Identity(cid:cid,firmwareHash:firmware);router=measuredRouter
            }
            if let expectedIdentity { try require(identity==expectedIdentity,"Предыдущая установка относится к другому модему") }
            _ = try verifyAssets()
            let adb=ADBClient(binary:assets.appendingPathComponent("adb"),runner:runner)
            let serials=try adb.discovery().readyUSBSerials
            try require(serials.count==1,"Для продолжения подготовки подключите единственный модем с root USB ADB")
            let serial=serials[0]
            try require(CommandText.decode(adb.command(["-d","get-serialno"],timeout:5)).trimmingCharacters(in:.whitespacesAndNewlines)==serial,"Не подтверждён физический USB-модем")
            let first=try adb.shellResult(serial,AccessIdentity.command,timeout:20)
            try require(first.status==0,"USB не подтвердил модем")
            let proof=try AccessIdentity.parse(first.stdout)
            let second=try adb.shellResult(serial,AccessIdentity.command,timeout:20)
            try require(second.status==0 && AccessIdentity.parse(second.stdout)==proof && proof.identity==identity && proof.routerHash==router,"USB относится к другому модему; прежний журнал сохранён")
            let id=UUID().uuidString.lowercased(),directory=root.appendingPathComponent("SetupBackups/"+id)
            try secureDirectory(directory);try savePrivate(original,directory.appendingPathComponent("previous-setup-before-replacement.json"))
            var fresh=AccessSetupJournal(id:id,cid:identity.cid,bootID:proof.bootID,firmwareHash:identity.firmwareHash,routerHash:router,installerProfile:AccessIdentity.profile(proof,experimental:true),directory:directory.path,adbSerial:serial)
            fresh.forceReinstall=true;fresh.cleanComponents=false
            fresh.remoteStage=SetupRemotePaths.anchor+"/stage-"+id;fresh.remoteJournal=SetupRemotePaths.anchor+"/installations/"+id
            try fresh.validate(root:root)
            try require(try DeviceBackups.smallFile(pending,maximum:65536)==original,"Предыдущий журнал изменился")
            try saveJSON(fresh,pending)
            return identity
        }
    }

    /// An undispatched cleanup from an earlier boot is host metadata only.
    /// Physical USB fallback reads an already-running root shell; it never activates ADB.
    private func retireUndispatchedCleanupForReplacement(_ plan: ComponentCleanupPlan, expectedIdentity:Identity?) throws -> Bool {
        try locked {
            try require(plan.connection.host == host, "Журнал очистки относится к другому адресу модема")
            if let expectedIdentity { try require(plan.identity==expectedIdentity,"Предыдущая установка относится к другому модему") }
            let ssh = sshFactory?(plan.connection) ?? SSHTransport(plan.connection)
            let first = try? ssh.run(AccessIdentity.command, input: nil, timeout: 20)
            let proof: DiagnosticDeviceProof
            if let first, first.status == 0 {
                proof = try AccessIdentity.parse(first.stdout)
                let second = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
                try require(second.status == 0 && AccessIdentity.parse(second.stdout) == proof, "Идентичность модема изменилась")
            } else {
                _ = try verifyAssets()
                let adb = ADBClient(binary: assets.appendingPathComponent("adb"), runner: runner)
                let serials = try adb.discovery().readyUSBSerials
                try require(serials.count == 1, "Для продолжения подготовки подключите единственный модем с root USB ADB")
                let serial = serials[0]
                try require(CommandText.decode(adb.command(["-d", "get-serialno"], timeout: 5)).trimmingCharacters(in: .whitespacesAndNewlines) == serial, "Не подтверждён физический USB-модем")
                let answer = try adb.shellResult(serial, AccessIdentity.command, timeout: 20)
                try require(answer.status == 0, "USB не подтвердил модем")
                proof = try AccessIdentity.parse(answer.stdout)
                let second = try adb.shellResult(serial, AccessIdentity.command, timeout: 20)
                try require(second.status == 0 && AccessIdentity.parse(second.stdout) == proof, "Идентичность USB-модема изменилась")
            }
            try require(proof.identity == plan.identity && proof.routerHash == plan.routerHash, "После перезагрузки обнаружено другое устройство; журнал сохранён")
            guard proof.bootID != plan.effectiveBootID else { return false }
            let directory = URL(fileURLWithPath: plan.backupDirectory)
            try DeviceBackups.directory(root.appendingPathComponent("ComponentBackups"), create: true)
            try DeviceBackups.directory(directory, create: true)
            // Retire the completed setup first: a crash cannot re-create its old cleanup intent.
            if fm.fileExists(atPath: pending.path) {
                let bytes = try DeviceBackups.smallFile(pending, maximum: 65536)
                let object = try JSONSerialization.jsonObject(with: bytes) as? [String:Any]
                try require(object?["id"] as? String == plan.id && object?["phase"] as? String == "complete" && object?["cleanComponents"] as? Bool == true && object?["forceReinstall"] as? Bool == true, "Предыдущая подготовка не соответствует журналу очистки")
                if object?["intent"] as? String == "linux-arm64-access" {
                    let setup=try JSONDecoder().decode(AccessSetupJournal.self,from:bytes);try setup.validate(root:root)
                    try require(setup.cid==plan.cid && setup.firmwareHash==plan.firmwareHash && setup.routerHash==plan.routerHash && setup.bootID==plan.bootID && URL(fileURLWithPath:setup.directory).standardizedFileURL.path==URL(fileURLWithPath:plan.setupReceipt).deletingLastPathComponent().standardizedFileURL.path,"Предыдущая подготовка относится к другому устройству")
                } else {
                    let setup=try JSONDecoder().decode(SetupJournal.self,from:bytes)
                    try require(setup.intent==nil && setup.cid==plan.cid && setup.firmwareHash==plan.firmwareHash && setup.routerHash==plan.routerHash && URL(fileURLWithPath:setup.directory).standardizedFileURL.path==URL(fileURLWithPath:plan.setupReceipt).deletingLastPathComponent().standardizedFileURL.path,"Предыдущая подготовка относится к другому устройству")
                    _ = try SetupRemotePaths(id:setup.id,installRequested:true,stage:setup.remoteStage,journal:setup.remoteJournal)
                }
                try savePrivate(bytes, directory.appendingPathComponent("previous-setup-before-replacement.json"))
                try require(try DeviceBackups.smallFile(pending, maximum: 65536) == bytes, "Предыдущий журнал изменился")
                try fm.removeItem(at: pending)
            }
            return try ComponentCleanup.archiveUndispatchedAfterReboot(root: root, connection: currentConnection, proof: proof)
        }
    }

    private func replaceCoreOverSSH(agentPassword: String, preserveSettings: Bool,
                                   expectedIdentity: Identity?, expectedIMEI: String?) throws -> SetupResult? {
        let saved = fm.fileExists(atPath: replacementPending.path)
            ? try JSONDecoder().decode(CoreReplacementPlan.self, from: DeviceBackups.smallFile(replacementPending, maximum: 65536)) : nil
        if let saved { try saved.validate(currentConnection) }
        let expected = try DiagnosticDeviceExpectation.load(root: root, identity: expectedIdentity, web: nil, imei: expectedIMEI)
        if saved == nil && !preserveSettings {
            guard let pins = try? String(contentsOfFile: currentConnection.knownHostsPath, encoding: .utf8),
                  pins.split(separator: "\n").contains(where: { line in
                      let host = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                      return host.hasPrefix("|1|") || host.split(separator: ",").contains(Substring("[" + currentConnection.host + "]:" + currentConnection.port)) ||
                          (currentConnection.port == "22" && host.split(separator: ",").contains(Substring(currentConnection.host)))
                  }) else { return nil }
        }
        let ssh = sshFactory?(currentConnection) ?? SSHTransport(currentConnection)
        let answer: CommandResult
        do { answer = try ssh.run(AccessIdentity.command, input: nil, timeout: 20) }
        catch {
            let partial = (error as? CommandFailure).map { CommandText.decode($0.partial.stderr) } ?? ""
            if saved == nil && !preserveSettings && !expected.cids.isEmpty && DiagnosticTransportSelector.hostTrustFailure(error.localizedDescription + partial) { replacementRequiresPhysicalUSB = true; return nil }
            try require(!DiagnosticTransportSelector.hostTrustFailure(error.localizedDescription + partial), "Проверка ключа SSH не пройдена; замена не запускалась")
            if saved != nil || preserveSettings { throw error }
            return nil
        }
        if DiagnosticTransportSelector.hostTrustFailure(CommandText.decode(answer.stderr)) {
            if saved == nil && !preserveSettings && !expected.cids.isEmpty { replacementRequiresPhysicalUSB = true; return nil }
            throw IMEIError.message("Проверка ключа SSH не пройдена; замена не запускалась")
        }
        if [Int32(-1), 255].contains(answer.status), saved == nil && !preserveSettings { return nil }
        try require(answer.status == 0, "SSH не подтвердил устройство перед заменой компонентов")
        let proof = try AccessIdentity.parse(answer.stdout)
        if let expectedIdentity { try require(proof.identity == expectedIdentity, "SSH относится к другому модему") }
        let session = try ssh.run(SSHReadProof.command, input: nil, timeout: 20)
        try require(session.status == 0 && SSHReadProof.parse(session.stdout).matches(expected), "SSH относится к другому модему")
        let hashes = try verifyAssets()
        var prior: Data?
        if fm.fileExists(atPath: pending.path) {
            prior = try DeviceBackups.smallFile(pending, maximum: 65536)
            guard let object = try JSONSerialization.jsonObject(with: prior!) as? [String: Any] else { throw IMEIError.message("Повреждён предыдущий журнал установки") }
            if object["installRequested"] as? Bool != true {
                guard ["prepared", "adb-ready"].contains(object["phase"] as? String ?? ""),
                      object["restoreRequested"] as? Bool != true, object["diagnosticRebootRequested"] as? Bool != true,
                      object["directADBRequested"] as? Bool != true, object["directADBOutcome"] == nil else { return nil }
                if object["intent"] as? String == "linux-arm64-access" {
                    try JSONDecoder().decode(AccessSetupJournal.self, from: prior!).validate(root: root)
                } else {
                    let old = try JSONDecoder().decode(SetupJournal.self, from: prior!)
                    try require(old.intent == nil && URL(fileURLWithPath:old.directory).standardizedFileURL.path == root.appendingPathComponent("SetupBackups/"+old.id).standardizedFileURL.path, "Повреждён предыдущий журнал установки")
                    _ = try SetupRemotePaths(id: old.id, installRequested: false, stage: old.remoteStage, journal: old.remoteJournal)
                }
            }
            try require(object["cid"] as? String == proof.identity.cid &&
                        object["firmwareHash"] as? String == proof.identity.firmwareHash &&
                        object["routerHash"] as? String == proof.routerHash,
                        "Предыдущая установка относится к другому устройству; журнал сохранён")
        }
        var plan = saved ?? CoreReplacementPlan(id: UUID().uuidString.lowercased(), connection: currentConnection,
            cid: proof.identity.cid, firmware: proof.identity.firmwareHash, router: proof.routerHash, boot: proof.bootID,
            preserveSettings: preserveSettings, agentSHA: hashes["zte-agent"]!, installerSHA: hashes["setup-agent.sh"]!,
            previousSetupSHA: prior.map(digest))
        try require(plan.identity == proof.identity && plan.router == proof.routerHash,
                    "Устройство изменилось; журнал замены сохранён")
        if plan.boot != proof.bootID {
            // A reboot makes the old dispatch uncertain. The new helper owns
            // reconciliation of that remote journal; keep the exact host copy.
            let old = root.appendingPathComponent("CoreReplacementBackups/" + plan.id)
            try secureDirectory(old); try saveJSON(plan, old.appendingPathComponent("before-reboot.json"))
            plan.boot = proof.bootID
            if plan.phase != "complete" {
                plan.id = UUID().uuidString.lowercased(); plan.phase = "prepared"
                plan.agentSHA = hashes["zte-agent"]!; plan.installerSHA = hashes["setup-agent.sh"]!
            }
            try saveJSON(plan, replacementPending)
        }
        if plan.phase == "prepared" && (plan.agentSHA != hashes["zte-agent"] || plan.installerSHA != hashes["setup-agent.sh"] || (plan.preserveSettings && !preserveSettings)) {
            let old = root.appendingPathComponent("CoreReplacementBackups/" + plan.id)
            try secureDirectory(old); try saveJSON(plan, old.appendingPathComponent("before-replacement.json"))
            plan.id = UUID().uuidString.lowercased()
            plan.agentSHA = hashes["zte-agent"]!; plan.installerSHA = hashes["setup-agent.sh"]!
            plan.preserveSettings = preserveSettings
        }
        let directory = root.appendingPathComponent("CoreReplacementBackups/" + plan.id)
        try secureDirectory(directory)
        if let prior {
            try require(plan.previousSetupSHA == digest(prior), "Предыдущий журнал изменился; замена остановлена")
            try savePrivate(prior, directory.appendingPathComponent("previous-setup.json"))
        }
        func observe() throws {
            let reply = try ssh.run(AccessIdentity.command, input: nil, timeout: 20)
            try require(reply.status == 0, "SSH не подтвердил устройство")
            let current = try AccessIdentity.parse(reply.stdout)
            try require(current.identity == plan.identity && current.routerHash == plan.router && current.bootID == plan.boot,
                        "Устройство или загрузка изменились; журнал замены сохранён")
        }
        func fixed(_ command: String, input: Data? = nil, timeout: TimeInterval = 60) throws -> String {
            let reply = try ssh.run(command, input: input, timeout: timeout)
            guard reply.status == 0 else {
                let codes = CommandText.decode(reply.stderr).split(separator: "\n").filter { $0.hasPrefix("INSTALL_ERROR ") }
                let code = codes.count == 1 ? String(codes[0].dropFirst(14)) : "COMMAND_FAILED"
                let safe = code.range(of: #"^[A-Z][A-Z0-9_]{0,79}$"#, options: .regularExpression) != nil ? code : "COMMAND_FAILED"
                if safe == "AGENT_SETTINGS_REQUIRED" { throw IMEIError.message("Не удалось сохранить прежний пароль агента [AGENT_SETTINGS_REQUIRED]. Введите новый пароль в поле подготовки модема и выполните подготовку.") }
                throw IMEIError.message("Замена компонентов не подтверждена [" + safe + "]. Журнал сохранён.")
            }
            return CommandText.decode(reply.stdout).trimmingCharacters(in: .newlines)
        }
        let owner = ([plan.id] + plan.policy).joined(separator: " ")
        let preserve = plan.preserveSettings ? ["--preserve-agent-settings"] : []
        if plan.phase == "prepared" {
            try require(plan.agentSHA == hashes["zte-agent"] && plan.installerSHA == hashes["setup-agent.sh"], "Комплект замены изменился; журнал сохранён")
            let startup = try Self.agentStartup(password: plan.preserveSettings ? "preserved-on-device" : agentPassword, bindHost: host)
            let script = try Data(contentsOf: assets.appendingPathComponent("setup-agent.sh"))
            // Preflight may normalize private directories and archive stale owned journals.
            try saveJSON(plan, replacementPending)
            let preflight = try fixed("sh -s -- " + (preserve + ["--preflight"] + plan.policy).map(shellQuote).joined(separator: " "), input: script)
            try require(preflight == "INSTALL_PREFLIGHT linux-arm64-access imei_config=unknown", "Предварительная проверка замены не подтверждена")
            let key = try createKey(), publicData = try Data(contentsOf: key.appendingPathExtension("pub"))
            try saveJSON(plan, replacementPending)
            try observe()
            try require(try fixed(Self.stagePreparationCommand(stage: plan.stage, owner: owner)) == "INSTALL_STAGE_READY", "Не подтверждён каталог замены")
            var files = [String: Data]()
            for name in ["zte-agent", "dropbear", "setup-agent.sh", "start_zte_imei_studio.sh"] { files[name] = try Data(contentsOf: assets.appendingPathComponent(name)) }
            files["start-agent.sh"] = startup; files["id_ed25519.pub"] = publicData
            let timeout = try Data(contentsOf: resources.appendingPathComponent("HostTools/zte-timeout"))
            let timeoutManifest = try readJSON([String:String].self, resources.appendingPathComponent("HostTools/SHA256.json"))
            try require(timeoutManifest["zte-timeout"] == digest(timeout), "Повреждён встроенный timeout")
            files["zte-timeout"] = timeout
            for name in files.keys.sorted() {
                let bytes = files[name]!, target = plan.stage + "/" + name
                let incoming = plan.stage + "/incoming-" + UUID().uuidString.lowercased()
                let cmd = "set -eu; umask 077; test \"$(cat " + shellQuote(plan.stage + "/.owner") + ")\" = " + shellQuote(owner) + "; test ! -e " + shellQuote(plan.stage + "/.install-requested") + "; test ! -L " + shellQuote(plan.stage + "/.install-requested") + "; test ! -L " + shellQuote(target) + "; if test -e " + shellQuote(target) + "; then test -f " + shellQuote(target) + "; test \"$(stat -c %u:%h " + shellQuote(target) + ")\" = 0:1; fi; (set -C; cat > " + shellQuote(incoming) + "); chmod 600 " + shellQuote(incoming) + "; test \"$(sha256sum " + shellQuote(incoming) + " | cut -d ' ' -f1)\" = " + shellQuote(digest(bytes)) + "; mv " + shellQuote(incoming) + " " + shellQuote(target) + "; sha256sum " + shellQuote(target)
                try require(try FirmwareCheck.hash(fixed(cmd, input: bytes, timeout: 120), path: target) == digest(bytes), "Переданный компонент замены повреждён")
            }
            try observe()
            plan.phase = "install-requested"; try saveJSON(plan, replacementPending)
            _ = try fixed("set -eu; umask 077; set -C; printf '%s\\n' " + shellQuote(owner) + " > " + shellQuote(plan.stage + "/.install-requested"))
            let args = preserve + [plan.stage, plan.cid, plan.agentSHA, hashes["dropbear"]!, digest(publicData)] + Array(plan.policy.dropFirst())
            let receipt = try fixed("set -eu; test \"$(sha256sum " + shellQuote(plan.stage + "/setup-agent.sh") + " | cut -d ' ' -f1)\" = " + shellQuote(plan.installerSHA) + "; sh " + shellQuote(plan.stage + "/setup-agent.sh") + " " + args.map(shellQuote).joined(separator: " "), timeout: 180)
            try require(receipt.split(separator: "\n").contains(Substring("INSTALL_READY " + plan.journal)), "Готовность замены не подтверждена")
            plan.phase = "ready"; try saveJSON(plan, replacementPending)
        }
        if plan.phase == "install-requested" {
            let state = try fixed(Self.installationStateCommand(plan.journal + "/state"), timeout: 20)
            if ["INSTALL_STATE MISSING", "INSTALL_STATE preparing", "INSTALL_STATE pending", "INSTALL_STATE rolled-back"].contains(state) {
                try observe()
                try saveJSON(plan, directory.appendingPathComponent("before-recovery.json"))
                plan.id = UUID().uuidString.lowercased(); plan.phase = "prepared"
                plan.agentSHA = hashes["zte-agent"]!; plan.installerSHA = hashes["setup-agent.sh"]!
                try saveJSON(plan, replacementPending)
                return try replaceCoreOverSSH(agentPassword: agentPassword, preserveSettings: plan.preserveSettings,
                                              expectedIdentity: expectedIdentity, expectedIMEI: expectedIMEI)
            }
            try require(["INSTALL_STATE ready", "INSTALL_STATE complete"].contains(state), "Прерванная замена ещё не подтверждена; журнал и копия сохранены")
            plan.phase = state == "INSTALL_STATE complete" ? "complete" : "ready"; try saveJSON(plan, replacementPending)
        }
        try observe()
        let process = try ssh.run(AccessAgentProcessProof.command(), input: nil, timeout: 20)
        if plan.phase=="complete" && process.status==72 {
            let absence=try ssh.run(AccessAgentProcessProof.absenceCommand(expectedHash:plan.agentSHA),input:nil,timeout:30)
            try require(absence.status==0 && absence.stdout==Data(("AGENT_ACCESS_ABSENT "+plan.agentSHA+"\n").utf8),"Отсутствие завершённого агента не подтверждено; журнал сохранён")
            try observe();try saveJSON(plan,directory.appendingPathComponent("before-agent-restart.json"))
            plan.id=UUID().uuidString.lowercased();plan.phase="prepared";plan.preserveSettings=preserveSettings
            plan.agentSHA=hashes["zte-agent"]!;plan.installerSHA=hashes["setup-agent.sh"]!
            try saveJSON(plan,replacementPending)
            return try replaceCoreOverSSH(agentPassword:agentPassword,preserveSettings:preserveSettings,expectedIdentity:expectedIdentity,expectedIMEI:expectedIMEI)
        }
        try require(process.status == 0, "Не подтверждён процесс нового агента")
        _ = try AccessAgentProcessProof.parse(process.stdout, allowedHashes: [plan.agentSHA])
        if !plan.preserveSettings && plan.agentSHA == hashes["zte-agent"] && plan.phase != "complete" { try authenticateAgent(transport: ssh, password: agentPassword) }
        if plan.phase == "ready" {
            let cmd = "set -eu; test \"$(sha256sum " + shellQuote(plan.stage + "/setup-agent.sh") + " | cut -d ' ' -f1)\" = " + shellQuote(plan.installerSHA) + "; sh " + shellQuote(plan.stage + "/setup-agent.sh") + " " + (["--commit", plan.journal] + plan.policy).map(shellQuote).joined(separator: " ")
            let receipt = try fixed(cmd)
            try require(receipt.split(separator: "\n").contains(Substring("INSTALL_COMMITTED " + plan.journal)), "Завершение замены не подтверждено")
            try observe(); plan.phase = "complete"; try saveJSON(plan, replacementPending)
        }
        if let previous = plan.previousSetupSHA, fm.fileExists(atPath: pending.path) {
            try require(digest(DeviceBackups.smallFile(pending, maximum: 65536)) == previous, "Предыдущий журнал изменился; он сохранён")
            try fm.removeItem(at: pending)
        }
        if plan.agentSHA != hashes["zte-agent"] || plan.installerSHA != hashes["setup-agent.sh"] {
            try saveJSON(plan, directory.appendingPathComponent("replacement-result.json"))
            plan.id = UUID().uuidString.lowercased(); plan.phase = "prepared"
            plan.agentSHA = hashes["zte-agent"]!; plan.installerSHA = hashes["setup-agent.sh"]!
            plan.preserveSettings = preserveSettings; plan.previousSetupSHA = nil
            try saveJSON(plan, replacementPending)
            return try replaceCoreOverSSH(agentPassword: agentPassword, preserveSettings: preserveSettings,
                                          expectedIdentity: expectedIdentity, expectedIMEI: expectedIMEI)
        }
        return SetupResult(connection: currentConnection, state: nil, identity: plan.identity, firmware: "unknown", suffix: "")
    }
}
