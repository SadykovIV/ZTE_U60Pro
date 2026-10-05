using System.Diagnostics;
using System.Text.Json;

namespace ZteImeiStudio.Windows.Esim;

// Only fixed protocol words and bounded numeric metadata may enter the journal.
// Never pass request bodies, identifiers, operator text or exception messages here.
public static class EsimDiagnostics
{
    public static readonly HashSet<string> Stages = ["checking_card", "reading_profiles", "downloading", "enabling", "deleting", "notifications", "verifying", "cleanup", "radio_offline", "radio_online", "reading_modem"];
    private static readonly HashSet<string> Events = ["stage", "waiting", "component_start", "component_exit", "apdu_sent", "apdu_reply", "http_start", "http_end", "cleanup_start", "cleanup_end"];
    private static readonly HashSet<string> Errors = [
        "operation_failed", "operation_busy", "cancelled", "transport_timeout", "agent_exit_failed", "identity_changed", "temporary_cleanup_failed",
        "http_tls_failed", "http_dns_failed", "http_timeout", "http_connection_failed", "http_response_too_large", "http_cancelled",
        "card_not_euicc", "card_busy", "card_open_rejected", "card_cleanup_unknown", "card_not_ready",
        "card_reset_failed", "card_power_restore_failed",
        "esim_busy", "operation_lock_failed", "launcher_operation_refused", "radio_read_failed", "radio_not_online", "radio_set_failed", "radio_offline_failed", "radio_restore_failed", "modem_readback_failed", "modem_slot_mismatch", "modem_iccid_mismatch",
        "bridge_already_open", "bridge_cleanup_failed", "bridge_missing", "card_changed", "component_already_closed", "component_closed", "component_eof", "component_exit_failed", "component_start_failed",
        "delete_confirmation_required", "firmware_check_failed", "http_destination_refused", "http_failed", "http_id_exhausted", "http_reply_missing", "http_unavailable", "invalid_activation_code", "invalid_apdu_reply", "invalid_arguments", "invalid_confirmation_code", "invalid_http_reply", "invalid_http_request", "invalid_json", "invalid_lpac_message", "invalid_lpac_result", "invalid_notifications", "invalid_output", "invalid_request", "invalid_snapshot", "job_deadline_exceeded", "job_message_limit", "job_start_failed", "lpac_failed", "lpac_result_missing", "message_too_large", "multiple_lpac_results", "notification_cleanup_failed", "postcondition_failed", "profile_not_disabled", "profile_not_found", "request_missing", "resource_cleanup_failed", "resource_integrity_failed", "resource_ownership_changed", "snapshot_changed", "snapshot_cleanup_failed", "snapshot_missing", "snapshot_required", "stream_read_failed", "stream_write_failed", "temporary_resource_failed", "unexpected_component_output", "unsupported_device", "unsupported_firmware", "unsupported_protocol", "unterminated_message"
    ];
    // Exact fixed helper catalog; dependency text and identifiers are discarded.
    private static readonly HashSet<string> ComponentErrors = [
        "lock_unavailable",
        "lock_random_failed",
        "lock_owner_failed",
        "lock_metadata_failed",
        "lock_release_failed",
        "lock_ownership_changed",
        "lock_retained",
        "selection_read_failed",
        "selection_mismatch",
        "qmi_connect_error",
        "qmi_open_rejected",
        "qmi_open_unknown",
        "channel_open_outcome_unknown",
        "channel_close_failed",
        "card_cleanup_unknown",
        "card_not_ready",
        "unsupported_channel",
        "qmi_transmit_error",
        "short_apdu_response",
        "snapshot_response_too_large",
        "snapshot_continuation_limit",
        "snapshot_card_status_error",
        "eid_command_error",
        "eid_parse_error",
        "eid_mismatch",
        "profiles_command_error",
        "profiles_parse_error",
        "stdout_error",
        "stdin_error",
        "unterminated_json_line",
        "input_line_too_large",
        "invalid_json_line",
        "invalid_header",
        "invalid_expected_eid",
        "missing_header",
        "invalid_arguments",
        "bridge_operation_failed",
        "already_connected",
        "already_open",
        "session_failed",
        "not_connected",
        "not_open",
        "missing_owned_connection",
        "empty_read_command",
        "invalid_envelope",
        "invalid_function",
        "invalid_aid",
        "aid_not_allowed",
        "invalid_apdu",
        "invalid_hex",
        "unsupported_function",
    ];
    public static string? SafeComponentError(string? code) => code is not null && ComponentErrors.Contains(code) ? code : null;
    public static string FailureMessage(string? code) => SafeError(code) switch
    {
        "card_busy" => "Карта занята другой операцией. Дождитесь её завершения и перечитайте профили.",
        "card_open_rejected" => "Модем отказал в открытии канала карты. Немного подождите и перечитайте профили. Операция с профилем не повторялась.",
        "card_cleanup_unknown" => "Закрытие канала карты не подтверждено. Перед повторной попыткой перезагрузите модем и перечитайте профили. Не удаляйте блокировку карты вручную.",
        "card_not_euicc" => "Управление eSIM недоступно для выбранной SIM-карты.",
        "card_not_ready" => "Выбранное приложение SIM ещё не готово. Подождите и перечитайте профили. Операция с профилем не повторялась.",
        "card_reset_failed" => "Перезапуск SIM не подтверждён. Перечитайте профили и проверьте результат переключения. Автоматического повтора не было.",
        "card_power_restore_failed" => "Включение SIM не подтверждено. Перезагрузите модем перед повторной попыткой, затем перечитайте профили.",
        "radio_restore_failed" => "Включение радио после авиарежима не подтверждено. Проверьте авиарежим на модеме и перечитайте профили. Автоматического повтора не было.",
        _ => "Операция eSIM не подтверждена. Перечитайте профили; автоматический повтор не выполняется."
    };
    public static string SafeError(string? code) => code is not null && Errors.Contains(code) ? code : "operation_failed";
    public static string ResultFailure(string? backendCode, string? httpCode)
    {
        var backend = SafeError(backendCode);
        // A failed close/cleanup or transport result takes precedence over an
        // earlier HTTP failure. Only LPAC's generic failure may be refined.
        return backend == "lpac_failed" && httpCode is not null ? SafeError(httpCode) : backend;
    }
    public static string ProgressLine(string stage, JsonElement? detail)
    {
        if (!Stages.Contains(stage)) throw new EsimException();
        var fields = new List<string> { "stage=" + stage };
        if (detail is not { } value) return string.Join(" ", fields);
        if (value.ValueKind != JsonValueKind.Object) throw new EsimException();
        var names = new HashSet<string>();
        foreach (var property in value.EnumerateObject()) if (!names.Add(property.Name)) throw new EsimException();
        string Word(string key, HashSet<string> permitted)
        {
            var word = value.GetProperty(key).GetString();
            return word is not null && permitted.Contains(word) ? word : throw new EsimException();
        }
        void Number(string key, bool required = false, ulong minimum = 0, ulong maximum = ulong.MaxValue)
        {
            if (!value.TryGetProperty(key, out var number)) { if (required) throw new EsimException(); return; }
            if (!number.TryGetUInt64(out var n) || n < minimum || n > maximum) throw new EsimException();
            fields.Add(key + "=" + n.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }
        fields.Add("event=" + Word("event", Events));
        Number("log_seq", required: true, minimum: 1);
        foreach (var key in new[] { "elapsed_ms", "apdu_count", "http_count" }) Number(key, required: true);
        foreach (var key in new[] { "duration_ms", "request_bytes", "response_bytes" }) Number(key);
        Number("http_status", maximum: 599);
        if (value.TryGetProperty("component", out _)) fields.Add("component=" + Word("component", ["snapshot", "bridge", "lpac"]));
        if (value.TryGetProperty("waiting_for", out _)) fields.Add("waiting_for=" + Word("waiting_for", ["card", "operator_https", "cleanup"]));
        if (value.TryGetProperty("outcome", out _)) fields.Add("outcome=" + Word("outcome", ["ok", "failed"]));
        if (value.TryGetProperty("error", out var error)) fields.Add("error=" + SafeError(error.ValueKind == JsonValueKind.String ? error.GetString() : null));
        // Unknown detail keys are discarded; they can never become log text.
        return string.Join(" ", fields);
    }
}

public sealed class EsimJournal
{
    private static readonly HashSet<string> HostStages = ["validating_request", "checking_target", "verifying_bundle", "uploading_agent", "starting_rpc", "checking_identity", "removing_temporary_files"];
    private readonly Action<string, string> write;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly string prefix;
    public EsimJournal(string operation, Action<string, string> write)
    {
        this.write = write;
        var safe = operation is "list" or "download" or "enable" or "delete" ? operation : "unknown";
        prefix = "eSIM[" + Guid.NewGuid().ToString("N")[..8] + "] operation=" + safe;
        Record("info", "event=start");
    }
    private void Record(string level, string fields) => write(level, prefix + " elapsed_ms=" + clock.ElapsedMilliseconds + " " + fields);
    public void HostStage(string stage) => Record("info", "stage=" + (HostStages.Contains(stage) ? stage : "unknown_stage"));
    public void Backend(string stage, JsonElement? detail) => Record("info", EsimDiagnostics.ProgressLine(stage, detail));
    public void HttpStart(int number, int requestBytes) => Record("info", $"event=host_http_start request={Math.Max(0, number)} request_bytes={Math.Clamp(requestBytes, 0, EsimValidation.MaximumHttpBytes)}");
    public void HttpEnd(int number, int status, int responseBytes, long durationMs, string? error = null) => Record(status == 0 ? "warning" : "info", $"event=host_http_end request={Math.Max(0, number)} http_status={(status is >= 100 and <= 599 ? status : 0)} response_bytes={Math.Clamp(responseBytes, 0, EsimValidation.MaximumHttpBytes)} duration_ms={Math.Max(0, durationMs)}" + (error is null ? "" : " error=" + EsimDiagnostics.SafeError(error)));
    public void BackendResult(EsimResult result) => Record(result.Ok ? "info" : "error", "event=backend_result outcome=" + (result.Ok ? "ok" : "failed") + (result.Ok ? "" : " error=" + EsimDiagnostics.SafeError(result.Error)) + (!result.Ok && EsimDiagnostics.SafeComponentError(result.ComponentError) is { } cause ? " component_error=" + cause : "") + (result.ModemVerified is { } modem ? " modem_verified=" + (modem ? "true" : "false") : "") + (result.RadioRestored is { } radio ? " radio_restored=" + (radio ? "true" : "false") : ""));
    public void Finish(bool ok, string? error, bool cleaned, bool pending = false, string? componentError = null) => Record(ok ? "ok" : "error", "event=final outcome=" + (ok ? "ok" : "not_confirmed") + " cleanup=" + (cleaned ? "ok" : "failed") + " notifications_pending=" + (pending ? "true" : "false") + (ok ? "" : " error=" + EsimDiagnostics.SafeError(error)) + (!ok && EsimDiagnostics.SafeComponentError(componentError) is { } cause ? " component_error=" + cause : ""));
}
