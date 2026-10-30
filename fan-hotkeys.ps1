#Requires -Version 5.1
<#
    fan-hotkeys.ps1 - global fan shortcuts for Acer Nitro laptops

      Ctrl + Alt + Up     raise fan speed by 10
      Ctrl + Alt + Down   lower fan speed by 10
      Ctrl + Alt + 0      automatic (Acer's own curve)
      Ctrl + Alt + 9      maximum
      Ctrl + Alt + 1/2/3  Quiet / Default / Performance mode

    Runs hidden from a scheduled task at logon (install.ps1 sets that up), so
    the shortcuts work in every application and never ask for administrator
    rights. Every press is confirmed with a small on-screen panel.
#>
$ErrorActionPreference = 'Stop'

$script:Root    = $PSScriptRoot
$script:LogFile = Join-Path $env:LOCALAPPDATA 'FanHotkeys\hotkeys.log'

. (Join-Path $script:Root 'FanCore.ps1')
. (Join-Path $script:Root 'FanOsd.ps1')

function Write-FanLog([string]$Message) {
    try {
        if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 200KB) {
            Move-Item $script:LogFile "$script:LogFile.old" -Force
        }
        "{0}  {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message |
            Add-Content -Path $script:LogFile -Encoding UTF8
    }
    catch { }
}

function Show-FanOsd([string]$Text) {
    try { [FanOsd]::Show($Text) }
    catch { }
}


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;

public class FanHotkeyWindow : NativeWindow
{
    public event Action<int> Hotkey;

    public FanHotkeyWindow()
    {
        CreateHandle(new CreateParams());
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x0312) // WM_HOTKEY
        {
            Action<int> handler = Hotkey;
            if (handler != null) handler(message.WParam.ToInt32());
            return;
        }
        base.WndProc(ref message);
    }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing


$MOD_ALT       = 0x0001
$MOD_CONTROL   = 0x0002
$MOD_SHIFT     = 0x0004
$MOD_NOREPEAT  = 0x4000

$bindings = @(
    @{ Id = 1; Key = 0x26; Action = 'up'          },  # VK_UP
    @{ Id = 2; Key = 0x28; Action = 'down'        },  # VK_DOWN
    @{ Id = 3; Key = 0x30; Action = 'auto'        },  # 0
    @{ Id = 4; Key = 0x39; Action = 'max'         },  # 9
    @{ Id = 5; Key = 0x31; Action = 'quiet'       },  # 1
    @{ Id = 6; Key = 0x32; Action = 'default'     },  # 2
    @{ Id = 7; Key = 0x33; Action = 'performance' }   # 3
)

# Single instance guard: a second listener would fight over the same hotkeys.
$mutex = [System.Threading.Mutex]::new($false, 'Local\NitroFanHotkeys')
if (-not $mutex.WaitOne(0)) {
    Write-FanLog 'Another listener is already running; exiting.'
    exit 0
}

$window = [FanHotkeyWindow]::new()
$registered = 0

# RegisterHotKey lives in user32; call it through a tiny helper type.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FanHotkeyApi
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
'@

foreach ($binding in $bindings) {
    $modifiers = $MOD_CONTROL -bor $MOD_ALT -bor $MOD_NOREPEAT
    $ok = [FanHotkeyApi]::RegisterHotKey($window.Handle, $binding.Id, $modifiers, $binding.Key)
    if (-not $ok) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        # Ctrl+Alt+arrows are claimed by some Intel graphics drivers; try Ctrl+Shift+Alt.
        $modifiers = $MOD_CONTROL -bor $MOD_ALT -bor $MOD_SHIFT -bor $MOD_NOREPEAT
        $ok = [FanHotkeyApi]::RegisterHotKey($window.Handle, $binding.Id, $modifiers, $binding.Key)
        if ($ok) {
            Write-FanLog "WARNING: Ctrl+Alt+$($binding.Action) unavailable (error $errorCode); using Ctrl+Alt+Shift instead."
        }
        else {
            Write-FanLog "ERROR: could not register hotkey '$($binding.Action)' (error $errorCode)."
        }
    }
    if ($ok) { $registered++ }
}

if ($registered -eq 0) {
    Write-FanLog 'ERROR: no hotkeys could be registered; exiting.'
    exit 1
}

Write-FanLog "Hotkey listener started ($registered registered)."

# The overlay form is created lazily on the first keypress (in FanOsd.Show),
# so idling costs nothing extra beyond PowerShell itself.


$window.add_Hotkey({
    param([int]$id)

    try {
        switch ($id) {
            1 {
                $result = Step-Fan -Delta 10
                Show-FanOsd "Fan $($result.Percent)%"
                Write-FanLog "Ctrl+Alt+Up -> custom $($result.Percent)%"
            }
            2 {
                $result = Step-Fan -Delta -10
                Show-FanOsd "Fan $($result.Percent)%"
                Write-FanLog "Ctrl+Alt+Down -> custom $($result.Percent)%"
            }
            3 {
                Set-FanAuto
                Show-FanOsd 'Fan Auto'
                Write-FanLog 'Ctrl+Alt+0 -> auto'
            }
            4 {
                Set-FanMax
                Show-FanOsd 'Fan Max'
                Write-FanLog 'Ctrl+Alt+9 -> max'
            }
            5 {
                Set-OperationMode quiet | Out-Null
                Show-FanOsd 'Quiet'
                Write-FanLog 'Ctrl+Alt+1 -> quiet'
            }
            6 {
                Set-OperationMode default | Out-Null
                Show-FanOsd 'Default'
                Write-FanLog 'Ctrl+Alt+2 -> default'
            }
            7 {
                Set-OperationMode performance | Out-Null
                Show-FanOsd 'Performance'
                Write-FanLog 'Ctrl+Alt+3 -> performance'
            }
        }
    }
    catch {
        Show-FanOsd 'Fan error'
        Write-FanLog "ERROR on hotkey ${id}: $($_.Exception.Message)"
    }
})

[System.Windows.Forms.Application]::Run()
