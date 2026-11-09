using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace LocalDictation.Windows;

public partial class MainWindow : Window
{
    private readonly UserStore store;
    private readonly BackendClient backend;
    private readonly bool smoke;
    private GlobalHotkey? hotkey;
    private System.Windows.Forms.NotifyIcon? tray;
    private readonly DispatcherTimer healthTimer = new() { Interval = TimeSpan.FromSeconds(5) };
    private readonly List<Job> jobs = [];
    private AudioSession? recording;
    private bool starting, configuring, refreshing, draining, quitting;
    private int historyPage;
    private string page = "home";
    private JsonElement? promptCatalog;
    private sealed class Job
    {
        public required AudioSession Session;
        public required DictationHud Hud;
        public DictationResult? Result;
        public string? Error;
        public bool Complete, Cancelled, Saved, Finishing;
        public readonly DeliveryGate Delivery = new();
    }
    private sealed class PromptRow
    { public required string Id { get; init; } public required string Label { get; init; } public JsonElement Value { get; init; } }

    public MainWindow(UserStore store, bool smoke = false)
    {
        InitializeComponent(); this.store = store; this.smoke = smoke;
        backend = new BackendClient(store.DirectoryPath);
        CleanupCheck.IsChecked = store.Preferences.Cleanup;
        RefreshShortcut(); RefreshHistory(); RefreshVocabulary(); RefreshStatistics(); SelectPage("home");
        Closing += OnClosing;
        Loaded += async (_, _) =>
        {
            if (smoke) { ServiceBadge.Text = "界面验证"; RecordButton.IsEnabled = false; return; }
            hotkey = new GlobalHotkey(new WindowInteropHelper(this).Handle);
            hotkey.Pressed += () => { if (!ShortcutBox.IsKeyboardFocusWithin) _ = ToggleRecordingAsync(); };
            if (!hotkey.Set(store.Preferences.HotkeyModifiers, store.Preferences.HotkeyKey)) Status("快捷键被其他应用占用，请在设置中更换。");
            CreateTray(); healthTimer.Tick += async (_, _) => await RefreshHealthAsync(); healthTimer.Start();
            await RunSetupAsync(false);
        };
    }

