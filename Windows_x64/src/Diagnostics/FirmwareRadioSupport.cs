using System.Text.RegularExpressions;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;
namespace ZteImeiStudio.Windows.Diagnostics;

internal static class FirmwareRadioSupport
{
    internal static readonly (string Name,string Argument,string Header)[] Probes = [
        ("zte-support-nv","--inspect-nv550","SUPPORT_NV_V1"),
        ("zte-support-config","--inspect-config","SUPPORT_CONFIG_V1"),
        ("zte-support-qmi","--inspect-current-card","")];
    internal static readonly Dictionary<string,string> Hashes = new() {
        ["zte-support-nv"] = "d41b1d537a0f690cc8dc954bd63bb2f41179e862a76818c650ee0b66346d3c76",
        ["zte-support-config"] = "61cfce1263c9c882eccf2303b93f83fa3f0e96919ed7da60e690df5a148fa262",
        ["zte-support-qmi"] = "8ae8a370596c1369b6c03c9fe5c048dccd83e8dda6b0947b4204b407934d2d0d",
    };
    static readonly string[] LinePatterns = [
        @"^EFS_CLOSE fd=-?[0-9]{1,10} verified=-?[0-9]{1,10}$",
        @"^EFS_EARLY_RELEASE -?[0-9]{1,10}$",
        @"^EFS_OPEN fd=-?[0-9]{1,10} errno=-?[0-9]{1,10} flags=0 mode=0$",
        @"^EFS_OPEN_NO_VALID_DESCRIPTOR$",
        @"^EFS_OPEN_OWNERSHIP_UNCERTAIN$",
        @"^EFS_OWNER ret=-?[0-9]{1,10} pid=-?[0-9]{1,10} self=-?[0-9]{1,10}$",
        @"^EFS_READ fd=-?[0-9]{1,10} offset=-?[0-9]{1,10} requested=-?[0-9]{1,10} returned=-?[0-9]{1,10} errno=-?[0-9]{1,10} exact=-?[0-9]{1,10}$",
        @"^EFS_RELEASE ret=-?[0-9]{1,10} owner=-?[0-9]{1,10} local_mode=-?[0-9]{1,10}$",
        @"^EFS_RELEASE_OWNERSHIP_UNCERTAIN$",
        @"^EFS_REQUEST label=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) send=-?[0-9]{1,10} length=-?[0-9]{1,10} diag_error=-?[0-9]{1,10} crc_valid=-?[0-9]{1,10}$",
        @"^EFS_RESULT outcome=-?[0-9]{1,10} bytes=-?[0-9]{1,10} file_closed=-?[0-9]{1,10} released=-?[0-9]{1,10} deinit=-?[0-9]{1,10} signal=-?[0-9]{1,10} crc_verified_frames=-?[0-9]{1,10} bad_crc_frames=-?[0-9]{1,10}$",
        @"^EFS_SESSION_OPEN -?[0-9]{1,10}$",
        @"^EFS_STAT label=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) errno=-?[0-9]{1,10} mode=0x[0-9a-f]{1,8} size=-?[0-9]{1,10} nlink=-?[0-9]{1,10}$",
        @"^PAIR_EARLY_RELEASE -?[0-9]{1,10}$",
        @"^PAIR_FRAME_BAD_CRC$",
        @"^PAIR_OPEN_OWNERSHIP_UNCERTAIN$",
        @"^PAIR_OWNER ret=-?[0-9]{1,10} pid=-?[0-9]{1,10} self=-?[0-9]{1,10}$",
        @"^PAIR_RELEASE ret=-?[0-9]{1,10} owner=-?[0-9]{1,10} local_mode=-?[0-9]{1,10}$",
        @"^PAIR_RELEASE_OWNERSHIP_UNCERTAIN$",
        @"^PAIR_REQUEST label=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) send=-?[0-9]{1,10} length=-?[0-9]{1,10} status=-?[0-9]{1,10} diag_error=-?[0-9]{1,10} verified=-?[0-9]{1,10}$",
        @"^PAIR_RESULT outcome=-?[0-9]{1,10} write_attempts=-?[0-9]{1,10} released=-?[0-9]{1,10} deinit=-?[0-9]{1,10} signal=-?[0-9]{1,10}$",
        @"^PAIR_SESSION_OPEN -?[0-9]{1,10}$",
        @"^PAIR_SNAPSHOT readable=-?[0-9]{1,10} legacy_alias=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_FLAG102 offset=-?[0-9]{1,10} length=-?[0-9]{1,10} value=-?[0-9]{1,10} b31_layout=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_FORMAT bytes=-?[0-9]{1,10} magic_known=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_HEADER records=-?[0-9]{1,10} declared_size=-?[0-9]{1,10} length_valid=-?[0-9]{1,10} trailer_known=-?[0-9]{1,10} crc_valid=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_LOAD library=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_RECORD index=-?[0-9]{1,10} id=-?[0-9]{1,10} offset=-?[0-9]{1,10} length=-?[0-9]{1,10} reserved_zero=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_RESPONSE label=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) unmatched_frames=-?[0-9]{1,10} last_unmatched_length=-?[0-9]{1,10} last_unmatched_opcode=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_RESULT outcome=-?[0-9]{1,10} file_closed=-?[0-9]{1,10} released=-?[0-9]{1,10} deinit=-?[0-9]{1,10} writes=0$",
        @"^SUPPORT_CONFIG_STRUCTURE valid=-?[0-9]{1,10} reason=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) consumed=-?[0-9]{1,10} flag102_count=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_STRUCTURE valid=0 reason=duplicate_id index=-?[0-9]{1,10} id=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_STRUCTURE valid=0 reason=invalid_header$",
        @"^SUPPORT_CONFIG_STRUCTURE valid=0 reason=invalid_record index=-?[0-9]{1,10} offset=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_STRUCTURE valid=0 reason=truncated_record index=-?[0-9]{1,10} offset=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_STRUCTURE valid=0 reason=unknown_header$",
        @"^SUPPORT_CONFIG_SYMBOLS init=-?[0-9]{1,10} deinit=-?[0-9]{1,10} callback=-?[0-9]{1,10} send=-?[0-9]{1,10} ioctl=-?[0-9]{1,10} fd=-?[0-9]{1,10} mode=-?[0-9]{1,10}$",
        @"^SUPPORT_CONFIG_V1$",
        @"^SUPPORT_NV_LOAD library=-?[0-9]{1,10}$",
        @"^SUPPORT_NV_RECORD index=-?[0-9]{1,10} readable=-?[0-9]{1,10} encoding_valid=-?[0-9]{1,10}$",
        @"^SUPPORT_NV_RESPONSE label=(read_legacy|read_index0|read_index1|before|after|open_readonly|read|close|trailing_data|invalid_crc|complete) unmatched_frames=-?[0-9]{1,10} last_unmatched_length=-?[0-9]{1,10} last_unmatched_opcode=-?[0-9]{1,10}$",
        @"^SUPPORT_NV_RESULT outcome=-?[0-9]{1,10} released=-?[0-9]{1,10} deinit=-?[0-9]{1,10} writes=0$",
        @"^SUPPORT_NV_STRUCTURE legacy_readable=-?[0-9]{1,10} legacy_alias=-?[0-9]{1,10} crc_verified_frames=-?[0-9]{1,10} bad_crc_frames=-?[0-9]{1,10}$",
        @"^SUPPORT_NV_SYMBOLS init=-?[0-9]{1,10} deinit=-?[0-9]{1,10} callback=-?[0-9]{1,10} send=-?[0-9]{1,10} ioctl=-?[0-9]{1,10} fd=-?[0-9]{1,10} mode=-?[0-9]{1,10}$",
        @"^SUPPORT_NV_V1$"
    ];
    static object? Project(JsonElement value, string key)
    {
        if(new[]{"observations","operating_mode","card_status","slot_status","root"}.Contains(key) && value.ValueKind==JsonValueKind.Object)
            return value.EnumerateObject().Select(p=>(p.Name,Value:Project(p.Value,p.Name))).Where(p=>p.Value is not null).ToDictionary(p=>p.Name,p=>p.Value);
        if(new[]{"cards","slots","applications"}.Contains(key) && value.ValueKind==JsonValueKind.Array && value.GetArrayLength()<=32)
            return value.EnumerateArray().Select(v=>Project(v,"root")).Where(v=>v is not null).ToArray();
        if(new[]{"primary_gw_index","primary_1x_index","secondary_gw_index","secondary_1x_index","schema","qmi_result","qmi_error","mode","logical_index","state","error","type","aid_length","physical_index","card_state","slot_state","logical_slot","iccid_length","protocol","application_count","atr_length","eid_length"}.Contains(key) && value.ValueKind==JsonValueKind.Number && value.TryGetUInt32(out var n))return n;
        if(new[]{"identifiers_exported","radio_reset","slot_switch","profile_mutation","apdu_performed","provisioning_proven","is_euicc"}.Contains(key) && value.ValueKind is JsonValueKind.True or JsonValueKind.False)return value.GetBoolean();
        if(value.ValueKind==JsonValueKind.String){var text=value.GetString();
            if(key=="status" && text is "observed" or "not_assessed")return text;
            if(key=="reason" && new[]{"missing_field","duplicate_field","length_overflow","truncated_field","trailing_bytes","card_count","application_count","slot_count","slot_enum","slot_array_count","euicc_enum","result_length","mode_length","operation_not_readonly","service_unavailable","request_failed"}.Contains(text))return text;
        }
        return null;
    }
    internal static string Output(RemoteResult result,string header)
    {
        if(result.Stdout.Length>131072)return "status=invalid_output\n";
        string raw;try{raw=new UTF8Encoding(false,true).GetString(result.Stdout);}catch(DecoderFallbackException){return "status=invalid_output\n";}
        if(header.Length==0){
            try{using var json=JsonDocument.Parse(raw);var obj=json.RootElement;
                if(obj.GetProperty("schema").GetInt32()!=1 || new[]{"identifiers_exported","radio_reset","slot_switch","profile_mutation","apdu_performed"}.Any(k=>obj.GetProperty(k).GetBoolean()))return "status=invalid_output\n";
                return JsonSerializer.Serialize(Project(obj,"root"))+"\n";
            }catch(Exception ex)when(ex is JsonException or InvalidOperationException or KeyNotFoundException){return "status=invalid_output\n";}
        }
        if(!raw.Split('\n').Contains(header))return "status=missing_summary\nexit_code="+result.ExitCode+"\n";
        var lines=raw.Split('\n').Where(l=>l.All(c=>c>=32&&c<=126)&&LinePatterns.Any(p=>Regex.IsMatch(l,p,RegexOptions.CultureInvariant,TimeSpan.FromSeconds(1))));
        return string.Join('\n',lines)+"\nexit_code="+result.ExitCode+"\n";
    }
    internal static async Task<Dictionary<string,byte[]>> CollectAsync(string resources,IRemoteShell shell,bool root,CancellationToken ct)
    {
        if(!root)return new(){["native-status.txt"]=Encoding.UTF8.GetBytes("status=not_assessed reason=root_required\n")};
        var folder=Path.Combine(resources,"FirmwareSupport");
        var manifest=JsonSerializer.Deserialize<Dictionary<string,string>>(File.ReadAllBytes(Path.Combine(folder,"SHA256.json")))!;
        var payloads=new Dictionary<string,byte[]>();
        foreach(var probe in Probes){var path=Path.Combine(folder,probe.Name);if(new FileInfo(path).Length>8*1024*1024)throw new InvalidDataException(FirmwareSupportCollector.Failed);
            var bytes=File.ReadAllBytes(path);var hash=FirmwareSupportCollector.Sha(bytes);
            if(!Hashes.TryGetValue(probe.Name,out var expected)||hash!=expected||manifest.GetValueOrDefault(probe.Name)!=hash)throw new InvalidDataException("Повреждён встроенный сборщик данных для адаптации");payloads.Add(probe.Name,bytes);}
        var stage="/tmp/zte-support-"+Guid.NewGuid().ToString("D");var quote=VerifiedHash.ShellQuote;
        var created=await shell.RunAsync("umask 077; mkdir "+quote(stage),timeout:TimeSpan.FromSeconds(15),ct:ct);
        if(!created.Success)throw new InvalidDataException("Не удалось создать временный каталог исследования");
        var results=new Dictionary<string,byte[]>();
        try{foreach(var probe in Probes){ct.ThrowIfCancellationRequested();var path=stage+"/"+probe.Name;var expected=Hashes[probe.Name];
            var uploaded=await shell.RunAsync("cat > "+quote(path)+" && chmod 700 "+quote(path)+" && sha256sum "+quote(path),payloads[probe.Name],TimeSpan.FromSeconds(30),ct);
            if(!uploaded.Success||!Encoding.UTF8.GetString(uploaded.Stdout).Split((char[]?)null,StringSplitOptions.RemoveEmptyEntries).SequenceEqual(new[]{expected,path}))throw new InvalidDataException("При передаче повреждён диагностический помощник");
            var command="test \"$(sha256sum "+quote(path)+" | cut -d ' ' -f1)\" = "+quote(expected)+" && "+quote(path)+" "+probe.Argument;
            try{var reply=await shell.RunAsync(command,timeout:TimeSpan.FromSeconds(150),ct:ct);results[probe.Name+".txt"]=Encoding.UTF8.GetBytes(Output(reply,probe.Header));}
            catch(OperationCanceledException) when(ct.IsCancellationRequested){throw;}
            catch{ct.ThrowIfCancellationRequested();results[probe.Name+".txt"]=Encoding.UTF8.GetBytes("status=not_assessed reason=transport_or_probe_failure\n");}
        }}finally{try{await shell.RunAsync("rm -f "+string.Join(" ",Probes.Select(p=>quote(stage+"/"+p.Name)))+"; rmdir "+quote(stage),timeout:TimeSpan.FromSeconds(15),ct:CancellationToken.None);}catch{/* The session's final continuity check determines whether export can finish. */}}
        return results;
    }
}
