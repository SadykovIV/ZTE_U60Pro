import Foundation
import Darwin

private enum Failure: Error { case check(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
    if try !value() { throw Failure.check(text) }
}
private func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch is Failure { throw Failure.check("Test assertion failed inside rejection") } catch { return }
    throw Failure.check("Malformed input unexpectedly accepted")
}

private struct Entry {
    var name: String
    var bytes: Data = Data()
    var kind: UInt8 = 48
    var link = ""
}

/// Independent synthetic ustar fixture builder; contains no device configuration.
private func tar(_ entries: [Entry]) -> Data {
    var result = Data()
    for entry in entries {
        var header = Data(repeating: 0, count: 512)
        func put(_ offset: Int, _ text: String) { header.replaceSubrange(offset..<offset+text.utf8.count, with: text.utf8) }
        put(0, entry.name); put(100, "0000775\0"); put(108, "0000000\0"); put(116, "0000000\0")
        put(124, String(format: "%011o", entry.bytes.count) + "\0"); put(136, "15100000000\0")
        put(148, "        "); header[156] = entry.kind; put(157, entry.link)
        put(257, "ustar\0"); put(263, "00"); put(265, "root"); put(297, "root")
        put(148, String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ")
        result.append(header); result.append(entry.bytes)
        result.append(Data(repeating: 0, count: (512 - entry.bytes.count % 512) % 512))
    }
    result.append(Data(repeating: 0, count: 2048))
    return result
}

private func pax(_ key: String, _ value: String) -> Data {
    let body = " \(key)=\(value)\n"
    var length = body.utf8.count + 1
    while String(length).utf8.count + body.utf8.count != length { length = String(length).utf8.count + body.utf8.count }
    return Data((String(length) + body).utf8)
}

private let imei = "490154203237518"
private let suffix = "synthetic-backup-suffix"
private let rc = try! Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/stock-usb-mode.synthetic.rc.local"))
private func entries(_ replacement: Data = rc) -> [Entry] {
    [Entry(name: "etc/config/test", bytes: Data("synthetic value\n".utf8)),
     Entry(name: BackupPatch.rcPath, bytes: replacement),
     Entry(name: "etc/udhcp/test", kind: 50, link: "../../sbin/test")]
}
private func outer(_ entries: [Entry], badMD5: Bool = false) throws -> Data {
    let inner = try BackupGzip.compress(tar(entries))
    return try BackupGzip.compress(tar([
        Entry(name: BackupPatch.innerPath, bytes: inner),
        Entry(name: BackupPatch.md5Path, bytes: Data(((badMD5 ? String(repeating: "0", count: 32) : BackupCipher.md5(inner)) + "\n").utf8))
    ]))
}
private func encrypted(_ entries: [Entry] = entries(), badMD5: Bool = false) throws -> Data {
    try BackupCipher.encrypt(outer(entries, badMD5: badMD5), password: imei + suffix)
}

@main struct BackupPatchTests {
    static func main() throws {
        var passed = 0, failed = 0
        func run(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        run("Executable stock USB block required before enabling the boot adapter") {
            let body = String(decoding:rc,as:UTF8.self).replacingOccurrences(of:"#!/bin/sh\n",with:"")
            for fake in ["#!/bin/sh\n# " + BackupPatch.usbNode + "\nexit 0\n", "#!/bin/sh\necho '" + BackupPatch.usbNode + "'\nexit 0\n", "#!/bin/sh\ncat <<'EOF'\n" + body + "EOF\n", "#!/bin/sh\nnode='" + BackupPatch.usbNode + "'\n" + body, String(decoding:rc,as:UTF8.self)+"echo 0 > " + BackupPatch.usbNode + "\n", String(decoding:rc,as:UTF8.self).replacingOccurrences(of:"if [ -f /tmp/fota_install_processing ]; then",with:"if false; then")] {
                try rejects { _ = try BackupPatch.prepare(encrypted:encrypted(entries(Data(fake.utf8))),imei:imei,suffix:suffix) }
            }
            let patched = try BackupPatch.enableADB(rc)
            try check(patched == Data(("#!/bin/sh\n"+BackupPatch.enableLine).utf8) + rc.dropFirst("#!/bin/sh\n".utf8.count), "Stock tail or block was changed")
            try check(try BackupPatch.enableADB(patched) == patched,"Recognized prefix was not idempotent")
        }
        run("Stock grammar uses shell ASCII whitespace only") {
            let text=String(decoding:rc,as:UTF8.self)
            for prefix in ["\u{00a0}","\u{000c}","\r"] {
                let altered=text.replacingOccurrences(of:"if [ x`cat",with:prefix+"if [ x`cat")
                try rejects { _ = try BackupPatch.enableADB(Data(altered.utf8)) }
            }
            let spaced=text.replacingOccurrences(of:"if [ x`cat",with:" \tif  [ x`cat")
            let modified=try BackupPatch.enableADB(Data(spaced.utf8))
            try check(modified == Data(("#!/bin/sh\n"+BackupPatch.enableLine).utf8)+Data(spaced.utf8).dropFirst("#!/bin/sh\n".utf8.count),"ASCII whitespace changed the preserved block")
        }
        run("OpenSSL 3DES SHA256 known vector") {
            let vector = try Data(hex: "53616c7465645f5f0102030405060708dfdd29b2bf3250ec90f326f288ce2986644b9e7978318c0b")
            try check(try BackupCipher.decrypt(vector, password: "synthetic-password") == Data("B31 test payload\n".utf8), "OpenSSL compatibility")
        }
        run("Native cipher random salt and full roundtrip") {
            let plain = Data((0..<10000).map { UInt8(truncatingIfNeeded: $0) })
            let first = try BackupCipher.encrypt(plain, password: "synthetic-password")
            let second = try BackupCipher.encrypt(plain, password: "synthetic-password")
            try check(first != second, "Fresh salt per encryption")
            try check(try BackupCipher.decrypt(first, password: "synthetic-password") == plain, "Full plaintext roundtrip")
            // CBC/PKCS7 itself is not authenticated; the complete prepare path
            // additionally requires valid gzip CRC, tar structure and inner MD5.
        }
        run("Malformed envelope and length rejection") {
            try rejects { _ = try BackupCipher.decrypt(Data(), password: "x") }
            var value = try encrypted(); value[0] ^= 1
            try rejects { _ = try BackupCipher.decrypt(value, password: "x") }
            value = try encrypted(); value.removeLast()
            try rejects { _ = try BackupCipher.decrypt(value, password: "x") }
        }
        run("Gzip CRC truncation concatenation and bomb limits") {
            let plain = Data(repeating: 42, count: 100000)
            let good = try BackupGzip.compress(plain)
            try check(try BackupGzip.decompress(good) == plain, "gzip roundtrip")
            var bad = good; bad[bad.count - 8] ^= 1
            try rejects { _ = try BackupGzip.decompress(bad) }
            try rejects { _ = try BackupGzip.decompress(Data(good.dropLast())) }
            try rejects { _ = try BackupGzip.decompress(good + good) }
            try rejects { _ = try BackupGzip.decompress(good, limit: 99999) }
            try check(try BackupGzip.decompress(good, limit: 100000) == plain, "Exact limit accepted")
        }
        run("Complete encrypted backup patch preserves every other byte") {
            let source = try encrypted()
            let result = try BackupPatch.prepare(encrypted: source, imei: imei, suffix: suffix)
            let old = try BackupPatch.inspect(result.originalOuter)
            let patchedOuter = try BackupCipher.decrypt(result.patchedEncrypted, password: imei + suffix)
            let new = try BackupPatch.inspect(patchedOuter)
            let expected = Data(("#!/bin/sh\n" + BackupPatch.enableLine).utf8) + rc.dropFirst(10)
            try old.inner.verify(new.inner, changes: [BackupPatch.rcPath: expected])
            try check(!result.alreadyEnabled && result.originalHash == digest(source) && result.patchedHash == digest(result.patchedEncrypted), "Hash/result contract")
            try check(new.inner.members[2].link == "../../sbin/test", "Safe existing link unchanged")
        }
        run("Already enabled archive is byte-identical and idempotent") {
            let first = try BackupPatch.prepare(encrypted: encrypted(), imei: imei, suffix: suffix)
            let second = try BackupPatch.prepare(encrypted: first.patchedEncrypted, imei: imei, suffix: suffix)
            try check(second.alreadyEnabled && second.patchedEncrypted == first.patchedEncrypted && second.originalHash == second.patchedHash, "Idempotent backup")
        }
        run("Wrong suffix invalid IMEI and empty suffix fail closed") {
            let source = try encrypted()
            try rejects { _ = try BackupPatch.prepare(encrypted: source, imei: imei, suffix: suffix + "wrong") }
            try rejects { _ = try BackupPatch.prepare(encrypted: source, imei: "490154203237519", suffix: suffix) }
            try rejects { _ = try BackupPatch.prepare(encrypted: source, imei: imei, suffix: "") }
        }
        run("Inner MD5 mismatch fails before patch") {
            try rejects { _ = try BackupPatch.prepare(encrypted: encrypted(badMD5: true), imei: imei, suffix: suffix) }
        }
        run("Duplicate rc.local rejected") {
            var value = entries(); value.append(Entry(name: BackupPatch.rcPath, bytes: rc))
            try rejects { _ = try BackupPatch.prepare(encrypted: encrypted(value), imei: imei, suffix: suffix) }
        }
        run("Path traversal absolute and normalized duplicate rejected") {
            for path in ["../etc/rc.local", "/etc/rc.local", "etc/../rc.local", "etc//rc.local", "etc\\rc.local"] {
                try rejects { _ = try BackupTar(tar([Entry(name: path, bytes: rc)])) }
            }
            try rejects { _ = try BackupTar(tar([Entry(name: "etc/rc.local"), Entry(name: "./etc/rc.local")])) }
        }
        run("Symlink and hardlink target rc.local rejected") {
            for kind: UInt8 in [49, 50] {
                var value = entries(); value[1] = Entry(name: BackupPatch.rcPath, kind: kind, link: "config/test")
                try rejects { _ = try BackupPatch.prepare(encrypted: encrypted(value), imei: imei, suffix: suffix) }
            }
        }
        run("Link escapes and symlink ancestors rejected in either order") {
            for link in ["../../../outside", "/outside", "../.."] {
                try rejects { _ = try BackupTar(tar([Entry(name: "etc/test/link", kind: 50, link: link)])) }
            }
            let ancestor = Entry(name: "etc", kind: 50, link: "target")
            let child = Entry(name: "etc/rc.local", bytes: rc)
            try rejects { _ = try BackupTar(tar([ancestor, child])) }
            try rejects { _ = try BackupTar(tar([child, ancestor])) }
        }
        run("Tar header checksum truncation trailer and padding guards") {
            let original = tar(entries())
            var bad = original; bad[100] ^= 1
            try rejects { _ = try BackupTar(bad) }
            try rejects { _ = try BackupTar(Data(original.dropLast(1))) }
            bad = original; bad[bad.count - 1] = 1
            try rejects { _ = try BackupTar(bad) }
            bad = original; bad[512 + entries()[0].bytes.count] = 1
            try rejects { _ = try BackupTar(bad) }
        }
        run("PAX metadata remains exact on changed file") {
            let attributes = pax("mtime", "1720000000.123456") + pax("comment", "synthetic test metadata")
            let old = try BackupTar(tar([Entry(name: "PaxHeaders/rc.local", bytes: attributes, kind: 120), Entry(name: BackupPatch.rcPath, bytes: rc)]))
            let updated = try BackupPatch.enableADB(rc)
            let new = try BackupTar(old.replacing([BackupPatch.rcPath: updated]))
            try old.verify(new, changes: [BackupPatch.rcPath: updated])
            try check(old.members[0].extensionRecords == new.members[0].extensionRecords, "Raw PAX bytes")
        }
        run("PAX path traversal sparse size and duplicate keys rejected") {
            let attributes = [pax("path", "../etc/rc.local"), pax("GNU.sparse.map", "0,512"), pax("size", "1"), pax("mtime", "1") + pax("mtime", "2")]
            for attr in attributes {
                try rejects { _ = try BackupTar(tar([Entry(name: "PaxHeaders/rc", bytes: attr, kind: 120), Entry(name: BackupPatch.rcPath, bytes: rc)])) }
            }
        }
        run("PAX and global metadata ambiguity rejected") {
            try rejects { _ = try BackupTar(tar([Entry(name: "PaxHeaders/rc", bytes: pax("mtime", "1"), kind: 120)])) }
            try rejects { _ = try BackupTar(tar([Entry(name: "Global", bytes: pax("path", "etc/rc.local"), kind: 103)])) }
            try rejects { _ = try BackupTar(tar([Entry(name: "A", bytes: pax("mtime", "1"), kind: 120), Entry(name: "B", bytes: pax("mtime", "2"), kind: 120), Entry(name: BackupPatch.rcPath, bytes: rc)])) }
        }
        run("Missing unknown or ambiguous rc.local stops patch") {
            try rejects { _ = try BackupPatch.prepare(encrypted: encrypted([Entry(name: "etc/test")]), imei: imei, suffix: suffix) }
            for invalid in [Data("#!/bin/bash\ncat \(BackupPatch.usbNode)\n".utf8),
                            Data("#!/bin/sh\ncat /sys/unknown/usb_op\n".utf8),
                            Data(("#!/bin/sh\nexit 0\n" + BackupPatch.enableLine).utf8),
                            rc + Data("#!/bin/sh\n".utf8), rc + Data([0])] {
                try rejects { _ = try BackupPatch.enableADB(invalid) }
            }
        }
        run("Unexpected outer structure rejected") {
            let value = try BackupGzip.compress(tar([Entry(name: "tmp/unexpected", bytes: Data("x".utf8))]))
            try rejects { _ = try BackupPatch.inspect(value) }
        }

        print("BackupPatch tests: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
