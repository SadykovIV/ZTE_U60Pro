import Foundation

/// Captured on the main actor before starting work. A newly created SSH engine
/// must still refer to the device which the user selected in the interface.
struct SSHSelectionContext: @unchecked Sendable {
    var identity: Identity?
    var imei: String?
    var session: ReadOnlyChannelSession?

    func verify(_ engine: ModemEngine) throws {
        if let session {
            let shell = try session.requireSSH()
            if let endpoint = session.sshEndpoint {
                try require(endpoint == ConnectionRouter.sshEndpoint(engine.connection), "Параметры SSH изменились. Подключитесь заново.")
                try shell.readProof.verify(SSHReadProof.parse(engine.remote(shell.readProof.verificationCommand, timeout: 15)))
                return // Operation-specific managers still check write privileges.
            }
        }
        let expected = identity ?? session?.summary.identity
        if let expected {
            let current = try engine.accessIdentity().0
            try require(current == expected, "Устройство или прошивка SSH изменились. Проверьте выбранное подключение заново.")
        }
        if let imei {
            let raw = try engine.remote("ubus call zwrt_web device_info '{}'", timeout: 15)
            guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw IMEIError.message("SSH не подтвердил IMEI выбранного модема")
            }
            let current = try WebIdentity(object, skipFirmwareCheck: true)
            try require(current.imei == imei, "SSH относится к другому модему или его IMEI изменился. Проверьте подключение заново.")
        }
    }
}
