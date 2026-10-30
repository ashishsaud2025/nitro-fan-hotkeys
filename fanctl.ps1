#Requires -Version 5.1
<#
    fanctl.ps1 - command line for the fan

    Usage:
      fanctl.ps1 status          show temperatures, RPM, fan mode and system mode
      fanctl.ps1 auto            hand the fans back to Acer's own curve
      fanctl.ps1 max             maximum fan speed
      fanctl.ps1 set 70          CPU and GPU fans at 70%
      fanctl.ps1 set 70 50       CPU 70%, GPU 50%
      fanctl.ps1 step 10         raise the current speed by 10 points
      fanctl.ps1 step -10        lower it by 10 points
      fanctl.ps1 quiet           quiet performance mode
      fanctl.ps1 default         default performance mode
      fanctl.ps1 performance     performance mode
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'auto', 'max', 'set', 'step', 'quiet', 'default', 'performance')]
    [string]$Command = 'status',

    [Parameter(Position = 1)]
    [int]$Value = 0,

    [Parameter(Position = 2)]
    [int]$Gpu = -1
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FanCore.ps1')

try {
    switch ($Command) {
        'status' { Format-FanStatus }
        'auto'   { Set-FanAuto;   Format-FanStatus }
        'max'    { Set-FanMax;    Format-FanStatus }
        'set'    {
            if ($Gpu -lt 0) { $Gpu = $Value }
            $result = Set-FanPercent -Cpu $Value -Gpu $Gpu
            "Fan set to CPU $($result.Percent)% / GPU $($result.GpuPercent)%"
        }
        'step'   {
            $result = Step-Fan -Delta $Value
            "Fan set to CPU $($result.Percent)% / GPU $($result.GpuPercent)%"
        }
        'quiet'       { Set-OperationMode quiet | Out-Null;       Format-FanStatus }
        'default'     { Set-OperationMode default | Out-Null;     Format-FanStatus }
        'performance' { Set-OperationMode performance | Out-Null; Format-FanStatus }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
