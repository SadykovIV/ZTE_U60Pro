import Foundation

/// A nil value leaves that direction's IPv4 TTL unchanged. Outbound means SET; inboundIncrement means INC after routing.
struct TTLConfiguration: Equatable, Sendable {
    var outbound: Int?
    var inboundIncrement: Int?

    static let disabled = TTLConfiguration(outbound: nil, inboundIncrement: nil)
    var isDisabled: Bool { outbound == nil && inboundIncrement == nil }

    init(outbound: Int?, inboundIncrement: Int?) {
        self.outbound = outbound
        self.inboundIncrement = inboundIncrement
    }

    init(outboundEnabled: Bool, outboundText: String, inboundIncrementEnabled: Bool, inboundIncrementText: String) throws {
        outbound = outboundEnabled ? try Self.value(outboundText, direction: "Исходящий TTL") : nil
        inboundIncrement = inboundIncrementEnabled ? try Self.value(inboundIncrementText, direction: "Прибавка к входящему TTL") : nil
    }

    func validate() throws {
        for value in [outbound, inboundIncrement].compactMap({ $0 }) {
            try require((1...255).contains(value), "TTL должен быть целым числом от 1 до 255")
        }
    }

    private static func value(_ text: String, direction: String) throws -> Int {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try require(!value.isEmpty && value.utf8.count <= 3 && value.utf8.allSatisfy { (48...57).contains($0) }, direction + ": введите целое число от 1 до 255")
        guard let number = Int(value), (1...255).contains(number) else {
            throw IMEIError.message(direction + ": введите целое число от 1 до 255")
        }
        return number
    }
}

enum TTLState: String, Sendable { case disabled, configured, verified, unsupported, error }
enum TTLCapability: String, Sendable { case unknown, supported, unsupported }
enum TTLVerification: String, Sendable { case unverified, verified, notApplicable = "not-applicable" }
enum TTLPersistence: String, Sendable { case none, session, boot }

struct TTLStatus: Sendable {
    var state: TTLState
    var configuration: TTLConfiguration = .disabled
    var capability: TTLCapability = .unknown
    var verification: TTLVerification = .unverified
    var persistence: TTLPersistence = .none
    var detail: String = ""

    var canApply: Bool { capability == .supported }
    var summary: String {
        if !detail.isEmpty { return title + ". " + detail }
        if state == .configured || state == .verified {
            let outbound = configuration.outbound.map(String.init) ?? "обычный"
            let inbound = configuration.inboundIncrement.map { "+\($0)" } ?? "без прибавки"
            return title + ". Исходящий TTL: " + outbound + "; входящий: " + inbound + "."
        }
        return title + "."
    }
    var title: String {
        switch state {
        case .disabled: return "Изменение TTL выключено"
        case .configured: return "Правила TTL установлены"
        case .verified: return "Проверка TTL прошла"
        case .unsupported: return "Изменение TTL недоступно"
        case .error: return "Не удалось подтвердить состояние TTL"
        }
    }
    var capabilityDescription: String {
        switch capability {
        case .unknown: return "Возможности прошивки ещё не проверены."
        case .supported: return "Фиксация исходящего IPv4 TTL и прибавка к входящему поддерживаются."
        case .unsupported: return "На этой прошивке не найден поддерживаемый способ изменения IPv4 TTL."
        }
    }
    var verificationDescription: String {
        switch verification {
        case .verified: return "При последней проверке трафика значения TTL совпали с настройками."
        case .unverified: return "Приложение проверяет настройки и правила. Автоматическая проверка трафика не выполняется."
        case .notApplicable: return "Правила изменения TTL отключены."
        }
    }
    var persistenceDescription: String {
        switch persistence {
        case .none: return ""
        case .session: return "Настройки действуют до перезагрузки модема."
        case .boot: return "Настройки сохраняются после перезагрузки модема."
        }
    }
}

/// Pure validation and status decoding. Remote calls are added after capability review.
enum TTLSettings {
    static func parseStatus(_ output: String) throws -> TTLStatus {
        let lines = output.split(whereSeparator: \.isNewline)
        try require(lines.count == 1, "Получен неполный или неоднозначный статус TTL")
        let fields = lines[0].split(separator: " ")
        try require(fields.first == "TTL_STATUS", "Неизвестный формат статуса TTL")
        var values = [String: String]()
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            try require(pair.count == 2 && values[String(pair[0])] == nil, "Повтор или повреждение поля статуса TTL")
            values[String(pair[0])] = String(pair[1])
        }
        try require(Set(values.keys) == Set(["state", "outbound", "inbound_inc", "capability", "verification", "persistence"]), "Неполный статус TTL")
        guard let state = TTLState(rawValue: values["state"]!),
              let capability = TTLCapability(rawValue: values["capability"]!),
              let verification = TTLVerification(rawValue: values["verification"]!),
              let persistence = TTLPersistence(rawValue: values["persistence"]!) else {
            throw IMEIError.message("Неизвестные значения статуса TTL")
        }
        func direction(_ name: String) throws -> Int? {
            let raw = values[name]!
            if raw == "off" { return nil }
            try require(!raw.isEmpty && raw.utf8.allSatisfy { (48...57).contains($0) }, "Неверное значение TTL в статусе")
            guard let number = Int(raw), (1...255).contains(number) else { throw IMEIError.message("Неверное значение TTL в статусе") }
            return number
        }
        let configuration = try TTLConfiguration(outbound: direction("outbound"), inboundIncrement: direction("inbound_inc"))
        if state != .error {
            switch state {
            case .disabled:
                try require(configuration.isDisabled && verification == .notApplicable, "Несогласованное выключенное состояние TTL")
            case .configured:
                try require(!configuration.isDisabled && capability == .supported && verification == .unverified, "Несогласованное состояние правил TTL")
            case .verified:
                try require(!configuration.isDisabled && capability == .supported && verification == .verified, "Проверка трафика не подтверждает состояние TTL")
            case .unsupported:
                try require(capability == .unsupported && verification != .verified && persistence == .none && configuration.isDisabled, "Несогласованные возможности TTL")
            case .error: break
            }
        }
        return TTLStatus(state: state, configuration: configuration, capability: capability, verification: verification, persistence: persistence)
    }
}
