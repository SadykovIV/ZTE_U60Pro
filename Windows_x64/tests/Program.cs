using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ZteImeiStudio.Windows.Core;

if (args.Contains("--component-cleanup-only")) { await ComponentCleanupTests.RunAsync(); return; }
if (args.Contains("--ready-reinstall-only")) { await ReadyReinstallTests.RunAsync(); return; }
if (args.Contains("--force-preparation-only")) { await ForcePreparationTests.RunAsync(); return; }

if (args.Contains("--installation-layout-only")) { await OnboardingLayoutTests.RunAsync(); return; }

if (args.Contains("--template-guard-only")) { BackupTemplateTests.Run(); return; }

if (args.Contains("--backup-key-only")) { await BackupKeyVerificationTests.RunAsync(); return; }

if (args.Contains("--access-reuse-only")) { await AccessAgentReuseTests.RunAsync(); return; }

if (args.Contains("--adb-stream-only")) { await AdbStreamingTests.RunAsync(); return; }

if (args.Contains("--discovery-only")) { await UniversalDiscoveryTests.RunAsync(); return; }

if (args.Contains("--adb-line-endings-only"))
{
    await AdbLineEndingTests.RunAsync(args.SkipWhile(x => x != "--adb-line-endings-only").Skip(1).FirstOrDefault());
    return;
}

static void Check(bool condition, string name)
{
    if (!condition) throw new Exception(name);
    Console.WriteLine("PASS " + name);
}

static void Reject(Action action, string name)
{
    try { action(); }
    catch { Console.WriteLine("PASS " + name); return; }
    throw new Exception("Unexpectedly accepted: " + name);
}

static byte[] Tar(params (string Path, byte[] Bytes)[] entries)
{
    using var output = new MemoryStream();
    foreach (var (path, bytes) in entries)
    {
        var header = new byte[512];
        void Put(int offset, string text) => Encoding.ASCII.GetBytes(text).CopyTo(header.AsSpan(offset));
        Put(0, path); Put(100, "0000775\0"); Put(108, "0000000\0"); Put(116, "0000000\0");
        Put(124, Convert.ToString(bytes.Length, 8)!.PadLeft(11, '0') + "\0");
        Put(136, "15100000000\0"); Put(148, "        "); header[156] = (byte)'0';
        Put(257, "ustar\0"); Put(263, "00"); Put(265, "root"); Put(297, "root");
        Put(148, Convert.ToString(header.Sum(x => (int)x), 8)!.PadLeft(6, '0') + "\0 ");
        output.Write(header); output.Write(bytes); output.Write(new byte[(512 - bytes.Length % 512) % 512]);
    }
    output.Write(new byte[2048]);
    return output.ToArray();
}

BackupTemplateTests.Run();
await BackupKeyVerificationTests.RunAsync();
await AdbRegressionTests.RunAsync();
await AdbLineEndingTests.RunAsync();
var vector = Convert.FromHexString("53616c7465645f5f0102030405060708dfdd29b2bf3250ec90f326f288ce2986644b9e7978318c0b");
Check(Encoding.UTF8.GetString(BackupCipher.Decrypt(vector, "synthetic-password")) == "B31 test payload\n",
    "OpenSSL 3DES SHA256 vector");

var rc = File.ReadAllBytes("Windows_x64/tests/fixtures/stock-usb-mode.synthetic.rc.local");
var inner = BackupGzip.Compress(Tar(("etc/config/test", Encoding.UTF8.GetBytes("safe\n")),
    ("etc/rc.local", rc)));
var md5 = Encoding.ASCII.GetBytes(Convert.ToHexString(MD5.HashData(inner)).ToLowerInvariant() + "\n");
var outer = BackupGzip.Compress(Tar(("tmp/back_parameter_r1.tgz", inner),
    ("tmp/back_parameter_r.md5", md5)));
