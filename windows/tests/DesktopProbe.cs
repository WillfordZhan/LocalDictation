using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using LocalDictation.Windows;

namespace DesktopProbe;

// An interactive acceptance fixture, never an observer of existing editors.
// The only text read belongs to the child window this test launches.
public static class Program
{
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, Input[] inputs, int size);
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint type; public Union data; }
    [StructLayout(LayoutKind.Explicit)] private struct Union { [FieldOffset(0)] public Keyboard key; [FieldOffset(0)] public Mouse mouse; }
    [StructLayout(LayoutKind.Sequential)] private struct Keyboard { public ushort vk, scan; public uint flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] private struct Mouse { public int x, y; public uint data, flags, time; public UIntPtr extra; }
    private static Input Key(ushort key, bool up) => new() { type = 1, data = new Union { key = new Keyboard { vk = key, flags = up ? 2u : 0 } } };
    private static void Keys(params Input[] values)
    { if (SendInput((uint)values.Length, values, Marshal.SizeOf<Input>()) != values.Length) throw new InvalidOperationException("fixture input dispatch failed"); }
    private static void WriteJson(string path, object value)
    {
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(value));
        File.Move(temporary, path, true);
    }

    [STAThread]
    public static void Main(string[] args)
    {
        string directory = Path.GetFullPath(args[1]); Directory.CreateDirectory(directory);
        var app = new System.Windows.Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        if (args[0] == "--target") { Target(app, directory); app.Run(); return; }
        var owner = new Window { Title = "LocalDictation acceptance runner", Width = 360, Height = 120, ShowInTaskbar = false };
        owner.Loaded += async (_, _) => await Run(app, owner, directory);
        app.Run(owner);
    }

    private static void Target(System.Windows.Application app, string directory)
    {
        var first = new TextBox { Name = "First", Height = 100, AcceptsReturn = true, Margin = new Thickness(12), FontSize = 18 };
        var second = new TextBox { Name = "Second", Height = 60, Margin = new Thickness(12), FontSize = 18 };
        var password = new PasswordBox { Height = 30, Margin = new Thickness(12) };
        var panel = new StackPanel(); panel.Children.Add(new TextBlock { Text = "LocalDictation 专用验收输入框", Margin = new Thickness(12) });
        panel.Children.Add(first); panel.Children.Add(second); panel.Children.Add(password);
        var window = new Window { Title = "LocalDictation isolated paste fixture", Width = 680, Height = 370, Content = panel };
        void Save() => WriteJson(Path.Combine(directory, "fields.json"), new { first = first.Text, second = second.Text });
        first.TextChanged += (_, _) => Save(); second.TextChanged += (_, _) => Save();
        window.SourceInitialized += (_, _) => HwndSource.FromHwnd(new WindowInteropHelper(window).Handle).AddHook(
            (IntPtr hwnd, int message, IntPtr wp, IntPtr lp, ref bool handled) =>
            {
                if (message == 0x8001) { second.Focus(); handled = true; }
                if (message == 0x8002) { password.Focus(); handled = true; }
                if (message == 0x8003) { first.Focus(); first.CaretIndex = first.Text.Length; handled = true; }
                return IntPtr.Zero;
            });
        window.Loaded += (_, _) => { first.Focus(); Save(); WriteJson(Path.Combine(directory, "target.json"), new { pid = Environment.ProcessId, hwnd = new WindowInteropHelper(window).Handle.ToInt64() }); };
        window.Closed += (_, _) => app.Shutdown(); window.Show();
    }

    private static async Task Run(System.Windows.Application app, Window owner, string directory)
    {
        var checks = new List<string>(); Process? child = null; System.Windows.IDataObject? clipboard = null;
        uint ownClipboard = 0; int exit = 1; DictationHud? hud = null;
        void Require(bool condition, string label) { if (!condition) throw new InvalidOperationException(label); checks.Add(label); }
        async Task WaitFor(Func<bool> test)
        { for (int i = 0; i < 80; i++) { try { if (test()) return; } catch (IOException) { } catch (JsonException) { } await Task.Delay(100); } throw new TimeoutException("desktop fixture condition"); }
        string Field(string name)
        { using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "fields.json"))); return json.RootElement.GetProperty(name).GetString()!.Replace("\r\n", "\n"); }
        try
        {
            clipboard = System.Windows.Clipboard.GetDataObject();
            var info = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
            info.ArgumentList.Add("--target"); info.ArgumentList.Add(directory); child = Process.Start(info)!;
            await WaitFor(() => File.Exists(Path.Combine(directory, "target.json")));
            using var target = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "target.json")));
            Require(target.RootElement.GetProperty("pid").GetInt32() == child.Id, "target_is_owned_test_process");
            var hwnd = new IntPtr(target.RootElement.GetProperty("hwnd").GetInt64());
            SetForegroundWindow(hwnd); await WaitFor(() => NativeInput.GetForegroundWindow() == hwnd);
            Require(NativeInput.CaptureTarget() == hwnd, "capture_external_editor");
            int pressed = 0; using var hotkey = new GlobalHotkey(new WindowInteropHelper(owner).Handle);
            hotkey.Pressed += () => pressed++;
            Require(hotkey.Set(3, 0x77), "register_ctrl_alt_f8");
            Keys(Key(0x11, false), Key(0x12, false), Key(0x77, false), Key(0x77, true), Key(0x12, true), Key(0x11, true));
            await WaitFor(() => pressed == 1); Require(true, "global_hotkey_while_other_window_focused");
            hud = new DictationHud(); hud.Position(0, 1); hud.Show(); hud.SetLevel(.7); await Task.Delay(250);
            Require(NativeInput.GetForegroundWindow() == hwnd, "recording_hud_does_not_take_focus");
            hud.Processing(); await Task.Delay(200); Require(NativeInput.GetForegroundWindow() == hwnd, "processing_hud_does_not_take_focus");
            hud.Close(); hud = null;
            var result = await NativeInput.PasteAsync(hwnd, "Windows 本地口述：第一段。\n"); ownClipboard = GetClipboardSequenceNumber();
            Require(result == DeliveryOutcome.PasteDispatched, "first_paste_dispatched");
            // Submit back-to-back as the production queue does: PasteAsync must
            // settle the first delivery before the clipboard is overwritten.
            result = await NativeInput.PasteAsync(hwnd, "第二段 API 3.28。"); ownClipboard = GetClipboardSequenceNumber();
            Require(result == DeliveryOutcome.PasteDispatched, "second_paste_dispatched");
            await WaitFor(() => Field("first") == "Windows 本地口述：第一段。\n第二段 API 3.28。");
            Require(true, "both_segments_inserted_exactly_once");
            Keys(Key(0x11, false));
            var pending = NativeInput.PasteAsync(hwnd, "不得误贴到另一个输入框");
            await Task.Delay(150); SendMessage(hwnd, 0x8001, IntPtr.Zero, IntPtr.Zero); await Task.Delay(100); Keys(Key(0x11, true));
            result = await pending; ownClipboard = GetClipboardSequenceNumber();
            Require(result == DeliveryOutcome.Copied && Field("second") == "", "same_window_focus_change_falls_back");
            SendMessage(hwnd, 0x8002, IntPtr.Zero, IntPtr.Zero); await Task.Delay(100);
            result = await NativeInput.PasteAsync(hwnd, "不得填入密码框"); ownClipboard = GetClipboardSequenceNumber();
            Require(result == DeliveryOutcome.Copied, "password_field_never_receives_paste");
            exit = 0;
            File.WriteAllText(Path.Combine(directory, "desktop-result.json"), JsonSerializer.Serialize(new { success = true, checks }, UserStore.Json));
        }
        catch (Exception ex)
        { File.WriteAllText(Path.Combine(directory, "desktop-result.json"), JsonSerializer.Serialize(new { success = false, checks, error = ex.ToString() }, UserStore.Json)); }
        finally
        {
            try { Keys(Key(0x11, true), Key(0x12, true)); } catch { }
            hud?.Close();
            // Restore only while the clipboard still belongs to this fixture.
            // An intervening user copy always wins over test cleanup.
            try
            {
                if (ownClipboard != 0 && GetClipboardSequenceNumber() == ownClipboard)
                { if (clipboard != null) System.Windows.Clipboard.SetDataObject(clipboard, true); else System.Windows.Clipboard.Clear(); }
            }
            catch (ExternalException) { }
            try { if (child is { HasExited: false }) { child.CloseMainWindow(); await Task.Delay(200); if (!child.HasExited) child.Kill(); } }
            catch (InvalidOperationException) { }
            child?.Dispose(); app.Shutdown(exit);
        }
    }
}
