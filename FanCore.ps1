<#
    FanCore.ps1 - fan control engine for Acer Nitro laptops

    Talks to the NitroSense background service (PSSvc) over its named pipe,
    the same channel the NitroSense window uses, and keeps the NitroSense
    registry state in sync so the app shows the same values afterwards.

    No administrator rights required. Tested on Nitro AN515-58,
    NitroSense Service 3.01.3052.

    Protocol:
      pipe  : \\.\pipe\PredatorSense_service_namedpipe
      frame : u16 command, u8 argument count, then per argument u32 length + bytes
      reply : 9 bytes (u32) or 13 bytes (u64); payload starts at byte 5,
              a setter returns 0 for success

      cmd 13 : telemetry, arg u32 = 1 | (index << 8)
               index 1 = CPU temp, 2 = CPU RPM, 6 = GPU RPM, 10 = GPU temp
               reading = (value >> 8) & 0xFFFF
      cmd 15 : fan behavior, arg u64
               0x410009 = automatic, 0x820009 = maximum
               custom  = 9 | ((gpuFlag | cpuValue) << 16)
               cpuValue 1 = auto, 3 = manual
               gpuFlag  0x40 = auto, 0xC0 = manual
      cmd 16 : manual speed, arg u64 = selector | (percent << 8)
               selector 1 = CPU fan, 4 = GPU fan
      cmd 3  : persist a value, args: path, name, type (4 = dword), value
#>

$script:PipeName     = 'PredatorSense_service_namedpipe'
$script:BehaviorAuto = [uint64]0x410009
$script:BehaviorMax  = [uint64]0x820009
$script:StateDir     = Join-Path $env:LOCALAPPDATA 'FanHotkeys'
$script:FanKey       = 'SOFTWARE\OEM\NitroSense\FanControl'
$script:ModeKey      = 'SOFTWARE\OEM\NitroSense\Overclock'
$script:MinPercent   = 20
$script:MaxPercent   = 100


function Send-AcerFrame {
    param(
        [Parameter(Mandatory)][uint16]$Code,
        [Parameter(Mandatory)][byte[][]]$Arguments,
        [Parameter(Mandatory)][int]$ReplySize
    )

    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
        '.', $script:PipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(2000)

        $stream = [System.IO.MemoryStream]::new()
        $writer = [System.IO.BinaryWriter]::new($stream)
        $writer.Write([uint16]$Code)
        $writer.Write([byte]$Arguments.Count)
        foreach ($argument in $Arguments) {
            $writer.Write([uint32]$argument.Length)
            $writer.Write($argument)
        }
        $writer.Flush()
        $message = $stream.ToArray()
        $pipe.Write($message, 0, $message.Length)
        $pipe.Flush()

        $reply = [byte[]]::new($ReplySize)
        $received = 0
        $deadline = [DateTime]::UtcNow.AddMilliseconds(1500)
        while ($received -lt $ReplySize -and [DateTime]::UtcNow -lt $deadline) {
            if (-not $pipe.IsConnected) { break }
            $chunk = [byte[]]::new($ReplySize - $received)
            $read = $pipe.Read($chunk, 0, $chunk.Length)
            if ($read -gt 0) {
                [Array]::Copy($chunk, 0, $reply, $received, $read)
                $received += $read
            }
            else { Start-Sleep -Milliseconds 20 }
        }
        if ($received -lt $ReplySize) {
            throw "NitroSense service did not answer command $Code (got $received of $ReplySize bytes)."
        }
        return $reply
    }
    finally { $pipe.Dispose() }
}

function ConvertTo-U32Argument([uint32]$Value) { [BitConverter]::GetBytes($Value) }
function ConvertTo-U64Argument([uint64]$Value) { [BitConverter]::GetBytes($Value) }
function ConvertTo-StringArgument([string]$Value) {
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Value)
    $padded = [byte[]]::new($bytes.Length + 2)   # trailing UTF-16 NUL
    [Array]::Copy($bytes, $padded, $bytes.Length)
    return $padded
}

