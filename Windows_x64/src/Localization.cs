using System.Text.Json;
using System.Text.RegularExpressions;

namespace ZteImeiStudio.Windows;

/// <summary>Local UI translation only: commands, user input and stored protocol values remain unchanged.</summary>
public static class Localization
{
    private static readonly string SettingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZTE IMEI Studio", "interface-language.json");
    private static readonly IReadOnlyDictionary<string, string> English = ReadEnglish();
    private static readonly (Regex Pattern, string Translation)[] Templates = English
        .Where(pair => pair.Key.Contains('{'))
        .Select(pair => (Pattern: TemplateRegex(pair.Key), Translation: TemplateTranslation(pair.Key, pair.Value)))
        .ToArray();
    public static string Language { get; private set; } = ReadLanguage();
    public static bool IsEnglish => Language == "en";

    public static void SetLanguage(string language, bool persist = true)
    {
        Language = language == "en" ? "en" : "ru";
        if (!persist) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            var temporary = SettingsPath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(new { language = Language }));
            File.Move(temporary, SettingsPath, overwrite: true);
        }
        catch (IOException) { /* A read-only profile still permits changing the language for this session. */ }
        catch (UnauthorizedAccessException) { }
    }

    public static string Translate(string? text)
    {
        if (text is null) return "";
        if (!IsEnglish || !text.Any(c => c is >= '\u0400' and <= '\u04ff')) return text;
        if (English.TryGetValue(text, out var exact)) return exact;
        foreach (var template in Templates)
            if (template.Pattern.IsMatch(text)) return template.Pattern.Replace(text, template.Translation);
        // Runtime device statuses and exception details often combine stable messages with paths.
        // Replace complete known phrases; never modify shell input, protocol keys or terminal output.
        var result = text;
        foreach (var pair in English.OrderByDescending(pair => pair.Key.Length))
        {
            if (pair.Key.Contains('{') || pair.Key.Length < 4 || !result.Contains(pair.Key, StringComparison.Ordinal)) continue;
            result = Regex.Replace(result, @"(?<![\p{L}\p{N}_])" + Regex.Escape(pair.Key) + @"(?![\p{L}\p{N}_])", _ => pair.Value);
        }
        return result;
    }

    private static IReadOnlyDictionary<string, string> ReadEnglish()
    {
        using var stream = typeof(Localization).Assembly.GetManifestResourceStream("ZteManager.Localization.en.json");
        return stream is null ? new Dictionary<string, string>() : JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ?? [];
    }

    private static string ReadLanguage()
    {
        try
        {
            using var json = JsonDocument.Parse(File.ReadAllText(SettingsPath));
            return json.RootElement.GetProperty("language").GetString() == "en" ? "en" : "ru";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException) { return "ru"; }
    }

    private static Regex TemplateRegex(string text)
    {
        var escaped = Regex.Escape(text);
        escaped = Regex.Replace(escaped, @"\\\{[^}]+}", _ => "(.*?)");
        return new Regex("^" + escaped + "$", RegexOptions.CultureInvariant | RegexOptions.Singleline, TimeSpan.FromMilliseconds(50));
    }

    private static string TemplateTranslation(string original, string translation)
    {
        var placeholders = Regex.Matches(original, @"\{[^}]+}").Select(match => match.Value).ToArray();
        for (var i = 0; i < placeholders.Length; i++) translation = translation.Replace(placeholders[i], "${" + (i + 1) + "}", StringComparison.Ordinal);
        return translation;
    }
}
