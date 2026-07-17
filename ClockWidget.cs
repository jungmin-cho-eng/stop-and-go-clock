using System;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;

[assembly: AssemblyTitle("Stop-and-Go Clock")]
[assembly: AssemblyDescription("Portable NTP-synchronized stop-and-go clock")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length > 0 && args[0] == "--ntp-test")
            {
                KrissNtpClient.GetClockOffsetAsync("ntp.kriss.re.kr", 5000).GetAwaiter().GetResult();
                return 0;
            }

            var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
            var clock = new ClockWindow();
            if (args.Length > 0 && args[0] == "--smoke-test")
            {
                clock.Show();
                clock.UpdateLayout();
                clock.Close();
                return 0;
            }
            app.Run(clock);
            return 0;
        }
        catch
        {
            return 1;
        }
    }
}

internal sealed class ClockWindow : Window
{
    private const string NtpHost = "ntp.kriss.re.kr";
    private const string StartupKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string StartupValueName = "MondaneStopAndGoClock";

    private readonly Canvas canvas;
    private readonly Button pinButton;
    private readonly MenuItem topmostMenuItem;
    private readonly Ellipse syncIndicator;
    private readonly Line hourHand;
    private readonly Line minuteHand;
    private readonly Line secondHand;
    private readonly DispatcherTimer animationTimer;

    private TimeSpan clockOffset = TimeSpan.Zero;
    private Task<TimeSpan> syncTask;
    private string lastSyncAttemptMinute;
    private bool syncHealthy;
    private bool? indicatorLit;

