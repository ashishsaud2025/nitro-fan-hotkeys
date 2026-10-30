#Requires -Version 5.1
<#
    install.ps1 - start the fan hotkeys automatically at logon

    Run once:   powershell -ExecutionPolicy Bypass -File .\install.ps1
    Remove:     powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall

    Creates a per-user scheduled task. No administrator rights needed: the
    NitroSense service accepts fan commands from a normal user session, and
    running without elevation means no UAC prompt at logon.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$taskName = 'Nitro Fan Hotkeys'
$root     = $PSScriptRoot
$listener = Join-Path $root 'fan-hotkeys.ps1'

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*fan-hotkeys.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    & (Join-Path $root 'fanctl.ps1') auto | Out-Null
    Write-Host 'Fan hotkeys removed. Fans are back on the automatic curve.' -ForegroundColor Yellow
    return
}

if (-not (Test-Path $listener)) { throw "fan-hotkeys.ps1 is missing next to install.ps1." }

try { Get-Service -Name 'PSSvc' -ErrorAction Stop | Out-Null }
catch { throw 'The NitroSense service (PSSvc) is not installed. Install NitroSense first.' }

$account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $listener)

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $account

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -Hidden

$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force `
    -Description 'Global hotkeys for Acer Nitro fan speed (Ctrl+Alt+Up/Down, Ctrl+Alt+0, Ctrl+Alt+9).' | Out-Null

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2

$running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*fan-hotkeys.ps1*' }

if ($running) {
    Write-Host 'Fan hotkeys are running.' -ForegroundColor Green
}
else {
    Write-Host 'Task created, but the listener is not visible yet. Check %LOCALAPPDATA%\FanHotkeys\hotkeys.log.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Ctrl + Alt + Up     fan +10%' -ForegroundColor Cyan
Write-Host '  Ctrl + Alt + Down   fan -10%' -ForegroundColor Cyan
Write-Host '  Ctrl + Alt + 0      Auto (Acer curve)' -ForegroundColor Cyan
Write-Host '  Ctrl + Alt + 9      Max' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Command line: fanctl.ps1 status | auto | max | set 70 | step 10'
