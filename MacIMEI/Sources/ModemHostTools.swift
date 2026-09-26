import Foundation

/// Small, private host tools used by installers on firmware with a reduced BusyBox.
enum ModemHostTools {
    static let timeoutHash = "6e81024c273080294a251ae38572f1ef0cb496fbd16c7009c6a4ae1c07fb55ff"

    static func stageTimeout(engine: ModemEngine, stage: String) throws {
        try require(engine.lockFD >= 0, "Передача инструмента установки требует блокировки операции")
        let prefix: String
        if stage.hasPrefix("/tmp/zte-diag-") { prefix = "/tmp/zte-diag-" }
        else if stage.hasPrefix("/tmp/zte-opkg-") { prefix = "/tmp/zte-opkg-" }
        else { throw IMEIError.message("Неверный временный каталог инструмента установки") }
        let suffix = String(stage.dropFirst(prefix.count))
        try require(suffix.count == 36 && suffix == suffix.lowercased() && UUID(uuidString: suffix) != nil,
                    "Неверный временный каталог инструмента установки")
        let binary = try DeviceBackups.smallFile(engine.resources.appendingPathComponent("HostTools/zte-timeout"),
                                                maximum: 256 * 1024, publicResource: true)
        try require(digest(binary) == timeoutHash, "Повреждён встроенный инструмент ограничения времени")
        let path = stage + "/zte-timeout"
        let command = "set -eu; umask 077; test -d " + shellQuote(stage) + "; test ! -L " + shellQuote(stage)
            + "; test \"$(stat -c %u:%a " + shellQuote(stage) + ")\" = 0:700; set -C; cat > "
            + shellQuote(path) + "; chmod 700 " + shellQuote(path) + "; sha256sum " + shellQuote(path)
        let raw = try engine.remote(command, input: binary, timeout: 30)
        let receipt = String(decoding: raw, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        try require(receipt.count == 2 && receipt[0] == Substring(timeoutHash) && receipt[1] == Substring(path),
                    "Не совпала SHA256 переданного инструмента ограничения времени")
    }
}