const string testSuffix = "test-only-backup-key-suffix";
var imei = "353490068701222";
var encrypted = BackupCipher.Encrypt(outer, imei + testSuffix);
var patched = BackupPatch.Prepare(encrypted, imei, testSuffix);
Check(!patched.AlreadyEnabled && !encrypted.AsSpan().SequenceEqual(patched.PatchedEncrypted),
    "B31 backup patched");
var after = BackupPatch.Inspect(BackupCipher.Decrypt(patched.PatchedEncrypted,
    imei + testSuffix));
Check(Encoding.UTF8.GetString(after.Inner.Members.Single(m => m.Path == BackupPatch.RcPath).Bytes)
    .StartsWith("#!/bin/sh\n" + BackupPatch.EnableLine, StringComparison.Ordinal), "Only expected rc.local line inserted");
if (args.Contains("--backup-suffix-only")) { await DiagnosticAdbTests.RunAsync(encrypted,patched.PatchedEncrypted,testSuffix,true); return; }
await DiagnosticAdbTests.RunAsync(encrypted, patched.PatchedEncrypted, testSuffix);
var repeated = BackupPatch.Prepare(patched.PatchedEncrypted, imei, testSuffix);
Check(repeated.AlreadyEnabled && repeated.PatchedEncrypted.AsSpan().SequenceEqual(patched.PatchedEncrypted),
    "B31 backup patch idempotent");
Reject(() => BackupPatch.Prepare(encrypted, "353490068701223", testSuffix), "Invalid IMEI rejected");
Reject(() => BackupPatch.Prepare(encrypted, imei, "wrong"), "Wrong suffix rejected");
Reject(() => new BackupTar(Tar(("../etc/rc.local", rc))), "Tar path traversal rejected");
Reject(() => BackupGzip.Decompress(inner.Concat(inner).ToArray()), "Concatenated gzip rejected");
var disguisedTail = inner.Concat(new byte[] { 0x58 }).Concat(inner[^8..]).ToArray();
Reject(() => BackupGzip.Decompress(disguisedTail), "Gzip trailing data with matching trailer rejected");
var truncatedDeflate = inner[..^9].Concat(inner[^8..]).ToArray();
Reject(() => BackupGzip.Decompress(truncatedDeflate), "Gzip truncated deflate rejected");
var bad = inner.ToArray(); bad[^8] ^= 1;
Reject(() => BackupGzip.Decompress(bad), "Gzip CRC rejected");

var pending = new OnboardingPending { Id = Guid.NewGuid().ToString("D"), Phase = "prepared" };
Check(pending.CanRequestRestore(false, false), "Fresh journal permits one restore request");
string? saved = null;
var sent = 0;
try
{
    await pending.RequestRestoreOnceAsync(
        state => { saved = JsonSerializer.Serialize(state); return Task.CompletedTask; },
        () => { sent++; throw new TimeoutException("Synthetic disconnect after submission."); });
    throw new Exception("Expected synthetic disconnect");
}
catch (RestoreDeliveryUncertainException) { }
Check(saved is not null && sent == 1, "Journal persisted before uncertain restore response");
var resumed = JsonSerializer.Deserialize<OnboardingPending>(saved!)!;
Check(resumed.RestoreRequested && resumed.Phase == "restore-requested" &&
    !resumed.CanRequestRestore(false, false), "Restore journal prevents repeat after restart");
try
{
    await resumed.RequestRestoreOnceAsync(_ => Task.CompletedTask,
        () => { sent++; return Task.CompletedTask; });
    throw new Exception("Repeated restore was accepted");
}
catch (InvalidOperationException) { }
Check(sent == 1, "Restore request was not repeated");
resumed.InstallRequested = true;
var installResumed = JsonSerializer.Deserialize<OnboardingPending>(JsonSerializer.Serialize(resumed))!;
Check(!installResumed.CanStartInstallation && !installResumed.CanRequestRestore(false, false),
    "Install journal prevents replay after restart");

