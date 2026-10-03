import Foundation

/// A measured access identity. This is never an IMEI/NV compatibility grant.
/// Missing component files are distinguished from unreadable or unsafe files.
enum AccessIdentity {
    static let command = """
    set -eu
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
    test "$(id -u)" = 0
    test "$(uname -s)" = Linux
    test "$(uname -m)" = aarch64
    zte_observed_hash() {
      zte_path=$1; zte_cursor=/; zte_rest=${zte_path#/}
      test -d / && test -r / && test -x / || return 71
      while :; do
        case "$zte_rest" in */*) zte_part=${zte_rest%%/*}; zte_rest=${zte_rest#*/};; *) break;; esac
        zte_cursor=${zte_cursor%/}/$zte_part
        test ! -L "$zte_cursor" || return 71
        if ! test -e "$zte_cursor"; then printf 'absent  %s\\n' "$zte_path"; return 0; fi
        test -d "$zte_cursor" && test -r "$zte_cursor" && test -x "$zte_cursor" || return 71
      done
      test ! -L "$zte_path" || return 71
      if test -e "$zte_path"; then
        test -f "$zte_path" && test -r "$zte_path" || return 71
        sha256sum "$zte_path" || return 71
      else
        printf 'absent  %s\\n' "$zte_path"
      fi
    }
    zte_observed_hash /firmware/image/modem.b16 || exit 71
    zte_observed_hash /usr/bin/diag-router || exit 71
    cat /sys/block/mmcblk0/device/cid /proc/sys/kernel/random/boot_id
    """
    static let optionalWebCommand = command + "; if command -v ubus >/dev/null 2>&1; then ubus call zwrt_web device_info '{}' 2>/dev/null || :; fi"
    static func parseObservation(_ data: Data, requireWeb: Bool) throws -> DiagnosticDeviceProof {
        if requireWeb { return try parse(data, requireWeb: true) }
        try require(data.count <= 65536 && !data.contains(0), "Неверный ответ проверки доступа")
        let lines = CommandText.decode(data).split(separator: "\n").map(String.init)
        var proof = try parse(Data(lines.prefix(4).joined(separator: "\n").utf8))
        if lines.count > 4, let object = try? JSONSerialization.jsonObject(with: Data(lines.dropFirst(4).joined(separator: "\n").utf8)) as? [String: Any] {
            proof.webIdentity = try? WebIdentity(object, skipFirmwareCheck: true)
        }
        return proof
    }
    static func observedHash(_ line: String, path: String) throws -> String {
        if line == "absent  " + path { return "absent" }
        return try FirmwareCheck.hash(line, path: path)
    }
    static func parse(_ data: Data, requireWeb: Bool = false) throws -> DiagnosticDeviceProof {
        try require(data.count <= 65536 && !data.contains(0), "Неверный ответ проверки доступа")
        let lines = CommandText.decode(data).split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        try require(lines.count >= 4 && (requireWeb || lines.count == 4), "Неполная идентификация доступа")
        let firmware = try observedHash(lines[0], path: "/firmware/image/modem.b16")
        let router = try observedHash(lines[1], path: "/usr/bin/diag-router")
        let cid = lines[2], boot = lines[3]
        try require(cid.count == 32 && cid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && boot.range(of: #"^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$"#, options: .regularExpression) != nil && UUID(uuidString: boot) != nil, "Для установки доступа нужны CID и boot ID")
        var web: WebIdentity?
        if requireWeb {
            guard let object = try JSONSerialization.jsonObject(with: Data(lines.dropFirst(4).joined(separator: "\n").utf8)) as? [String: Any] else { throw IMEIError.message("Не получена идентификация Web через выбранный транспорт") }
            web = try WebIdentity(object, skipFirmwareCheck: true)
        }
        return .init(identity: .init(cid: cid, firmwareHash: firmware), routerHash: router, bootID: boot, webIdentity: web)
    }
    static func profile(_ proof: DiagnosticDeviceProof, experimental: Bool) -> String {
        guard proof.routerHash == ModemEngine.routerHash else { return "linux-arm64-access" }
        if proof.identity.firmwareHash == ModemEngine.firmwareHash { return "b31" }
        if experimental && proof.identity.firmwareHash == OnboardingEngine.b02FirmwareHash { return "b02-experimental" }
        return "linux-arm64-access"
    }
    static func policyArguments(_ proof: DiagnosticDeviceProof, profile: String) -> [String] {
        [proof.identity.cid, profile, proof.identity.firmwareHash, proof.routerHash] + (profile == "linux-arm64-access" ? [proof.bootID] : [])
    }
}

extension ModemEngine {
    func measuredIdentity() throws -> DiagnosticDeviceProof {
        try AccessIdentity.parse(remote(AccessIdentity.command, timeout: 20))
    }
    func accessIdentity() throws -> (Identity, String) {
        let proof = try measuredIdentity()
        return (proof.identity, proof.bootID)
    }
}
