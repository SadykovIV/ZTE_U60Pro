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

var emptyCard = new EsimSnapshot(true, new string('9', 32), []);
var confirmedCard = new { kind = "euicc_confirmed", management = "available", reason = "eid_and_profiles_read", cleanup_confirmed = true };
string CardFrame(bool success, object? card, EsimSnapshot? snapshot = null, bool includeCard = true)
{
    var value = new Dictionary<string, object?> { ["type"] = "result", ["ok"] = success,
        ["changed"] = false, ["notifications_pending"] = false };
    if (snapshot is not null) value["snapshot"] = snapshot;
    if (!success) value["error"] = "card_open_rejected";
    if (includeCard) value["card"] = card;
    return JsonSerializer.Serialize(value) + "\n";
}
foreach (bool withMetadata in new[] { true, false })
{
    var result = EsimProtocol.Completed(await Parse(CardFrame(true, confirmedCard, emptyCard, withMetadata)), 0);
    var capability = EsimCardStatus.FromAcceptedResult(result);
    Check(capability.Kind == "euicc_confirmed" && capability.Management == "available" && capability.CleanupConfirmed, "empty eUICC confirmed with current or legacy agent");
    Check(result.Snapshot!.Profiles.Count == 0, "empty inventory remains valid");
    try { EsimProtocol.Completed(result, 1); throw new Exception("Metadata authorized nonzero exit"); }
    catch (EsimException e) { Check(e.Code == "agent_exit_failed", "metadata cannot replace exit proof"); }
    var lines = new List<string>(); new EsimJournal("list", (_, text) => lines.Add(text)).BackendResult(result);
    Check(!string.Join('\n', lines).Contains(emptyCard.Eid), "card evidence never logs EID");
}
foreach (var reason in new[] { "busy", "open_rejected", "cleanup_unknown", "not_ready", "unsupported_device", "read_failed", "operation_failed" })
{
    var result = await Parse(CardFrame(false, new { kind = "unknown", management = "unknown", reason, cleanup_confirmed = false }));
    Check(result.Card?.Kind == "unknown" && result.Card.Reason == reason, "fixed failed card reason retained");
    bool rejected = false; try { EsimCardStatus.FromAcceptedResult(result); } catch (EsimException) { rejected = true; }
    Check(rejected, "failed result never authorizes eUICC operations");
}
foreach (var malformed in new object?[] {
    null, 7, "PRIVATE_CARD_CANARY",
    new { kind = "ordinary_sim", management = "unavailable", reason = "read_failed", cleanup_confirmed = false },
    new { kind = "absent", management = "unavailable", reason = "read_failed", cleanup_confirmed = false },
    new { kind = "unknown", management = "unknown", reason = "PRIVATE_CARD_CANARY", cleanup_confirmed = false },
    new { kind = "unknown", management = "unknown", reason = "busy", cleanup_confirmed = true },
    new { kind = "unknown", management = "unknown", reason = "busy", cleanup_confirmed = "false" },
    new { kind = "unknown", management = "unknown", reason = "busy" },
    new { kind = "unknown", management = "unknown", reason = "busy", cleanup_confirmed = false, eid = "PRIVATE_CARD_CANARY" },
    confirmedCard,
})
{
    bool rejected = false; try { await Parse(CardFrame(false, malformed)); } catch (Exception e) { rejected = true; Check(!e.Message.Contains("PRIVATE_CARD_CANARY"), "invalid card text not surfaced"); }
    Check(rejected, "malformed or contradictory error card rejected");
}
foreach (var frame in new[] {
    CardFrame(true, confirmedCard),
    CardFrame(true, confirmedCard, emptyCard with { Eid = "bad" }),
    CardFrame(true, new { kind = "unknown", management = "unknown", reason = "read_failed", cleanup_confirmed = false }, emptyCard),
    CardFrame(true, new { kind = "euicc_confirmed", management = "available", reason = "eid_and_profiles_read", cleanup_confirmed = false }, emptyCard),
    CardFrame(false, new { kind = "unknown", management = "unknown", reason = "busy", cleanup_confirmed = false }).Replace("\"kind\":\"unknown\"", "\"kind\":\"unknown\",\"kind\":\"euicc_confirmed\"")
})
{
    bool rejected = false; try { await Parse(frame); } catch { rejected = true; }
    Check(rejected, "metadata cannot replace valid inventory or contradict the result");
}
foreach (var phrase in new[] { "Проверить карту и профили", "Карта: eUICC подтверждена", "Карта: тип не определён. Повторите проверку.", "Карта ещё не проверена." })
    Check(english.TryGetValue(phrase, out var translated) && translated != phrase, "card status has English translation");
Console.WriteLine(JsonSerializer.Serialize(new { ok = true, checks, deviceAccess = false, networkAccess = false }));
