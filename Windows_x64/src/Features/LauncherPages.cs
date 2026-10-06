using System.Text;

namespace ZteImeiStudio.Windows.Features;

public sealed record LauncherPages(IReadOnlyList<string> Order, bool UsesDefault = false)
{
    public static readonly string[] Ids = ["info", "vpn", "esim"];
    public static LauncherPages Default => new(Ids.ToArray(), true);
    public byte[] Encode()
    {
        if (Order is null || Order.Count > 3 || Order.Any(id => !Ids.Contains(id)) ||
            Order.Distinct(StringComparer.Ordinal).Count() != Order.Count)
            throw new DeviceFeatureException("Выберите известные страницы без повторов.");
        return Encoding.ASCII.GetBytes("ZTE_LAUNCHER_PAGES_V1\n" + string.Concat(Order.Select(id => id + "\n")));
    }
    public static LauncherPages Decode(byte[] bytes)
    {
        if (bytes.Length is 0 or > 128 || bytes.Any(c => c != 10 && (c < 32 || c > 126)))
            throw new DeviceFeatureException("Повреждён файл выбора страниц Launcher.");
        var lines = Encoding.ASCII.GetString(bytes).Split('\n');
        if (lines[0] != "ZTE_LAUNCHER_PAGES_V1" || lines[^1] != "")
            throw new DeviceFeatureException("Неизвестный формат выбора страниц Launcher.");
        var pages = new LauncherPages(lines.Skip(1).SkipLast(1).ToArray());
        _ = pages.Encode();
        return pages;
    }
    public LauncherPages IncludeEsim() => Order.Contains("esim") ? this : new(Order.Append("esim").ToArray());
}

public sealed partial class DeviceFeatureService
{
    private async Task<LauncherPages?> ReadLauncherPagesAsync(CancellationToken ct)
    {
        var output = await RunTextAsync("set -eu; f=/data/zte-launcher/page-layout.conf; if test ! -e \"$f\" && test ! -L \"$f\"; then echo missing; elif test -f \"$f\" && test ! -L \"$f\" && test \"$(stat -c %u:%a:%h \"$f\")\" = 0:600:1 && test \"$(stat -c %s \"$f\")\" -le 128; then echo data; dd if=\"$f\" bs=129 count=1 2>/dev/null | base64; else echo unsafe; fi", ct: ct);
        if (output == "missing") return LauncherPages.Default;
        if (!output.StartsWith("data\n", StringComparison.Ordinal)) return null;
        try { return LauncherPages.Decode(Convert.FromBase64String(output[5..].Replace("\n", "", StringComparison.Ordinal))); }
        catch { return null; }
    }

    public Task<LauncherStatus> ApplyLauncherPagesAsync(LauncherPages pages, CancellationToken ct = default)
    {
        _ = pages.Encode();
        return MutateAsync(async (identity, token) =>
        {
            var before = await ReadLauncherStatusAsync(identity, ct);
            Check(before.CanApplyLayout && before.Pages is not null, before.Detail ?? "Launcher не готов к настройке.");
            return await WriteLauncherPagesAsync(identity, token, before.Pages!, pages, ct);
        }, ct, measuredAgentPlatform: true);
    }

    private async Task<LauncherStatus> WriteLauncherPagesAsync(DeviceIdentity identity, string token, LauncherPages expected, LauncherPages pages, CancellationToken ct)
    {
        var bytes = pages.Encode();
        var expectedGuard = expected.UsesDefault ? "test ! -e \"$f\" && test ! -L \"$f\" || exit 73; " : "test -f \"$f\" && test ! -L \"$f\" || exit 73; test \"$(sha256sum \"$f\" | cut -d ' ' -f1)\" = " + Quote(Sha(expected.Encode())) + "; ";
        var stage = LauncherRoot + "/.page-layout-" + Guid.NewGuid().ToString("D");
        var path = stage + "/pages";
        var guard = Guard(identity, token) + "test -d " + LauncherRoot + " && test ! -L " + LauncherRoot + "; test \"$(stat -c %u:%a " + LauncherRoot + ")\" = 0:700; test \"$(cat " + LauncherRoot + "/owner)\" = zte-native-launcher-v1; test \"$(cat " + LauncherRoot + "/cid)\" = " + Quote(identity.Cid) + "; test \"$(sha256sum " + LauncherRoot + "/launcher.so | cut -d ' ' -f1)\" = " + Quote(LauncherHash) + "; ";
        await RunAsync(guard + "umask 077; mkdir -m 700 " + Quote(stage), ct: ct);
        var remoteFinished = true;
        try
        {
            remoteFinished = false;
            var uploaded = await _shell.RunAsync(guard + "cat > " + Quote(path) + "; chmod 600 " + Quote(path) + "; sha256sum " + Quote(path), bytes, TimeSpan.FromSeconds(30), ct);
            remoteFinished = KnownInstallerExit(uploaded.ExitCode);
            Check(remoteFinished && uploaded.Success && Text(uploaded.Stdout).Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() == Sha(bytes), "Передача выбора страниц не подтверждена.");
            remoteFinished = false;
            var applied = await _shell.RunAsync(guard + "f=" + Quote(LauncherRoot + "/page-layout.conf") + "; if test -e \"$f\" || test -L \"$f\"; then test -f \"$f\" && test ! -L \"$f\" && test \"$(stat -c %u:%a:%h \"$f\")\" = 0:600:1 && test \"$(stat -c %s \"$f\")\" -le 128 || exit 73; fi; " + expectedGuard + "test -d " + Quote(stage) + " && test ! -L " + Quote(stage) + " && test \"$(stat -c %u:%a " + Quote(stage) + ")\" = 0:700 || exit 73; test -f " + Quote(path) + " && test ! -L " + Quote(path) + " && test \"$(stat -c %u:%a:%h " + Quote(path) + ")\" = 0:600:1 && test \"$(stat -c %s " + Quote(path) + ")\" = " + bytes.Length + " || exit 73; test \"$(sha256sum " + Quote(path) + " | cut -d ' ' -f1)\" = " + Quote(Sha(bytes)) + "; mv -f " + Quote(path) + " \"$f\"; sync", timeout: TimeSpan.FromSeconds(30), ct: ct);
            remoteFinished = KnownInstallerExit(applied.ExitCode);
            Check(remoteFinished && applied.Success, "Применение выбора страниц не подтверждено; перечитайте состояние перед повтором.");
        }
        finally { if (remoteFinished) await CleanupStageAsync(stage, ["pages"], CancellationToken.None); }
        var after = await GetLauncherStatusAsync(ct);
        Check(after.State == "ready" && after.Pages is { UsesDefault: false } && after.Pages.Encode().SequenceEqual(bytes), "Модем не подтвердил точный выбор и порядок страниц.");
        return after;
    }
}
