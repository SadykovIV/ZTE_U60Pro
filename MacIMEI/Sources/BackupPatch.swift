import Foundation
import CryptoKit
import CommonCrypto
import Security
import zlib

/// B31 web-backup codec. All archives stay in memory; no entry is ever extracted
/// into the Mac filesystem. The only configuration change is the rc.local line.
enum BackupPatch {
    struct Result: Sendable {
        let originalOuter: Data
        let patchedEncrypted: Data
        let alreadyEnabled: Bool
        let originalHash: String
        let patchedHash: String
    }

    static let innerPath = "tmp/back_parameter_r1.tgz"
    static let md5Path = "tmp/back_parameter_r.md5"
    static let rcPath = "etc/rc.local"
    static let usbNode = "/sys/class/android_usb/android0/usb_op"
    static let enableLine = "echo 1 > \(usbNode)\n"

    static func prepare(encrypted: Data, imei: String, suffix: String) throws -> Result {
        try require(IMEI.valid(imei), "IMEI устройства не проходит проверку формата и Luhn")
        try require(!suffix.isEmpty && suffix.utf8.count <= 128 && !suffix.contains("\0"), "Некорректный Backup-key suffix")
        let password = imei + suffix
        let originalOuter = try BackupCipher.decrypt(encrypted, password: password)
        let original = try inspect(originalOuter)
        let rcMember = original.inner.members.first { $0.path == rcPath }!
        let patchedRC = try enableADB(rcMember.bytes)
        if patchedRC == rcMember.bytes {
            return Result(originalOuter: originalOuter, patchedEncrypted: encrypted, alreadyEnabled: true,
                          originalHash: digest(encrypted), patchedHash: digest(encrypted))
        }
        let innerTar = try original.inner.replacing([rcPath: patchedRC])
        let patchedInner = try BackupGzip.compress(innerTar)
        let newMD5 = Data((BackupCipher.md5(patchedInner) + "\n").utf8)
        let outerTar = try original.outer.replacing([innerPath: patchedInner, md5Path: newMD5])
        let patchedOuter = try BackupGzip.compress(outerTar)
        let verified = try inspect(patchedOuter)
        try original.inner.verify(verified.inner, changes: [rcPath: patchedRC])
        try original.outer.verify(verified.outer, changes: [innerPath: patchedInner, md5Path: newMD5])
        let patchedEncrypted = try BackupCipher.encrypt(patchedOuter, password: password)
        try require(try BackupCipher.decrypt(patchedEncrypted, password: password) == patchedOuter,
                    "Проверка шифрования резервной копии не пройдена")
        return Result(originalOuter: originalOuter, patchedEncrypted: patchedEncrypted, alreadyEnabled: false,
                      originalHash: digest(encrypted), patchedHash: digest(patchedEncrypted))
    }

    static func inspect(_ outerGzip: Data) throws -> (outer: BackupTar, inner: BackupTar) {
        let outer = try BackupTar(BackupGzip.decompress(outerGzip))
        try require(outer.members.map(\.path) == [innerPath, md5Path] && outer.members.allSatisfy(\.isFile),
                    "Неизвестная структура внешнего архива B31")
        let compressedInner = outer.members[0].bytes
        let expectedMD5 = Data((BackupCipher.md5(compressedInner) + "\n").utf8)
        try require(outer.members[1].bytes == expectedMD5, "Контрольная сумма MD5 внутреннего архива не совпадает")
        let inner = try BackupTar(BackupGzip.decompress(compressedInner))
        guard let rc = inner.members.first(where: { $0.path == rcPath }) else {
            throw IMEIError.message("В резервной копии отсутствует etc/rc.local")
        }
        try require(rc.isFile && rc.bytes.count <= 128 * 1024, "etc/rc.local должен быть обычным файлом допустимого размера")
        return (outer, inner)
    }

