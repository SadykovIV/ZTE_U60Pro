using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows.Features;

public sealed record PrivatePackage(string Name, string Version, string Summary);
public sealed record PrivateOpkgStatus(bool Installed, IReadOnlyList<PrivatePackage> Packages, ulong FreeKiB,
    bool CanRollback, string? Generation, string? Previous, bool Running);
public sealed record PrivateOpkgResult(string Output, PrivateOpkgStatus Status);
public sealed record OpkgFeeds(string Text, string Generation, string Release, string Architecture, IReadOnlyList<string> KeyFingerprints);

public sealed partial class DeviceFeatureService
{
    private const string OpkgManagerHash = "317371dc85fdb89d1f6de381065cc0eb3ed0f64a69781fe3cfca8db6dc7cf3d5";
    private const string OpkgRuntimeMetadataHash = "1ed406a3644f16bb7937ce11cb395a2520bdeb4eb36090b6d1d9d7753804a74a";
    private static readonly HashSet<string> OpkgCommands = ["update", "list", "search", "info", "install", "remove", "list-installed", "status", "files"];
    private static readonly HashSet<string> ProtectedPackages = ["kernel", "libc", "libpthread", "zte-private-musl", "busybox", "opkg", "base-files", "procd", "netifd", "firewall", "firewall4"];

    public async Task<PrivateOpkgStatus> GetPrivateOpkgStatusAsync(CancellationToken ct = default)
        => (await InvokeOpkgAsync("inspect", [], null, null, ct)).Status;
    public Task<PrivateOpkgResult> InstallPrivateOpkgAsync(CancellationToken ct = default)
        => InvokeOpkgAsync("install-adapter", [], null, null, ct);
    public Task<PrivateOpkgResult> RemovePrivateOpkgAsync(CancellationToken ct = default)
        => InvokeOpkgAsync("remove-adapter", [], null, null, ct);
    public Task<PrivateOpkgResult> RollbackPrivateOpkgAsync(CancellationToken ct = default)
        => InvokeOpkgAsync("rollback", [], null, null, ct);

    public Task<PrivateOpkgResult> RunPrivateOpkgCommandAsync(string commandLine, CancellationToken ct = default)
    {
        Check(commandLine.Length <= 900 && !commandLine.Any(char.IsControl), "Слишком длинная или повреждённая команда opkg.");
        var args = commandLine.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        ValidateOpkgArguments(args);
        return InvokeOpkgAsync("execute", args, null, null, ct);
    }

    public async Task<OpkgFeeds> ReadPrivateOpkgFeedsAsync(CancellationToken ct = default)
    {
        var result = await InvokeOpkgAsync("read-feeds", [], null, null, ct);
        var lines = result.Output.Split('\n');
        Check(lines.Length >= 5 && lines[0] == "__ZTE_OPKG_FEEDS_V1__" && lines[^1] == "__END_FEEDS__", "Неполный список источников opkg.");
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        var sources = new List<string>();
        var keys = new List<string>();
        foreach (var line in lines.Skip(1).SkipLast(1))
        {
            if (line.StartsWith("source=", StringComparison.Ordinal)) { sources.Add(line[7..]); continue; }
            if (line.StartsWith("key=", StringComparison.Ordinal)) { keys.Add(line[4..]); continue; }
            var pair = line.Split('=', 2);
            Check(pair.Length == 2 && fields.TryAdd(pair[0], pair[1]), "Повреждены поля источников opkg.");
        }
        Check(fields.Keys.ToHashSet().SetEquals(["release", "architecture", "generation"]) &&
              fields["release"] == "23.05.4" && fields["architecture"] == "aarch64_cortex-a53" &&
              fields["generation"] == result.Status.Generation && keys is { Count: > 0 and <= 32 } &&
              keys.All(key => Regex.IsMatch(key, "^[0-9a-f]{16}$")) && keys.Distinct().Count() == keys.Count,
            "Источник opkg не соответствует поддерживаемой платформе.");
        return new OpkgFeeds(NormalizeFeeds(string.Join('\n', sources)), fields["generation"], fields["release"], fields["architecture"], keys);
    }

