using ZteImeiStudio.Windows.Research;

namespace ZteImeiStudio.Windows;

public enum ModemOperation
{
    DiscoverConnections,
    PrepareSsh,
    EnableDiagnosticAdb,
    RefreshAdbState,
    SetAdbEnabled,
    Connect,
    RefreshDevice,
    RefreshAgent,
    InstallAgent,
    RestoreAgent,
    RefreshLocalization,
    InstallLocalization,
    RestoreLocalization,
    RefreshLauncher,
    InstallLauncher,
    ApplyLauncherLayout,
    ReadImei,
    CreateImeiBackup,
    ApplyImei,
    ResumeImei,
    RestoreImeiBackup,
    RefreshTtl,
    ApplyTtl,
    RefreshVpn,
    InstallVpn,
    RefreshVpnWifi,
    SaveVpnWifi,
    RefreshApplications,
    InstallApplication,
    RemoveApplication,
    RefreshOpkg,
    InstallOpkg,
    RemoveOpkg,
    RunOpkgCommand,
    LoadOpkgFeeds,
    SaveOpkgFeeds,
    RefreshAccess,
    CreateSshAccount,
    RemoveSshAccount,
    ChangeAccessService,
    CreateDeviceBackup,
    VerifyDeviceBackup,
    CreateSystemBackup,
    VerifySystemBackup,
    RestoreDeviceBackup,
    ExportDiagnostics,
    RefreshDiagnostics,
    RebootDevice,
    InstallEsimLauncher,
    ApplyLauncherPages,
}

public sealed record OperationRequest(
    ModemOperation Operation,
    IReadOnlyDictionary<string, string>? Parameters = null);

public sealed record OperationResult(
    bool Success,
    string Message,
    string? Details = null,
    IReadOnlyDictionary<string, string>? Values = null);

public sealed record DeviceSnapshot(
    bool IsConnected,
    string Status,
    string? Model = null,
    string? Firmware = null,
    string? Serial = null,
    string? Imei = null,
    string? IpAddress = null,
    string? ConnectionMode = null,
    string? Battery = null,
    string? Storage = null,
    string? Agent = null,
    string? Launcher = null,
    string? Ttl = null,
    string? Vpn = null,
    IReadOnlyDictionary<string, string>? Details = null,
    string? LauncherStyle = null,
    string? LauncherMetrics = null,
    string? VpnSsid = null,
    string? VpnPasswordMode = null,
    string? LauncherMetricOrder = null,
    VpnPageSnapshot? VpnPage = null,
    string? LauncherPages = null,
    bool AdbActivationPending = false,
    bool PreparationPending = false,
    bool? AdbEnabled = null,
    bool AdbControlSupported = false,
    string? AdbStatus = null);

public sealed record VpnPageSnapshot(
    bool Installed,
    bool ComponentsReady,
    bool Configured,
    bool Enabled,
    bool CoreRunning,
    string? Ssid,
    IReadOnlyList<string> Profiles,
    string? ActiveProfile);

public sealed record BackupInfo(
    string Id,
    string Name,
    string Category,
    DateTimeOffset CreatedAt,
    string? Path = null,
    long? SizeBytes = null);

public sealed record ModemAppInfo(
    string Id,
    string Name,
    string? Version = null,
    bool Installed = false,
    string? Description = null,
    bool StatusKnown = true);

public sealed record LogEntry(
    DateTimeOffset Timestamp,
    string Level,
    string Message);

public sealed class TerminalDataEventArgs(string text) : EventArgs
{
    public string Text { get; } = text;
}

public interface ITerminalSession : IAsyncDisposable
{
    event EventHandler<TerminalDataEventArgs>? OutputReceived;
    bool IsConnected { get; }
    Task SendAsync(string text, CancellationToken cancellationToken = default);
}

public sealed record ConnectionSettingsSnapshot(
    string Host = "192.168.0.1", int Port = 2222, string Username = "root",
    string KeyPath = "", string KnownHostsPath = "");

public interface IModemService
{
    ConnectionSettingsSnapshot GetConnectionSettings() => new();
    Task<Esim.EsimResult> RunEsimAsync(Esim.EsimRequest request, IProgress<string>? progress, CancellationToken ct = default) => throw new Esim.EsimException();
    Task<ResearchReport?> GetFirmwareResearchAsync(CancellationToken ct = default) => Task.FromResult<ResearchReport?>(null);
    Task<ResearchReport> CollectFirmwareResearchAsync(IReadOnlyDictionary<string,string> parameters, IProgress<ResearchProgress>? progress, CancellationToken ct = default) => throw new NotSupportedException();
    Task<ResearchReport> CollectPreparationResearchAsync(IReadOnlyDictionary<string,string> parameters, IProgress<ResearchProgress>? progress, CancellationToken ct = default)
        => CollectFirmwareResearchAsync(parameters, progress, ct);
    Task ExportFirmwareResearchAsync(ResearchReport report, string destination, CancellationToken ct = default) => throw new NotSupportedException();
    Task<DeviceSnapshot> GetDeviceSnapshotAsync(CancellationToken cancellationToken = default);
    Task<OperationResult> RunAsync(OperationRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<BackupInfo>> ListBackupsAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ModemAppInfo>> ListApplicationsAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<LogEntry>> GetLogsAsync(CancellationToken cancellationToken = default);
    Task<ITerminalSession> OpenTerminalAsync(CancellationToken cancellationToken = default);
}
