import Foundation
import Darwin

@main enum OnboardingCommitTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-commit-" + UUID().uuidString)
        try secureDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let id = "01234567-89AB-4CDE-8F01-23456789ABCD"
        let policy = [String(repeating: "a", count: 32), "b31", String(repeating: "b", count: 64), String(repeating: "c", count: 64)]
        let owner = ([id] + policy).joined(separator: " ")
        let legacy = try SetupRemotePaths(id: id, installRequested: true, stage: nil, journal: nil)
        let current = try SetupRemotePaths(id: id, installRequested: false, stage: nil, journal: nil)
        let direct = "sh " + ([current.stage + "/setup-agent.sh", "--commit", current.journal] + policy).map(shellQuote).joined(separator: " ")
        try require(current.commitCommand(id: id, policy: policy) == direct, "Private layout command changed")
        var failures = 0, passed = 1
        for state in ["good", "unsafe-parent", "symlink-parent", "stage-mode", "missing-owner", "wrong-owner", "extra-marker-byte", "symlink-marker", "hardlinked-marker", "marker-mode", "symlink-script", "hardlinked-script", "script-mode", "replace-after-open"] {
            let folder = root.appendingPathComponent(state), data = folder.appendingPathComponent("data")
            let stage = data.appendingPathComponent("local/tmp/zte-imei-setup-" + id)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            for path in [data, data.appendingPathComponent("local"), data.appendingPathComponent("local/tmp")] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
            for name in [".owner", ".install-requested"] { try savePrivate(Data((owner + "\n").utf8), stage.appendingPathComponent(name)) }
            let script = stage.appendingPathComponent("setup-agent.sh"), marker = stage.appendingPathComponent(".owner")
            try savePrivate(Data("#!/bin/sh\nprintf ORIGINAL_COMMIT\n".utf8), script)
            switch state {
            case "unsafe-parent": try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: data.appendingPathComponent("local").path)
            case "symlink-parent":
                let local = data.appendingPathComponent("local"), moved = data.appendingPathComponent("moved")
                try FileManager.default.moveItem(at: local, to: moved); try FileManager.default.createSymbolicLink(at: local, withDestinationURL: moved)
            case "stage-mode": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stage.path)
            case "missing-owner": try FileManager.default.removeItem(at: marker)
            case "wrong-owner": try savePrivate(Data("foreign\n".utf8), marker)
            case "extra-marker-byte": try savePrivate(Data((owner + "\n\n").utf8), marker)
            case "symlink-marker", "symlink-script":
                let target = state == "symlink-marker" ? marker : script, moved = stage.appendingPathComponent("original")
                try FileManager.default.moveItem(at: target, to: moved); try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
            case "hardlinked-marker", "hardlinked-script": try FileManager.default.linkItem(at: state == "hardlinked-marker" ? marker : script, to: stage.appendingPathComponent("linked"))
            case "marker-mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
            case "script-mode": try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: script.path)
            default: break
            }
            let replace = state == "replace-after-open" ? "mv \"$script\" \"$script.original\"; printf '#!/bin/sh\\nprintf REPLACED\\n' > \"$script\"; chmod 600 \"$script\"; " : ""
            // Only host filesystem paths and UID reporting are adapted. The
            // production guard and original script execute under the real shell.
            let shim = """
            stat() {
              case "$2" in
                %u) printf '0\\n';;
                %a) /usr/bin/stat -f %Lp "$3";;
                %h) /usr/bin/stat -f %l "$3";;
                %s) /usr/bin/stat -f %z "$3";;
                %d:%i:%u:%a:%h) if [ "$1" = '-Lc' ]; then \(replace)/usr/bin/python3 -c 'import os; s=os.fstat(9); print("%d:%d:0:%o:%d"%(s.st_dev,s.st_ino,s.st_mode&4095,s.st_nlink))'; else /usr/bin/stat -f '%d:%i:0:%Lp:%l' "$3"; fi;;
                *) exit 88;;
              esac
            }
            
            """
            let command = legacy.commitCommand(id: id, policy: policy).replacingOccurrences(of: "/data", with: data.path).replacingOccurrences(of: "/proc/self/fd/9", with: "/dev/fd/9")
            let result = try HostProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", shim + command], timeout: 5)
            let good = state == "good" ? result.status == 0 && result.stdout == Data("ORIGINAL_COMMIT".utf8) : result.status != 0 && result.stdout.isEmpty && String(decoding: result.stderr, as: UTF8.self).contains("INSTALL_ERROR COMMIT_STAGE_UNSAFE")
            print((good ? "PASS " : "FAIL ") + state)
            if good { passed += 1 } else { failures += 1 }
        }
        print("RESULT \(passed) passed; \(failures) failed")
        if failures != 0 { exit(1) }
    }
}
