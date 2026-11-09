using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Windows.Input;
using System.Windows.Interop;

namespace LocalDictation.Windows;

public sealed class GlobalHotkey : IDisposable
{
    private readonly HwndSource source;
    private uint modifiers, key;
    private bool registered;
    public event Action? Pressed;
    public GlobalHotkey(IntPtr handle)
    { source = HwndSource.FromHwnd(handle); source.AddHook(Hook); }
    public bool Set(uint newModifiers, uint newKey)
    {
        if (registered) UnregisterHotKey(source.Handle, 601);
        bool ok = RegisterHotKey(source.Handle, 601, newModifiers | 0x4000, newKey);
        if (ok) { modifiers = newModifiers; key = newKey; registered = true; }
        else registered = key != 0 && RegisterHotKey(source.Handle, 601, modifiers | 0x4000, key);
        return ok;
    }
    private IntPtr Hook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    { if (message == 0x0312 && wParam.ToInt32() == 601) { handled = true; Pressed?.Invoke(); } return IntPtr.Zero; }
    public static string Describe(uint modifiers, uint key)
    {
        var parts = new List<string>();
        if ((modifiers & 2) != 0) parts.Add("Ctrl");
        if ((modifiers & 1) != 0) parts.Add("Alt");
        if ((modifiers & 4) != 0) parts.Add("Shift");
        if ((modifiers & 8) != 0) parts.Add("Win");
        parts.Add(key == 0x20 ? "Space" : KeyInterop.KeyFromVirtualKey((int)key).ToString());
        return string.Join(" + ", parts);
    }
    public void Dispose() { if (registered) UnregisterHotKey(source.Handle, 601); source.RemoveHook(Hook); }
    [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hwnd, int id);
}

public enum DeliveryOutcome { PasteDispatched, Copied, HistoryOnly }

public static class NativeInput
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [StructLayout(LayoutKind.Sequential)] private struct INPUT { public uint type; public InputUnion data; }
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion
    { [FieldOffset(0)] public KEYBDINPUT key; [FieldOffset(0)] public MOUSEINPUT mouse; }
    [StructLayout(LayoutKind.Sequential)] private struct KEYBDINPUT
    { public ushort vk, scan; public uint flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] private struct MOUSEINPUT
    { public int x, y; public uint mouseData, flags, time; public UIntPtr extra; }

    public static bool IsOwnWindow(IntPtr hwnd)
    { GetWindowThreadProcessId(hwnd, out uint process); return process == Environment.ProcessId; }
    public static IntPtr CaptureTarget()
    { var target = GetForegroundWindow(); return IsOwnWindow(target) ? IntPtr.Zero : target; }
    public static async Task<bool> CopyAsync(string text)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try { System.Windows.Clipboard.SetText(text); return true; }
            catch (ExternalException) { await Task.Delay(70); }
        }
        return false;
    }

    private sealed record FocusSnapshot(AutomationElement Element, int[] RuntimeId, TextPatternRange[]? Selection);
    private static FocusSnapshot? EditableFocus()
    {
        try
        {
            var focus = AutomationElement.FocusedElement;
            if (focus == null || focus.Current.ProcessId == Environment.ProcessId || focus.Current.IsPassword
                || !focus.Current.IsEnabled || !focus.Current.HasKeyboardFocus) return null;
            TextPattern? textPattern = focus.TryGetCurrentPattern(TextPattern.Pattern, out var text) ? (TextPattern)text : null;
            bool writableValue = focus.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && !((ValuePattern)value).Current.IsReadOnly;
            if (!writableValue && !((focus.Current.ControlType == ControlType.Edit || focus.Current.ControlType == ControlType.Document) && textPattern != null)) return null;
            if (textPattern?.DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is bool readOnly && readOnly) return null;
            var selection = textPattern?.GetSelection().Select(range => range.Clone()).ToArray();
            return new FocusSnapshot(focus, focus.GetRuntimeId(), selection);
        }
        catch (Exception ex) when (ex is ElementNotAvailableException or InvalidOperationException or COMException) { return null; }
    }

    private static bool SameFocus(FocusSnapshot original)
    {
        try
        {
            var current = EditableFocus();
            if (current == null || !original.RuntimeId.SequenceEqual(current.RuntimeId)) return false;
            if (original.Selection == null) return true;
            if (current.Selection == null || original.Selection.Length != current.Selection.Length) return false;
            for (int i = 0; i < original.Selection.Length; i++)
                if (original.Selection[i].CompareEndpoints(TextPatternRangeEndpoint.Start, current.Selection[i], TextPatternRangeEndpoint.Start) != 0
                    || original.Selection[i].CompareEndpoints(TextPatternRangeEndpoint.End, current.Selection[i], TextPatternRangeEndpoint.End) != 0) return false;
            return true;
        }
        catch (Exception ex) when (ex is ElementNotAvailableException or InvalidOperationException or COMException) { return false; }
    }

    public static async Task<DeliveryOutcome> PasteAsync(IntPtr originalTarget, string text)
    {
        if (!await CopyAsync(text)) return DeliveryOutcome.HistoryOnly;
        uint clipboardSequence = GetClipboardSequenceNumber();
        DeliveryOutcome Fallback() => GetClipboardSequenceNumber() == clipboardSequence ? DeliveryOutcome.Copied : DeliveryOutcome.HistoryOnly;
        var foreground = GetForegroundWindow();
        // Prefer the current external editor. Restore the original only when
        // our own window has focus; never steal focus from another application.
        if (IsOwnWindow(foreground) && originalTarget != IntPtr.Zero && IsWindow(originalTarget))
        { SetForegroundWindow(originalTarget); await Task.Delay(100); foreground = GetForegroundWindow(); }
        var focus = EditableFocus();
        if (foreground == IntPtr.Zero || IsOwnWindow(foreground) || focus == null) return Fallback();
        for (int attempt = 0; attempt < 20; attempt++)
        {
            if (!new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0)) break;
            await Task.Delay(50);
        }
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0)
            || GetForegroundWindow() != foreground || !SameFocus(focus)) return Fallback();
        if (GetClipboardSequenceNumber() != clipboardSequence) return DeliveryOutcome.HistoryOnly;
        // Exactly one Ctrl+V dispatch. Never retry a paste whose effect cannot
        // be established: duplicate insertion is worse than clipboard fallback.
        INPUT Key(ushort vk, bool up) => new() { type = 1, data = new InputUnion { key = new KEYBDINPUT { vk = vk, flags = up ? 2u : 0u } } };
        INPUT[] events = [Key(0x11, false), Key(0x56, false), Key(0x56, true), Key(0x11, true)];
        if (SendInput((uint)events.Length, events, Marshal.SizeOf<INPUT>()) == events.Length) return DeliveryOutcome.PasteDispatched;
        INPUT[] releases = [Key(0x56, true), Key(0x11, true)];
        SendInput((uint)releases.Length, releases, Marshal.SizeOf<INPUT>());
        return Fallback();
    }
}
