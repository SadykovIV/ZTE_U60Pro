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


/// Facts observed over an authenticated, host-key-checked SSH connection.
/// Missing facts reduce attribution; they never authorize an installer or write.
struct SSHReadProof: Equatable, Sendable {
    var uid: String?
    var system: String?
    var architecture: String?
    var cid: String?
    var bootID: String?
    var firmwareHash: String?
    var routerHash: String?
    var identity: Identity? {
        guard let cid, let firmwareHash else { return nil }
        return Identity(cid: cid, firmwareHash: firmwareHash)
    }
    var completeProof: DiagnosticDeviceProof? {
        guard let identity, let routerHash, let bootID else { return nil }
        return DiagnosticDeviceProof(identity: identity, routerHash: routerHash, bootID: bootID)
    }
    init(uid: String? = nil, system: String? = nil, architecture: String? = nil, cid: String? = nil,
         bootID: String? = nil, firmwareHash: String? = nil, routerHash: String? = nil) {
        self.uid = uid; self.system = system; self.architecture = architecture; self.cid = cid
        self.bootID = bootID; self.firmwareHash = firmwareHash; self.routerHash = routerHash
    }
    init(_ proof: DiagnosticDeviceProof) {
        self.init(cid: proof.identity.cid, bootID: proof.bootID, firmwareHash: proof.identity.firmwareHash, routerHash: proof.routerHash)
    }
    /// Compare every fact initially observed. An unavailable fact stays unknown.
    func verify(_ current: SSHReadProof) throws {
        for (before, after) in [(uid,current.uid),(system,current.system),(architecture,current.architecture),
                                (cid,current.cid),(bootID,current.bootID),(firmwareHash,current.firmwareHash),(routerHash,current.routerHash)] {
            if let before { try require(after == before, "Устройство или сеанс SSH изменились; дальнейшее чтение остановлено") }
        }
    }
    func matches(_ expected: DiagnosticDeviceExpectation) -> Bool {
        // SSH host-key authentication binds the selected endpoint. Compare a
        // saved hardware fact when the current device can expose that fact.
        cid.map { expected.cids.isEmpty || expected.cids.contains($0) } ?? true
    }
    static let command = """
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
    zte_read_fact() { value=$("$@" 2>/dev/null) || value=; case "$value" in ''|*[!A-Za-z0-9_.-]*) printf '?\\n';; *) test "${#value}" -le 128 && printf '%s\\n' "$value" || printf '?\\n';; esac; }
    zte_read_hash() {
      p=$1
      if test -L "$p"; then printf '?\\n'
      elif test -f "$p" && test -r "$p"; then
        h=$(sha256sum "$p" 2>/dev/null) || h=
        h=${h%% *}; case "$h" in ''|*[!0-9a-f]*) printf '?\\n';; *) test "${#h}" = 64 && printf '%s\\n' "$h" || printf '?\\n';; esac
      elif test ! -e "$p" && test -r "${p%/*}" && test -x "${p%/*}"; then printf 'absent\\n'
      else printf '?\\n'; fi
    }
    printf 'ZTE_SSH_READ_V1\\n'
    zte_read_fact id -u
    zte_read_fact uname -s
    zte_read_fact uname -m
    zte_read_fact cat /sys/block/mmcblk0/device/cid
    zte_read_fact cat /proc/sys/kernel/random/boot_id
    zte_read_hash /firmware/image/modem.b16
    zte_read_hash /usr/bin/diag-router
    """
    static func parse(_ bytes: Data) throws -> Self {
        try require(bytes.count <= 4096 && !bytes.contains(0), "Неверный ответ проверки SSH")
        let lines = CommandText.decode(bytes).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let fields = lines.last == "" ? Array(lines.dropLast()) : lines
        try require(fields.count == 8 && fields[0] == "ZTE_SSH_READ_V1", "Неполный ответ проверки SSH")
        let values = Array(fields.dropFirst()).map { $0 == "?" ? nil : Optional($0) }
        func valid(_ value: String?, pattern: String) -> Bool { value == nil || value!.range(of: pattern, options: .regularExpression) != nil }
        try require(valid(values[0], pattern: "^[0-9]{1,10}$") && valid(values[1], pattern: "^[A-Za-z0-9_.-]{1,128}$") &&
                    valid(values[2], pattern: "^[A-Za-z0-9_.-]{1,128}$") && valid(values[3], pattern: "^[0-9a-f]{32}$") &&
                    valid(values[4], pattern: "^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$") &&
                    valid(values[5], pattern: "^(?:absent|[0-9a-f]{64})$") && valid(values[6], pattern: "^(?:absent|[0-9a-f]{64})$"), "Некорректные сведения SSH")
        return Self(uid:values[0],system:values[1],architecture:values[2],cid:values[3],bootID:values[4],firmwareHash:values[5],routerHash:values[6])
    }
}
