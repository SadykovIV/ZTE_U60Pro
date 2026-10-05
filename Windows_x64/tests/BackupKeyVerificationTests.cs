using System.Text.Json;
using ZteImeiStudio.Transport;
using ZteImeiStudio.Windows.Core;

internal static class BackupKeyVerificationTests
{
    private static readonly WebIdentity B28 = new("353490068701222", "FLY_CN_MU5250V1.0.0B13", "BD_FLYMODEMMU5250V1.0.0B28");
    private static void Check(bool value, string name) { if (!value) throw new Exception(name); Console.WriteLine("PASS " + name); }
    public static async Task RunAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "zte-backup-key-tests-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        var known = File.ReadAllBytes("Windows_x64/tests/fixtures/b31-auto-backup.synthetic.bin");
        var counter = 0;
        (OnboardingEngine Engine, Wire Web, string Storage, List<string> Log) Setup(WebIdentity? identity = null)
        {
            var storage = Path.Combine(root, (++counter).ToString());
            var wire = new Wire(identity ?? B28, known); var log = new List<string>();
            var adb = new AdbTransport((_, _, _) => { wire.AdbCalls++; throw new Exception("Unexpected ADB access"); });
            return (new OnboardingEngine("192.0.2.1", storage, "absent-resources", adb, progress: log.Add)
                { WebFactory = () => new ModemWebClient("192.0.2.1", wire) }, wire, storage, log);
        }
        async Task<Exception> Reject(Func<Task> action, string label)
        {
            try { await action(); } catch (Exception error) { Check(true, label); return error; }
            throw new Exception("Unexpected acceptance: " + label);
        }
        void NoWrites(Wire wire, string name) => Check(wire.AdbCalls == 0 && wire.ForbiddenCalls == 0, name);
        try
        {
            foreach (var identity in new[] { B28, B28 with { Firmware = "CN_ZTE_MU5250V1.0.0B31", Inner = "BD_CNMU5250V1.0.0B31" }, B28 with { Firmware = "UNLISTED_1", Inner = "UNLISTED_2" }, B28 with { Firmware = "Generic build "+new string('a',130), Inner = "Inner version 2" } })
            {
                var test = Setup(identity);
                var result = await test.Engine.VerifyBackupKeyAsync("synthetic-web-password");
                Check(result.Firmware == identity.Firmware && result.InnerVersion == identity.Inner && result.Entries > 0 && result.EncryptedSha256 == VerifiedHash.Sha256(known), "Fresh backup key check reports observed firmware and exact encrypted hash");
                Check(test.Web.IdentityReads == 2 && test.Web.Backups == 1 && test.Web.Downloads == 1, "Read-only key check freshly binds one backup between two identities");
                NoWrites(test.Web, "Key check does not access ADB, upload, restore, reboot or install");
                Check(Directory.GetFiles(result.Directory).Select(Path.GetFileName).Order().SequenceEqual(new[] { "back_parameter.original", "identity.json", "manifest.json" }), "Only encrypted original, private identity and manifest are saved");
                Check(File.ReadAllBytes(Path.Combine(result.Directory, "back_parameter.original")).SequenceEqual(known), "Encrypted original is byte-preserved");
                Check(!Directory.Exists(Path.Combine(test.Storage, "SSH")) && !Directory.EnumerateFiles(test.Storage, "*pending*", SearchOption.AllDirectories).Any(), "Read-only verification creates no SSH or pending write authorization");
                var metadata = File.ReadAllText(Path.Combine(result.Directory, "manifest.json")) + JsonSerializer.Serialize(result) + string.Join('\n', test.Log);
                Check(!metadata.Contains(identity.Imei) && !metadata.Contains("synthetic-web-password") && !metadata.Contains(OnboardingEngine.ResolveBackupKeySuffix(B28 with { Firmware = "CN_ZTE_MU5250V1.0.0B31", Inner = "BD_CNMU5250V1.0.0B31" }, "")), "Result and log contain no IMEI, password or key suffix");
            }
            var explicitCheck = Setup();
            const string explicitKey = "synthetic-manual-key";
            var validIdentity = B28 with { Firmware = "CN_ZTE_MU5250V1.0.0B31", Inner = "BD_CNMU5250V1.0.0B31" };
            var plain = BackupCipher.Decrypt(known, B28.Imei + OnboardingEngine.ResolveBackupKeySuffix(validIdentity, ""));
            explicitCheck.Web.Backup = BackupCipher.Encrypt(plain, B28.Imei + explicitKey);
            await explicitCheck.Engine.VerifyBackupKeyAsync("pw", explicitKey);
            NoWrites(explicitCheck.Web, "Manual key check succeeds without firmware allowlist or device writes");
            var wrong = Setup();
            var wrongError = await Reject(() => wrong.Engine.VerifyBackupKeyAsync("pw", "wrong-manual-key"), "Wrong explicit key never falls back to known key");
            Check(wrongError.Message == "Не удалось подтвердить ключ или формат архива бэкапа.", "Crypto failure uses neutral key/format wording without firmware compatibility claim");
            NoWrites(wrong.Web, "Wrong key causes no device writes");
            using (var manifest = JsonDocument.Parse(File.ReadAllText(Directory.GetFiles(wrong.Storage, "manifest.json", SearchOption.AllDirectories).Single())))
                Check(!manifest.RootElement.GetProperty("formatVerified").GetBoolean(), "Failed key check preserves encrypted original with unverified manifest");
            var corrupt = Setup(); corrupt.Web.Backup = known.ToArray(); corrupt.Web.Backup[^1] ^= 1;
            await Reject(() => corrupt.Engine.VerifyBackupKeyAsync("pw"), "Corrupt encrypted backup is rejected"); NoWrites(corrupt.Web, "Corrupt backup causes no writes");
            var invalid = Setup(); invalid.Web.Backup = BackupCipher.Encrypt("not-a-gzip-archive"u8.ToArray(), B28.Imei + explicitKey);
            await Reject(() => invalid.Engine.VerifyBackupKeyAsync("pw", explicitKey), "Valid decryption with invalid archive structure is rejected"); NoWrites(invalid.Web, "Invalid format causes no writes");
            var changed = Setup(); changed.Web.ChangeIdentity = true;
            await Reject(() => changed.Engine.VerifyBackupKeyAsync("pw"), "Changed identity during download refuses verification"); NoWrites(changed.Web, "Changed identity causes no writes");
            Check(!Directory.Exists(Path.Combine(changed.Storage, "BackupKeyChecks")), "Changed identity cannot save a verified archive association");
            foreach (var value in new[] { "bad\0key", new string('x', 129) })
            {
                var invalidKey = Setup(); await Reject(() => invalidKey.Engine.VerifyBackupKeyAsync("pw", value), "Invalid explicit key input refused before network");
                Check(invalidKey.Web.Requests == 0, "Invalid key syntax makes no Web request");
            }
            var pending = Setup(); Directory.CreateDirectory(pending.Storage);
            File.WriteAllText(Path.Combine(pending.Storage,"setup-pending.json"),"synthetic untouched pending");
            await pending.Engine.VerifyBackupKeyAsync("pw");
            Check(File.ReadAllText(Path.Combine(pending.Storage,"setup-pending.json"))=="synthetic untouched pending","Read-only key check does not require or alter pending write journal");
            NoWrites(pending.Web,"Pending write journal does not make key check execute a write");
            var leased=Setup();Directory.CreateDirectory(leased.Storage);
            using(var lease=new FileStream(Path.Combine(leased.Storage,"operation.lock"),FileMode.Create,FileAccess.ReadWrite,FileShare.None))
            {
                await Reject(()=>leased.Engine.VerifyBackupKeyAsync("pw"),"Actual active operation lease blocks simultaneous key check");
                Check(leased.Web.Requests==0,"Active lease prevents Web request");
            }
            var noPassword = Setup(); await Reject(() => noPassword.Engine.VerifyBackupKeyAsync(""), "Key check requires Web password only"); Check(noPassword.Web.Requests == 0, "Empty Web password makes no request");
            var writeGate = Setup();
            await writeGate.Engine.VerifyBackupKeyAsync("pw");
            Check(!Directory.EnumerateFiles(writeGate.Storage,"*pending*",SearchOption.AllDirectories).Any(), "Successful B28 key check does not create write authorization");
            NoWrites(writeGate.Web, "Successful read-only B28 check remains read-only");
        }
        finally { Directory.Delete(root, true); }
    }
    private sealed class Wire(WebIdentity identity, byte[] backup) : IWebTransport
    {
        public byte[] Backup = backup;
        public bool ChangeIdentity;
        public int Requests, IdentityReads, Backups, Downloads, ForbiddenCalls, AdbCalls;
        public Task<WebReply> RequestAsync(string path, byte[]? data = null, string? contentType = null, string? cookie = null, CancellationToken ct = default)
        {
            Requests++;
            var headers = new Dictionary<string, string[]>();
            if (path == "/backup/back_parameter") { Downloads++; return Task.FromResult(new WebReply(Backup, headers)); }
            if (path != "/ubus/") { ForbiddenCalls++; throw new Exception("Unexpected upload or endpoint"); }
            using var doc = JsonDocument.Parse(data!);
            var p = doc.RootElement[0].GetProperty("params");
            object reply;
            switch (p[2].GetString())
            {
                case "web_login_info": reply = new { zte_web_sault = "synthetic" }; break;
                case "web_login": reply = new { result = 0, ubus_rpc_session = "11111111111111111111111111111111" }; headers["Set-Cookie"] = ["webtoken=synthetic; Path=/"]; break;
                case "device_info": IdentityReads++; reply = new { imei = identity.Imei, integrate_version = ChangeIdentity && IdentityReads > 1 ? "CHANGED" : identity.Firmware, wa_inner_version = identity.Inner }; break;
                case "device_backup_proc": Backups++; reply = new { }; break;
                default: ForbiddenCalls++; throw new Exception("Unexpected write or control method");
            }
            return Task.FromResult(new WebReply(JsonSerializer.SerializeToUtf8Bytes(new[] { new { result = new object[] { 0, reply } } }), headers));
        }
    }
}
