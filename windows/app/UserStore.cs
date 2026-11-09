using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LocalDictation.Windows;

public sealed class Preferences
{
    [JsonRequired] public List<string> Vocabulary { get; set; } = [];
    public bool Cleanup { get; set; } = true;
    public string Language { get; set; } = "zh";
    public uint HotkeyModifiers { get; set; } = 3; // MOD_ALT | MOD_CONTROL
    public uint HotkeyKey { get; set; } = 0x20;
}

public sealed class DictationResult
{
    [JsonRequired, JsonPropertyName("raw_text")] public string RawText { get; set; } = "";
    [JsonRequired, JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("audio_seconds")] public double AudioSeconds { get; set; }
    [JsonPropertyName("asr_seconds")] public double AsrSeconds { get; set; }
    [JsonPropertyName("cleanup_seconds")] public double CleanupSeconds { get; set; }
    [JsonPropertyName("cleanup_applied")] public bool CleanupApplied { get; set; }
    [JsonPropertyName("asr_model")] public string? AsrModel { get; set; }
    [JsonPropertyName("cleanup_profile")] public JsonElement? CleanupProfile { get; set; }
    [JsonPropertyName("streaming_metrics")] public JsonElement? StreamingMetrics { get; set; }
    [JsonPropertyName("warning")] public string? Warning { get; set; }
}

public sealed class HistoryEntry
{
    [JsonRequired] public string Id { get; set; } = Guid.NewGuid().ToString();
    [JsonRequired] public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    [JsonRequired] public DictationResult Result { get; set; } = new();
    [JsonIgnore] public string Preview => Result.Text.Replace("\r", " ").Replace("\n", " ");
    [JsonIgnore] public string DateLabel => CreatedAt.LocalDateTime.ToString("MM月dd日 HH:mm");
}

/// <summary>Private user files live outside the executable. A durable primary is
/// the commit record; the mirror recovers a damaged primary without losing it.</summary>
public sealed class UserStore
{
    public static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };
    public string DirectoryPath { get; }
    public Preferences Preferences { get; private set; }
    public List<HistoryEntry> History { get; private set; }
    public string? StorageWarning { get; private set; }

    public UserStore(string? directory = null)
    {
        DirectoryPath = directory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LocalDictation");
        Directory.CreateDirectory(DirectoryPath);
        Preferences = Read<Preferences>("windows-preferences.json", new());
        History = Read<List<HistoryEntry>>("windows-history.json", []);
    }

    private T Read<T>(string name, T empty)
    {
        string primary = Path.Combine(DirectoryPath, name), mirror = primary + ".backup";
        if (!File.Exists(primary) && !File.Exists(mirror)) return empty;
        foreach (var candidate in new[] { primary, mirror })
        {
            try
            {
                var value = JsonSerializer.Deserialize<T>(File.ReadAllText(candidate, Encoding.UTF8), Json)
                    ?? throw new InvalidDataException("存储内容为空。");
                Validate(value);
                if (candidate != primary)
                {
                    if (File.Exists(primary)) File.Move(primary, primary + ".preserved-" + Guid.NewGuid().ToString("N"));
                    WriteFile(primary, JsonSerializer.SerializeToUtf8Bytes(value, Json));
                    StorageWarning = "已从本机备份恢复数据，原文件已保留。";
                }
                return value;
            }
            catch (Exception ex) when (ex is IOException or InvalidDataException or JsonException or UnauthorizedAccessException) { }
        }
        throw new InvalidDataException("本机数据暂时无法读取。原文件未被覆盖，请检查数据文件夹。");
    }

    private static void WriteFile(string path, byte[] bytes)
    {
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { stream.Write(bytes); stream.Flush(true); }
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private void Save<T>(string name, T value)
    {
        Validate(value);
        var path = Path.Combine(DirectoryPath, name);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, Json);
        WriteFile(path, bytes);
        try { WriteFile(path + ".backup", bytes); StorageWarning = null; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { StorageWarning = "正文已保存，但备份未完成，请检查可用空间。"; }
    }

    private static void Validate<T>(T value)
    {
        if (value is Preferences preferences)
        {
            if (preferences.Vocabulary == null || preferences.Vocabulary.Any(word => string.IsNullOrWhiteSpace(word))
                || preferences.Language is not ("zh" or "auto") || preferences.HotkeyKey == 0 || (preferences.HotkeyModifiers & ~15u) != 0)
                throw new InvalidDataException("词典或快捷键配置格式异常。");
        }
        if (value is List<HistoryEntry> rows && rows.Any(row => row == null || string.IsNullOrWhiteSpace(row.Id)
            || row.Result == null || row.Result.RawText == null || row.Result.Text == null
            || !double.IsFinite(row.Result.AudioSeconds) || row.Result.AudioSeconds < 0
            || (row.Result.CleanupProfile is JsonElement profile && profile.ValueKind != JsonValueKind.Object)))
            throw new InvalidDataException("历史记录结构异常。");
    }

    public void SavePreferences(Preferences value)
    { Save("windows-preferences.json", value); Preferences = value; }
    public void Add(HistoryEntry entry)
    {
        if (History.Any(item => item.Id == entry.Id)) return;
        var next = new List<HistoryEntry>(History); next.Insert(0, entry);
        Save("windows-history.json", next); History = next;
    }
    public void Delete(string id)
    { var next = History.Where(item => item.Id != id).ToList(); Save("windows-history.json", next); History = next; }
    public Preferences CopyPreferences() => JsonSerializer.Deserialize<Preferences>(JsonSerializer.Serialize(Preferences, Json), Json)!;
    public List<HistoryEntry> Search(string search) => History.Where(item => string.IsNullOrWhiteSpace(search)
        || item.Result.Text.Contains(search, StringComparison.CurrentCultureIgnoreCase)
        || item.Result.RawText.Contains(search, StringComparison.CurrentCultureIgnoreCase)).ToList();
}
