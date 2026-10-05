using System.Security.Cryptography;
using System.Diagnostics;
using System.Text.Json;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Esim;

namespace ZteImeiStudio.Windows;
public sealed partial class WindowsModemService
{
    public async Task<EsimResult> RunEsimAsync(EsimRequest request, IProgress<string>? progress, CancellationToken ct = default)
    {
        _diagnosticPrivacy.Remember([request.ActivationCode, request.ConfirmationCode, request.Iccid]);
        var journal = new EsimJournal(request.Operation, Log);
        if (!await _operation.WaitAsync(0, ct)) { journal.Finish(false, "operation_busy", true); throw new EsimException("operation_busy"); }
        string? directory = null;
        string owner = Guid.NewGuid().ToString("N");
        bool confirmed = false, pending = false;
        string failure = "operation_failed";
        string? httpFailure = null, componentFailure = null;
        var shell = _ssh;
        EsimHttpRelay? http = null;
        try
        {
            journal.HostStage("validating_request");
            EsimValidation.Request(request);
            if (shell is null || !_snapshot.IsConnected || _snapshot.ConnectionMode != "SSH") throw new EsimException();
            var target = (_host, _port, _keyPath, _knownHostsPath);
            journal.HostStage("checking_target");
            var observation = await shell.RunAsync(EsimReadBinding.Command, timeout: TimeSpan.FromSeconds(10), ct: ct);
            var boot = EsimReadBinding.Parse(observation.ExitCode, observation.Stdout);
            journal.HostStage("verifying_bundle");
            string resources = Path.Combine(_resources, "Esim");
            var manifest = JsonSerializer.Deserialize<Dictionary<string, string>>(await File.ReadAllTextAsync(Path.Combine(resources, "SHA256.json"), ct)) ?? throw new EsimException();
            async Task<byte[]> Verified(string name, int maximum)
            {
                var path = Path.Combine(resources, name);
                if (!manifest.TryGetValue(name, out var pin) || pin.Length != 64 || new FileInfo(path).Length > maximum) throw new EsimException();
                var bytes = await File.ReadAllBytesAsync(path, ct);
                if (Convert.ToHexStringLower(SHA256.HashData(bytes)) != pin.ToLowerInvariant()) throw new EsimException();
                return bytes;
            }
            var agent = await Verified("zte-agent-esim", 64 * 1024 * 1024);
            AgentPackage.VerifyPayload(agent);

            directory = "/tmp/zte-desktop-esim-" + Guid.NewGuid().ToString("N");
            string pin = Convert.ToHexStringLower(SHA256.HashData(agent));
            journal.HostStage("uploading_agent");
            var stage = await shell!.RunAsync($"set -eu\n[ \"$(id -u)\" = 0 ]\n[ \"$(uname -m)\" = aarch64 ]\numask 077\nmkdir {directory}\ntrap 'rm -f {directory}/agent {directory}/owner; rmdir {directory}' EXIT\nset -C\nprintf %s {owner} > {directory}/owner\ncat > {directory}/agent\n[ \"$(sha256sum {directory}/agent | cut -d ' ' -f 1)\" = {pin} ]\nchmod 500 {directory}/agent\ntrap - EXIT", agent, TimeSpan.FromSeconds(60), ct);
            if (!stage.Success) throw new EsimException();
            int httpNumber = 0;
            async Task<(int Code, string Hex)> Relay(JsonElement payload, CancellationToken token)
            {
                if (http is null)
                {
                    _ = await Verified("gsma-rsp-roots.pem", 65536);
                    http = new EsimHttpRelay(Path.Combine(resources, "gsma-rsp-roots.pem"));
                }
                int number = ++httpNumber;
                using var validated = EsimHttpRelay.BuildRequest(payload);
                journal.HttpStart(number, payload.GetProperty("tx").GetString()!.Length / 2);
                var started = Stopwatch.StartNew();
                var response = await http.SendDetailedAsync(payload, token);
                if (response.Error is not null) httpFailure ??= response.Error;
                journal.HttpEnd(number, response.Code, response.Hex.Length / 2, started.ElapsedMilliseconds, response.Error);
                return (response.Code, response.Hex);
            }
            journal.HostStage("starting_rpc");
            var response = await shell.RunPrivateAsync(directory + "/agent --esim-rpc", (output, input, token) => EsimProtocol.ExchangeAsync(output, input, request, Relay, progress, token, journal.Backend), ct);
            journal.BackendResult(response.Value);
            if (!response.Value.Ok)
            {
                failure = EsimDiagnostics.ResultFailure(response.Value.Error, httpFailure);
                componentFailure = EsimDiagnostics.SafeComponentError(response.Value.ComponentError);
            }
            EsimProtocol.Completed(response.Value, response.ExitCode);
            journal.HostStage("checking_identity");
            if (!ReferenceEquals(shell, _ssh) || target != (_host, _port, _keyPath, _knownHostsPath) || !_snapshot.IsConnected || _snapshot.ConnectionMode != "SSH") throw new EsimException("identity_changed");
            var after = await shell.RunAsync(EsimReadBinding.Command, timeout: TimeSpan.FromSeconds(10), ct: ct);
            if (boot != EsimReadBinding.Parse(after.ExitCode, after.Stdout) || !ReferenceEquals(shell, _ssh) || target != (_host, _port, _keyPath, _knownHostsPath) || !_snapshot.IsConnected || _snapshot.ConnectionMode != "SSH") throw new EsimException("identity_changed");
            confirmed = response.Value.Ok;
            pending = response.Value.NotificationsPending;
            return response.Value;
        }
        catch (Exception error)
        {
            if (failure == "operation_failed") failure = error switch
            {
                OperationCanceledException => "cancelled", TimeoutException => "transport_timeout",
                EsimException esim => esim.Code, _ => "operation_failed"
            };
            throw new EsimException(failure, componentFailure);
        }
        finally
        {
            bool clean = true;
            if (directory is not null)
            {
                journal.HostStage("removing_temporary_files");
                try { clean = (await shell!.RunAsync($"if [ ! -e {directory} ]; then exit 0; fi; [ \"$(cat {directory}/owner)\" = {owner} ] && rm -f {directory}/agent {directory}/owner && rmdir {directory}", timeout: TimeSpan.FromSeconds(15), ct: CancellationToken.None)).Success; }
                catch { clean = false; }
            }
            http?.Dispose();
            _operation.Release();
            journal.Finish(confirmed && clean, clean ? failure : "temporary_cleanup_failed", clean, pending, componentFailure);
            if (!clean) throw new EsimException("temporary_cleanup_failed");
        }
    }
}