    static func enableADB(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw IMEIError.message("Неизвестная кодировка rc.local") }
        let shebang = "#!/bin/sh\n"
        try require(!text.contains("\0") && text.components(separatedBy: shebang).count == 2,
                    "Неизвестный заголовок rc.local; автоматическая правка остановлена")
        guard let heading = text.range(of: shebang) else { throw IMEIError.message("Не найден заголовок rc.local") }
        // Stock B31 places two comments and an empty line before the shebang.
        // Commands before it would make the insertion point ambiguous.
        try require(text[..<heading.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).allSatisfy {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("#")
        }, "Команды перед заголовком rc.local не поддерживаются")
        let expression = try NSRegularExpression(pattern: #"/sys/[^\s`"']*usb_op[^\s`"']*"#)
        let nodes = Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        })
        try require(nodes == [usbNode], "USB-путь в rc.local отличается от проверенного B31")
        if text[heading.lowerBound...].hasPrefix(shebang + enableLine) { return data }
        try require(!text.contains(enableLine), "Строка включения ADB найдена в неоднозначном месте rc.local")
        var patched = text
        patched.insert(contentsOf: enableLine, at: heading.upperBound)
        return Data(patched.utf8)
    }
}

enum BackupCipher {
    static let encryptedLimit = 16 * 1024 * 1024
    private static let marker = Data("Salted__".utf8)

    static func md5(_ data: Data) -> String {
        // Required by the modem's archive format, not used as an authenticity check.
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func crypt(_ input: Data, password: String, salt: Data, operation: CCOperation) throws -> Data {
        try require(salt.count == 8 && !input.isEmpty && input.count <= encryptedLimit,
                    "Некорректный размер шифрованного архива")
        // OpenSSL EVP_BytesToKey, SHA-256, one iteration. 3DES key (24) + IV (8)
        // fit exactly into the first digest D1 = SHA256(password || salt).
        var material = Array(SHA256.hash(data: Data(password.utf8) + salt))
        defer { _ = material.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var output = Data(count: input.count + kCCBlockSize3DES)
        let capacity = output.count
        var written = 0
        let status = material.withUnsafeBytes { key in
            input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithm3DES), CCOptions(kCCOptionPKCS7Padding),
                            key.baseAddress, kCCKeySize3DES, key.baseAddress!.advanced(by: kCCKeySize3DES),
                            source.baseAddress, input.count, destination.baseAddress, capacity, &written)
                }
            }
        }
        try require(status == kCCSuccess, "Не удалось расшифровать резервную копию: ключ или файл не соответствует B31")
        output.removeSubrange(written..<output.count)
        return output
    }

    static func decrypt(_ encrypted: Data, password: String) throws -> Data {
        try require(encrypted.count >= 24 && encrypted.count <= encryptedLimit && encrypted.prefix(8) == marker && (encrypted.count - 16) % 8 == 0,
                    "Резервная копия не имеет ожидаемого формата OpenSSL Salted__")
        return try crypt(Data(encrypted.dropFirst(16)), password: password, salt: Data(encrypted[8..<16]), operation: CCOperation(kCCDecrypt))
    }

    static func encrypt(_ plain: Data, password: String) throws -> Data {
        var salt = Data(count: 8)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        try require(status == errSecSuccess, "Не удалось получить случайную соль для резервной копии")
        return marker + salt + (try crypt(plain, password: password, salt: salt, operation: CCOperation(kCCEncrypt)))
    }
}

