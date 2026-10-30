#Requires -Version 5.1
<#
    fan-osd.ps1 - tiny on-screen display for the fan hotkeys

    Shows a rounded dark panel in the bottom right corner for about a second.
    Launched as a separate hidden process by fan-hotkeys.ps1 so the hotkey
    listener never blocks while the panel is visible.
#>
param(
    [string]$Text = 'Fan',
    [int]$Milliseconds = 1100
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$window = [System.Windows.Window]::new()
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.ResizeMode = 'NoResize'
$window.Width = 210
$window.Height = 62

$panel = [System.Windows.Controls.Border]::new()
$panel.CornerRadius = [System.Windows.CornerRadius]::new(14)
$panel.Background = [System.Windows.Media.SolidColorBrush]::new(
    [System.Windows.Media.Color]::FromArgb(232, 22, 22, 24))
$panel.BorderThickness = [System.Windows.Thickness]::new(1)
$panel.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
    [System.Windows.Media.Color]::FromArgb(70, 255, 255, 255))

$label = [System.Windows.Controls.TextBlock]::new()
$label.Text = $Text
$label.Foreground = [System.Windows.Media.Brushes]::White
$label.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI Semibold')
$label.FontSize = 24
$label.HorizontalAlignment = 'Center'
$label.VerticalAlignment = 'Center'

$panel.Child = $label
$window.Content = $panel

$area = [System.Windows.SystemParameters]::WorkArea
$window.WindowStartupLocation = 'Manual'
$window.Left = $area.Right - $window.Width - 28
$window.Top = $area.Bottom - $window.Height - 42

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
$timer.Add_Tick({
    $timer.Stop()
    $window.Close()
})
$timer.Start()

$window.ShowDialog() | Out-Null