    public ClockWindow()
    {
        Title = "Stop-and-Go Clock";
        Width = 430;
        Height = 438;
        MinWidth = 280;
        MinHeight = 288;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.CanResizeWithGrip;
        AllowsTransparency = true;
        Background = Brushes.Transparent;

        var root = new Grid { Background = Brushes.Transparent };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(32) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Content = root;

        var titleBar = new Grid { Background = Brushes.Transparent };
        Grid.SetRow(titleBar, 0);
        root.Children.Add(titleBar);

        var title = new TextBlock
        {
            Text = "STOP\u2013AND\u2013GO",
            Foreground = Brush("#565656"),
            FontSize = 10,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(12, 0, 72, 0)
        };
        titleBar.Children.Add(title);

        var titleButtons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        titleBar.Children.Add(titleButtons);

        pinButton = MakeTitleButton("\u25C7", 15, "Always on top");
        var closeButton = MakeTitleButton("\u00D7", 18, "Close");
        titleButtons.Children.Add(pinButton);
        titleButtons.Children.Add(closeButton);

        canvas = new Canvas
        {
            Width = 400,
            Height = 400,
            Background = Brushes.Transparent
        };
        var viewbox = new Viewbox
        {
            Stretch = Stretch.Uniform,
            Margin = new Thickness(10),
            Child = canvas
        };
        Grid.SetRow(viewbox, 1);
        root.Children.Add(viewbox);

        DrawFace();
        hourHand = AddLine(200, 205, 200, 103, "#111111", 14, PenLineCap.Round);
        minuteHand = AddLine(200, 210, 200, 29.5, "#111111", 10, PenLineCap.Round);
        secondHand = AddLine(200, 232, 200, 29.5, "#E3202A", 5, PenLineCap.Round);

        var hub = new Ellipse { Width = 18, Height = 18, Fill = Brush("#E3202A") };
        Canvas.SetLeft(hub, 191);
        Canvas.SetTop(hub, 191);
        canvas.Children.Add(hub);

        syncIndicator = new Ellipse
        {
            Width = 7,
            Height = 7,
            Fill = Brush("#31513A"),
            Stroke = Brush("#1E3123"),
            StrokeThickness = 1
        };
        Canvas.SetLeft(syncIndicator, 196.5);
        Canvas.SetTop(syncIndicator, 279.5);
        canvas.Children.Add(syncIndicator);

        var menu = new ContextMenu();
        topmostMenuItem = new MenuItem { Header = "Always on top", IsCheckable = true };
        topmostMenuItem.Click += delegate { SetTopmost(!Topmost); };
        menu.Items.Add(topmostMenuItem);

        bool startupEnabled = IsStartupEnabled();
        if (startupEnabled)
        {
            try { SetStartupEnabled(true); } catch { }
        }
        var startupMenuItem = new MenuItem
        {
            Header = "Start with Windows",
            IsCheckable = true,
            IsChecked = startupEnabled
        };
        startupMenuItem.Click += delegate
        {
            try
            {
                SetStartupEnabled(startupMenuItem.IsChecked);
            }
            catch (Exception ex)
            {
                startupMenuItem.IsChecked = IsStartupEnabled();
                MessageBox.Show("Could not update Windows startup: " + ex.Message, Title,
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
        menu.Items.Add(startupMenuItem);

        var syncNow = new MenuItem { Header = "Sync now" };
        syncNow.Click += delegate { StartTimeSync(); };
        menu.Items.Add(syncNow);
        menu.Items.Add(new Separator());
        var exit = new MenuItem { Header = "Exit" };
        exit.Click += delegate { Close(); };
        menu.Items.Add(exit);
        ContextMenu = menu;

        titleBar.MouseLeftButtonDown += delegate(object sender, MouseButtonEventArgs e)
        {
            if (e.GetPosition(titleBar).X >= titleBar.ActualWidth - 68) return;
            if (e.ClickCount == 2) SetTopmost(!Topmost);
            else DragMove();
        };
        canvas.MouseLeftButtonDown += delegate { DragMove(); };
        pinButton.Click += delegate { SetTopmost(!Topmost); };
        closeButton.Click += delegate { Close(); };
        KeyDown += delegate(object sender, KeyEventArgs e) { if (e.Key == Key.Escape) Close(); };

        animationTimer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(25)
        };
        animationTimer.Tick += delegate
        {
            UpdateClock();
            CompleteTimeSync();
        };
        Loaded += delegate { UpdateClock(); animationTimer.Start(); };
        Closed += delegate { animationTimer.Stop(); };
    }

    private static SolidColorBrush Brush(string value)
    {
        return (SolidColorBrush)new BrushConverter().ConvertFromString(value);
    }

    private static Button MakeTitleButton(string content, double fontSize, string tooltip)
    {
        return new Button
        {
            Content = content,
            Width = 34,
            Height = 30,
            ToolTip = tooltip,
            Foreground = Brush("#565656"),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            FontSize = fontSize
        };
    }

    private void DrawFace()
    {
        var face = new Ellipse
        {
            Width = 386,
            Height = 386,
            Fill = Brushes.White,
            Stroke = Brush("#D9D9D7"),
            StrokeThickness = 3,
            Effect = new DropShadowEffect
            {
                Color = Colors.Black,
                BlurRadius = 12,
                ShadowDepth = 2,
                Opacity = 0.28
            }
        };
        Canvas.SetLeft(face, 7);
        Canvas.SetTop(face, 7);
        canvas.Children.Add(face);

        for (int i = 0; i < 60; i++)
        {
            double angle = i * Math.PI / 30.0;
            bool major = i % 5 == 0;
            double outer = 178;
            double inner = major ? 145 : 163;
            double width = major ? 8 : 3;
            AddLine(200 + Math.Sin(angle) * inner, 200 - Math.Cos(angle) * inner,
                    200 + Math.Sin(angle) * outer, 200 - Math.Cos(angle) * outer,
                    "#111111", width, PenLineCap.Flat);
        }
    }

    private Line AddLine(double x1, double y1, double x2, double y2,
                         string color, double width, PenLineCap cap)
    {
        var line = new Line
        {
            X1 = x1,
            Y1 = y1,
            X2 = x2,
            Y2 = y2,
            Stroke = Brush(color),
            StrokeThickness = width,
            StrokeStartLineCap = cap,
            StrokeEndLineCap = cap
        };
        canvas.Children.Add(line);
        return line;
    }

    private static void Rotate(UIElement element, double angle)
    {
        element.RenderTransform = new RotateTransform(angle, 200, 200);
    }

    private void UpdateClock()
    {
        DateTime now = (DateTime.UtcNow + clockOffset).ToLocalTime();
        double elapsed = now.Second + now.Millisecond / 1000.0;
        double secondAngle = elapsed < 59.0 ? elapsed / 59.0 * 360.0 : 0.0;

        double minuteAdvance = 0.0;
        if (elapsed >= 59.0)
        {
            double progress = Math.Min(1.0, Math.Max(0.0, elapsed - 59.0));
            minuteAdvance = progress * progress * (3.0 - 2.0 * progress);
        }
        double displayMinute = now.Minute + minuteAdvance;
        double minuteAngle = displayMinute * 6.0;
        double hourAngle = ((now.Hour % 12) + displayMinute / 60.0) * 30.0;

        Rotate(secondHand, secondAngle);
        Rotate(minuteHand, minuteAngle);
        Rotate(hourHand, hourAngle);
        SetSyncIndicatorLit(syncHealthy && elapsed < 59.0);

        if (elapsed >= 59.0)
        {
            string minuteKey = now.ToString("yyyyMMddHHmm");
            if (lastSyncAttemptMinute != minuteKey)
            {
                lastSyncAttemptMinute = minuteKey;
                StartTimeSync();
            }
        }
    }

    private void StartTimeSync()
    {
        if (syncTask != null && !syncTask.IsCompleted) return;
        syncTask = KrissNtpClient.GetClockOffsetAsync(NtpHost, 5000);
    }

    private void CompleteTimeSync()
    {
        if (syncTask == null || !syncTask.IsCompleted) return;
        try
        {
            clockOffset = syncTask.GetAwaiter().GetResult();
            SetSyncHealthy(true);
        }
        catch
        {
            SetSyncHealthy(false);
        }
        finally
        {
            syncTask = null;
        }
    }

    private void SetSyncHealthy(bool healthy)
    {
        syncHealthy = healthy;
        DateTime now = (DateTime.UtcNow + clockOffset).ToLocalTime();
        double elapsed = now.Second + now.Millisecond / 1000.0;
        SetSyncIndicatorLit(healthy && elapsed < 59.0);
    }

    private void SetSyncIndicatorLit(bool lit)
    {
        if (indicatorLit.HasValue && indicatorLit.Value == lit) return;
        indicatorLit = lit;
        if (lit)
        {
            syncIndicator.Fill = Brush("#39FF63");
            syncIndicator.Stroke = Brush("#0D8F2E");
            syncIndicator.Effect = new DropShadowEffect
            {
                Color = Color.FromRgb(57, 255, 99),
                BlurRadius = 7,
                ShadowDepth = 0,
                Opacity = 0.9
            };
        }
        else
        {
            syncIndicator.Fill = Brush("#31513A");
            syncIndicator.Stroke = Brush("#1E3123");
            syncIndicator.Effect = null;
        }
    }

    private void SetTopmost(bool enabled)
    {
        Topmost = enabled;
        pinButton.Content = enabled ? "\u25C6" : "\u25C7";
        pinButton.Foreground = Brush(enabled ? "#E3202A" : "#565656");
        topmostMenuItem.IsChecked = enabled;
    }

    private static bool IsStartupEnabled()
    {
        try
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(StartupKeyPath))
                return key != null && key.GetValue(StartupValueName) != null;
        }
        catch { return false; }
    }