enum BackupGzip {
    static let expandedLimit = 64 * 1024 * 1024
    static func decompress(_ data: Data, limit: Int = expandedLimit) throws -> Data {
        try require(data.count >= 18 && data.count <= BackupCipher.encryptedLimit && limit > 0 && limit <= expandedLimit,
                    "Недопустимый размер gzip")
        var stream = z_stream()
        try require(inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK,
                    "Не удалось подготовить чтение gzip")
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let used = buffer.count - Int(stream.avail_out)
                try require(used <= limit - result.count, "Распакованный архив превышает допустимый размер")
                result.append(contentsOf: buffer.prefix(used))
                if status == Z_STREAM_END {
                    try require(stream.avail_in == 0, "Лишние данные или второй поток после gzip")
                    return result
                }
                try require(status == Z_OK && used > 0, "Повреждён или обрезан gzip (CRC/размер)")
            }
        }
    }

    static func compress(_ data: Data) throws -> Data {
        try require(!data.isEmpty && data.count <= expandedLimit, "Недопустимый размер архива перед сжатием")
        var stream = z_stream()
        try require(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                 ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK,
                    "Не удалось подготовить сжатие gzip")
        defer { deflateEnd(&stream) }
        return try data.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(destination.count)
                    return deflate(&stream, Z_FINISH)
                }
                let used = buffer.count - Int(stream.avail_out)
                try require(used <= BackupCipher.encryptedLimit - result.count, "Сжатый архив превышает допустимый размер")
                result.append(contentsOf: buffer.prefix(used))
                if status == Z_STREAM_END { return result }
                try require(status == Z_OK && used > 0, "Ошибка сжатия резервной копии")
            }
        }
    }
}

/// Strict, bounded tar reader/repacker. Untouched records retain their original
/// bytes, including headers, local PAX metadata and padding. PAX size overrides,
/// sparse files, global headers, hardlinks and device entries are unsupported.
struct BackupTar {
    struct Member {
        let path: String
        let kind: UInt8
        let header: Data
        let bytes: Data
        let padding: Data
        let extensionRecords: Data
        let link: String
        var isFile: Bool { kind == 0 || kind == 48 }
    }
    let members: [Member]
    let footer: Data

    init(_ data: Data) throws {
        try require(data.count >= 1024 && data.count <= BackupGzip.expandedLimit && data.count % 512 == 0,
                    "Некорректный размер tar")
        var result = [Member](), offset = 0, names = Set<String>(), pending = Data(), pax = [String:String]()
        var foundFooter: Data?
        while offset + 512 <= data.count {
            let header = Data(data[offset..<offset+512])
            if header.allSatisfy({ $0 == 0 }) {
                let remainder = Data(data[offset...])
                try require(remainder.count >= 1024 && remainder.allSatisfy { $0 == 0 } && pending.isEmpty,
                            "Неоднозначный конец tar")
                foundFooter = remainder
                break
            }
            try require(result.count < 4096, "Слишком много записей tar")
            let storedChecksum = try Self.octal(header, 148..<156)
            let actualChecksum = header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
            try require(storedChecksum == actualChecksum, "Контрольная сумма заголовка tar не совпадает")
            let magic = Data(header[257..<263])
            try require(magic == Data([117,115,116,97,114,0]) || magic == Data([117,115,116,97,114,32]),
                        "Неизвестный формат tar: требуется ustar")
            let size = try Self.octal(header, 124..<136)
            try require(size <= BackupCipher.encryptedLimit, "Запись tar превышает допустимый размер")
            let padded = ((size + 511) / 512) * 512
            try require(padded <= data.count - offset - 512, "Обрезанная запись tar")
            let payload = Data(data[offset+512..<offset+512+size])
            let padding = Data(data[offset+512+size..<offset+512+padded])
            try require(padding.allSatisfy { $0 == 0 }, "Ненулевое заполнение tar")
            let kind = header[156]
            let prefix = try Self.string(header, 345..<500)
            let name = try Self.string(header, 0..<100)
            let rawPath = try Self.safePath(prefix.isEmpty ? name : prefix + "/" + name, directory: kind == 53)
            if kind == 120 {
                try require(pending.isEmpty && payload.count <= 65536, "Повторный или слишком большой PAX-заголовок")
                pax = try Self.readPAX(payload)
                pending = Data(data[offset..<offset+512+padded])
                offset += 512 + padded
                continue
            }
            try require([UInt8(0), 48, 50, 53].contains(kind), "Неподдерживаемый тип записи tar (ссылка/устройство/расширение)")
            let path = try Self.safePath(pax["path"] ?? rawPath, directory: kind == 53)
            try require(names.insert(path).inserted, "Повторный путь в tar")
            try require(kind == 0 || kind == 48 || size == 0, "У ссылки/каталога tar не должно быть данных")
            let rawLink = try Self.string(header, 157..<257)
            let link = pax["linkpath"] ?? rawLink
            if kind == 50 {
                try Self.validateLink(rawLink, at: path)
                try Self.validateLink(link, at: path)
            } else { try require(link.isEmpty && rawLink.isEmpty, "Неожиданная ссылка у обычной записи tar") }
            result.append(Member(path: path, kind: kind, header: header, bytes: payload, padding: padding, extensionRecords: pending, link: link))
            pending = Data(); pax = [:]
            offset += 512 + padded
        }
        guard let footer = foundFooter else { throw IMEIError.message("В tar отсутствует завершение") }
        let kinds = Dictionary(uniqueKeysWithValues: result.map { ($0.path, $0.kind) })
        for member in result {
            let pieces = member.path.split(separator: "/")
            for count in 1..<pieces.count {
                if let ancestor = kinds[pieces.prefix(count).joined(separator: "/")] {
                    try require(ancestor == 53, "Путь tar проходит через ссылку или обычный файл")
                }
            }
        }
        self.members = result; self.footer = footer
    }

