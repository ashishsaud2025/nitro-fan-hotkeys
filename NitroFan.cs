using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// NitroFan - compiled replacement for fan-hotkeys.ps1 + FanCore.ps1 + FanOsd.ps1
//
// Global hotkeys for Acer Nitro fan speed and performance mode, talking directly
// to the NitroSense service pipe. Runs hidden from a scheduled task at logon,
// no administrator rights, no PowerShell in the background.
//
// Build: csc.exe /out:NitroFan.exe /target:winexe NitroFan.cs

static class NitroFan
{

    const string PipeName = "PredatorSense_service_namedpipe";
    const ulong BehaviorAuto = 0x410009;
    const ulong BehaviorMax = 0x820009;
    const string FanRegKey = @"SOFTWARE\OEM\NitroSense\FanControl";
    const string ModeRegKey = @"SOFTWARE\OEM\NitroSense\Overclock";
    const int MinPercent = 20;
    const int MaxPercent = 100;


    const int WM_HOTKEY = 0x0312;
    const uint MOD_ALT = 0x0001;
    const uint MOD_CONTROL = 0x0002;
    const uint MOD_SHIFT = 0x0004;
    const uint MOD_NOREPEAT = 0x4000;

    static readonly Binding[] Bindings = new[]
    {
        new Binding(1, 0x26, "up"),          // VK_UP
        new Binding(2, 0x28, "down"),        // VK_DOWN
        new Binding(3, 0x30, "auto"),        // '0'
        new Binding(4, 0x39, "max"),         // '9'
        new Binding(5, 0x31, "quiet"),       // '1'
        new Binding(6, 0x32, "default"),     // '2'
        new Binding(7, 0x33, "performance"), // '3'
    };

    sealed class Binding
    {
        public int Id;
        public uint Vk;
        public string Name;
        public Binding(int id, uint vk, string name) { Id = id; Vk = vk; Name = name; }
    }


    static readonly Mutex SingleInstance = new Mutex(false, @"Local\NitroFanHotkeys");
    static string LogFile;
    static string StateDir;
    static HotkeyWindow Window;
    static OverlayForm Overlay;

    [STAThread]
    static int Main()
    {
        if (!SingleInstance.WaitOne(0))
        {
            Log("Another listener is already running; exiting.");
            return 0;
        }

        StateDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FanHotkeys");
        Directory.CreateDirectory(StateDir);
        LogFile = Path.Combine(StateDir, "hotkeys.log");

        Application.EnableVisualStyles();
        Window = new HotkeyWindow();

        int registered = 0;
        foreach (var b in Bindings)
        {
            uint modifiers = MOD_CONTROL | MOD_ALT | MOD_NOREPEAT;
            bool ok = NativeMethods.RegisterHotKey(Window.Handle, b.Id, modifiers, b.Vk);
            if (!ok)
            {
                int err = Marshal.GetLastWin32Error();
                modifiers = MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT;
                ok = NativeMethods.RegisterHotKey(Window.Handle, b.Id, modifiers, b.Vk);
                if (ok)
                    Log("WARNING: Ctrl+Alt+" + b.Name + " unavailable (error " + err + "); using Ctrl+Alt+Shift instead.");
                else
                    Log("ERROR: could not register hotkey '" + b.Name + "' (error " + err + ").");
            }
            if (ok) registered++;
        }

        if (registered == 0)
        {
            Log("ERROR: no hotkeys could be registered; exiting.");
            return 1;
        }

        Log("Hotkey listener started (" + registered + " registered).");

        Window.HotkeyPressed += id =>
        {
            try
            {
                switch (id)
                {
                    case 1:
                        {
                            int r = StepFan(10);
                            ShowOsd("Fan " + r + "%");
                            Log("Ctrl+Alt+Up -> custom " + r + "%");
                            break;
                        }
                    case 2:
                        {
                            int r = StepFan(-10);
                            ShowOsd("Fan " + r + "%");
                            Log("Ctrl+Alt+Down -> custom " + r + "%");
                            break;
                        }
                    case 3:
                        SetFanAuto();
                        ShowOsd("Fan Auto");
                        Log("Ctrl+Alt+0 -> auto");
                        break;
                    case 4:
                        SetFanMax();
                        ShowOsd("Fan Max");
                        Log("Ctrl+Alt+9 -> max");
                        break;
                    case 5:
                        SetOperationMode("quiet");
                        ShowOsd("Quiet");
                        Log("Ctrl+Alt+1 -> quiet");
                        break;
                    case 6:
                        SetOperationMode("default");
                        ShowOsd("Default");
                        Log("Ctrl+Alt+2 -> default");
                        break;
                    case 7:
                        SetOperationMode("performance");
                        ShowOsd("Performance");
                        Log("Ctrl+Alt+3 -> performance");
                        break;
                }
            }
            catch (Exception ex)
            {
                ShowOsd("Fan error");
                Log("ERROR on hotkey " + id + ": " + ex.Message);
            }
        };

        Application.Run();
        return 0;
    }