var inventory = new SystemBackupInventory(1, new string('a', 32),
    Guid.NewGuid().ToString("D"), ImeiEngine.FirmwareHash, new string('b', 64),
    512, false, "ROOT_NOT_RAM", "live-non-atomic",
    [new("mmcblk0", "/dev/mmcblk0", 512, 1, 512, 512),
     new("mmcblk0boot0", "/dev/mmcblk0boot0", 512, 1, 512, 512),
     new("mmcblk0boot1", "/dev/mmcblk0boot1", 512, 1, 512, 512)],
    [new("mmcblk0p1", "test", 1, 0, 1)]);
SystemBackupManager.ValidateInventory(inventory);
Check(true, "Full eMMC inventory accepted");
Reject(() => SystemBackupManager.ValidateInventory(inventory with
    { Devices = inventory.Devices.Reverse().ToArray() }), "Swapped eMMC regions rejected");
var tempRoot = Path.Combine(Path.GetTempPath(), "zte-full-backup-test-" + Guid.NewGuid().ToString("N"));
var backupId = Guid.NewGuid().ToString("D");
var backupDir = Path.Combine(tempRoot, "SystemBackups", backupId);
Directory.CreateDirectory(backupDir);
try
{
    var files = new List<SystemBackupFile>();
    var chunks = new List<SystemBackupChunk>();
    for (var index = 0; index < inventory.Devices.Length; index++)
    {
        var device = inventory.Devices[index];
        var bytes = Enumerable.Repeat((byte)(index + 1), 512).ToArray();
        File.WriteAllBytes(Path.Combine(backupDir, device.FileName), bytes);
        var digest = Convert.ToHexStringLower(SHA256.HashData(bytes));
        files.Add(new SystemBackupFile(device.FileName, device.Source, bytes.Length, digest));
        chunks.Add(new SystemBackupChunk(device.Name, 0, bytes.Length, digest));
    }
    var manifest = new SystemBackupManifest(1, backupId, DateTimeOffset.UtcNow,
        inventory, "live-non-atomic", files.ToArray(), chunks.ToArray(), true,
        "Synthetic full eMMC", "Synthetic non-atomic snapshot");
    File.WriteAllText(Path.Combine(backupDir, "manifest.json"), JsonSerializer.Serialize(manifest,
        new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
    Check(SystemBackupManager.List(tempRoot).Count == 1,
        "Full eMMC list includes only complete metadata");
    var verified = await SystemBackupManager.VerifyStoredAsync(tempRoot, backupId);
    Check(verified.Files.Length == 3, "Full eMMC image and chunk SHA256 verified");
    var changedPath = Path.Combine(backupDir, "mmcblk0boot1.bin");
    var changed = File.ReadAllBytes(changedPath); changed[0] ^= 1; File.WriteAllBytes(changedPath, changed);
    Check(SystemBackupManager.List(tempRoot).Count == 1,
        "Fast list reads metadata without rehashing images");
    try
    {
        await SystemBackupManager.VerifyStoredAsync(tempRoot, backupId);
        throw new Exception("Tampered eMMC backup was accepted");
    }
    catch (InvalidDataException) { }
    Check(true, "Tampered eMMC image rejected");
}
finally { Directory.Delete(tempRoot, recursive: true); }
Console.WriteLine("ALL SYNTHETIC CHECKS PASSED");

Check(AgentPackage.VersionForHash(AgentPackage.LegacyPublicSha256) == "2.8.0" && AgentPackage.SupportsVpn(AgentPackage.LegacyPublicSha256), "Previous public agent 2.8.0 remains recognized");
Reject(() => BackupPatch.Prepare(encrypted, imei, ""), "Low-level backup codec still requires an explicit suffix");

Check(AgentPackage.SupportedUpgradeHashes.Contains(AgentPackage.LegacyPublicSha256) && !AgentPackage.SupportedUpgradeHashes.Contains(new string('f',64)), "Public legacy agent accepted; unknown upgrade hash rejected");
