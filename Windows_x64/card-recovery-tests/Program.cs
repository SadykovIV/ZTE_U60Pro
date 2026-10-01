using System.Text;
using System.Text.Json;
using ZteImeiStudio.Windows.Esim;

// Only synthetic NDJSON and in-memory streams. No modem, network or settings.
var root = Path.GetFullPath(args.Single());
var catalog = JsonSerializer.Deserialize<string[]>(File.ReadAllText(Path.Combine(root, "Windows_x64/card-recovery-tests/component-error-codes.json")))!;
var english = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Path.Combine(root, "Windows_x64/Resources/Localization/en.json")))!;
int checks = 0;
void Check(bool value, string name) { if (!value) throw new Exception(name); checks++; }
async Task<EsimResult> Parse(string frames)
{
    using var output = new MemoryStream(Encoding.UTF8.GetBytes(frames)); using var input = new MemoryStream();
    return await EsimProtocol.ExchangeAsync(output, input, new() { Operation = "list" }, (_, _) => throw new Exception("Unexpected HTTP"), null, CancellationToken.None);
}
string Failure(string code, object? cause) => JsonSerializer.Serialize(new { type = "result", ok = false, error = code, component_error = cause, raw_stderr = "PRIVATE-STDERR", iccid = "89000000000000000001" }) + "\n";
Check(catalog.Length == 51, "fixed catalog count");
foreach (var cause in catalog)
{
    Check(EsimDiagnostics.SafeComponentError(cause) == cause, "fixed cause retained");
    var result = await Parse(Failure("card_open_rejected", cause));
    Check(!result.Ok && result.Error == "card_open_rejected" && result.ComponentError == cause, "typed final cause retained");
}
foreach (var code in new[] { "card_busy", "card_open_rejected", "card_cleanup_unknown", "card_not_ready", "card_reset_failed", "card_power_restore_failed" })
{
    Check(EsimDiagnostics.SafeError(code) == code, "fixed card error retained");
    var message = EsimDiagnostics.FailureMessage(code);
    Check(english.TryGetValue(message, out var translated) && translated != message, "RU and EN error available");
    var result = await Parse(Failure(code, "qmi_open_rejected"));
    var lines = new List<string>(); var journal = new EsimJournal("list", (_, text) => lines.Add(text));
    journal.BackendResult(result);
    try { _ = EsimProtocol.Completed(result, 1); throw new Exception("Accepted failed process"); }
    catch (EsimException error)
    {
        Check(error.Code == code && error.ComponentError == "qmi_open_rejected", "exit1 retains fixed error and cause");
        journal.Finish(false, error.Code, true, componentError: error.ComponentError);
    }
    Check(lines.Count(line => line.Contains("component_error=qmi_open_rejected")) == 2, "backend and final journal preserve cause");
    Check(!lines.Any(line => line.Contains("PRIVATE") || line.Contains("890000")), "no private fields logged");
}
Check(EsimDiagnostics.FailureMessage("card_cleanup_unknown").Contains("перезагрузите"), "cleanup unknown requires reboot");
Check(EsimDiagnostics.FailureMessage("card_not_ready").Contains("Подождите"), "not ready asks to wait");
Check(EsimDiagnostics.FailureMessage("card_reset_failed").Contains("Перезапуск SIM не подтверждён"), "reset remains unconfirmed");
Check(EsimDiagnostics.FailureMessage("card_power_restore_failed").Contains("Перезагрузите модем"), "power restore failure requires reboot");
foreach (var code in new[] { "card_reset_failed", "card_power_restore_failed" })
    Check(EsimDiagnostics.SafeComponentError(code) is null, "agent errors never enter helper catalog");
foreach (object? unsafeCause in new object?[] { "PRIVATE-STDERR", "qmi_open_rejected\nPRIVATE", 123, null, new { error = "qmi_open_rejected" } })
{
    var result = await Parse(Failure("card_open_rejected", unsafeCause));
    Check(result.ComponentError is null, "unrecognized component discarded");
    var lines = new List<string>(); var journal = new EsimJournal("PRIVATE", (_, text) => lines.Add(text));
    journal.BackendResult(result); journal.Finish(false, "PRIVATE", true, componentError: unsafeCause as string);
    Check(!string.Join("\n", lines).Contains("PRIVATE"), "unknown text never enters log");
}
foreach (var frames in new[] {
    "{\"type\":\"result\",\"ok\":false,\"error\":\"card_busy\",\"error\":\"PRIVATE\"}\n",
    "{\"type\":\"result\",\"ok\":false,\"component_error\":\"qmi_open_rejected\",\"component_error\":\"PRIVATE\"}\n",
    Failure("card_busy", "qmi_open_rejected") + Failure("card_busy", "qmi_open_rejected"),
    Failure("card_busy", "qmi_open_rejected").TrimEnd(),
    "{\"type\":\"result\",\"ok\":true,\"component_error\":\"qmi_open_rejected\"}\n"
})
{
    bool rejected = false; try { await Parse(frames); } catch { rejected = true; }
    Check(rejected, "duplicate/truncated/contradictory final rejected");
}
var oldFailure = await Parse("{\"type\":\"result\",\"ok\":false,\"error\":\"snapshot_cleanup_failed\"}\n");
Check(oldFailure.ComponentError is null && oldFailure.Error == "snapshot_cleanup_failed", "old result remains compatible");
var fabricated = new EsimResult(false, null, false, false, "PRIVATE", ComponentError: "PRIVATE");
var fabricatedLines = new List<string>(); new EsimJournal("list", (_, text) => fabricatedLines.Add(text)).BackendResult(fabricated);
Check(!string.Join("\n", fabricatedLines).Contains("PRIVATE"), "journal sanitizes even manually constructed records");
try { EsimProtocol.Completed(new(true, null, false, false), 1); throw new Exception("Accepted false success"); }
catch (EsimException error) { Check(error.Code == "agent_exit_failed", "nonzero exit cannot confirm success"); }
Console.WriteLine(JsonSerializer.Serialize(new { ok = true, checks, deviceAccess = false, networkAccess = false }));