    public Task<PrivateOpkgResult> SavePrivateOpkgFeedsAsync(string text, string expectedGeneration, CancellationToken ct = default)
    {
        Check(Regex.IsMatch(expectedGeneration, "^g-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$"), "Обновите состояние источников перед сохранением.");
        var normalized = NormalizeFeeds(text);
        return InvokeOpkgAsync("save-feeds", [], Encoding.UTF8.GetBytes(normalized), expectedGeneration, ct);
    }

    public static string NormalizeFeeds(string text)
    {
        Check(Encoding.UTF8.GetByteCount(text) <= 16384, "Список источников превышает 16 КиБ.");
        var names = new HashSet<string>(StringComparer.Ordinal);
        var output = new List<string>();
        foreach (var raw in text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var words = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            Check(words.Length == 3 && words[0] == "src/gz", "Каждый источник должен иметь вид: src/gz имя http(s)://адрес.");
            var name = words[1]; var address = words[2];
            Check(name.Length is >= 1 and <= 48 && Regex.IsMatch(name, "^[A-Za-z0-9_][A-Za-z0-9_-]*$") && names.Add(name), "Имя источника недопустимо или повторяется.");
            Check(address.Length <= 1024 && Regex.IsMatch(address, "^[A-Za-z0-9:/._~%+\\[\\]=-]+$") && !Regex.IsMatch(address, "%(?![0-9A-Fa-f]{2})"), "Недопустимый адрес источника.");
            Check(Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" && uri.Host.Length > 0 && uri.UserInfo.Length == 0 && uri.Query.Length == 0 && uri.Fragment.Length == 0,
                "Источник должен иметь HTTP(S) URL без пароля и параметров.");
            output.Add("src/gz " + name + " " + address);
        }
        Check(output.Count <= 16, "Допускается не более 16 источников opkg.");
        return output.Count == 0 ? "" : string.Join('\n', output) + "\n";
    }

    private static void ValidateOpkgArguments(IReadOnlyList<string> args)
    {
        Check(args.Count is >= 1 and <= 9 && OpkgCommands.Contains(args[0]), "Недопустимая команда opkg.");
        var command = args[0];
        if (command == "update") Check(args.Count == 1, "update не принимает параметры.");
        if (command is "install" or "remove" or "search" or "info") Check(args.Count > 1, "Укажите имя пакета.");
        if (command == "files") Check(args.Count == 2, "files принимает одно имя пакета.");
        foreach (var name in args.Skip(1))
        {
            var pattern = command is "list" or "search" or "info" or "status" or "list-installed";
            var allowed = pattern ? "^[a-z0-9+._*?-]{1,100}$" : "^[a-z0-9+._-]{1,100}$";
            Check(Regex.IsMatch(name, allowed) && !name.StartsWith('-') && !name.Contains("..", StringComparison.Ordinal), "Разрешены только имена пакетов и шаблоны.");
            if (command is "install" or "remove") Check(!name.StartsWith("kmod-", StringComparison.Ordinal) && !name.StartsWith("luci-", StringComparison.Ordinal) && !ProtectedPackages.Contains(name), "Системные пакеты нельзя менять в изолированной среде.");
        }
    }

