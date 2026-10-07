using Avalonia.Threading;
using ZteImeiStudio.Windows.Research;

namespace ZteImeiStudio.Windows;
public sealed partial class MainWindow
{
    private ResearchReport? _researchReport;
    private CancellationTokenSource? _researchCancellation;
    private string? _lastResearchInput;
    private string ResearchInputKey()=>string.Join("\n",new[]{"host","key_path","known_hosts_path"}.Select(Get));
    private async Task CollectPreparationResearchAsync()
    {
        if(_busy || _terminal?.IsConnected==true || _terminalOpening)return;
        var inspectedInput=ResearchInputKey();
        _lastResearchInput=null;
        _researchCancellation=CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        var collection = _researchCancellation;
        var parameters=_form.ToDictionary(x=>x.Key,x=>x.Value);
        parameters["mode"] = "Автоматически";
        foreach (var secret in _secretFields) parameters[secret.Key] = secret.Value.Text ?? "";
        SetBusy(true);SetStatus("Определение доступного канала…");RenderPage();
        try
        {
            var progress=new Progress<ResearchProgress>(value=>Dispatcher.UIThread.Post(()=>
            {
                if (ReferenceEquals(_researchCancellation, collection))
                    SetStatus($"{value.Completed}/{value.Total} · {value.Title.Text(Localization.IsEnglish)}");
            }));
            _researchReport = await _service.CollectPreparationResearchAsync(parameters,progress,_researchCancellation.Token);
            if(_researchReport.Outcome is not ("cancelled" or "device_changed" or "trust_rejected"))_lastResearchInput=inspectedInput;
        }
        catch(Exception error) { SetStatus(error.Message, true); }
        finally { _researchCancellation.Dispose();_researchCancellation=null;SetBusy(false);RenderPage(); }
    }
}
