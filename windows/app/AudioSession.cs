using System.IO;
using System.Threading.Channels;
using NAudio.Wave;

namespace LocalDictation.Windows;

/// <summary>Send audio in sequence while recording. Backpressure aborts
/// explicitly instead of silently dropping samples or corrupting offsets.</summary>
public sealed class AudioSession : IDisposable
{
    public string Id { get; } = Guid.NewGuid().ToString();
    public IntPtr Target { get; }
    public DateTimeOffset Started { get; } = DateTimeOffset.Now;
    private readonly BackendClient backend;
    private readonly Channel<byte[]> chunks = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(300)
        { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly CancellationTokenSource cancellation = new();
    private readonly TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private WaveInEvent? microphone;
    private Task? pump;
    private Exception? recordingError;
    private long samples;
    private int stopping;
    private int disposed;
    public event Action<double>? Level;
    public event Action<string>? Failure;
    public event Action? LimitReached;
    public AudioSession(BackendClient backend, IntPtr target) { this.backend = backend; Target = target; }

    public async Task StartAsync(Preferences options)
    {
        await backend.RequestAsync("POST", "/stream/start", new { session_id = Id }, options, cancellation: cancellation.Token);
        try
        {
            if (WaveInEvent.DeviceCount == 0) throw new IOException("没有可用的麦克风，请连接音频设备后重试。");
            microphone = new WaveInEvent { WaveFormat = new WaveFormat(16000, 16, 1), BufferMilliseconds = 20, NumberOfBuffers = 3 };
            microphone.DataAvailable += DataAvailable;
            microphone.RecordingStopped += (_, args) =>
            { recordingError ??= args.Exception; chunks.Writer.TryComplete(); stopped.TrySetResult(); };
            pump = PumpAsync(); microphone.StartRecording();
        }
        catch (Exception ex)
        {
            chunks.Writer.TryComplete(); stopped.TrySetResult();
            await CancelAsync();
            throw new IOException("无法打开麦克风。请检查音频设备，以及 Windows 隐私设置中的麦克风访问权限。", ex);
        }
    }

    private void DataAvailable(object? sender, WaveInEventArgs args)
    {
        if (cancellation.IsCancellationRequested || args.BytesRecorded == 0) return;
        Level?.Invoke(PcmPeak(args.Buffer.AsSpan(0, args.BytesRecorded)));
        var data = new byte[args.BytesRecorded]; Buffer.BlockCopy(args.Buffer, 0, data, 0, data.Length);
        if (!chunks.Writer.TryWrite(data))
        {
            recordingError = new IOException("音频上传跟不上录音，请检查本地服务后重试。");
            StopCapture(); Failure?.Invoke(recordingError.Message);
        }
        else if ((DateTimeOffset.Now - Started).TotalSeconds >= 295 && Interlocked.Exchange(ref stopping, 1) == 0)
        { microphone?.StopRecording(); LimitReached?.Invoke(); }
    }

    public static double PcmPeak(ReadOnlySpan<byte> bytes)
    {
        double peak = 0;
        for (int i = 0; i + 1 < bytes.Length; i += 2)
        {
            // Promote before Abs: -32768 is valid 16-bit PCM, but its positive
            // magnitude cannot be represented by the Math.Abs(short) overload.
            int sample = (short)(bytes[i] | bytes[i + 1] << 8);
            peak = Math.Max(peak, Math.Abs(sample) / 32768d);
        }
        return peak;
    }

    private async Task PumpAsync()
    {
        using var pending = new MemoryStream();
        try
        {
            await foreach (var data in chunks.Reader.ReadAllAsync(cancellation.Token))
            { pending.Write(data); if (pending.Length >= 16000) await SendPendingAsync(pending); }
            if (pending.Length > 0) await SendPendingAsync(pending);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        { recordingError ??= ex; StopCapture(); Failure?.Invoke(ex.Message); throw; }
    }

    private async Task SendPendingAsync(MemoryStream pending)
    {
        var data = pending.ToArray();
        await backend.AppendAsync(Id, samples, data, cancellation.Token);
        samples += data.Length / 2; pending.SetLength(0);
    }
    public void StopCapture()
    { if (Interlocked.Exchange(ref stopping, 1) == 0) microphone?.StopRecording(); }
    public async Task<DictationResult> FinishAsync()
    {
        StopCapture();
        try { await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (TimeoutException) { throw new IOException("麦克风未能正常结束，已停止本段录音，请检查音频设备。"); }
        if (pump != null) await pump;
        if (recordingError != null) throw recordingError;
        if (samples == 0) throw new InvalidOperationException("没有录到声音，请检查麦克风。");
        return await backend.FinishAsync(Id, samples, cancellation.Token);
    }
    public async Task CancelAsync()
    {
        if (Volatile.Read(ref disposed) != 0) return;
        StopCapture(); cancellation.Cancel(); chunks.Writer.TryComplete();
        try { await backend.RequestAsync("POST", $"/stream/{Id}/cancel", new { }); } catch { }
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        cancellation.Cancel(); microphone?.Dispose(); chunks.Writer.TryComplete(); cancellation.Dispose();
    }
}
