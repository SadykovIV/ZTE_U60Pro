import Foundation

struct ADBDeviceRecord: Equatable {
    var serial: String
    var state: String
    var usb: Bool
    var hasUSBDescriptor: Bool

    var canResolveUSB: Bool {
        !hasUSBDescriptor && !serial.contains(":") && !serial.hasPrefix("emulator-") && !serial.contains("._tcp")
    }
}

struct ADBDiscovery {
    var records: [ADBDeviceRecord]
    var usbResolutionError: String?
    var readyUSBSerials: [String] { records.filter { $0.usb && $0.state == "device" }.map(\.serial) }

    static func parse(_ data: Data) throws -> ADBDiscovery {
        try require(data.count <= 65536, "Слишком большой список ADB")
        var records = [ADBDeviceRecord]()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, ["device", "offline", "unauthorized", "no", "recovery", "sideload", "bootloader"].contains(String(fields[1])) else { continue }
            let serial = String(fields[0])
            try require(!serial.isEmpty && serial.utf8.count <= 256 && serial.utf8.allSatisfy { (33...126).contains($0) }, "Некорректный серийный номер ADB")
            let descriptors = fields.filter { $0.hasPrefix("usb:") }
            let usb = descriptors.count == 1 && String(descriptors[0]).range(of: #"^usb:[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil
            records.append(ADBDeviceRecord(serial: serial, state: fields[1] == "no" && fields.dropFirst(2).first == "permissions" ? "no permissions" : String(fields[1]), usb: usb, hasUSBDescriptor: !descriptors.isEmpty))
        }
        try require(Set(records.map(\.serial)).count == records.count, "ADB сообщает повторяющиеся серийные номера; однозначный выбор невозможен")
        return ADBDiscovery(records: records)
    }

    var explanation: String {
        var details = [String]()
        if records.contains(where: { $0.state == "unauthorized" }) { details.append("ADB обнаружен, но компьютер не авторизован (unauthorized). Разрешите отладку на модеме, если показан запрос.") }
        if records.contains(where: { $0.state == "offline" }) { details.append("ADB обнаружен, но находится в состоянии offline. Переподключите USB-кабель и повторите проверку.") }
        if records.contains(where: { $0.state == "no permissions" }) { details.append("Компьютер не имеет прав доступа к USB ADB (no permissions).") }
        if readyUSBSerials.isEmpty && records.contains(where: { $0.state == "device" }) { details.append("ADB отвечает, но физическое USB-подключение не подтверждено.") }
        if let usbResolutionError, !usbResolutionError.isEmpty { details.append(usbResolutionError) }
        if details.isEmpty { details.append(records.isEmpty ? "USB ADB не обнаружен. Нужен USB-кабель с передачей данных." : "ADB обнаружен; root-доступ и идентичность модема ещё не подтверждены.") }
        return details.joined(separator: " ")
    }
}

extension ADBClient {
    /// Some host backends omit usb: in `devices -l`. Ask ADB's USB-only
    /// selector rather than treating every serial without a colon as USB.
    func discovery() throws -> ADBDiscovery {
        var result = try ADBDiscovery.parse(command(["devices", "-l"]))
        let candidates = result.records.filter { $0.canResolveUSB && $0.state == "device" }
        if !candidates.isEmpty {
            do {
                let response = try command(["-d", "get-serialno"], timeout: 10)
                let serial = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = result.records.firstIndex(where: { $0.serial == serial && $0.canResolveUSB && $0.state == "device" }) { result.records[index].usb = true }
                else { result.usbResolutionError = "USB-селектор ADB не подтвердил устройство из текущего списка." }
            } catch { result.usbResolutionError = ActivityJournal.sanitize(error.localizedDescription) }
        }
        return result
    }
}
