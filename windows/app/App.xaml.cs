using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace LocalDictation.Windows;

public partial class App : System.Windows.Application
{
    private Mutex? singleton;
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        string? Arg(string name)
        { int index = Array.IndexOf(e.Args, name); return index >= 0 && index + 1 < e.Args.Length ? e.Args[index + 1] : null; }
        if (e.Args.Contains("--self-test"))
        {
            int exit = RunSelfTest(Arg("--result-file")); Shutdown(exit); return;
        }
        bool smoke = e.Args.Contains("--ui-smoke");
        if (smoke && (Arg("--data-dir") == null || Arg("--result-dir") == null)) { Shutdown(2); return; }
        if (!smoke)
        {
            singleton = new Mutex(true, "Local\\LocalDictation.Windows", out bool first);
            if (!first) { MessageBox.Show("本地口述已在托盘运行。", "本地口述"); Shutdown(); return; }
        }
        try
        {
            if (smoke)
            {
                var smokeData = Path.GetFullPath(Arg("--data-dir")!);
                var marker = Path.Combine(smokeData, ".ui-smoke-fixture");
                if (Directory.Exists(smokeData) && Directory.EnumerateFileSystemEntries(smokeData).Any() && !File.Exists(marker))
                    throw new InvalidOperationException("界面测试需要独立的空数据目录，不能读取已有用户数据。");
                Directory.CreateDirectory(smokeData); File.WriteAllText(marker, "LocalDictation UI test data");
            }
            var store = new UserStore(Arg("--data-dir"));
            if (smoke && store.History.Count == 0)
            {
                for (int i = 0; i < 24; i++) store.Add(new HistoryEntry { CreatedAt = DateTimeOffset.Now.AddMinutes(-i * 17),
                    Result = new DictationResult { RawText = "嗯，先把页面做好，测试通过以后再发布。", Text = "先把页面做好，测试通过以后再发布。", AudioSeconds = 18, AsrSeconds = 1.2, CleanupSeconds = 2.3, AsrModel = "本机识别模型" } });
                var preferences = store.CopyPreferences(); preferences.Vocabulary = ["BOM", "SalesPart", "ProductPart", "SalesItem", "Typeless"]; store.SavePreferences(preferences);
            }
            var window = new MainWindow(store, smoke); MainWindow = window; window.Show();
            if (smoke)
            {
                string directory = Path.GetFullPath(Arg("--result-dir")!); Directory.CreateDirectory(directory);
                foreach (string page in new[] { "home", "history", "dictionary", "prompts", "settings" })
                {
                    window.SelectPage(page); await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                    await Task.Delay(100); window.UpdateLayout();
                    var image = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                    image.Render(window); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
                    using var stream = File.Create(Path.Combine(directory, page + ".png")); encoder.Save(stream);
                }
                File.WriteAllText(Path.Combine(directory, "ui-smoke.json"), JsonSerializer.Serialize(new
                    { success = true, pages = new[] { "home", "history", "dictionary", "prompts", "settings" }, history = store.History.Count,
                      microphone_access = false, hotkey_registered = false, backend_started = false, clipboard_access = false }, UserStore.Json));
                window.CloseSmoke();
            }
        }
        catch (Exception ex)
        {
            if (smoke && Arg("--result-dir") is string result)
            { Directory.CreateDirectory(result); File.WriteAllText(Path.Combine(result, "ui-smoke-error.txt"), ex.ToString()); }
            else MessageBox.Show(ex.Message, "本地口述暂时无法启动", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    private static int RunSelfTest(string? resultFile)
    {
        var checks = new List<string>();
        string directory = Path.Combine(Path.GetTempPath(), "LocalDictation-tests-" + Guid.NewGuid().ToString("N"));
        void Require(bool condition, string name) { if (!condition) throw new InvalidOperationException(name); checks.Add(name); }
        try
        {
            var store = new UserStore(directory);
            var preferences = store.CopyPreferences(); preferences.Vocabulary = Enumerable.Range(0, 120).Select(i => "术语" + i).ToList();
            preferences.HotkeyModifiers = 3; preferences.HotkeyKey = 0x20; store.SavePreferences(preferences);
            var result = new DictationResult { Text = "正文 😀\n保留代码 `x < 2`。", RawText = "嗯，正文 😀 保留代码 `x < 2`。", AsrModel = "fixture", AudioSeconds = 10 };
            var entry = new HistoryEntry { Result = result }; store.Add(entry); store.Add(entry);
            var reopened = new UserStore(directory);
            Require(reopened.History.Count == 1 && reopened.History[0].Result.Text == result.Text, "history_persists_exactly_and_deduplicates");
            Require(reopened.History[0].Result.RawText == result.RawText, "raw_and_final_stored_separately");
            Require(reopened.Preferences.Vocabulary.Count == 120, "dictionary_over_64_words_persists");
            File.WriteAllText(Path.Combine(directory, "windows-preferences.json"), "{\"Vocabulary\":null}");
            Require(new UserStore(directory).Preferences.Vocabulary.Count == 120, "null_vocabulary_recovers_without_replacing_backup");
            Require(reopened.Search("代码").Count == 1 && reopened.Search("不存在").Count == 0, "history_search_all_records");
            var header = BackendClient.OptionsHeader(preferences); using var options = JsonDocument.Parse(Convert.FromBase64String(header));
            Require(options.RootElement.GetProperty("vocabulary").GetArrayLength() == 120, "request_preserves_vocabulary");
            Require(GlobalHotkey.Describe(3, 0x20) == "Ctrl + Alt + Space", "shortcut_rendering");
            Require(AudioSession.PcmPeak(new byte[] { 0x00, 0x80 }) == 1d
                && AudioSession.PcmPeak(new byte[] { 0xFF, 0x7F }) == 32767d / 32768d
                && AudioSession.PcmPeak(new byte[] { 0, 0, 0, 0 }) == 0d,
                "pcm_peak_accepts_min_max_and_silence_without_overflow");
            var delivery = new DeliveryGate(); int dispatches = 0;
            Parallel.For(0, 32, _ => { if (delivery.TryBegin()) Interlocked.Increment(ref dispatches); });
            Require(dispatches == 1 && !delivery.TryBegin(), "delivery_attempt_is_exactly_once_after_callbacks_or_retry");
            var receipt = new PasteReceipt("开头\r\n结尾", "第一段。\n", 3, 0);
            Require(!receipt.Matches("开头\r\n结尾") && receipt.Matches("开头\r\n第一段。\r\n结尾"),
                "paste_receipt_requires_observed_insertion_not_dispatch_or_delay");
            Require(!receipt.Matches("开头\r\n别的文字\r\n结尾") && !receipt.Matches("第一段。\r\n开头\r\n结尾"),
                "paste_receipt_rejects_unrelated_changes_or_wrong_selection");
            Require(new PasteReceipt("abcDEFghi", "正文", 3, 3).Matches("abc正文ghi"),
                "paste_receipt_handles_exact_selected_replacement");
            Require(new PasteReceipt("ab", "bc").Matches("abcb")
                && !new PasteReceipt("ab", "bc").Matches("abxx") && !new PasteReceipt("正文", "正文", 0, 2).Matches("正文"),
                "paste_receipt_handles_shared_prefix_without_accepting_unchanged_text");
            Require(!new PasteReceipt(new string('x', PasteReceipt.MaximumCharacters), "next").CanObserve,
                "paste_receipt_observation_is_bounded");
            File.WriteAllText(Path.Combine(directory, "windows-history.json"), "broken");
            var recovered = new UserStore(directory);
            Require(recovered.History.Count == 1 && Directory.GetFiles(directory, "windows-history.json.preserved-*").Length == 1, "mirror_recovery_preserves_corrupt_source");
            File.WriteAllText(Path.Combine(directory, "windows-history.json"), "[{\"Id\":\"broken-row\",\"CreatedAt\":\"2026-11-09T00:00:00+00:00\",\"Result\":null}]");
            Require(new UserStore(directory).History[0].Result.Text == result.Text, "null_history_result_recovers_without_discarding_original");
            foreach (string malformed in new[] { "[{}]", "[{\"Id\":\"broken-row\",\"Result\":{\"raw_text\":\"raw\",\"text\":\"final\"}}]",
                "[{\"Id\":\"broken-row\",\"CreatedAt\":\"2026-11-09T00:00:00+00:00\",\"Result\":{\"raw_text\":\"raw\"}}]" })
            {
                File.WriteAllText(Path.Combine(directory, "windows-history.json"), malformed);
                Require(new UserStore(directory).History[0].Id == entry.Id, "missing_required_history_fields_recover_" + checks.Count);
            }
            recovered.Delete(entry.Id); Require(new UserStore(directory).History.Count == 0, "history_delete_persists");
            if (resultFile != null) { Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(resultFile))!); File.WriteAllText(resultFile, JsonSerializer.Serialize(new { success = true, checks, microphone_access = false, clipboard_access = false, backend_started = false }, UserStore.Json)); }
            return 0;
        }
        catch (Exception ex)
        {
            if (resultFile != null) { Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(resultFile))!); File.WriteAllText(resultFile, JsonSerializer.Serialize(new { success = false, checks, error = ex.ToString() }, UserStore.Json)); }
            return 1;
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    protected override void OnExit(ExitEventArgs e) { singleton?.Dispose(); base.OnExit(e); }
}
