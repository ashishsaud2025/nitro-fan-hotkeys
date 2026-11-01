# Nitro fan hotkeys

Global keyboard shortcuts for fan speed and performance mode on an Acer Nitro,
without opening NitroSense. Works by sending the same commands to the
NitroSense background service (`PSSvc`) that the NitroSense window sends, and
mirroring the result into NitroSense's registry state so the app shows the
right values the next time it starts.

Tested on **Nitro AN515-58**, NitroSense Service 3.01.3052, Windows 11.
No administrator rights are needed at any point.

## Shortcuts

| Keys | Effect |
| --- | --- |
| `Ctrl + Alt + Up` | fan speed +10 (starts at 50 when coming from Auto/Max) |
| `Ctrl + Alt + Down` | fan speed -10 |
| `Ctrl + Alt + 0` | Auto - back to Acer's own curve |
| `Ctrl + Alt + 9` | Max |
| `Ctrl + Alt + 1` | Quiet performance mode |
| `Ctrl + Alt + 2` | Default performance mode |
| `Ctrl + Alt + 3` | Performance mode |
| `Ctrl + Alt + Numpad8` | fan speed +10 |
| `Ctrl + Alt + Numpad0` | Auto - back to Acer's own curve |
| `Ctrl + Alt + Numpad9` | Max |
| `Ctrl + Alt + Numpad1` | Quiet performance mode |
| `Ctrl + Alt + Numpad2` | Default performance mode |
| `Ctrl + Alt + Numpad3` | Performance mode |

Fan range is 20-100%. The performance modes are the same Quiet / Default /
Performance presets as in NitroSense's Mode panel; they change CPU and GPU power
limits and leave the fan setting alone. Every press shows a small panel in the
bottom-right corner.

## Command line

```powershell
.\fanctl.ps1 status        # temperatures, RPM, fan mode, system mode
.\fanctl.ps1 auto
.\fanctl.ps1 max
.\fanctl.ps1 set 70        # CPU and GPU
.\fanctl.ps1 set 70 50     # CPU 70, GPU 50
.\fanctl.ps1 step 10
.\fanctl.ps1 quiet
.\fanctl.ps1 default
.\fanctl.ps1 performance
```

## Install / remove

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

`install.ps1` registers a per-user scheduled task called **Nitro Fan Hotkeys**
that starts the listener (hidden) at logon. Uninstalling also sets the fans
back to Auto.

The listener can also be started ad hoc by launching `NitroFan.exe` directly -
it is a single instance, so a second copy exits immediately.

## Files

| File | Purpose |
| --- | --- |
| `NitroFan.cs` | source for the compiled hotkey listener + OSD (global hotkeys, pipe client, panel) |
| `NitroFan.exe` | the compiled listener (built with `csc.exe` - do not edit by hand) |
| `FanCore.ps1` | pipe protocol + fan/action functions used by the CLI |
| `fanctl.ps1` | command line front end |
| `install.ps1` | creates/removes the logon task |
| `hotkeys.log` | one line per press, plus errors |

## Build the listener

The background listener is compiled to `NitroFan.exe` (no PowerShell required):

```
C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe ^
  /out:NitroFan.exe ^
  /target:winexe ^
  /reference:System.dll ^
  /reference:System.Drawing.dll ^
  /reference:System.Windows.Forms.dll ^
  NitroFan.cs
```

Then run `install.ps1` to start the scheduled task that runs the `.exe`.

## Troubleshooting

**Nothing happens on the hotkeys** - check `hotkeys.log`. If it says
`could not register hotkey`, another program owns the combination. If the file
does not exist, the listener is not running: start it or re-run `install.ps1`.

**"Fan error" panel** - the service refused the command. Check `hotkeys.log` for
the reason, then try again; if NitroSense has just re-applied its own profile,
the write is simply retried on the next press.

**Shortcuts use Ctrl+Alt+Shift instead of Ctrl+Alt** - some Intel graphics
drivers claim `Ctrl+Alt+Arrow` for screen rotation. The listener falls back
automatically and logs which combination it got.

**Fan speed snaps back** - NitroSense re-applies its own profile when you open
the window or switch performance modes. Set the speed again after that, or
leave NitroSense closed.

**NitroSense still shows "Auto" after a hotkey** - expected. The window reads
its state once at startup and never re-reads it; not on focus, not on tab
switch, not when another program changes the fan. The RPM numbers are live, and
the setting itself is applied, but the Auto/Max/Custom selector stays where it
was. Close and reopen NitroSense and it will show the correct mode and slider
position, because the registry state is kept in sync. The same applies to the
Quiet/Default/Performance buttons.

## How it works

```
pipe  \\.\pipe\PredatorSense_service_namedpipe
frame u16 command, u8 argument count, then per argument u32 length + bytes
reply 9 bytes (u32) or 13 bytes (u64), payload at byte 5, 0 = success

cmd 13  telemetry        arg u32  1 | (index << 8)
                         1 CPU temp, 2 CPU RPM, 6 GPU RPM, 10 GPU temp
cmd 15  fan behavior     arg u64  0x410009 auto, 0x820009 max
                         custom = 9 | ((cpuValue | gpuFlag) << 16)
                         cpuValue 1 auto / 3 manual, gpuFlag 0x40 auto / 0xC0 manual
cmd 16  manual speed     arg u64  selector | (percent << 8), 1 = CPU, 4 = GPU
cmd 3   persist a value  args path, name, type 4, value
                         HKLM\SOFTWARE\OEM\NitroSense\FanControl
cmd 30  operation mode   arg u32  0 quiet, 1 default, 4 performance
                         returns 0xFFFFFFFF even on success, so it is verified
                         with cmd 34 and persisted as CurrentOperationMode under
                         HKLM\SOFTWARE\OEM\NitroSense\Overclock
cmd 34  mode readback    arg u32  11, mode = (value >> 8) & 0xFF
```

The protocol was confirmed against this laptop and cross-checked with the
reverse-engineering notes of the open-source RESense project.

## License

Apache License 2.0 - see [LICENSE](LICENSE). You may use, modify and
redistribute this code, including commercially, provided the license text and
the attribution notices in [NOTICE](NOTICE) stay with it.

## Credits

- [RESense](https://github.com/mdonmez/RESense) (Apache-2.0) - the fan command
  encoding, telemetry query layout and NitroSense registry synchronisation used
  here were derived from that project, then verified independently on this
  laptop.
- [acer-aspire-fan-control](https://github.com/vicentetob/acer-aspire-fan-control)
  (MIT) - background on the Acer fan interface. No code from it is included.

## Disclaimer

Unofficial project. Not affiliated with, endorsed by, or supported by Acer Inc.
Acer, Nitro, NitroSense and Predator are trademarks of Acer Inc.

Fan control can raise temperatures, noise and fan wear. Running fans at 100%
continuously wears the bearings faster than the stock curve does. Use at your
own risk; the software is provided without warranty of any kind.

