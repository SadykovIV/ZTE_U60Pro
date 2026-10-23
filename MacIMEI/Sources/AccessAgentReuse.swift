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
    /// Fixed, read-only proof for recovery of a committed agent that stopped.
    /// A failed transport or an unreadable live process never proves absence.
    static func absenceCommand(expectedHash: String) throws -> String {
        try require(expectedHash.utf8.count == 64 && expectedHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                    "Повреждён журнал замены")
        return #"""
        set -eu
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
        expected=EXPECTED_AGENT_SHA
        absent_fail() { exit 73; }
        absent_file() {
          test -d /data && test ! -L /data && test -r /data && test -x /data && test "$(stat -c %u /data)" = 0 || absent_fail
          if test ! -e /data/zte-agent && test ! -L /data/zte-agent; then
            file_state=missing
            return
          fi
          test -f /data/zte-agent && test ! -L /data/zte-agent && test -r /data/zte-agent || absent_fail
          test "$(stat -c %u:%h /data/zte-agent)" = 0:1 || absent_fail
          disk=$(sha256sum /data/zte-agent) || absent_fail
          test "${disk%% *}" = "$expected" || absent_fail
          file_state=$(stat -c %d:%i:%u:%a:%h /data/zte-agent) || absent_fail
        }
        absent_scan() {
          names=; pidof_status=0
          names=$(pidof zte-agent 2>/dev/null) || pidof_status=$?
          test "$pidof_status" = 1 && test -z "$names" || absent_fail
          count=0
          for process in /proc/[0-9]*; do
            test -d "$process" || continue
            test ! -L "$process" || absent_fail
            count=$((count + 1)); test "$count" -le 4096 || absent_fail
            pid=${process##*/}
            if test -r "$process/cmdline"; then
              args=$(tr '\000' '\n' < "$process/cmdline" 2>/dev/null) || {
                test ! -d "$process" && continue
                absent_fail
              }
            else
              test ! -d "$process" && continue
              absent_fail
            fi
            first=${args%%'
        '*}
            case "$first" in zte-agent|*/zte-agent) absent_fail;; esac
            if mapped=$(readlink "$process/exe" 2>/dev/null); then
              case "$mapped" in */zte-agent|*/zte-agent' (deleted)') absent_fail;; esac
            else
              test ! -d "$process" && continue
              test -z "$args" || absent_fail
              # Only a kernel thread or a zombie may have no executable. An ordinary
              # process with cleared argv and unreadable exe is not absence evidence.
              state=$(cat "$process/stat" 2>/dev/null) || {
                test ! -d "$process" && continue
                absent_fail
              }
              case "$state" in "$pid ("*') '*) ;; *) absent_fail;; esac
              rest=${state##*) }; set -- $rest
              test "$#" -ge 20 || absent_fail
              process_state=$1; shift 6; flags=$1
              case "$flags" in ''|*[!0-9]*) absent_fail;; esac
              test "$process_state" = Z || test "$((flags & 2097152))" != 0 || absent_fail
            fi
          done
          test "$count" -gt 0 || absent_fail
        }
        absent_file
        initial_file_state=$file_state
        absent_scan
        absent_scan
        absent_file
        test "$file_state" = "$initial_file_state" || absent_fail
        printf 'AGENT_ACCESS_ABSENT %s\n' "$expected"
        """#.replacingOccurrences(of: "EXPECTED_AGENT_SHA", with: expectedHash)
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
