using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using ZteImeiStudio.Windows.Research;

namespace ZteImeiStudio.Windows;
public sealed partial class MainWindow
{
    private ResearchReport? _researchReport;
    private CancellationTokenSource? _researchCancellation;
    private TextBlock? _researchProgress;
    private string _researchProgressText="";
    private string? _lastResearchInput;
    private string ResearchInputKey()=>string.Join("\n",new[]{"host","key_path","known_hosts_path"}.Select(Get));
    private static string ResearchState(string state)=>state switch
    {
        "prerequisites_met"=>"Предпосылки подтверждены",
        "blocked"=>"Есть препятствия",
        _=>"Недостаточно данных",
    };
    private static string ResearchOutcome(string value)=>Localization.Translate(value switch
    {
        "complete"=>"Сбор завершён", "partial"=>"Частичный отчёт", "cancelled"=>"Сбор отменён", "device_changed"=>"Устройство изменилось", "connection_lost"=>"Подключение потеряно", "time_limit"=>"Лимит времени сбора", "trust_rejected"=>"Ключ SSH отклонён", _=>value,
    });
    private void BuildFirmwareResearch()
    {
        AddCard(Localization.IsEnglish ? "1. Check device" : "1. Проверить устройство", Localization.IsEnglish ? "Collect technical information over SSH. Unknown firmware and missing CID do not stop the survey. Installation prerequisites are checked again before each operation." : "Технические сведения собираются по SSH. Неизвестная прошивка и отсутствие CID не прекращают диагностику. Возможности установки проверяются отдельно перед каждой операцией.",panel=>
        {
            panel.Children.Add(Muted(Localization.IsEnglish ? "Read-only. No ADB activation, component installation or automatic fallback to another channel." : "Только чтение. Без включения ADB, установки компонентов и автоматического перехода на другой канал."));
            var row=new WrapPanel {Orientation=Orientation.Horizontal};
            var collect=ActionButton(Localization.IsEnglish ? "Check device" : "Проверить устройство",() => CollectFirmwareResearchAsync(),true);
            _researchCollectButton = collect;
            collect.Name="CollectFirmwareResearch";collect.IsEnabled=!_busy && _terminal?.IsConnected!=true && !_terminalOpening;
            row.Children.Add(collect);
            if(_researchCancellation is not null)
            {
                var cancel=new Button {Content=Localization.Translate("Остановить сбор"),Margin=new Thickness(0,0,8,7),Padding=new Thickness(13,8),Background=Elevated,Foreground=Foreground};
                cancel.Click+=(_,_)=>_researchCancellation?.Cancel();row.Children.Add(cancel);
            }
            panel.Children.Add(row);
            if(_terminal?.IsConnected==true || _terminalOpening)panel.Children.Add(Muted("Перед исследованием отключите интерактивный терминал."));
            _researchProgress=Muted(_researchProgressText);panel.Children.Add(_researchProgress);
            if(_researchReport is not { } report)return;
            panel.Children.Add(Muted($"{report.CompletedAt.LocalDateTime:dd.MM.yyyy HH:mm:ss} · {report.Channel} · {ResearchOutcome(report.Outcome)} · {report.Profile??Localization.Translate("Неизвестная прошивка")}"));
            panel.Children.Add(Muted("Отчёт сохраняется локально и включается в общий диагностический ZIP. Экспорт доступен после отключения модема или перезапуска программы; пароли и личные идентификаторы скрываются."));
            var details=new StackPanel {Spacing=12};
            details.Children.Add(Muted((Localization.IsEnglish ? "Device binding: " : "Привязка устройства: ")+report.BindingStrength));
            details.Children.Add(new TextBlock {Text=Localization.IsEnglish ? "Technical inventory" : "Технические сведения",Foreground=Accent,FontWeight=FontWeight.SemiBold});
            foreach(var observation in report.Observations??[])
                details.Children.Add(Muted(observation.Title.Text(Localization.IsEnglish)+": "+(observation.Value??observation.Status)+" · "+observation.Probe+"/"+observation.Fact+" · "+observation.SourceStatus));
            details.Children.Add(new TextBlock {Text=Localization.IsEnglish ? "Operation prerequisites" : "Предпосылки функций",Foreground=Accent,FontWeight=FontWeight.SemiBold});
            foreach(var feature in report.Features)
            {
                var featurePanel=new StackPanel {Spacing=4};
                featurePanel.Children.Add(new TextBlock {Text=feature.Title.Text(Localization.IsEnglish)+" · "+Localization.Translate(ResearchState(feature.State)),Foreground=feature.State=="prerequisites_met"?Accent:Warn,FontWeight=FontWeight.SemiBold,TextWrapping=TextWrapping.Wrap});
                foreach(var reason in feature.Reasons)featurePanel.Children.Add(Muted("• "+reason.Text(Localization.IsEnglish)));
                featurePanel.Children.Add(Muted(feature.Limitations.Text(Localization.IsEnglish)));
                details.Children.Add(new Border {Background=Elevated,Padding=new Thickness(12),CornerRadius=new CornerRadius(8),Child=featurePanel});
            }
            var faults=report.Probes.Where(p=>p.Status is not "success" and not "skipped").ToArray();
            foreach(var fault in faults)details.Children.Add(Muted(fault.Title.Text(Localization.IsEnglish)+" · "+fault.Status+" · "+(fault.Stderr.Length>800?fault.Stderr[..800]+"…":fault.Stderr)));
            details.Children.Add(Muted(Localization.IsEnglish?"Full commands, outputs, timings, omissions and checksums are included in the ZIP.":"Все команды, результаты, длительности, пропуски и контрольные суммы включаются в ZIP."));
            panel.Children.Add(new Expander {Header=Localization.Translate("Результаты исследования"),Content=details,HorizontalAlignment=HorizontalAlignment.Stretch});
        });
    }
    private async Task CollectFirmwareResearchAsync(bool forPreparation = false)
    {
        if(_busy || _terminal?.IsConnected==true || _terminalOpening)return;
        var inspectedInput=ResearchInputKey();
        _lastResearchInput=null;
        _researchCancellation=CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        var parameters=_form.ToDictionary(x=>x.Key,x=>x.Value);
        parameters["mode"] = forPreparation ? "Автоматически" : "SSH";
        foreach (var secret in _secretFields) parameters[secret.Key] = secret.Value.Text ?? "";
        SetBusy(true);_researchProgressText=Localization.Translate("Определение доступного канала…");RenderPage();
        try
        {
            var progress=new Progress<ResearchProgress>(value=>Dispatcher.UIThread.Post(()=>
            {
                _researchProgressText=$"{value.Completed}/{value.Total} · {value.Title.Text(Localization.IsEnglish)}";
                if(_researchProgress is not null)_researchProgress.Text=_researchProgressText;
            }));
            _researchReport = forPreparation
                ? await _service.CollectPreparationResearchAsync(parameters,progress,_researchCancellation.Token)
                : await _service.CollectFirmwareResearchAsync(parameters,progress,_researchCancellation.Token);
            if(forPreparation && _researchReport.Outcome is not ("cancelled" or "device_changed" or "trust_rejected"))_lastResearchInput=inspectedInput;
            _researchProgressText=Localization.Translate("Исследование завершено. Частичный отчёт также доступен для экспорта.");
        }
        catch(Exception error) { _researchProgressText=error.Message; }
        finally { _researchCancellation.Dispose();_researchCancellation=null;SetBusy(false);RenderPage(); }
    }
    private async Task ExportFirmwareResearchAsync()
    {
        if(_researchReport is not { } report || _busy)return;
        var file=await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title=Localization.Translate("Экспорт исследования прошивки"),SuggestedFileName="ZTE-firmware-research-"+report.CompletedAt.ToString("yyyyMMdd-HHmmss")+".zip",DefaultExtension="zip",
            FileTypeChoices=[new FilePickerFileType("ZIP") {Patterns=["*.zip"]}],ShowOverwritePrompt=true,
        });
        if(file?.TryGetLocalPath() is not { } path)return;
        await _service.ExportFirmwareResearchAsync(report,path,_lifetime.Token);SetStatus("Отчёт ZIP сохранён.");
    }
}