    private Task<PrivateOpkgResult> InvokeOpkgAsync(string action, IReadOnlyList<string> args, byte[]? payload, string? generation, CancellationToken ct)
    {
        if (action is "inspect" or "read-feeds") return ReadOnly();
        return MutateAsync(async (identity, token) => await Invoke(identity, token), ct);

        async Task<PrivateOpkgResult> ReadOnly()
        {
            var identity = await ReadIdentityAsync(requireSupportedFirmware: true, ct);
            var result = await Invoke(identity, null);
            await VerifyIdentityAsync(identity, ct);
            return result;
        }
        async Task<PrivateOpkgResult> Invoke(DeviceIdentity identity, string? token)
        {
            var files = new Dictionary<string, byte[]>(StringComparer.Ordinal)
            {
                ["manager.sh"] = await ResourceAsync("ExperimentalOpkg", "manager.sh", ct)
            };
            Check(Sha(files["manager.sh"]) == OpkgManagerHash, "Несовместимый менеджер opkg.");
            if (token != null) files.Add("zte-timeout", await ResourceAsync("HostTools", "zte-timeout", ct));
            if (action == "install-adapter")
            {
                var metadata = await ResourceAsync("ExperimentalOpkg", "runtime.json", ct);
                Check(Sha(metadata) == OpkgRuntimeMetadataHash, "Несовместимый каталог runtime opkg.");
                using var doc = JsonDocument.Parse(metadata);
                var root = doc.RootElement;
                var archive = await ResourceAsync("ExperimentalOpkg", "runtime.tar.gz", ct);
                Check(root.GetProperty("bytes").GetInt32() == archive.Length && StringProperty(root, "sha256") == Sha(archive), "Архив runtime opkg повреждён.");
                files.Add("runtime.tar.gz", archive);
            }
            if (payload != null) files.Add("feeds.txt", payload);
            var stage = await StageAsync("zte-opkg", files, ct);
            try
            {
                var call = new List<string> { action, identity.Cid, identity.BootId };
                if (action == "install-adapter")
                {
                    using var doc = JsonDocument.Parse(await ResourceAsync("ExperimentalOpkg", "runtime.json", ct));
                    call.AddRange([stage, Sha(files["runtime.tar.gz"]), StringProperty(doc.RootElement, "manifestSHA256") ?? ""]);
                }
                else if (action == "save-feeds") call.AddRange([stage, Sha(payload!), generation!]);
                else call.AddRange(args);
                var command = (token != null ? Guard(identity, token) : "set -eu; ") +
                    "test \"$(sha256sum " + Quote(stage + "/manager.sh") + " | cut -d ' ' -f1)\" = " + Quote(OpkgManagerHash) +
                    "; sh " + Quote(stage + "/manager.sh") + " " + string.Join(" ", call.Select(Quote));
                var output = (await RunAsync(command, seconds: token == null ? 60 : 600, ct: ct)).Stdout;
                return ParseOpkgResult(output);
            }
            finally { await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
        }
    }

    private static PrivateOpkgResult ParseOpkgResult(byte[] data)
    {
        Check(data.Length <= 4 * 1024 * 1024, "Слишком большой ответ opkg.");
        var text = Encoding.UTF8.GetString(data);
        const string marker = "__ZTE_PRIVATE_OPKG_V1__\n";
        var index = text.LastIndexOf(marker, StringComparison.Ordinal);
        Check(index >= 0, "Менеджер opkg не вернул состояние.");
        var output = text[..index].TrimEnd('\r', '\n');
        var report = text[(index + marker.Length)..].Split('\n');
        Check(report.Length >= 8 && report[^2] == "__END__" && report[^1] == "", "Неполный ответ opkg.");
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        var packages = new List<PrivatePackage>();
        foreach (var line in report.SkipLast(2))
        {
            if (line.StartsWith("package=", StringComparison.Ordinal))
            {
                var parts = line[8..].Split('\t');
                Check(parts.Length is 2 or 3 && Regex.IsMatch(parts[0], "^[a-z0-9+._-]+$") && parts[1].Length > 0, "Повреждено имя пакета opkg.");
                packages.Add(new PrivatePackage(parts[0], parts[1], parts.Length == 3 ? parts[2] : ""));
            }
            else
            {
                var pair = line.Split('=', 2);
                Check(pair.Length == 2 && fields.TryAdd(pair[0], pair[1]), "Повтор полей статуса opkg.");
            }
        }
        ulong free = 0;
        Check(fields.Keys.ToHashSet().SetEquals(["installed", "generation", "previous", "rollback", "free_kib", "running"]) &&
              packages.Count <= 1024 && packages.Select(p => p.Name).Distinct().Count() == packages.Count &&
              new[] { "0", "1" }.Contains(fields["installed"]) && new[] { "0", "1" }.Contains(fields["rollback"]) && new[] { "0", "1" }.Contains(fields["running"]) &&
              ulong.TryParse(fields["free_kib"], out free), "Некорректное состояние opkg.");
        string? Gen(string value) => value is "none" or "unset" ? null : Regex.IsMatch(value, "^g-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$") ? value : throw new DeviceFeatureException("Повреждён идентификатор состояния opkg.");
        var current = Gen(fields["generation"]); var previous = Gen(fields["previous"]);
        Check((fields["installed"] == "1") == (current != null), "Установка opkg не соответствует её состоянию.");
        return new PrivateOpkgResult(output, new PrivateOpkgStatus(current != null, packages, free, fields["rollback"] == "1", current, previous, fields["running"] == "1"));
    }
}
