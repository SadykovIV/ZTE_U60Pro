import Foundation
import CryptoKit

enum IMEIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
func require(_ condition: @autoclosure () throws -> Bool, _ text: String) throws {
    if try !condition() { throw IMEIError.message(text) }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init(hex: String) throws {
        try require(hex.count % 2 == 0 && hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Некорректные двоичные данные")
        self.init(); var i = hex.startIndex
        while i < hex.endIndex { let end = hex.index(i, offsetBy: 2); append(UInt8(hex[i..<end], radix: 16)!); i = end }
    }
    func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << (8 * $1) } }
    mutating func put32(_ offset: Int, _ value: UInt32) { for i in 0..<4 { self[offset+i] = UInt8(truncatingIfNeeded: value >> (8*i)) } }
}
enum IMEI {
    static func valid(_ text: String) -> Bool {
        guard text.utf8.count == 15, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        let digits = text.utf8.map { Int($0 - 48) }
        return digits.enumerated().reduce(0) { s, item in let v = item.offset % 2 == 1 ? item.element * 2 : item.element; return s + (v > 9 ? v - 9 : v) } % 10 == 0
    }
    static func second(_ first: String) throws -> String {
        try require(valid(first), "Первый IMEI должен содержать 15 цифр и корректную контрольную цифру")
        let tac = String(first.prefix(8)); let serial = Int(first.dropFirst(8).prefix(6))!
        try require(serial < 999999, "Серийный номер достиг 999999; введите второй IMEI вручную")
        let base = tac + String(format: "%06d", serial + 1)
        return (0...9).map { base + String($0) }.first(where: valid)!
    }
    static func decode(_ record: Data) throws -> String {
        try require(record.count == 128, "NV550 должен содержать ровно 128 байт")
        try require(record[0] == 8 && record[1] & 15 == 10, "Неизвестный формат NV550")
        var digits = [record[1] >> 4]
        for i in 2...8 { digits.append(record[i] & 15); digits.append(record[i] >> 4) }
        try require(digits.allSatisfy { $0 < 10 }, "Некорректный BCD в NV550")
        let result = digits.map(String.init).joined()
        try require(valid(result), "IMEI в NV550 не проходит контрольную сумму")
        return result
    }
    static func encode(_ text: String, preserving record: Data) throws -> Data {
        _ = try decode(record); try require(valid(text), "IMEI должен содержать 15 цифр и корректную контрольную цифру")
        let d = text.utf8.map { $0 - 48 }; var out = record
        out[0] = 8; out[1] = d[0] << 4 | 10
        for i in 0..<7 { out[i+2] = d[1+2*i] | d[2+2*i] << 4 }
        return out
    }
}
enum ConfigFile {
    static func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0
        for (i,b) in data.enumerated() {
            value ^= UInt32((12..<16).contains(i) ? 0 : b) << 24
            for _ in 0..<8 { value = value & 0x80000000 != 0 ? (value << 1) ^ 0x04c11db7 : value << 1 }
        }
        return value
    }
    static func validate(_ data: Data) throws -> UInt8 {
        try require(data.count == 15073, "Размер config отличается от проверенной B31")
        try require(data.u32(0) == 0x78563412 && data.u32(4) == 249 && data.u32(8) == data.count, "Неизвестный заголовок config B31")
        try require(data.u32(12) == crc(data) && data.u32(data.count-4) == 0x21436587, "Повреждён CRC или конец config")
        var offset = 16; var flag: UInt8?; var ids = Set<UInt32>()
        for index in 0..<249 {
            try require(offset + 16 <= data.count - 4, "Обрезанный config")
            let id = data.u32(offset), length = Int(data.u32(offset+4))
            try require(length >= 16 && offset + length <= data.count - 4 && data.u32(offset+8) == 0x18080820, "Неверная запись config")
            try require(id <= 65535, "Неизвестный ID config")
            try require(ids.insert(id).inserted, "Повтор ID в config")
            if id == 102 {
                try require(index == 5 && offset == 483 && length == 17 && data.u32(offset+12) == 0 && data[offset+16] <= 1, "Неизвестная структура флага config102")
                flag = data[offset+16]
            }
            offset += length
        }
        try require(offset == data.count - 4 && flag != nil, "Не найден однозначный config102")
        return flag!
    }
    static func candidate(_ original: Data) throws -> Data {
        let flag = try validate(original); try require(flag == 0, "В config уже включён флаг записи. Продолжите незавершённую операцию")
        var result = original; result[499] = 1; result.put32(12, crc(result)); _ = try validate(result); return result
    }
}
struct Connection: Codable, Sendable {
    var host: String; var port: String; var keyPath: String; var knownHostsPath: String
    // Explicit session-only consent: never restored from settings or transaction JSON.
    var skipFirmwareCheck = false
    enum CodingKeys: String, CodingKey { case host, port, keyPath, knownHostsPath }
    /// Preserve a user's still-readable legacy trust file. Never populate a new
    /// known_hosts file or replace its contents while restoring preferences.
    static func restoredKnownHostsPath(_ saved: String, fallback: String) -> String {
        guard saved.hasSuffix("/Contents/Resources/trusted_known_hosts") else { return saved }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: saved, isDirectory: &directory) && !directory.boolValue &&
            FileManager.default.isReadableFile(atPath: saved) ? saved : fallback
    }
    func validate() throws {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        try require(parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && (Int($0) ?? 256) <= 255 }, "Введите IPv4-адрес модема")
        try require(Int(port).map { (1...65535).contains($0) } == true, "Некорректный SSH-порт")
        for path in [keyPath, knownHostsPath] { try require(path.hasPrefix("/") && !path.contains("\n") && !path.contains("\r") && !path.contains("\0") && FileManager.default.isReadableFile(atPath: path), "Файл SSH не найден: \(path)") }
    }
}
enum FirmwareCheck {
    static let warning = "Проверка прошивки отключена. Все действия выполняются на свой страх и риск. Несовместимая прошивка может привести к потере данных, повреждению или полной неработоспособности модема."
    static func hash(_ line: String, path: String) throws -> String {
        let fields = line.split(whereSeparator: \.isWhitespace)
        try require(fields.count == 2 && fields[1] == Substring(path), "Не удалось прочитать контрольную сумму компонента прошивки")
        let value = String(fields[0])
        try require(value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Некорректная контрольная сумма прошивки")
        return value
    }
}
struct Identity: Codable, Equatable, Sendable { var cid: String; var firmwareHash: String }
struct DeviceState: Sendable { var identity: Identity; var boot: String; var records: [Data]; var imeis: [String] }
struct BackupManifest: Codable, Sendable {
    var schema = 1; var id: String; var created: String; var identity: Identity; var imeis: [String]; var hashes: [String:String]
    var scope = "Полные NV550 обоих слотов и EFS config. Не QCN и не образ всех разделов."
}
struct BackupItem: Identifiable, Sendable { var id: String; var date: String; var imei1: String; var imei2: String; var url: URL }
struct Transaction: Codable, Sendable {
    var schema = 1; var id: String; var backupID: String; var identity: Identity; var targetHex: [String]; var connection: Connection
    var phase: String; var finalBootBefore: String?; var completed = false
}
func secureDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}
func savePrivate(_ data: Data, _ url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
func saveJSON<T: Encodable>(_ value: T, _ url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try savePrivate(encoder.encode(value), url)
}
func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
