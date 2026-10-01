using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using ZteImeiStudio.Windows.Features;

namespace ZteImeiStudio.Windows;

public sealed partial class MainWindow
{
    private bool _launcherPagesDirty;
    private StackPanel? _launcherPageRows;
    private void BuildLauncherPageEditor(StackPanel panel)
    {
        if (!_form.ContainsKey("pages")) _form["pages"] = "info,vpn,esim";
        if (!_form.ContainsKey("page_order")) _form["page_order"] = "info,vpn,esim";
        _launcherPageRows = new StackPanel { Spacing = 6 };
        panel.Children.Add(_launcherPageRows);
        RenderLauncherPageRows();
        panel.Children.Add(Muted("Отметьте дополнительные страницы и задайте их порядок. Без отметок останутся только две штатные страницы."));
        var actions = new WrapPanel { Orientation = Orientation.Horizontal };
        var install = ActionButton("Установить плитки", () => SubmitLauncherPagesAsync(true), true);
        install.Name = "LauncherInstallPages"; actions.Children.Add(install);
        var apply = ActionButton("Применить выбор страниц", () => SubmitLauncherPagesAsync(false), false);
        apply.Name = "LauncherApplyPages"; actions.Children.Add(apply); panel.Children.Add(actions);
        panel.Children.Add(Muted("Установка может перезапустить экран. Изменение выбора страниц применяется без перезапуска; настройки информационных показателей сохраняются."));
    }
    private string[] LauncherPageOrder()
    {
        var order = Get("page_order").Split(',', StringSplitOptions.RemoveEmptyEntries);
        return order.Length == 3 && order.Distinct().Count() == 3 && order.All(LauncherPages.Ids.Contains)
            ? order : LauncherPages.Ids.ToArray();
    }
    private void SaveLauncherPageDraft(IEnumerable<string> order, IEnumerable<string> enabled)
    {
        var items = order.ToArray(); var set = enabled.ToHashSet(StringComparer.Ordinal);
        _form["page_order"] = string.Join(',', items);
        _form["pages"] = string.Join(',', items.Where(set.Contains));
        _launcherPagesDirty = true;
    }
    private void RenderLauncherPageRows()
    {
        if (_launcherPageRows is null) return;
        _launcherPageRows.Children.Clear();
        var order = LauncherPageOrder();
        var enabled = Get("pages").Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
        foreach (var id in order)
        {
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto") };
            var label = id switch { "info" => "Информация о модеме", "vpn" => "Управление VPN", _ => "eSIM" };
            var box = new CheckBox { Name = "LauncherPage-" + id, Content = Localization.Translate(label), IsChecked = enabled.Contains(id), IsEnabled = !_busy };
            box.IsCheckedChanged += (_, _) =>
            {
                var current = Get("pages").Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
                if (box.IsChecked == true) current.Add(id); else current.Remove(id);
                SaveLauncherPageDraft(LauncherPageOrder(), current);
            };
            row.Children.Add(box);
            foreach (var (direction, column) in new[] { (-1, 1), (1, 2) })
            {
                var move = new Button { Name = "LauncherPage" + (direction < 0 ? "Up-" : "Down-") + id, Content = direction < 0 ? "▲" : "▼", Margin = new Thickness(4, 0, 0, 0), IsEnabled = !_busy && Array.IndexOf(order, id) + direction is >= 0 and < 3 };
                move.Click += (_, _) =>
                {
                    var items = LauncherPageOrder(); var from = Array.IndexOf(items, id); var to = from + direction;
                    if (to is < 0 or >= 3) return;
                    (items[from], items[to]) = (items[to], items[from]);
                    SaveLauncherPageDraft(items, Get("pages").Split(',', StringSplitOptions.RemoveEmptyEntries));
                    RenderLauncherPageRows();
                };
                Grid.SetColumn(move, column); row.Children.Add(move);
            }
            _launcherPageRows.Children.Add(row);
        }
    }
    private async Task SubmitLauncherPagesAsync(bool install)
    {
        if (_busy) return;
        var selected = Get("pages");
        var metrics = new[] { "style", "metrics", "metric_order" }.ToDictionary(k => k, k => _form.GetValueOrDefault(k));
        try
        {
            await ExecuteAsync(install ? ModemOperation.InstallLauncher : ModemOperation.ApplyLauncherPages, ["pages"]);
            if (_snapshot?.LauncherPages == selected) _launcherPagesDirty = false;
        }
        finally
        {
            foreach (var (key, value) in metrics)
                if (value is null) _form.Remove(key); else _form[key] = value;
        }
    }
}
