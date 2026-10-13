import Foundation
private func check(_ value: Bool, _ label: String) throws { if !value { throw IMEIError.message(label) }; print("PASS " + label) }
private let qmi = #"{"schema":1,"observations":{"slot_status":{"status":"observed","qmi_result":0,"qmi_error":0,"slots":[{"physical_index":2,"is_euicc":true,"eid_length":16,"eid":"SECRET_EID"}]}},"identifiers_exported":false,"radio_reset":false,"slot_switch":false,"apdu_performed":false,"profile_mutation":false,"provisioning_proven":false,"password":"SECRET"}"#
private final class Wire: RemoteTransport {
    var commands=[String](); var failFirst=false
    func run(_ command:String,input:Data?,timeout:TimeInterval)throws->CommandResult {
        commands.append(command)
        if command.hasPrefix("cat > ") {
            let parts=command.components(separatedBy:"'");let path=parts[1]
            return .init(status:0,stdout:Data((digest(input!) + "  " + path + "\n").utf8),stderr:Data())
        }
        if command.hasPrefix("test ") {
            if command.hasSuffix("--inspect-nv550") && failFirst { throw IMEIError.message("PRIVATE_TRANSPORT_ERROR") }
            let result=command.hasSuffix("--inspect-current-card") ? qmi : command.hasSuffix("--inspect-nv550") ? "SUPPORT_NV_V1\nSUPPORT_NV_RESULT outcome=20 released=1 deinit=1 writes=0\n" : "SUPPORT_CONFIG_V1\nSUPPORT_CONFIG_RESULT outcome=0 file_closed=1 released=1 deinit=1 writes=0\n"
            return .init(status:command.hasSuffix("--inspect-nv550") ? 20:0,stdout:Data(result.utf8),stderr:Data("PRIVATE_STDERR".utf8))
        }
        return .init(status:0,stdout:Data(),stderr:Data())
    }
}
@main struct FirmwareRadioSupportTests {
 static func main() throws {
    let good=FirmwareRadioSupport.output(.init(status:0,stdout:Data(qmi.utf8),stderr:Data()),header:"")
    try check(!good.contains("SECRET") && good.contains("is_euicc") && good.contains("physical_index"),"QMI preserves slot observations and removes extra identifiers")
    let c="SUPPORT_NV_V1\nSUPPORT_NV_RESULT outcome=20 released=1 deinit=1 writes=0\nSUPPORT_NV_SECRET password=PRIVATE\nPAIR_REQUEST label=read_index0 send=0 length=138 status=0 diag_error=-1 verified=1\nAPP_NV PRIVATE\nEFS_DATA_HEX data=PRIVATE\n"
    let safe=FirmwareRadioSupport.output(.init(status:20,stdout:Data(c.utf8),stderr:Data("PRIVATE".utf8)),header:"SUPPORT_NV_V1")
    try check(!safe.contains("PRIVATE") && safe.contains("PAIR_REQUEST") && safe.contains("exit_code=20"),"DIAG output projects known fields and preserves failure code")
    for invalid in [qmi.replacingOccurrences(of:"\"radio_reset\":false",with:"\"radio_reset\":true"),"not-json"] {
        try check(FirmwareRadioSupport.output(.init(status:0,stdout:Data(invalid.utf8),stderr:Data()),header:"").contains("invalid_output"),"invalid or mutating report refused")
    }
    let wire=Wire();wire.failFirst=true
    let res=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
    let result=try FirmwareRadioSupport.collect(resources:res,remote:wire,root:true,cancelled:{false})
    try check(result.count==3 && String(decoding:result["zte-support-nv.txt"]!,as:UTF8.self).contains("not_assessed"),"one unavailable native query preserves other reports")
    try check(!result.values.contains{String(decoding:$0,as:UTF8.self).contains("PRIVATE")},"native failures never export transport details")
    try check(wire.commands.filter{$0.hasPrefix("test ")}.count==3 && wire.commands.last!.hasPrefix("rm -f "),"three read queries run once and temporary tools are cleaned")
    let nonroot=Wire();let skipped=try FirmwareRadioSupport.collect(resources:res,remote:nonroot,root:false,cancelled:{false})
    try check(nonroot.commands.isEmpty && skipped.count==1,"nonroot collection does not start native tools")
    let cancelled=Wire()
    do { _=try FirmwareRadioSupport.collect(resources:res,remote:cancelled,root:true,cancelled:{true}); throw IMEIError.message("cancellation ignored") }
    catch { try check(cancelled.commands.count==2 && cancelled.commands.last!.hasPrefix("rm -f "),"cancelled collection cleans stage without running probes") }
 }
}
