import Foundation
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw IMEIError.message("TEST: " + message) } }
private func rejects(_ body: () throws -> Void) throws { do { try body() } catch { if error.localizedDescription.hasPrefix("TEST:") { throw error };return };throw IMEIError.message("TEST: refusal expected") }
private final class Remote: RemoteTransport {
    let cid = String(repeating: "a", count: 32)
    var boot = "11111111-2222-3333-4444-555555555555", firmware = ModemEngine.firmwareHash
    var active = "none", previous = "unset", packages = "", corruptUpload = false, failCommand = false, reboot = false
    var commands: [String] = [], archives = 0, timeoutUploads = 0
    var measuredReads = 0, platformFailure = false
    var badTimeoutUpload = false
    var feeds = "src/gz official_base https://downloads.openwrt.org/releases/23.05.4/packages/aarch64_cortex-a53/base\n"
    var uploadedFeeds: String?
    var feedUploads = 0
    func status() -> String { "__ZTE_PRIVATE_OPKG_V1__\ninstalled=\(active == "none" ? 0 : 1)\ngeneration=\(active)\nprevious=\(previous)\nrollback=\(previous == "unset" ? 0 : 1)\nfree_kib=999999\nrunning=0\n\(packages)__END__\n" }
    func run(_ command: String, input: Data?, timeout: TimeInterval) throws -> CommandResult {
        commands.append(command)
        func result(_ text: String, _ code: Int32 = 0) -> CommandResult { .init(status: code, stdout: code == 0 ? Data(text.utf8) : Data(), stderr: code == 0 ? Data() : Data(text.utf8)) }
        if command == AccessIdentity.command {
            measuredReads += 1
            if platformFailure { return result("PLATFORM", 71) }
            return result(firmware + "  /firmware/image/modem.b16\n" + ModemEngine.routerHash + "  /usr/bin/diag-router\n" + cid + "\n" + boot + "\n")
        }
        if command.hasPrefix("sha256sum /firmware/image/modem.b16") { return result(firmware + "  /firmware/image/modem.b16\n" + ModemEngine.routerHash + "  /usr/bin/diag-router\n" + cid + "\n" + boot + "\n") }
        if let input, command.contains("cat > '") {
            let path = command.components(separatedBy: "cat > '")[1].components(separatedBy: "'")[0]
            if path.hasSuffix("runtime.tar.gz") { archives += 1 }
            if path.hasSuffix("feeds.txt") { feedUploads += 1;uploadedFeeds = String(decoding: input, as: UTF8.self) }
            if path.hasSuffix("zte-timeout") { timeoutUploads += 1; try check(digest(input) == ModemHostTools.timeoutHash && command.contains("chmod 700"), "Timeout helper was not pinned/executable") }
            return result(((corruptUpload || (badTimeoutUpload && path.hasSuffix("zte-timeout"))) ? String(repeating: "0", count: 64) : digest(input)) + "  " + path + "\n")
        }
        if command.contains("; sh '") || command.hasPrefix("sh -s -- ") {
            let pinned = command.hasPrefix("sh -s -- ") ? input.map(digest) == ExperimentalOpkgManager.helperHash : command.contains(ExperimentalOpkgManager.helperHash)
            try check(pinned && command.contains(cid) && command.contains(boot), "Helper omitted hash/device proof")
            if failCommand { return result("OPKG_ERROR FEED_SIGNATURE", 1) }
            if command.contains(" 'install-adapter' ") { try check(archives == 1, "Runtime not uploaded");previous = active;active = "g-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }
            if command.contains(" 'remove-adapter' ") { previous = active;active = "none";packages = "" }
            if command.contains(" 'rollback' ") { let old = active;active = previous;previous = old }
            if command.contains(" 'execute' ") { try check(command.contains(" 'list' ") || command.hasSuffix(" 'list'") || command.hasSuffix(" 'files' 'htop'"), "Unexpected argv") }
            if command.contains(" 'read-feeds' ") { if reboot { boot = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }; return result("__ZTE_OPKG_FEEDS_V1__\nrelease=23.05.4\narchitecture=aarch64_cortex-a53\ngeneration=\(active)\nkey=b5043e70f9a75cde\n" + feeds.split(separator: "\n").map { "source=" + $0 + "\n" }.joined() + "__END_FEEDS__\n" + status()) }
            if command.contains(" 'save-feeds' ") {
                guard command.hasSuffix(" '" + active + "'") else { return result("OPKG_ERROR FEEDS_STALE", 1) }
                try check(feedUploads > 0 && command.contains(digest(Data(uploadedFeeds!.utf8))), "Feeds payload proof omitted")
                feeds = uploadedFeeds!;previous = active;active = "g-11111111-2222-3333-4444-555555555555"
            }
            let output = status();if reboot { boot = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" };return result(output)
        }
        try check(!command.contains("remount") && !command.contains("/etc/init.d") && !command.contains("opkg install"), "Unscoped command")
        return result("")
    }
}
private final class Fixture {
    let root: URL, resources: URL, remote: Remote, engine: ModemEngine
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zte-opkg-test-" + UUID().uuidString);try secureDirectory(root)
        resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        remote = Remote();engine = try ModemEngine(root: root, resources: resources, connection: Connection(host: "192.0.2.1", port: "2222", keyPath: "/fixture/key", knownHostsPath: "/fixture/hosts"), transport: remote)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
@main struct ExperimentalOpkgTests {
    static func main() throws {
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) throws { try body();count += 1;print("PASS " + name) }
        try test("Resource hashes and runtime metadata are pinned") {
            let f = try Fixture(), dir = f.resources.appendingPathComponent("ExperimentalOpkg")
            try check(digest(Data(contentsOf: dir.appendingPathComponent("manager.sh"))) == ExperimentalOpkgManager.helperHash, "Helper hash")
            let metadata = try Data(contentsOf: dir.appendingPathComponent("runtime.json"))
            try check(digest(metadata) == ExperimentalOpkgManager.runtimeMetadataHash, "Runtime metadata hash")
            let fields = try JSONSerialization.jsonObject(with: metadata) as! [String:Any], archive = try Data(contentsOf: dir.appendingPathComponent("runtime.tar.gz"))
            try check(fields["sha256"] as? String == digest(archive) && fields["bytes"] as? Int == archive.count, "Archive hash/size")
        }
        try test("Allowed genuine opkg commands and explicit files arity") {
            for args in [["update"],["list"],["list","lib*"],["search","*ssl*"],["info","htop"],["install","htop","nano"],["remove","nano"],["list-installed"],["status"],["files","htop"]] { try ExperimentalOpkgManager.validate(args) }
            for args in [[],["shell"],["files"],["files","a","b"],["files","*"],["update","foo"],["install","--force-postinstall"],["install","/tmp/file.ipk"],["install","https://example.invalid/a"],["install","htop;reboot"],["install","kmod-usb"],["remove","libc"],["install","*"],Array(repeating:"htop",count:10)] { try rejects { try ExperimentalOpkgManager.validate(args) } }
        }
        try test("Absent installed removed and rollback-to-none status") {
            let r = Remote();try check(!ExperimentalOpkgManager.parse(Data(r.status().utf8)).status.installed, "Absent")
            r.active = "g-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";r.previous = "none";r.packages = "package=htop\t3.3.0-1\tInteractive process viewer\n"
            let parsed = try ExperimentalOpkgManager.parse(Data(("opkg log\n" + r.status()).utf8));try check(parsed.output == "opkg log" && parsed.status.canRollback && parsed.status.packages.first?.summary == "Interactive process viewer", "Inventory")
            r.previous = r.active;r.active = "none";r.packages = "";try check(ExperimentalOpkgManager.parse(Data(r.status().utf8)).status.canRollback, "Removed rollback")
        }
        try test("Malformed inconsistent oversized and duplicated status rejected") {
            let s = Remote().status()
            for bad in [s.replacingOccurrences(of:"generation=none",with:"generation=unset"),s.replacingOccurrences(of:"rollback=0",with:"rollback=1"),s.replacingOccurrences(of:"previous=unset",with:"previous=none"),s.replacingOccurrences(of:"__END__",with:"package=htop\t1\n__END__"),s.replacingOccurrences(of:"running=0",with:"running=2"),s.replacingOccurrences(of:"free_kib=999999",with:"free_kib=-1"),s.replacingOccurrences(of:"__END__",with:"installed=0\n__END__"),String(s.dropLast()),String(repeating:"x",count:4*1024*1024+1)] { try rejects { _ = try ExperimentalOpkgManager.parse(Data(bad.utf8)) } }
        }
        try test("Feed declarations normalize comments and allow signed HTTP HTTPS mirrors") {
            let valid = "# note\n src/gz base https://example.org/releases/23.05.4/base\n\nsrc/gz lan http://[::1]:8080/feed\n"
            let text = try ExperimentalOpkgManager.normalizeFeeds(valid)
            try check(!text.contains("#") && text.contains("src/gz lan http://[::1]:8080/feed"), "Mirror declaration lost")
            try check(ExperimentalOpkgManager.normalizeFeeds("# none\n") == "", "Empty sources not supported")
            for invalid in ["option check_signature 0", "src a https://example.org", "src/gz a file:///etc", "src/gz ../x https://example.org", "src/gz a https://example.org;reboot", "src/gz a https://u:p@example.org", "src/gz a https://example.org?x=y", "src/gz a https://example.org/%zz", "src/gz a https://example.org:70000", "src/gz a https://example.org\nsrc/gz a https://other.org", String(repeating:"x",count:16385)] { try rejects { _ = try ExperimentalOpkgManager.normalizeFeeds(invalid) } }
        }
        try test("Load feeds is read-only and save uploads a pinned isolated configuration") {
            let f = try Fixture(), m = ExperimentalOpkgManager(engine:f.engine);f.remote.active = "g-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";f.remote.previous = "none"
            let feeds = try f.engine.locked { try m.loadFeeds() }
            try check(feeds.release == "23.05.4" && feeds.architecture == "aarch64_cortex-a53" && feeds.keyFingerprints == ["b5043e70f9a75cde"] && f.remote.timeoutUploads == 0 && f.remote.feedUploads == 0, "Read changed modem resources")
            let saved = try f.engine.locked { try m.saveFeeds("src/gz custom http://example.org/feed\n", expectedGeneration: feeds.generation) }
            try check(saved.status.generation != feeds.generation && saved.status.canRollback && f.remote.feedUploads == 1 && f.remote.timeoutUploads == 1, "Save did not commit isolated payload")
            try rejects { _ = try f.engine.locked { try m.saveFeeds(feeds.text, expectedGeneration: feeds.generation) } }
        }
        try test("Malformed or stale feed snapshot cannot populate the editor") {
            let f = try Fixture(), m = ExperimentalOpkgManager(engine:f.engine);f.remote.active = "g-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";f.remote.previous = "none"
            let valid = "__ZTE_OPKG_FEEDS_V1__\nrelease=23.05.4\narchitecture=aarch64_cortex-a53\ngeneration=\(f.remote.active)\nkey=b5043e70f9a75cde\nsource=\(f.remote.feeds.trimmingCharacters(in: .newlines))\n__END_FEEDS__"
            let status = try ExperimentalOpkgManager.parse(Data(f.remote.status().utf8)).status
            for bad in [valid.replacingOccurrences(of:"23.05.4",with:"24.10"),valid.replacingOccurrences(of:"generation=\(f.remote.active)",with:"generation=none"),valid.replacingOccurrences(of:"__END_FEEDS__",with:"key=b5043e70f9a75cde\n__END_FEEDS__"),String(valid.dropLast())] { try rejects { _ = try ExperimentalOpkgManager.parseFeeds(.init(output: bad, status: status)) } }
            _ = m
        }
        try test("Capability and bootstrap errors name the missing tool in inventory") {
            let missing = ExperimentalOpkgManager.failureMessage("Remote failed: OPKG_ERROR CAPABILITY_chroot\n")
            try check(missing.contains("«chroot»") && missing.contains("CAPABILITY_chroot"), "Missing command concealed")
            try check(ExperimentalOpkgManager.failureMessage("OPKG_ERROR TIMEOUT_HELPER_HASH").contains("Повреждён"), "Bootstrap integrity error not explained")
        }
        try test("Inspect stages only the pinned helper and no runtime") {
            let f = try Fixture(), m = ExperimentalOpkgManager(engine:f.engine)
            try rejects { _ = try m.inspect() }
            let s = try f.engine.locked { try m.inspect() };try check(!s.installed && f.remote.archives == 0 && f.remote.timeoutUploads == 0, "Inspect installed data")
        }
        try test("B28 read status and feeds use measured identity without staging or unrelated pending") {
            let f = try Fixture(), m = ExperimentalOpkgManager(engine:f.engine)
            f.remote.firmware = String(repeating:"b",count:64)
            try Data("{}".utf8).write(to:f.root.appendingPathComponent("pending.json"))
            try Data("{}".utf8).write(to:f.root.appendingPathComponent("setup-pending.json"))
            _ = try f.engine.locked { try m.inspect() }
            f.remote.active = "g-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            _ = try f.engine.locked { try m.loadFeeds() }
            try check(f.remote.measuredReads == 4 && f.remote.archives == 0 && f.remote.timeoutUploads == 0 && !f.remote.commands.contains { $0.contains("mkdir") || $0.contains("cat >") }, "Read unexpectedly staged or skipped proof")
        }
        try test("Read status rejects platform failure and final boot drift") {
            for platform in [true,false] {
                let f = try Fixture(), m = ExperimentalOpkgManager(engine:f.engine)
                f.remote.platformFailure = platform;f.remote.reboot = !platform
                try rejects { _ = try f.engine.locked { try m.inspect() } }
                try check(f.remote.archives == 0 && !f.remote.commands.contains { $0.contains("mkdir") }, "Read refusal staged data")
            }
        }
        try test("Install remove rollback and files query verify final receipt") {
            let f = try Fixture(), m = ExperimentalOpkgManager(engine:f.engine)
            try check(f.engine.locked { try m.installAdapter().status.installed }, "Install")
            try check(f.remote.timeoutUploads == 1, "Supervisor not staged for install")
            _ = try f.engine.locked { try m.execute(["files","htop"]) }
            try check(!(f.engine.locked { try m.removeAdapter().status.installed }), "Remove")
            try check(f.engine.locked { try m.rollback().status.installed }, "Rollback")
        }
        try test("Corrupt supervisor upload refuses before runtime or invocation") {
            let f = try Fixture(), m = ExperimentalOpkgManager(engine:f.engine);f.remote.badTimeoutUpload = true
            try rejects { _ = try f.engine.locked { try m.installAdapter() } }
            try check(f.remote.timeoutUploads == 1 && f.remote.archives == 0 && !f.remote.commands.contains { $0.contains("; sh '") }, "Corrupt supervisor reached remote execution")
        }
        try test("Unknown firmware and pending journals refuse before transfer") {
            for pending in [false,true] {
                let f = try Fixture(), m = ExperimentalOpkgManager(engine:f.engine)
                if pending { try Data("{}".utf8).write(to:f.root.appendingPathComponent("setup-pending.json")) } else { f.remote.firmware = String(repeating:"b",count:64) }
                try rejects { _ = try f.engine.locked { try m.installAdapter() } };try check(f.remote.archives == 0, "Refusal uploaded runtime")
            }
        }
        try test("Corrupt upload remote failure and changed boot cannot report success") {
            for kind in 0..<3 { let f = try Fixture(), m = ExperimentalOpkgManager(engine:f.engine);f.remote.corruptUpload = kind == 0;f.remote.failCommand = kind == 1;f.remote.reboot = kind == 2;try rejects { _ = try f.engine.locked { try m.installAdapter() } } }
        }
        print("\(count) experimental opkg tests passed")
    }
}
