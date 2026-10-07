using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows.Features;

public sealed record AccessServiceStatus(string Id, string State, string Capability, IReadOnlyList<string> AllowedActions);
public sealed record SshAccount(string Name, int Uid, string Home, bool Administrator);
public sealed record SshAccountStatus(IReadOnlyList<SshAccount> Accounts, bool ListenerReady, bool RecoveryPending, string RecoveryKind, int Port = 2223);
public sealed record AccessStatus(IReadOnlyList<AccessServiceStatus> Services, SshAccountStatus Accounts);

public sealed partial class DeviceFeatureService
{
    private static readonly string[] AccessServiceIds = ["stockWeb", "dashboard", "agent", "managementSSH", "userSSH", "adb"];
    private static readonly HashSet<string> ControllableServices = ["dashboard", "agent", "userSSH"];
    private const string AccessScriptHash = "260e06d377fa59c46c17655f9e16ff2e2996d9d9afb64cea5e645c9534fb9b97";

    private static void ValidateLanAddress(string value)
        => Check(IPAddress.TryParse(value, out var address) && address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address), "Укажите IPv4-адрес модема.");
    private static void ValidateAccountName(string value)
        => Check(value.Length is >= 1 and <= 24 && Regex.IsMatch(value, "^[a-z][a-z0-9_]*$") && value is not ("root" or "zteimei" or "daemon" or "nobody"),
            "Логин: 1–24 латинских символа, первая буква a–z; системные имена запрещены.");

    public async Task<AccessStatus> GetAccessStatusAsync(string lanAddress, CancellationToken ct = default)
    {
        ValidateLanAddress(lanAddress);
        var identity = await ReadAgentIdentityAsync(ct);
        var services = await ReadAccessServicesAsync(identity, lanAddress, ct);
        var accounts = await GetSshAccountStatusAsync(lanAddress, ct);
        Check(identity == await ReadAgentIdentityAsync(ct), "Модем или его загрузка изменились во время операции. Обновите состояние.");
        return new AccessStatus(services, accounts);
    }

    public Task<AccessStatus> ChangeAccessServiceAsync(string service, string action, string lanAddress, CancellationToken ct = default)
    {
        ValidateLanAddress(lanAddress);
        Check(ControllableServices.Contains(service), "Служба защищена или доступна только для просмотра.");
        Check(action is "start" or "stop" or "restart", "Допустимы start, stop и restart.");
        return MutateAsync(async (identity, token) =>
        {
            var before = await ReadAccessServicesAsync(identity, lanAddress, ct);
            Check(before.FirstOrDefault(item => item.Id == service)?.AllowedActions.Contains(action) == true,
                "Служба не подтверждена как управляемая приложением.");
            var script = await ResourceAsync("SSHAccounts", "access-services.sh", ct);
            Check(Sha(script) == AccessScriptHash, "Компонент управления доступом повреждён.");
            var files = new Dictionary<string, byte[]> { ["access-services.sh"] = script };
            var stage = await StageAsync("zte-access", files, ct);
            try
            {
                var command = Guard(identity, token) + "sh " + Quote(stage + "/access-services.sh") + " action " +
                    string.Join(" ", new[] { identity.Cid, lanAddress, service, action, stage, token }.Select(Quote));
                var output = await RunTextAsync(command, seconds: 90, ct: ct);
                var services = ParseAccessServices(output);
                var expected = action == "stop" ? "stopped" : "running";
                Check(services.FirstOrDefault(item => item.Id == service)?.State == expected, "Служба не подтвердила изменение состояния.");
                var accounts = await GetSshAccountStatusAsync(lanAddress, ct);
                return new AccessStatus(services, accounts);
            }
            finally { await CleanupStageAsync(stage, ["access-services.sh", "launcher.private.sh"], CancellationToken.None); }
        }, ct, measuredAgentPlatform: true);
    }

    private async Task<IReadOnlyList<AccessServiceStatus>> ReadAccessServicesAsync(DeviceIdentity identity, string lanAddress, CancellationToken ct)
    {
        var script = await ResourceAsync("SSHAccounts", "access-services.sh", ct);
        Check(Sha(script) == AccessScriptHash, "Компонент управления доступом повреждён.");
        var output = await RunTextAsync("sh -s -- status " + Quote(identity.Cid) + " " + Quote(lanAddress), script, 60, ct);
        return ParseAccessServices(output);
    }

    private static IReadOnlyList<AccessServiceStatus> ParseAccessServices(string output)
    {
        var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Check(lines.Length == 7 && lines[0] == "ACCESS_SCHEMA 1", "Неполный список служб доступа.");
        var services = new List<AccessServiceStatus>();
        foreach (var line in lines.Skip(1))
        {
            var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            Check(fields.Length == 4 && fields[0] == "ACCESS_SERVICE" && AccessServiceIds.Contains(fields[1]) &&
                  new[] { "running", "stopped", "unavailable", "unknown" }.Contains(fields[2]) &&
                  new[] { "control", "readonly", "protected" }.Contains(fields[3]) &&
                  services.All(item => item.Id != fields[1]), "Повреждён статус службы доступа.");
            Check((fields[1] == "managementSSH") == (fields[3] == "protected"), "Защита служебного SSH не подтверждена.");
            Check(fields[3] != "control" || ControllableServices.Contains(fields[1]) && fields[2] is "running" or "stopped", "Недопустимое право управления службой.");
            string[] actions = fields[3] == "control" ? fields[2] == "running" ? ["stop", "restart"] : ["start"] : [];
            services.Add(new AccessServiceStatus(fields[1], fields[2], fields[3], actions));
        }
        Check(AccessServiceIds.SequenceEqual(services.Select(item => item.Id)), "Список служб доступа неполон.");
        return services;
    }

    public async Task<SshAccountStatus> GetSshAccountStatusAsync(string lanAddress, CancellationToken ct = default)
    {
        ValidateLanAddress(lanAddress);
        var command = "set -eu; base=/data/zte-imei-admin; printf 'SSH_USERS_SCHEMA 1\\n'; " +
            "pending=0; recovery=none; if test -e \"$base/active\" || test -L \"$base/active\"; then pending=1; recovery=unknown; " +
            "if test -f \"$base/active\" && test ! -L \"$base/active\"; then token=$(cat \"$base/active\"); case \"$token\" in *[!a-f0-9-]*) ;; *) " +
            "j=\"$base/transactions/$token\"; if test -f \"$j/operation\" && test \"$(cat \"$j/operation\")\" = delete; then recovery=delete; elif test -f \"$j/user\" && test -f \"$j/targets\"; then recovery=create; fi;; esac; fi; fi; " +
            "printf 'SSH_USERS_PENDING %s\\nSSH_USERS_RECOVERY %s\\n' \"$pending\" \"$recovery\"; " +
            "awk -F: '$3 >= 50000 && $3 <= 59999 && $5 == \"ZTE IMEI Studio\" && $6 ~ /^\\/data\\/zte-imei-admin\\/homes\\/[a-z][a-z0-9_]*$/ {print $1 \" \" $3 \" \" $6}' /etc/passwd | " +
            "while read -r name uid home; do admin=0; if test -f /etc/zte-imei-admin/doas.conf && grep -qFx \"permit $name as root\" /etc/zte-imei-admin/doas.conf; then admin=1; fi; printf 'SSH_ACCOUNT %s %s %s %s\\n' \"$name\" \"$uid\" \"$home\" \"$admin\"; done; " +
            "ready=0; if test -f /var/run/zte-imei-users.pid && test ! -L /var/run/zte-imei-users.pid; then pid=$(cat /var/run/zte-imei-users.pid); case \"$pid\" in ''|*[!0-9]*) ;; *) " +
            "if test \"$(readlink /proc/$pid/exe 2>/dev/null || true)\" = \"$base/bin/dropbear\" && tr '\\000' '\\n' < /proc/$pid/cmdline | grep -qFx " + Quote(lanAddress + ":2223") +
            " && awk '$2 ~ /:08AF$/ && $4 == \"0A\" {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6; then ready=1; fi;; esac; fi; printf 'SSH_USERS_LISTENER %s\\n' \"$ready\"";
        return ParseSshAccountStatus(await RunTextAsync(command, seconds: 45, ct: ct));
    }

    private static SshAccountStatus ParseSshAccountStatus(string output)
    {
        var accounts = new List<SshAccount>();
        var schema = false; string? pending = null, recovery = null, listener = null;
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length == 2 && fields[0] == "SSH_USERS_SCHEMA") { Check(!schema && fields[1] == "1", "Неизвестная схема SSH-пользователей."); schema = true; continue; }
            if (fields.Length == 2 && fields[0] == "SSH_USERS_PENDING") { Check(pending == null && fields[1] is "0" or "1", "Неверный флаг операции SSH."); pending = fields[1]; continue; }
            if (fields.Length == 2 && fields[0] == "SSH_USERS_RECOVERY") { Check(recovery == null && fields[1] is "none" or "create" or "delete" or "unknown", "Неверный вид восстановления SSH."); recovery = fields[1]; continue; }
            if (fields.Length == 2 && fields[0] == "SSH_USERS_LISTENER") { Check(listener == null && fields[1] is "0" or "1", "Неверный статус SSH-службы."); listener = fields[1]; continue; }
            if (fields.Length == 5 && fields[0] == "SSH_ACCOUNT")
            {
                ValidateAccountName(fields[1]);
                Check(int.TryParse(fields[2], out var uid) && uid is >= 50000 and <= 59999 && fields[3] == "/data/zte-imei-admin/homes/" + fields[1] && fields[4] is "0" or "1" &&
                      accounts.All(value => value.Name != fields[1] && value.Uid != uid), "Некорректная запись SSH-пользователя.");
                accounts.Add(new SshAccount(fields[1], uid, fields[3], fields[4] == "1"));
                continue;
            }
            throw new DeviceFeatureException("Неожиданный ответ проверки SSH-пользователей.");
        }
        Check(schema && pending != null && recovery != null && listener != null && (pending == "1") == (recovery != "none"), "Неполный статус SSH-пользователей.");
        return new SshAccountStatus(accounts.OrderBy(item => item.Name, StringComparer.Ordinal).ToArray(), listener == "1", pending == "1", recovery!);
    }

    public Task<SshAccountStatus> CreateSshAccountAsync(string username, string password, string lanAddress, CancellationToken ct = default)
    {
        ValidateLanAddress(lanAddress);
        ValidateAccountName(username);
        Check(Encoding.UTF8.GetByteCount(password) is >= 8 and <= 128 && password.All(character => character is >= ' ' and <= '~'), "Пароль SSH: 8–128 печатных ASCII символов.");
        return MutateAsync(async (identity, token) =>
        {
            var before = await GetSshAccountStatusAsync(lanAddress, ct);
            Check(!before.RecoveryPending && before.Accounts.All(account => account.Name != username), "На модеме есть незавершённая операция SSH или такое имя уже занято.");
            var names = new[] { "create-ssh-user.sh", "start-ssh-users.sh", "doas", "dropbear" };
            var files = await LoadResourcesAsync("SSHAccounts", names, ct);
            var stage = await StageAsync("zte-ssh-users", files, ct);
            try
            {
                var command = Guard(identity, token) + "sh " + Quote(stage + "/create-ssh-user.sh") + " " + string.Join(" ",
                    new[] { stage, identity.Cid, lanAddress, username, Sha(files["doas"]), Sha(files["dropbear"]) }.Select(Quote));
                await RunAsync(command, Encoding.UTF8.GetBytes(password + "\n"), 180, ct);
                var after = await GetSshAccountStatusAsync(lanAddress, ct);
                Check(!after.RecoveryPending && after.ListenerReady && after.Accounts.Any(account => account.Name == username && account.Administrator),
                    "SSH-пользователь создан, но служба не подтвердила запуск; проверьте журнал модема.");
                return after;
            }
            finally { await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
        }, ct, measuredAgentPlatform: true);
    }

    public Task<SshAccountStatus> DeleteSshAccountAsync(string username, string lanAddress, CancellationToken ct = default)
    {
        ValidateLanAddress(lanAddress);
        ValidateAccountName(username);
        return MutateAsync(async (identity, token) =>
        {
            var before = await GetSshAccountStatusAsync(lanAddress, ct);
            Check(!before.RecoveryPending && before.Accounts.Any(account => account.Name == username), "Можно удалить только пользователя, созданного приложением; завершите другие операции SSH.");
            var files = await LoadResourcesAsync("SSHAccounts", ["delete-ssh-user.sh"], ct);
            var stage = await StageAsync("zte-ssh-users", files, ct);
            try
            {
                var command = Guard(identity, token) + "sh " + Quote(stage + "/delete-ssh-user.sh") + " delete " + string.Join(" ",
                    new[] { stage, identity.Cid, username, token }.Select(Quote));
                await RunAsync(command, seconds: 180, ct: ct);
                var after = await GetSshAccountStatusAsync(lanAddress, ct);
                Check(!after.RecoveryPending && after.Accounts.All(account => account.Name != username), "Удаление SSH-пользователя не подтверждено.");
                return after;
            }
            finally { await CleanupStageAsync(stage, files.Keys, CancellationToken.None); }
        }, ct, measuredAgentPlatform: true);
    }
}