    private static void SetStartupEnabled(bool enabled)
    {
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(StartupKeyPath))
        {
            if (enabled)
            {
                string path = Assembly.GetExecutingAssembly().Location;
                key.SetValue(StartupValueName, "\"" + path + "\"", RegistryValueKind.String);
            }
            else
            {
                key.DeleteValue(StartupValueName, false);
            }
        }
    }
}

internal static class KrissNtpClient
{
    private const ulong EpochOffset = 2208988800UL;

    private struct NtpSample
    {
        public TimeSpan Offset;
        public TimeSpan RoundTrip;
    }

    public static async Task<TimeSpan> GetClockOffsetAsync(string host, int timeoutMilliseconds)
    {
        IPAddress[] addresses = await Dns.GetHostAddressesAsync(host).ConfigureAwait(false);
        if (addresses.Length == 0) throw new InvalidOperationException("NTP host returned no addresses.");

        NtpSample? best = null;
        Exception lastError = null;
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                NtpSample sample = await QueryAsync(addresses[0], timeoutMilliseconds).ConfigureAwait(false);
                if (!best.HasValue || sample.RoundTrip < best.Value.RoundTrip) best = sample;
            }
            catch (Exception ex)
            {
                lastError = ex;
            }
            if (attempt < 2) await Task.Delay(35).ConfigureAwait(false);
        }

        if (!best.HasValue)
            throw new InvalidOperationException("No valid NTP samples were received.", lastError);
        return best.Value.Offset;
    }

    private static async Task<NtpSample> QueryAsync(IPAddress address, int timeoutMilliseconds)
    {
        byte[] request = new byte[48];
        request[0] = 0x23;

        using (var udp = new UdpClient(address.AddressFamily))
        {
            udp.Connect(new IPEndPoint(address, 123));
            DateTime sentUtc = DateTime.UtcNow;
            WriteTimestamp(request, 40, sentUtc);
            await udp.SendAsync(request, request.Length).ConfigureAwait(false);

            Task<UdpReceiveResult> receiveTask = udp.ReceiveAsync();
            Task finished = await Task.WhenAny(receiveTask, Task.Delay(timeoutMilliseconds)).ConfigureAwait(false);
            if (finished != receiveTask) throw new TimeoutException("The NTP server did not respond in time.");

            UdpReceiveResult response = await receiveTask.ConfigureAwait(false);
            DateTime receivedUtc = DateTime.UtcNow;
            if (response.Buffer.Length < 48) throw new InvalidOperationException("Incomplete NTP response.");

            byte leap = (byte)(response.Buffer[0] >> 6);
            byte mode = (byte)(response.Buffer[0] & 0x07);
            byte stratum = response.Buffer[1];
            if (leap == 3 || (mode != 4 && mode != 5) || stratum == 0)
                throw new InvalidOperationException("Invalid NTP clock response.");

            for (int i = 0; i < 8; i++)
                if (response.Buffer[24 + i] != request[40 + i])
                    throw new InvalidOperationException("The NTP response did not match the request.");

            DateTime serverReceivedUtc = ReadTimestamp(response.Buffer, 32);
            DateTime serverSentUtc = ReadTimestamp(response.Buffer, 40);
            long offsetTicks = ((serverReceivedUtc - sentUtc).Ticks +
                                (serverSentUtc - receivedUtc).Ticks) / 2;
            TimeSpan roundTrip = (receivedUtc - sentUtc) - (serverSentUtc - serverReceivedUtc);
            if (roundTrip < TimeSpan.Zero) roundTrip = TimeSpan.Zero;
            return new NtpSample { Offset = TimeSpan.FromTicks(offsetTicks), RoundTrip = roundTrip };
        }
    }

    private static DateTime ReadTimestamp(byte[] data, int offset)
    {
        ulong seconds = ReadUInt32BigEndian(data, offset);
        ulong fraction = ReadUInt32BigEndian(data, offset + 4);
        double unixSeconds = (seconds - EpochOffset) + fraction / 4294967296.0;
        DateTime epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        return epoch.AddSeconds(unixSeconds);
    }

    private static void WriteTimestamp(byte[] data, int offset, DateTime utc)
    {
        DateTime epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        long ticks = (utc.ToUniversalTime() - epoch).Ticks;
        ulong seconds = (ulong)(ticks / TimeSpan.TicksPerSecond) + EpochOffset;
        ulong fraction = ((ulong)(ticks % TimeSpan.TicksPerSecond) * 4294967296UL) /
                         (ulong)TimeSpan.TicksPerSecond;
        WriteUInt32BigEndian(data, offset, (uint)seconds);
        WriteUInt32BigEndian(data, offset + 4, (uint)fraction);
    }

    private static uint ReadUInt32BigEndian(byte[] data, int offset)
    {
        return ((uint)data[offset] << 24) | ((uint)data[offset + 1] << 16) |
               ((uint)data[offset + 2] << 8) | data[offset + 3];
    }

    private static void WriteUInt32BigEndian(byte[] data, int offset, uint value)
    {
        data[offset] = (byte)(value >> 24);
        data[offset + 1] = (byte)(value >> 16);
        data[offset + 2] = (byte)(value >> 8);
        data[offset + 3] = (byte)value;
    }
}
