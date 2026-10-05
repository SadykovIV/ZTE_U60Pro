import Foundation

/// Ordinary diagnostics use SSH only. Bootstrap research remains a separate
/// onboarding operation; a failed SSH read never selects another transport.
enum ConnectionDiagnostics {
    static func collect(engine: ModemEngine, mode: ConnectionMode, session supplied: ReadOnlyChannelSession? = nil,
                        expectedIdentity: Identity? = nil, expectedWebIdentity: WebIdentity? = nil, expectedIMEI: String? = nil,
                        webPassword: String = "", agentPassword: String = "", router suppliedRouter: ConnectionRouter? = nil) throws -> DiagnosticReport {
        try require(engine.lockFD >= 0, "Диагностика требует блокировки операции")
        try require(mode == .automatic || mode == .ssh, "Диагностика модема доступна только через SSH")
        let session: ReadOnlyChannelSession
        if let supplied {
            try require(supplied.mode == .ssh, "Диагностика модема доступна только через SSH")
            session = supplied
        } else {
            // Legacy credential parameters are retained for source compatibility;
            // ordinary diagnostics never authenticate to Web or agent APIs.
            let router = try suppliedRouter ?? ConnectionRouter(engine: engine, expectedIdentity: expectedIdentity, expectedWebIdentity: expectedWebIdentity, expectedIMEI: expectedIMEI)
            let selected = try router.select(mode: .ssh)
            guard let chosen = selected.session else { throw IMEIError.message(selected.reason) }
            session = chosen
        }
        guard session.mode == .ssh, let shell = session.diagnosticSession, shell.transport == "ssh" else {
            throw IMEIError.message("Выбранный канал не предоставил проверенную SSH-сессию")
        }
        return try ModemInformationManager(engine: engine).collectDiagnostics(expectedIdentity: expectedIdentity, expectedWebIdentity: expectedWebIdentity, expectedIMEI: expectedIMEI, preferredSession: shell)
    }
}