    private void CreateTray()
    {
        tray = new System.Windows.Forms.NotifyIcon { Icon = System.Drawing.SystemIcons.Application, Text = "本地口述", Visible = true };
        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add("打开本地口述", null, (_, _) => Dispatcher.Invoke(BringForward));
        menu.Items.Add("开始 / 结束口述", null, (_, _) => Dispatcher.Invoke(() => _ = ToggleRecordingAsync()));
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Dispatcher.Invoke(() => _ = QuitAsync()));
        tray.ContextMenuStrip = menu; tray.DoubleClick += (_, _) => Dispatcher.Invoke(BringForward);
    }
    private void BringForward() { Show(); WindowState = WindowState.Normal; Activate(); }
    private void OnClosing(object? sender, CancelEventArgs e)
    { if (!quitting) { e.Cancel = true; Hide(); } }
    private void Status(string text) => StatusMessage.Text = text;
    private void Navigate(object sender, RoutedEventArgs e) => SelectPage((string)((Button)sender).Tag);
    public void SelectPage(string target)
    {
        page = target;
        foreach (var (name, control) in new (string, FrameworkElement)[] { ("home", HomePage), ("history", HistoryPage), ("dictionary", DictionaryPage), ("prompts", PromptsPage), ("settings", SettingsPage) })
            control.Visibility = name == target ? Visibility.Visible : Visibility.Collapsed;
        foreach (var button in new[] { HomeNav, HistoryNav, DictionaryNav, PromptsNav, SettingsNav })
            button.Background = (string)button.Tag == target ? new SolidColorBrush(Color.FromRgb(229, 230, 233)) : Brushes.Transparent;
        if (target == "history") RefreshHistory();
        if (target == "prompts" && !smoke) _ = LoadPromptsAsync();
    }

    private void RefreshStatistics()
    {
        WordCount.Text = store.History.Sum(item => item.Result.Text.EnumerateRunes().Count()).ToString("N0");
        SessionCount.Text = store.History.Count.ToString("N0");
        MinutesCount.Text = Math.Round(store.History.Sum(item => item.Result.AudioSeconds) / 60).ToString("N0") + " 分钟";
    }
    private void RefreshShortcut()
    { ShortcutHeadline.Text = ShortcutBox.Text = GlobalHotkey.Describe(store.Preferences.HotkeyModifiers, store.Preferences.HotkeyKey); }
    private void CaptureShortcut(object sender, KeyEventArgs e)
    {
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
        uint modifiers = 0;
        if ((Keyboard.Modifiers & ModifierKeys.Alt) != 0) modifiers |= 1;
        if ((Keyboard.Modifiers & ModifierKeys.Control) != 0) modifiers |= 2;
        if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0) modifiers |= 4;
        if ((Keyboard.Modifiers & ModifierKeys.Windows) != 0) modifiers |= 8;
        if ((modifiers & 3) == 0) { Status("请使用包含 Ctrl 或 Alt 的组合键。"); return; }
        uint code = (uint)KeyInterop.VirtualKeyFromKey(key);
        if (!smoke && hotkey?.Set(modifiers, code) != true) { Status("这个快捷键已被占用，请换一个组合。"); return; }
        var previous = store.CopyPreferences();
        try { var next = store.CopyPreferences(); next.HotkeyModifiers = modifiers; next.HotkeyKey = code; store.SavePreferences(next); RefreshShortcut(); Status("快捷键已更新。"); }
        catch (Exception ex) { hotkey?.Set(previous.HotkeyModifiers, previous.HotkeyKey); Status(ex.Message); }
    }
    private void CleanupChanged(object sender, RoutedEventArgs e)
    {
        if (store == null) return;
        try { var next = store.CopyPreferences(); next.Cleanup = CleanupCheck.IsChecked == true; store.SavePreferences(next); }
        catch (Exception ex) { Status(ex.Message); }
    }
    private async void ToggleRecordingClick(object sender, RoutedEventArgs e) => await ToggleRecordingAsync();

    public async Task ToggleRecordingAsync()
    {
        if (smoke || starting || configuring || quitting) return;
        if (recording != null)
        {
            var current = recording; recording = null; RecordButton.Content = "开始口述"; RecordingStatus.Text = "正在整理，可以继续口述";
            var job = jobs.First(item => item.Session == current); job.Hud.Processing(); _ = CompleteJobAsync(job); return;
        }
        if (jobs.Count >= 8) { Status("待处理的口述较多，请稍后再录。"); return; }
        var target = NativeInput.CaptureTarget(); starting = true;
        try
        {
            var health = await backend.HealthAsync();
            if (health == null || !health.Value.GetProperty("ready").GetBoolean()) throw new InvalidOperationException("请先在首页完成本机模型配置。");
            var session = new AudioSession(backend, target); var hud = new DictationHud();
            var job = new Job { Session = session, Hud = hud };
            session.Level += value => Dispatcher.InvokeAsync(() => { if (!job.Complete) hud.SetLevel(value); });
            session.LimitReached += () => Dispatcher.InvokeAsync(() => { if (recording == session) _ = ToggleRecordingAsync(); });
            session.Failure += text => Dispatcher.InvokeAsync(() =>
            { Status(text); if (recording == session) { recording = null; RecordButton.Content = "开始口述"; _ = CompleteJobAsync(job); } });
            hud.CancelRequested += () => _ = CancelJobAsync(job);
            try { await session.StartAsync(store.CopyPreferences()); }
            catch { session.Dispose(); hud.Close(); throw; }
            jobs.Add(job); recording = session; hud.Show(); PositionHuds();
            RecordButton.Content = "结束口述"; RecordingStatus.Text = "正在聆听"; Status("结束后会填入当前输入框。");
        }
        catch (Exception ex) { Status(ex.Message); }
        finally { starting = false; }
    }

    private async Task CompleteJobAsync(Job job)
    {
        if (job.Complete || job.Finishing) return;
        job.Finishing = true; job.Hud.Processing();
        try { job.Result = await job.Session.FinishAsync(); }
        catch (Exception ex) { job.Error = ex is OperationCanceledException ? "已取消" : ex.Message; await job.Session.CancelAsync(); }
        finally { job.Complete = true; }
        await DrainDeliveriesAsync();
    }
    private async Task CancelJobAsync(Job job)
    {
        if (job.Result != null) { await DrainDeliveriesAsync(); return; }
        job.Cancelled = true;
        if (recording == job.Session) { recording = null; RecordButton.Content = "开始口述"; }
        await job.Session.CancelAsync(); job.Complete = true; job.Error = "已取消";
        await DrainDeliveriesAsync();
    }
    private async Task DrainDeliveriesAsync()
    {
        if (draining) return; draining = true;
        try
        {
            // The recording slot is independent of delivery. Results are saved
            // and pasted once in start order even when finish responses race.
            while (jobs.Count > 0 && jobs[0].Complete)
            {
                var job = jobs[0];
                if (job.Result != null && !job.Cancelled)
                {
                    if (!job.Saved)
                    {
                        try { store.Add(new HistoryEntry { Id = job.Session.Id, CreatedAt = job.Session.Started, Result = job.Result }); job.Saved = true; }
                        catch (Exception ex) { job.Hud.Message("保存失败，请检查存储"); Status(ex.Message + " · 结果暂存于内存，请不要退出。"); return; }
                    }
                    RefreshHistory(); RefreshStatistics();
                    if (!string.IsNullOrWhiteSpace(job.Result.Text) && job.Delivery.TryBegin())
                    {
                        var delivery = await NativeInput.PasteAsync(job.Session.Target, job.Result.Text);
                        bool pasted = delivery == DeliveryOutcome.PasteDispatched;
                        if (!pasted) { job.Hud.Message(delivery == DeliveryOutcome.Copied ? "已复制 · 按 Ctrl + V 粘贴" : "结果已保存在历史记录"); await Task.Delay(3500); }
                        Status(job.Result.Warning ?? (pasted ? "文字已填入。" : "结果已保存在历史记录。"));
                    }
                    else if (string.IsNullOrWhiteSpace(job.Result.Text)) Status(job.Result.Warning ?? "没有识别到语音。");
                }
                else if (!job.Cancelled) { job.Hud.Message("处理未完成"); Status(job.Error ?? "处理未完成，请重试。"); await Task.Delay(3000); }
                jobs.RemoveAt(0); job.Hud.Close(); job.Session.Dispose(); PositionHuds();
            }
            if (recording == null) RecordingStatus.Text = jobs.Count == 0 ? "准备就绪" : "正在整理，可以继续口述";
        }
        catch (Exception ex) { Status(ex.Message); }
        finally { draining = false; }
    }
    private void PositionHuds() { for (int i = 0; i < jobs.Count; i++) jobs[i].Hud.Position(i, jobs.Count); }

    private async Task RefreshHealthAsync()
    {
        if (refreshing || configuring || smoke || quitting) return; refreshing = true;
        try
        {
            var health = await backend.HealthAsync();
            bool ready = health?.GetProperty("ready").GetBoolean() == true;
            bool loading = health?.GetProperty("status").GetString() == "loading";
            ServiceBadge.Text = ready ? "● 本机服务就绪" : loading ? "◌ 正在加载本机模型" : "○ 本机服务未就绪";
            if (health != null && health.Value.TryGetProperty("models", out var models))
                ModelSummary.Text = $"识别 · {models.GetProperty("asr").GetString()}\n润色 · {models.GetProperty("cleanup").GetString()}";
            RecordButton.IsEnabled = ready || recording != null;
            if (ready && health?.GetProperty("cleanup_ready").GetBoolean() != true) Status("语音识别可用，润色模型未就绪，将保留原始转写。");
        }
        catch (Exception ex) { ServiceBadge.Text = "服务暂不可用"; Status(ex.Message); }
        finally { refreshing = false; }
    }
    private async void CheckSetupClick(object sender, RoutedEventArgs e) { await DrainDeliveriesAsync(); await RunSetupAsync(false); }
    private async void DownloadClick(object sender, RoutedEventArgs e) => await RunSetupAsync(true);
    private async Task RunSetupAsync(bool download)
    {
        if (smoke || configuring) return;
        if (jobs.Count != 0 || starting) { Status("请先完成正在处理的口述，再配置模型。"); return; }
        configuring = true; RuntimeButton.IsEnabled = CheckButton.IsEnabled = DownloadButton.IsEnabled = false;
        SetupProgress.IsIndeterminate = true; SetupProgress.Value = 0; SetupProgress.Visibility = Visibility.Visible;
        try
        {
            var report = await backend.CheckSetupAsync(download,
                message => Dispatcher.InvokeAsync(() => SetupDetails.Text = message),
                fraction => Dispatcher.InvokeAsync(() => { SetupProgress.IsIndeterminate = false; SetupProgress.Value = fraction * 100; }));
            var ready = report.GetProperty("ready").GetBoolean();
            bool runtimeReady = !report.TryGetProperty("runtime_ready", out var runtime) || runtime.GetBoolean();
            bool modelsReady = report.TryGetProperty("models_ready", out var models) ? models.GetBoolean() : ready;
            RuntimeButton.Visibility = runtimeReady ? Visibility.Collapsed : Visibility.Visible;
            SetupDetails.Text = report.TryGetProperty("message", out var text) ? text.GetString() : ready ? "模型已就绪。" : "需要下载模型。";
            bool hasBytes = report.TryGetProperty("required_download_bytes", out var bytes) || report.TryGetProperty("required_bytes", out bytes) || report.TryGetProperty("total_bytes", out bytes);
            if (hasBytes && bytes.TryGetDouble(out var size) && size > 0)
                DownloadButton.Content = $"一键下载并配置 · {size / 1_000_000_000:F1} GB";
            DownloadButton.Visibility = modelsReady ? Visibility.Collapsed : Visibility.Visible;
            if (ready) { if (download) await backend.StopOwnedAsync(); await backend.EnsureStartedAsync(); }
            else ServiceBadge.Text = runtimeReady ? "等待下载模型" : "等待安装运行库";
        }
        catch (Exception ex) { SetupDetails.Text = ex.Message; Status("配置未完成，可以检查网络后重试。"); }
        finally { configuring = false; RuntimeButton.IsEnabled = CheckButton.IsEnabled = DownloadButton.IsEnabled = true; SetupProgress.Visibility = Visibility.Collapsed; await RefreshHealthAsync(); }
    }

    private async void InstallRuntimeClick(object sender, RoutedEventArgs e)
    {
        if (configuring || jobs.Count > 0 || starting || smoke) return;
        string installer = Path.Combine(AppContext.BaseDirectory, "runtime", "vc_redist.x64.exe");
        if (!File.Exists(installer)) { Status("安装包缺少 Windows 运行库安装程序，请重新下载完整安装包。"); return; }
        configuring = true; RuntimeButton.IsEnabled = DownloadButton.IsEnabled = CheckButton.IsEnabled = false;
        bool complete = false;
        try
        {
            SetupDetails.Text = "请在 Windows 提示中确认安装运行库。";
            using var process = Process.Start(new ProcessStartInfo(installer, "/install /passive /norestart") { UseShellExecute = true, Verb = "runas" })
                ?? throw new InvalidOperationException("安装程序未能启动。");
            await process.WaitForExitAsync();
            complete = process.ExitCode is 0 or 3010;
            if (!complete) throw new InvalidOperationException($"运行库安装未完成（{process.ExitCode}），请检查安装程序提示。");
            SetupDetails.Text = process.ExitCode == 3010 ? "运行库已安装，Windows 建议稍后重启。" : "运行库已安装。";
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223) { Status("已取消安装，需要时可再次点击安装运行库。"); }
        catch (Exception ex) { Status(ex.Message); }
        finally { configuring = false; RuntimeButton.IsEnabled = DownloadButton.IsEnabled = CheckButton.IsEnabled = true; }
        if (complete) await RunSetupAsync(false);
    }

    private void RefreshHistory()
    {
        string? selected = (HistoryList.SelectedItem as HistoryEntry)?.Id;
        var matches = store.Search(HistorySearch.Text ?? "");
        int totalPages = Math.Max(1, (matches.Count + 19) / 20); historyPage = Math.Clamp(historyPage, 0, totalPages - 1);
        var rows = matches.Skip(historyPage * 20).Take(20).ToList(); HistoryList.ItemsSource = rows;
        HistoryList.SelectedItem = rows.FirstOrDefault(row => row.Id == selected) ?? rows.FirstOrDefault();
        Pagination.Visibility = totalPages > 1 ? Visibility.Visible : Visibility.Collapsed; PageLabel.Text = $"{historyPage + 1} / {totalPages}";
        if (rows.Count == 0) { RawText.Text = FinalText.Text = ""; HistoryMetadata.Text = "尚无记录"; }
    }
    private void HistorySearchChanged(object sender, TextChangedEventArgs e) { if (store == null) return; historyPage = 0; RefreshHistory(); }
    private void PreviousPage(object sender, RoutedEventArgs e) { historyPage--; RefreshHistory(); }
    private void NextPage(object sender, RoutedEventArgs e) { historyPage++; RefreshHistory(); }
    private void HistorySelected(object sender, SelectionChangedEventArgs e)
    {
        if (HistoryList.SelectedItem is not HistoryEntry entry) return;
        RawText.Text = entry.Result.RawText; FinalText.Text = entry.Result.Text;
        string model = "未润色";
        if (entry.Result.CleanupProfile is JsonElement profile && profile.TryGetProperty("model_id", out var id)) model = id.GetString() ?? "";
        HistoryMetadata.Text = $"{entry.CreatedAt.LocalDateTime:yyyy-MM-dd HH:mm} · 识别 {entry.Result.AsrSeconds:F1}s · 整理 {entry.Result.CleanupSeconds:F1}s\n{entry.Result.AsrModel} · {model}";
    }
    private async void CopyHistory(object sender, RoutedEventArgs e)
    { if (HistoryList.SelectedItem is HistoryEntry entry) Status(await NativeInput.CopyAsync(entry.Result.Text) ? "已复制。" : "剪贴板被占用，请稍后重试。"); }
    private void DeleteHistory(object sender, RoutedEventArgs e)
    {
        if (HistoryList.SelectedItem is not HistoryEntry entry) return;
        if (MessageBox.Show(this, "删除这条口述记录？", "本地口述", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        try { store.Delete(entry.Id); RefreshHistory(); RefreshStatistics(); } catch (Exception ex) { Status(ex.Message); }
    }
    private void RefreshVocabulary() { VocabularyList.ItemsSource = store.Preferences.Vocabulary.ToList(); VocabularyCount.Text = $"手动添加 · {store.Preferences.Vocabulary.Count} 个词"; }
    private void AddVocabulary(object sender, RoutedEventArgs e)
    {
        string word = VocabularyInput.Text.Trim(); if (word.Length == 0) return;
        if (word.EnumerateRunes().Count() > 64) { Status("单个术语请控制在 64 个字符以内。"); return; }
        try
        {
            var next = store.CopyPreferences(); if (!next.Vocabulary.Contains(word)) next.Vocabulary.Add(word);
            if (BackendClient.OptionsHeader(next).Length > 40 * 1024) throw new InvalidOperationException("词典已达到本地请求容量，请移除暂时不用的术语。");
            store.SavePreferences(next); VocabularyInput.Clear(); RefreshVocabulary(); Status("将从下一次录音生效。");
        }
        catch (Exception ex) { Status(ex.Message); }
    }
    private void VocabularyKeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) { AddVocabulary(sender, e); e.Handled = true; } }
    private void DeleteVocabulary(object sender, RoutedEventArgs e)
    { try { var next = store.CopyPreferences(); next.Vocabulary.Remove((string)((Button)sender).Tag); store.SavePreferences(next); RefreshVocabulary(); } catch (Exception ex) { Status(ex.Message); } }

    private async Task LoadPromptsAsync(string? select = null)
    {
        try
        {
            promptCatalog = await backend.RequestAsync("GET", "/cleanup/prompts"); var catalog = promptCatalog.Value;
            var active = catalog.GetProperty("active_version_id").GetString();
            var rows = catalog.GetProperty("versions").EnumerateArray().Select(v => new PromptRow { Id = v.GetProperty("id").GetString()!,
                Label = (v.GetProperty("id").GetString() == active ? "● " : "") + v.GetProperty("name").GetString(), Value = v.Clone() }).ToList();
            PromptList.ItemsSource = rows; PromptList.SelectedItem = rows.FirstOrDefault(row => row.Id == (select ?? active)) ?? rows.FirstOrDefault();
            CurrentModel.Text = "当前模型\n" + catalog.GetProperty("current_model").GetProperty("id").GetString();
        }
        catch (Exception ex) { PromptStatus.Text = ex.Message; }
    }
    private void PromptSelected(object sender, SelectionChangedEventArgs e)
    {
        if (PromptList.SelectedItem is not PromptRow row) return; var v = row.Value;
        PromptName.Text = v.GetProperty("name").GetString(); PromptSystem.Text = v.GetProperty("system_prompt").GetString();
        PromptPrefix.Text = v.GetProperty("user_prefix").GetString(); PromptExamples.Text = JsonSerializer.Serialize(v.GetProperty("examples"), UserStore.Json);
        PromptStatus.Text = "修改后保存为新版本，旧版本会保留。";
    }
    private async void SavePrompt(object sender, RoutedEventArgs e)
    {
        try
        {
            using var examples = JsonDocument.Parse(PromptExamples.Text);
            var body = new { name = PromptName.Text, note = "Windows 编辑", system_prompt = PromptSystem.Text,
                user_prefix = PromptPrefix.Text, examples = examples.RootElement.Clone() };
            var previous = promptCatalog?.GetProperty("versions").EnumerateArray().Select(v => v.GetProperty("id").GetString()).ToHashSet() ?? [];
            var catalog = await backend.RequestAsync("POST", "/cleanup/prompts", body);
            var added = catalog.GetProperty("versions").EnumerateArray().First(v => !previous.Contains(v.GetProperty("id").GetString())).GetProperty("id").GetString();
            await LoadPromptsAsync(added); PromptStatus.Text = "新版本已保存，可点击启用。";
        }
        catch (Exception ex) { PromptStatus.Text = ex.Message; }
    }
    private async void ActivatePrompt(object sender, RoutedEventArgs e)
    {
        if (PromptList.SelectedItem is not PromptRow row) return;
        try { await backend.RequestAsync("POST", "/cleanup/prompts/activate", new { version_id = row.Id }); await LoadPromptsAsync(row.Id); PromptStatus.Text = "已启用，将从下一次录音生效。"; }
        catch (Exception ex) { PromptStatus.Text = ex.Message; }
    }
    private void OpenDataFolder(object sender, RoutedEventArgs e) => Process.Start(new ProcessStartInfo("explorer.exe", store.DirectoryPath) { UseShellExecute = true });
    private async void QuitClick(object sender, RoutedEventArgs e) => await QuitAsync();
    public async Task QuitAsync()
    {
        if (jobs.Count != 0 || starting || configuring) { BringForward(); Status("请先完成当前录音、整理或配置，再退出。"); return; }
        quitting = true; healthTimer.Stop(); hotkey?.Dispose(); tray?.Dispose();
        await backend.StopOwnedAsync(); backend.Dispose(); Close(); System.Windows.Application.Current.Shutdown();
    }
    public void CloseSmoke() { quitting = true; backend.Dispose(); Close(); System.Windows.Application.Current.Shutdown(); }
}
