param(
    [switch]$SmokeTest,
    [string]$RenderPreview,
    [switch]$NtpTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;

public static class KrissNtpClient
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
        request[0] = 0x23; // NTP v4, client mode

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
            if (response.Buffer.Length < 48) throw new InvalidOperationException("The NTP response was incomplete.");

            byte leap = (byte)(response.Buffer[0] >> 6);
            byte mode = (byte)(response.Buffer[0] & 0x07);
            byte stratum = response.Buffer[1];
            if (leap == 3 || (mode != 4 && mode != 5) || stratum == 0)
                throw new InvalidOperationException("The NTP server returned an invalid clock response.");

            for (int i = 0; i < 8; i++)
                if (response.Buffer[24 + i] != request[40 + i])
                    throw new InvalidOperationException("The NTP response did not match the request.");

            DateTime serverReceivedUtc = ReadTimestamp(response.Buffer, 32);
            DateTime serverSentUtc = ReadTimestamp(response.Buffer, 40);

            // Standard NTP four-timestamp calculation:
            // offset = ((T2 - T1) + (T3 - T4)) / 2
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
        DateTime unixEpoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        return unixEpoch.AddSeconds(unixSeconds);
    }

    private static void WriteTimestamp(byte[] data, int offset, DateTime utc)
    {
        DateTime unixEpoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        long ticks = (utc.ToUniversalTime() - unixEpoch).Ticks;
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
'@

$script:AppName = 'Mondane Stop-and-Go Clock'
$script:NtpHost = 'ntp.kriss.re.kr'
$script:ClockOffset = [TimeSpan]::Zero
$script:LastSync = $null
$script:SyncTask = $null
$script:LastSyncAttemptMinute = $null
$script:SyncHealthy = $false
$script:IndicatorLit = $false
$script:StartupValueName = 'MondaneStopAndGoClock'
$script:StartupKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
$script:ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LauncherPath = Join-Path $script:ScriptDirectory 'ClockWidget.vbs'

if ($NtpTest) {
    $offset = [KrissNtpClient]::GetClockOffsetAsync($script:NtpHost, 5000).GetAwaiter().GetResult()
    Write-Output ('NTP response valid. Clock offset: {0:N3} ms' -f $offset.TotalMilliseconds)
    exit 0
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Mondane Stop-and-Go Clock" Width="430" Height="438"
        MinWidth="280" MinHeight="288" WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="CanResizeWithGrip" AllowsTransparency="True"
        Background="Transparent">
  <Border BorderThickness="0" Background="Transparent">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="32"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
        <TextBlock Text="STOP&#x2013;AND&#x2013;GO" Foreground="#565656" FontSize="10"
                   FontWeight="SemiBold" VerticalAlignment="Center" Margin="12,0,72,0"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="PinButton" Content="&#x25C7;" Width="34" Height="30" ToolTip="Always on top"
                  Foreground="#565656" Background="Transparent" BorderThickness="0" FontSize="15"/>
          <Button x:Name="CloseButton" Content="&#x00D7;" Width="34" Height="30" ToolTip="Close"
                  Foreground="#565656" Background="Transparent" BorderThickness="0" FontSize="18"/>
        </StackPanel>
      </Grid>
      <Viewbox Grid.Row="1" Stretch="Uniform" Margin="10">
        <Canvas x:Name="ClockCanvas" Width="400" Height="400" Background="Transparent"/>
      </Viewbox>
    </Grid>
  </Border>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$canvas = $window.FindName('ClockCanvas')
$titleBar = $window.FindName('TitleBar')
$pinButton = $window.FindName('PinButton')
$closeButton = $window.FindName('CloseButton')

function New-Line {
    param([double]$X1, [double]$Y1, [double]$X2, [double]$Y2, [string]$Color, [double]$Width, [string]$Start = 'Flat', [string]$End = 'Flat')
    $line = [Windows.Shapes.Line]::new()
    $line.X1 = $X1; $line.Y1 = $Y1; $line.X2 = $X2; $line.Y2 = $Y2
    $line.Stroke = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    $line.StrokeThickness = $Width
    $line.StrokeStartLineCap = [Windows.Media.PenLineCap]::$Start
    $line.StrokeEndLineCap = [Windows.Media.PenLineCap]::$End
    [void]$canvas.Children.Add($line)
    return $line
}

function Add-ClockFace {
    $face = [Windows.Shapes.Ellipse]::new()
    $face.Width = 386; $face.Height = 386
    $face.Fill = [Windows.Media.Brushes]::White
    $face.Stroke = [Windows.Media.BrushConverter]::new().ConvertFromString('#D9D9D7')
    $face.StrokeThickness = 3
    $faceShadow = [Windows.Media.Effects.DropShadowEffect]::new()
    $faceShadow.Color = [Windows.Media.Colors]::Black
    $faceShadow.BlurRadius = 12
    $faceShadow.ShadowDepth = 2
    $faceShadow.Opacity = 0.28
    $face.Effect = $faceShadow
    [Windows.Controls.Canvas]::SetLeft($face, 7)
    [Windows.Controls.Canvas]::SetTop($face, 7)
    [void]$canvas.Children.Add($face)

    for ($i = 0; $i -lt 60; $i++) {
        $angle = $i * [Math]::PI / 30
        $major = ($i % 5 -eq 0)
        $outer = 178
        $inner = if ($major) { 145 } else { 163 }
        $width = if ($major) { 8 } else { 3 }
        $x1 = 200 + [Math]::Sin($angle) * $inner
        $y1 = 200 - [Math]::Cos($angle) * $inner
        $x2 = 200 + [Math]::Sin($angle) * $outer
        $y2 = 200 - [Math]::Cos($angle) * $outer
        [void](New-Line $x1 $y1 $x2 $y2 '#111111' $width)
    }

    $script:HourHand = New-Line 200 205 200 103 '#111111' 14 'Round' 'Round'
    # Both long hands end at the radial midpoint of the minute markers.
    $script:MinuteHand = New-Line 200 210 200 29.5 '#111111' 10 'Round' 'Round'
    $script:SecondHand = New-Line 200 232 200 29.5 '#E3202A' 5 'Round' 'Round'

    $hub = [Windows.Shapes.Ellipse]::new()
    $hub.Width = 18; $hub.Height = 18
    $hub.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#E3202A')
    [Windows.Controls.Canvas]::SetLeft($hub, 191)
    [Windows.Controls.Canvas]::SetTop($hub, 191)
    [void]$canvas.Children.Add($hub)

    # Sync status LED, halfway between the center and the six o'clock marker.
    $script:SyncIndicator = [Windows.Shapes.Ellipse]::new()
    $script:SyncIndicator.Width = 7; $script:SyncIndicator.Height = 7
    $script:SyncIndicator.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#31513A')
    $script:SyncIndicator.Stroke = [Windows.Media.BrushConverter]::new().ConvertFromString('#1E3123')
    $script:SyncIndicator.StrokeThickness = 1
    [Windows.Controls.Canvas]::SetLeft($script:SyncIndicator, 196.5)
    [Windows.Controls.Canvas]::SetTop($script:SyncIndicator, 279.5)
    [void]$canvas.Children.Add($script:SyncIndicator)
}

function Set-Rotation($element, [double]$angle, [double]$centerX = 200, [double]$centerY = 200) {
    $element.RenderTransform = [Windows.Media.RotateTransform]::new($angle, $centerX, $centerY)
}

function Update-Clock {
    $now = ([DateTime]::UtcNow + $script:ClockOffset).ToLocalTime()
    $elapsed = $now.Second + ($now.Millisecond / 1000.0)

    # The sweep completes in 59 seconds, then waits at 12 for one second.
    $secondAngle = if ($elapsed -lt 59.0) { ($elapsed / 59.0) * 360.0 } else { 0.0 }

    # While the second hand is stopped, ease the minute hand to its next mark.
    # Smoothstep gives the movement gentle acceleration and deceleration while
    # remaining continuous across the minute boundary.
    $minuteAdvance = 0.0
    if ($elapsed -ge 59.0) {
        $progress = [Math]::Min(1.0, [Math]::Max(0.0, $elapsed - 59.0))
        $minuteAdvance = $progress * $progress * (3.0 - (2.0 * $progress))
    }
    $displayMinute = $now.Minute + $minuteAdvance
    $minuteAngle = $displayMinute * 6.0
    $hourAngle = (($now.Hour % 12) + ($displayMinute / 60.0)) * 30.0

    Set-Rotation $script:SecondHand $secondAngle
    Set-Rotation $script:MinuteHand $minuteAngle
    Set-Rotation $script:HourHand $hourAngle
    Update-SyncIndicatorVisual ($script:SyncHealthy -and $elapsed -lt 59.0)

    # There is exactly one automatic sync attempt during each stop phase.
    if ($elapsed -ge 59.0) {
        $minuteKey = $now.ToString('yyyyMMddHHmm')
        if ($script:LastSyncAttemptMinute -ne $minuteKey) {
            $script:LastSyncAttemptMinute = $minuteKey
            Start-TimeSync
        }
    }
}

function Set-SyncIndicator([bool]$healthy) {
    $script:SyncHealthy = $healthy
    $now = ([DateTime]::UtcNow + $script:ClockOffset).ToLocalTime()
    $elapsed = $now.Second + ($now.Millisecond / 1000.0)
    Update-SyncIndicatorVisual ($healthy -and $elapsed -lt 59.0)
}

function Update-SyncIndicatorVisual([bool]$lit) {
    if ($script:IndicatorLit -eq $lit) { return }
    $script:IndicatorLit = $lit
    if ($lit) {
        $script:SyncIndicator.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#39FF63')
        $script:SyncIndicator.Stroke = [Windows.Media.BrushConverter]::new().ConvertFromString('#0D8F2E')
        $glow = [Windows.Media.Effects.DropShadowEffect]::new()
        $glow.Color = [Windows.Media.Color]::FromRgb(57, 255, 99)
        $glow.BlurRadius = 7
        $glow.ShadowDepth = 0
        $glow.Opacity = 0.9
        $script:SyncIndicator.Effect = $glow
    } else {
        $script:SyncIndicator.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#31513A')
        $script:SyncIndicator.Stroke = [Windows.Media.BrushConverter]::new().ConvertFromString('#1E3123')
        $script:SyncIndicator.Effect = $null
    }
}

function Get-StartupEnabled {
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:StartupKeyPath)
        if ($null -eq $key) { return $false }
        $value = $key.GetValue($script:StartupValueName, $null)
        $key.Dispose()
        return $null -ne $value
    } catch { return $false }
}

