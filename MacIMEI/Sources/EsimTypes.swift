import Foundation
import CoreFoundation

enum EsimNetworkFailure: String {
    case tls = "http_tls_failed", dns = "http_dns_failed", timeout = "http_timeout"
    case connection = "http_connection_failed", bodyLimit = "http_response_too_large"
    case cancelled = "http_cancelled", transport = "http_failed"
    case redirect = "http_redirect_refused", invalidRequest = "http_request_invalid"
    var explanation: String {
        switch self {
        case .tls: return "Не удалось проверить TLS-сертификат сервера оператора."
        case .dns: return "Не удалось определить адрес сервера оператора."
        case .timeout: return "Сервер оператора не ответил за отведённое время."
        case .connection: return "Нет соединения с сервером оператора. Проверьте интернет компьютера."
        case .bodyLimit: return "Ответ сервера превысил допустимый размер."
        case .cancelled: return "HTTPS-запрос был прерван."
        case .redirect: return "Сервер вернул запрещённое перенаправление HTTPS."
        case .invalidRequest: return "Агент передал некорректный HTTPS-запрос."
        case .transport: return "Не удалось выполнить HTTPS-запрос к оператору."
        }
    }
}

enum EsimFailure: Error, LocalizedError {
    case resources, invalidInput, invalidSnapshot, transport, protocolError, operationRejected, targetChanged
    case backend(String)
    case network(EsimNetworkFailure)
    var errorDescription: String? {
        switch self {
        case .resources: return "Компоненты eSIM отсутствуют или повреждены. Установите полный комплект приложения."
        case .invalidInput: return "Проверьте код LPA и выбранный профиль."
        case .invalidSnapshot: return "Карта вернула некорректный список профилей. Обновите список."
        case .targetChanged: return "Карта или выбранное подключение изменились. Обновите список профилей."
        case .backend(let code):
            if code == "radio_restore_failed" { return "Включение радио после авиарежима не подтверждено. Проверьте авиарежим на модеме и обновите список профилей. Автоматического повтора не было." }
            if let message = EsimLog.cardMessage(code) { return message }
            return "Ошибка eSIM: " + EsimLog.backendError(code) + ". Результат не подтверждён. Перечитайте профили перед следующим действием."
        case .network(let reason): return reason.explanation + " Код: " + reason.rawValue + ". Перечитайте профили перед следующей попыткой."
        case .operationRejected: return "Карта отклонила операцию. Обновите список перед следующей попыткой."
        case .transport, .protocolError: return "Результат операции неизвестен. Прочитайте профили заново; операция не повторялась автоматически."
        }
    }
}

struct EsimProfile: Codable, Equatable, Sendable {
    var iccid: String?
    var isdpAid: String?
    var state: String
    var enabled: Bool
    var nickname: String?
    var serviceProvider: String?
    var name: String?
    enum CodingKeys: String, CodingKey { case iccid, isdpAid = "isdp_aid", state, enabled, nickname, serviceProvider = "service_provider", name }
    var title: String { EsimPrivacy.label(nickname ?? name ?? serviceProvider ?? "Профиль") }
    var maskedICCID: String { EsimPrivacy.mask(iccid ?? "") }
    var selectable: Bool { iccid.map { EsimValidation.digits($0, count: 18...20) } == true }
    var inventoryKey: String { (iccid ?? "") + ":" + (isdpAid ?? "").lowercased() + ":" + state }
}

