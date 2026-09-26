namespace ZteImeiStudio.Windows;

public enum ModemOperation
{
    DiscoverConnections,
    PrepareSsh,
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
    VpnPageSnapshot? VpnPage = null);

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

public interface IModemService
{
    Task<DeviceSnapshot> GetDeviceSnapshotAsync(CancellationToken cancellationToken = default);
    Task<OperationResult> RunAsync(OperationRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<BackupInfo>> ListBackupsAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ModemAppInfo>> ListApplicationsAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<LogEntry>> GetLogsAsync(CancellationToken cancellationToken = default);
    Task<ITerminalSession> OpenTerminalAsync(CancellationToken cancellationToken = default);
}