function Invoke-AcerGet {
    param([uint16]$Code, [uint32]$Query)
    $reply = Send-AcerFrame -Code $Code -Arguments @(, (ConvertTo-U32Argument $Query)) -ReplySize 13
    return [BitConverter]::ToUInt64($reply, 5)
}

function Invoke-AcerSet {
    param([uint16]$Code, [uint64]$Value)
    $reply = Send-AcerFrame -Code $Code -Arguments @(, (ConvertTo-U64Argument $Value)) -ReplySize 9
    $returnCode = [BitConverter]::ToUInt32($reply, 5)
    if ($returnCode -ne 0) { throw "NitroSense service rejected command $Code (return code $returnCode)." }
}

function Invoke-AcerSet32 {
    param([uint16]$Code, [uint32]$Value)
    $reply = Send-AcerFrame -Code $Code -Arguments @(, (ConvertTo-U32Argument $Value)) -ReplySize 9
    $returnCode = [BitConverter]::ToUInt32($reply, 5)
    if ($returnCode -ne 0) { throw "NitroSense service rejected command $Code (return code $returnCode)." }
}

function Set-NitroSenseRegistry {
    param([string]$Key, [string]$Name, [uint32]$Value)
    $reply = Send-AcerFrame -Code 3 -ReplySize 9 -Arguments @(
        (ConvertTo-StringArgument "HKEY_LOCAL_MACHINE\$Key"),
        (ConvertTo-StringArgument $Name),
        (ConvertTo-U32Argument 4),
        (ConvertTo-U32Argument $Value)
    )
    $returnCode = [BitConverter]::ToUInt32($reply, 5)
    if ($returnCode -ne 0) { throw "Could not persist '$Name' (return code $returnCode)." }
}

function Get-NitroSenseRegistry {
    param([string]$Key, [string]$Name, [int]$Default = 0)
    try {
        return [int](Get-ItemProperty -Path "HKLM:\$Key" -Name $Name -ErrorAction Stop).$Name
    }
    catch { return $Default }
}


function Get-FanReading([uint32]$Index) {
    $value = Invoke-AcerGet -Code 13 -Query (1 -bor ($Index -shl 8))
    return [int](($value -shr 8) -band 0xFFFF)
}

function Get-FanTelemetry {
    [pscustomobject]@{
        CpuTemp = Get-FanReading 1
        CpuRpm  = Get-FanReading 2
        GpuTemp = Get-FanReading 10
        GpuRpm  = Get-FanReading 6
    }
}


function Get-FanState {
    $modeCode = Get-NitroSenseRegistry $script:FanKey 'CurrentFanMode'
    $mode = switch ($modeCode) {
        1 { 'max' }
        2 { 'custom' }
        default { 'auto' }
    }
    [pscustomobject]@{
        Mode    = $mode
        Percent = (Get-NitroSenseRegistry $script:FanKey 'CPUFanPercentage' 50)
        GpuPercent = (Get-NitroSenseRegistry $script:FanKey 'GPU1FanPercentage' 50)
        CpuManual = ((Get-NitroSenseRegistry $script:FanKey 'CPUFanCustomAuto' 1) -eq 0)
        GpuManual = ((Get-NitroSenseRegistry $script:FanKey 'GPU1FanCustomAuto' 1) -eq 0)
    }
}

function Test-FanApplied([string]$ExpectedMode) {
    $actual = (Get-FanState).Mode
    if ($actual -ne $ExpectedMode) {
        throw "The fan did not switch to '$ExpectedMode' (still '$actual'). NitroSense may have re-applied its own fan profile."
    }
}


function Set-FanAuto {
    Invoke-AcerSet -Code 15 -Value $script:BehaviorAuto
    Set-NitroSenseRegistry $script:FanKey 'CurrentFanMode' 0
    Test-FanApplied 'auto'
}