struct EsimSnapshot: Codable, Equatable, Sendable {
    var ok: Bool
    var eid: String
    var profiles: [EsimProfile]
    func validate() throws {
        guard ok, EsimValidation.digits(eid, count: 32...32), profiles.count <= 1024,
              profiles.allSatisfy({ ["enabled", "disabled", "unknown"].contains($0.state) && $0.enabled == ($0.state == "enabled") }) else { throw EsimFailure.invalidSnapshot }
        var ids = Set<String>(), aids = Set<String>()
        for profile in profiles {
            guard let id = profile.iccid, EsimValidation.digits(id, count: 18...20), ids.insert(id).inserted,
                  [profile.name, profile.nickname, profile.serviceProvider].allSatisfy({ ($0?.utf8.count ?? 0) <= 4096 }) else { throw EsimFailure.invalidSnapshot }
            if let aid = profile.isdpAid {
                guard !aid.isEmpty, (try? EsimValidation.hex(aid, maxBytes: 32)) != nil, aids.insert(aid.lowercased()).inserted else { throw EsimFailure.invalidSnapshot }
            }
        }
    }
    var writeReady: Bool {
        profiles.allSatisfy(\.selectable) && Set(profiles.compactMap(\.iccid)).count == profiles.count
    }
    var inventory: [String] { profiles.map(\.inventoryKey).sorted() }
}

