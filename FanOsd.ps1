#Requires -Version 5.1
<#
    FanOsd.ps1 - the confirmation panel, drawn inside the listener's own process

    The first version launched a whole PowerShell + WPF process for every
    keypress: about 1.5 s of latency and a 180 MB memory spike to show a
    one-second badge. This draws the panel on a layered window owned by the
    listener instead, so a press costs a few milliseconds and no extra process.

    Per-pixel alpha via UpdateLayeredWindow keeps the rounded corners smooth and
    the panel translucent, matching the old WPF look.
#>
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class FanOsd
{
    private static Overlay current;

    // Creates the window up front so the first keypress is not the one that
    // pays for handle creation.
    public static void Prepare()
    {
        if (current == null)
        {
            current = new Overlay();
            IntPtr unused = current.Handle;
        }
    }

    public static void Show(string text)
    {
        Show(text, 1100);
    }

    public static void Show(string text, int milliseconds)
    {
        if (current == null) current = new Overlay();
        current.Present(text, milliseconds);
    }

    private sealed class Overlay : Form
    {
        private readonly Timer hideTimer;
        private readonly Font font;

        public Overlay()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            BackColor = Color.Black;
            Size = new Size(210, 62);

            font = new Font("Segoe UI Semibold", 18f, FontStyle.Regular, GraphicsUnit.Point);

            hideTimer = new Timer();
            hideTimer.Interval = 1100;
            hideTimer.Tick += OnHideTick;
        }

        // Clicks and key focus must never go to the panel.
        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW  (no taskbar button)
                cp.ExStyle |= 0x00080000; // WS_EX_LAYERED    (per-pixel alpha)
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE (never steals focus)
                return cp;
            }
        }

        // The layered window is painted entirely through UpdateLayeredWindow.
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e) { }

        private void OnHideTick(object sender, EventArgs e)
        {
            hideTimer.Stop();
            Hide();
        }

        public void Present(string text, int milliseconds)
        {
            Rectangle area = Screen.FromPoint(System.Windows.Forms.Cursor.Position).WorkingArea;
            Location = new Point(area.Right - Width - 28, area.Bottom - Height - 42);

            if (!Visible) Show();
            Render(text);

            hideTimer.Stop();
            hideTimer.Interval = milliseconds;
            hideTimer.Start();
        }

        private void Render(string text)
        {
            using (Bitmap bitmap = new Bitmap(Width, Height, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bitmap))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.TextRenderingHint = TextRenderingHint.AntiAlias;
                    g.Clear(Color.Transparent);

                    RectangleF bounds = new RectangleF(0.5f, 0.5f, Width - 1f, Height - 1f);
                    using (GraphicsPath path = RoundedRect(bounds, 14f))
                    {
                        using (SolidBrush fill = new SolidBrush(Color.FromArgb(232, 22, 22, 24)))
                        {
                            g.FillPath(fill, path);
                        }
                        using (Pen border = new Pen(Color.FromArgb(70, 255, 255, 255), 1f))
                        {
                            g.DrawPath(border, path);
                        }
                    }

                    using (StringFormat format = new StringFormat())
                    {
                        format.Alignment = StringAlignment.Center;
                        format.LineAlignment = StringAlignment.Center;
                        g.DrawString(text, font, Brushes.White,
                                     new RectangleF(0, 0, Width, Height), format);
                    }
                }

                // UpdateLayeredWindow wants premultiplied alpha; 32bppPArgb
                // makes GDI+ do that conversion when we draw into it.
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

        private void Apply(Bitmap bitmap)
        {
            IntPtr screenDc = GetDC(IntPtr.Zero);
            IntPtr memoryDc = CreateCompatibleDC(screenDc);
            IntPtr hBitmap = bitmap.GetHbitmap(Color.FromArgb(0));
            IntPtr previous = SelectObject(memoryDc, hBitmap);

            POINT destination = new POINT();
            destination.x = Left;
            destination.y = Top;

            SIZE size = new SIZE();
            size.cx = bitmap.Width;
            size.cy = bitmap.Height;

            POINT source = new POINT();

            BLENDFUNCTION blend = new BLENDFUNCTION();
            blend.BlendOp = 0;                  // AC_SRC_OVER
            blend.SourceConstantAlpha = 255;
            blend.AlphaFormat = 1;              // AC_SRC_ALPHA

            UpdateLayeredWindow(Handle, screenDc, ref destination, ref size,
                                memoryDc, ref source, 0, ref blend, 2);

            SelectObject(memoryDc, previous);
            DeleteObject(hBitmap);
            DeleteDC(memoryDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }

        private static GraphicsPath RoundedRect(RectangleF bounds, float radius)
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

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int x; public int y; }

        [StructLayout(LayoutKind.Sequential)]
        private struct SIZE { public int cx; public int cy; }

        [StructLayout(LayoutKind.Sequential)]
        private struct BLENDFUNCTION
        {
            public byte BlendOp;
            public byte BlendFlags;
            public byte SourceConstantAlpha;
            public byte AlphaFormat;
        }

        [DllImport("user32.dll")]
        private static extern IntPtr GetDC(IntPtr window);

        [DllImport("user32.dll")]
        private static extern int ReleaseDC(IntPtr window, IntPtr dc);

        [DllImport("gdi32.dll")]
        private static extern IntPtr CreateCompatibleDC(IntPtr dc);

        [DllImport("gdi32.dll")]
        private static extern bool DeleteDC(IntPtr dc);

        [DllImport("gdi32.dll")]
        private static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);

        [DllImport("gdi32.dll")]
        private static extern bool DeleteObject(IntPtr obj);

        [DllImport("user32.dll")]
        private static extern bool UpdateLayeredWindow(IntPtr window, IntPtr destinationDc,
            ref POINT destination, ref SIZE size, IntPtr sourceDc, ref POINT source,
            int colorKey, ref BLENDFUNCTION blend, int flags);
    }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing
