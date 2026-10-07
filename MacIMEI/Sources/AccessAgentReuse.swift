import Foundation

/// Access verification only. This grants neither an update nor feature/NV compatibility.
/// The previous binary is pinned by the preserved local 2.7.0-esim.8 release,
/// independently of any hash reported by a connected device.
enum AccessAgentReusePolicy {
    static let previousSHA256 = "e9f3e2170a7a2fa80a4836fd7d0db92c4aa119b4b8cceaa0907450123de29d19"
    // Published v1.23.2 PROVENANCE.json names this independent public build.
    static let publishedPreviousSHA256 = "8ee8073b684613f358a5b857f7ed85ac165fc96f0d74980b04be006659ebea67"
    static func allowedHashes(latest: String, proof: DiagnosticDeviceProof, profile: String, reuseExisting: Bool) -> Set<String> {
        var values: Set<String> = [latest]
        if reuseExisting && profile == "b31" && proof.identity.firmwareHash == ModemEngine.firmwareHash && proof.routerHash == ModemEngine.routerHash {
            values.formUnion([previousSHA256, publishedPreviousSHA256])
        }
        return values
    }
}

struct AccessAgentProcessProof: Equatable {
    let pid: String
    let startTime: String
    let diskHash: String
    let mappedHash: String
    static func parse(_ data: Data, allowedHashes: Set<String>) throws -> Self {
        let text = CommandText.decode(data), lines = text.split(whereSeparator: \.isNewline)
        try require(lines.count == 1, "Не подтверждён единственный процесс установленного агента")
        let fields = lines[0].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        try require(fields.count == 5 && fields[0] == "AGENT_ACCESS_READY", "Не подтверждён процесс установленного агента")
        func canonical(_ value: String) -> Bool { guard let number = UInt64(value) else { return false }; return number > 0 && String(number) == value }
        try require(canonical(fields[1]) && UInt64(fields[1])! <= UInt64(Int32.max) && canonical(fields[2]) &&
                    fields[3].range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil && fields[3] == fields[4] && allowedHashes.contains(fields[3]),
                    "Не подтверждена разрешённая сборка файла и работающего процесса агента")
        return .init(pid: fields[1], startTime: fields[2], diskHash: fields[3], mappedHash: fields[4])
    }
    static func command() -> String {
        return """
        set -eu
        test -f /data/zte-agent && test ! -L /data/zte-agent || exit 72
        disk=$(sha256sum /data/zte-agent); disk=${disk%% *}
        found=0; selected=; started=; mapped=
        for p in $(pidof zte-agent); do
          case "$p" in ''|*[!0-9]*) exit 72;; esac
          if test "$(readlink /proc/$p/exe)" = /data/zte-agent; then
            mapped=$(sha256sum /proc/$p/exe); mapped=${mapped%% *}
            test "$disk" = "$mapped" || exit 72
            state=$(cat /proc/$p/stat)
            case "$state" in "$p (zte-agent) "*) ;; *) exit 72;; esac
            rest=${state#*) }; set -- $rest
            test "$#" -ge 20 || exit 72
            shift 19; started=$1
            case "$started" in ''|*[!0-9]*) exit 72;; esac
            selected=$p; found=$((found + 1))
          fi
        done
        test "$found" = 1 || exit 72
        printf 'AGENT_ACCESS_READY %s %s %s %s\\n' "$selected" "$started" "$disk" "$mapped"
        """
    }
}