enum EsimOperation: Sendable {
    case list
    case download(String, String)
    case enable(String)
    case delete(String)
    var name: String { switch self { case .list: return "list"; case .download: return "download"; case .enable: return "enable"; case .delete: return "delete" } }
    var mutates: Bool { name != "list" }
    func request(snapshot: EsimSnapshot?) throws -> Data {
        var object: [String: Any] = ["protocol": 1, "operation": name]
        if mutates {
            guard let snapshot, snapshot.writeReady else { throw EsimFailure.invalidSnapshot }
            try snapshot.validate()
            object["expected_snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        }
        switch self {
        case .list: break
        case .download(let code, let confirmation):
            guard EsimValidation.activationCode(code) == code, confirmation.utf8.count <= 512, !confirmation.hasPrefix("-"),
                  !confirmation.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { throw EsimFailure.invalidInput }
            object["activation_code"] = code
            if !confirmation.isEmpty { object["confirmation_code"] = confirmation }
        case .enable(let iccid), .delete(let iccid):
            guard let matches = snapshot?.profiles.filter({ $0.iccid == iccid }), matches.count == 1,
                  EsimValidation.digits(iccid, count: 18...20) else { throw EsimFailure.invalidInput }
            if case .delete = self {
                guard matches[0].state == "disabled", !matches[0].enabled else { throw EsimFailure.invalidInput }
                object["confirm_delete"] = true
            }
            object["iccid"] = iccid
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

struct EsimRPCResult: Decodable, Sendable {
    var type: String
    var ok: Bool
    var snapshot: EsimSnapshot?
    var changed: Bool?
    var notificationsPending: Bool?
    var modemVerified: Bool?
    var radioRestored: Bool?
    var error: String?
    var componentError: String?
    enum CodingKeys: String, CodingKey { case type, ok, snapshot, changed, notificationsPending = "notifications_pending", modemVerified = "modem_verified", radioRestored = "radio_restored", error, componentError = "component_error" }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        type = try fields.decode(String.self, forKey: .type)
        ok = try fields.decode(Bool.self, forKey: .ok)
        snapshot = try fields.decodeIfPresent(EsimSnapshot.self, forKey: .snapshot)
        changed = try fields.decodeIfPresent(Bool.self, forKey: .changed)
        notificationsPending = try fields.decodeIfPresent(Bool.self, forKey: .notificationsPending)
        modemVerified = try fields.decodeIfPresent(Bool.self, forKey: .modemVerified)
        radioRestored = try fields.decodeIfPresent(Bool.self, forKey: .radioRestored)
        error = try fields.decodeIfPresent(String.self, forKey: .error)
        componentError = EsimLog.componentError(try fields.decodeIfPresent(String.self, forKey: .componentError))
    }
    func accepted(for operation: EsimOperation, before: EsimSnapshot?) throws -> EsimSnapshot {
        guard type == "result" else { throw EsimFailure.protocolError }
        guard ok else { throw EsimFailure.backend(EsimLog.backendError(error)) }
        guard componentError == nil else { throw EsimFailure.protocolError }
        guard let current = snapshot, let changed, notificationsPending != nil else { throw EsimFailure.protocolError }
        try current.validate()
        if !operation.mutates { guard !changed else { throw EsimFailure.protocolError }; return current }
        guard let before, current.eid == before.eid, current.writeReady else { throw EsimFailure.targetChanged }
        switch operation {
        case .list: break
        case .download:
            let old = Set(before.profiles.compactMap(\.iccid))
            let added = current.profiles.filter { !old.contains($0.iccid ?? "") }
            guard changed, added.count == 1, added[0].state == "disabled", current.profiles.count == before.profiles.count + 1,
                  current.profiles.filter({ old.contains($0.iccid ?? "") }).map(\.inventoryKey).sorted() == before.inventory else { throw EsimFailure.protocolError }
        case .enable(let iccid):
            guard let previous = before.profiles.first(where: { $0.iccid == iccid }), changed == !previous.enabled,
                  modemVerified == true, radioRestored == true,
                  current.profiles.map({ ($0.iccid ?? "") + ":" + ($0.isdpAid ?? "").lowercased() }).sorted() == before.profiles.map({ ($0.iccid ?? "") + ":" + ($0.isdpAid ?? "").lowercased() }).sorted(),
                  current.profiles.allSatisfy({ $0.iccid == iccid ? $0.state == "enabled" : $0.state == "disabled" }),
                  current.profiles.contains(where: { $0.iccid == iccid && $0.enabled }) else { throw EsimFailure.protocolError }
        case .delete(let iccid):
            guard changed, !current.profiles.contains(where: { $0.iccid == iccid }), current.inventory == before.profiles.filter({ $0.iccid != iccid }).map(\.inventoryKey).sorted() else { throw EsimFailure.protocolError }
        }
        return current
    }
}

enum EsimPrivacy {
    static func mask(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "•", count: max(value.count, 4)) }
        return String(value.prefix(4)) + "••••••••" + String(value.suffix(4))
    }
    static func label(_ text: String) -> String {
        let printable = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(160))
        return printable.replacingOccurrences(of: "[0-9]{9,}", with: "[скрыто]", options: .regularExpression)
            .replacingOccurrences(of: "(?i)LPA:[^\\s]+", with: "[скрыто]", options: .regularExpression)
    }
}

enum EsimValidation {
    static func digits(_ value: String, count: ClosedRange<Int>) -> Bool { count.contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) } }
    static func domain(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 253 && labels.count >= 2 && labels.contains(where: { $0.contains(where: { $0.isLetter }) }) && labels.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
    static func activationCode(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 512, value.hasPrefix("LPA:1$"), value.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { return nil }
        let parts = value.split(separator: "$", omittingEmptySubsequences: false)
        guard (3...5).contains(parts.count), domain(String(parts[1])), !parts[2].isEmpty else { return nil }
        return value
    }
    static func uniqueQR(_ payloads: [String]) throws -> String {
        guard payloads.count == 1, let code = activationCode(payloads[0]) else { throw EsimFailure.invalidInput }
        return code
    }
    static func manualCode(address: String, matchingID: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = matchingID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              !matching.isEmpty, matching.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 36 }) else { return nil }
        let host: String
        if trimmed.contains("://") {
            guard let parts = URLComponents(string: trimmed), parts.scheme == "https",
                  let name = parts.host, parts.percentEncodedHost?.contains("%") != true,
                  parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.percentEncodedPath) else { return nil }
            host = name.lowercased()
        } else { host = trimmed.lowercased() }
        guard domain(host) else { return nil }
        let code = "LPA:1$" + host + "$" + matching
        return activationCode(code)
    }
    static func hex(_ text: String, maxBytes: Int) throws -> Data {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0, bytes.count / 2 <= maxBytes else { throw EsimFailure.protocolError }
        func nibble(_ v: UInt8) -> UInt8? { if v >= 48 && v <= 57 { return v - 48 }; if v >= 65 && v <= 70 { return v - 55 }; if v >= 97 && v <= 102 { return v - 87 }; return nil }
        var data = Data(); data.reserveCapacity(bytes.count / 2)
        for i in stride(from: 0, to: bytes.count, by: 2) { guard let a = nibble(bytes[i]), let b = nibble(bytes[i + 1]) else { throw EsimFailure.protocolError }; data.append(a << 4 | b) }
        return data
    }
}

