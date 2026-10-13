using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public class BrightnessWheel
{
    // ================= 配置（由 PowerShell 注入） =================
    public static int StepPercent = 3;
    public static int FineStepPercent = 1;
    public static int MinPercent = 0;
    public static int MaxPercent = 100;
    public static bool ReqCtrl = true;
    public static bool ReqAlt = true;
    public static int OsdHoldMs = 1300;
    public static bool OsdEnabled = true;
    public static bool UseTrayIcon = true;
    public static string LogPath = "";

    // ================= 日志 =================
    static void Log(string msg)
    {
        if (LogPath == null || LogPath.Length == 0) return;
        try
        {
            System.IO.File.AppendAllText(LogPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + msg + Environment.NewLine);
        }
        catch { }
    }

    // ================= 状态 =================
    class Mon
    {
        public IntPtr Handle;
        public uint Min;
        public uint Max;
        public uint Cur;
        public string Name;
        public int Mode;      // 0 = 传统 API（Get/SetMonitorBrightness），1 = VCP 0x10（MCCS）
    }

    static readonly object Gate = new object();
    static readonly AutoResetEvent Wake = new AutoResetEvent(false);
    static List<Mon> monitors = new List<Mon>();
    static List<Mon> found;
    static int targetPct = -1;
    static bool dirty;
    static string lastError = "";
    static OsdForm osd;
    static NotifyIcon tray;
    static IntPtr hookHandle = IntPtr.Zero;
    static HookProc hookProc;                 // 必须保持强引用，否则委托被 GC 回收
    static readonly MonitorEnumProc enumProc = EnumCallback;
    static Mutex singleton;
    // 控制通道：-1 自动（优先传统 API，不可用则退回 VCP 0x10）、0 只用传统、1 只用 VCP
    // 可用环境变量 BRIGHTNESS_TOOL_VCP_MODE=vcp|legacy 强制，便于在别的机器上排查
    static int ForceMode = -1;

    // ================= Win32 : 鼠标钩子 =================
    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
    delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprcMonitor, IntPtr dwData);

    const int WH_MOUSE_LL = 14;
    const int WM_MOUSEWHEEL = 0x020A;
    const int HealthCheckMs = 15000;
    const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12;
    const int VK_LWIN = 0x5B, VK_RWIN = 0x5C;

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vKey);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibrary(string lpFileName);

    // ================= Win32 : DDC/CI =================
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint size, [Out] PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint cur, out uint max);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool SetMonitorBrightness(IntPtr h, uint value);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint cur, out uint max);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool DestroyPhysicalMonitors(uint size, [In] PHYSICAL_MONITOR[] arr);

    // ================= 显示器枚举 =================
    static bool EnumCallback(IntPtr hMonitor, IntPtr hdc, IntPtr lprc, IntPtr data)
    {
        uint n = 0;
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMonitor, out n) || n == 0) return true;
        PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
        if (!GetPhysicalMonitorsFromHMONITOR(hMonitor, n, arr)) return true;
        for (int i = 0; i < n; i++)
        {
            Mon m = MakeMon(arr[i]);
            if (m != null) found.Add(m);
            else DestroyPhysicalMonitors(1, new PHYSICAL_MONITOR[] { arr[i] });
        }
        return true;
    }

    // 两种控制通道二选一：优先传统 API，不支持时退回 VCP 0x10（MCCS 标准亮度指令）
    static Mon MakeMon(PHYSICAL_MONITOR pm)
    {
        uint min = 0, cur = 0, max = 0;
        if (ForceMode != 1 && GetMonitorBrightness(pm.hPhysicalMonitor, out min, out cur, out max) && max > min)
        {
            Mon m = new Mon();
            m.Handle = pm.hPhysicalMonitor;
            m.Min = min; m.Max = max; m.Cur = cur; m.Mode = 0;
            m.Name = pm.szPhysicalMonitorDescription;
            return m;
        }
        if (ForceMode != 0)
        {
            uint type = 0, vcur = 0, vmax = 0;
            if (GetVCPFeatureAndVCPFeatureReply(pm.hPhysicalMonitor, 0x10, out type, out vcur, out vmax) && vmax > 0)
            {
                Mon m = new Mon();
                m.Handle = pm.hPhysicalMonitor;
                m.Min = 0; m.Max = vmax; m.Cur = vcur; m.Mode = 1;
                m.Name = pm.szPhysicalMonitorDescription;
                return m;
            }
        }
        return null;
    }

    // 按该显示器实际使用的通道读取亮度
    static bool ReadMon(Mon m, out uint min, out uint cur, out uint max)
    {
        min = 0;
        if (m.Mode == 1)
        {
            uint type = 0;
            return GetVCPFeatureAndVCPFeatureReply(m.Handle, 0x10, out type, out cur, out max);
        }
        return GetMonitorBrightness(m.Handle, out min, out cur, out max);
    }

    static void RefreshMonitors()
    {
        List<Mon> old = monitors;
        found = new List<Mon>();
        try { EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, enumProc, IntPtr.Zero); }
        catch { }
        monitors = found;
        foreach (Mon m in old)
        {
            bool keep = false;
            foreach (Mon n in monitors) if (n.Handle == m.Handle) keep = true;
            if (!keep)
            {
                PHYSICAL_MONITOR pm = new PHYSICAL_MONITOR();
                pm.hPhysicalMonitor = m.Handle;
                DestroyPhysicalMonitors(1, new PHYSICAL_MONITOR[] { pm });
            }
        }
    }

    static uint ToRaw(Mon m, int pct)
    {
        if (pct < MinPercent) pct = MinPercent;
        if (pct > MaxPercent) pct = MaxPercent;
        double v = m.Min + (m.Max - m.Min) * (pct / 100.0);
        return (uint)Math.Round(v);
    }

    static bool ApplyOnce(int pct)
    {
        bool any = false;
        foreach (Mon m in monitors)
        {
            try
            {
                uint raw = ToRaw(m, pct);
                bool wrote = (m.Mode == 1) ? SetVCPFeature(m.Handle, 0x10, raw) : SetMonitorBrightness(m.Handle, raw);
                if (wrote) { any = true; m.Cur = raw; }
            }
            catch { }
        }
        return any;
    }

    // dxva2 在失效句柄上的写入会「假成功」，所以必须读回确认
    static bool VerifyOnce(int pct)
    {
        int good = 0, bad = 0;
        foreach (Mon m in monitors)
        {
            uint min = 0, cur = 0, max = 0;
            bool ok = false;
            try { ok = ReadMon(m, out min, out cur, out max); }
            catch { }
            if (!ok) continue;                 // 读取偶发失败：当作未知，不据此判定失败
            m.Cur = cur;
            if (Math.Abs((long)cur - (long)ToRaw(m, pct)) <= 1) good++; else bad++;
        }
        return bad == 0 && good > 0;
    }

    static bool ApplyAll(int pct)
    {
        if (monitors.Count == 0) RefreshMonitors();
        if (monitors.Count == 0) { lastError = "未检测到支持 DDC/CI 的显示器"; return false; }

        bool ok = ApplyOnce(pct) && VerifyOnce(pct);
        if (!ok)
        {
            // 睡眠唤醒 / 分辨率或 HDR 切换后旧句柄会失效，重建句柄再试一次
            Log("写入未生效 pct=" + pct + "，重建 DDC 句柄后重试");
            RefreshMonitors();
            if (monitors.Count == 0) { lastError = "未检测到支持 DDC/CI 的显示器"; return false; }
            ok = ApplyOnce(pct) && VerifyOnce(pct);
        }
        return ok;
    }

    // 空闲健康检查：句柄失效就重建；设备值被别的途径改过就同步内部基准
    static void IdleCheck()
    {
        try
        {
            lock (Gate) { if (dirty) return; }

            int devPct = -1;
            bool readOk = false;
            foreach (Mon m in monitors)
            {
                uint min = 0, cur = 0, max = 0;
                if (ReadMon(m, out min, out cur, out max) && max > min)
                {
                    m.Cur = cur;
                    devPct = (int)Math.Round((cur - min) * 100.0 / (max - min));
                    readOk = true;
                    break;
                }
            }
            if (!readOk)
            {
                Log("空闲检查：句柄已失效，重建");
                RefreshMonitors();
                if (monitors.Count > 0)
                {
                    int p = InitialPercent();
                    lock (Gate) { targetPct = p; }
                    Log("空闲检查：重建后设备值=" + p + "%");
                }
                return;
            }

            int old;
            lock (Gate)
            {
                if (dirty) return;
                old = targetPct;
                int p = devPct;
                if (p < MinPercent) p = MinPercent;
                if (p > MaxPercent) p = MaxPercent;
                targetPct = p;
            }
            if (old != targetPct) Log("空闲同步：内部值 " + old + " -> " + targetPct);
        }
        catch (Exception ex) { Log("空闲检查异常: " + ex.Message); }
    }

    // ================= 后台写入线程（合并连续的滚轮事件） =================
    static void WorkerLoop()
    {
        while (true)
        {
            if (!Wake.WaitOne(HealthCheckMs)) { IdleCheck(); continue; }
            while (true)
            {
                int pct;
                lock (Gate)
                {
                    if (!dirty) break;
                    pct = targetPct;
                    dirty = false;
                }
                bool ok;
                try { ok = ApplyAll(pct); }
                catch (Exception ex) { ok = false; Log("apply error: " + ex); }
                lock (Gate) { lastError = ok ? "" : "调光未生效"; }
                if (!ok)
                {
                    Log("apply failed pct=" + pct + " monitors=" + monitors.Count);
                    OsdShow(pct, lastError);       // 失败要显性化，不能只让提示条说好看的话
                }
            }
        }
    }

    // ================= 滚轮处理 =================
    static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    static bool ModifiersOk(out bool fine)
    {
        fine = Down(VK_SHIFT);
        if (ReqCtrl && !Down(VK_CONTROL)) return false;
        if (ReqAlt && !Down(VK_MENU)) return false;
        if (ReqCtrl == false && ReqAlt == false) { /* 无需修饰键 */ }
        return true;
    }

    static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (nCode >= 0 && wParam == (IntPtr)WM_MOUSEWHEEL)
            {
                bool fine;
                if (ModifiersOk(out fine))
                {
                    MSLLHOOKSTRUCT ms = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                    int delta = (short)((ms.mouseData >> 16) & 0xFFFF);
                    if (delta != 0)
                    {
                        int steps = delta / 120;
                        if (steps == 0) steps = delta > 0 ? 1 : -1;
                        Adjust(steps, fine);
                        return (IntPtr)1;   // 吞掉该事件，避免被前台程序同时响应
                    }
                }
            }
        }
        catch (Exception ex) { Log("hook error: " + ex); }
        return CallNextHookEx(hookHandle, nCode, wParam, lParam);
    }

    static void Adjust(int steps, bool fine)
    {
        int cur;
        lock (Gate) { cur = targetPct; }
        if (cur < 0) return;

        int step = fine ? FineStepPercent : StepPercent;
        int next = cur + steps * step;
        if (next < MinPercent) next = MinPercent;
        if (next > MaxPercent) next = MaxPercent;

        bool limited = (next == cur);
        if (!limited)
        {
            lock (Gate) { targetPct = next; dirty = true; }
            Wake.Set();
        }
        ShowOsd(next, limited);
    }

    // 线程安全地弹提示条（后台线程也会调用）
    static void OsdShow(int pct, string err)
    {
        if (!OsdEnabled || osd == null) return;
        try
        {
            if (osd.InvokeRequired)
                osd.BeginInvoke((MethodInvoker)delegate { osd.Flash(pct, err); });
            else
                osd.Flash(pct, err);
        }
        catch { }
    }

    static void ShowOsd(int pct, bool limited)
    {
        OsdShow(pct, lastError);
    }

    static int InitialPercent()
    {
        if (monitors.Count == 0) return 50;
        Mon m = monitors[0];
        if (m.Max <= m.Min) return 50;
        int pct = (int)Math.Round((m.Cur - m.Min) * 100.0 / (m.Max - m.Min));
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        return pct;
    }

    // ================= OSD =================
    class OsdForm : Form
    {
        public int Pct = 50;
        public string Err = "";

        float S = 1f;
        int PadX, PadY, BarW, BarH, Gap, TextH, R;
        readonly System.Windows.Forms.Timer hold = new System.Windows.Forms.Timer();
        readonly System.Windows.Forms.Timer fade = new System.Windows.Forms.Timer();
        const double BaseOpacity = 0.94;

        public OsdForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Color.FromArgb(22, 22, 26);
            Opacity = BaseOpacity;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            hold.Tick += delegate { hold.Stop(); fade.Start(); };
            fade.Interval = 15;
            fade.Tick += delegate
            {
                Opacity -= 0.07;
                if (Opacity <= 0.03) { fade.Stop(); Hide(); Opacity = BaseOpacity; }
            };
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000;  // WS_EX_NOACTIVATE：不抢焦点
                cp.ExStyle |= 0x00000080;  // WS_EX_TOOLWINDOW：不出现在 Alt+Tab
                cp.ExStyle |= 0x00000020;  // WS_EX_TRANSPARENT：鼠标穿透
                return cp;
            }
        }

        public void SetHold(int ms) { hold.Interval = ms; }

        public void Flash(int pct, string err)
        {
            try
            {
                Pct = pct;
                Err = err ?? "";
                IntPtr h = Handle;          // 强制建句柄，确保尺寸/DPI 已布局
                ApplyMetrics();
                Position();
                Invalidate();
                hold.Stop();
                fade.Stop();
                Opacity = BaseOpacity;
                if (!Visible) Show();
                hold.Start();
                Log("osd flash pct=" + pct + " size=" + Width + "x" + Height + " loc=" + Location.X + "," + Location.Y
                    + " dpi=" + DeviceDpi + " visible=" + Visible + " opacity=" + Opacity);
            }
            catch (Exception ex) { Log("osd error: " + ex); }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            ApplyMetrics();
            Position();
        }

        void ApplyMetrics()
        {
            S = DeviceDpi / 96f;
            PadX = (int)(20 * S);
            PadY = (int)(13 * S);
            BarW = (int)(230 * S);
            BarH = (int)(8 * S);
            Gap = (int)(9 * S);
            TextH = (int)(28 * S);
            R = (int)(11 * S);
            ClientSize = new Size(PadX * 2 + BarW, PadY * 2 + TextH + Gap + BarH);
            using (GraphicsPath p = RoundRect(new Rectangle(0, 0, Width, Height), R))
                Region = new Region(p);
        }

        void Position()
        {
            if (Width <= 0) return;
            Screen scr = Screen.FromPoint(Cursor.Position);
            Rectangle wa = scr.WorkingArea;
            int x = wa.Left + (wa.Width - Width) / 2;
            int y = wa.Bottom - Height - (int)(wa.Height * 0.10);
            if (y < wa.Top) y = wa.Top;
            Location = new Point(x, y);
        }

        static GraphicsPath RoundRect(Rectangle r, int radius)
        {
            GraphicsPath p = new GraphicsPath();
            int d = Math.Max(1, radius * 2);
            if (d > r.Height) d = r.Height;
            if (d > r.Width) d = r.Width;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush bg = new SolidBrush(Color.FromArgb(238, 22, 22, 26)))
                g.FillRectangle(bg, ClientRectangle);
            using (GraphicsPath p = RoundRect(new Rectangle(0, 0, Width - 1, Height - 1), R))
            using (Pen pen = new Pen(Color.FromArgb(64, 255, 255, 255), Math.Max(1f, S)))
                g.DrawPath(pen, p);

            bool err = Err.Length > 0;
            string label = err ? Err : "屏幕亮度";
            string val = err ? "" : Pct + "%";

            using (Font fLabel = new Font("Microsoft YaHei UI", 9.5f, FontStyle.Regular, GraphicsUnit.Point))
            using (Font fVal = new Font("Microsoft YaHei UI", 13f, FontStyle.Bold, GraphicsUnit.Point))
            using (SolidBrush bLabel = new SolidBrush(Color.FromArgb(205, 232, 232, 242)))
            using (SolidBrush bVal = new SolidBrush(err ? Color.FromArgb(255, 255, 160, 90) : Color.White))
            {
                SizeF ls = g.MeasureString(label, fLabel);
                g.DrawString(label, fLabel, bLabel, PadX, PadY + (TextH - ls.Height) / 2f);
                if (!err)
                {
                    SizeF vs = g.MeasureString(val, fVal);
                    g.DrawString(val, fVal, bVal, Width - PadX - vs.Width, PadY + (TextH - vs.Height) / 2f);
                }
            }

            int by = PadY + TextH + Gap;
            using (GraphicsPath bp = RoundRect(new Rectangle(PadX, by, BarW, BarH), BarH / 2))
            using (SolidBrush bb = new SolidBrush(Color.FromArgb(46, 255, 255, 255)))
                g.FillPath(bb, bp);

            int span = Math.Max(1, MaxPercent - MinPercent);
            int clamped = Math.Max(MinPercent, Math.Min(MaxPercent, Pct));
            int fillW = (int)Math.Round(BarW * (clamped - MinPercent) / (double)span);
            if (fillW > 0)
            {
                if (fillW < BarH) fillW = BarH;
                int w = Math.Min(fillW, BarW);
                using (GraphicsPath fp = RoundRect(new Rectangle(PadX, by, w, BarH), BarH / 2))
                using (LinearGradientBrush fb = new LinearGradientBrush(
                    new Rectangle(PadX, by, Math.Max(BarW, 2), BarH),
                    Color.FromArgb(255, 56, 148, 255),
                    Color.FromArgb(255, 126, 205, 255),
                    LinearGradientMode.Horizontal))
                    g.FillPath(fb, fp);
            }
        }
    }

    // ================= 托盘图标 =================
    static void MakeTray()
    {
        if (!UseTrayIcon) return;
        try
        {
            tray = new NotifyIcon();
            Icon ic = null;
            try { ic = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            if (ic == null) { try { ic = SystemIcons.Application; } catch { } }
            if (ic != null) tray.Icon = ic;
            tray.Text = "屏幕亮度：Ctrl + Alt + 滚轮";
            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripMenuItem info = new ToolStripMenuItem("Ctrl + Alt + 滚轮 = 调亮度");
            info.Enabled = false;
            menu.Items.Add(info);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("显示当前亮度", null, delegate
            {
                int p;
                lock (Gate) { p = targetPct; }
                if (osd != null && p >= 0) osd.Flash(p, lastError);
            });
            menu.Items.Add("重新检测显示器", null, delegate
            {
                RefreshMonitors();
                lock (Gate) { dirty = true; }
                Wake.Set();
            });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出", null, delegate { Application.Exit(); });
            tray.ContextMenuStrip = menu;
            tray.Visible = true;
            Log("tray icon created");
        }
        catch (Exception ex) { tray = null; Log("tray error: " + ex.Message); }
    }

    static void Cleanup()
    {
        try { if (hookHandle != IntPtr.Zero) UnhookWindowsHookEx(hookHandle); } catch { }
        hookHandle = IntPtr.Zero;
        try
        {
            foreach (Mon m in monitors)
            {
                PHYSICAL_MONITOR pm = new PHYSICAL_MONITOR();
                pm.hPhysicalMonitor = m.Handle;
                DestroyPhysicalMonitors(1, new PHYSICAL_MONITOR[] { pm });
            }
        }
        catch { }
        monitors.Clear();
        try { if (tray != null) { tray.Visible = false; tray.Dispose(); } } catch { }
        try { if (singleton != null) singleton.ReleaseMutex(); } catch { }
    }

    // ================= 启动 =================
    static void UiThread()
    {
        bool created;
        singleton = new Mutex(true, @"Local\BrightnessWheelSingleton", out created);
        if (!created) return;          // 已经有实例在跑

        try { Application.SetHighDpiMode(HighDpiMode.PerMonitorV2); } catch (Exception ex) { Log("dpi: " + ex.Message); }
        try { Application.EnableVisualStyles(); } catch { }
        Application.ThreadException += delegate (object s, ThreadExceptionEventArgs e) { Log("ui error: " + e.Exception); };
        Application.ApplicationExit += delegate { Cleanup(); };

        string forced = Environment.GetEnvironmentVariable("BRIGHTNESS_TOOL_VCP_MODE");
        if (forced == "vcp") ForceMode = 1;
        else if (forced == "legacy") ForceMode = 0;

        RefreshMonitors();
        targetPct = InitialPercent();
        if (monitors.Count == 0) lastError = "未找到支持 DDC/CI 的显示器";
        Log("start: monitors=" + monitors.Count + " initialPct=" + targetPct + " step=" + StepPercent
            + " osd=" + OsdEnabled + " tray=" + UseTrayIcon);
        foreach (Mon m in monitors)
            Log("  monitor: " + m.Name + " channel=" + (m.Mode == 1 ? "VCP0x10" : "legacy")
                + " min=" + m.Min + " max=" + m.Max + " cur=" + m.Cur);

        osd = new OsdForm();
        osd.SetHold(OsdHoldMs);
        MakeTray();

        Thread w = new Thread(WorkerLoop);
        w.IsBackground = true;
        w.Name = "brightness-writer";
        w.Start();

        hookProc = HookCallback;
        IntPtr hMod = GetModuleHandle(null);
        if (hMod == IntPtr.Zero) hMod = LoadLibrary("user32.dll");
        hookHandle = SetWindowsHookEx(WH_MOUSE_LL, hookProc, hMod, 0);
        if (hookHandle == IntPtr.Zero)
        {
            lastError = "鼠标钩子安装失败";
            if (tray != null) tray.Text = "屏幕亮度：钩子安装失败";
            Log("hook install FAILED err=" + Marshal.GetLastWin32Error());
            return;
        }
        Log("hook installed");

        Application.Run(new ApplicationContext());
    }

    public static void Run()
    {
        Thread t = new Thread(UiThread);
        t.IsBackground = false;
        t.Name = "brightness-ui";
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        t.Join();
    }
}