    func replacing(_ changes: [String:Data]) throws -> Data {
        try require(Set(changes.keys).isSubset(of: Set(members.filter(\.isFile).map(\.path))), "Не найден однозначный файл для изменения tar")
        var result = Data()
        for member in members {
            result.append(member.extensionRecords)
            if let bytes = changes[member.path] {
                try require(bytes.count <= BackupCipher.encryptedLimit, "Слишком большая замена tar")
                var header = member.header
                try Self.writeOctal(bytes.count, to: &header, range: 124..<136)
                header.replaceSubrange(148..<156, with: [UInt8](repeating: 32, count: 8))
                let checksum = header.reduce(0) { $0 + Int($1) }
                header.replaceSubrange(148..<156, with: Data((String(format: "%06o", checksum) + "\0 ").utf8))
                result.append(header); result.append(bytes)
                result.append(Data(repeating: 0, count: (512 - bytes.count % 512) % 512))
            } else {
                result.append(member.header); result.append(member.bytes); result.append(member.padding)
            }
            try require(result.count <= BackupGzip.expandedLimit - footer.count, "Собранный tar превышает допустимый размер")
        }
        result.append(footer)
        return result
    }

    func verify(_ other: BackupTar, changes: [String:Data]) throws {
        try require(members.count == other.members.count && footer == other.footer, "Изменена структура tar")
        for (old, new) in zip(members, other.members) {
            try require(old.path == new.path && old.kind == new.kind && old.link == new.link && old.extensionRecords == new.extensionRecords,
                        "Изменены метаданные записи tar")
            if let expected = changes[old.path] {
                var before = old.header, after = new.header
                for range in [124..<136, 148..<156] {
                    before.replaceSubrange(range, with: Data(repeating: 0, count: range.count))
                    after.replaceSubrange(range, with: Data(repeating: 0, count: range.count))
                }
                try require(before == after && new.bytes == expected, "Неожиданное изменение данных или метаданных tar")
            } else {
                try require(old.header == new.header && old.bytes == new.bytes && old.padding == new.padding,
                            "Изменён посторонний файл резервной копии")
            }
        }
    }