    static byte[] SendFrame(ushort code, byte[][] arguments, int replySize)
    {
        using (var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut))
        {
            pipe.Connect(2000);

            using (var ms = new MemoryStream())
            {
                using (var writer = new BinaryWriter(ms))
                {
                    writer.Write(code);
                    writer.Write((byte)arguments.Length);
                    foreach (var arg in arguments)
                    {
                        writer.Write((uint)arg.Length);
                        writer.Write(arg);
                    }
                    writer.Flush();
                }
                var message = ms.ToArray();
                pipe.Write(message, 0, message.Length);
                pipe.Flush();
            }

            var reply = new byte[replySize];
            int received = 0;
            var deadline = DateTime.UtcNow.AddMilliseconds(1500);
            while (received < replySize && DateTime.UtcNow < deadline)
            {
                if (!pipe.IsConnected) break;
                var chunk = new byte[replySize - received];
                int read = pipe.Read(chunk, 0, chunk.Length);
                if (read > 0)
                {
                    Array.Copy(chunk, 0, reply, received, read);
                    received += read;
                }
                else
                {
                    Thread.Sleep(20);
                }
            }
            if (received < replySize)
                throw new IOException("NitroSense service did not answer command " + code +
                    " (got " + received + " of " + replySize + " bytes).");
            return reply;
        }
    }

    static byte[] U32(uint v) { return BitConverter.GetBytes(v); }
    static byte[] U64(ulong v) { return BitConverter.GetBytes(v); }
    static byte[] Str(string v)
    {
        var bytes = Encoding.Unicode.GetBytes(v);
        var padded = new byte[bytes.Length + 2]; // trailing UTF-16 NUL
        Array.Copy(bytes, padded, bytes.Length);
        return padded;
    }

    static ulong GetU64(ushort code, uint query)
    {
        var reply = SendFrame(code, new byte[][] { U32(query) }, 13);
        return BitConverter.ToUInt64(reply, 5);
    }

    static void SetU64(ushort code, ulong value)
    {
        var reply = SendFrame(code, new byte[][] { U64(value) }, 9);
        uint rc = BitConverter.ToUInt32(reply, 5);
        if (rc != 0)
            throw new IOException("NitroSense service rejected command " + code +
                " (return code " + rc + ").");
    }

    static void SetU32(ushort code, uint value)
    {
        var reply = SendFrame(code, new byte[][] { U32(value) }, 9);
        uint rc = BitConverter.ToUInt32(reply, 5);
        if (rc != 0)
            throw new IOException("NitroSense service rejected command " + code +
                " (return code " + rc + ").");
    }

    static void PersistReg(string key, string name, uint value)
    {
        var reply = SendFrame(3, new byte[][]
            { Str(@"HKEY_LOCAL_MACHINE\" + key), Str(name), U32(4), U32(value) }, 9);
        uint rc = BitConverter.ToUInt32(reply, 5);
        if (rc != 0)
            throw new IOException("Could not persist '" + name + "' (return code " + rc + ").");
    }

    static int ReadReg(string key, string name, int defaultValue)
    {
        try
        {
            using (var rk = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(key))
            {
                if (rk == null) return defaultValue;
                var v = rk.GetValue(name, defaultValue);
                return v == null ? defaultValue : Convert.ToInt32(v);
            }
        }
        catch { return defaultValue; }
    }


    static int ReadFan(uint index)
    {
        ulong value = GetU64(13, (uint)(1 | (index << 8)));
        return (int)((value >> 8) & 0xFFFF);
    }

    static void GetTelemetry(out int cpuTemp, out int cpuRpm, out int gpuTemp, out int gpuRpm)
    {
        cpuTemp = ReadFan(1);
        cpuRpm = ReadFan(2);
        gpuTemp = ReadFan(10);
        gpuRpm = ReadFan(6);
    }


    static void GetFanState(out string mode, out int percent, out int gpuPercent)
    {
        int modeCode = ReadReg(FanRegKey, "CurrentFanMode", 0);
        if (modeCode == 1) mode = "max";
        else if (modeCode == 2) mode = "custom";
        else mode = "auto";
        percent = ReadReg(FanRegKey, "CPUFanPercentage", 50);
        gpuPercent = ReadReg(FanRegKey, "GPU1FanPercentage", 50);
    }

    static void TestFanApplied(string expectedMode)
    {
        string actual;
        int dummy1, dummy2;
        GetFanState(out actual, out dummy1, out dummy2);
        if (actual != expectedMode)
            throw new IOException("The fan did not switch to '" + expectedMode + "' (still '" +
                actual + "'). NitroSense may have re-applied its own fan profile.");
    }


    static void SetFanAuto()
    {
        SetU64(15, BehaviorAuto);
        PersistReg(FanRegKey, "CurrentFanMode", 0);
        TestFanApplied("auto");
    }

    static void SetFanMax()
    {
        SetU64(15, BehaviorMax);
        PersistReg(FanRegKey, "CurrentFanMode", 1);
        TestFanApplied("max");
    }

    static void SetFanPercent(int cpu, int gpu)
    {
        cpu = Math.Min(MaxPercent, Math.Max(MinPercent, cpu));
        gpu = Math.Min(MaxPercent, Math.Max(MinPercent, gpu));

        ulong behavior = 9 | ((ulong)0xC3 << 16);
        SetU64(15, behavior);
        SetU64(16, (ulong)(1 | (cpu << 8)));
        SetU64(16, (ulong)(4 | (gpu << 8)));

        PersistReg(FanRegKey, "CurrentFanMode", 2);
        PersistReg(FanRegKey, "CPUFanPercentage", (uint)cpu);
        PersistReg(FanRegKey, "CPUFanCustomAuto", 0);
        PersistReg(FanRegKey, "GPU1FanPercentage", (uint)gpu);
        PersistReg(FanRegKey, "GPU1FanCustomAuto", 0);

        TestFanApplied("custom");
    }

    static int StepFan(int delta)
    {
        string mode;
        int percent, gpuPercent;
        GetFanState(out mode, out percent, out gpuPercent);
        int start = mode == "custom" ? percent : 50;
        SetFanPercent(start + delta, start + delta);
        GetFanState(out mode, out percent, out gpuPercent);
        return percent;
    }


    static string GetOperationMode()
    {
        ulong value = GetU64(34, 11);
        int code = (int)((value >> 8) & 0xFF);
        if (code == 0) return "quiet";
        if (code == 1) return "default";
        if (code == 4) return "performance";
        return "unknown";
    }

    static void SetOperationMode(string mode)
    {
        int code;
        if (mode == "quiet") code = 0;
        else if (mode == "default") code = 1;
        else if (mode == "performance") code = 4;
        else throw new ArgumentException("Unknown mode: " + mode);

        // vendor setter returns 0xFFFFFFFF even on success; ignore return code
        SendFrame(30, new byte[][] { U32((uint)code) }, 9);

        string observed = "unknown";
        for (int attempt = 0; attempt < 10; attempt++)
        {
            observed = GetOperationMode();
            if (observed == mode) break;
            Thread.Sleep(200);
        }
        if (observed != mode)
            throw new IOException("The operation mode did not change to '" + mode +
                "' (still '" + observed + ").");

        PersistReg(ModeRegKey, "CurrentOperationMode", (uint)code);
    }


    static void Log(string message)
    {
        try
        {
            if (File.Exists(LogFile) && new FileInfo(LogFile).Length > 200 * 1024)
                File.Move(LogFile, LogFile + ".old");
            File.AppendAllText(LogFile,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine);
        }
        catch { }
    }


    static void ShowOsd(string text)
    {
        try
        {
            if (Overlay == null) Overlay = new OverlayForm();
            Overlay.Present(text, 1100);
        }
        catch { }
    }


    sealed class HotkeyWindow : NativeWindow
    {
        public event Action<int> HotkeyPressed;

        public HotkeyWindow()
        {
            CreateHandle(new CreateParams());
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY)
            {
                Action<int> handler = HotkeyPressed;
                if (handler != null) handler(m.WParam.ToInt32());
                return;
            }
            base.WndProc(ref m);
        }
    }


    sealed class OverlayForm : Form
    {
        readonly System.Windows.Forms.Timer hideTimer;
        readonly Font font;

        public OverlayForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            BackColor = Color.Black;
            Size = new Size(210, 62);

            font = new Font("Segoe UI Semibold", 18f, FontStyle.Regular, GraphicsUnit.Point);

            hideTimer = new System.Windows.Forms.Timer();
            hideTimer.Interval = 1100;
            hideTimer.Tick += (s, e) => { hideTimer.Stop(); Hide(); };
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                cp.ExStyle |= 0x00080000; // WS_EX_LAYERED
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                return cp;
            }
        }

        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e) { }

        public void Present(string text, int milliseconds)
        {
            Rectangle area = Screen.FromPoint(Cursor.Position).WorkingArea;
            Location = new Point(area.Right - Width - 28, area.Bottom - Height - 42);

            if (!Visible) Show();
            Render(text);

            hideTimer.Stop();
            hideTimer.Interval = milliseconds;
            hideTimer.Start();
        }

        void Render(string text)
        {
            using (Bitmap bitmap = new Bitmap(Width, Height, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bitmap))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
                    g.Clear(Color.Transparent);

                    RectangleF bounds = new RectangleF(0.5f, 0.5f, Width - 1f, Height - 1f);
                    using (GraphicsPath path = RoundedRect(bounds, 14f))
                    {
                        using (SolidBrush fill = new SolidBrush(Color.FromArgb(232, 22, 22, 24)))
                            g.FillPath(fill, path);
                        using (Pen border = new Pen(Color.FromArgb(70, 255, 255, 255), 1f))
                            g.DrawPath(border, path);
                    }

                    using (StringFormat format = new StringFormat())
                    {
                        format.Alignment = StringAlignment.Center;
                        format.LineAlignment = StringAlignment.Center;
                        g.DrawString(text, font, Brushes.White,
                            new RectangleF(0, 0, Width, Height), format);
                    }
                }

                using (Bitmap premultiplied = new Bitmap(Width, Height, PixelFormat.Format32bppPArgb))
                {
                    using (Graphics g = Graphics.FromImage(premultiplied))
                    {
                        g.CompositingMode = CompositingMode.SourceCopy;
                        g.DrawImage(bitmap, 0, 0, Width, Height);
                    }
                    Apply(premultiplied);
                }
            }
        }

        void Apply(Bitmap bitmap)
        {
            IntPtr screenDc = NativeMethods.GetDC(IntPtr.Zero);
            IntPtr memoryDc = NativeMethods.CreateCompatibleDC(screenDc);
            IntPtr hBitmap = bitmap.GetHbitmap(Color.FromArgb(0));
            IntPtr previous = NativeMethods.SelectObject(memoryDc, hBitmap);

            Point destination = new Point();
            NativeMethods.SIZE size = new NativeMethods.SIZE { cx = bitmap.Width, cy = bitmap.Height };
            Point source = new Point();
            NativeMethods.BLENDFUNCTION blend = new NativeMethods.BLENDFUNCTION
            {
                BlendOp = 0,
                SourceConstantAlpha = 255,
                AlphaFormat = 1
            };

            NativeMethods.UpdateLayeredWindow(Handle, screenDc, ref destination, ref size,
                memoryDc, ref source, 0, ref blend, 2);

            NativeMethods.SelectObject(memoryDc, previous);
            NativeMethods.DeleteObject(hBitmap);
            NativeMethods.DeleteDC(memoryDc);
            NativeMethods.ReleaseDC(IntPtr.Zero, screenDc);
        }

        static GraphicsPath RoundedRect(RectangleF bounds, float radius)
        {
            float diameter = radius * 2f;
            GraphicsPath path = new GraphicsPath();
            path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180f, 90f);
            path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270f, 90f);
            path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0f, 90f);
            path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90f, 90f);
            path.CloseFigure();
            return path;
        }
    }


    static class NativeMethods
    {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

        [DllImport("user32.dll")]
        public static extern IntPtr GetDC(IntPtr window);

        [DllImport("user32.dll")]
        public static extern int ReleaseDC(IntPtr window, IntPtr dc);

        [DllImport("gdi32.dll")]
        public static extern IntPtr CreateCompatibleDC(IntPtr dc);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteDC(IntPtr dc);

        [DllImport("gdi32.dll")]
        public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteObject(IntPtr obj);

        [DllImport("user32.dll")]
        public static extern bool UpdateLayeredWindow(IntPtr window, IntPtr destinationDc,
            ref Point destination, ref SIZE size, IntPtr sourceDc, ref Point source,
            int colorKey, ref BLENDFUNCTION blend, int flags);

        [StructLayout(LayoutKind.Sequential)]
        public struct SIZE { public int cx; public int cy; }

        [StructLayout(LayoutKind.Sequential)]
        public struct BLENDFUNCTION
        {
            public byte BlendOp;
            public byte BlendFlags;
            public byte SourceConstantAlpha;
            public byte AlphaFormat;
        }
    }
}
