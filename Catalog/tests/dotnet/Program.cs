using System.Net;
using System.Text;
using ZteImeiStudio.Windows;

var root = args[0]; var fixtures = Path.Combine(root, "tests", "fixtures");
var temp = Path.Combine(Path.GetTempPath(), "zte-catalog-" + Guid.NewGuid());
Directory.CreateDirectory(temp);
var count = 0;
void Check(bool value, string name) { if (!value) throw new Exception("FAIL " + name); count++; Console.WriteLine("PASS .NET " + name); }
void Rejected(string name, Action action) { try { action(); } catch { Check(true, name); return; } Check(false, name); }
(byte[] Payload, byte[] Signature) Data(string name) => (File.ReadAllBytes(Path.Combine(fixtures, name + ".json")), Convert.FromBase64String(File.ReadAllText(Path.Combine(fixtures, name + ".sig")).Trim()));
try
{
    var baseline = Convert.FromBase64String(VerifiedCatalogPolicy.BaselinePayload);
    var signature = Convert.FromBase64String(VerifiedCatalogPolicy.BaselineSignature);
    var initial = VerifiedCatalogPolicy.Validate(baseline, signature);
    Check(initial.Apps.Select(x => x.Id).SequenceEqual(new[] { "htop", "opkg" }), "cross-runtime baseline signature and physical whitelist");
    var modified = baseline.ToArray(); modified[0] ^= 1;
    Rejected("tampered payload rejected", () => VerifiedCatalogPolicy.Validate(modified, signature));
    Rejected("tampered signature rejected", () => VerifiedCatalogPolicy.Validate(baseline, new byte[64]));
    Rejected("oversized payload rejected", () => VerifiedCatalogPolicy.Validate(new byte[VerifiedCatalogPolicy.MaxPayloadBytes + 1], signature));
    Rejected("rollback revision rejected", () => VerifiedCatalogPolicy.Validate(baseline, signature, 2));
    var next = Data("new-revision"); var empty = Data("empty-list");
    var update = VerifiedCatalogPolicy.Validate(next.Payload, next.Signature, 1, baseline);
    Check(update.Revision == 2 && update.Apps.Count == 1, "signed approval withdrawal accepted");
    Rejected("same-revision equivocation rejected", () => VerifiedCatalogPolicy.Validate(empty.Payload, empty.Signature, 2, next.Payload));
    foreach (var name in new[] { "duplicate-id", "too-new-manager", "future-date" })
    {
        var value = Data(name); Rejected(name + " rejected", () => VerifiedCatalogPolicy.Validate(value.Payload, value.Signature));
    }
    foreach (var name in new[] { "unknown-installer", "unpinned-version", "incompatible-architecture" })
    {
        var value = Data(name); var doc = VerifiedCatalogPolicy.Validate(value.Payload, value.Signature);
        Check(doc.Apps.Where(VerifiedCatalogPolicy.Compatible).Select(x => x.Id).SequenceEqual(new[] { "opkg" }), name + " not installable");
    }
    var cache = Path.Combine(temp, "cache.json");
    File.WriteAllBytes(cache, VerifiedCatalogPolicy.EncodeEnvelope(next.Payload, next.Signature));
    var saved = new VerifiedCatalogStore(cache);
    Check(saved.Revision == 2 && saved.Entries.Count == 1, "verified cache restored");
    File.WriteAllText(cache, "corrupt");
    var corrupt = new VerifiedCatalogStore(cache);
    Check(corrupt.Revision == 1 && corrupt.Entries.Count == 2 && corrupt.Error.Length > 0, "corrupt cache retains signed offline baseline");
    File.Delete(cache);
    var mode = "update";
    var store = new VerifiedCatalogStore(cache, () => new FakeHandler(request =>
    {
        var isSignature = request.RequestUri!.AbsolutePath.EndsWith(".sig", StringComparison.Ordinal);
        if (mode == "404") return new(HttpStatusCode.NotFound);
        if (mode == "redirect") { var response = new HttpResponseMessage(HttpStatusCode.Redirect); response.Headers.Location = new("http://example.invalid/catalog"); return response; }
        var data = mode == "oversize" ? new byte[VerifiedCatalogPolicy.MaxPayloadBytes + 1] :
            isSignature ? Encoding.UTF8.GetBytes(mode == "tamper" ? "AAAA" : Convert.ToBase64String(next.Signature)) : next.Payload;
        return new(HttpStatusCode.OK) { Content = new ByteArrayContent(data) };
    }));
    await store.UpdateAsync();
    Check(store.Revision == 2 && store.Allows("htop") && !store.Allows("opkg") && store.Error.Length == 0, "refresh accepts approved exact versions only");
    var committed = File.ReadAllBytes(cache);
    Check(VerifiedCatalogPolicy.ReadEnvelope(committed).Document.Revision == 2, "atomic cache contains payload and signature");
    foreach (var nextMode in new[] { "tamper", "404", "redirect", "oversize" })
    {
        mode = nextMode; await store.UpdateAsync();
        Check(store.Revision == 2 && store.Error.Length > 0 && File.ReadAllBytes(cache).SequenceEqual(committed), nextMode + " preserves cache and document");
    }
    Console.WriteLine($"{count} .NET catalog tests passed");
}
finally { Directory.Delete(temp, recursive: true); }
sealed class FakeHandler(Func<HttpRequestMessage, HttpResponseMessage> action) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => Task.FromResult(action(request));
}