function Set-StartupEnabled([bool]$enabled) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:StartupKeyPath)
    try {
        if ($enabled) {
            $command = 'wscript.exe "{0}"' -f $script:LauncherPath
            $key.SetValue($script:StartupValueName, $command, [Microsoft.Win32.RegistryValueKind]::String)
        } else {
            $key.DeleteValue($script:StartupValueName, $false)
        }
    } finally { $key.Dispose() }
}

function Start-TimeSync {
    if ($null -ne $script:SyncTask -and -not $script:SyncTask.IsCompleted) { return }
    $script:SyncTask = [KrissNtpClient]::GetClockOffsetAsync($script:NtpHost, 5000)
}

function Complete-TimeSync {
    if ($null -eq $script:SyncTask -or -not $script:SyncTask.IsCompleted) { return }
    try {
        $script:ClockOffset = $script:SyncTask.GetAwaiter().GetResult()
        $script:LastSync = [DateTime]::Now
        Set-SyncIndicator $true
    } catch {
        Set-SyncIndicator $false
    } finally {
        $script:SyncTask = $null
    }
}

function Set-Topmost([bool]$enabled) {
    $window.Topmost = $enabled
    $pinButton.Content = if ($enabled) { [char]0x25C6 } else { [char]0x25C7 }
    $pinButton.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($(if ($enabled) { '#E3202A' } else { '#565656' }))
    if ($null -ne $script:TopmostMenuItem) { $script:TopmostMenuItem.IsChecked = $enabled }
}