enum EsimStreamEvent {
    case progress(String, EsimProgressDetail?)
    case http(Int, [String: Any])
    case result
}

struct EsimRPCDecoder {
    private(set) var result: EsimRPCResult?
    private var seenHTTPIDs = Set<Int>()
    private var messageCount = 0
    private var lastLogSequence = 0
    var allowsHTTP = true
    mutating func consume(_ line: Data) throws -> EsimStreamEvent {
        messageCount += 1
        guard messageCount <= 10000, line.count <= 9 * 1024 * 1024, result == nil,
              let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { throw EsimFailure.protocolError }
        switch type {
        case "progress":
            guard let stage = object["stage"] as? String, ["checking_card", "reading_profiles", "downloading", "enabling", "deleting", "notifications", "verifying", "cleanup", "radio_offline", "radio_online", "reading_modem"].contains(stage) else { throw EsimFailure.protocolError }
            var detail: EsimProgressDetail?
            if let raw = object["detail"] {
                guard let fields = raw as? [String: Any] else { throw EsimFailure.protocolError }
                detail = try EsimProgressDetail(fields)
                guard detail!.sequence == lastLogSequence + 1 else { throw EsimFailure.protocolError }
                lastLogSequence = detail!.sequence
            }
            return .progress(stage, detail)
        case "http":
            guard allowsHTTP, let n = object["id"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 1,
                  n.doubleValue <= Double(Int32.max), n.doubleValue.rounded() == n.doubleValue,
                  seenHTTPIDs.insert(n.intValue).inserted,
                  let payload = object["payload"] as? [String: Any] else { throw EsimFailure.protocolError }
            return .http(n.intValue, payload)
        case "result": result = try JSONDecoder().decode(EsimRPCResult.self, from: line); return .result
        default: throw EsimFailure.protocolError
        }
    }
    func finish(exitCode: Int32, operation: EsimOperation, before: EsimSnapshot?) throws -> EsimRPCResult {
        guard let result else { throw EsimFailure.transport }
        if exitCode == 1 && !result.ok { throw EsimFailure.backend(EsimLog.backendError(result.error)) }
        guard exitCode == 0 else { throw EsimFailure.transport }
        _ = try result.accepted(for: operation, before: before)
        return result
    }
}

/// Only literal enums and bounded numeric metadata cross from private RPC into
/// the persistent journal. Unknown keys (including private identifiers) never do.
struct EsimProgressDetail {
    let sequence: Int
    let summary: String
    init(_ fields: [String: Any]) throws {
        func number(_ key: String, max: Int = 1_000_000_000_000) throws -> Int? {
            guard let value = fields[key] else { return nil }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue >= 0, n.doubleValue <= Double(max), n.doubleValue.rounded() == n.doubleValue else { throw EsimFailure.protocolError }
            return n.intValue
        }
        guard let event = fields["event"] as? String,
              ["stage", "waiting", "component_start", "component_exit", "apdu_sent", "apdu_reply", "http_start", "http_end", "cleanup_start", "cleanup_end"].contains(event),
              let seq = try number("log_seq", max: 10000), seq > 0,
              let elapsed = try number("elapsed_ms"), let apdu = try number("apdu_count"), let http = try number("http_count") else { throw EsimFailure.protocolError }
        sequence = seq
        var parts = [event, "seq=\(seq)", "agent_ms=\(elapsed)", "apdu=\(apdu)", "http=\(http)"]
        for (key, allowed) in [("component", ["snapshot", "bridge", "lpac"]), ("waiting_for", ["card", "operator_https", "cleanup"]), ("outcome", ["ok", "failed"])] {
            if let value = fields[key] as? String, allowed.contains(value) { parts.append(key + "=" + value) }
        }
        for key in ["duration_ms", "request_bytes", "response_bytes"] {
            if let n = try number(key) { parts.append("\(key)=\(n)") }
        }
        if let status = try number("http_status", max: 599) { parts.append("http_status=\(status)") }
        if fields["error"] != nil { parts.append("error=" + EsimLog.backendError(fields["error"] as? String)) }
        summary = parts.joined(separator: " ")
    }
}

enum EsimLog {
    // Pinned literal catalog from ModemAgent/esim-build/progress-error-codes.json.
    static let backendErrors: Set<String> = [
        "card_busy", "card_open_rejected", "card_cleanup_unknown", "card_not_ready",
        "card_reset_failed", "card_power_restore_failed",
        "operation_lock_failed", "launcher_operation_refused", "radio_read_failed", "radio_not_online", "radio_set_failed", "radio_offline_failed", "radio_restore_failed", "modem_readback_failed", "modem_slot_mismatch", "modem_iccid_mismatch", "esim_busy",
        "bridge_already_open",
        "bridge_cleanup_failed",
        "bridge_missing",
        "card_changed",
        "component_already_closed",
        "component_closed",
        "component_eof",
        "component_exit_failed",
        "component_start_failed",
        "delete_confirmation_required",
        "firmware_check_failed",
        "http_destination_refused",
        "http_failed",
        "http_id_exhausted",
        "http_reply_missing",
        "http_unavailable",
        "invalid_activation_code",
        "invalid_apdu_reply",
        "invalid_arguments",
        "invalid_confirmation_code",
        "invalid_http_reply",
        "invalid_http_request",
        "invalid_json",
        "invalid_lpac_message",
        "invalid_lpac_result",
        "invalid_notifications",
        "invalid_output",
        "invalid_request",
        "invalid_snapshot",
        "job_deadline_exceeded",
        "job_message_limit",
        "job_start_failed",
        "lpac_failed",
        "lpac_result_missing",
        "message_too_large",
        "multiple_lpac_results",
        "notification_cleanup_failed",
        "postcondition_failed",
        "profile_not_disabled",
        "profile_not_found",
        "request_missing",
        "resource_cleanup_failed",
        "resource_integrity_failed",
        "resource_ownership_changed",
        "snapshot_changed",
        "snapshot_cleanup_failed",
        "snapshot_missing",
        "snapshot_required",
        "stream_read_failed",
        "stream_write_failed",
        "temporary_resource_failed",
        "unexpected_component_output",
        "unsupported_device",
        "unsupported_firmware",
        "unsupported_protocol",
        "unterminated_message"
    ]
    static func backendError(_ value: String?) -> String {
        guard let value, backendErrors.contains(value) else { return "unrecognized_backend_error" }
        return value
    }
    // Exact static helper catalog from snapshot-diagnostics/component-error-codes.json.
    static let componentErrors: Set<String> = [
        "lock_unavailable", "lock_random_failed", "lock_owner_failed", "lock_metadata_failed",
        "lock_release_failed", "lock_ownership_changed", "lock_retained", "selection_read_failed",
        "selection_mismatch", "qmi_connect_error", "qmi_open_rejected", "qmi_open_unknown",
        "channel_open_outcome_unknown", "channel_close_failed", "card_cleanup_unknown", "card_not_ready",
        "unsupported_channel", "qmi_transmit_error", "short_apdu_response", "snapshot_response_too_large",
        "snapshot_continuation_limit", "snapshot_card_status_error", "eid_command_error", "eid_parse_error",
        "eid_mismatch", "profiles_command_error", "profiles_parse_error", "stdout_error", "stdin_error",
        "unterminated_json_line", "input_line_too_large", "invalid_json_line", "invalid_header",
        "invalid_expected_eid", "missing_header", "invalid_arguments", "bridge_operation_failed",
        "already_connected", "already_open", "session_failed", "not_connected", "not_open",
        "missing_owned_connection", "empty_read_command", "invalid_envelope", "invalid_function",
        "invalid_aid", "aid_not_allowed", "invalid_apdu", "invalid_hex", "unsupported_function"
    ]
    static func componentError(_ value: String?) -> String? {
        guard let value, componentErrors.contains(value) else { return nil }
        return value
    }
    static func componentMetadata(_ value: String?) -> String {
        componentError(value).map { " component_error=" + $0 } ?? ""
    }
    static func resultMetadata(_ result: EsimRPCResult) -> String {
        "agent_result_received ok=" + (result.ok ? "true" : "false error=" + backendError(result.error)) + componentMetadata(result.componentError)
    }
    private static let cardMessages: [String: (String, String)] = [
        "card_busy": ("Карта занята другой операцией. Дождитесь её завершения и обновите список профилей. Автоматического повтора не было.",
                      "The card is busy with another operation. Wait for it to finish, then refresh the profile list. No automatic retry was made."),
        "card_open_rejected": ("Модем отклонил открытие канала карты. Дождитесь готовности SIM и обновите список профилей. Автоматического повтора не было.",
                               "The modem rejected opening a card channel. Wait for the SIM to be ready, then refresh the profile list. No automatic retry was made."),
        "card_cleanup_unknown": ("Закрытие канала карты не подтверждено. Перезагрузите модем перед повторной попыткой, затем обновите список профилей. Не повторяйте переключение до перезагрузки.",
                                 "Card channel cleanup is unconfirmed. Restart the modem before trying again, then refresh the profile list. Do not retry the profile switch before restarting."),
        "card_not_ready": ("SIM ещё не готова после перечитывания. Радио включено. Дождитесь готовности SIM и обновите список профилей; переключение автоматически не повторялось.",
                           "The SIM is not ready after the refresh. The radio is online. Wait for the SIM to be ready, then refresh the profile list; the switch was not retried automatically."),
        "card_reset_failed": ("Перезапуск SIM не подтверждён. Перечитайте профили и проверьте результат переключения. Автоматического повтора не было.",
                              "The SIM restart is unconfirmed. Read profiles again and check the switch result. No automatic retry was made."),
        "card_power_restore_failed": ("Включение SIM не подтверждено. Перезагрузите модем перед повторной попыткой, затем перечитайте профили.",
                                      "SIM power restoration is unconfirmed. Restart the modem before trying again, then read profiles again.")
    ]
    static func cardMessage(_ code: String, language: String = "ru") -> String? {
        guard let pair = cardMessages[code] else { return nil }
        return language == "en" ? pair.1 : pair.0
    }
    static func localizedCardMessage(_ message: String, language: String) -> String {
        guard language == "en", let pair = cardMessages.values.first(where: { $0.0 == message }) else { return message }
        return pair.1
    }
    static func recoveryCode(_ failure: EsimFailure) -> String {
        switch failure {
        case .backend("card_cleanup_unknown"), .backend("card_power_restore_failed"): return "restart_modem_before_retry"
        case .backend("card_busy"), .backend("card_open_rejected"), .backend("card_not_ready"): return "wait_then_refresh_profiles"
        default: return "refresh_profiles_before_retry"
        }
    }
    static func failureCode(_ failure: EsimFailure) -> String {
        switch failure {
        case .resources: return "local_resources_invalid"
        case .invalidInput: return "local_input_invalid"
        case .invalidSnapshot: return "snapshot_invalid"
        case .transport: return "transport_result_unknown"
        case .protocolError: return "protocol_result_unknown"
        case .operationRejected: return "operation_rejected"
        case .targetChanged: return "target_changed"
        case .backend(let value): return backendError(value)
        case .network(let value): return value.rawValue
        }
    }
}