    private static func string(_ data: Data, _ range: Range<Int>) throws -> String {
        let bytes = Data(data[range]), prefix = bytes.prefix { $0 != 0 }
        if let nul = bytes.firstIndex(of: 0) { try require(bytes[nul...].allSatisfy { $0 == 0 }, "Данные после NUL в поле tar") }
        guard let value = String(data: prefix, encoding: .utf8) else { throw IMEIError.message("Неизвестная кодировка пути tar") }
        return value
    }

    private static func octal(_ data: Data, _ range: Range<Int>) throws -> Int {
        let bytes = data[range]
        try require(bytes.allSatisfy { $0 == 0 || $0 == 32 || (48...55).contains($0) }, "Неизвестное числовое поле tar")
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
        try require(text.isEmpty || text.utf8.allSatisfy { (48...55).contains($0) }, "Некорректное числовое поле tar")
        guard let result = text.isEmpty ? 0 : Int(text, radix: 8) else { throw IMEIError.message("Переполнение числового поля tar") }
        return result
    }

    private static func writeOctal(_ value: Int, to data: inout Data, range: Range<Int>) throws {
        let digits = String(value, radix: 8)
        try require(digits.count < range.count, "Размер файла не помещается в заголовок tar")
        data.replaceSubrange(range, with: Data((String(repeating: "0", count: range.count-1-digits.count) + digits + "\0").utf8))
    }

    private static func safePath(_ path: String, directory: Bool = false) throws -> String {
        try require(!path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") && !path.contains("\\") && path.utf8.allSatisfy { $0 >= 32 && $0 != 127 },
                    "Небезопасный путь в tar")
        var result = path
        if result.hasPrefix("./") { result.removeFirst(2) }
        if directory && result.hasSuffix("/") { result.removeLast() }
        let parts = result.split(separator: "/", omittingEmptySubsequences: false)
        try require(!parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }, "Переход за пределы пути tar")
        return parts.joined(separator: "/")
    }

    private static func validateLink(_ target: String, at path: String) throws {
        try require(!target.isEmpty && target.utf8.count <= 4096 && !target.hasPrefix("/") && !target.contains("\\") && target.utf8.allSatisfy { $0 >= 32 && $0 != 127 },
                    "Небезопасная символическая ссылка tar")
        var stack = path.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/", omittingEmptySubsequences: false) {
            try require(!part.isEmpty, "Некорректная символическая ссылка tar")
            if part == ".." {
                try require(!stack.isEmpty, "Символическая ссылка выходит за корень tar")
                stack.removeLast()
            } else if part != "." { stack.append(String(part)) }
        }
        try require(!stack.isEmpty, "Символическая ссылка указывает на корень tar")
    }

    private static func readPAX(_ data: Data) throws -> [String:String] {
        let allowed: Set<String> = ["path", "linkpath", "uid", "gid", "uname", "gname", "mtime", "atime", "ctime", "charset", "comment"]
        var result = [String:String](), offset = 0
        while offset < data.count {
            guard let space = data[offset...].firstIndex(of: 32), space - offset <= 6 else { throw IMEIError.message("Некорректная длина PAX") }
            let digits = data[offset..<space]
            try require(!digits.isEmpty && digits.allSatisfy { (48...57).contains($0) }, "Некорректная длина PAX")
            guard let size = Int(String(decoding: digits, as: UTF8.self)) else { throw IMEIError.message("Некорректная длина PAX") }
            try require(size > space - offset + 3 && size <= data.count - offset && data[offset+size-1] == 10, "Обрезанный PAX")
            let body = Data(data[space+1..<offset+size-1])
            guard let equal = body.firstIndex(of: 61), let key = String(data: body[..<equal], encoding: .utf8),
                  let value = String(data: body[body.index(after: equal)...], encoding: .utf8) else { throw IMEIError.message("Некорректный PAX") }
            try require(allowed.contains(key) && result[key] == nil && !value.contains("\0") && !value.contains("\n"),
                        "Неподдерживаемый или повторный атрибут PAX")
            result[key] = value
            offset += size
        }
        return result
    }
}