Add-ClockFace

$contextMenu = [Windows.Controls.ContextMenu]::new()
$script:TopmostMenuItem = [Windows.Controls.MenuItem]::new()
$script:TopmostMenuItem.Header = 'Always on top'
$script:TopmostMenuItem.IsCheckable = $true
$script:TopmostMenuItem.Add_Click({ Set-Topmost (-not $window.Topmost) })
[void]$contextMenu.Items.Add($script:TopmostMenuItem)

$startupMenuItem = [Windows.Controls.MenuItem]::new()
$startupMenuItem.Header = 'Start with Windows'
$startupMenuItem.IsCheckable = $true
$startupMenuItem.IsChecked = Get-StartupEnabled
$startupMenuItem.Add_Click({
    try {
        Set-StartupEnabled (-not (Get-StartupEnabled))
        $startupMenuItem.IsChecked = Get-StartupEnabled
    } catch {
        [Windows.MessageBox]::Show("Could not update Windows startup: $($_.Exception.Message)", $script:AppName) | Out-Null
    }
})
[void]$contextMenu.Items.Add($startupMenuItem)

$syncMenuItem = [Windows.Controls.MenuItem]::new()
$syncMenuItem.Header = 'Sync now'
$syncMenuItem.Add_Click({ Start-TimeSync })
[void]$contextMenu.Items.Add($syncMenuItem)
[void]$contextMenu.Items.Add([Windows.Controls.Separator]::new())

$exitMenuItem = [Windows.Controls.MenuItem]::new()
$exitMenuItem.Header = 'Exit'
$exitMenuItem.Add_Click({ $window.Close() })
[void]$contextMenu.Items.Add($exitMenuItem)
$window.ContextMenu = $contextMenu

$titleBar.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.GetPosition($titleBar).X -ge ($titleBar.ActualWidth - 68)) { return }
    if ($eventArgs.ClickCount -eq 2) { Set-Topmost (-not $window.Topmost) }
    else { $window.DragMove() }
})
$canvas.Add_MouseLeftButtonDown({ $window.DragMove() })
$pinButton.Add_Click({ Set-Topmost (-not $window.Topmost) })
$closeButton.Add_Click({ $window.Close() })
$window.Add_KeyDown({ param($sender, $eventArgs); if ($eventArgs.Key -eq 'Escape') { $window.Close() } })

$animationTimer = [Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Render)
$animationTimer.Interval = [TimeSpan]::FromMilliseconds(25)
$animationTimer.Add_Tick({ Update-Clock; Complete-TimeSync })
$animationTimer.Start()

$window.Add_Loaded({ Update-Clock })
$window.Add_Closed({ $animationTimer.Stop() })

if ($SmokeTest -or $RenderPreview) {
    Update-Clock
    if ($RenderPreview) {
        $window.ShowInTaskbar = $false
        $window.Left = 100
        $window.Top = 100
        $window.Show()
        $window.UpdateLayout()
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(430, 438, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($window)
        $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Open($RenderPreview, [IO.FileMode]::Create)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        $window.Close()
    }
    Write-Output 'Clock widget smoke test passed.'
    exit 0
}

[void]$window.ShowDialog()
