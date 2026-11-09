using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace LocalDictation.Windows;

public sealed class DictationHud : Window
{
    private readonly TextBlock label;
    private readonly TextBlock number;
    private readonly Waveform waveform;
    private readonly DispatcherTimer timer;
    private readonly DateTimeOffset created = DateTimeOffset.Now;
    public event Action? CancelRequested;
    public DictationHud()
    {
        Width = 244; Height = 60; WindowStyle = WindowStyle.None; AllowsTransparency = true;
        Background = Brushes.Transparent; ShowInTaskbar = false; ShowActivated = false; Topmost = true; ResizeMode = ResizeMode.NoResize;
        var row = new Grid { Margin = new Thickness(5) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        number = new TextBlock { Foreground = new SolidColorBrush(Color.FromRgb(100, 104, 112)), FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        row.Children.Add(number);
        var body = new Border { Background = new SolidColorBrush(Color.FromRgb(35, 37, 42)), CornerRadius = new CornerRadius(25), Padding = new Thickness(15, 0, 9, 0) };
        Grid.SetColumn(body, 1); row.Children.Add(body);
        var content = new Grid(); content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(25) }); body.Child = content;
        var center = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        waveform = new Waveform { Height = 19, Width = 124, HorizontalAlignment = HorizontalAlignment.Left };
        label = new TextBlock { Text = "正在录音", FontSize = 10, Foreground = new SolidColorBrush(Color.FromRgb(193, 196, 203)), Margin = new Thickness(0, 2, 0, 0) };
        center.Children.Add(waveform); center.Children.Add(label); content.Children.Add(center);
        var cancel = new Button { Content = "×", Foreground = Brushes.White, Background = Brushes.Transparent,
            Padding = new Thickness(2), Width = 22, Height = 25, FontSize = 19, ToolTip = "取消这一段" };
        cancel.Click += (_, _) => CancelRequested?.Invoke(); Grid.SetColumn(cancel, 1); content.Children.Add(cancel);
        Content = row;
        timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        timer.Tick += (_, _) => waveform.Tick(); timer.Start();
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            var style = GetWindowLongPtr(hwnd, -20).ToInt64(); SetWindowLongPtr(hwnd, -20, new IntPtr(style | 0x08000000L | 0x80));
            HwndSource.FromHwnd(hwnd)?.AddHook(NoActivate);
        };
        Loaded += (_, _) => BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140)));
        Closed += (_, _) => timer.Stop();
    }
    private static IntPtr NoActivate(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    { if (message == 0x0021) { handled = true; return new IntPtr(3); } return IntPtr.Zero; }
    public void SetLevel(double value) => waveform.Push(value);
    public void Processing() { waveform.Processing = true; label.Text = "正在整理"; }
    public void Message(string text) { waveform.Visibility = Visibility.Collapsed; label.FontSize = 12; label.Foreground = Brushes.White; label.Text = text; }
    public void Position(int index, int total)
    {
        number.Text = total > 1 ? (index + 1).ToString() : "";
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Width) / 2; Top = area.Bottom - 78 - (total - 1 - index) * 62;
    }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
}

public sealed class Waveform : FrameworkElement
{
    private readonly double[] bars = new double[24];
    private double peak;
    private double phase;
    public bool Processing { get; set; }
    public void Push(double value)
    {
        // A restrained square-root curve keeps quiet speech visible without
        // flattening louder peaks. The buffer is driven by microphone frames.
        peak = Math.Clamp(Math.Sqrt(Math.Max(0, value - .004)) * 1.55, 0, 1);
        Array.Copy(bars, 1, bars, 0, bars.Length - 1); bars[^1] = peak;
    }
    public void Tick() { phase += .018; InvalidateVisual(); }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        if (Processing)
        {
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(78, 81, 88)), null, new Rect(0, 7, ActualWidth, 3), 1.5, 1.5);
            var x = (Math.Sin(phase) + 1) / 2 * Math.Max(0, ActualWidth - 32);
            dc.DrawRoundedRectangle(Brushes.LightGray, null, new Rect(x, 7, 32, 3), 1.5, 1.5); return;
        }
        double step = ActualWidth / bars.Length;
        for (int i = 0; i < bars.Length; i++)
        {
            double height = 2 + bars[i] * Math.Max(0, ActualHeight - 2);
            dc.DrawRoundedRectangle(Brushes.White, null, new Rect(i * step, (ActualHeight - height) / 2, 2.5, height), 1.25, 1.25);
        }
    }
}
