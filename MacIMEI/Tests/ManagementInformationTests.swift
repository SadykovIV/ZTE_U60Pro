import Foundation
import Darwin
private enum Failure: Error { case assertion(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure.assertion(message) } }
private func reject(_ body: () throws -> Void) throws { do { try body() } catch { return };throw Failure.assertion("Expected refusal") }
private let identity = Identity(cid:"0123456789abcdef0123456789abcdef",firmwareHash:ModemEngine.firmwareHash)
private let boot="2a2fb1c5-1bbf-4d3b-92a8-3daaf5510601"
private let info = """
__INFO_SCHEMA__
1
__INFO_BOARD__
{"kernel":"5.15.137","hostname":"modem","system":"Qualcomm Technologies, Inc SDX75","model":"ZTE MU5250","board_name":"qcom,sdx75","release":{"distribution":"OpenWrt","version":"23.05","revision":"r-custom"}}
__INFO_DEVICE__
{"integrate_version":"MU5250V1.0.0B31","wa_inner_version":"B31-internal"}
__INFO_ARCH__
aarch64
__INFO_CPU__
4
__INFO_UPTIME__
12345.67 20000.00
__INFO_LOAD__
0.01 0.02 0.03
__INFO_MEMORY__
MemTotal:       2048000 kB
MemFree:        512000 kB
MemAvailable:   1024000 kB
Cached:         400000 kB
SwapTotal:      0 kB
SwapFree:       0 kB
HugePages_Total: 0
__INFO_DISKS__
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/root 65536 65536 0 100% /
/dev/mmcblk0p50 5242880 2097152 3145728 40% /data
tmpfs 1000000 100 999900 1% /tmp
tmpfs 1000000 100 999900 1% /usr/ui/language/English.ini
/dev/mmcblk0p50 5242880 2097152 3145728 40% /usr/bin/zte_topsw_devui
__INFO_MOUNTS__
/dev/root / squashfs ro,relatime 0 0
/dev/mmcblk0p50 /data ext4 rw,relatime 0 0
tmpfs /tmp tmpfs rw,nosuid 0 0
__INFO_BATTERY__
78
Charging
__INFO_AGENT__
b5c27d398e85db8a87d454d729cb36f22e54a2d832fb1117b27aa055e5032537  /data/zte-agent
__INFO_END__
"""
private final class Stub: RemoteTransport {
    var calls=0, identities=0, reboot=false, transportFailure=false, finish: (() throws -> Void)?
    func run(_ command: String,input:Data?,timeout:TimeInterval) throws -> CommandResult {
        calls += 1
        if command.hasPrefix("sha256sum /firmware") {
            identities += 1
            return CommandResult(status:0,stdout:Data((ModemEngine.firmwareHash+" /firmware/image/modem.b16\n"+ModemEngine.routerHash+" /usr/bin/diag-router\n"+identity.cid+"\n"+(reboot && identities>1 ? "3a2fb1c5-1bbf-4d3b-92a8-3daaf5510601" : boot)+"\n").utf8),stderr:Data())
        }
        if command == ModemInformationManager.command { return CommandResult(status:0,stdout:Data(info.utf8),stderr:Data()) }
        if transportFailure {throw IMEIError.message("password='do-not-export' failed")}
        try finish?()
        return CommandResult(status:0,stdout:Data("safe output\npassword='do-not-export'\n__DIAGNOSTIC_RESULT__0\n".utf8),stderr:Data())
    }
}
@main enum ManagementInformationTests {
    static func main() throws {
        var passed=0
        func test(_ title:String,_ body:()throws->Void)throws{try body();passed+=1;print("PASS "+title)}
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("zte-information-tests-"+UUID().uuidString)
        try secureDirectory(temp);defer{try? FileManager.default.removeItem(at:temp)}
        func newEngine(_ stub:Stub)throws->ModemEngine{try ModemEngine(root:temp.appendingPathComponent(UUID().uuidString),resources:temp,connection:Connection(host:"192.168.0.1",port:"2222",keyPath:"/dev/null",knownHostsPath:"/dev/null"),transport:stub)}
        try test("Real BusyBox/ubus-shaped sections preserve identity firmware and storage"){
            let value=try ModemInformationManager.parse(info,identity:identity,boot:boot)
            try check(value.firmware=="MU5250V1.0.0B31" && value.internalFirmware=="B31-internal","Firmware")
            try check(value.cpuCount==4 && value.memoryAvailableKiB==1024000 && value.uptimeSeconds==12345.67,"Numeric values")
            try check(value.volumes.map(\.mount)==["/","/data","/tmp"] && value.readOnlyMounts==["/"],"Bind files must not count as disks")
            try check(value.agentVersion.contains("2.4.1") && value.batteryPercent==78 && value.identity==identity,"Agent/battery/identity")
        }
        try test("Missing duplicate unknown or trailing sections never masquerade as complete info"){
            for text in [info.replacingOccurrences(of:"__INFO_CPU__\n4\n",with:""),info+"__INFO_ARCH__\naarch64\n",info.replacingOccurrences(of:"__INFO_CPU__",with:"__INFO_FOREIGN__"),info+"\nextraneous",info.replacingOccurrences(of:"__INFO_END__",with:"")] {try reject{_=try ModemInformationManager.parse(text,identity:identity,boot:boot)}}
        }
        try test("Invalid memory uptime CPU and load values rejected"){
            for (old,new) in [("1024000 kB","9999999 kB"),("512000 kB","-1 kB"),("12345.67 20000.00","nan 20000.00"),("12345.67 20000.00","1e300 20000.00"),("2048000 kB","9223372036854775807 kB"),("__INFO_CPU__\n4","__INFO_CPU__\n0"),("0.01 0.02 0.03","0.01 bad 0.03")] {try reject{_=try ModemInformationManager.parse(info.replacingOccurrences(of:old,with:new),identity:identity,boot:boot)}}
        }
        try test("Optional vendor details and battery remain explicitly absent"){
            let text=info.replacingOccurrences(of:"{\"integrate_version\":\"MU5250V1.0.0B31\",\"wa_inner_version\":\"B31-internal\"}",with:"{}").replacingOccurrences(of:"78\nCharging",with:"")
            let value=try ModemInformationManager.parse(text,identity:identity,boot:boot);try check(value.batteryPercent==nil && value.internalFirmware=="—","Absent optional values")
        }
        try test("Inspect detects reboot during collection"){
            let stub=Stub();stub.reboot=true;try reject{_=try ModemInformationManager(engine:newEngine(stub)).inspect()}
        }
        try test("Shell JSON Basic Cookie and incomplete private-key secrets are redacted"){
            let samples=["export ZTE_AGENT_PASSWORD='visible '\\''secret-tail'",#"{"password":"visible\"secret-tail","other":1}"#,"Authorization: Basic c2VjcmV0LXRhaWw=","Cookie: session=abc; secret-tail=def","api_key=secret-tail","-----BEGIN OPENSSH PRIVATE KEY-----\nsecret-tail\n"]
            for sample in samples{let clean=ActivityJournal.sanitize(sample);try check(!clean.contains("secret-tail") && !clean.contains("c2VjcmV0"),"Credential suffix leaked")}
            try check(ActivityJournal.sanitize("normal modem ready\nvoltage=4200")=="normal modem ready\nvoltage=4200","Ordinary diagnostics changed")
        }
        try test("Journal sensitive dictionary keys are masked and records are private"){
            let journal=try ActivityJournal(root:temp.appendingPathComponent("journal"))
            try journal.record(operationID:"op",category:"test",title:"safe",result:"completed",details:["password":"secret-tail","token":"abc","ordinary":"safe"])
            let events=journal.recent();try check(events.count==1 && events[0].details["password"]=="[скрыто]" && events[0].details["ordinary"]=="safe","Field masking")
            let file=try FileManager.default.contentsOfDirectory(at:journal.directory,includingPropertiesForKeys:nil).first!
            let permissions=(try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions]) as? NSNumber
            try check(permissions?.intValue==0o600,"Journal permissions");try check(journal.recent(limit:-1).isEmpty,"Negative limit")
        }
        try test("Journal symlink target is never appended or followed"){
            let journal=try ActivityJournal(root:temp.appendingPathComponent("symlink"));let other=temp.appendingPathComponent("unrelated");try savePrivate(Data("unchanged".utf8),other)
            let date=String(ISO8601DateFormatter().string(from:Date()).prefix(10));try FileManager.default.createSymbolicLink(at:journal.directory.appendingPathComponent(date+".jsonl"),withDestinationURL:other)
            try reject{try journal.record(operationID:"op",category:"test",title:"safe",result:"completed")};try check(try String(contentsOf:other,encoding:.utf8)=="unchanged","Symlink modified");try check(journal.recent().isEmpty,"Symlink read")
        }
        try test("Audit transport records metadata without command stdin or response secrets"){
            let journal=try ActivityJournal(root:temp.appendingPathComponent("audit")),stub=Stub()
            let transport=AuditedRemoteTransport(base:stub,journal:journal,operationID:"op",endpoint:"192.168.0.1:2222")
            _=try transport.run("password='command-secret'",input:Data("stdin-secret".utf8),timeout:10)
            let events=journal.recent();try check(events.count==2 && Set(events.map(\.result))==["started","completed"],"Audit pair")
            let data=try JSONEncoder().encode(events);let text=String(decoding:data,as:UTF8.self)
            for secret in ["command-secret","stdin-secret","do-not-export"]{try check(!text.contains(secret),"Transport leaked plaintext")}
            try check(events[0].details["exitCode"]=="0" && events[0].details["stdoutSHA256"] != nil,"Completion metadata")
        }
        try test("Audit start failure prevents the device command"){
            let journal=try ActivityJournal(root:temp.appendingPathComponent("audit-start-fail")),stub=Stub()
            let day=String(ISO8601DateFormatter().string(from:Date()).prefix(10))
            try FileManager.default.createDirectory(at:journal.directory.appendingPathComponent(day+".jsonl"),withIntermediateDirectories:false)
            let transport=AuditedRemoteTransport(base:stub,journal:journal,operationID:"op",endpoint:"192.168.0.1:2222")
            try reject{_=try transport.run("safe",input:nil,timeout:10)};try check(stub.calls==0,"Remote call ran without its audit start")
        }
        try test("Audit completion failure preserves actual command success and leaves an explicit gap marker"){
            let journal=try ActivityJournal(root:temp.appendingPathComponent("audit-end-fail")),stub=Stub()
            stub.finish={
                let file=try FileManager.default.contentsOfDirectory(at:journal.directory,includingPropertiesForKeys:nil).first!
                try FileManager.default.moveItem(at:file,to:file.appendingPathExtension("started"))
                try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
            }
            let transport=AuditedRemoteTransport(base:stub,journal:journal,operationID:"op",endpoint:"192.168.0.1:2222")
            let result=try transport.run("safe",input:nil,timeout:10)
            try check(result.status==0 && FileManager.default.fileExists(atPath:journal.directory.appendingPathComponent("incomplete.txt").path),"Completed device operation falsely failed or audit gap hidden")
        }
        try test("Audit transport exception stays failed without credential details"){
            let journal=try ActivityJournal(root:temp.appendingPathComponent("audit-transport-fail")),stub=Stub();stub.transportFailure=true
            let transport=AuditedRemoteTransport(base:stub,journal:journal,operationID:"op",endpoint:"192.168.0.1:2222")
            try reject{_=try transport.run("safe",input:nil,timeout:10)}
            let events=journal.recent();try check(events.count==2 && events[0].result=="failed","Missing failed audit event")
            try check(!String(decoding:JSONEncoder().encode(events),as:UTF8.self).contains("do-not-export"),"Exception secret leaked")
        }
        try test("Nonzero transport status wins over a success-shaped producer footer"){
            let r=ModemInformationManager.decodeDiagnostic(CommandResult(status:255,stdout:Data("partial\n__DIAGNOSTIC_RESULT__0\n".utf8),stderr:Data("transport closed".utf8)))
            try check(r.status==255 && String(decoding:r.body,as:UTF8.self).contains("transport closed"),"False diagnostic success")
        }
        try test("Missing malformed and out-of-range diagnostic footer are errors"){
            for suffix in ["", "\n__DIAGNOSTIC_RESULT__bad\n", "\n__DIAGNOSTIC_RESULT__999\n"]{let r=ModemInformationManager.decodeDiagnostic(CommandResult(status:0,stdout:Data(("body"+suffix).utf8),stderr:Data()));try check(r.status == -2,"Invalid footer succeeded")}
        }
        try test("Diagnostic byte limit preserves valid UTF8 and flags truncation"){
            let payload=String(repeating:"я",count:ModemInformationManager.diagnosticByteLimit)+"\n__DIAGNOSTIC_RESULT__0\n"
            let r=ModemInformationManager.decodeDiagnostic(CommandResult(status:0,stdout:Data(payload.utf8),stderr:Data()))
            try check(r.truncated && r.body.count < ModemInformationManager.diagnosticByteLimit+100 && String(data:r.body,encoding:.utf8) != nil,"Byte/UTF8 cap")
        }
        try test("Diagnostic export sanitizes payload and records producer failure"){
            let r=ModemInformationManager.decodeDiagnostic(CommandResult(status:0,stdout:Data("password='secret-tail'\nuseful\n__DIAGNOSTIC_RESULT__127\n".utf8),stderr:Data()))
            try check(r.status==127 && !String(decoding:r.body,as:UTF8.self).contains("secret-tail") && String(decoding:r.body,as:UTF8.self).contains("useful"),"Export masking/status")
        }
        try test("Intentional producer file-size signal is a successful truncated capture"){
            let payload=Data((String(repeating:"a",count:ModemInformationManager.diagnosticByteLimit+1)+"\n__DIAGNOSTIC_RESULT__153\n").utf8)
            let r=ModemInformationManager.decodeDiagnostic(CommandResult(status:0,stdout:payload,stderr:Data()))
            try check(r.status==0 && r.truncated,"File-size limit treated as unexpected failure")
            let short=ModemInformationManager.decodeDiagnostic(CommandResult(status:0,stdout:Data("short\n__DIAGNOSTIC_RESULT__153\n".utf8),stderr:Data()))
            try check(short.status==153,"Unexplained signal masked")
        }
        try test("Unavailable log service is probed before logread and service logs do not retry it"){
            let commands=Dictionary(uniqueKeysWithValues:ModemInformationManager.diagnosticCommands.map { ($0.0,$0.2) })
            try check(commands["system.log"]!.contains("ubus list log") && commands["system.log"]!.contains("exit 3"),"No fast missing-log check")
            try check(!commands["services.txt"]!.contains("logread") && commands["services.txt"]!.contains("tail -c 131072"),"Service logger may hang")
        }
        try test("USB diagnostic keeps state ConfigFS links and devices when legacy functions file is absent") {
            let fixture=temp.appendingPathComponent("usb-fixture")
            let android=fixture.appendingPathComponent("sys/class/android_usb/android0"), devices=fixture.appendingPathComponent("sys/bus/usb/devices"), config=fixture.appendingPathComponent("config/usb_gadget/g1/configs/b.1")
            for directory in [android,devices,config] { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
            try Data("CONFIGURED\n".utf8).write(to:android.appendingPathComponent("state"))
            try FileManager.default.createDirectory(at:devices.appendingPathComponent("usb1"),withIntermediateDirectories:false)
            try FileManager.default.createSymbolicLink(atPath:config.appendingPathComponent("ncm.usb0").path,withDestinationPath:"../../functions/ncm.usb0")
            let source=ModemInformationManager.diagnosticCommands.first{$0.0=="usb.txt"}!.2
            let command=source.replacingOccurrences(of:"/sys/",with:fixture.appendingPathComponent("sys").path+"/").replacingOccurrences(of:"/config/",with:fixture.appendingPathComponent("config").path+"/")
            let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=["-c","set -e; "+command];process.standardOutput=pipe
            try process.run();let output=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);process.waitUntilExit()
            try check(process.terminationStatus==0 && output.contains("CONFIGURED") && output.contains("ncm.usb0 -> ../../functions/ncm.usb0") && output.contains("usb1") && output.contains("недоступно"),"Optional USB failure stopped remaining collection")
        }
        try test("Process diagnostic survives a PID disappearing after readability check") {
            let fixture=temp.appendingPathComponent("proc-fixture"),bin=fixture.appendingPathComponent("bin")
            for directory in [bin,fixture.appendingPathComponent("proc/100"),fixture.appendingPathComponent("proc/200")] {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
            try Data("Name:\trace\nPid:\t100\n".utf8).write(to:fixture.appendingPathComponent("proc/100/status"))
            try Data("Name:\tkeeper\nPid:\t200\nState:\tS\n".utf8).write(to:fixture.appendingPathComponent("proc/200/status"))
            let mock=bin.appendingPathComponent("awk")
            try Data("#!/bin/sh\nfor arg do last=$arg; done\ncase \"$last\" in */100/status) exit 1;; esac\nexec /usr/bin/awk \"$@\"\n".utf8).write(to:mock)
            try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:mock.path)
            let source=ModemInformationManager.diagnosticCommands.first{$0.0=="processes.txt"}!.2
            let command=source.replacingOccurrences(of:"/proc/",with:fixture.appendingPathComponent("proc").path+"/")
            let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=["-c","set -e; "+command]
            process.environment=["PATH":bin.path+":/usr/bin:/bin"];process.standardOutput=pipe
            try process.run();let output=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);process.waitUntilExit()
            try check(process.terminationStatus==0 && output.contains("keeper") && output.contains("200"),"A vanished PID aborted the process list")
        }
        try test("Full diagnostics records each bounded result and a manifest"){
            let stub=Stub(),engine=try newEngine(stub),report=try ModemInformationManager(engine:engine).collectDiagnostics()
            try check(report.files.count==ModemInformationManager.diagnosticCommands.count,"Missing diagnostics")
            for item in report.files {let data=try Data(contentsOf:report.url.appendingPathComponent(item.name));try check(!String(decoding:data,as:UTF8.self).contains("do-not-export") && item.sha256==digest(data) && item.status==0,"Unsafe or inconsistent export")}
            try check(FileManager.default.fileExists(atPath:report.url.appendingPathComponent("manifest.json").path),"No manifest")
        }
        print("\(passed) management-information tests passed")
    }
}
