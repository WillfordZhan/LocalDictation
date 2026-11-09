using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace LocalDictation.Windows;

public sealed class BackendClient : IDisposable
{
    private readonly HttpClient http = new(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false })
        { BaseAddress = new Uri("http://127.0.0.1:8767"), Timeout = TimeSpan.FromMinutes(8) };
    private Process? child;
    private readonly string dataDirectory;
    private readonly string applicationDirectory;
    public event Action<string>? Diagnostic;
    public BackendClient(string dataDirectory, string? applicationDirectory = null)
    { this.dataDirectory = dataDirectory; this.applicationDirectory = applicationDirectory ?? AppContext.BaseDirectory; }

    public static string OptionsHeader(Preferences options) => Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new
        { cleanup = options.Cleanup, language = options.Language, vocabulary = options.Vocabulary }));

    public async Task<JsonElement> RequestAsync(string method, string path, object? body = null,
        Preferences? options = null, string? profileId = null, CancellationToken cancellation = default)
    {
        using var request = new HttpRequestMessage(new HttpMethod(method), path);
        if (body != null) request.Content = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(body));
        if (request.Content != null) request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        if (options != null) request.Headers.Add("X-Dictation-Options", OptionsHeader(options));
        if (profileId != null) request.Headers.Add("X-Cleanup-Prompt-Version", profileId);
        using var response = await http.SendAsync(request, cancellation);
        return await ReadAsync(response, cancellation);
    }

    private static async Task<JsonElement> ReadAsync(HttpResponseMessage response, CancellationToken cancellation)
    {
        var text = await response.Content.ReadAsStringAsync(cancellation);
        JsonElement result;
        try { using var json = JsonDocument.Parse(text); result = json.RootElement.Clone(); }
        catch (JsonException) { throw new InvalidDataException("本地服务返回了无法读取的结果。"); }
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException(result.TryGetProperty("error", out var error) ? error.GetString() : "本地服务暂不可用。");
        return result;
    }

    public async Task<JsonElement?> HealthAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            var health = await RequestAsync("GET", "/health", cancellation: timeout.Token);
            if (health.GetProperty("service").GetString() != "local-dictation")
                throw new InvalidDataException("本地服务端口被其他程序使用。");
            return health;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException) { return null; }
    }

    public async Task EnsureStartedAsync()
    {
        if (await HealthAsync() != null) return;
        if (child != null && !child.HasExited) return;
        string python = Path.Combine(applicationDirectory, "runtime", "python", "python.exe");
        string entry = Path.Combine(applicationDirectory, "backend", "windows_server.py");
        string llama = Path.Combine(applicationDirectory, "runtime", "llama", "llama-server.exe");
        if (!File.Exists(python) || !File.Exists(entry)) throw new FileNotFoundException("运行环境不完整，请重新解压完整安装包。");
        var start = ProcessInfo(python);
        foreach (var argument in new[] { "-B", entry, "--data-dir", dataDirectory, "--port", "8767", "--llama-server", llama,
                     "--parent-pid", Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture) })
            start.ArgumentList.Add(argument);
        child = new Process { StartInfo = start, EnableRaisingEvents = true };
        child.OutputDataReceived += (_, e) => { if (e.Data != null) Diagnostic?.Invoke(e.Data); };
        child.ErrorDataReceived += (_, e) => { if (e.Data != null) Diagnostic?.Invoke(e.Data); };
        child.Start(); child.BeginOutputReadLine(); child.BeginErrorReadLine();
    }

    private ProcessStartInfo ProcessInfo(string executable)
    {
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
            RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8, WorkingDirectory = applicationDirectory
        };
        info.Environment["PYTHONUTF8"] = "1"; info.Environment["PYTHONDONTWRITEBYTECODE"] = "1";
        return info;
    }

    public async Task<JsonElement> CheckSetupAsync(bool download, Action<string>? progress = null, Action<double>? percentage = null)
    {
        var start = ProcessInfo(Path.Combine(applicationDirectory, "runtime", "python", "python.exe"));
        foreach (var argument in new[] { "-B", Path.Combine(applicationDirectory, "backend", "windows_setup.py"),
                     "--data-dir", dataDirectory, "--json" }) start.ArgumentList.Add(argument);
        if (download) start.ArgumentList.Add("--download");
        using var process = new Process { StartInfo = start };
        var output = new StringBuilder();
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            lock (output) output.AppendLine(e.Data);
            try
            {
                using var line = JsonDocument.Parse(e.Data);
                if (line.RootElement.TryGetProperty("message", out var message)) progress?.Invoke(message.GetString() ?? "正在准备模型…");
                if (line.RootElement.TryGetProperty("progress", out var fraction) && fraction.TryGetDouble(out var value)) percentage?.Invoke(Math.Clamp(value, 0, 1));
            }
            catch (JsonException) { }
        };
        process.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) progress?.Invoke(e.Data); };
        process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
        await process.WaitForExitAsync(); process.WaitForExit();
        string value; lock (output) value = output.ToString();
        JsonElement report;
        try { using var document = JsonDocument.Parse(value); report = document.RootElement.Clone(); }
        catch (JsonException)
        {
            var lines = value.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            if (lines.Length == 0) throw new InvalidOperationException("配置检查没有返回结果，请检查运行环境。");
            using var document = JsonDocument.Parse(lines[^1]); report = document.RootElement.Clone();
        }
        if (process.ExitCode != 0)
            throw new InvalidOperationException(report.TryGetProperty("error", out var error) ? error.GetString() : "模型配置没有完成，请重试。");
        return report;
    }

    public async Task AppendAsync(string session, long offset, byte[] pcm, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/stream/{session}/audio");
        request.Headers.Add("X-Audio-Offset", offset.ToString(System.Globalization.CultureInfo.InvariantCulture));
        request.Content = new ByteArrayContent(pcm);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        using var response = await http.SendAsync(request, cancellation); await ReadAsync(response, cancellation);
    }

    public async Task<DictationResult> FinishAsync(string session, long samples, CancellationToken cancellation)
    {
        var value = await RequestAsync("POST", $"/stream/{session}/finish", new { total_samples = samples }, cancellation: cancellation);
        var result = value.Deserialize<DictationResult>() ?? throw new InvalidDataException("没有收到转写结果。");
        if (result.Text == null || result.RawText == null) throw new InvalidDataException("转写结果缺少正文。");
        return result;
    }

    public async Task StopOwnedAsync()
    {
        if (child == null) return;
        if (!child.HasExited)
        {
            // Only this app's child tree is stopped after all recording work
            // has drained. An externally launched service is never terminated.
            child.Kill(entireProcessTree: true); await child.WaitForExitAsync();
        }
        child.Dispose(); child = null;
    }
    public void Dispose() { http.Dispose(); child?.Dispose(); }
}