function Set-FanMax {
    Invoke-AcerSet -Code 15 -Value $script:BehaviorMax
    Set-NitroSenseRegistry $script:FanKey 'CurrentFanMode' 1
    Test-FanApplied 'max'
}

function Set-FanPercent {
    param(
        [Parameter(Mandatory)][int]$Cpu,
        [int]$Gpu = $Cpu
    )

    $Cpu = [Math]::Min($script:MaxPercent, [Math]::Max($script:MinPercent, [int]$Cpu))
    $Gpu = [Math]::Min($script:MaxPercent, [Math]::Max($script:MinPercent, [int]$Gpu))

    # custom mode: CPU manual (3), GPU manual (0xC0), both channels in the bitmap (9)
    $behavior = [uint64]9 -bor ([uint64]0xC3 -shl 16)
    Invoke-AcerSet -Code 15 -Value $behavior
    Invoke-AcerSet -Code 16 -Value ([uint64]1 -bor ([uint64]$Cpu -shl 8))
    Invoke-AcerSet -Code 16 -Value ([uint64]4 -bor ([uint64]$Gpu -shl 8))

    Set-NitroSenseRegistry $script:FanKey 'CurrentFanMode' 2
    Set-NitroSenseRegistry $script:FanKey 'CPUFanPercentage' $Cpu
    Set-NitroSenseRegistry $script:FanKey 'CPUFanCustomAuto' 0
    Set-NitroSenseRegistry $script:FanKey 'GPU1FanPercentage' $Gpu
    Set-NitroSenseRegistry $script:FanKey 'GPU1FanCustomAuto' 0

    Test-FanApplied 'custom'
    [pscustomobject]@{ Mode = 'custom'; Percent = $Cpu; GpuPercent = $Gpu }
}

function Step-Fan {
    param([Parameter(Mandatory)][int]$Delta)
    $state = Get-FanState
    $start = if ($state.Mode -eq 'custom') { [int]$state.Percent } else { 50 }
    Set-FanPercent -Cpu ($start + $Delta)
}


function Get-OperationMode {
    $value = Invoke-AcerGet -Code 34 -Query 11
    switch (($value -shr 8) -band 0xFF) {
        0 { 'quiet' }
        1 { 'default' }
        4 { 'performance' }
        default { 'unknown' }
    }
}

function Set-OperationMode {
    param([Parameter(Mandatory)][ValidateSet('quiet', 'default', 'performance')][string]$Mode)

    $code = switch ($Mode) { 'quiet' { 0 } 'default' { 1 } 'performance' { 4 } }

    # The vendor setter returns 0xFFFFFFFF for this command even on success, so
    # the return code is ignored and the live readback below is authoritative.
    Send-AcerFrame -Code 30 -Arguments @(, (ConvertTo-U32Argument $code)) -ReplySize 9 | Out-Null

    # the service applies the mode asynchronously; poll for confirmation
    $observed = 'unknown'
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $observed = Get-OperationMode
        if ($observed -eq $Mode) { break }
        Start-Sleep -Milliseconds 200
    }
    if ($observed -ne $Mode) {
        throw "The operation mode did not change to '$Mode' (still '$observed')."
    }

    Set-NitroSenseRegistry $script:ModeKey 'CurrentOperationMode' $code
    $Mode
}

function Format-FanStatus {
    $state = Get-FanState
    $telemetry = Get-FanTelemetry
    $mode = switch ($state.Mode) {
        'custom' { "custom $($state.Percent)% (GPU $($state.GpuPercent)%)" }
        'max'    { 'max' }
        default  { 'auto' }
    }
    "CPU {0,3} C / {1,4} RPM    GPU {2,3} C / {3,4} RPM    fan: {4}    system: {5}" -f `
        $telemetry.CpuTemp, $telemetry.CpuRpm, $telemetry.GpuTemp, $telemetry.GpuRpm,
        $mode, (Get-OperationMode)
}
